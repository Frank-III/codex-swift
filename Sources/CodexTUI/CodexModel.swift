import Foundation
import Observation
import TermLoom
import TermLoomSyntaxHighlighting

public enum CodexMode: String, Hashable, Sendable {
  case defaultMode = "default"
  case plan = "Plan mode"
  case side = "Side conversation"
}

public struct CodexImageAttachment: Identifiable, Hashable, Sendable {
  public var id: UUID
  public var data: Data
  public var mimeType: String
  public var name: String

  public init(id: UUID = UUID(), data: Data, mimeType: String, name: String) {
    self.id = id
    self.data = data
    self.mimeType = mimeType
    self.name = name
  }
}

public enum ToolActivityStatus: Hashable, Sendable {
  case running
  case succeeded
  case failed
  case interrupted
}

public enum ExplorationActionKind: String, Hashable, Sendable {
  case search = "Search"
  case read = "Read"
  case list = "List"
}

public struct ExplorationAction: Hashable, Sendable {
  public var kind: ExplorationActionKind
  public var subject: String
  public var path: String?

  public init(kind: ExplorationActionKind, subject: String, path: String? = nil) {
    self.kind = kind
    self.subject = subject
    self.path = path
  }
}

public enum DiffLineKind: Hashable, Sendable {
  case context
  case addition
  case deletion
  case separator
}

public struct DiffLine: Hashable, Sendable {
  public var lineNumber: Int?
  public var kind: DiffLineKind
  public var text: String

  public init(lineNumber: Int?, kind: DiffLineKind, text: String) {
    self.lineNumber = lineNumber
    self.kind = kind
    self.text = text
  }
}

public enum ToolPresentation: Hashable, Sendable {
  case generic
  case command(command: String, output: [String], omittedLineCount: Int)
  case exploration(ExplorationAction)
  case edit(path: String, additions: Int, deletions: Int, lines: [DiffLine])
  case editFailure(path: String, output: [String])
}

public struct ToolActivity: Hashable, Sendable {
  public var callID: String
  public var name: String
  public var detail: String
  public var output: [String]
  public var status: ToolActivityStatus
  public var durationMilliseconds: Int?
  public var presentation: ToolPresentation

  public init(
    callID: String,
    name: String,
    detail: String = "",
    output: [String] = [],
    status: ToolActivityStatus = .running,
    durationMilliseconds: Int? = nil,
    presentation: ToolPresentation = .generic
  ) {
    self.callID = callID
    self.name = name
    self.detail = detail
    self.output = output
    self.status = status
    self.durationMilliseconds = durationMilliseconds
    self.presentation = presentation
  }
}

public enum TranscriptContent: Hashable, Sendable {
  case user(String)
  case assistant(String, streaming: Bool)
  case reasoning(summary: String, body: String?, streaming: Bool)
  case tool(ToolActivity)
  case approvalDecision(ApprovalDecisionRecord)
  case notice(String)
  case error(String)
}

public enum CodexVimMode: String, Hashable, Sendable {
  case normal = "Normal"
  case insert = "Insert"
}

public enum CodexVimOperator: Hashable, Sendable {
  case delete
  case yank
  case change
}

public struct TranscriptEntry: Identifiable, Hashable, Sendable {
  public var id: String
  public var content: TranscriptContent
  public var streamingMarkdown: CodexStreamingMarkdown?

  public init(
    id: String = UUID().uuidString, content: TranscriptContent,
    streamingMarkdown: CodexStreamingMarkdown? = nil
  ) {
    self.id = id
    self.content = content
    self.streamingMarkdown = streamingMarkdown
  }
}

public struct ApprovalChoice: Hashable, Sendable {
  public var title: String
  public var shortcut: String?
  public var detail: String?
  public var decision: ApprovalDecision

  public init(
    _ title: String,
    shortcut: String? = nil,
    detail: String? = nil,
    decision: ApprovalDecision = .approveOnce
  ) {
    self.title = title
    self.shortcut = shortcut
    self.detail = detail
    self.decision = decision
  }
}

public enum ApprovalDecision: Hashable, Sendable {
  case approveOnce
  case approveForSession
  case decline
  case cancel
}

public enum ApprovalSubject: Hashable, Sendable {
  case command(String)
  case fileChange(String)
}

public struct ApprovalRequest: Hashable, Sendable {
  public var id: String
  public var title: String
  public var reason: String?
  public var command: String?
  public var choices: [ApprovalChoice]
  public var selection: SelectionState

  public init(
    id: String = UUID().uuidString,
    title: String,
    reason: String? = nil,
    command: String? = nil,
    choices: [ApprovalChoice],
    selectedIndex: Int = 0
  ) {
    self.id = id
    self.title = title
    self.reason = reason
    self.command = command
    self.choices = choices
    selection = SelectionState(selectedIndex: selectedIndex)
  }

  public var selectedIndex: Int { selection.selectedIndex ?? 0 }
}

public struct ApprovalDecisionRecord: Hashable, Sendable {
  public var subject: ApprovalSubject
  public var decision: ApprovalDecision

  public init(subject: ApprovalSubject, decision: ApprovalDecision) {
    self.subject = subject
    self.decision = decision
  }
}

public struct CodexModelOption: Identifiable, Hashable, Sendable {
  public var id: String
  public var modelID: String
  public var name: String
  public var provider: String
  public var contextWindow: Int
  public var supportsReasoning: Bool

  public init(
    id: String,
    modelID: String,
    name: String,
    provider: String,
    contextWindow: Int,
    supportsReasoning: Bool
  ) {
    self.id = id
    self.modelID = modelID
    self.name = name
    self.provider = provider
    self.contextWindow = contextWindow
    self.supportsReasoning = supportsReasoning
  }
}

public struct ModelPicker: Hashable, Sendable {
  public var models: [CodexModelOption]
  public var selectedIndex: Int
  public var query: String

  public init(models: [CodexModelOption], selectedIndex: Int = 0, query: String = "") {
    self.models = models
    self.selectedIndex = selectedIndex
    self.query = query
  }

