import Darwin
import Foundation
import KWWKAI
import KWWKAgent

public struct CodexSessionEntryID: RawRepresentable, Codable, Hashable, Sendable,
  CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) { self.rawValue = rawValue }
  public init() { rawValue = UUID().uuidString.lowercased() }
  public var description: String { rawValue }
}

public struct CodexSessionTreeEntry: Codable, Hashable, Sendable, Identifiable {
  public enum Content: Codable, Hashable, Sendable {
    case message(Message)
    case modelChange(model: String, provider: String?)
    case thinkingLevelChange(String)
    case compaction(replacementMessages: [Message], messagesCompacted: Int)
    case branchSummary(fromID: CodexSessionEntryID?, summary: String)
    case custom(extensionID: String, customType: String, data: JSONValue?)
    case customMessage(
      extensionID: String, customType: String, message: Message, display: Bool,
      details: JSONValue?)
  }

  public let id: CodexSessionEntryID
  public let parentID: CodexSessionEntryID?
  public let timestamp: Int64
  public let content: Content

  public init(
    id: CodexSessionEntryID = CodexSessionEntryID(), parentID: CodexSessionEntryID?,
    timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1_000), content: Content
  ) {
    self.id = id
    self.parentID = parentID
    self.timestamp = timestamp
    self.content = content
  }
}

public struct CodexSessionTreeItem: Identifiable, Hashable, Sendable {
  public enum Kind: String, Hashable, Sendable {
    case user
    case assistant
    case toolResult = "tool_result"
    case runtime
    case modelChange = "model_change"
    case thinkingLevelChange = "thinking_level_change"
    case compaction
    case branchSummary = "branch_summary"
    case custom
    case customMessage = "custom_message"
  }

  public let id: CodexSessionEntryID
  public let parentID: CodexSessionEntryID?
  public let timestamp: Int64
  public let depth: Int
  public let kind: Kind
  public let preview: String
  public let isOnActiveBranch: Bool
  public let hasChildren: Bool
  public let label: String?

  public init(
    id: CodexSessionEntryID, parentID: CodexSessionEntryID?, timestamp: Int64, depth: Int,
    kind: Kind, preview: String, isOnActiveBranch: Bool, hasChildren: Bool, label: String?
  ) {
    self.id = id
    self.parentID = parentID
    self.timestamp = timestamp
    self.depth = depth
    self.kind = kind
    self.preview = preview
    self.isOnActiveBranch = isOnActiveBranch
    self.hasChildren = hasChildren
    self.label = label
  }
}

public struct CodexSessionTreeSnapshot: Hashable, Sendable {
  public let sessionID: String
  public let items: [CodexSessionTreeItem]
  public let activeLeafID: CodexSessionEntryID?
  public let selectedEditableEntryID: CodexSessionEntryID?

  public init(
    sessionID: String, items: [CodexSessionTreeItem], activeLeafID: CodexSessionEntryID?,
    selectedEditableEntryID: CodexSessionEntryID?
  ) {
    self.sessionID = sessionID
    self.items = items
    self.activeLeafID = activeLeafID
    self.selectedEditableEntryID = selectedEditableEntryID
  }
}

public struct CodexSessionTreeLoadedSession: Sendable, Hashable {
  public struct Header: Codable, Sendable, Hashable {
    public let type: String
    public let format: String
    public let version: Int
    public let id: String
    public let cwd: String
    public let createdAt: Int64
    public let model: String?
    public let provider: String?
    public let parentSession: String?

    public init(
      id: String, cwd: String, createdAt: Int64, model: String?, provider: String?,
      parentSession: String? = nil
    ) {
      type = "session"
      format = "codex-tree"
      version = CodexSessionTreeStore.version
      self.id = id
      self.cwd = cwd
      self.createdAt = createdAt
      self.model = model
      self.provider = provider
      self.parentSession = parentSession
    }
  }

