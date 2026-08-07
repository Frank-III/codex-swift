import KWWKAI
import KWWKAgent
import Testing

@testable import CodexTUI

@MainActor
@Suite struct CodexEventReducerTests {
  @Test func streamingMessageAndToolLifecycleReduceIntoStableEntries() {
    let model = CodexSessionModel(snapshot: CodexSnapshot(showHeader: false))
    let reducer = CodexEventReducer(model: model)
    reducer.consume(.agentStart)
    reducer.consume(.turnStart)
    let reasoningOnly = AssistantMessage(
      content: [.thinking(ThinkingContent(thinking: "Checking files\nstill thinking"))],
      api: "test", provider: "test", model: "test")
    reducer.consume(
      .messageUpdate(
        message: reasoningOnly,
        assistantMessageEvent: .thinkingDelta(
          contentIndex: 0, delta: "still thinking", partial: reasoningOnly)))
    guard case .reasoning(_, let visibleThinking, streaming: true) = model.entries[0].content else {
      Issue.record("Expected source-backed streaming reasoning")
      return
    }
    #expect(visibleThinking == "Checking files\n")
    #expect(model.entries[0].streamingMarkdown?.pendingSource == "still thinking")

    reducer.consume(
      .messageUpdate(
        message: AssistantMessage(
          content: [
            .thinking(ThinkingContent(thinking: "Checking files\nstill thinking")),
            .text(TextContent(text: "I found")),
          ],
          api: "test", provider: "test", model: "test"
        ),
        assistantMessageEvent: .textDelta(
          contentIndex: 1,
          delta: " found",
          partial: AssistantMessage(
            content: [.text(TextContent(text: "I found"))],
            api: "test", provider: "test", model: "test"))
      ))
    guard case .reasoning(_, let completedThinking, streaming: false) = model.entries[0].content
    else {
      Issue.record("Expected reasoning to finalize when assistant text begins")
      return
    }
    #expect(completedThinking == "Checking files\nstill thinking")
    #expect(model.entries[0].streamingMarkdown == nil)

    reducer.consume(
      .toolExecutionStart(
        toolCallId: "call-1", toolName: "bash", args: ["command": "swift test"]))
    reducer.consume(
      .toolExecutionEnd(
        toolCallId: "call-1",
        toolName: "bash",
        result: AgentToolResult(
          content: [.text(TextContent(text: "ok"))], uiDisplay: ["exit 0 · 1.2s"]),
        isError: false
      ))
    reducer.consume(.agentEnd(messages: [], summary: AgentRunSummary(durationMs: 1_200)))

    #expect(model.isWorking == false)
    #expect(model.elapsedSeconds == 1)
    #expect(model.entries.count == 3)
    guard case .reasoning(_, let finalThinking, streaming: false) = model.entries[0].content else {
      Issue.record("Expected finalized reasoning")
      return
    }
    #expect(finalThinking == "Checking files\nstill thinking")
    guard case .assistant("I found", streaming: false) = model.entries[1].content else {
      Issue.record("Expected finalized assistant response")
      return
    }
    guard case .tool(let tool) = model.entries[2].content else {
      Issue.record("Expected tool activity")
      return
    }
    #expect(tool.status == .succeeded)
    #expect(tool.detail == "swift test")
    #expect(tool.output == ["exit 0 · 1.2s"])
  }

  @Test func streamRewindDropsOnlyUncommittedAssistantCells() {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(
        entries: [TranscriptEntry(content: .notice("keep me"))], showHeader: false))
    let reducer = CodexEventReducer(model: model)
    reducer.consume(.turnStart)
    let partial = AssistantMessage(
      content: [.text(TextContent(text: "discard me"))],
      api: "test", provider: "test", model: "test")
    reducer.consume(
      .messageUpdate(
        message: partial,
        assistantMessageEvent: .textDelta(contentIndex: 0, delta: "discard me", partial: partial)))
    reducer.consume(.streamRewind)