  public var filteredModels: [CodexModelOption] {
    let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace })
    guard !terms.isEmpty else { return models }
    return models.filter { model in
      let haystack = "\(model.provider) \(model.modelID) \(model.name)".lowercased()
      return terms.allSatisfy(haystack.contains)
    }
  }

  public mutating func reconcileSelection() {
    selectedIndex = min(max(0, selectedIndex), max(0, filteredModels.count - 1))
  }
}

public struct CodexReasoningOption: Identifiable, Hashable, Sendable {
  public var id: String
  public var label: String
  public var description: String
  public var isDefault: Bool

  public init(id: String, label: String, description: String, isDefault: Bool = false) {
    self.id = id
    self.label = label
    self.description = description
    self.isDefault = isDefault
  }
}

public struct ReasoningPicker: Hashable, Sendable {
  public var modelID: String
  public var modelName: String
  public var options: [CodexReasoningOption]
  public var selectedIndex: Int

  public init(
    modelID: String, modelName: String, options: [CodexReasoningOption], selectedIndex: Int = 0
  ) {
    self.modelID = modelID
    self.modelName = modelName
    self.options = options
    self.selectedIndex = min(max(0, selectedIndex), max(0, options.count - 1))
  }
}

public enum CodexPermissionMode: String, Hashable, Sendable {
  case askForApproval = "Ask for approval"
  case fullAccess = "Full Access"
}

public struct PermissionPicker: Hashable, Sendable {
  public var selectedIndex: Int
  public var confirmingFullAccess: Bool

  public init(selectedIndex: Int = 0, confirmingFullAccess: Bool = false) {
    self.selectedIndex = min(max(0, selectedIndex), 1)
    self.confirmingFullAccess = confirmingFullAccess
  }
}

public enum CodexPersonality: String, Hashable, Sendable {
  case friendly = "Friendly"
  case pragmatic = "Pragmatic"

  public var description: String {
    switch self {
    case .friendly: "Warm, collaborative, and helpful."
    case .pragmatic: "Concise, task-focused, and direct."
    }
  }

  public var instruction: String {
    switch self {
    case .friendly: "Communicate warmly, collaboratively, and helpfully."
    case .pragmatic: "Communicate concisely, stay task-focused, and be direct."
    }
  }
}

public struct PersonalityPicker: Hashable, Sendable {
  public var selectedIndex: Int
  public init(selectedIndex: Int = 0) { self.selectedIndex = min(max(0, selectedIndex), 1) }
}

public struct ThemePicker: Hashable, Sendable {
  public var themes: [SyntaxTheme]
  public var query: TextFieldState
  public var selectedIndex: Int
  public var originalThemeName: String

  public init(
    themes: [SyntaxTheme], query: String = "", selectedIndex: Int = 0,
    originalThemeName: String
  ) {
    self.themes = themes
    self.query = TextFieldState(text: query)
    self.selectedIndex = selectedIndex
    self.originalThemeName = originalThemeName
    reconcileSelection()
  }

  public var filteredThemes: [SyntaxTheme] {
    let needle = query.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return themes }
    return themes.filter { $0.name.lowercased().contains(needle) }
  }

  public mutating func reconcileSelection() {
    selectedIndex = min(max(0, selectedIndex), max(0, filteredThemes.count - 1))
  }

  public var selectedTheme: SyntaxTheme? { filteredThemes[safe: selectedIndex] }
}

public enum SessionPickerAction: Hashable, Sendable {
  case resume
  case fork

  public var title: String {
    switch self {
    case .resume: "Resume a previous session"
    case .fork: "Fork a previous session"
    }
  }
}

public struct CodexSessionSummary: Identifiable, Hashable, Sendable {
  public var id: String
  public var title: String
  public var directory: String
  public var createdAt: Int64
  public var updatedAt: Int64
  public var messageCount: Int

  public init(
    id: String, title: String, directory: String, createdAt: Int64, updatedAt: Int64,
    messageCount: Int
  ) {
    self.id = id
    self.title = title
    self.directory = directory
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.messageCount = messageCount
  }
}

public struct SessionPicker: Hashable, Sendable {
  public var action: SessionPickerAction
  public var sessions: [CodexSessionSummary]
  public var query: TextFieldState
  public var selection: SelectionState
  public var showAllDirectories: Bool
  public var currentDirectory: String

  public init(
    action: SessionPickerAction, sessions: [CodexSessionSummary], query: String = "",
    selectedIndex: Int = 0, showAllDirectories: Bool = false, currentDirectory: String = ""
  ) {
    self.action = action
    self.sessions = sessions
    self.query = TextFieldState(text: query)
    selection = SelectionState(selectedIndex: selectedIndex)
    self.showAllDirectories = showAllDirectories
    self.currentDirectory = currentDirectory
    reconcileSelection()
  }

  public var filteredSessions: [CodexSessionSummary] {
    let needle = query.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let directorySessions =
      showAllDirectories || currentDirectory.isEmpty
      ? sessions : sessions.filter { normalized($0.directory) == normalized(currentDirectory) }
    guard !needle.isEmpty else { return directorySessions }
    return directorySessions.filter {
      $0.title.lowercased().contains(needle) || $0.directory.lowercased().contains(needle)
        || $0.id.lowercased().contains(needle)
    }
  }

  public var selectedIndex: Int { selection.selectedIndex ?? 0 }

  public mutating func reconcileSelection() {
    selection.reconcile(itemCount: filteredSessions.count)
  }

  private func normalized(_ path: String) -> String {
    var path = path
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
  }
}

public struct RenameThreadPrompt: Hashable, Sendable {
  public var name: TextFieldState
  public init(name: String = "") { self.name = TextFieldState(text: name) }
}

public enum DestructiveSessionAction: Hashable, Sendable {
  case archive
  case delete
}

public struct SessionActionConfirmation: Hashable, Sendable {
  public var action: DestructiveSessionAction
  public var selectedIndex: Int

  public init(action: DestructiveSessionAction, selectedIndex: Int = 0) {
    self.action = action
    self.selectedIndex = min(max(0, selectedIndex), 1)
  }
}

public struct HistorySearch: Hashable, Sendable {
  public var originalDraft: TextFieldState
  public var query: TextFieldState
  public var matches: [String]
  public var selectedIndex: Int?

