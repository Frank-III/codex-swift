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
- transcript-pager open and page-scroll frames;
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

Median of three optimized runs on the development Apple Silicon host. Each row starts a fresh process, so its cold
frame begins with empty application and syntax-highlight caches:

| Turns | Entries | Source | Cold frame | Key p95 | Append | Width replay | Pager open / scroll | RSS cold / replay |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,000 | 5,082 | 3.4 MiB | 0.39 s | 0.07 ms | 2.4 ms | 0.39 s | 0.19 / 0.14 ms | 45 / 49 MiB |
| 2,000 | 10,165 | 6.8 MiB | 0.79 s | 0.07 ms | 4.7 ms | 0.78 s | 0.18 / 0.14 ms | 70 / 78 MiB |
| 5,000 | 25,415 | 17.0 MiB | 1.98 s | 0.07 ms | 12.5 ms | 1.97 s | 0.19 / 0.14 ms | 156 / 176 MiB |

The 5,000-turn case is intentionally pathological and greatly exceeds a normal model context. Ordinary
editing remains independent of transcript length because the app caches the canonical document and only
renders the mutable live tail. Transcript mutations still reconcile canonical identity. Cold load and width
reflow remain linear because canonical presentation is reconstructed, but native terminal replay is capped to
the newest 1,000 rendered rows. The complete source remains available in the transcript pager.

Sampling the 2,000-turn cold path attributed most prior CPU time to repeatedly tokenizing fenced Swift and shell
lines through ICU regular expressions. `TerminalSyntaxHighlighter` now owns a private bounded cache keyed by source,
language, complete theme, and background. It is independent of width, so reflow reuses tokenized spans while Codex
rebuilds wrapping and terminal rows. The fixture intentionally repeats one fenced Swift snippet, making the improvement
larger than a session containing only unique code; unique shell commands still parse normally.

The pager reuses the already rendered transcript cache and Ratatui's `ScrollViewport` row geometry. Only the
visible row range is passed to `Paragraph`; opening or scrolling no longer reparses Markdown, measures tens of
thousands of off-screen rows, or copies the committed transcript into the retained live viewport.

## Performance invariants

- Composer-only changes must not rerender completed Markdown or allocate another copy of terminal history.
- `CodexSessionModel.transcriptRevision` advances on semantic transcript mutation, not local composer edits.
- `InlineDocument.revision` is an application-owned promise. At the same document identity and width, an
  unchanged non-`nil` revision lets Ratatui bypass stable-block reconciliation.
- Width changes ignore the shortcut and replay canonical rows.
- Per-entry rendering remains cached so appends and mutable-tail changes do not reparse completed Markdown.
- Ordinary overlays render only the overlay, composer, and mutable tail; they never repaint committed history.
- Streaming and external model changes opt into Ratatui's periodic redraw capability while work is active.
- The revision is an optimization only; applications that cannot provide a reliable revision should leave
  it `nil` and retain full source-backed comparison.

Before these invariants were added, the 500-turn fixture took roughly 743 ms for every key-driven frame and
resident memory climbed from about 53 MiB to 776 MiB over 30 edits because the full transcript was reparsed
on every redraw. The benchmark is retained to prevent that regression.

A second defect appeared only in the real terminal path: a cold resume produced one backend insertion per
semantic block. Supaterm's whole-terminal strategy cleared and re-reserved the live pane for each block,
creating long blank regions and withholding input until thousands of writes completed. Ratatui now groups
canonical rows into bounded render buffers and marks them as one history batch; the backend clears once,
streams continuation chunks, and reserves the composer only after the final chunk. A 1,000-turn PTY soak
then reached output quiescence in 2.70 seconds, accepted a new chat, completed the simulated response in
3.22 seconds, emitted 3.12 MB, and peaked near 96 MiB on the development host. After replay capping and bounded
syntax-highlight reuse, three 2,000-turn deterministic PTY runs reached startup quiescence in 1.23–1.76 seconds,
emitted about 89.5 KiB, and peaked near 73 MiB. The quiescence timer includes a deliberate 0.4-second quiet window.
