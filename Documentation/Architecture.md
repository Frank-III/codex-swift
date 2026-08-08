# Architecture

Codex Swift has three intentionally separate layers:

1. `CodexTUI` models the transcript, composer, overlays, shortcuts, session status, and reducers.
2. `KWWKAgent` supplies streaming model turns, tools, queues, compaction, subagents, and background
   work. `KWWKAI` supplies providers and authentication primitives. Codex Swift owns durable sessions
   because its tree, branch, display-history, and extension-state semantics are application policy.
3. `TermLoom` renders the value snapshot and owns Unicode width, layout, input decoding, inline
   viewport behavior, buffer diffing, and terminal restoration.

The UI never reads KWWK's mutable state while rendering. Agent events are reduced on the main
actor into a `CodexSnapshot`; rendering is therefore deterministic and snapshot-testable. The
controller is the sole command boundary back into the harness.

## Persistent session trees

`CodexSessionTreeStore` keeps each logical session as an append-only JSONL tree. Stable entry IDs and
parent IDs preserve every in-place branch; durable checkout records restore the selected leaf even
when the user navigates and exits before submitting another prompt. `/tree` renders the complete
session graph in Codex's overlay style. Selecting a user message checks out its parent and restores
its text and images for editing, while selecting a complete assistant/tool boundary continues after
that entry. `/rewind` uses the same non-destructive branch operation.

The selected root-to-leaf path is projected into ordinary KWWK `[Message]` state. Branch navigation
retires the old agent and builds a fresh agent from that projection, so KWWK remains an unmodified,
upgradable dependency. Compaction nodes replace model-facing context only for their descendants;
full display history and sibling branches remain available. Existing flat KWWK session files import
as linear trees and are backed up under `sessions/legacy` on the first tree write.

The default experience is inline. Ownership is deliberately split at the source/terminal boundary:

- `CodexTUI` decides what is semantically committed, retains canonical source, gates mutable Markdown
  tables and incomplete lines, and requests reset/replay after rewinds, provider rewrites, display-mode
  changes, or session replacement. It owns the 75 ms resize quiet period and formats backward from the
  transcript tail until the 1,000-row replay budget is full. Running tools and streams without committed
  source emit no placeholder history rows; they remain solely in the mutable viewport until their final
  source can append cleanly.
- `TermLoom` decides how committed rendered rows reach native scrollback for the detected terminal host,
  owns viewport movement and buffer invalidation, and notifies the application after clear, resize, or
  suspend/resume resets.

Only the active tail, status, composer, queues, and overlays remain in the retained viewport. Its
height follows the current presentation up to a 22-row cap, matching upstream Codex's
`desired_height`/`draw_with_resize_reflow` behavior instead of reserving the cap at startup. This keeps
Codex lifecycle policy out of the terminal backend while keeping emulator-specific ANSI behavior
out of the Codex application.

## Stress-client findings and ownership

The complementary audit uses upstream Codex commit
`e428a12d2235fe2bc10b10bc45d245d1f491f3c7` as the behavioral baseline and assigns fixes at the
lowest reusable layer:

- TermLoom owns retained input/parser state across backend rebuilds, one-shot cursor-probe bytes,
  physical-to-local mouse rebasing, balanced terminal protocols, render-time Observation, stable focus,
  state-derived cursor metadata, and identified atomic text elements.
- Codex owns whether content is a large-paste element and its hidden payload, active-agent versus local
  shell state, atomic model-plus-reasoning confirmation, live context reporting, setting-change policy,
  fuzzy mention ranking, and exact popup commands.
- Selection/popup geometry is shared only where policy-free: `SelectionViewport` and measured row groups
  live below Codex filtering and insertion semantics. A complete generic menu presenter remains a design
  direction, not an excuse to move Codex overlays into TermLoom.

Large pastes now use TermLoom text-element identity instead of visible-label replacement. Cursor motion
cannot enter a placeholder, intersecting deletion removes it as a unit, unrelated mention/Vim edits keep
its range valid, and submission expands only still-present element IDs. Model and reasoning choices are
committed and persisted together only after final confirmation. Local shell completion consults the live
driver before changing working state, so it cannot make an active agent turn appear idle.

Editable replacement overlays expose a hardware bar cursor with wide-grapheme-aware columns; skill and
file menus measure their actual wrapped rows, fuzzy-rank results, wrap navigation, accept Tab, and support
Ctrl-P/Ctrl-N. `/status` reads live driver context usage rather than a stale snapshot default.

### Remaining deliberate gaps

- The transcript pager is feature-complete inside the retained inline surface, but the current 22-row cap
  means it is not yet a full physical-terminal alternate-screen pager on taller terminals. Its full-source,
  width-specific cache is also prepared eagerly, so first open remains linear for pathological sessions even
  though later frames are viewport-bound. Switching viewport modes safely is framework lifecycle work; lazy
  cell measurement and indexing remain Codex presentation work.
- Escape dismissal for an active mention currently follows the established Swift behavior of reopening
  after cursor re-entry. Upstream retains a dismissed-token sentinel; adopting that policy requires an
  explicit UX decision because the prior Swift requirement requested re-entry reopening.
- Native scrollback/reflow evidence remains terminal-host specific. PTY tests verify transport, protocol,
  origin, input and lifecycle invariants; Supaterm/Ghostty and tmux/Zellij attest native-history behavior.