  public init(originalDraft: TextFieldState, history: [String]) {
    self.originalDraft = originalDraft
    query = TextFieldState()
    matches = Array(history.reversed())
    selectedIndex = nil
  }

  public mutating func refresh(history: [String]) {
    let needle = query.text.lowercased()
    matches = history.reversed().filter { needle.isEmpty || $0.lowercased().contains(needle) }
    if matches.isEmpty {
      selectedIndex = nil
    } else if let selectedIndex {
      self.selectedIndex = min(selectedIndex, matches.count - 1)
    }
  }
}

public struct ReviewPicker: Hashable, Sendable {
  public var selectedIndex: Int
  public init(selectedIndex: Int = 0) { self.selectedIndex = min(max(0, selectedIndex), 3) }
}

public struct AgentThreadSummary: Identifiable, Hashable, Sendable {
  public var id: String
  public var name: String
  public var role: String
  public var status: String
  public var description: String
  public var entries: [TranscriptEntry]

  public init(
    id: String, name: String, role: String, status: String, description: String,
    entries: [TranscriptEntry] = []
  ) {
    self.id = id
    self.name = name
    self.role = role
    self.status = status
    self.description = description
    self.entries = entries
  }
}

public struct AgentPicker: Hashable, Sendable {
  public var threads: [AgentThreadSummary]
  public var selectedIndex: Int

  public init(threads: [AgentThreadSummary], selectedIndex: Int = 0) {
    self.threads = threads
    self.selectedIndex = min(max(0, selectedIndex), max(0, threads.count - 1))
  }
}

public struct AgentThreadPreview: Hashable, Sendable {
  public var thread: AgentThreadSummary
  public init(thread: AgentThreadSummary) { self.thread = thread }
}

public struct BackgroundTaskSummary: Identifiable, Hashable, Sendable {
  public var id: String
  public var label: String
  public var kind: String
  public var status: String
  public var output: String

  public init(id: String, label: String, kind: String, status: String, output: String = "") {
    self.id = id
    self.label = label
    self.kind = kind
    self.status = status
    self.output = output
  }
}

public struct BackgroundTaskPicker: Hashable, Sendable {
  public var tasks: [BackgroundTaskSummary]
  public var selectedIndex: Int

  public init(tasks: [BackgroundTaskSummary], selectedIndex: Int = 0) {
    self.tasks = tasks
    self.selectedIndex = min(max(0, selectedIndex), max(0, tasks.count - 1))
  }
}

public struct SkillSummary: Identifiable, Hashable, Sendable {
  public var id: String { path }
  public var name: String
  public var description: String
  public var path: String

  public init(name: String, description: String, path: String) {
    self.name = name
    self.description = description
    self.path = path
  }
}

private func mentionFuzzyScore(query: String, candidate: String) -> Int? {
  let normalizedQuery = query.lowercased().filter { !$0.isWhitespace }
  guard !normalizedQuery.isEmpty else { return 0 }
  let normalizedCandidate = candidate.lowercased()
  if normalizedCandidate.contains(normalizedQuery) { return 1_000 }
  let needle = Array(normalizedQuery)
  let haystack = Array(normalizedCandidate)
  var searchStart = 0
  var previousMatch = -2
  var score = 0
  for character in needle {
    guard searchStart < haystack.count,
      let match = (searchStart..<haystack.count).first(where: { haystack[$0] == character })
    else { return nil }
    score += match == previousMatch + 1 ? 12 : 2
    if match == 0 || haystack[match - 1].isWhitespace || "/-_:".contains(haystack[match - 1]) {
      score += 6
    }
    score -= min(4, match - searchStart)
    previousMatch = match
    searchStart = match + 1
  }
  return score
}

public struct SkillPicker: Hashable, Sendable {
  public var skills: [SkillSummary]
  public var query: TextFieldState
  public var selectedIndex: Int

  public init(skills: [SkillSummary], query: String = "", selectedIndex: Int = 0) {
    self.skills = skills
    self.query = TextFieldState(text: query)
    self.selectedIndex = selectedIndex
    reconcileSelection()
  }

  public var filteredSkills: [SkillSummary] {
    let needle = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return skills }
    return skills.enumerated().compactMap { index, skill -> (Int, Int, SkillSummary)? in
      let candidate = "\(skill.name) \(skill.description) \(skill.path)"
      return mentionFuzzyScore(query: needle, candidate: candidate).map { ($0, index, skill) }
    }.sorted { lhs, rhs in
      lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 > rhs.0
    }.map(\.2)
  }

  public mutating func reconcileSelection() {
    selectedIndex = min(max(0, selectedIndex), max(0, filteredSkills.count - 1))
  }
}

public struct FileMentionPicker: Hashable, Sendable {
  public var files: [String]
  public var query: TextFieldState
  public var selectedIndex: Int

  public init(files: [String], query: String = "", selectedIndex: Int = 0) {
    self.files = files
    self.query = TextFieldState(text: query)
    self.selectedIndex = selectedIndex
    reconcileSelection()
  }

  public var filteredFiles: [String] {
    let needle = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return files }
    return files.enumerated().compactMap { index, path -> (Int, Int, String)? in
      mentionFuzzyScore(query: needle, candidate: path).map { ($0, index, path) }
    }.sorted { lhs, rhs in
      lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 > rhs.0
    }.map(\.2)
  }

  public mutating func reconcileSelection() {
    selectedIndex = min(max(0, selectedIndex), max(0, filteredFiles.count - 1))
  }
}

public struct RewindCandidate: Identifiable, Hashable, Sendable {
  public var id: Int
  public var preview: String

  public init(id: Int, preview: String) {
    self.id = id
    self.preview = preview
  }
}

public struct RewindDraft: Hashable, Sendable {
  public var text: String
  public var images: [CodexImageAttachment]

  public init(text: String, images: [CodexImageAttachment] = []) {
    self.text = text
    self.images = images
  }
}

public struct RewindPicker: Hashable, Sendable {
  public var candidates: [RewindCandidate]
  public var selectedIndex: Int

