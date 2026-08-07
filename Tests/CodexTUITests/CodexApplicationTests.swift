import Foundation
import KWWKAgent
import Ratatui
import RatatuiSyntaxHighlighting
import Testing

@testable import CodexTUI

@MainActor
@Suite struct CodexApplicationTests {
  private func historyInsertions(
    from application: CodexApplication, size: Size,
    runtime: inout InlineDocumentRuntime<String>
  ) -> [TerminalHistoryInsertion] {
    guard let document = application.inlineDocument(size: size) else { return [] }
    return runtime.reconcile(document, width: size.width)
  }

  @Test func slashDiscoveryDoesNotAdvertiseDisconnectedWorkflows() {
    let names = Set(CodexSlashCommand.builtins.map(\.name))
    #expect(!names.contains("apps"))
    #expect(!names.contains("plugins"))
    #expect(!names.contains("logout"))
  }

  private actor SavedTheme {
    var name: String?
    func set(_ name: String) { self.name = name }
  }
  private actor SavedRawMode {
    var enabled: Bool?
    func set(_ enabled: Bool) { self.enabled = enabled }
  }
  private actor SavedKeymap {
    var configuration: CodexKeymapConfiguration?
    func set(_ configuration: CodexKeymapConfiguration) { self.configuration = configuration }
  }
  private final class Driver: CodexConversationDriving {
    var isRunning = false
    var availableModels: [CodexModelOption] = []
    var availableReasoningOptions: [String: [CodexReasoningOption]] = [:]
    var selectedModel: String?
    var selectedReasoning: String?
    var selectedPermission: CodexPermissionMode?
    var selectedPersonality: CodexPersonality?
    var savedSessions: [CodexSessionSummary] = []
    var activatedSession: (id: String, fork: Bool)?
    var archived = false
    var deleted = false
    var renamed: String?
    var submitted: [String] = []
    var submittedImages: [[CodexImageAttachment]] = []
    var selectedMode: CodexMode?
    var goalCommands: [String] = []
    var sidePrompts: [String?] = []
    var returnedFromSide = false
    var sideToggleCount = 0
    var sideCloseCount = 0
    var threadSummaries: [AgentThreadSummary] = []
    var tasks: [BackgroundTaskSummary] = []
    var stoppedTaskCount = 0
    var remainingPercent: Int?
    var availableSkills: [SkillSummary] = []
    var runtimeCommands: [(String, String)] = []
    var queuedEdit: String?
    var replacedDrafts: [String] = []
    var retried = false
    var rewindItems: [RewindCandidate] = []
    var rewoundID: Int?
    var rewindDraft = RewindDraft(text: "")
    var interruptCount = 0

    func submit(_ text: String) { submitted.append(text) }
    func submit(_ text: String, images: [CodexImageAttachment]) {
      submitted.append(text)
      submittedImages.append(images)
    }
    func steer(_ text: String) {}
    func followUp(_ text: String) {}
    func interrupt() { interruptCount += 1 }
    func selectModel(id: String) { selectedModel = id }
    func selectModel(id: String, reasoningID: String) {
      selectedModel = id
      selectedReasoning = reasoningID
    }
    func reasoningOptions(modelID: String) -> [CodexReasoningOption] {
      availableReasoningOptions[modelID] ?? []
    }
    func selectReasoning(_ id: String) { selectedReasoning = id }
    func selectPermissionMode(_ mode: CodexPermissionMode) { selectedPermission = mode }
    func selectPersonality(_ personality: CodexPersonality) { selectedPersonality = personality }
    func selectMode(_ mode: CodexMode) { selectedMode = mode }
    func sessions() async -> [CodexSessionSummary] { savedSessions }
    func activateSession(id: String, fork: Bool) async throws {
      activatedSession = (id, fork)
    }
    func renameSession(_ title: String) async throws { renamed = title }
    func archiveSession() async throws { archived = true }
    func deleteSession() async throws { deleted = true }
    func goalCommand(_ command: String) { goalCommands.append(command) }
    func startSideConversation(prompt: String?) async throws { sidePrompts.append(prompt) }
    func toggleSideConversation() async { sideToggleCount += 1 }
    func closeSideConversation() async { sideCloseCount += 1 }
    func returnFromSideConversation() async { returnedFromSide = true }
    func agentThreads() async -> [AgentThreadSummary] { threadSummaries }
    func backgroundTasks() async -> [BackgroundTaskSummary] { tasks }
    func stopBackgroundTasks() async -> Int { stoppedTaskCount }
    func usageSummary() -> String { "Usage: 10 input · 2 output" }
    func contextRemainingPercent() -> Int? { remainingPercent }
    func skills() -> [SkillSummary] { availableSkills }
    func runtimeCommand(_ name: String, arguments: String) -> String {
      runtimeCommands.append((name, arguments))
      return "runtime: \(name) \(arguments)"
    }
    func dequeueQueuedMessage(replacing draft: String) -> String? {
      replacedDrafts.append(draft)
      return queuedEdit
    }
    func retryLastPrompt() -> Bool {
      retried = true
      return true
    }
    func rewindCandidates() -> [RewindCandidate] { rewindItems }
    func rewind(to candidateID: Int) async throws -> RewindDraft {
      rewoundID = candidateID
      return rewindDraft
    }
  }

