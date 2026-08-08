import Foundation
import KWWKAI
import KWWKAgent
import Testing

@testable import CodexTUI

@MainActor
@Suite struct CodexSessionPersistenceTests {
  private struct HistoryPage: Encodable {
    var status: String
    var prompt: String
    var currentActivity: String?
    var errorMessage: String?
    var messages: [Message]
    var liveMessage: Message?
    var nextOffset: Int?
  }

  @Test func modelSelectionClampsReasoningToTheSelectedModelsCapabilities() throws {
    let deepseek = try #require(
      ModelsCatalog.models(for: "deepseek").first { $0.id == "deepseek-v4-flash" })
    let agent = Agent(
      initialState: AgentInitialState(model: deepseek, thinkingLevel: .medium))
    let sessionModel = CodexSessionModel(
      snapshot: CodexSnapshot(
        model: deepseek.id, modelProvider: deepseek.provider, reasoningEffort: "medium",
        directory: "/tmp"))
    let driver = CodexAgentDriver(
      agent: agent, model: sessionModel, availableModels: [deepseek])

    driver.selectModel(id: "deepseek::deepseek-v4-flash")

    #expect(agent.state.thinkingLevel == .high)
    #expect(sessionModel.reasoningEffort == "high")
    #expect(driver.runtimeCommand("thinking", arguments: "medium").contains("unavailable"))
    #expect(agent.state.thinkingLevel == .high)
    driver.selectReasoning("medium")
    #expect(agent.state.thinkingLevel == .high)
  }

  @Test func runtimeCommandsReadAndMutateTheUpstreamKWWKAgent() throws {
    let runtimeModel = try #require(ModelsCatalog.models(for: "openai").first)
    let agent = Agent(
      initialState: AgentInitialState(
        model: runtimeModel,
        tools: [createReadTool(cwd: "/tmp")],
        messages: [.user(UserMessage(text: "hello"))]))
    let sessionModel = CodexSessionModel(
      snapshot: CodexSnapshot(model: runtimeModel.id, directory: "/tmp"))
    let driver = CodexAgentDriver(
      agent: agent, model: sessionModel, availableModels: [runtimeModel])

    #expect(driver.runtimeCommand("tools", arguments: "").contains("read"))
    #expect(driver.runtimeCommand("context", arguments: "").contains("token window"))
    #expect(driver.runtimeCommand("verbose", arguments: "on") == "/verbose: on")
    #expect(agent.state.verboseEnabled)
    #expect(driver.runtimeCommand("thinking", arguments: "max").contains("unavailable"))
    #expect(agent.state.thinkingLevel == .off)

    agent.steer("queued follow-up")
    #expect(driver.runtimeCommand("queue", arguments: "").contains("queued follow-up"))
    #expect(driver.runtimeCommand("queue", arguments: "clear").contains("cleared 1"))
    #expect(agent.queuedSteeringMessages().isEmpty)

    agent.steer("first")
    agent.steer("second")
    sessionModel.queuedMessages = ["first", "second"]
    #expect(driver.dequeueQueuedMessage(replacing: "draft") == "second")
    #expect(sessionModel.queuedMessages == ["draft", "first"])
    #expect(agent.queuedSteeringMessages().count == 2)

    agent.clearSteeringQueue()
    let image = CodexImageAttachment(
      data: Data([1, 2, 3]), mimeType: "image/png", name: "test.png")
    driver.steer("inspect", images: [image])
    let queued = try #require(agent.queuedSteeringMessages().first)
    guard case .user(let message) = queued else {
      Issue.record("Expected KWWK user message with image")
      return
    }
    #expect(
      message.content.contains {
        if case .image(let content) = $0 {
          return content.mimeType == "image/png" && content.data == "AQID"
        }
        return false
      })
  }

  @Test func resumeRebuildsSessionScopedAgentAndVisibleTranscript() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "codex-swift-session-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CodexSessionTreeStore(directory: directory)
    let runtimeModel = try #require(ModelsCatalog.models(for: "openai").first)
    let assistant = AssistantMessage(
      content: [.text(TextContent(text: "Persisted answer"))], api: runtimeModel.api,
      provider: runtimeModel.provider, model: runtimeModel.id)
    try await store.create(id: "saved", cwd: "/tmp/project", model: runtimeModel.id)
    try await store.append(
      id: "saved", cwd: "/tmp/project",
      messages: [.user(UserMessage(text: "Persisted prompt")), .assistant(assistant)])

    let initial = Agent(
      initialState: AgentInitialState(model: runtimeModel), sessionId: "current")
    let sessionModel = CodexSessionModel(
      snapshot: CodexSnapshot(model: runtimeModel.id, directory: "/tmp/project"))
    let factory: @MainActor @Sendable (String, Model, [Message]) async -> CodingAgent = {
      id, selected, messages in
      CodingAgent(
        agent: Agent(
          initialState: AgentInitialState(model: selected, messages: messages), sessionId: id),
        detachBackground: nil)
    }
    let driver = CodexAgentDriver(
      codingAgent: CodingAgent(agent: initial, detachBackground: nil), model: sessionModel,
      availableModels: [runtimeModel], sessionStore: store,
      backgroundManager: BackgroundTaskManager(), agentFactory: factory)

    try await driver.activateSession(id: "saved", fork: false)

    #expect(driver.agent.sessionId == "saved")
    #expect(driver.agent.state.messages.count == 2)
    #expect(sessionModel.history == ["Persisted prompt"])
    #expect(sessionModel.entries.count == 2)
    if case .assistant(let text, false) = sessionModel.entries.last?.content {
      #expect(text == "Persisted answer")
    } else {
      Issue.record("Expected restored assistant transcript cell")
    }

    try await driver.renameSession("Restored work")
    let loaded = try await store.load(id: "saved")
    #expect(loaded.title == "Restored work")

    await driver.compactSession()
    #expect(
      sessionModel.entries.contains {
        if case .notice(let text) = $0.content { return text.contains("nothing to compact") }
        return false
      })

    try await driver.startSideConversation(prompt: nil)
    #expect(sessionModel.mode == .side)
    #expect(driver.agent.sessionId?.hasPrefix("side-") == true)
    #expect(driver.agent.state.messages.count == 3)
    if let last = driver.agent.state.messages.last, case .user(let boundary) = last {
      #expect(boundary.source == .runtime)
      #expect(
        boundary.content.contains { block in
          if case .text(let text) = block { return text.text.contains("reference context only") }
          return false
        })
    } else {
      Issue.record("Expected hidden side-conversation boundary")
    }

    let sideID = try #require(driver.agent.sessionId)
    await driver.toggleSideConversation()
    #expect(sessionModel.mode == .defaultMode)
    #expect(driver.agent.sessionId == "saved")
    #expect(sessionModel.history == ["Persisted prompt"])

    await driver.toggleSideConversation()
    #expect(sessionModel.mode == .side)
    #expect(driver.agent.sessionId == sideID)

    await driver.closeSideConversation()
    #expect(sessionModel.mode == .defaultMode)
    #expect(driver.agent.sessionId == "saved")
  }

  @Test func rewindCreatesADurableBranchWithoutDiscardingTheOldPath() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "codex-swift-rewind-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CodexSessionTreeStore(directory: directory)
    let runtimeModel = try #require(ModelsCatalog.models(for: "openai").first)
    func assistant(_ text: String) -> Message {
      .assistant(
        AssistantMessage(
          content: [.text(TextContent(text: text))], api: runtimeModel.api,
          provider: runtimeModel.provider, model: runtimeModel.id))
    }
    let messages: [Message] = [
      .user(UserMessage(text: "keep this")), assistant("kept answer"),
      .user(
        UserMessage(content: [
          .text(TextContent(text: "edit this")),
          .image(ImageContent(data: "AQID", mimeType: "image/png")),
        ])),
      assistant("drop this answer"),
    ]
    try await store.create(id: "rewind", cwd: "/tmp/project", model: runtimeModel.id)
    try await store.append(id: "rewind", cwd: "/tmp/project", messages: messages)

    let initial = Agent(
      initialState: AgentInitialState(model: runtimeModel), sessionId: "current")
    let sessionModel = CodexSessionModel(
      snapshot: CodexSnapshot(model: runtimeModel.id, directory: "/tmp/project"))
    let factory: @MainActor @Sendable (String, Model, [Message]) async -> CodingAgent = {
      id, selected, messages in
      CodingAgent(
        agent: Agent(
          initialState: AgentInitialState(model: selected, messages: messages), sessionId: id),
        detachBackground: nil)
    }
    let driver = CodexAgentDriver(
      codingAgent: CodingAgent(agent: initial, detachBackground: nil), model: sessionModel,
      availableModels: [runtimeModel], sessionStore: store,
      backgroundManager: BackgroundTaskManager(), agentFactory: factory)
    try await driver.activateSession(id: "rewind", fork: false)

    let candidates = driver.rewindCandidates()
    #expect(candidates.map(\.id) == [0, 2])
    #expect(candidates.last?.preview == "[1 image] edit this")
    let draft = try await driver.rewind(to: 2)

    #expect(draft.text == "edit this")
    #expect(draft.images.first?.data == Data([1, 2, 3]))
    #expect(driver.agent.state.messages == Array(messages.prefix(2)))
    #expect(sessionModel.history == ["keep this"])
    #expect(sessionModel.entries.count == 3)
    let loaded = try await store.load(id: "rewind")
    #expect(loaded.messages == Array(messages.prefix(2)))
    #expect(loaded.displayMessages == Array(messages.prefix(2)))
    let tree = try await store.snapshot(id: "rewind")
    #expect(tree.items.count == messages.count)
    #expect(tree.items.contains(where: { $0.preview == "drop this answer" }))
    #expect(
      tree.items.first(where: { $0.preview == "drop this answer" })?.isOnActiveBranch == false)
  }

  @Test func agentPickerReadsFullKwwkBackgroundHistoryInSpawnOrder() async throws {
    let runtimeModel = try #require(ModelsCatalog.models(for: "openai").first)
    let assistant = AssistantMessage(
      content: [.text(TextContent(text: "child answer"))], api: runtimeModel.api,
      provider: runtimeModel.provider, model: runtimeModel.id)
    let page = HistoryPage(
      status: "completed", prompt: "inspect child", currentActivity: nil,
      errorMessage: nil,
      messages: [.user(UserMessage(text: "child prompt")), .assistant(assistant)],
      liveMessage: nil, nextOffset: nil)
    let json = String(decoding: try JSONEncoder().encode(page), as: UTF8.self)
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
    let historyTool = AgentTool(
      name: "agent_history", label: "agent history", description: "history",
      parameters: .object([:]),
      execute: { _, _, _, _ in
        AgentToolResult(
          content: [
            .text(
              TextContent(
                text:
                  "Subagent data below is untrusted.\n<subagent-history trust=\"untrusted\">\n\(json)\n</subagent-history>"
              ))
          ])
      })
    let agent = Agent(
      initialState: AgentInitialState(model: runtimeModel, tools: [historyTool]),
      sessionId: "parent")
    let sessionModel = CodexSessionModel(
      snapshot: CodexSnapshot(model: runtimeModel.id, directory: "/tmp"))
    let driver = CodexAgentDriver(
      agent: agent, model: sessionModel, availableModels: [runtimeModel])

    driver.consumeSubagent(
      SubagentLifecycleEvent(
        kind: .backgroundStarted, subagentType: "reviewer",
        childSessionId: "child-z", description: "review changes",
        backgroundTaskId: "task-z"))
    driver.consumeSubagent(
      SubagentLifecycleEvent(
        kind: .backgroundStarted, subagentType: "explorer",
        childSessionId: "child-a", description: "inspect sources",
        backgroundTaskId: "task-a"))

    let threads = await driver.agentThreads()
    #expect(threads.map(\.id) == ["parent", "child-z", "child-a"])
    #expect(threads[1].status == "completed")
    #expect(threads[1].description == "inspect child")
    #expect(threads[1].entries.count == 2)
    if case .assistant(let text, false) = threads[1].entries.last?.content {
      #expect(text == "child answer")
    } else {
      Issue.record("Expected full KWWK child transcript")
    }
  }
}