  public init(candidates: [RewindCandidate], selectedIndex: Int? = nil) {
    self.candidates = candidates
    self.selectedIndex = min(
      max(0, selectedIndex ?? candidates.count - 1), max(0, candidates.count - 1))
  }
}

public struct SessionTreePicker: Hashable, Sendable {
  public var snapshot: CodexSessionTreeSnapshot
  public var query: TextFieldState
  public var selection: SelectionState

  public init(
    snapshot: CodexSessionTreeSnapshot, query: String = "", selectedID: CodexSessionEntryID? = nil
  ) {
    self.snapshot = snapshot
    self.query = TextFieldState(text: query)
    let items = Self.filtered(snapshot.items, query: query)
    let preferred = selectedID ?? snapshot.activeLeafID
    let selectedIndex =
      preferred.flatMap { id in items.firstIndex(where: { $0.id == id }) }
      ?? max(0, items.count - 1)
    selection = SelectionState(selectedIndex: selectedIndex)
    reconcileSelection()
  }

  public var filteredItems: [CodexSessionTreeItem] {
    Self.filtered(snapshot.items, query: query.text)
  }

  public var selectedIndex: Int { selection.selectedIndex ?? 0 }
  public var selectedItem: CodexSessionTreeItem? { filteredItems[safe: selectedIndex] }

  public mutating func reconcileSelection() {
    selection.reconcile(itemCount: filteredItems.count)
  }

  private static func filtered(
    _ items: [CodexSessionTreeItem], query: String
  ) -> [CodexSessionTreeItem] {
    let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace })
    guard !terms.isEmpty else { return items }
    return items.filter { item in
      let haystack = "\(item.kind.rawValue) \(item.label ?? "") \(item.preview)".lowercased()
      return terms.allSatisfy(haystack.contains)
    }
  }
}

public struct RequestUserInputOption: Hashable, Sendable {
  public var label: String
  public var description: String

  public init(label: String, description: String = "") {
    self.label = label
    self.description = description
  }
}

public struct RequestUserInputQuestion: Hashable, Sendable {
  public var id: String
  public var header: String
  public var question: String
  public var options: [RequestUserInputOption]

  public init(
    id: String, header: String, question: String,
    options: [RequestUserInputOption] = []
  ) {
    self.id = id
    self.header = header
    self.question = question
    self.options = options
  }
}

public struct RequestUserInputAnswer: Hashable, Sendable {
  public var selection: SelectionState
  public var draft: TextFieldState
  public var isCommitted: Bool
  public var showsNotes: Bool

  public init() {
    selection = SelectionState()
    draft = TextFieldState()
    isCommitted = false
    showsNotes = false
  }
}

public enum RequestUserInputFocus: Hashable, Sendable {
  case options
  case text
}

public struct RequestUserInputRequest: Hashable, Sendable {
  public var id: String
  public var questions: [RequestUserInputQuestion]
  public var answers: [RequestUserInputAnswer]
  public var currentIndex: Int
  public var focus: RequestUserInputFocus

  public init(
    id: String = UUID().uuidString,
    questions: [RequestUserInputQuestion],
    currentIndex: Int = 0
  ) {
    self.id = id
    self.questions = questions
    answers = questions.map { _ in RequestUserInputAnswer() }
    self.currentIndex = min(max(0, currentIndex), max(0, questions.count - 1))
    focus = questions[safe: self.currentIndex]?.options.isEmpty == false ? .options : .text
  }

  public var unansweredCount: Int { answers.count(where: { !$0.isCommitted }) }
}

public struct CodexTranscriptPager: Hashable, Sendable {
  public var scrollFromBottom: Int
  public var backtrackCandidates: [RewindCandidate]
  public var selectedBacktrackIndex: Int?
  public var cachedTranscriptLines: [Line]?
  public var cachedWidth: Int?
  public var sourceEntries: [TranscriptEntry]?

  public init(
    scrollFromBottom: Int = 0, backtrackCandidates: [RewindCandidate] = [],
    selectedBacktrackIndex: Int? = nil, cachedTranscriptLines: [Line]? = nil,
    cachedWidth: Int? = nil, sourceEntries: [TranscriptEntry]? = nil
  ) {
    self.scrollFromBottom = max(0, scrollFromBottom)
    self.backtrackCandidates = backtrackCandidates
    self.selectedBacktrackIndex = selectedBacktrackIndex
    self.cachedTranscriptLines = cachedTranscriptLines
    self.cachedWidth = cachedWidth
    self.sourceEntries = sourceEntries
  }

  public var highlightedUserFromEnd: Int? {
    guard let selectedBacktrackIndex,
      backtrackCandidates.indices.contains(selectedBacktrackIndex)
    else { return nil }
    return backtrackCandidates.count - 1 - selectedBacktrackIndex
  }

  public var followsLiveTail: Bool { scrollFromBottom == 0 }

  public mutating func scrollUp(_ rows: Int = 1) {
    let distance = max(0, rows)
    let result = scrollFromBottom.addingReportingOverflow(distance)
    scrollFromBottom = result.overflow ? .max : result.partialValue
  }

  public mutating func scrollDown(_ rows: Int = 1) {
    scrollFromBottom = max(0, scrollFromBottom - max(0, rows))
  }

  public mutating func jumpToTop() { scrollFromBottom = Int.max }
  public mutating func jumpToBottom() { scrollFromBottom = 0 }
}

public enum CodexOverlay: Hashable, Sendable {
  case approval(ApprovalRequest)
  case requestUserInput(RequestUserInputRequest)
  case models(ModelPicker)
  case reasoning(ReasoningPicker)
  case permissions(PermissionPicker)
  case personality(PersonalityPicker)
  case theme(ThemePicker)
  case keymap(CodexKeymapPicker)
  case keymapAction(CodexKeymapActionMenu)
  case keymapCapture(CodexKeymapCapture)
  case keymapDebug(CodexKeymapDebug)
  case transcript(CodexTranscriptPager)
  case sessions(SessionPicker)
  case rename(RenameThreadPrompt)
  case sessionConfirmation(SessionActionConfirmation)
  case historySearch(HistorySearch)
  case review(ReviewPicker)
  case agents(AgentPicker)
  case agentPreview(AgentThreadPreview)
  case backgroundTasks(BackgroundTaskPicker)
  case skills(SkillPicker)
  case fileMentions(FileMentionPicker)
  case rewind(RewindPicker)
  case sessionTree(SessionTreePicker)
  case shortcuts
}