  @Test func retryAndRewindUseKwwkSessionOperations() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(composer: TextFieldState(text: "/retry")))
    let driver = Driver()
    driver.rewindItems = [
      RewindCandidate(id: 2, preview: "first prompt"),
      RewindCandidate(id: 7, preview: "latest prompt"),
    ]
    driver.rewindDraft = RewindDraft(
      text: "latest prompt",
      images: [CodexImageAttachment(data: Data([1]), mimeType: "image/png", name: "image.png")])
    let application = CodexApplication(model: model, driver: driver)

    #expect(await application.update(.key(KeyEvent(.enter))) == .redraw)
    #expect(driver.retried)

    model.composer = TextFieldState(text: "/rewind")
    #expect(await application.update(.key(KeyEvent(.enter))) == .redraw)
    guard case .rewind(let picker) = model.overlay else {
      Issue.record("Expected rewind picker")
      return
    }
    #expect(picker.selectedIndex == 1)

    #expect(await application.update(.key(KeyEvent(.enter))) == .redraw)
    #expect(driver.rewoundID == 7)
    #expect(model.composer.text == "latest prompt")
    #expect(model.imageAttachments.count == 1)
    #expect(model.overlay == nil)
  }

  @Test func rawCommandAndOptionRMatchUpstreamToggleSemantics() async {
    let saved = SavedRawMode()
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(composer: TextFieldState(text: "/raw")))
    let services = CodexSystemServices(
      gitDiff: { _ in "" }, copyToClipboard: { _ in },
      saveRawOutputMode: { await saved.set($0) })
    let application = CodexApplication(model: model, driver: Driver(), systemServices: services)

    #expect(await application.update(.key(KeyEvent(.enter))) == .redraw)
    #expect(model.rawOutputMode)
    #expect(await saved.enabled == true)
    guard case .notice(let notice) = model.entries.last?.content else {
      Issue.record("Expected raw mode notice")
      return
    }
    #expect(notice == "Raw output mode on: transcript text is shown for clean terminal selection.")

    let entryCount = model.entries.count
    #expect(
      await application.update(.key(KeyEvent(.character("r"), modifiers: [.option]))) == .redraw)
    #expect(!model.rawOutputMode)
    #expect(await saved.enabled == false)
    #expect(model.entries.count == entryCount)

    model.composer = TextFieldState(text: "/raw sideways")
    _ = await application.update(.key(KeyEvent(.enter)))
    #expect(model.entries.last?.content == .error("Usage: /raw [on|off]"))
  }

  @Test func vimCommandEnablesARealModalComposer() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(composer: TextFieldState(text: "/vim")))
    let application = CodexApplication(model: model, driver: Driver(), systemServices: .disabled)

    #expect(await application.update(.key(KeyEvent(.enter))) == .redraw)
    #expect(model.vimEnabled)
    #expect(model.vimMode == .normal)
    #expect(model.entries.last?.content == .notice("Vim mode enabled."))

    model.composer = TextFieldState(text: "one two", cursor: 0)
    _ = await application.update(.key(KeyEvent(.character("w"))))
    #expect(model.composer.cursor == 4)
    _ = await application.update(.key(KeyEvent(.character("d"))))
    _ = await application.update(.key(KeyEvent(.character("w"))))
    #expect(model.composer.text == "one ")
    #expect(model.vimMode == .normal)

    _ = await application.update(.key(KeyEvent(.character("i"))))
    #expect(model.vimMode == .insert)
    _ = await application.update(.key(KeyEvent(.character("X"))))
    #expect(model.composer.text == "oneX ")
    _ = await application.update(.key(KeyEvent(.escape)))
    #expect(model.vimMode == .normal)
    #expect(model.composer.cursor == 3)
  }

  @Test func vimMultilineMotionsOpenLinesAndLinewisePasteMatchUpstream() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(
        vimEnabled: true, vimMode: .normal,
        composer: TextFieldState(text: "aa\nbbbb\nc", cursor: 1)))
    let application = CodexApplication(model: model, driver: Driver(), systemServices: .disabled)

    _ = await application.update(.key(KeyEvent(.character("j"))))
    #expect(model.composer.cursor == 4)
    _ = await application.update(.key(KeyEvent(.character("j"))))
    #expect(model.composer.cursor == 8)
    _ = await application.update(.key(KeyEvent(.character("k"))))
    #expect(model.composer.cursor == 4)

    _ = await application.update(.key(KeyEvent(.character("y"))))
    _ = await application.update(.key(KeyEvent(.character("y"))))
    _ = await application.update(.key(KeyEvent(.character("p"))))
    #expect(model.composer.text == "aa\nbbbb\nbbbb\nc")
    #expect(model.composer.cursor == 8)

    _ = await application.update(.key(KeyEvent(.character("o"))))
    #expect(model.vimMode == .insert)
    #expect(model.composer.text == "aa\nbbbb\nbbbb\n\nc")
    _ = await application.update(.key(KeyEvent(.escape)))
    _ = await application.update(.key(KeyEvent(.character("O"))))
    #expect(model.vimMode == .insert)
    #expect(model.composer.text == "aa\nbbbb\nbbbb\n\n\nc")
  }

  @Test func vimInnerAndAroundTextObjectsApplyPendingOperators() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(
        vimEnabled: true, vimMode: .normal,
        composer: TextFieldState(text: "call(alpha beta) tail", cursor: 7)))
    let application = CodexApplication(model: model, driver: Driver(), systemServices: .disabled)

    for key in ["d", "i", "w"] {
      _ = await application.update(.key(KeyEvent(.character(Character(key)))))
    }
    #expect(model.composer.text == "call( beta) tail")
    #expect(model.vimMode == .normal)

    model.composer = TextFieldState(text: "call(alpha beta) tail", cursor: 7)
    for key in ["c", "i", "("] {
      _ = await application.update(.key(KeyEvent(.character(Character(key)))))
    }
    #expect(model.composer.text == "call() tail")
    #expect(model.vimMode == .insert)

    model.vimMode = .normal
    model.composer = TextFieldState(text: "say \"hello world\" now", cursor: 8)
    for key in ["d", "a", "\""] {
      _ = await application.update(.key(KeyEvent(.character(Character(key)))))
    }
    #expect(model.composer.text == "say  now")
  }

  @Test func bangCommandUsesKwwkShellWithoutSubmittingToTheAgent() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(
        directory: "/tmp/project", composer: TextFieldState(text: "!printf hello")))
    let driver = Driver()
    let services = CodexSystemServices(
      gitDiff: { _ in "" }, copyToClipboard: { _ in },
      localShell: { command, directory in
        #expect(command == "printf hello")
        #expect(directory == "/tmp/project")
        return BashExecutionResult(stdout: "hello", stderr: "warning", exitCode: 0)
      })
    let application = CodexApplication(model: model, driver: driver, systemServices: services)

    #expect(await application.update(.key(KeyEvent(.enter))) == .redraw)
    #expect(driver.submitted.isEmpty)
    #expect(!model.isWorking)
    guard case .tool(let activity) = model.entries.last?.content,
      case .command(let command, let output, 0) = activity.presentation
    else {
      Issue.record("Expected completed local command cell")
      return
    }
    #expect(command == "printf hello")
    #expect(output == ["hello", "warning"])
    #expect(activity.status == .succeeded)
  }

  @Test func localShellCompletionPreservesAnActiveAgentTurn() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(
        directory: "/tmp/project", composer: TextFieldState(text: "!pwd"),
        isWorking: true, workingLabel: "Working"))
    let driver = Driver()
    driver.isRunning = true
    let services = CodexSystemServices(
      gitDiff: { _ in "" }, copyToClipboard: { _ in },
      localShell: { _, _ in
        BashExecutionResult(stdout: "/tmp/project", stderr: "", exitCode: 0)
      })
    let application = CodexApplication(model: model, driver: driver, systemServices: services)

    #expect(await application.update(.key(KeyEvent(.enter))) == .redraw)
    #expect(model.isWorking)
    #expect(model.workingLabel == "Working")

    #expect(await application.update(.key(KeyEvent(.escape))) == .redraw)
    #expect(driver.interruptCount == 1)
  }

  @Test func fullAccessRequiresASecondExplicitConfirmation() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(
        overlay: .permissions(PermissionPicker(selectedIndex: 1))))
    let driver = Driver()
    let application = CodexApplication(model: model, driver: driver)

    #expect(await application.update(.key(KeyEvent(.enter))) == .redraw)
    #expect(driver.selectedPermission == nil)
    guard case .permissions(let confirmation) = model.overlay else {
      Issue.record("Expected full-access confirmation")
      return
    }
    #expect(confirmation.confirmingFullAccess)
    #expect(confirmation.selectedIndex == 0)

    #expect(await application.update(.key(KeyEvent(.enter))) == .redraw)
    #expect(driver.selectedPermission == .fullAccess)
    #expect(model.overlay == nil)
  }

  @Test func modelPickerFiltersAcrossProviderIDAndNameBeforeSelection() async {
    let models = [
      CodexModelOption(
        id: "openai::gpt", modelID: "gpt", name: "GPT", provider: "openai",
        contextWindow: 100_000, supportsReasoning: false),
      CodexModelOption(
        id: "anthropic::claude", modelID: "claude", name: "Claude Sonnet",
        provider: "anthropic", contextWindow: 200_000, supportsReasoning: false),
    ]
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(overlay: .models(ModelPicker(models: models))))
    let driver = Driver()
    driver.availableModels = models
    let application = CodexApplication(model: model, driver: driver)

    for character in "anthropic sonnet" {
      _ = await application.update(.key(KeyEvent(.character(character))))
    }
    guard case .models(let picker) = model.overlay else {
      Issue.record("Expected filtered model picker")
      return
    }
    #expect(picker.filteredModels.map(\.id) == ["anthropic::claude"])
    _ = await application.update(.key(KeyEvent(.enter)))
    #expect(driver.selectedModel == "anthropic::claude")
  }

  @Test func reasoningSelectionUpdatesTheRuntimeDriver() async {
    let picker = ReasoningPicker(
      modelID: "openai::gpt-5.6-sol",
      modelName: "gpt-5.6-sol",
      options: [
        CodexReasoningOption(id: "medium", label: "Medium", description: "Balanced"),
        CodexReasoningOption(id: "high", label: "High", description: "Deep"),
      ],
      selectedIndex: 1)
    let model = CodexSessionModel(snapshot: CodexSnapshot(overlay: .reasoning(picker)))
    let driver = Driver()
    let application = CodexApplication(model: model, driver: driver)

    #expect(await application.update(.key(KeyEvent(.enter))) == .redraw)
    #expect(driver.selectedModel == "openai::gpt-5.6-sol")
    #expect(driver.selectedReasoning == "high")
    #expect(model.overlay == nil)
  }

  @Test func cancellingReasoningDoesNotCommitTheCandidateModel() async {
    let candidate = CodexModelOption(
      id: "openai::candidate", modelID: "candidate", name: "Candidate", provider: "openai",
      contextWindow: 100_000, supportsReasoning: true)
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(overlay: .models(ModelPicker(models: [candidate]))))
    let driver = Driver()
    driver.availableModels = [candidate]
    driver.availableReasoningOptions[candidate.id] = [
      CodexReasoningOption(id: "medium", label: "Medium", description: "Balanced")
    ]
    let application = CodexApplication(model: model, driver: driver)

    #expect(await application.update(.key(KeyEvent(.enter))) == .redraw)
    #expect(driver.selectedModel == nil)
    guard case .reasoning = model.overlay else {
      Issue.record("Expected reasoning confirmation")
      return
    }

    #expect(await application.update(.key(KeyEvent(.escape))) == .redraw)
    #expect(driver.selectedModel == nil)
    #expect(driver.selectedReasoning == nil)
  }

  @Test func activeTurnSettingChangesRemainOpenWithAnExplicitRejection() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(overlay: .personality(PersonalityPicker(selectedIndex: 1))))
    let driver = Driver()
    driver.isRunning = true
    let application = CodexApplication(model: model, driver: driver)

    #expect(await application.update(.key(KeyEvent(.enter))) == .redraw)
    #expect(driver.selectedPersonality == nil)
    #expect(model.overlay == .personality(PersonalityPicker(selectedIndex: 1)))
    #expect(model.rightStatus == "Finish the active turn before changing settings")
  }

  @Test func personalitySelectionUpdatesTheRuntimeDriver() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(overlay: .personality(PersonalityPicker(selectedIndex: 1))))
    let driver = Driver()
    let application = CodexApplication(model: model, driver: driver)

    #expect(await application.update(.key(KeyEvent(.enter))) == .redraw)
    #expect(driver.selectedPersonality == .pragmatic)
    #expect(model.overlay == nil)
  }

  @Test func themePickerPreviewsRestoresAndPersistsSelection() async {
    let themes = [SyntaxTheme.named("base16-ocean-dark")!, SyntaxTheme.named("dracula")!]
    let saved = SavedTheme()
    let services = CodexSystemServices(
      gitDiff: { _ in "" }, copyToClipboard: { _ in },
      syntaxThemes: { themes },
      saveSyntaxTheme: { await saved.set($0) })
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(
        syntaxTheme: themes[0], composer: TextFieldState(text: "/theme")))
    let application = CodexApplication(model: model, driver: Driver(), systemServices: services)

    #expect(await application.update(.key(KeyEvent(.enter))) == .redraw)
    #expect(await application.update(.key(KeyEvent(.down))) == .redraw)
    #expect(model.syntaxTheme.name == "dracula")
    #expect(await application.update(.key(KeyEvent(.escape))) == .redraw)
    #expect(model.syntaxTheme.name == "base16-ocean-dark")

    model.composer = TextFieldState(text: "/theme")
    _ = await application.update(.key(KeyEvent(.enter)))
    _ = await application.update(.key(KeyEvent(.down)))
    _ = await application.update(.key(KeyEvent(.enter)))
    #expect(model.overlay == nil)
    #expect(await saved.name == "dracula")
  }

  @Test func resumePickerFiltersAndActivatesTheSelectedSession() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(directory: "/tmp/project", composer: TextFieldState(text: "/resume")))
    let driver = Driver()
    driver.savedSessions = [
      CodexSessionSummary(
        id: "one", title: "Fix renderer", directory: "/tmp/project", createdAt: 1,
        updatedAt: 2, messageCount: 4),
      CodexSessionSummary(
        id: "two", title: "Named thread", directory: "/tmp/project", createdAt: 1,
        updatedAt: 3, messageCount: 2),
    ]
    let application = CodexApplication(model: model, driver: driver)

    #expect(await application.update(.key(KeyEvent(.enter))) == .redraw)
    guard case .sessions(let initial) = model.overlay else {
      Issue.record("Expected session picker")
      return
    }
    #expect(initial.filteredSessions.count == 2)

    for character in "named" {
      _ = await application.update(.key(KeyEvent(.character(character))))
    }
    _ = await application.update(.key(KeyEvent(.enter)))
    #expect(driver.activatedSession?.id == "two")
    #expect(driver.activatedSession?.fork == false)
    #expect(model.overlay == nil)
  }

  @Test func forkImmediatelyForksTheCurrentSession() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(composer: TextFieldState(text: "/fork copied work")))
    model.sessionID = "current-thread"
    let driver = Driver()
    let application = CodexApplication(model: model, driver: driver, systemServices: .disabled)

    _ = await application.update(.key(KeyEvent(.enter)))

    #expect(driver.activatedSession?.id == "current-thread")
    #expect(driver.activatedSession?.fork == true)
    #expect(driver.renamed == "copied work")
    #expect(model.overlay == nil)
  }

  @Test func reverseSearchRestoresOrAcceptsComposerHistory() async {
    let model = CodexSessionModel()
    model.history = ["first request", "fix renderer", "last request"]
    model.composer = TextFieldState(text: "draft")
    let application = CodexApplication(model: model, driver: Driver())

    _ = await application.update(.key(KeyEvent(.character("r"), modifiers: [.control])))
    for character in "fix" {
      _ = await application.update(.key(KeyEvent(.character(character))))
    }
    _ = await application.update(.key(KeyEvent(.enter)))
    #expect(model.composer.text == "fix renderer")

    _ = await application.update(.key(KeyEvent(.character("r"), modifiers: [.control])))
    _ = await application.update(.key(KeyEvent(.escape)))
    #expect(model.composer.text == "fix renderer")
  }

  @Test func destructiveSessionActionsRequireExplicitConfirmation() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(composer: TextFieldState(text: "/archive")))
    let driver = Driver()
    let application = CodexApplication(model: model, driver: driver)

    _ = await application.update(.key(KeyEvent(.enter)))
    #expect(driver.archived == false)
    _ = await application.update(.key(KeyEvent(.down)))
    #expect(await application.update(.key(KeyEvent(.enter))) == .quit)
    #expect(driver.archived)
  }

  @Test func escapeBacktrackPreviewsStepsAndRewindsThroughKwwk() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(
        entries: [
          TranscriptEntry(content: .user("first prompt")),
          TranscriptEntry(content: .assistant("first answer", streaming: false)),
          TranscriptEntry(content: .user("latest prompt")),
          TranscriptEntry(content: .assistant("latest answer", streaming: false)),
        ], showHeader: false))
    model.vimEnabled = true
    model.vimMode = .normal
    let driver = Driver()
    driver.rewindItems = [
      RewindCandidate(id: 2, preview: "first prompt"),
      RewindCandidate(id: 7, preview: "latest prompt"),
    ]
    driver.rewindDraft = RewindDraft(text: "first prompt")
    let application = CodexApplication(model: model, driver: driver, systemServices: .disabled)

    #expect(await application.update(.key(KeyEvent(.escape))) == .redraw)
    #expect(model.overlay == nil)
    #expect(model.rightStatus == "esc again to rewind")
    #expect(await application.update(.key(KeyEvent(.escape))) == .redraw)
    guard case .transcript(let latest) = model.overlay else {
      Issue.record("Expected backtrack transcript preview")
      return
    }
    #expect(latest.selectedBacktrackIndex == 1)

    _ = await application.update(.key(KeyEvent(.escape)))
    guard case .transcript(let older) = model.overlay else { return }
    #expect(older.selectedBacktrackIndex == 0)
    _ = await application.update(.key(KeyEvent(.enter)))

    #expect(driver.rewoundID == 2)
    #expect(model.composer.text == "first prompt")
    #expect(model.overlay == nil)
  }

  @Test func reviewPickerRunsTheSelectedReviewAndPlanChangesTheDriverMode() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(composer: TextFieldState(text: "/review")))
    let driver = Driver()
    let application = CodexApplication(model: model, driver: driver, systemServices: .disabled)

    _ = await application.update(.key(KeyEvent(.enter)))
    _ = await application.update(.key(KeyEvent(.down)))
    _ = await application.update(.key(KeyEvent(.enter)))
    #expect(driver.submitted.last?.contains("uncommitted changes") == true)

    model.composer = TextFieldState(text: "/plan investigate resize")
    _ = await application.update(.key(KeyEvent(.enter)))
    #expect(driver.selectedMode == .plan)
    #expect(driver.submitted.last == "investigate resize")
  }

  @Test func stableStreamingSourceMovesIntoInlineHistoryWithoutLeavingTheLiveTailBehind() {
    var stream = CodexStreamingMarkdown()
    stream.update(fullSource: "first committed line\nsecond unfinished")
    let user = TranscriptEntry(id: "user", content: .user("write a poem"))
    let assistant = TranscriptEntry(
      id: "assistant", content: .assistant(stream.visibleSource, streaming: true),
      streamingMarkdown: stream)
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(entries: [user, assistant], showHeader: true))
    let application = CodexApplication(model: model, driver: Driver(), systemServices: .disabled)
    var runtime = InlineDocumentRuntime<String>()

    let inserted = historyInsertions(
      from: application, size: Size(width: 80, height: 24), runtime: &runtime)
    let insertedText = inserted.flatMap(\.text.lines).flatMap(\.spans).map(\.content).joined()
    #expect(insertedText.contains("write a poem"))
    #expect(insertedText.contains("first committed line"))
    #expect(!insertedText.contains("second unfinished"))
    #expect(!application.body.snapshot.showHeader)
    #expect(application.body.snapshot.entries.count == 1)
    guard case .assistant(let liveTail, true) = application.body.snapshot.entries.first?.content
    else {
      Issue.record("Expected only the uncommitted streaming tail in the retained viewport")
      return
    }
    #expect(liveTail.isEmpty)

    stream.update(fullSource: "first committed line\nsecond committed line\n")
    model.entries[1].content = .assistant(stream.visibleSource, streaming: true)
    model.entries[1].streamingMarkdown = stream
    let continuation = historyInsertions(
      from: application, size: Size(width: 80, height: 24), runtime: &runtime)
    let continuationText = continuation.flatMap(\.text.lines).flatMap(\.spans).map(\.content)
      .joined()
    #expect(continuationText.contains("second committed line"))
    #expect(!continuationText.contains("first committed line"))

    let reflowed = historyInsertions(
      from: application, size: Size(width: 40, height: 24), runtime: &runtime)
    #expect(reflowed.first?.resetsScrollback == true)
    let reflowedText = reflowed.flatMap(\.text.lines).flatMap(\.spans).map(\.content).joined()
    #expect(reflowedText.contains("write a poem"))
    #expect(reflowedText.contains("first committed line"))
    #expect(reflowedText.contains("second committed line"))

    let heightReflow = historyInsertions(
      from: application, size: Size(width: 40, height: 30), runtime: &runtime)
    #expect(heightReflow.isEmpty)

    var rewrittenStream = CodexStreamingMarkdown()
    rewrittenStream.update(fullSource: "replacement canonical line\n")
    model.entries[1].content = .assistant(rewrittenStream.visibleSource, streaming: true)
    model.entries[1].streamingMarkdown = rewrittenStream
    let rewritten = historyInsertions(
      from: application, size: Size(width: 40, height: 30), runtime: &runtime)
    #expect(rewritten.first?.resetsScrollback == true)
    let rewrittenText = rewritten.flatMap(\.text.lines).flatMap(\.spans).map(\.content).joined()
    #expect(rewrittenText.contains("replacement canonical line"))
    #expect(!rewrittenText.contains("first committed line"))
  }

  @Test func completingDemoToolAppendsHistoryWithoutResettingTheTerminal() {
    let responseID = "response"
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(
        entries: [
          TranscriptEntry(id: "user", content: .user("inspect")),
          TranscriptEntry(
            id: "\(responseID)-reasoning",
            content: .reasoning(
              summary: "Inspecting the request", body: nil, streaming: true)),
        ],
        showHeader: false
      ))
    let application = CodexApplication(model: model, driver: Driver(), systemServices: .disabled)
    var runtime = InlineDocumentRuntime<String>()
    let size = Size(width: 100, height: 30)

    let initial = historyInsertions(from: application, size: size, runtime: &runtime)
    #expect(!initial.contains { $0.resetsScrollback })
    let initialText = initial.flatMap(\.text.lines).flatMap(\.spans).map(\.content).joined()
    #expect(!initialText.contains("Inspecting the request"))

    model.entries[1].content = .reasoning(
      summary: "Inspecting the request", body: nil, streaming: false)
    model.entries.append(
      TranscriptEntry(
        id: "tool-\(responseID)",
        content: .tool(
          ToolActivity(
            callID: responseID,
            name: "Searched",
            detail: "the workspace",
            status: .running,
            presentation: .exploration(
              ExplorationAction(kind: .search, subject: "the workspace")
            )
          ))))
    let running = historyInsertions(from: application, size: size, runtime: &runtime)
    #expect(!running.contains { $0.resetsScrollback })
    let runningText = running.flatMap(\.text.lines).flatMap(\.spans).map(\.content).joined()
    #expect(runningText.contains("Inspecting the request"))

    model.entries[2].content = .tool(
      ToolActivity(
        callID: responseID,
        name: "Searched",
        detail: "the workspace",
        output: ["Found the relevant Swift package"],
        status: .succeeded,
        durationMilliseconds: 700,
        presentation: .exploration(
          ExplorationAction(kind: .search, subject: "the workspace")
        )
      ))
    let completed = historyInsertions(from: application, size: size, runtime: &runtime)
    #expect(!completed.contains { $0.resetsScrollback })
    let completedText = completed.flatMap(\.text.lines).flatMap(\.spans).map(\.content).joined()
    #expect(completedText.contains("Explored"))
    #expect(completedText.contains("Search the workspace"))
  }

  @Test func completedReasoningDoesNotBlockStableAssistantRowsDuringTheSameTurn() {
    var assistantStream = CodexStreamingMarkdown()
    assistantStream.update(fullSource: "section one\nsection two\nunfinished")
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(
        entries: [
          TranscriptEntry(
            id: "reasoning",
            content: .reasoning(summary: "Thinking", body: "finished thought", streaming: false)),
          TranscriptEntry(
            id: "assistant",
            content: .assistant(assistantStream.visibleSource, streaming: true),
            streamingMarkdown: assistantStream),
        ], showHeader: false))
    let application = CodexApplication(model: model, driver: Driver(), systemServices: .disabled)
    var runtime = InlineDocumentRuntime<String>()

    let inserted = historyInsertions(
      from: application, size: Size(width: 80, height: 24), runtime: &runtime)
    let text = inserted.flatMap(\.text.lines).flatMap(\.spans).map(\.content).joined()
    #expect(text.contains("finished thought"))
    #expect(text.contains("section one"))
    #expect(text.contains("section two"))
    #expect(!text.contains("unfinished"))
  }

  @Test func stableReasoningSourceAlsoLeavesTheMutableViewportIncrementally() {
    var stream = CodexStreamingMarkdown()
    stream.update(fullSource: "first thought\nunfinished thought")
    let reasoning = TranscriptEntry(
      id: "reasoning",
      content: .reasoning(summary: "Thinking", body: stream.visibleSource, streaming: true),
      streamingMarkdown: stream)
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(entries: [reasoning], showHeader: false))
    let application = CodexApplication(model: model, driver: Driver(), systemServices: .disabled)
    var runtime = InlineDocumentRuntime<String>()

    let inserted = historyInsertions(
      from: application, size: Size(width: 80, height: 24), runtime: &runtime)
    let text = inserted.flatMap(\.text.lines).flatMap(\.spans).map(\.content).joined()
    #expect(text.contains("first thought"))
    #expect(!text.contains("unfinished thought"))
    guard case .reasoning(_, let body, true) = application.body.snapshot.entries.first?.content
    else {
      Issue.record("Expected a retained mutable reasoning tail")
      return
    }
    #expect(body?.isEmpty == true)
  }

  @Test func heightOnlyResizeDoesNotReplayOrDuplicateNativeHistory() {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(
        entries: [TranscriptEntry(id: "notice", content: .notice("committed"))],
        showHeader: false))
    let application = CodexApplication(model: model, driver: Driver(), systemServices: .disabled)
    var runtime = InlineDocumentRuntime<String>()

    #expect(
      !historyInsertions(
        from: application, size: Size(width: 80, height: 24), runtime: &runtime
      ).isEmpty)
    #expect(
      historyInsertions(
        from: application, size: Size(width: 80, height: 48), runtime: &runtime
      ).isEmpty)
    #expect(
      historyInsertions(from: application, size: Size(width: 60, height: 48), runtime: &runtime)
        .first?
        .resetsScrollback == true)
  }

  @Test func initialLargeResumeReplaysOnlyTheRecentTerminalRowBudget() {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(
        entries: CodexLargeSessionFixture.makeEntries(turns: 100), showHeader: false))
    let application = CodexApplication(model: model, driver: Driver(), systemServices: .disabled)
    let size = Size(width: 80, height: 24)
    guard let initial = application.inlineDocument(size: size) else {
      Issue.record("Expected inline history")
      return
    }

    #expect(initial.blocks.flatMap(\.text.lines).count == 1_000)
    #expect(initial.blocks.last?.id == "fixture-assistant-100")
    #expect(initial.blocks.first?.id != "fixture-user-1")

    var runtime = InlineDocumentRuntime<String>()
    _ = runtime.reconcile(initial, width: size.width)
    model.entries.append(TranscriptEntry(id: "after-resume", content: .notice("new live row")))
    let appended = application.inlineDocument(size: size)!
    #expect(appended.blocks.first?.id == initial.blocks.first?.id)
    let insertion = runtime.reconcile(appended, width: size.width)
    #expect(insertion.first?.resetsScrollback != true)
    #expect(
      insertion.flatMap(\.text.lines).flatMap(\.spans).map(\.content).joined().contains(
        "new live row"))
  }

  @Test func transcriptPagerReusesCommittedRenderCacheForLargeIdleSessions() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(
        entries: CodexLargeSessionFixture.makeEntries(turns: 100), showHeader: false))
    let application = CodexApplication(model: model, driver: Driver(), systemServices: .disabled)
    _ = application.inlineDocument(size: Size(width: 80, height: 24))

    _ = await application.update(.key(KeyEvent(.character("t"), modifiers: [.control])))
    guard case .transcript(let pager) = model.overlay else {
      Issue.record("Expected transcript pager")
      return
    }
    #expect(pager.cachedWidth == 80)
    #expect(pager.cachedTranscriptLines?.isEmpty == false)
    #expect(application.body.snapshot.entries.isEmpty)

    _ = await application.update(.resize(Size(width: 64, height: 24)))
    guard case .transcript(let resizedPager) = model.overlay else {
      Issue.record("Expected transcript pager after resize")
      return
    }
    #expect(resizedPager.cachedWidth == 64)
    #expect(resizedPager.cachedTranscriptLines?.isEmpty == false)
  }

  @Test func ordinaryOverlaysDoNotRepaintCommittedNativeHistoryIntoTheLiveViewport() {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(
        entries: CodexLargeSessionFixture.makeEntries(turns: 20),
        overlay: .fileMentions(FileMentionPicker(files: ["Package.swift"])),
        showHeader: false))
    let application = CodexApplication(model: model, driver: Driver(), systemServices: .disabled)

    #expect(application.body.snapshot.entries.isEmpty)
    guard case .fileMentions = application.body.snapshot.overlay else {
      Issue.record("Expected the file mention overlay to remain presented")
      return
    }

    model.overlay = .transcript(CodexTranscriptPager())
    #expect(application.body.snapshot.entries.count == model.entries.count)
  }

  @Test func inlineDocumentRevisionChangesOnlyWithSemanticTranscriptMutations() {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(
        entries: [TranscriptEntry(id: "notice", content: .notice("committed"))],
        showHeader: false))
    let application = CodexApplication(model: model, driver: Driver(), systemServices: .disabled)
    let size = Size(width: 80, height: 24)

    let initial = application.inlineDocument(size: size)
    model.composer.text = "local draft"
    #expect(application.inlineDocument(size: size)?.revision == initial?.revision)

    model.entries.append(TranscriptEntry(id: "next", content: .notice("next")))
    let appended = application.inlineDocument(size: size)
    #expect(appended?.revision != initial?.revision)
    #expect(appended?.blocks.count == 2)

    model.entries[1].content = .notice("updated")
    let updated = application.inlineDocument(size: size)
    #expect(updated?.revision != appended?.revision)
    #expect(
      updated?.blocks[1].text.lines.flatMap(\.spans).map(\.content).joined().contains("updated")
        == true)
  }

  @Test func historyRebuildsAreDeferredAcrossOverlaysAndReplayAfterTerminalReset() {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(
        entries: [TranscriptEntry(id: "notice", content: .notice("committed"))],
        showHeader: false))
    let application = CodexApplication(model: model, driver: Driver(), systemServices: .disabled)
    var runtime = InlineDocumentRuntime<String>()
    let size = Size(width: 80, height: 24)
    #expect(
      !historyInsertions(from: application, size: size, runtime: &runtime).isEmpty)

    model.overlay = .permissions(PermissionPicker())
    model.rawOutputMode = true
    #expect(historyInsertions(from: application, size: size, runtime: &runtime).isEmpty)
    model.overlay = nil
    let deferred = historyInsertions(from: application, size: size, runtime: &runtime)
    #expect(deferred.first?.resetsScrollback == true)
    #expect(
      deferred.flatMap(\.text.lines).flatMap(\.spans).map(\.content).joined().contains("committed"))

    runtime.reset()
    let replay = historyInsertions(from: application, size: size, runtime: &runtime)
    #expect(replay.first?.resetsScrollback == false)
    #expect(
      replay.flatMap(\.text.lines).flatMap(\.spans).map(\.content).joined().contains("committed"))
  }

  @Test func transcriptPagerOpensNavigatesAndClosesWithUpstreamBindings() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(
        entries: (0..<40).map { TranscriptEntry(content: .notice("line \($0)")) }))
    let application = CodexApplication(model: model, driver: Driver(), systemServices: .disabled)

    #expect(
      await application.update(.key(KeyEvent(.character("t"), modifiers: [.control]))) == .redraw)
    guard case .transcript(let opened) = model.overlay else {
      Issue.record("Expected transcript pager")
      return
    }
    #expect(opened.followsLiveTail)

    _ = await application.update(.key(KeyEvent(.pageUp)))
    guard case .transcript(let scrolled) = model.overlay else { return }
    #expect(scrolled.scrollFromBottom == 20)
    model.entries.append(TranscriptEntry(content: .assistant("live tail", streaming: true)))
    guard case .transcript(let preserved) = model.overlay else { return }
    #expect(preserved.scrollFromBottom == 20)

    _ = await application.update(.key(KeyEvent(.end)))
    guard case .transcript(let bottom) = model.overlay else { return }
    #expect(bottom.followsLiveTail)

    #expect(
      await application.update(.key(KeyEvent(.character("t"), modifiers: [.control]))) == .redraw)
    #expect(model.overlay == nil)

    #expect(await application.update(.key(KeyEvent(.pageUp))) == .redraw)
    guard case .transcript(let pageUpOpened) = model.overlay else {
      Issue.record("Expected PageUp to open transcript pager")
      return
    }
    #expect(pageUpOpened.scrollFromBottom == 20)
  }

  @Test func controlGEditsTheExpandedDraftWithATerminalSuspendedAction() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(
        composer: TextFieldState(text: "seed draft"), isWorking: true, showHeader: false))
    let application = CodexApplication(
      model: model, driver: Driver(),
      systemServices: CodexSystemServices(
        gitDiff: { _ in "" }, copyToClipboard: { _ in },
        editDraft: { seed in
          #expect(seed == "seed draft")
          return "edited externally\n\n"
        }))

    #expect(
      await application.update(.key(KeyEvent(.character("g"), modifiers: [.control]))) == .suspend)
    #expect(model.composer.text == "seed draft")
    await application.performSuspendedAction()
    #expect(model.composer.text == "edited externally")
  }

  @Test func controlLClearsIdleTranscriptButIsBlockedDuringTasks() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(
        entries: [TranscriptEntry(content: .notice("old transcript"))], showHeader: false))
    let application = CodexApplication(model: model, driver: Driver(), systemServices: .disabled)

    #expect(
      await application.update(.key(KeyEvent(.character("l"), modifiers: [.control])))
        == .resetTerminalHistory)
    #expect(model.entries.isEmpty)

    model.isWorking = true
    model.entries = [TranscriptEntry(content: .notice("keep"))]
    #expect(
      await application.update(.key(KeyEvent(.character("l"), modifiers: [.control]))) == .redraw)
    #expect(model.entries.first?.content == .notice("keep"))
    #expect(
      model.entries.last?.content == .error("Ctrl+L is disabled while a task is in progress."))
  }

  @Test func externalEditorFailurePreservesTheDraftAndSurfacesTheError() async {
    enum EditorFailure: Error { case failed }
    let model = CodexSessionModel(snapshot: CodexSnapshot(composer: TextFieldState(text: "keep")))
    let application = CodexApplication(
      model: model, driver: Driver(),
      systemServices: CodexSystemServices(
        gitDiff: { _ in "" }, copyToClipboard: { _ in },
        editDraft: { _ in throw EditorFailure.failed }))

    _ = await application.update(.key(KeyEvent(.character("g"), modifiers: [.control])))
    await application.performSuspendedAction()

    #expect(model.composer.text == "keep")
    guard case .error(let message) = model.entries.last?.content else {
      Issue.record("Expected external-editor error")
      return
    }
    #expect(message.hasPrefix("Failed to open editor:"))
  }

  @Test func copyAndDiffUseInjectedSystemServices() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(
        entries: [TranscriptEntry(content: .assistant("answer markdown", streaming: false))],
        composer: TextFieldState(text: "/copy")))
    let application = CodexApplication(
      model: model, driver: Driver(),
      systemServices: CodexSystemServices(
        gitDiff: { _ in "diff --git a/file b/file" },
        copyToClipboard: { text in #expect(text == "answer markdown") }))

    _ = await application.update(.key(KeyEvent(.enter)))
    #expect(
      model.entries.contains {
        if case .notice("Copied last message to clipboard") = $0.content { return true }
        return false
      })

    model.composer = TextFieldState(text: "/diff")
    _ = await application.update(.key(KeyEvent(.enter)))
    #expect(
      model.entries.contains {
        if case .assistant(let text, false) = $0.content { return text.contains("diff --git") }
        return false
      })
  }

  @Test func mentionCommandAndAtKeyUseTheProjectFilePicker() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(composer: TextFieldState(text: "/mention Screen")))
    let services = CodexSystemServices(
      gitDiff: { _ in "" }, copyToClipboard: { _ in },
      projectFiles: { _ in
        ["README.md", "Sources/CodexTUI/CodexScreen.swift", "Tests/CodexScreenTests.swift"]
      })
    let application = CodexApplication(
      model: model, driver: Driver(), systemServices: services)

    _ = await application.update(.key(KeyEvent(.enter)))
    guard case .fileMentions(let picker) = model.overlay else {
      Issue.record("Expected file mention picker")
      return
    }
    #expect(picker.query.text == "Screen")
    #expect(picker.filteredFiles.count == 2)

    _ = await application.update(.key(KeyEvent(.enter)))
    #expect(model.overlay == nil)
    #expect(model.composer.text == "@Sources/CodexTUI/CodexScreen.swift ")

    model.composer = TextFieldState(text: "inspect ")
    _ = await application.update(.key(KeyEvent(.character("@"))))
    #expect(model.composer.text == "inspect @")
    #expect(model.overlay != nil)

    _ = await application.update(.key(KeyEvent(.left)))
    #expect(model.overlay == nil)
    #expect(model.composer.cursor == 8)
    _ = await application.update(.key(KeyEvent(.right)))
    #expect(model.overlay != nil)
    #expect(model.composer.cursor == 9)

    _ = await application.update(.key(KeyEvent(.character("R"))))
    #expect(model.composer.text == "inspect @R")
    guard case .fileMentions(let filtered) = model.overlay else {
      Issue.record("Expected the inline mention popup to remain active")
      return
    }
    #expect(filtered.query.text == "R")

    _ = await application.update(.key(KeyEvent(.backspace)))
    #expect(model.composer.text == "inspect @")
    _ = await application.update(.key(KeyEvent(.backspace)))
    #expect(model.composer.text == "inspect ")
    #expect(model.overlay == nil)

    let path = "Sources/CodexTUI/CodexScreen.swift"
    model.composer = TextFieldState(text: "inspect @\(path) later", cursor: 9 + path.count)
    _ = await application.update(.key(KeyEvent(.left)))
    guard case .fileMentions(let reopened) = model.overlay else {
      Issue.record("Expected cursor movement inside an existing mention to reopen the picker")
      return
    }
    #expect(reopened.query.text == path)
    #expect(reopened.query.cursor == path.count - 1)

    _ = await application.update(.key(KeyEvent(.character("X"))))
    #expect(model.composer.text == "inspect @\(path.dropLast())X\(path.last!) later")
    _ = await application.update(.key(KeyEvent(.backspace)))
    #expect(model.composer.text == "inspect @\(path) later")

    _ = await application.update(.key(KeyEvent(.enter)))
    #expect(model.composer.text == "inspect @\(path) later")
    #expect(model.composer.cursor == 9 + path.count)

    model.overlay = .fileMentions(FileMentionPicker(files: [path], query: path))
    _ = await application.update(.key(KeyEvent(.character(" "))))
    #expect(model.overlay == nil)
    #expect(model.composer.text == "inspect @\(path)  later")
  }

  @Test func optionUpEditsTheLastKwwkQueuedMessage() async {
    let model = CodexSessionModel(snapshot: CodexSnapshot(composer: TextFieldState(text: "draft")))
    let driver = Driver()
    driver.queuedEdit = "queued follow-up"
    let application = CodexApplication(
      model: model, driver: driver, systemServices: .disabled)

    _ = await application.update(.key(KeyEvent(.up, modifiers: [.option])))

    #expect(driver.replacedDrafts == ["draft"])
    #expect(model.composer.text == "queued follow-up")
  }

  @Test func largePastesUseCodexPlaceholderAndExpandBeforeKwwkSubmission() async {
    let model = CodexSessionModel()
    let driver = Driver()
    let application = CodexApplication(
      model: model, driver: driver, systemServices: .disabled)
    let pasted = String(repeating: "x", count: 1_005)

    _ = await application.update(.paste(pasted))
    #expect(model.composer.text == "[Pasted Content 1005 chars]")

    _ = await application.update(.key(KeyEvent(.enter)))
    #expect(driver.submitted == [pasted])
    #expect(model.history == [pasted])
    #expect(model.composer.text.isEmpty)
  }

  @Test func largePasteExpansionPreservesPayloadBoundaryWhitespaceExactly() {
    let pasted = "  \n" + String(repeating: "x", count: 1_001) + "\n  "
    let model = CodexSessionModel()

    #expect(model.handleComposerEvent(.paste(pasted)))
    #expect(model.takeComposerText() == pasted)

    let ordinary = CodexSessionModel()
    #expect(ordinary.handleComposerEvent(.paste("  hello  ")))
    #expect(ordinary.takeComposerText() == "hello")
  }

  @Test func allWhitespaceLargePasteCanStillBeSubmitted() {
    let pasted = String(repeating: " ", count: 1_001)
    let model = CodexSessionModel()

    #expect(model.handleComposerEvent(.paste(pasted)))
    #expect(model.takeComposerText() == pasted)
  }

  @Test func largePastePlaceholderIsAnAtomicComposerElement() {
    let pasted = String(repeating: "x", count: 1_005)
    let model = CodexSessionModel()

    #expect(model.handleComposerEvent(.paste(pasted)))
    #expect(model.composer.elements.count == 1)
    #expect(model.handleComposerEvent(.key(KeyEvent(.left))))
    #expect(model.composer.cursor == 0)
    #expect(model.handleComposerEvent(.key(KeyEvent(.right))))
    #expect(model.composer.cursor == model.composer.text.count)
    #expect(model.handleComposerEvent(.key(KeyEvent(.backspace))))
    #expect(model.composer.text.isEmpty)
    #expect(model.composer.elements.isEmpty)
    #expect(model.takeComposerText() == nil)
  }

  @Test func editingAroundLargePastePreservesItsPayloadIdentity() {
    let first = String(repeating: "a", count: 1_005)
    let second = String(repeating: "b", count: 1_005)
    let model = CodexSessionModel()

    #expect(model.handleComposerEvent(.paste(first)))
    #expect(model.handleComposerEvent(.paste(" between ")))
    #expect(model.handleComposerEvent(.paste(second)))
    #expect(model.composer.elements.count == 2)
    #expect(model.takeComposerText() == first + " between " + second)
  }

  @Test func vimDeletionCannotSplitALargePastePlaceholder() {
    let pasted = String(repeating: "x", count: 1_005)
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(vimEnabled: true, vimMode: .normal))

    #expect(model.handleComposerEvent(.paste(pasted)))
    #expect(model.handleVimEvent(.key(KeyEvent(.character("h")))))
    #expect(model.composer.cursor == 0)
    #expect(model.handleVimEvent(.key(KeyEvent(.character("x")))))
    #expect(model.composer.text.isEmpty)
    #expect(model.composer.elements.isEmpty)
  }

  @Test func pastedImagePathBecomesNativeKwwkImageSubmission() async {
    let model = CodexSessionModel(snapshot: CodexSnapshot(directory: "/tmp/project"))
    let driver = Driver()
    let expected = CodexImageAttachment(
      data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png", name: "shot.png")
    let services = CodexSystemServices(
      gitDiff: { _ in "" }, copyToClipboard: { _ in }, projectFiles: { _ in [] },
      imageFile: { path, directory in
        #expect(path == "./shot.png")
        #expect(directory == "/tmp/project")
        return expected
      })
    let application = CodexApplication(model: model, driver: driver, systemServices: services)

    _ = await application.update(.paste("./shot.png"))
    #expect(model.imageAttachments == [expected])

    _ = await application.update(.key(KeyEvent(.enter)))
    #expect(driver.submitted == [""])
    #expect(driver.submittedImages == [[expected]])
    #expect(model.imageAttachments.isEmpty)
  }

  @Test func composerNavigationAndBackspaceRemainUsable() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(composer: TextFieldState(text: "abcdef"), showHeader: false))
    let application = CodexApplication(model: model, driver: Driver(), systemServices: .disabled)

    _ = await application.update(.key(KeyEvent(.left)))
    _ = await application.update(.key(KeyEvent(.left)))
    _ = await application.update(.key(KeyEvent(.backspace)))
    _ = await application.update(.key(KeyEvent(.character("Z"))))

    #expect(model.composer.text == "abcZef")
  }

  @Test func shiftEnterInsertsANewlineWithoutSubmitting() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(composer: TextFieldState(text: "first"), showHeader: false))
    let driver = Driver()
    let application = CodexApplication(model: model, driver: driver, systemServices: .disabled)

    _ = await application.update(.key(KeyEvent(.enter, modifiers: [.shift])))
    _ = await application.update(.key(KeyEvent(.character("s"))))

    #expect(model.composer.text == "first\ns")
    #expect(driver.submitted.isEmpty)
  }

  @Test func slashPopupNavigatesWrapsDismissesAndCompletesTheSelectedCommand() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(composer: TextFieldState(text: "/"), showHeader: false))
    let application = CodexApplication(model: model, driver: Driver(), systemServices: .disabled)

    _ = await application.update(.key(KeyEvent(.down)))
    _ = await application.update(.key(KeyEvent(.down)))
    _ = await application.update(.key(KeyEvent(.tab)))
    #expect(model.composer.text == "/verbose ")

    model.composer = TextFieldState(text: "/")
    model.slashCommandSelection = 0
    _ = await application.update(.key(KeyEvent(.up)))
    _ = await application.update(.key(KeyEvent(.tab)))
    #expect(model.composer.text == "/quit ")

    model.composer = TextFieldState(text: "/")
    model.slashCommandSelection = 0
    _ = await application.update(.key(KeyEvent(.escape)))
    #expect(model.composer.text == "/")
    #expect(model.slashPopupDismissed)
  }

  @Test func controlVPastesClipboardImageIntoComposer() async {
    let model = CodexSessionModel()
    let image = CodexImageAttachment(
      data: Data([1, 2, 3]), mimeType: "image/png", name: "clipboard.png")
    let services = CodexSystemServices(
      gitDiff: { _ in "" }, copyToClipboard: { _ in }, clipboardImage: { image })
    let application = CodexApplication(
      model: model, driver: Driver(), systemServices: services)

    _ = await application.update(.key(KeyEvent(.character("v"), modifiers: [.control])))

    #expect(model.imageAttachments == [image])
    _ = await application.update(.key(KeyEvent(.backspace)))
    #expect(model.imageAttachments.isEmpty)
  }

  @Test func imageRowsCanBeSelectedAndDeletedWithoutClearingComposerText() async {
    let first = CodexImageAttachment(
      data: Data([1]), mimeType: "image/png", name: "first.png")
    let second = CodexImageAttachment(
      data: Data([2]), mimeType: "image/png", name: "second.png")
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(
        composer: TextFieldState(text: "c"), imageAttachments: [first, second], showHeader: false))
    let application = CodexApplication(
      model: model, driver: Driver(), systemServices: .disabled)

    _ = await application.update(.key(KeyEvent(.up)))
    #expect(model.selectedImageAttachmentIndex == 1)
    _ = await application.update(.key(KeyEvent(.up)))
    #expect(model.selectedImageAttachmentIndex == 0)
    _ = await application.update(.key(KeyEvent(.backspace)))

    #expect(model.imageAttachments == [second])
    #expect(model.selectedImageAttachmentIndex == 0)
    #expect(model.composer.text == "c")

    _ = await application.update(.key(KeyEvent(.down)))
    #expect(model.selectedImageAttachmentIndex == nil)
  }

  @Test func pastedRemoteImageURLBecomesAnAttachmentInsteadOfComposerText() async {
    let model = CodexSessionModel(snapshot: CodexSnapshot(directory: "/tmp/project"))
    let image = CodexImageAttachment(
      data: Data([1, 2, 3]), mimeType: "image/webp", name: "reference.webp")
    let services = CodexSystemServices(
      gitDiff: { _ in "" }, copyToClipboard: { _ in },
      remoteImage: { value in
        #expect(value == "https://example.com/reference.webp")
        return image
      })
    let application = CodexApplication(
      model: model, driver: Driver(), systemServices: services)

    #expect(
      await application.update(.paste("https://example.com/reference.webp")) == .redraw)
    #expect(model.imageAttachments == [image])
    #expect(model.composer.text.isEmpty)
  }

  @Test func goalArgumentsReachTheRuntimeGoalController() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(composer: TextFieldState(text: "/goal finish parity")))
    let driver = Driver()
    let application = CodexApplication(model: model, driver: driver, systemServices: .disabled)

    _ = await application.update(.key(KeyEvent(.enter)))

    #expect(driver.goalCommands == ["finish parity"])
  }

  @Test func sideConversationStartsWithInlinePromptAndUsesDistinctSwitchAndCloseKeys() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(composer: TextFieldState(text: "/side explain this")))
    let driver = Driver()
    let application = CodexApplication(model: model, driver: driver, systemServices: .disabled)

    _ = await application.update(.key(KeyEvent(.enter)))
    #expect(driver.sidePrompts == ["explain this"])

    model.mode = .side
    #expect(
      await application.update(.key(KeyEvent(.character("/"), modifiers: [.control]))) == .redraw)
    #expect(driver.sideToggleCount == 1)

    #expect(
      await application.update(.key(KeyEvent(.character("c"), modifiers: [.control]))) == .redraw)
    #expect(driver.sideCloseCount == 1)
  }

  @Test func sideConversationRejectsMainThreadOnlyCommands() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(composer: TextFieldState(text: "/review"), mode: .side))
    let driver = Driver()
    let application = CodexApplication(model: model, driver: driver, systemServices: .disabled)

    _ = await application.update(.key(KeyEvent(.enter)))

    #expect(driver.submitted.isEmpty)
    #expect(
      model.entries.contains {
        if case .error(let text) = $0.content {
          return text.contains("unavailable in side conversations")
        }
        return false
      })
  }

  @Test func agentCommandOpensThreadPickerAndChildPreview() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(composer: TextFieldState(text: "/agent")))
    let driver = Driver()
    driver.threadSummaries = [
      AgentThreadSummary(
        id: "main", name: "Main thread", role: "main", status: "idle",
        description: "Primary conversation"),
      AgentThreadSummary(
        id: "child", name: "explorer", role: "subagent", status: "completed",
        description: "Inspect renderer",
        entries: [TranscriptEntry(content: .assistant("Found it", streaming: false))]),
    ]
    let application = CodexApplication(model: model, driver: driver, systemServices: .disabled)

    _ = await application.update(.key(KeyEvent(.enter)))
    _ = await application.update(.key(KeyEvent(.down)))
    _ = await application.update(.key(KeyEvent(.enter)))

    guard case .agentPreview(let preview) = model.overlay else {
      Issue.record("Expected child transcript preview")
      return
    }
    #expect(preview.thread.id == "child")

    #expect(
      await application.update(.key(KeyEvent(.left, modifiers: [.option]))) == .redraw)
    #expect(model.overlay == nil)
  }

  @Test func skillsCommandMentionsTheSelectedRuntimeSkill() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(composer: TextFieldState(text: "/skills")))
    let driver = Driver()
    driver.availableSkills = [
      SkillSummary(
        name: "snapshot-testing", description: "Snapshot test Swift code",
        path: "/skills/snapshot-testing/SKILL.md")
    ]
    let application = CodexApplication(model: model, driver: driver, systemServices: .disabled)

    _ = await application.update(.key(KeyEvent(.enter)))
    guard case .skills(let picker) = model.overlay else {
      Issue.record("Expected the runtime skill picker")
      return
    }
    #expect(picker.skills.map(\.name) == ["snapshot-testing"])

    _ = await application.update(.key(KeyEvent(.enter)))
    #expect(model.overlay == nil)
    #expect(model.composer.text == "$snapshot-testing ")
  }

  @Test func mentionEditingPreservesUnrelatedAtomicPastePayloads() async {
    let pasted = String(repeating: "x", count: 1_005)
    let model = CodexSessionModel()
    #expect(model.handleComposerEvent(.paste(pasted)))
    #expect(model.handleComposerEvent(.paste(" @REA")))
    let application = CodexApplication(
      model: model, driver: Driver(),
      systemServices: CodexSystemServices(
        gitDiff: { _ in "" }, copyToClipboard: { _ in },
        projectFiles: { _ in ["README.md"] }))

    _ = await application.update(.key(KeyEvent(.left)))
    guard case .fileMentions = model.overlay else {
      Issue.record("Expected file picker")
      return
    }
    _ = await application.update(.key(KeyEvent(.enter)))
    #expect(model.takeComposerText() == pasted + " @README.md")
  }

  @Test func mentionPopupRecognizesCursorOnTheSigil() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(composer: TextFieldState(text: "@README.md", cursor: 0)))
    let driver = Driver()
    let application = CodexApplication(
      model: model, driver: driver,
      systemServices: CodexSystemServices(
        gitDiff: { _ in "" }, copyToClipboard: { _ in },
        projectFiles: { _ in ["README.md"] }))

    _ = await application.update(.key(KeyEvent(.left)))
    guard case .fileMentions(let picker) = model.overlay else {
      Issue.record("Expected mention popup while cursor is on @")
      return
    }
    #expect(picker.query.text == "README.md")
    #expect(picker.query.cursor == 0)
  }

  @Test func mentionPickersFuzzyMatchWrapAndAcceptCodexNavigationKeys() async {
    let skills = [
      SkillSummary(name: "Other", description: "Unrelated", path: "/skills/other"),
      SkillSummary(name: "pr-babysitter", description: "Watch pull requests", path: "/skills/pr"),
    ]
    var skillPicker = SkillPicker(skills: skills, query: "prb")
    #expect(skillPicker.filteredSkills.map(\.name) == ["pr-babysitter"])

    skillPicker = SkillPicker(skills: skills, selectedIndex: 0)
    let skillModel = CodexSessionModel(
      snapshot: CodexSnapshot(
        composer: TextFieldState(text: "$"), overlay: .skills(skillPicker)))
    let skillApplication = CodexApplication(
      model: skillModel, driver: Driver(), systemServices: .disabled)
    _ = await skillApplication.update(.key(KeyEvent(.up)))
    guard case .skills(let wrappedSkillPicker) = skillModel.overlay else {
      Issue.record("Expected skill picker")
      return
    }
    #expect(wrappedSkillPicker.selectedIndex == 1)
    _ = await skillApplication.update(.key(KeyEvent(.tab)))
    #expect(skillModel.composer.text == "$pr-babysitter ")

    let fileModel = CodexSessionModel(
      snapshot: CodexSnapshot(
        composer: TextFieldState(text: "@"),
        overlay: .fileMentions(FileMentionPicker(files: ["a.swift", "b.swift"]))))
    let fileApplication = CodexApplication(
      model: fileModel, driver: Driver(), systemServices: .disabled)
    _ = await fileApplication.update(.key(KeyEvent(.character("p"), modifiers: [.control])))
    guard case .fileMentions(let wrappedFilePicker) = fileModel.overlay else {
      Issue.record("Expected file picker")
      return
    }
    #expect(wrappedFilePicker.selectedIndex == 1)
  }

  @Test func skillSelectionTracksTheHighlightedItemAcrossWrappedRows() async {
    let model = CodexSessionModel(snapshot: CodexSnapshot())
    let driver = Driver()
    driver.availableSkills = (1...10).map { index in
      SkillSummary(
        name: "skill-\(index)",
        description: "A long skill description that occupies multiple terminal rows.",
        path: "/skills/skill-\(index)/SKILL.md")
    }
    let application = CodexApplication(model: model, driver: driver, systemServices: .disabled)

    _ = await application.update(.key(KeyEvent(.character("$"))))
    for _ in 0..<8 { _ = await application.update(.key(KeyEvent(.down))) }
    guard case .skills(let picker) = model.overlay else {
      Issue.record("Expected the skill picker")
      return
    }
    #expect(picker.selectedIndex == 8)

    _ = await application.update(.key(KeyEvent(.enter)))
    #expect(model.overlay == nil)
    #expect(model.composer.text == "$skill-9 ")
  }

  @Test func backgroundTerminalAndUsageCommandsUseRuntimeState() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(composer: TextFieldState(text: "/ps")))
    let driver = Driver()
    driver.tasks = [
      BackgroundTaskSummary(
        id: "task-1", label: "swift test", kind: "bash", status: "running",
        output: "Building")
    ]
    driver.stoppedTaskCount = 1
    let application = CodexApplication(model: model, driver: driver, systemServices: .disabled)

    _ = await application.update(.key(KeyEvent(.enter)))
    guard case .backgroundTasks(let picker) = model.overlay else {
      Issue.record("Expected background task picker")
      return
    }
    #expect(picker.tasks.first?.id == "task-1")
    _ = await application.update(.key(KeyEvent(.escape)))

    model.composer = TextFieldState(text: "/stop")
    _ = await application.update(.key(KeyEvent(.enter)))
    model.composer = TextFieldState(text: "/usage")
    _ = await application.update(.key(KeyEvent(.enter)))
    #expect(
      model.entries.contains {
        if case .notice(let text) = $0.content { return text == "Stopped 1 background terminal(s)" }
        return false
      })
    #expect(
      model.entries.contains {
        if case .notice(let text) = $0.content { return text.contains("10 input") }
        return false
      })
  }

  @Test func statusUsesLiveDriverContextRemaining() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(
        composer: TextFieldState(text: "/status"), contextRemainingPercent: 100))
    let driver = Driver()
    driver.remainingPercent = 37
    let application = CodexApplication(model: model, driver: driver, systemServices: .disabled)

    _ = await application.update(.key(KeyEvent(.enter)))
    #expect(model.contextRemainingPercent == 37)
    #expect(
      model.entries.contains {
        if case .notice(let text) = $0.content { return text.contains("Context: 37%") }
        return false
      })
  }

  @Test func keymapCapturePersistsAndActivatesReplacementImmediately() async throws {
    let saved = SavedKeymap()
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(composer: TextFieldState(text: "/keymap")))
    let driver = Driver()
    let services = CodexSystemServices(
      gitDiff: { _ in "" }, copyToClipboard: { _ in },
      saveKeymap: { await saved.set($0) })
    let application = CodexApplication(model: model, driver: driver, systemServices: services)

    #expect(await application.update(.key(KeyEvent(.enter))) == .redraw)
    guard case .keymap(var picker) = model.overlay else {
      Issue.record("Expected keymap picker")
      return
    }
    picker.selectedIndex = try #require(CodexKeymapAction.allCases.firstIndex(of: .submit))
    model.overlay = .keymap(picker)
    #expect(await application.update(.key(KeyEvent(.enter))) == .redraw)
    #expect(await application.update(.key(KeyEvent(.enter))) == .redraw)
    guard case .keymapCapture = model.overlay else {
      Issue.record("Expected raw key capture")
      return
    }
    #expect(
      await application.update(.key(KeyEvent(.character("x"), modifiers: [.control]))) == .redraw)
    #expect(model.runtimeKeymap.bindings(for: .submit).map(\.canonicalName) == ["ctrl-x"])
    #expect(await saved.configuration?[.submit]?.map(\.canonicalName) == ["ctrl-x"])
    #expect(await application.update(.key(KeyEvent(.escape))) == .redraw)

    model.composer = TextFieldState(text: "send me")
    _ = await application.update(.key(KeyEvent(.enter)))
    #expect(driver.submitted.isEmpty)
    #expect(
      await application.update(.key(KeyEvent(.character("x"), modifiers: [.control]))) == .redraw)
    #expect(driver.submitted == ["send me"])
  }

  @Test func keymapConflictCancelAndSaveFailureLeaveRuntimeUnchanged() async {
    enum SaveFailure: Error { case failed }
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(isWorking: true))
    let driver = Driver()
    let application = CodexApplication(
      model: model, driver: driver,
      systemServices: CodexSystemServices(
        gitDiff: { _ in "" }, copyToClipboard: { _ in },
        saveKeymap: { _ in throw SaveFailure.failed }))
    model.overlay = .keymapCapture(
      CodexKeymapCapture(
        action: .submit, operation: .replaceAll,
        configuration: model.runtimeKeymap.configuration))

    #expect(await application.update(.key(KeyEvent(.escape))) == .redraw)
    #expect(driver.interruptCount == 0)
    guard case .keymapAction = model.overlay else {
      Issue.record("Expected capture cancellation to return to action menu")
      return
    }

    model.overlay = .keymapCapture(
      CodexKeymapCapture(
        action: .submit, operation: .replaceAll,
        configuration: model.runtimeKeymap.configuration))
    _ = await application.update(.key(KeyEvent(.character("x"), modifiers: [.control])))
    #expect(model.runtimeKeymap.bindings(for: .submit) == [CodexKeyBinding(.enter)])
    guard case .error(let saveError) = model.entries.last?.content else {
      Issue.record("Expected save error")
      return
    }
    #expect(saveError.hasPrefix("Shortcut not changed:"))
    guard case .keymapAction = model.overlay else {
      Issue.record("Expected failed save to return to action menu")
      return
    }

    model.overlay = .keymapCapture(
      CodexKeymapCapture(
        action: .submit, operation: .replaceAll,
        configuration: model.runtimeKeymap.configuration))
    _ = await application.update(.key(KeyEvent(.tab)))
    #expect(model.runtimeKeymap.bindings(for: .submit) == [CodexKeyBinding(.enter)])
    guard case .error(let conflict) = model.entries.last?.content else {
      Issue.record("Expected conflict error")
      return
    }
    #expect(conflict.contains("conflicts"))
  }

  @Test func customizedHistoryBindingsDriveTheOpenOverlayEndToEnd() async throws {
    var configuration = CodexKeymapConfiguration()
    configuration[.historySearchPrevious] = [
      CodexKeyBinding(.character("p"), modifiers: [.option])
    ]
    configuration[.historySearchNext] = [
      CodexKeyBinding(.character("n"), modifiers: [.option])
    ]
    let model = CodexSessionModel(
      runtimeKeymap: try CodexRuntimeKeymap(configuration: configuration))
    model.history = ["older", "newer"]
    let application = CodexApplication(
      model: model, driver: Driver(), systemServices: .disabled)

    #expect(
      await application.update(.key(KeyEvent(.character("r"), modifiers: [.control]))) == .ignore)
    #expect(model.overlay == nil)
    _ = await application.update(.key(KeyEvent(.character("n"), modifiers: [.option])))
    #expect(model.overlay == nil)

    #expect(
      await application.update(.key(KeyEvent(.character("p"), modifiers: [.option]))) == .redraw)
    guard case .historySearch(let opened) = model.overlay else {
      Issue.record("Expected history search overlay")
      return
    }
    #expect(opened.selectedIndex == nil)

    #expect(
      await application.update(.key(KeyEvent(.character("r"), modifiers: [.control]))) == .ignore)
    guard case .historySearch(let unchanged) = model.overlay else { return }
    #expect(unchanged.selectedIndex == nil)

    _ = await application.update(.key(KeyEvent(.character("p"), modifiers: [.option])))
    _ = await application.update(.key(KeyEvent(.character("p"), modifiers: [.option])))
    guard case .historySearch(let older) = model.overlay else { return }
    #expect(older.selectedIndex == 1)

    #expect(
      await application.update(.key(KeyEvent(.character("s"), modifiers: [.control]))) == .ignore)
    guard case .historySearch(let stillOlder) = model.overlay else { return }
    #expect(stillOlder.selectedIndex == 1)

    _ = await application.update(.key(KeyEvent(.character("n"), modifiers: [.option])))
    guard case .historySearch(let newer) = model.overlay else { return }
    #expect(newer.selectedIndex == 0)
  }

  @Test func keymapDebugInspectsEscapeAndClosesOnlyOnControlC() async throws {
    var configuration = CodexKeymapConfiguration()
    configuration[.toggleRawOutput] = [CodexKeyBinding(.character("x"), modifiers: [.option])]
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(composer: TextFieldState(text: "/keymap debug")),
      runtimeKeymap: try CodexRuntimeKeymap(configuration: configuration))
    let application = CodexApplication(model: model, driver: Driver(), systemServices: .disabled)

    #expect(await application.update(.key(KeyEvent(.enter))) == .redraw)
    guard case .keymapDebug = model.overlay else {
      Issue.record("Expected keypress inspector")
      return
    }

    #expect(await application.update(.key(KeyEvent(.escape))) == .redraw)
    guard case .keymapDebug(let escapeReport) = model.overlay else { return }
    #expect(escapeReport.detected?.canonicalName == "esc")
    #expect(escapeReport.matches.map(\.action) == [.interruptTurn])

    _ = await application.update(.key(KeyEvent(.character("x"), modifiers: [.option])))
    guard case .keymapDebug(let customReport) = model.overlay else { return }
    #expect(
      customReport.matches == [CodexKeymapDebugMatch(action: .toggleRawOutput, source: "Custom")])

    #expect(
      await application.update(.key(KeyEvent(.character("c"), modifiers: [.control]))) == .redraw)
    #expect(model.overlay == nil)

    model.composer = TextFieldState(text: "/keymap unknown")
    _ = await application.update(.key(KeyEvent(.enter)))
    #expect(model.entries.last?.content == .error("Usage: /keymap [debug]"))
  }

  @Test func keymapDebugTabOpensTheInspector() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(
        overlay: .keymap(CodexKeymapPicker(configuration: .init(), tab: .debug))))
    let application = CodexApplication(model: model, driver: Driver(), systemServices: .disabled)

    #expect(await application.update(.key(KeyEvent(.enter))) == .redraw)
    guard case .keymapDebug = model.overlay else {
      Issue.record("Expected keypress inspector")
      return
    }
  }

  @Test func kwwkRuntimeCommandsAndInitAreExposedThroughCodexShell() async {
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(composer: TextFieldState(text: "/context")))
    let driver = Driver()
    let application = CodexApplication(model: model, driver: driver, systemServices: .disabled)

    _ = await application.update(.key(KeyEvent(.enter)))
    #expect(driver.runtimeCommands.count == 1)
    #expect(driver.runtimeCommands.first?.0 == "context")
    guard case .notice(let context) = model.entries.last?.content else {
      Issue.record("Expected KWWK runtime command output")
      return
    }
    #expect(context == "runtime: context ")

    model.composer = TextFieldState(text: "/init")
    _ = await application.update(.key(KeyEvent(.enter)))
    #expect(driver.submitted.last?.contains("create or improve AGENTS.md") == true)

    model.composer = TextFieldState(text: "/help")
    _ = await application.update(.key(KeyEvent(.enter)))
    guard case .notice(let help) = model.entries.last?.content else {
      Issue.record("Expected slash command help")
      return
    }
    #expect(help.contains("/tools — list tools available to the KWWK agent"))
  }
}
