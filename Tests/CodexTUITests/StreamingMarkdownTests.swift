import KWWKAI
import KWWKAgent
import Testing

@testable import CodexTUI

@Suite struct StreamingMarkdownTests {
  @Test func sourceCommitsOnlyAtNewlinesAndFinalizationFlushesTheLastLine() {
    var stream = CodexStreamingMarkdown()

    stream.update(fullSource: "Hello")
    #expect(stream.visibleSource.isEmpty)
    #expect(stream.pendingSource == "Hello")

    stream.update(fullSource: "Hello, world\nNext")
    #expect(stream.stableSource == "Hello, world\n")
    #expect(stream.mutableTailSource.isEmpty)
    #expect(stream.pendingSource == "Next")

    #expect(stream.finalize() == "Hello, world\nNext")
    #expect(stream.stableSource == "Hello, world\nNext")
    #expect(stream.mutableTailSource.isEmpty)
    #expect(stream.pendingSource.isEmpty)
  }

  @Test func candidateAndConfirmedTablesRemainAMutableTail() {
    var stream = CodexStreamingMarkdown()

    stream.update(fullSource: "Intro\nName | Value\n")
    #expect(stream.stableSource == "Intro\n")
    #expect(stream.mutableTailSource == "Name | Value\n")

    stream.update(fullSource: "Intro\nName | Value\n--- | ---\n")
    #expect(stream.stableSource == "Intro\n")
    #expect(stream.mutableTailSource == "Name | Value\n--- | ---\n")

    stream.update(fullSource: "Intro\nName | Value\n--- | ---\nSwift | 6")
    #expect(stream.visibleSource == "Intro\nName | Value\n--- | ---\n")
    #expect(stream.pendingSource == "Swift | 6")

    stream.update(fullSource: "Intro\nName | Value\n--- | ---\nSwift | 6\n")
    #expect(stream.stableSource == "Intro\n")
    #expect(stream.mutableTailSource.hasSuffix("Swift | 6\n"))
  }

  @Test func pipeRowsInsideNonMarkdownFencesDoNotTriggerTableHoldback() {
    var stream = CodexStreamingMarkdown()
    let source = """
      ```swift
      Name | Value
      --- | ---
      ```
      Done
      """ + "\n"

    stream.update(fullSource: source)
    #expect(stream.stableSource == source)
    #expect(stream.mutableTailSource.isEmpty)
  }

  @Test func delimiterAndUnicodeBoundariesMaySpanArbitraryProviderUpdates() {
    let snapshots = [
      "Préface\nNa",
      "Préface\nName | 値\n--",
      "Préface\nName | 値\n--- | ---\nSw",
      "Préface\nName | 値\n--- | ---\nSwift | 六\n",
    ]
    var stream = CodexStreamingMarkdown()
    for snapshot in snapshots { stream.update(fullSource: snapshot) }

    #expect(stream.stableSource == "Préface\n")
    #expect(stream.mutableTailSource == "Name | 値\n--- | ---\nSwift | 六\n")
    #expect(stream.finalize() == snapshots.last)
  }

  @Test func blockquotedTablesUseTheSameMutableTailBoundary() {
    var stream = CodexStreamingMarkdown()
    stream.update(fullSource: "> Intro\n> Name | Value\n> --- | ---\n> Swift | 6\n")

    #expect(stream.stableSource == "> Intro\n")
    #expect(stream.mutableTailSource == "> Name | Value\n> --- | ---\n> Swift | 6\n")
  }

  @Test func providerRewriteResetsAndReplaysTheSourceState() {
    var stream = CodexStreamingMarkdown()
    stream.update(fullSource: "Old line\npartial")
    stream.update(fullSource: "Replacement\n")

    #expect(stream.receivedSource == "Replacement\n")
    #expect(stream.stableSource == "Replacement\n")
    #expect(stream.pendingSource.isEmpty)
  }

  @Test func everyChunkingStrategyFinalizesToTheCanonicalSource() {
    let source = "Intro\n\n```swift\nprint(\"hi\")\n```\n\nName | Value\n--- | ---\nSwift | 6\nDone"
    let boundaries = [1, 2, 5, 11, 19, 31, 47, source.count]

    var stream = CodexStreamingMarkdown()
    for boundary in boundaries {
      stream.update(fullSource: String(source.prefix(boundary)))
    }
    stream.update(fullSource: source)

    #expect(stream.receivedSource == source)
    #expect(stream.finalize() == source)
    #expect(stream.stableSource == source)
    #expect(stream.mutableTailSource.isEmpty)
  }

  @MainActor
  @Test func reducerPublishesOnlyStableSourceThenCanonicalizesTheFinalMessage() {
    let model = CodexSessionModel(snapshot: CodexSnapshot(showHeader: false))
    let reducer = CodexEventReducer(model: model)
    reducer.consume(.turnStart)

    let partialText = "Intro\nName | Value\n--- | ---\nSwift | 6"
    let partial = AssistantMessage(
      content: [.text(TextContent(text: partialText))], api: "test", provider: "test",
      model: "test")
    reducer.consume(
      .messageUpdate(
        message: partial,
        assistantMessageEvent: .textDelta(contentIndex: 0, delta: partialText, partial: partial)))

    guard case .assistant(let visible, streaming: true) = model.entries.first?.content else {
      Issue.record("Expected streaming assistant entry")
      return
    }
    #expect(visible == "Intro\nName | Value\n--- | ---\n")
    #expect(model.entries.first?.streamingMarkdown?.pendingSource == "Swift | 6")

    let finalText = partialText + "\nDone"
    let final = AssistantMessage(
      content: [.text(TextContent(text: finalText))], api: "test", provider: "test",
      model: "test")
    reducer.consume(.messageEnd(message: .assistant(final)))

    #expect(model.entries.first?.content == .assistant(finalText, streaming: false))
    #expect(model.entries.first?.streamingMarkdown == nil)
  }
}