extension Collection {
  fileprivate subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

public struct CodexSnapshot: Hashable, Sendable {
  public var version: String
  public var model: String
  public var modelProvider: String
  public var reasoningEffort: String
  public var permissionMode: CodexPermissionMode
  public var personality: CodexPersonality
  public var syntaxTheme: SyntaxTheme
  public var rawOutputMode: Bool
  public var vimEnabled: Bool
  public var vimMode: CodexVimMode
  public var serviceTier: String?
  public var directory: String
  public var entries: [TranscriptEntry]
  public var composer: TextFieldState

  public var imageAttachments: [CodexImageAttachment]
  public var selectedImageAttachmentIndex: Int?
  public var mode: CodexMode

  public var isWorking: Bool
  public var workingLabel: String
  public var elapsedSeconds: Int
  public var queuedMessages: [String]
  public var contextRemainingPercent: Int
  public var rightStatus: String?
  public var overlay: CodexOverlay?
  public var showHeader: Bool
  public var slashCommandSelection: Int
  public var slashPopupDismissed: Bool

  public init(
    version: String = "0.1.0",
    model: String = "model unavailable",
    modelProvider: String = "",
    reasoningEffort: String = "high",
    permissionMode: CodexPermissionMode = .askForApproval,
    personality: CodexPersonality = .friendly,
    syntaxTheme: SyntaxTheme = SyntaxTheme.named(SyntaxTheme.defaultName)!,
    rawOutputMode: Bool = false,
    vimEnabled: Bool = false,
    vimMode: CodexVimMode = .insert,
    serviceTier: String? = nil,
    directory: String = FileManager.default.currentDirectoryPath,
    entries: [TranscriptEntry] = [],
    composer: TextFieldState = TextFieldState(),
    imageAttachments: [CodexImageAttachment] = [],
    selectedImageAttachmentIndex: Int? = nil,
    mode: CodexMode = .defaultMode,
    isWorking: Bool = false,
    workingLabel: String = "Working",
    elapsedSeconds: Int = 0,
    queuedMessages: [String] = [],
    contextRemainingPercent: Int = 100,
    rightStatus: String? = nil,
    overlay: CodexOverlay? = nil,
    showHeader: Bool = true,
    slashCommandSelection: Int = 0,
    slashPopupDismissed: Bool = false
  ) {
    self.version = version
    self.model = model
    self.modelProvider = modelProvider
    self.reasoningEffort = reasoningEffort
    self.permissionMode = permissionMode
    self.personality = personality
    self.syntaxTheme = syntaxTheme
    self.rawOutputMode = rawOutputMode
    self.vimEnabled = vimEnabled
    self.vimMode = vimMode
    self.serviceTier = serviceTier
    self.directory = directory
    self.entries = entries
    self.composer = composer
    self.imageAttachments = imageAttachments
    self.selectedImageAttachmentIndex = selectedImageAttachmentIndex
    self.mode = mode
    self.isWorking = isWorking
    self.workingLabel = workingLabel
    self.elapsedSeconds = elapsedSeconds
    self.queuedMessages = queuedMessages
    self.contextRemainingPercent = contextRemainingPercent
    self.rightStatus = rightStatus
    self.overlay = overlay
    self.showHeader = showHeader
    self.slashCommandSelection = slashCommandSelection
    self.slashPopupDismissed = slashPopupDismissed
  }
}

@MainActor
@Observable
public final class CodexSessionModel {
  public var sessionID: String
  public var threadTitle: String?
  public var version: String
  public var model: String
  public var modelProvider: String
  public var reasoningEffort: String
  public var permissionMode: CodexPermissionMode
  public var personality: CodexPersonality
  public var syntaxTheme: SyntaxTheme
  public var rawOutputMode: Bool
  public var runtimeKeymap: CodexRuntimeKeymap
  public var vimEnabled: Bool
  public var vimMode: CodexVimMode
  public var serviceTier: String?
  public var directory: String
  public private(set) var transcriptRevision: UInt64 = 0
  public var entries: [TranscriptEntry] {
    didSet { transcriptRevision &+= 1 }
  }
  public var composer: TextFieldState
  public var imageAttachments: [CodexImageAttachment]
  public var selectedImageAttachmentIndex: Int?
  public var mode: CodexMode
  public var isWorking: Bool
  public var workingLabel: String
  public var elapsedSeconds: Int
  public var queuedMessages: [String]
  public var contextRemainingPercent: Int
  public var rightStatus: String?
  public var overlay: CodexOverlay?
  public var showHeader: Bool
  public var slashCommandSelection: Int
  public var slashPopupDismissed: Bool
  public var history: [String]
  public var historyIndex: Int?
  private var pendingPastes: [(id: TextFieldElementID, placeholder: String, content: String)]
  private var vimPendingOperator: CodexVimOperator?
  private var vimKillBuffer: String
  private var vimKillLinewise: Bool
  private var vimPreferredColumn: Int?
  private var vimTextObjectAround: Bool?

