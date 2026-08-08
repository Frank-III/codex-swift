import Foundation
import KWWKAI
import KWWKAgent

/// Records one active KWWK agent projection into Codex's durable session tree.
/// The KWWK agent remains unaware of branches; every append is checked against
/// the store's active model projection before new messages are committed.
public final class CodexSessionTreeRecorder: @unchecked Sendable {
  private let store: CodexSessionTreeStore
  private let sessionID: String
  private let cwd: String
  private let model: String?
  private let provider: String?
  private let lock = NSLock()
  private var chain: Task<Void, Never>?
  private var _lastPersistenceError: String?
  private let onPersistenceError: (@Sendable (String) -> Void)?

  public var lastPersistenceError: String? {
    lock.withLock { _lastPersistenceError }
  }

  public init(
    store: CodexSessionTreeStore, sessionID: String, cwd: String,
    model: String? = nil, provider: String? = nil,
    onPersistenceError: (@Sendable (String) -> Void)? = nil
  ) {
    self.store = store
    self.sessionID = sessionID
    self.cwd = cwd
    self.model = model
    self.provider = provider
    self.onPersistenceError = onPersistenceError
  }

  public func ensureCreated() async {
    do {
      try await store.createIfMissing(
        id: sessionID, cwd: cwd, model: model, provider: provider)
      setError(nil)
    } catch {
      setError(error.localizedDescription)
    }
  }

  @discardableResult
  public func attach(to agent: Agent) -> Unsubscribe {
    agent.subscribe { [weak self, weak agent] event, _ in
      guard let self, let agent else { return }
      switch event {
      case .messageEnd, .turnEnd, .agentEnd, .compactStart:
        await self.flush(messages: agent.state.messages)
      case .compactEnd(let outcome):
        if case .compacted(let count, _) = outcome {
          await self.recordCompaction(
            messages: agent.state.messages, messagesCompacted: count)
        }
      default:
        break
      }
    }
  }

  public func flush(messages: [Message]) async {
    await enqueue { [store, sessionID, cwd, model, provider] in
      _ = try await store.appendMessages(
        id: sessionID, cwd: cwd, messages: messages.map(redactedForPersistence),
        model: model, provider: provider)
    }
  }

  public func recordCompaction(messages: [Message], messagesCompacted: Int) async {
    await enqueue { [store, sessionID, cwd, model, provider] in
      _ = try await store.recordCompaction(
        id: sessionID, cwd: cwd,
        replacementMessages: messages.map(redactedForPersistence),
        messagesCompacted: messagesCompacted, model: model, provider: provider)
    }
  }

  public func recordTitle(_ title: String) async {
    await enqueue { [store, sessionID, cwd, model, provider] in
      try await store.createIfMissing(
        id: sessionID, cwd: cwd, model: model, provider: provider)
      try await store.recordTitle(id: sessionID, title: title)
    }
  }

  public func waitForPendingWrites() async {
    let pending = lock.withLock { chain }
    await pending?.value
  }

  private func enqueue(
    _ operation: @escaping @Sendable () async throws -> Void
  ) async {
    let task: Task<Void, Never> = lock.withLock {
      let previous = chain
      let next = Task { [weak self] in
        await previous?.value
        do {
          var attempt = 0
          while true {
            do {
              try await operation()
              self?.setError(nil)
              return
            } catch  where attempt < 2 {
              attempt += 1
              try? await Task.sleep(for: .milliseconds(100 * attempt))
            }
          }
        } catch {
          let message = error.localizedDescription
          self?.setError(message)
          self?.onPersistenceError?(message)
        }
      }
      chain = next
      return next
    }
    await task.value
  }

  private func setError(_ error: String?) {
    lock.withLock { _lastPersistenceError = error }
  }
}