  public let header: Header
  public let messages: [Message]
  public let displayMessages: [Message]
  public let activeLeafID: CodexSessionEntryID?
  public let selectedEditableEntryID: CodexSessionEntryID?
  public let model: String?
  public let provider: String?
  public let thinkingLevel: String?
  public let title: String?
  public let isLegacy: Bool

  public var persistedContextCount: Int { messages.count }
}

public struct CodexSessionTreeInfo: Sendable, Hashable {
  public let id: String
  public let cwd: String
  public let createdAt: Int64
  public let updatedAt: Int64
  public let messageCount: Int
  public let title: String?
  public let firstUserText: String?
  public let path: URL
}

public enum CodexSessionTreeError: LocalizedError, Equatable {
  case invalidSessionID(String)
  case sessionNotFound(String)
  case invalidHeader(String)
  case unsupportedVersion(Int)
  case missingEntry(CodexSessionEntryID)
  case invalidBranchPoint(CodexSessionEntryID)
  case projectionMismatch
  case corruptLine(path: String, line: Int)

  public var errorDescription: String? {
    switch self {
    case .invalidSessionID(let id): "Invalid session id: \(id)"
    case .sessionNotFound(let id): "Session not found: \(id)"
    case .invalidHeader(let path): "Invalid session header: \(path)"
    case .unsupportedVersion(let version): "Unsupported Codex session-tree version: \(version)"
    case .missingEntry(let id): "Session tree entry not found: \(id)"
    case .invalidBranchPoint(let id): "Entry \(id) is not a complete conversation boundary."
    case .projectionMismatch: "The live agent context no longer matches the active session branch."
    case .corruptLine(let path, let line): "Corrupt session entry at \(path):\(line)"
    }
  }
}