  public init(
    snapshot: CodexSnapshot = CodexSnapshot(),
    runtimeKeymap: CodexRuntimeKeymap = try! CodexRuntimeKeymap()
  ) {
    sessionID = UUID().uuidString
    threadTitle = nil
    version = snapshot.version
    model = snapshot.model
    modelProvider = snapshot.modelProvider
    reasoningEffort = snapshot.reasoningEffort
    permissionMode = snapshot.permissionMode
    personality = snapshot.personality
    syntaxTheme = snapshot.syntaxTheme
    rawOutputMode = snapshot.rawOutputMode
    self.runtimeKeymap = runtimeKeymap
    vimEnabled = snapshot.vimEnabled
    vimMode = snapshot.vimMode
    serviceTier = snapshot.serviceTier
    directory = snapshot.directory
    entries = snapshot.entries
    composer = snapshot.composer
    imageAttachments = snapshot.imageAttachments
    selectedImageAttachmentIndex = snapshot.selectedImageAttachmentIndex
    mode = snapshot.mode
    isWorking = snapshot.isWorking
    workingLabel = snapshot.workingLabel
    elapsedSeconds = snapshot.elapsedSeconds
    queuedMessages = snapshot.queuedMessages
    contextRemainingPercent = snapshot.contextRemainingPercent
    rightStatus = snapshot.rightStatus
    overlay = snapshot.overlay
    showHeader = snapshot.showHeader
    slashCommandSelection = snapshot.slashCommandSelection
    slashPopupDismissed = snapshot.slashPopupDismissed
    history = []
    historyIndex = nil
    pendingPastes = []
    vimPendingOperator = nil
    vimKillBuffer = ""
    vimKillLinewise = false
    vimPreferredColumn = nil
    vimTextObjectAround = nil
  }

  public var snapshot: CodexSnapshot {
    CodexSnapshot(
      version: version,
      model: model,
      modelProvider: modelProvider,
      reasoningEffort: reasoningEffort,
      permissionMode: permissionMode,
      personality: personality,
      syntaxTheme: syntaxTheme,
      rawOutputMode: rawOutputMode,
      vimEnabled: vimEnabled,
      vimMode: vimMode,
      serviceTier: serviceTier,
      directory: directory,
      entries: entries,
      composer: composer,
      imageAttachments: imageAttachments,
      selectedImageAttachmentIndex: selectedImageAttachmentIndex,
      mode: mode,
      isWorking: isWorking,
      workingLabel: workingLabel,
      elapsedSeconds: elapsedSeconds,
      queuedMessages: queuedMessages,
      contextRemainingPercent: contextRemainingPercent,
      rightStatus: rightStatus,
      overlay: overlay,
      showHeader: showHeader,
      slashCommandSelection: slashCommandSelection,
      slashPopupDismissed: slashPopupDismissed
    )
  }

  public func composerTextWithPendingPastes() -> String {
    composer.expandingElements { id in
      pendingPastes.first(where: { $0.id == id })?.content
    }
  }

  public func applyExternalEdit(_ text: String) {
    composer = TextFieldState(text: text)
    pendingPastes.removeAll()
    historyIndex = nil
  }

  @discardableResult
  public func takeComposerText() -> String? {
    takeComposerSubmission()?.text
  }

  public func takeComposerSubmission() -> (text: String, images: [CodexImageAttachment])? {
    var submissionComposer = composer
    let visibleCharacters = Array(submissionComposer.text)
    let lower = visibleCharacters.firstIndex(where: { !$0.isWhitespace }) ?? visibleCharacters.count
    let upper = visibleCharacters.lastIndex(where: { !$0.isWhitespace }).map { $0 + 1 } ?? lower
    if upper < visibleCharacters.count {
      submissionComposer.delete(upper..<visibleCharacters.count)
    }
    if lower > 0 { submissionComposer.delete(0..<lower) }
    let text = submissionComposer.expandingElements { id in
      pendingPastes.first(where: { $0.id == id })?.content
    }
    guard !text.isEmpty || !imageAttachments.isEmpty else { return nil }
    history.append(text)
    historyIndex = nil
    composer = TextFieldState()
    pendingPastes.removeAll()
    let images = imageAttachments
    imageAttachments.removeAll()
    selectedImageAttachmentIndex = nil
    if vimEnabled { vimMode = .normal }
    return (text, images)
  }

  public func toggleVimMode() -> Bool {
    vimEnabled.toggle()
    vimMode = vimEnabled ? .normal : .insert
    vimPendingOperator = nil
    return vimEnabled
  }

  @discardableResult
  public func handleVimEvent(_ event: TerminalEvent) -> Bool {
    guard vimEnabled, case .key(let key) = event, key.kind != .release else { return false }
    if vimMode == .insert {
      guard key.key == .escape, key.modifiers.isEmpty else { return false }
      if composer.cursor > beginningOfLine() { composer.moveCursor(to: composer.cursor - 1) }
      vimMode = .normal
      vimPendingOperator = nil
      return true
    }
    guard key.modifiers.intersection([.control, .command, .option, .meta, .hyper]).isEmpty else {
      return false
    }
    if let around = vimTextObjectAround, let pending = vimPendingOperator {
      vimPendingOperator = nil
      vimTextObjectAround = nil
      return handleVimTextObject(pending, around: around, key: key.key)
    }
    if let pending = vimPendingOperator {
      vimPendingOperator = nil
      return handleVimOperator(pending, key: key.key)
    }
    if ![Key.character("j"), .character("k"), .up, .down].contains(key.key) {
      vimPreferredColumn = nil
    }
    switch key.key {
    case .character("i"):
      vimMode = .insert
    case .character("a"):
      composer.moveCursor(to: min(endOfLine(), composer.cursor + 1))
      vimMode = .insert
    case .character("A"):
      composer.moveCursor(to: endOfLine())
      vimMode = .insert
    case .character("I"):
      composer.moveCursor(to: firstNonBlank())
      vimMode = .insert
    case .character("o"):
      openLine(below: true)
    case .character("O"):
      openLine(below: false)
    case .character("h"), .left:
      composer.moveCursor(to: max(beginningOfLine(), composer.cursor - 1))
    case .character("l"), .right:
      composer.moveCursor(to: min(normalLineEnd(), composer.cursor + 1))
    case .character("j"), .down:
      moveVertical(by: 1)
    case .character("k"), .up:
      moveVertical(by: -1)
    case .character("0"), .home:
      composer.moveCursor(to: beginningOfLine())
    case .character("$"), .end:
      composer.moveCursor(to: normalLineEnd())
    case .character("w"):
      composer.moveCursor(to: min(nextWordStart(), max(0, composer.text.count - 1)))
    case .character("b"):
      composer.moveCursor(to: previousWordStart())
    case .character("e"):
      composer.moveCursor(to: wordEnd())
    case .character("x"):
      kill(composer.cursor..<min(endOfLine(), composer.cursor + 1))
    case .character("s"):
      kill(composer.cursor..<min(endOfLine(), composer.cursor + 1))
      vimMode = .insert
    case .character("D"):
      kill(composer.cursor..<endOfLine())
    case .character("C"):
      kill(composer.cursor..<endOfLine())
      vimMode = .insert
    case .character("p"):
      pasteAfter()
    case .character("Y"):
      vimKillBuffer = substring(lineRange())
      vimKillLinewise = true
    case .character("d"):
      vimPendingOperator = .delete
    case .character("y"):
      vimPendingOperator = .yank
    case .character("c"):
      vimPendingOperator = .change
    case .escape:
      vimPendingOperator = nil
    default:
      break
    }
    return true
  }

