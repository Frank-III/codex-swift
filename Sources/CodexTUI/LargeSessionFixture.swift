import Foundation

/// A deterministic, frontend-only session corpus that uses the same semantic transcript entries as a
/// live KWWK-backed conversation. It is intended for interactive soak testing and repeatable benchmarks.
public enum CodexLargeSessionFixture {
  public struct Summary: Hashable, Sendable {
    public var turns: Int
    public var entries: Int
    public var sourceBytes: Int

    public init(turns: Int, entries: Int, sourceBytes: Int) {
      self.turns = turns
      self.entries = entries
      self.sourceBytes = sourceBytes
    }
  }

  @MainActor
  public static func makeApplication(
    turns: Int = 1_000,
    directory: String = FileManager.default.currentDirectoryPath
  ) -> CodexApplication {
    let application = CodexRuntime.demo(directory: directory)
    populate(application.model, turns: turns)
    return application
  }

  @discardableResult
  @MainActor
  public static func populate(_ model: CodexSessionModel, turns requestedTurns: Int) -> Summary {
    let turns = max(0, requestedTurns)
    let entries = makeEntries(turns: turns)
    model.entries = entries
    model.threadTitle = "Large deterministic performance session"
    model.model = "gpt-5.6-sol"
    model.modelProvider = "openai-codex"
    model.reasoningEffort = "medium"
    model.contextRemainingPercent = 8
    model.composer.text = ""
    model.isWorking = false

    return Summary(
      turns: turns,
      entries: entries.count,
      sourceBytes: entries.reduce(into: 0) { total, entry in
        total += sourceByteCount(entry.content)
      })
  }

  public static func makeEntries(turns: Int) -> [TranscriptEntry] {
    guard turns > 0 else { return [] }
    var entries: [TranscriptEntry] = []
    entries.reserveCapacity(turns * 5)

    for turn in 0..<turns {
      let ordinal = turn + 1
      entries.append(
        TranscriptEntry(
          id: "fixture-user-\(ordinal)",
          content: .user(userPrompt(turn: ordinal))))
      entries.append(
        TranscriptEntry(
          id: "fixture-reasoning-\(ordinal)",
          content: .reasoning(
            summary: "Inspecting the relevant code paths",
            body: reasoningBody(turn: ordinal),
            streaming: false)))
      entries.append(explorationEntry(turn: ordinal))
      entries.append(commandEntry(turn: ordinal))
      if ordinal.isMultiple(of: 17) {
        entries.append(editEntry(turn: ordinal))
      }
      entries.append(
        TranscriptEntry(
          id: "fixture-assistant-\(ordinal)",
          content: .assistant(assistantResponse(turn: ordinal), streaming: false)))
      if ordinal.isMultiple(of: 41) {
        entries.append(
          TranscriptEntry(
            id: "fixture-notice-\(ordinal)",
            content: .notice("You have \(max(1, 100 - ordinal / 20))% weighted tokens left")))
      }
    }
    return entries
  }

  private static func userPrompt(turn: Int) -> String {
    """
    Please inspect the session and implement iteration \(turn). Keep the existing behavior stable, add a
    regression test for the edge case, and explain any terminal or application ownership decision.
    """
  }

  private static func reasoningBody(turn: Int) -> String {
    """
    I need to inspect the current implementation before changing it. I will trace the rendering path,
    compare the semantic state with the terminal-facing representation, and verify that iteration \(turn)
    does not invalidate already committed history. The important invariant is that live state remains
    mutable while completed rows retain stable identity.
    """
  }

  private static func explorationEntry(turn: Int) -> TranscriptEntry {
    let kind: ExplorationActionKind =
      switch turn % 3 {
      case 0: .search
      case 1: .read
      default: .list
      }
    let path = "Sources/CodexTUI/Feature\(turn % 23).swift"
    return TranscriptEntry(
      id: "fixture-exploration-\(turn)",
      content: .tool(
        ToolActivity(
          callID: "fixture-exploration-call-\(turn)",
          name: kind.rawValue,
          detail: path,
          output: ["Matched the presentation and lifecycle code"],
          status: .succeeded,
          durationMilliseconds: 12 + turn % 80,
          presentation: .exploration(
            ExplorationAction(kind: kind, subject: "render and update paths", path: path)))))
  }

  private static func commandEntry(turn: Int) -> TranscriptEntry {
    let output = (0..<8).map { line in
      "Test Case 'LargeSessionTests.testIteration\(turn)_\(line)' passed (0.00\(line) seconds)"
    }
    return TranscriptEntry(
      id: "fixture-command-\(turn)",
      content: .tool(
        ToolActivity(
          callID: "fixture-command-call-\(turn)",
          name: "swift test",
          detail: "Run focused and integration tests",
          output: output,
          status: .succeeded,
          durationMilliseconds: 850 + turn % 300,
          presentation: .command(
            command: "swift test --filter LargeSessionTests/testIteration\(turn)",
            output: output,
            omittedLineCount: turn.isMultiple(of: 9) ? 37 : 0))))
  }

  private static func editEntry(turn: Int) -> TranscriptEntry {
    TranscriptEntry(
      id: "fixture-edit-\(turn)",
      content: .tool(
        ToolActivity(
          callID: "fixture-edit-call-\(turn)",
          name: "Edited",
          detail: "Sources/CodexTUI/Feature\(turn % 23).swift",
          status: .succeeded,
          durationMilliseconds: 21,
          presentation: .edit(
            path: "Sources/CodexTUI/Feature\(turn % 23).swift",
            additions: 3,
            deletions: 1,
            lines: [
              DiffLine(lineNumber: 40, kind: .context, text: "  let previous = state"),
              DiffLine(lineNumber: 41, kind: .deletion, text: "- return previous"),
              DiffLine(lineNumber: 41, kind: .addition, text: "+ let next = update(previous)"),
              DiffLine(lineNumber: 42, kind: .addition, text: "+ validate(next)"),
              DiffLine(lineNumber: 43, kind: .addition, text: "+ return next"),
            ]))))
  }

  private static func assistantResponse(turn: Int) -> String {
    """
    Implemented iteration \(turn) and kept the reusable mechanics in the framework layer.

    ### What changed

    - Preserved stable transcript identity and mutable-tail behavior.
    - Kept terminal lifecycle policy separate from conversation semantics.
    - Added focused coverage for narrow widths, resize, and repeated input.

    ```swift
    let result = session.reconcile(width: terminalWidth)
    guard result.isConsistent else { throw SessionError.invalidState }
    ```

    | Check | Result |
    | --- | --- |
    | Focused tests | Passed |
    | Full suite | Passed |
    | History identity | Preserved |

    The next redraw should only process newly changed presentation state; completed native-history rows do
    not need to be painted into the retained viewport again.
    """
  }

  private static func sourceByteCount(_ content: TranscriptContent) -> Int {
    switch content {
    case .user(let text), .assistant(let text, _), .notice(let text), .error(let text):
      text.utf8.count
    case .reasoning(let summary, let body, _):
      summary.utf8.count + (body?.utf8.count ?? 0)
    case .tool(let tool):
      tool.name.utf8.count + tool.detail.utf8.count
        + tool.output.reduce(0) { $0 + $1.utf8.count }
    case .approvalDecision(let decision):
      String(describing: decision).utf8.count
    }
  }
}
