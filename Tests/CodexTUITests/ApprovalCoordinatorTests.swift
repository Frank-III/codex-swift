import KWWKAI
import Testing

@testable import CodexTUI

@MainActor
@Suite struct ApprovalCoordinatorTests {
  @Test func inactiveThreadApprovalWaitsUntilThatThreadIsVisible() async {
    let model = CodexSessionModel(snapshot: CodexSnapshot())
    let coordinator = ApprovalCoordinator(model: model)
    var isActive = false
    let task = Task {
      await coordinator.request(
        toolCallID: "inactive-command", name: "bash",
        arguments: .object(["command": .string("git status")]),
        isActive: { isActive })
    }
    await Task.yield()

    #expect(model.overlay == nil)
    isActive = true
    coordinator.refreshPresentation()
    guard case .approval(let request) = model.overlay else {
      Issue.record("Expected the inactive approval after switching threads")
      return
    }
    #expect(request.id == "inactive-command")
    #expect(coordinator.resolve(requestID: request.id, decision: .decline))
    _ = await task.value
  }

  @Test func declineBlocksThePendingToolAndRecordsTheDecision() async {
    let model = CodexSessionModel()
    let coordinator = ApprovalCoordinator(model: model)
    let result = Task {
      await coordinator.request(
        toolCallID: "call-1",
        name: "bash",
        arguments: ["command": "git push origin main"])
    }
    await Task.yield()

    guard case .approval(let request) = model.overlay else {
      Issue.record("Expected a pending approval")
      return
    }
    #expect(request.title == "Would you like to run the following command?")
    #expect(request.command == "git push origin main")
    #expect(coordinator.resolve(requestID: request.id, decision: .decline))

    #expect(await result.value?.block == true)
    #expect(
      model.entries.last?.content
        == .approvalDecision(
          ApprovalDecisionRecord(
            subject: .command("git push origin main"), decision: .decline)))
    #expect(model.overlay == nil)
  }

  @Test func sessionApprovalSuppressesTheSameLaterPrompt() async {
    let model = CodexSessionModel()
    let coordinator = ApprovalCoordinator(model: model)
    let first = Task {
      await coordinator.request(
        toolCallID: "call-1",
        name: "bash",
        arguments: ["command": "mise run test"])
    }
    await Task.yield()

    guard case .approval(let request) = model.overlay else {
      Issue.record("Expected a pending approval")
      return
    }
    #expect(coordinator.resolve(requestID: request.id, decision: .approveForSession))
    #expect(await first.value == nil)

    let repeated = await coordinator.request(
      toolCallID: "call-2",
      name: "bash",
      arguments: ["command": "mise run test"])
    #expect(repeated == nil)
    #expect(model.overlay == nil)
  }

  @Test func readOnlyToolsDoNotPrompt() async {
    let model = CodexSessionModel()
    let coordinator = ApprovalCoordinator(model: model)

    let result = await coordinator.request(
      toolCallID: "call-1",
      name: "read",
      arguments: ["path": "README.md"])

    #expect(result == nil)
    #expect(model.overlay == nil)
  }

  @Test func fullAccessBypassesTheExecutionGate() async {
    let model = CodexSessionModel(snapshot: CodexSnapshot(permissionMode: .fullAccess))
    let coordinator = ApprovalCoordinator(model: model)

    let result = await coordinator.request(
      toolCallID: "call-1",
      name: "bash",
      arguments: ["command": "curl https://example.com"])

    #expect(result == nil)
    #expect(model.overlay == nil)
  }
}