  private func beginningOfLine(at position: Int? = nil) -> Int {
    let characters = Array(composer.text)
    var index = min(position ?? composer.cursor, characters.count)
    while index > 0, characters[index - 1] != "\n" { index -= 1 }
    return index
  }

  private func endOfLine(at position: Int? = nil) -> Int {
    let characters = Array(composer.text)
    var index = min(position ?? composer.cursor, characters.count)
    while index < characters.count, characters[index] != "\n" { index += 1 }
    return index
  }

  private func normalLineEnd() -> Int {
    max(beginningOfLine(), endOfLine() - (endOfLine() > beginningOfLine() ? 1 : 0))
  }

  private func firstNonBlank() -> Int {
    let characters = Array(composer.text)
    var index = beginningOfLine()
    let end = endOfLine()
    while index < end, characters[index].isWhitespace { index += 1 }
    return index
  }

  private func nextWordStart() -> Int {
    let characters = Array(composer.text)
    var index = min(composer.cursor + 1, characters.count)
    while index < characters.count, !characters[index].isWhitespace { index += 1 }
    while index < characters.count, characters[index].isWhitespace { index += 1 }
    return index
  }

  private func previousWordStart() -> Int {
    let characters = Array(composer.text)
    var index = min(composer.cursor, characters.count)
    while index > 0, characters[index - 1].isWhitespace { index -= 1 }
    while index > 0, !characters[index - 1].isWhitespace { index -= 1 }
    return index
  }

  private func wordEnd() -> Int {
    let characters = Array(composer.text)
    guard !characters.isEmpty else { return 0 }
    var index = min(composer.cursor + 1, characters.count - 1)
    while index < characters.count - 1, characters[index].isWhitespace { index += 1 }
    while index < characters.count - 1, !characters[index + 1].isWhitespace { index += 1 }
    return index
  }

  private func lineRange() -> Range<Int> {
    let start = beginningOfLine()
    let end = endOfLine()
    return start..<(end < composer.text.count ? end + 1 : end)
  }

  private func moveVertical(by distance: Int) {
    let column = vimPreferredColumn ?? (composer.cursor - beginningOfLine())
    vimPreferredColumn = column
    if distance < 0 {
      let currentStart = beginningOfLine()
      guard currentStart > 0 else {
        composer.moveCursor(to: 0)
        return
      }
      let targetStart = beginningOfLine(at: currentStart - 1)
      let targetEnd = endOfLine(at: targetStart)
      composer.moveCursor(to: min(targetStart + column, max(targetStart, targetEnd - 1)))

    } else {
      let currentEnd = endOfLine()
      guard currentEnd < composer.text.count else {
        composer.moveCursor(to: max(0, composer.text.count - 1))
        return
      }
      let targetStart = currentEnd + 1
      let targetEnd = endOfLine(at: targetStart)
      composer.moveCursor(to: min(targetStart + column, max(targetStart, targetEnd - 1)))
    }
  }

  private func openLine(below: Bool) {
    let characters = Array(composer.text)
    let offset = below ? endOfLine() : beginningOfLine()
    let insertion = below && offset == characters.count ? "\n" : "\n"
    composer.moveCursor(to: offset)
    composer.insert(insertion)
    composer.moveCursor(to: below ? offset + 1 : offset)
    vimMode = .insert
  }

  private func handleVimOperator(_ operation: CodexVimOperator, key: Key) -> Bool {
    if key == .character("i") || key == .character("a") {
      vimPendingOperator = operation
      vimTextObjectAround = key == .character("a")
      return true
    }
    let range: Range<Int>
    switch key {
    case .character("d") where operation == .delete,
      .character("y") where operation == .yank,
      .character("c") where operation == .change:
      range = lineRange()
    case .character("w"):
      range = composer.cursor..<max(composer.cursor, nextWordStart())
    case .character("j"):
      let current = lineRange()
      let nextEnd =
        current.upperBound < composer.text.count
        ? endOfLine(at: current.upperBound) : current.upperBound
      range = current.lowerBound..<(nextEnd < composer.text.count ? nextEnd + 1 : nextEnd)
    case .character("k"):
      let current = lineRange()
      let previousStart =
        current.lowerBound > 0
        ? beginningOfLine(at: current.lowerBound - 1) : current.lowerBound
      range = previousStart..<current.upperBound
    case .character("$"), .end:
      range = composer.cursor..<endOfLine()
    case .character("0"), .home:
      range = beginningOfLine()..<composer.cursor
    default:
      return true
    }
    if operation == .yank {
      vimKillBuffer = substring(range)
      vimKillLinewise = key == .character("y") || key == .character("j") || key == .character("k")
    } else {
      kill(
        range,
        linewise: key == .character("d") || key == .character("c")
          || key == .character("j") || key == .character("k"))
      if operation == .change { vimMode = .insert }
    }
    return true
  }

  private func handleVimTextObject(
    _ operation: CodexVimOperator, around: Bool, key: Key
  ) -> Bool {
    guard let range = vimTextObjectRange(for: key, around: around) else { return true }
    if operation == .yank {
      vimKillBuffer = substring(range)
      vimKillLinewise = false
    } else {
      kill(range)
      if operation == .change { vimMode = .insert }
    }
    return true
  }

