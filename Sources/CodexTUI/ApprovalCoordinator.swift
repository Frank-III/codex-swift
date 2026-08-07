import Foundation
import KWWKAI
import KWWKAgent

@MainActor
public final class ApprovalCoordinator {
  private struct PendingApproval {
    var request: ApprovalRequest
    var signature: String
    var subject: ApprovalSubject
    var continuation: CheckedContinuation<BeforeToolCallResult?, Never>
    var cancellationRegistration: CancellationRegistration?
    var isActive: @MainActor () -> Bool
  }

  private struct Candidate {
    var request: ApprovalRequest
    var signature: String
    var subject: ApprovalSubject
  }

  private let model: CodexSessionModel
  private var pending: [PendingApproval] = []
  private var sessionApprovals: Set<String> = []
  public var permissionMode: CodexPermissionMode

  public init(model: CodexSessionModel) {
    self.model = model
    permissionMode = model.permissionMode
  }

  public func request(
    _ context: BeforeToolCallContext,
    cancellation: CancellationHandle?,
    isActive: @escaping @MainActor () -> Bool = { true }
  ) async -> BeforeToolCallResult? {
    await request(
      toolCallID: context.toolCall.id,
      name: context.toolCall.name,
      arguments: context.args,
      cancellation: cancellation, isActive: isActive)
  }

  func request(
    toolCallID: String,
    name: String,
    arguments: JSONValue,
    cancellation: CancellationHandle? = nil,
    isActive: @escaping @MainActor () -> Bool = { true }
  ) async -> BeforeToolCallResult? {
    guard permissionMode != .fullAccess else { return nil }
    guard
      let candidate = candidate(
        toolCallID: toolCallID, name: name, arguments: arguments)
    else { return nil }
    guard !sessionApprovals.contains(candidate.signature) else { return nil }
    if cancellation?.isCancelled == true {
      return BeforeToolCallResult(
        block: true, reason: cancellation?.reason ?? "Tool execution was cancelled")
    }

    return await withCheckedContinuation { continuation in
      pending.append(
        PendingApproval(
          request: candidate.request,
          signature: candidate.signature,
          subject: candidate.subject,
          continuation: continuation,
          isActive: isActive))
      let requestID = candidate.request.id
      if let cancellation {
        let registration = cancellation.onCancel { [weak self] reason in
          Task { @MainActor [weak self] in
            self?.cancel(requestID: requestID, reason: reason)
          }
        }
        if let index = pending.firstIndex(where: { $0.request.id == requestID }) {
          pending[index].cancellationRegistration = registration
        } else {
          registration.cancel()
        }
      }
      presentNextIfNeeded()
    }
  }

  @discardableResult
  public func resolve(requestID: String, decision: ApprovalDecision) -> Bool {
    guard let index = pending.firstIndex(where: { $0.request.id == requestID }) else {
      return false
    }
    let approval = pending.remove(at: index)
    approval.cancellationRegistration?.cancel()
    if decision == .approveForSession {
      sessionApprovals.insert(approval.signature)
    }

    if case .approval(let visible) = model.overlay, visible.id == requestID {
      model.overlay = nil
    }
    if case .command = approval.subject {
      model.entries.append(
        TranscriptEntry(
          content: .approvalDecision(
            ApprovalDecisionRecord(subject: approval.subject, decision: decision))))
    }

    let result: BeforeToolCallResult? =
      switch decision {
      case .approveOnce, .approveForSession:
        nil
      case .decline:
        BeforeToolCallResult(block: true, reason: "User did not approve this tool call")
      case .cancel:
        BeforeToolCallResult(
          block: true, reason: "User canceled the request and wants a different approach")
      }
    approval.continuation.resume(returning: result)
    presentNextIfNeeded()
    return true
  }

  public func cancelAll(reason: String = "Tool execution was interrupted") {
    let approvals = pending
    pending.removeAll()
    model.overlay = nil
    for approval in approvals {
      approval.cancellationRegistration?.cancel()
      approval.continuation.resume(
        returning: BeforeToolCallResult(block: true, reason: reason))
    }
  }

  public func refreshPresentation() {
    if case .approval = model.overlay { model.overlay = nil }
    presentNextIfNeeded()
  }

  private func cancel(requestID: String, reason: String?) {
    guard let index = pending.firstIndex(where: { $0.request.id == requestID }) else { return }
    let approval = pending.remove(at: index)
    approval.cancellationRegistration?.cancel()
    if case .approval(let visible) = model.overlay, visible.id == requestID {
      model.overlay = nil
    }
    approval.continuation.resume(
      returning: BeforeToolCallResult(
        block: true, reason: reason ?? "Tool execution was cancelled"))
    presentNextIfNeeded()
  }

  private func presentNextIfNeeded() {
    guard model.overlay == nil, let next = pending.first(where: { $0.isActive() }) else { return }
    model.overlay = .approval(next.request)
  }

  private func candidate(
    toolCallID: String,
    name: String,
    arguments: JSONValue
  ) -> Candidate? {
    let normalizedName = name.lowercased()
    let object: [String: JSONValue]
    if case .object(let value) = arguments { object = value } else { object = [:] }

    switch normalizedName {
    case "bash", "shell", "exec_command":
      let command = string(in: object, keys: ["command", "cmd"]) ?? ""
      guard !command.isEmpty else { return nil }
      return Candidate(
        request: ApprovalRequest(
          id: toolCallID,
          title: "Would you like to run the following command?",
          command: command,
          choices: [
            ApprovalChoice("Yes, proceed", shortcut: "y", decision: .approveOnce),
            ApprovalChoice(
              "Yes, and don't ask again for this command in this session",
              shortcut: "a", decision: .approveForSession),
            ApprovalChoice(
              "No, continue without running it", shortcut: "d", decision: .decline),
            ApprovalChoice(
              "No, and tell Codex what to do differently",
              shortcut: "esc", decision: .cancel),
          ]),
        signature: "command:\(command)",
        subject: .command(command))

    case "edit", "write", "write_file", "apply_patch":
      let path = string(in: object, keys: ["path"]) ?? "files"
      return Candidate(
        request: ApprovalRequest(
          id: toolCallID,
          title: "Would you like to make the following edits?",
          choices: [
            ApprovalChoice("Yes, proceed", shortcut: "y", decision: .approveOnce),
            ApprovalChoice(
              "Yes, and don't ask again for these files",
              shortcut: "a", decision: .approveForSession),
            ApprovalChoice(
              "No, and tell Codex what to do differently",
              shortcut: "esc", decision: .cancel),
          ]),
        signature: "file:\(path)",
        subject: .fileChange(path))

    default:
      return nil
    }
  }

  private func string(in object: [String: JSONValue], keys: [String]) -> String? {
    for key in keys {
      if case .string(let value)? = object[key] { return value }
    }
    return nil
  }
}
