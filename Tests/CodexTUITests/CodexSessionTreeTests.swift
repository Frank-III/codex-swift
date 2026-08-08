import Foundation
import KWWKAI
import KWWKAgent
import Testing

@testable import CodexTUI

@Suite struct CodexSessionTreeTests {
  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "codex-session-tree-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func assistant(_ text: String, model: Model) -> Message {
    .assistant(
      AssistantMessage(
        content: [.text(TextContent(text: text))], api: model.api,
        provider: model.provider, model: model.id))
  }

  @Test func checkoutSurvivesRestartBeforeAnotherMessageIsAppended() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = try #require(ModelsCatalog.models(for: "openai").first)
    let store = CodexSessionTreeStore(directory: directory)
    let messages: [Message] = [
      .user(UserMessage(text: "first")), assistant("first answer", model: model),
      .user(UserMessage(text: "second")), assistant("second answer", model: model),
    ]
    try await store.create(id: "session", cwd: "/tmp", model: model.id, provider: model.provider)
    try await store.append(id: "session", cwd: "/tmp", messages: messages)
    let initial = try await store.snapshot(id: "session")
    let firstUser = try #require(initial.items.first(where: { $0.kind == .user }))

    let checkedOut = try await store.checkout(id: "session", targetID: firstUser.id)
    #expect(checkedOut.messages.isEmpty)
    #expect(checkedOut.selectedEditableEntryID == firstUser.id)

    let reopenedStore = CodexSessionTreeStore(directory: directory)
    let reopened = try await reopenedStore.load(id: "session")
    #expect(reopened.messages.isEmpty)
    #expect(reopened.selectedEditableEntryID == firstUser.id)
    let reopenedTree = try await reopenedStore.snapshot(id: "session")
    #expect(reopenedTree.items.count == 4)
    #expect(reopenedTree.activeLeafID == nil)
  }

  @Test func branchingPreservesBothPathsAndProjectsOnlyTheActiveOne() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = try #require(ModelsCatalog.models(for: "openai").first)
    let store = CodexSessionTreeStore(directory: directory)
    let original: [Message] = [
      .user(UserMessage(text: "root")), assistant("answer", model: model),
      .user(UserMessage(text: "approach A")), assistant("A result", model: model),
    ]
    try await store.create(id: "session", cwd: "/tmp")
    try await store.append(id: "session", cwd: "/tmp", messages: original)
    let originalTree = try await store.snapshot(id: "session")
    let approachA = try #require(
      originalTree.items.first(where: { $0.kind == .user && $0.preview == "approach A" }))

    let branched = try await store.checkout(id: "session", targetID: approachA.id)
    #expect(branched.messages.count == 2)
    let approachB: [Message] =
      branched.messages + [
        .user(UserMessage(text: "approach B")), assistant("B result", model: model),
      ]
    try await store.append(id: "session", cwd: "/tmp", messages: approachB)

    let loaded = try await store.load(id: "session")
    #expect(loaded.messages == approachB)
    let tree = try await store.snapshot(id: "session")
    #expect(tree.items.count == 6)
    let rootAnswer = try #require(tree.items.first(where: { $0.preview == "answer" }))
    let children = tree.items.filter { $0.parentID == rootAnswer.id }
    #expect(Set(children.map(\.preview)) == ["approach A", "approach B"])
    #expect(tree.items.first(where: { $0.preview == "A result" })?.isOnActiveBranch == false)
    #expect(tree.items.first(where: { $0.preview == "B result" })?.isOnActiveBranch == true)
  }

  @Test func repeatedBacktrackingPreservesEveryPathAndRestoresTheLastCheckout() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = try #require(ModelsCatalog.models(for: "openai").first)
    let store = CodexSessionTreeStore(directory: directory)
    let original: [Message] = [
      .user(UserMessage(text: "root")), assistant("root answer", model: model),
      .user(UserMessage(text: "first path")), assistant("first answer", model: model),
      .user(UserMessage(text: "deep path")), assistant("deep answer", model: model),
    ]
    try await store.create(id: "session", cwd: "/tmp")
    try await store.append(id: "session", cwd: "/tmp", messages: original)

    var tree = try await store.snapshot(id: "session")
    let deepPrompt = try #require(tree.items.first(where: { $0.preview == "deep path" }))
    let firstCheckout = try await store.checkout(id: "session", targetID: deepPrompt.id)
    let revisedDeep =
      firstCheckout.messages + [
        Message.user(UserMessage(text: "revised deep path")),
        assistant("revised deep answer", model: model),
      ]
    try await store.append(id: "session", cwd: "/tmp", messages: revisedDeep)

    tree = try await store.snapshot(id: "session")
    let firstPath = try #require(tree.items.first(where: { $0.preview == "first path" }))
    let secondCheckout = try await store.checkout(id: "session", targetID: firstPath.id)
    let alternateFirst =
      secondCheckout.messages + [
        Message.user(UserMessage(text: "alternate first path")),
        assistant("alternate first answer", model: model),
      ]
    try await store.append(id: "session", cwd: "/tmp", messages: alternateFirst)

    let reopened = CodexSessionTreeStore(directory: directory)
    let loaded = try await reopened.load(id: "session")
    #expect(loaded.messages == alternateFirst)
    let finalTree = try await reopened.snapshot(id: "session")
    #expect(finalTree.items.count == 10)
    #expect(
      finalTree.items.first(where: { $0.preview == "deep answer" })?.isOnActiveBranch == false)
    #expect(
      finalTree.items.first(where: { $0.preview == "revised deep answer" })?.isOnActiveBranch
        == false)
    #expect(
      finalTree.items.first(where: { $0.preview == "alternate first answer" })?.isOnActiveBranch
        == true)

    let rootAnswer = try #require(finalTree.items.first(where: { $0.preview == "root answer" }))
    #expect(
      Set(finalTree.items.filter { $0.parentID == rootAnswer.id }.map(\.preview))
        == ["first path", "alternate first path"])
    let firstAnswer = try #require(finalTree.items.first(where: { $0.preview == "first answer" }))
    #expect(
      Set(finalTree.items.filter { $0.parentID == firstAnswer.id }.map(\.preview))
        == ["deep path", "revised deep path"])
  }

  @Test func modelIndexDisambiguatesRepeatedPrompts() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = try #require(ModelsCatalog.models(for: "openai").first)
    let store = CodexSessionTreeStore(directory: directory)
    let repeated = Message.user(UserMessage(text: "continue"))
    let messages = [
      repeated, assistant("one", model: model), repeated, assistant("two", model: model),
    ]
    try await store.create(id: "session", cwd: "/tmp")
    try await store.append(id: "session", cwd: "/tmp", messages: messages)

    let loaded = try await store.checkoutModelMessage(id: "session", index: 0, expected: repeated)
    #expect(loaded.messages.isEmpty)
    let tree = try await store.snapshot(id: "session")
    #expect(tree.selectedEditableEntryID == tree.items.first(where: { $0.kind == .user })?.id)
  }

  @Test func compactionChangesOnlyItsDescendantModelProjection() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = try #require(ModelsCatalog.models(for: "openai").first)
    let store = CodexSessionTreeStore(directory: directory)
    let original: [Message] = [
      .user(UserMessage(text: "old prompt")), assistant("old answer", model: model),
      .user(UserMessage(text: "recent prompt")), assistant("recent answer", model: model),
    ]
    try await store.create(id: "session", cwd: "/tmp")
    try await store.append(id: "session", cwd: "/tmp", messages: original)
    let beforeCompaction = try await store.snapshot(id: "session")
    let oldPrompt = try #require(
      beforeCompaction.items.first(where: { $0.preview == "old prompt" }))
    let compacted: [Message] = [
      .user(UserMessage(text: "summary", source: .runtime)), original[2], original[3],
    ]
    _ = try await store.recordCompaction(
      id: "session", cwd: "/tmp", replacementMessages: compacted, messagesCompacted: 2)
    #expect(try await store.load(id: "session").messages == compacted)

    _ = try await store.checkout(id: "session", targetID: oldPrompt.id)
    let sibling = try await store.load(id: "session")
    #expect(sibling.messages.isEmpty)
    #expect(sibling.displayMessages.isEmpty)
    let tree = try await store.snapshot(id: "session")
    #expect(tree.items.contains(where: { $0.kind == .compaction }))
    #expect(tree.items.count == 5)
  }

  @Test func truncatedTrailingRecordIsRemovedBeforeTheNextAppend() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CodexSessionTreeStore(directory: directory)
    try await store.create(id: "session", cwd: "/tmp")
    let first = Message.user(UserMessage(text: "first"))
    try await store.append(id: "session", cwd: "/tmp", messages: [first])
    let file = directory.appendingPathComponent("session.jsonl")
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"entry\":".utf8))
    try handle.close()

    let reopened = CodexSessionTreeStore(directory: directory)
    #expect(try await reopened.load(id: "session").messages.count == 1)
    try await reopened.append(
      id: "session", cwd: "/tmp",
      messages: [first, .user(UserMessage(text: "second"))])

    let final = try await CodexSessionTreeStore(directory: directory).load(id: "session")
    #expect(final.messages.count == 2)
  }

  @Test func newSessionFilesAndDirectoriesArePrivate() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "codex-private-session-tree-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CodexSessionTreeStore(directory: directory)
    try await store.create(id: "session", cwd: "/tmp")
    let directoryMode = try #require(
      FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)
    let fileMode = try #require(
      FileManager.default.attributesOfItem(
        atPath: directory.appendingPathComponent("session.jsonl").path)[.posixPermissions]
        as? NSNumber)
    #expect(directoryMode.intValue & 0o777 == 0o700)
    #expect(fileMode.intValue & 0o777 == 0o600)
  }

  @Test func legacyKwwkSessionImportsLazilyAndKeepsABackupOnFirstTreeWrite() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = try #require(ModelsCatalog.models(for: "openai").first)
    let legacy = SessionStore(directory: directory)
    let messages: [Message] = [
      .user(UserMessage(text: "legacy")), assistant("answer", model: model),
    ]
    try await legacy.create(id: "legacy", cwd: "/tmp", model: model.id, provider: model.provider)
    try await legacy.append(id: "legacy", cwd: "/tmp", messages: messages)
    let legacyFile = directory.appendingPathComponent("legacy.jsonl")
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: legacyFile.path)

    let store = CodexSessionTreeStore(directory: directory)
    let imported = try await store.load(id: "legacy")
    #expect(imported.isLegacy)
    #expect(imported.messages == messages)
    let tree = try await store.snapshot(id: "legacy")
    let user = try #require(tree.items.first(where: { $0.kind == .user }))
    _ = try await store.checkout(id: "legacy", targetID: user.id)

    let migrated = try await store.load(id: "legacy")
    #expect(!migrated.isLegacy)
    let backup = directory.appendingPathComponent("legacy/legacy.jsonl")
    #expect(FileManager.default.fileExists(atPath: backup.path))
    let migratedFile = directory.appendingPathComponent("legacy.jsonl")
    let firstLine = try String(contentsOf: migratedFile).split(separator: "\n").first
    #expect(firstLine?.contains("\"format\":\"codex-tree\"") == true)
    let migratedMode = try #require(
      FileManager.default.attributesOfItem(atPath: migratedFile.path)[.posixPermissions]
        as? NSNumber)
    #expect(migratedMode.intValue & 0o777 == 0o600)
  }
}