  private func vimTextObjectRange(for key: Key, around: Bool) -> Range<Int>? {
    let characters = Array(composer.text)
    guard !characters.isEmpty else { return nil }
    switch key {
    case .character("w"), .character("W"):
      let bigWord = key == .character("W")
      let belongs: (Character) -> Bool = { character in
        bigWord
          ? !character.isWhitespace
          : (character.isLetter || character.isNumber || character == "_")
      }
      var start = min(composer.cursor, characters.count - 1)
      while start < characters.count, !belongs(characters[start]) { start += 1 }
      guard start < characters.count else { return nil }
      while start > 0, belongs(characters[start - 1]) { start -= 1 }
      var end = start
      while end < characters.count, belongs(characters[end]) { end += 1 }
      if around {
        while end < characters.count, characters[end].isWhitespace { end += 1 }
        if end == start {
          while start > 0, characters[start - 1].isWhitespace { start -= 1 }
        }
      }
      return start..<end
    case .character("("), .character(")"), .character("b"):
      return pairedTextObject(characters, open: "(", close: ")", around: around)
    case .character("["), .character("]"):
      return pairedTextObject(characters, open: "[", close: "]", around: around)
    case .character("{"), .character("}"), .character("B"):
      return pairedTextObject(characters, open: "{", close: "}", around: around)
    case .character("\""), .character("'"), .character("`"):
      guard case .character(let delimiter) = key else { return nil }
      return quotedTextObject(characters, delimiter: delimiter, around: around)
    default:
      return nil
    }
  }

  private func pairedTextObject(
    _ characters: [Character], open: Character, close: Character, around: Bool
  ) -> Range<Int>? {
    let cursor = min(composer.cursor, characters.count - 1)
    guard
      let start = stride(from: cursor, through: 0, by: -1).first(where: { characters[$0] == open }),
      let end = (cursor..<characters.count).first(where: { characters[$0] == close }), start < end
    else { return nil }
    return around ? start..<(end + 1) : (start + 1)..<end
  }

  private func quotedTextObject(
    _ characters: [Character], delimiter: Character, around: Bool
  ) -> Range<Int>? {
    let cursor = min(composer.cursor, characters.count - 1)
    guard
      let start = stride(from: cursor, through: 0, by: -1).first(where: {
        characters[$0] == delimiter
      }),
      let end = ((start + 1)..<characters.count).first(where: { characters[$0] == delimiter }),
      cursor <= end
    else { return nil }
    return around ? start..<(end + 1) : (start + 1)..<end
  }

  private func substring(_ range: Range<Int>) -> String {
    let characters = Array(composer.text)
    let expanded = composer.rangeIncludingElements(range)
    return String(characters[expanded])
  }

  private func kill(_ range: Range<Int>, linewise: Bool = false) {
    let expanded = composer.rangeIncludingElements(range)
    guard !expanded.isEmpty else { return }
    vimKillBuffer = substring(expanded)
    vimKillLinewise = linewise
    composer.delete(expanded)
    composer.moveCursor(to: min(expanded.lowerBound, max(0, composer.text.count - 1)))
    composer.selectionAnchor = nil
  }

  private func pasteAfter() {
    guard !vimKillBuffer.isEmpty else { return }
    let characters = Array(composer.text)
    if vimKillLinewise {
      let lineEnd = endOfLine()
      let offset = lineEnd < characters.count ? lineEnd + 1 : lineEnd
      let insertion =
        lineEnd < characters.count
        ? (vimKillBuffer.hasSuffix("\n") ? vimKillBuffer : vimKillBuffer + "\n")
        : "\n" + vimKillBuffer.trimmingCharacters(in: .newlines)
      composer.moveCursor(to: offset)
      composer.insert(insertion)
      composer.moveCursor(to: min(offset, max(0, composer.text.count - 1)))
      return
    }
    let offset = min(characters.count, composer.cursor + (characters.isEmpty ? 0 : 1))
    composer.moveCursor(to: offset)
    composer.insert(vimKillBuffer)
    composer.moveCursor(to: min(max(0, composer.text.count - 1), offset + vimKillBuffer.count - 1))
  }

  public func addImageAttachment(_ attachment: CodexImageAttachment) {
    imageAttachments.append(attachment)
    selectedImageAttachmentIndex = nil
  }

  @discardableResult
  public func removeLastImageAttachment() -> CodexImageAttachment? {
    selectedImageAttachmentIndex = nil
    return imageAttachments.popLast()
  }

  @discardableResult
  public func removeSelectedImageAttachment() -> CodexImageAttachment? {
    guard let selectedImageAttachmentIndex,
      imageAttachments.indices.contains(selectedImageAttachmentIndex)
    else {
      self.selectedImageAttachmentIndex = nil
      return nil
    }
    let removed = imageAttachments.remove(at: selectedImageAttachmentIndex)
    self.selectedImageAttachmentIndex =
      imageAttachments.isEmpty
      ? nil : min(selectedImageAttachmentIndex, imageAttachments.count - 1)
    return removed
  }

  @discardableResult
  public func handleComposerEvent(_ event: TerminalEvent) -> Bool {
    guard case .paste(let pasted) = event else { return composer.handle(event) }
    let normalized = pasted.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    let count = normalized.count
    guard count > 1_000 else { return composer.handle(.paste(normalized)) }
    let activeElementIDs = Set(composer.elements.map(\.id))
    pendingPastes.removeAll { !activeElementIDs.contains($0.id) }
    let base = "[Pasted Content \(count) chars]"
    let matching = pendingPastes.count {
      $0.placeholder == base || $0.placeholder.hasPrefix("\(base) #")
    }
    let placeholder = matching == 0 ? base : "\(base) #\(matching + 1)"
    let id = TextFieldElementID("paste-\(UUID().uuidString)")
    pendingPastes.append((id, placeholder, normalized))
    composer.insertElement(placeholder, id: id)
    return true
  }

  public func recallHistory(previous: Bool) {
    guard !history.isEmpty else { return }
    let index: Int
    if previous {
      index = max(0, (historyIndex ?? history.count) - 1)
    } else {
      index = min(history.count, (historyIndex ?? history.count - 1) + 1)
    }
    historyIndex = index == history.count ? nil : index
    composer = TextFieldState(text: index == history.count ? "" : history[index])
  }
}