public actor CodexSessionTreeStore {
  public static let version = 1
  public let directory: URL

  private struct Checkout: Codable, Hashable, Sendable {
    var targetID: CodexSessionEntryID?
    var leafID: CodexSessionEntryID?
    var selectedEditableEntryID: CodexSessionEntryID?
    var timestamp: Int64
  }

  private struct TitleChange: Codable, Hashable, Sendable {
    var title: String?
    var timestamp: Int64
  }

  private struct LabelChange: Codable, Hashable, Sendable {
    var targetID: CodexSessionEntryID
    var label: String?
    var timestamp: Int64
  }

  private enum Record: Codable, Hashable, Sendable {
    case entry(CodexSessionTreeEntry)
    case checkout(Checkout)
    case title(TitleChange)
    case label(LabelChange)
  }

  private struct Document: Sendable {
    var header: CodexSessionTreeLoadedSession.Header
    var records: [Record]
    var entries: [CodexSessionTreeEntry]
    var byID: [CodexSessionEntryID: CodexSessionTreeEntry]
    var activeLeafID: CodexSessionEntryID?
    var selectedEditableEntryID: CodexSessionEntryID?
    var title: String?
    var labels: [CodexSessionEntryID: String]
    var isLegacy: Bool
  }

  private var documents: [String: Document] = [:]
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(directory: URL) {
    self.directory = directory
    encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    decoder = JSONDecoder()
  }

  public func create(
    id: String, cwd: String, model: String? = nil, provider: String? = nil,
    parentSession: String? = nil
  ) async throws {
    try await createIfMissing(
      id: id, cwd: cwd, model: model, provider: provider, parentSession: parentSession)
  }

  public func append(
    id: String, cwd: String, messages: [Message]
  ) async throws {
    _ = try await appendMessages(id: id, cwd: cwd, messages: messages)
  }

  public func createIfMissing(
    id: String, cwd: String, model: String? = nil, provider: String? = nil,
    parentSession: String? = nil
  ) async throws {
    try validateSessionID(id)
    if FileManager.default.fileExists(atPath: fileURL(id: id).path) {
      _ = try await document(id: id)
      return
    }
    let now = Self.now()
    let header = CodexSessionTreeLoadedSession.Header(
      id: id, cwd: cwd, createdAt: now, model: model, provider: provider,
      parentSession: parentSession)
    let document = Document(
      header: header, records: [], entries: [], byID: [:], activeLeafID: nil,
      selectedEditableEntryID: nil, title: nil, labels: [:], isLegacy: false)
    try secureDirectory(directory)
    try write(document: document, to: fileURL(id: id))
    documents[id] = document
  }

  public func load(id: String) async throws -> CodexSessionTreeLoadedSession {
    let document = try await document(id: id)
    return loadedSession(from: document)
  }

  public func snapshot(id: String) async throws -> CodexSessionTreeSnapshot {
    let document = try await document(id: id)
    let activePath = Set(path(to: document.activeLeafID, in: document).map(\.id))
    var children: [CodexSessionEntryID?: [CodexSessionTreeEntry]] = [:]
    for entry in document.entries { children[entry.parentID, default: []].append(entry) }
    for key in Array(children.keys) {
      children[key]?.sort { ($0.timestamp, $0.id.rawValue) < ($1.timestamp, $1.id.rawValue) }
    }

    var items: [CodexSessionTreeItem] = []
    var stack = (children[nil] ?? []).reversed().map { ($0, 0) }
    while let (entry, depth) = stack.popLast() {
      let directChildren = children[entry.id] ?? []
      items.append(
        CodexSessionTreeItem(
          id: entry.id, parentID: entry.parentID, timestamp: entry.timestamp, depth: depth,
          kind: itemKind(entry.content), preview: preview(entry.content),
          isOnActiveBranch: activePath.contains(entry.id), hasChildren: !directChildren.isEmpty,
          label: document.labels[entry.id]))
      let childDepth = depth + (directChildren.count > 1 ? 1 : 0)
      stack.append(contentsOf: directChildren.reversed().map { ($0, childDepth) })
    }

    return CodexSessionTreeSnapshot(
      sessionID: id, items: items, activeLeafID: document.activeLeafID,
      selectedEditableEntryID: document.selectedEditableEntryID)
  }

  @discardableResult
  public func appendMessages(
    id: String, cwd: String, messages: [Message], model: String? = nil,
    provider: String? = nil
  ) async throws -> CodexSessionEntryID? {
    try await createIfMissing(id: id, cwd: cwd, model: model, provider: provider)
    var document = try await writableDocument(id: id)
    let projected = modelProjection(in: document)
    guard messages.starts(with: projected) else { throw CodexSessionTreeError.projectionMismatch }
    guard messages.count > projected.count else { return document.activeLeafID }

    for message in messages.dropFirst(projected.count) {
      let entry = CodexSessionTreeEntry(
        parentID: document.activeLeafID, content: .message(message))
      try append(.entry(entry), to: &document)
    }
    documents[id] = document
    return document.activeLeafID
  }

  @discardableResult
  public func recordCompaction(
    id: String, cwd: String, replacementMessages: [Message], messagesCompacted: Int,
    model: String? = nil, provider: String? = nil
  ) async throws -> CodexSessionEntryID {
    try await createIfMissing(id: id, cwd: cwd, model: model, provider: provider)
    var document = try await writableDocument(id: id)
    if case .compaction(let existing, _) = document.activeLeafID.flatMap({ document.byID[$0] })?
      .content,
      existing == replacementMessages
    {
      return document.activeLeafID!
    }
    let entry = CodexSessionTreeEntry(
      parentID: document.activeLeafID,
      content: .compaction(
        replacementMessages: replacementMessages, messagesCompacted: messagesCompacted))
    try append(.entry(entry), to: &document)
    documents[id] = document
    return entry.id
  }

  public func appendMeta(
    id: String, model: String?, provider: String?, thinkingLevel: String?
  ) async throws {
    var document = try await writableDocument(id: id)
    if let model {
      let entry = CodexSessionTreeEntry(
        parentID: document.activeLeafID,
        content: .modelChange(model: model, provider: provider))
      try append(.entry(entry), to: &document)
    }
    if let thinkingLevel {
      let entry = CodexSessionTreeEntry(
        parentID: document.activeLeafID, content: .thinkingLevelChange(thinkingLevel))
      try append(.entry(entry), to: &document)
    }
    documents[id] = document
  }

  public func recordTitle(id: String, title: String?) async throws {
    var document = try await writableDocument(id: id)
    try append(.title(TitleChange(title: title, timestamp: Self.now())), to: &document)
    documents[id] = document
  }

  public func setLabel(id: String, entryID: CodexSessionEntryID, label: String?) async throws {
    var document = try await writableDocument(id: id)
    guard document.byID[entryID] != nil else { throw CodexSessionTreeError.missingEntry(entryID) }
    let normalized = label?.trimmingCharacters(in: .whitespacesAndNewlines)
    try append(
      .label(
        LabelChange(
          targetID: entryID, label: normalized?.isEmpty == false ? normalized : nil,
          timestamp: Self.now())),
      to: &document)
    documents[id] = document
  }

  public func checkout(
    id: String, targetID: CodexSessionEntryID
  ) async throws -> CodexSessionTreeLoadedSession {
    var document = try await writableDocument(id: id)
    guard let target = document.byID[targetID] else {
      throw CodexSessionTreeError.missingEntry(targetID)
    }
    guard isValidBranchPoint(target.content) else {
      throw CodexSessionTreeError.invalidBranchPoint(targetID)
    }
    let editable = editableMessage(target.content) != nil
    let checkout = Checkout(
      targetID: targetID, leafID: editable ? target.parentID : targetID,
      selectedEditableEntryID: editable ? targetID : nil, timestamp: Self.now())
    try append(.checkout(checkout), to: &document)
    documents[id] = document
    return loadedSession(from: document)
  }

  public func resetCheckout(id: String) async throws -> CodexSessionTreeLoadedSession {
    var document = try await writableDocument(id: id)
    try append(
      .checkout(
        Checkout(
          targetID: nil, leafID: nil, selectedEditableEntryID: nil, timestamp: Self.now())),
      to: &document)
    documents[id] = document
    return loadedSession(from: document)
  }

  public func editableMessage(
    id: String, entryID: CodexSessionEntryID
  ) async throws -> Message? {
    let document = try await document(id: id)
    guard let entry = document.byID[entryID] else {
      throw CodexSessionTreeError.missingEntry(entryID)
    }
    return editableMessage(entry.content)
  }

  public func checkoutModelMessage(
    id: String, index: Int, expected: Message
  ) async throws -> CodexSessionTreeLoadedSession {
    let document = try await document(id: id)
    let projected = modelProjectionWithOrigins(
      path: path(to: document.activeLeafID, in: document))
    guard projected.indices.contains(index), projected[index].message == expected,
      let entryID = projected[index].entryID
    else { throw CodexSessionTreeError.projectionMismatch }
    return try await checkout(id: id, targetID: entryID)
  }

  public func fork(
    sourceID: String, targetID: String, cwd: String, model: String?, provider: String?
  ) async throws -> CodexSessionTreeLoadedSession {
    try validateSessionID(targetID)
    let source = try await document(id: sourceID)
    let loaded = loadedSession(from: source)
    let sourcePath = path(to: source.activeLeafID, in: source)
    var idMap: [CodexSessionEntryID: CodexSessionEntryID] = [:]
    var target = Document(
      header: CodexSessionTreeLoadedSession.Header(
        id: targetID, cwd: cwd, createdAt: Self.now(), model: model ?? loaded.model,
        provider: provider ?? loaded.provider, parentSession: sourceID),
      records: [], entries: [], byID: [:], activeLeafID: nil,
      selectedEditableEntryID: nil, title: nil, labels: [:], isLegacy: false)
    for entry in sourcePath {
      let newID = CodexSessionEntryID()
      idMap[entry.id] = newID
      apply(
        .entry(
          CodexSessionTreeEntry(
            id: newID, parentID: entry.parentID.flatMap { idMap[$0] },
            timestamp: entry.timestamp, content: entry.content)),
        to: &target)
    }
    if let title = source.title {
      apply(.title(TitleChange(title: title, timestamp: Self.now())), to: &target)
    }
    for (sourceID, label) in source.labels {
      guard let targetID = idMap[sourceID] else { continue }
      apply(
        .label(LabelChange(targetID: targetID, label: label, timestamp: Self.now())),
        to: &target)
    }
    try write(document: target, to: fileURL(id: targetID))
    documents[targetID] = target
    return loadedSession(from: target)
  }

  public func list() async -> [CodexSessionTreeInfo] {
    guard
      let urls = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles])
    else { return [] }
    var result: [CodexSessionTreeInfo] = []
    for url in urls where url.pathExtension == "jsonl" {
      let id = url.deletingPathExtension().lastPathComponent
      let wasCached = documents[id] != nil
      guard let document = try? await document(id: id) else { continue }
      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
      let updated = Int64((values?.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1_000)
      result.append(
        CodexSessionTreeInfo(
          id: id, cwd: document.header.cwd, createdAt: document.header.createdAt,
          updatedAt: updated,
          messageCount: document.entries.count {
            if case .message = $0.content { return true }
            return false
          }, title: document.title,
          firstUserText: displayProjection(
            path: path(to: document.activeLeafID, in: document)
          ).compactMap(Self.userText).first,
          path: url))
      if !wasCached { documents[id] = nil }
    }
    return result.sorted { $0.updatedAt > $1.updatedAt }
  }

  public func archive(id: String) async throws {
    try validateSessionID(id)
    documents[id] = nil
    let source = fileURL(id: id)
    guard FileManager.default.fileExists(atPath: source.path) else {
      throw CodexSessionTreeError.sessionNotFound(id)
    }
    let archive = directory.appendingPathComponent("archived", isDirectory: true)
    try secureDirectory(archive)
    let destination = archive.appendingPathComponent(source.lastPathComponent)
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.moveItem(at: source, to: destination)
  }

  public func delete(id: String) async throws {
    try validateSessionID(id)
    documents[id] = nil
    let source = fileURL(id: id)
    guard FileManager.default.fileExists(atPath: source.path) else { return }
    try FileManager.default.removeItem(at: source)
  }

  private func document(id: String) async throws -> Document {
    try validateSessionID(id)
    if let cached = documents[id] { return cached }
    let url = fileURL(id: id)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw CodexSessionTreeError.sessionNotFound(id)
    }
    let data = try Data(contentsOf: url)
    let firstLine = data.split(separator: 0x0A, omittingEmptySubsequences: true).first
    guard let firstLine,
      let headerObject = try? JSONSerialization.jsonObject(with: Data(firstLine)) as? [String: Any]
    else { throw CodexSessionTreeError.invalidHeader(url.path) }

    if headerObject["format"] as? String == "codex-tree" {
      let parsed = try parseTree(data: data, path: url.path)
      documents[id] = parsed
      return parsed
    }

    let legacy = try await legacyDocument(id: id, path: url)
    documents[id] = legacy
    return legacy
  }

  private func legacyDocument(id: String, path: URL) async throws -> Document {
    let legacyStore = KWWKAgent.SessionStore(directory: directory)
    let loaded = try await legacyStore.load(id: id)
    let header = CodexSessionTreeLoadedSession.Header(
      id: loaded.header.id, cwd: loaded.header.cwd, createdAt: loaded.header.createdAt,
      model: loaded.header.model, provider: loaded.header.provider)
    var document = Document(
      header: header, records: [], entries: [], byID: [:], activeLeafID: nil,
      selectedEditableEntryID: nil, title: loaded.title, labels: [:], isLegacy: true)
    for message in loaded.displayMessages {
      apply(
        .entry(CodexSessionTreeEntry(parentID: document.activeLeafID, content: .message(message))),
        to: &document)
    }
    if loaded.messages != loaded.displayMessages {
      apply(
        .entry(
          CodexSessionTreeEntry(
            parentID: document.activeLeafID,
            content: .compaction(
              replacementMessages: loaded.messages,
              messagesCompacted: max(0, loaded.displayMessages.count - loaded.messages.count)))),
        to: &document)
    }
    if let model = loaded.model {
      apply(
        .entry(
          CodexSessionTreeEntry(
            parentID: document.activeLeafID,
            content: .modelChange(model: model, provider: loaded.provider))),
        to: &document)
    }
    if let thinking = loaded.thinkingLevel {
      apply(
        .entry(
          CodexSessionTreeEntry(
            parentID: document.activeLeafID, content: .thinkingLevelChange(thinking))),
        to: &document)
    }
    if let title = loaded.title {
      apply(.title(TitleChange(title: title, timestamp: Self.now())), to: &document)
    }
    return document
  }

  private func writableDocument(id: String) async throws -> Document {
    var document = try await document(id: id)
    guard document.isLegacy else { return document }
    let source = fileURL(id: id)
    let legacyDirectory = directory.appendingPathComponent("legacy", isDirectory: true)
    try secureDirectory(legacyDirectory)
    let backup = legacyDirectory.appendingPathComponent(source.lastPathComponent)
    if !FileManager.default.fileExists(atPath: backup.path) {
      try FileManager.default.copyItem(at: source, to: backup)
    }
    document.isLegacy = false
    try write(document: document, to: source)
    documents[id] = document
    return document
  }

  private func parseTree(data: Data, path: String) throws -> Document {
    let rawLines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
    guard let first = rawLines.first, !first.isEmpty else {
      throw CodexSessionTreeError.invalidHeader(path)
    }
    let header = try decoder.decode(
      CodexSessionTreeLoadedSession.Header.self, from: Data(first))
    guard header.format == "codex-tree" else {
      throw CodexSessionTreeError.invalidHeader(path)
    }
    guard header.version == Self.version else {
      throw CodexSessionTreeError.unsupportedVersion(header.version)
    }
    var document = Document(
      header: header, records: [], entries: [], byID: [:], activeLeafID: nil,
      selectedEditableEntryID: nil, title: nil, labels: [:], isLegacy: false)
    for index in 1..<rawLines.count {
      let line = rawLines[index]
      if line.isEmpty { continue }
      do {
        apply(try decoder.decode(Record.self, from: Data(line)), to: &document)
      } catch  where index == rawLines.count - 1 {
        // A killed process can leave one partial trailing line. Remove it before any future append.
        let validByteCount = rawLines[..<index].reduce(0) { $0 + $1.count + 1 }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.truncate(atOffset: UInt64(validByteCount))
        try handle.close()
        break
      } catch {
        throw CodexSessionTreeError.corruptLine(path: path, line: index + 1)
      }
    }
    return document
  }

  private func append(_ record: Record, to document: inout Document) throws {
    let data = try encoder.encode(record)
    var line = data
    line.append(0x0A)
    let url = fileURL(id: document.header.id)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: line)
    apply(record, to: &document)
  }

  private func apply(_ record: Record, to document: inout Document) {
    document.records.append(record)
    switch record {
    case .entry(let entry):
      document.entries.append(entry)
      document.byID[entry.id] = entry
      document.activeLeafID = entry.id
      document.selectedEditableEntryID = nil
    case .checkout(let checkout):
      document.activeLeafID = checkout.leafID
      document.selectedEditableEntryID = checkout.selectedEditableEntryID
    case .title(let change):
      document.title = change.title
    case .label(let change):
      if let label = change.label {
        document.labels[change.targetID] = label
      } else {
        document.labels[change.targetID] = nil
      }
    }
  }

  private func loadedSession(from document: Document) -> CodexSessionTreeLoadedSession {
    let path = path(to: document.activeLeafID, in: document)
    let settings = path.reduce(
      into: (
        model: document.header.model, provider: document.header.provider, thinking: nil as String?
      )
    ) { result, entry in
      switch entry.content {
      case .modelChange(let model, let provider):
        result.model = model
        result.provider = provider
      case .thinkingLevelChange(let thinking):
        result.thinking = thinking
      default:
        break
      }
    }
    return CodexSessionTreeLoadedSession(
      header: document.header, messages: modelProjection(path: path),
      displayMessages: displayProjection(path: path), activeLeafID: document.activeLeafID,
      selectedEditableEntryID: document.selectedEditableEntryID, model: settings.model,
      provider: settings.provider, thinkingLevel: settings.thinking, title: document.title,
      isLegacy: document.isLegacy)
  }

  private func path(
    to leafID: CodexSessionEntryID?, in document: Document
  ) -> [CodexSessionTreeEntry] {
    guard var current = leafID else { return [] }
    var reversed: [CodexSessionTreeEntry] = []
    var visited: Set<CodexSessionEntryID> = []
    while visited.insert(current).inserted, let entry = document.byID[current] {
      reversed.append(entry)
      guard let parent = entry.parentID else { break }
      current = parent
    }
    return reversed.reversed()
  }

  private func modelProjection(in document: Document) -> [Message] {
    modelProjection(path: path(to: document.activeLeafID, in: document))
  }

  private func modelProjection(path: [CodexSessionTreeEntry]) -> [Message] {
    modelProjectionWithOrigins(path: path).map(\.message)
  }

  private func modelProjectionWithOrigins(
    path: [CodexSessionTreeEntry]
  ) -> [(message: Message, entryID: CodexSessionEntryID?)] {
    var messages: [(Message, CodexSessionEntryID?)] = []
    for entry in path {
      switch entry.content {
      case .message(let message): messages.append((message, entry.id))
      case .compaction(let replacement, _): messages = replacement.map { ($0, nil) }
      case .branchSummary(_, let summary):
        messages.append(
          (.user(UserMessage(text: "Branch summary:\n\(summary)", source: .runtime)), entry.id))
      case .customMessage(_, _, let message, _, _): messages.append((message, entry.id))
      default: break
      }
    }
    return messages
  }

  private func displayProjection(path: [CodexSessionTreeEntry]) -> [Message] {
    path.compactMap { entry in
      switch entry.content {
      case .message(let message): message
      case .customMessage(_, _, let message, let display, _): display ? message : nil
      default: nil
      }
    }
  }

  private func itemKind(_ content: CodexSessionTreeEntry.Content) -> CodexSessionTreeItem.Kind {
    switch content {
    case .message(let message):
      switch message {
      case .user(let user): return user.source == nil ? .user : .runtime
      case .assistant: return .assistant
      case .toolResult: return .toolResult
      }
    case .modelChange: return .modelChange
    case .thinkingLevelChange: return .thinkingLevelChange
    case .compaction: return .compaction
    case .branchSummary: return .branchSummary
    case .custom: return .custom
    case .customMessage: return .customMessage
    }
  }

  private func preview(_ content: CodexSessionTreeEntry.Content) -> String {
    let raw: String
    switch content {
    case .message(let message): raw = messagePreview(message)
    case .modelChange(let model, let provider):
      raw = "Model: \([provider, model].compactMap { $0 }.joined(separator: "/"))"
    case .thinkingLevelChange(let level): raw = "Thinking: \(level)"
    case .compaction(_, let count): raw = "Compacted \(count) messages"
    case .branchSummary(_, let summary): raw = "Branch summary: \(summary)"
    case .custom(let extensionID, let type, _): raw = "\(extensionID): \(type)"
    case .customMessage(_, let type, let message, _, _):
      raw = "\(type): \(messagePreview(message))"
    }
    let oneLine = raw.replacingOccurrences(of: "\n", with: " ")
    return oneLine.count <= 160 ? oneLine : String(oneLine.prefix(159)) + "…"
  }

  private static func userText(_ message: Message) -> String? {
    guard case .user(let user) = message, user.source == nil else { return nil }
    let text = user.content.compactMap { block -> String? in
      if case .text(let value) = block { return value.text }
      return nil
    }.joined()
    return text.isEmpty ? nil : text
  }

  private func messagePreview(_ message: Message) -> String {
    switch message {
    case .user(let user):
      let text = user.content.compactMap { block -> String? in
        if case .text(let value) = block { return value.text }
        return nil
      }.joined(separator: " ")
      let images = user.content.count {
        if case .image = $0 { return true }
        return false
      }
      return [images > 0 ? "[\(images) image\(images == 1 ? "" : "s")]" : nil, text]
        .compactMap { $0 }.joined(separator: " ")
    case .assistant(let assistant):
      return assistant.content.compactMap { block -> String? in
        switch block {
        case .text(let value): value.text
        case .thinking: "Reasoning"
        case .toolCall(let call): "Tool: \(call.name)"
        }
      }.joined(separator: " ")
    case .toolResult(let result):
      let text = result.content.compactMap { block -> String? in
        if case .text(let value) = block { return value.text }
        return nil
      }.joined(separator: " ")
      return "\(result.toolName): \(text)"
    }
  }

  private func isValidBranchPoint(_ content: CodexSessionTreeEntry.Content) -> Bool {
    switch content {
    case .message(.user):
      return true
    case .message(.assistant(let assistant)):
      return !assistant.content.contains {
        if case .toolCall = $0 { return true }
        return false
      }
    case .message(.toolResult):
      return true
    case .customMessage(_, _, .user, _, _):
      return true
    default:
      return false
    }
  }

  private func editableMessage(_ content: CodexSessionTreeEntry.Content) -> Message? {
    let message: Message?
    switch content {
    case .message(let value): message = value
    case .customMessage(_, _, let value, _, _): message = value
    default: message = nil
    }
    guard let message, case .user(let user) = message, user.source == nil else { return nil }
    return message
  }

  private func write(document: Document, to url: URL) throws {
    var lines = [try encoder.encode(document.header)]
    lines += try document.records.map(encoder.encode)
    let data = lines.reduce(into: Data()) { result, line in
      result.append(line)
      result.append(0x0A)
    }
    try secureDirectory(url.deletingLastPathComponent())
    let temporary = url.deletingLastPathComponent().appendingPathComponent(
      ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    guard
      FileManager.default.createFile(
        atPath: temporary.path, contents: data,
        attributes: [.posixPermissions: NSNumber(value: 0o600)])
    else { throw CocoaError(.fileWriteUnknown) }
    guard Darwin.rename(temporary.path, url.path) == 0 else {
      let code = POSIXErrorCode(rawValue: errno) ?? .EIO
      try? FileManager.default.removeItem(at: temporary)
      throw POSIXError(code)
    }
  }

  private func secureDirectory(_ url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: 0o700)])
    }
  }

  private func fileURL(id: String) -> URL {
    directory.appendingPathComponent("\(id).jsonl")
  }

  private func validateSessionID(_ id: String) throws {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    guard !id.isEmpty, !id.hasPrefix("."), id.unicodeScalars.allSatisfy(allowed.contains)
    else { throw CodexSessionTreeError.invalidSessionID(id) }
  }

  private static func now() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1_000)
  }
}
