# Large-session performance

Codex Swift includes a deterministic frontend-only stress corpus. It uses the same `TranscriptEntry`
shapes as a live KWWK-backed conversation: user prompts, completed reasoning, exploration, command output,
diffs, notices, Markdown, fenced Swift, and tables. It does not call a model or alter persisted sessions.

## Interactive soak tests

Run a release build so compiler instrumentation does not dominate rendering.

The isolated frontend fixture uses the deterministic demo driver. It is useful for rendering, composer,
overlay, resize, scrollback, and keymap tests, but deliberately has no live KWWK tools or model:

```sh
swift run -c release codex-swift --large-demo 1000
```

For a fully fledged runtime, seed the same visible history into `CodexRuntime.live()`:

```sh
swift run -c release codex-swift --large-live 1000
```

`--large-live` retains the real KWWK driver, authenticated model catalog, file/skill discovery, image input,
tools, slash commands, and system services. The synthetic rows stress the UI only; they are **not** copied
into the model's context, so a subsequent live prompt does not send thousands of fake turns to a provider.
New live turns append normally and are suitable for testing responsiveness while tools stream output.

The number is conversation turns. A 1,000-turn fixture contains about 5,082 semantic entries and 38,454
rendered rows at 120 columns.

## Repeatable benchmark

```sh
swift run -c release codex-benchmark --turns 1000 --iterations 100
```

Options are `--turns`, `--iterations`, `--width`, `--height`, and `--reflow-width`. The harness measures:

- deterministic session construction;
- the cold canonical-document render;
- key handling plus the same document/body/TestBackend frame path used by the app;
- an incremental user/assistant append;
- capped width-dependent native-history replay;
- eager transcript-pager cache preparation, followed by open and page-scroll frames;
- current resident memory at each phase using Mach task information.

The in-process harness intentionally does not measure terminal-emulator parsing, native scrollback
storage, PTY bandwidth, or session deserialization. Cold startup and width replay therefore establish
application-side costs, not end-to-end wall time in every terminal host.

The PTY soak runs the real application loop, waits for the final resumed row to be emitted, submits a new
chat prompt, waits for the demo response to settle, and samples process RSS:

```sh
swift build -c release --product codex-swift
python3 Scripts/large-session-pty-soak.py .build/release/codex-swift 1000
```

It selects the Supaterm/Ghostty whole-terminal history path. This validates application output and input
continuity, though it still does not emulate a terminal's visual scrollback implementation.

## Baseline results

Median of three optimized runs on the development Apple Silicon host. Each row starts a fresh process. Syntax
highlighting has no exact-result cache; normal inline startup and width replay format only the newest 1,000 rows:

| Turns | Entries | Source | Cold frame | Key p95 | Append | Width replay | Pager prepare | Pager frame / scroll | RSS cold / replay / pager |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,000 | 5,082 | 3.4 MiB | 51.7 ms | 0.07 ms | 0.29 ms | 34.0 ms | 1.47 s | 0.19 / 0.14 ms | 29 / 31 / 90 MiB |
| 2,000 | 10,165 | 6.8 MiB | 50.9 ms | 0.07 ms | 0.30 ms | 35.0 ms | 2.96 s | 0.19 / 0.15 ms | 37 / 38 / 157 MiB |
| 5,000 | 25,415 | 17.0 MiB | 51.3 ms | 0.07 ms | 0.30 ms | 35.0 ms | 7.56 s | 0.20 / 0.15 ms | 56 / 58 / 356 MiB |

The 5,000-turn case is intentionally pathological and greatly exceeds a normal model context. Ordinary
editing remains independent of transcript length because the app caches the canonical document and only
renders the mutable live tail. Transcript mutations still reconcile canonical identity. Cold load and width
reflow are bounded by walking backward from the source transcript and stopping once the newest 1,000 rendered rows
are available, matching Rust Codex's fallback resize-reflow cap. The complete source remains available in the
transcript pager.

Actual resize events use Rust Codex's 75 ms quiet-period policy. Repeated intermediate widths postpone the deadline;
only the settled width rebuilds normal terminal history. Transcript and other overlays keep their current projection
while they own the screen, avoiding an eager full-history rebuild during resize. At a stable width, append-only replay
may grow to 2,000 rows before Codex reanchors it to the newest 1,000 in one source-backed reset; this hysteresis keeps
streaming work bounded without resetting scrollback for every new row.

The pager remains a distinct full-source surface. Preparing its width-specific cache is intentionally reported
separately above and is still linear in transcript size. Once prepared, `ScrollViewport` passes only the visible row
range to `Paragraph`, so open and scroll frames remain viewport-bound. Removing that eager preparation cost requires a
cell-oriented, lazily measured pager index; the normal inline-history row cap must not silently truncate pager source.

## Performance invariants

- Composer-only changes must not rerender completed Markdown or allocate another copy of terminal history.
- `CodexSessionModel.transcriptRevision` advances on semantic transcript mutation, not local composer edits.
- `InlineDocument.revision` is an application-owned promise. At the same document identity and width, an
  unchanged non-`nil` revision lets TermLoom bypass stable-block reconciliation.
- Width changes debounce for 75 ms, then format and replay only the source-backed row-capped tail.
- Per-entry rendering remains identity-based so appends and mutable-tail changes do not reparse completed Markdown.
- Ordinary overlays render only the overlay, composer, and mutable tail; they never repaint committed history.
- Streaming and external model changes opt into TermLoom's periodic redraw capability while work is active.
- The revision is an optimization only; applications that cannot provide a reliable revision should leave
  it `nil` and retain full source-backed comparison.

Before these invariants were added, the 500-turn fixture took roughly 743 ms for every key-driven frame and
resident memory climbed from about 53 MiB to 776 MiB over 30 edits because the full transcript was reparsed
on every redraw. The benchmark is retained to prevent that regression.

A second defect appeared only in the real terminal path: a cold resume produced one backend insertion per
semantic block. Supaterm's whole-terminal strategy cleared and re-reserved the live pane for each block,
creating long blank regions and withholding input until thousands of writes completed. TermLoom now groups
canonical rows into bounded render buffers and marks them as one history batch; the backend clears once,
streams continuation chunks, and reserves the composer only after the final chunk. A 1,000-turn PTY soak
then reached output quiescence in 2.70 seconds, accepted a new chat, completed the simulated response in
3.22 seconds, emitted 3.12 MB, and peaked near 96 MiB on the development host. With tail-first replay and no
syntax-result cache, three warm 2,000-turn deterministic PTY runs reached startup quiescence in 0.45–0.46 seconds.
A 20-event, 200 ms resize drag settled in 0.77–0.79 seconds and emitted about 72 KiB; that interval includes the
75 ms debounce and a deliberate 0.35-second output-quiet window.