    #expect(
      model.entries == [TranscriptEntry(id: model.entries[0].id, content: .notice("keep me"))])
  }

  @Test func commandOutputUpdatesLiveAndEditFailuresRetainContext() {
    let model = CodexSessionModel(snapshot: CodexSnapshot(showHeader: false))
    let reducer = CodexEventReducer(model: model)

    reducer.consume(
      .toolExecutionStart(
        toolCallId: "bash-live", toolName: "bash", args: ["command": "swift test"]))
    reducer.consume(
      .toolExecutionUpdate(
        toolCallId: "bash-live", toolName: "bash", args: ["command": "swift test"],
        partialResult: AgentToolResult(
          content: [.text(TextContent(text: "suite one\nstill running"))])))
    guard case .tool(let running) = model.entries.first?.content,
      case .command(let command, let output, _) = running.presentation
    else {
      Issue.record("Expected live command cell")
      return
    }
    #expect(running.status == .running)
    #expect(command == "swift test")
    #expect(output == ["suite one", "still running"])

    reducer.consume(
      .toolExecutionStart(
        toolCallId: "edit-failed", toolName: "edit", args: ["path": "Sources/App.swift"]))
    reducer.consume(
      .toolExecutionEnd(
        toolCallId: "edit-failed", toolName: "edit",
        result: AgentToolResult(
          content: [.text(TextContent(text: "Could not find the target block"))]),
        isError: true))

    guard case .tool(let failed) = model.entries.last?.content,
      case .editFailure(let path, let failureOutput) = failed.presentation
    else {
      Issue.record("Expected source-shaped edit failure")
      return
    }
    #expect(failed.status == .failed)
    #expect(path == "Sources/App.swift")
    #expect(failureOutput == ["Could not find the target block"])
  }

  @Test func structuredToolsBecomeSemanticCodexCells() {
    let model = CodexSessionModel(snapshot: CodexSnapshot(showHeader: false))
    let reducer = CodexEventReducer(model: model)

    reducer.consume(
      .toolExecutionStart(
        toolCallId: "bash-1", toolName: "bash",
        args: ["command": "mise exec -- swift test"]))
    reducer.consume(
      .toolExecutionEnd(
        toolCallId: "bash-1", toolName: "bash",
        result: AgentToolResult(
          content: [
            .text(TextContent(text: (1...12).map { "line \($0)" }.joined(separator: "\n")))
          ]
        ),
        isError: false))

    reducer.consume(
      .toolExecutionStart(
        toolCallId: "edit-1", toolName: "edit",
        args: ["path": "Sources/App.swift", "edits": []]))
    reducer.consume(
      .toolExecutionEnd(
        toolCallId: "edit-1", toolName: "edit",
        result: AgentToolResult(
          content: [.text(TextContent(text: "Successfully replaced 1 block."))],
          details: [
            "patch":
              """
            --- a/Sources/App.swift
            +++ b/Sources/App.swift
            @@ -4,2 +4,2 @@
             let old = 1
            -print(old)
            +print("new")
            """
          ]),
        isError: false))

    guard case .tool(let command) = model.entries[0].content,
      case .command(let text, let output, let omitted) = command.presentation
    else {
      Issue.record("Expected a semantic command cell")
      return
    }
    #expect(text == "mise exec -- swift test")
    #expect(output.first == "line 1")
    #expect(output.last == "line 12")
    #expect(output.count == 12)
    #expect(omitted == 0)

    guard case .tool(let edit) = model.entries[1].content,
      case .edit(let path, let additions, let deletions, let lines) = edit.presentation
    else {
      Issue.record("Expected a semantic edit cell")
      return
    }
    #expect(path == "Sources/App.swift")
    #expect(additions == 1)
    #expect(deletions == 1)
    #expect(lines.map(\.lineNumber) == [4, 5, 5])
    #expect(lines.map(\.kind) == [.context, .deletion, .addition])
  }
}
