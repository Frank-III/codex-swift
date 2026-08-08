import Foundation
import TermLoom
import TermLoomSyntaxHighlighting

@MainActor
public final class CodexApplication: TerminalApplication, InlineViewportSizing,
  PeriodicallyRedrawingTerminalApplication
{
  public let model: CodexSessionModel
  public let driver: any CodexConversationDriving
  public let systemServices: CodexSystemServices
  private struct CachedHistoryBlock {
    var entry: TranscriptEntry
    var width: Int
    var rawOutputMode: Bool
    var syntaxTheme: SyntaxTheme
    var lines: [Line]
  }

  private struct PreparedHistoryBlock {
    var sourceIndex: Int
    var id: String
    var lines: [Line]
    var isComplete: Bool
    var isUser: Bool
  }

  private struct IndexedHistoryBlock {
    var sourceIndex: Int
    var block: InlineDocumentBlock<String>
  }

  private struct CachedInlineDocument {
    var sessionID: String
    var transcriptRevision: UInt64
    var width: Int
    var rawOutputMode: Bool
    var syntaxTheme: SyntaxTheme
    var document: InlineDocument<String>
  }

  private struct HistoryReplayWindow {
    var sessionID: String
    var width: Int
    var rawOutputMode: Bool
    var syntaxTheme: SyntaxTheme
    var startIndex: Int
    var startBlockID: String
    var startLineOffset: Int
  }

  private var externalEditorRequested = false
  private var backtrackPrimed = false
  private var historyRenderCache: [String: CachedHistoryBlock] = [:]
  private var historyRenderCacheSessionID: String?
  private var cachedInlineDocument: CachedInlineDocument?
  private var inlineDocumentRevision: UInt64 = 0
  private var historyReplayWindow: HistoryReplayWindow?
  private var lastKnownTerminalWidth: Int?
  private var resizeReflowDeadline: ContinuousClock.Instant?
  private var pendingResizeWidth: Int?
  private let resizeReflowClock = ContinuousClock()
  private let resizeReflowDebounce: Duration = .milliseconds(75)
  private let historyReplayRowLimit = 1_000
  private let historyReplayReanchorRowLimit = 2_000

  public init(
    model: CodexSessionModel, driver: any CodexConversationDriving,
    systemServices: CodexSystemServices = .live
  ) {
    self.model = model
    self.driver = driver
    self.systemServices = systemServices
  }

  // Codex already owns a complete event/stream redraw scheduler. Automatic Observation invalidation would
  // duplicate those frames and can expose transient multi-property model updates as visible flashes.
  public var automaticallyTracksObservableState: Bool { false }
  public var needsPeriodicRedraw: Bool { model.isWorking || resizeReflowDeadline != nil }

  public var body: CodexScreen {
    var snapshot = model.snapshot
    if case .transcript(let pager) = snapshot.overlay {
      guard pager.cachedTranscriptLines != nil else { return CodexScreen(snapshot: snapshot) }
      snapshot.entries = []
      snapshot.showHeader = false
      return CodexScreen(snapshot: snapshot)
    }

    // Completed entries form a stable prefix. Walking backward from the mutable tail keeps ordinary
    // composer redraws independent of the total session length.
    var liveStart = snapshot.entries.endIndex
    while liveStart > snapshot.entries.startIndex {
      let candidate = snapshot.entries.index(before: liveStart)
      guard !historyEntryIsComplete(snapshot.entries[candidate]) else { break }
      liveStart = candidate
    }
    snapshot.entries = snapshot.entries[liveStart...].map { entry in
      var live = entry
      switch entry.content {
      case .assistant(let text, true):
        live.content = .assistant(
          entry.streamingMarkdown?.mutableTailSource ?? text, streaming: true)
        live.streamingMarkdown = nil
      case .reasoning(let summary, _, true):
        live.content = .reasoning(
          summary: summary, body: entry.streamingMarkdown?.mutableTailSource ?? "",
          streaming: true)
        live.streamingMarkdown = nil
      default:
        break
      }
      return live
    }
    if liveStart > model.entries.startIndex { snapshot.showHeader = false }
    return CodexScreen(snapshot: snapshot)
  }

  public func desiredInlineViewportHeight(size: Size) -> Int {
    (min(22, min(size.height, body.desiredHeight(width: size.width))))
  }

  public func inlineDocument(size: Size) -> InlineDocument<String>? {
    if let deadline = resizeReflowDeadline {
      guard resizeReflowClock.now >= deadline else { return nil }
      resizeReflowDeadline = nil
      let targetWidth = pendingResizeWidth ?? size.width
      pendingResizeWidth = nil
      lastKnownTerminalWidth = targetWidth
      if case .transcript = model.overlay {
        // Keep the existing pager projection responsive while it owns the screen. Closing the overlay
        // lets the normal source-backed history rebuild at the settled width.
        return nil
      }
    }
    guard model.overlay == nil else { return nil }
    if let cached = cachedInlineDocument,
      cached.sessionID == model.sessionID,
      cached.transcriptRevision == model.transcriptRevision,
      cached.width == size.width,
      cached.rawOutputMode == model.rawOutputMode,
      cached.syntaxTheme == model.syntaxTheme
    {
      return cached.document
    }
    if historyRenderCacheSessionID != model.sessionID {
      historyRenderCache.removeAll(keepingCapacity: true)
      historyRenderCacheSessionID = model.sessionID
    }

    let renderer = CodexScreen(snapshot: model.snapshot)
    let prepared = preparedHistoryTail(size: size, renderer: renderer)
    let indexedBlocks = indexedHistoryBlocks(from: prepared)
    let replayBlocks = replayBlocks(from: indexedBlocks, size: size)
    if historyRenderCache.count > replayBlocks.count {
      let retainedIDs = Set(replayBlocks.map(\.id))
      historyRenderCache = historyRenderCache.filter { retainedIDs.contains($0.key) }
    }

    inlineDocumentRevision &+= 1
    let document = InlineDocument(
      id: model.sessionID, revision: inlineDocumentRevision, blocks: replayBlocks)
    cachedInlineDocument = CachedInlineDocument(
      sessionID: model.sessionID,
      transcriptRevision: model.transcriptRevision,
      width: size.width,
      rawOutputMode: model.rawOutputMode,
      syntaxTheme: model.syntaxTheme,
      document: document)
    lastKnownTerminalWidth = size.width
    return document
  }

  private func preparedHistoryTail(
    size: Size, renderer: CodexScreen
  ) -> [PreparedHistoryBlock] {
    guard !model.entries.isEmpty else {
      historyReplayWindow = nil
      return []
    }

    if let window = historyReplayWindow,
      window.sessionID == model.sessionID, window.width == size.width,
      window.rawOutputMode == model.rawOutputMode, window.syntaxTheme == model.syntaxTheme,
      model.entries.indices.contains(window.startIndex),
      model.entries[window.startIndex].id == window.startBlockID
    {
      return model.entries.indices[window.startIndex...].map {
        preparedHistoryBlock(at: $0, size: size, renderer: renderer)
      }
    }

    var reversed: [PreparedHistoryBlock] = []
    var renderedRows = 0
    var laterIsUser: Bool?
    for index in model.entries.indices.reversed() {
      let block = preparedHistoryBlock(at: index, size: size, renderer: renderer)
      reversed.append(block)
      guard !block.lines.isEmpty else { continue }
      if let laterIsUser, !block.isUser, !laterIsUser { renderedRows += 1 }
      renderedRows += block.lines.count
      laterIsUser = block.isUser
      if renderedRows >= historyReplayRowLimit { break }
    }
    return reversed.reversed()
  }

  private func preparedHistoryBlock(
    at index: Int, size: Size, renderer: CodexScreen, cacheResult: Bool = true
  ) -> PreparedHistoryBlock {
    let entry = model.entries[index]
    var rendered = entry
    var omitsHistory = false
    switch entry.content {
    case .assistant(let text, let streaming):
      let source = streaming ? entry.streamingMarkdown?.stableSource ?? "" : text
      rendered.content = .assistant(source, streaming: false)
      rendered.streamingMarkdown = nil
      omitsHistory = streaming && source.isEmpty
    case .reasoning(let summary, let body, let streaming):
      let source = streaming ? entry.streamingMarkdown?.stableSource ?? "" : (body ?? summary)
      rendered.content = .reasoning(summary: summary, body: source, streaming: false)
      rendered.streamingMarkdown = nil
      omitsHistory = streaming && source.isEmpty
    case .tool(let tool) where tool.status == .running:
      omitsHistory = true
    default:
      break
    }

    let lines: [Line]
    if omitsHistory {
      // Mutable content without stable source belongs only to the retained viewport.
      lines = []
    } else if let cached = historyRenderCache[entry.id], cached.entry == rendered,
      cached.width == size.width, cached.rawOutputMode == model.rawOutputMode,
      cached.syntaxTheme == model.syntaxTheme
    {
      lines = cached.lines
    } else {
      lines = renderer.terminalHistoryLines(
        for: rendered, width: size.width, sourceContinuation: false)
      if cacheResult {
        historyRenderCache[entry.id] = CachedHistoryBlock(
          entry: rendered, width: size.width, rawOutputMode: model.rawOutputMode,
          syntaxTheme: model.syntaxTheme, lines: lines)
      }
    }

    let isUser: Bool = if case .user = entry.content { true } else { false }
    return PreparedHistoryBlock(
      sourceIndex: index, id: entry.id, lines: lines,
      isComplete: historyEntryIsComplete(entry), isUser: isUser)
  }

  private func indexedHistoryBlocks(
    from prepared: [PreparedHistoryBlock]
  ) -> [IndexedHistoryBlock] {
    let wrap: WrapMode = model.rawOutputMode ? .character : .word
    var result: [IndexedHistoryBlock] = []
    result.reserveCapacity(prepared.count)
    var hasRows = false
    var lastWasUser = false
    for preparedBlock in prepared {
      var lines = preparedBlock.lines
      if !lines.isEmpty, hasRows, !lastWasUser, !preparedBlock.isUser {
        lines.insert(Line(""), at: 0)
      }
      if !lines.isEmpty {
        hasRows = true
        lastWasUser = preparedBlock.isUser
      }
      result.append(
        IndexedHistoryBlock(
          sourceIndex: preparedBlock.sourceIndex,
          block: InlineDocumentBlock(
            id: preparedBlock.id, text: Text(lines), wrap: wrap,
            isComplete: preparedBlock.isComplete)))
    }
    return result
  }

  private func replayBlocks(
    from indexedBlocks: [IndexedHistoryBlock], size: Size
  ) -> [InlineDocumentBlock<String>] {
    guard !indexedBlocks.isEmpty else {
      historyReplayWindow = nil
      return []
    }

    if let window = historyReplayWindow,
      window.sessionID == model.sessionID, window.width == size.width,
      window.rawOutputMode == model.rawOutputMode, window.syntaxTheme == model.syntaxTheme,
      indexedBlocks.first?.sourceIndex == window.startIndex,
      indexedBlocks.first?.block.id == window.startBlockID
    {
      var result = indexedBlocks.map(\.block)
      if window.startLineOffset > 0 {
        result[0].text.lines = Array(result[0].text.lines.dropFirst(window.startLineOffset))
      }
      let rowCount = result.reduce(0) { $0 + $1.text.lines.count }
      if rowCount <= historyReplayReanchorRowLimit { return result }
      historyReplayWindow = nil
      return replayBlocks(from: indexedBlocks, size: size)
    }

    let totalRows = indexedBlocks.reduce(0) { $0 + $1.block.text.lines.count }
    var rowsToDrop = max(0, totalRows - historyReplayRowLimit)
    var retained: [IndexedHistoryBlock] = []
    var firstLineOffset = 0
    for indexed in indexedBlocks {
      let lineCount = indexed.block.text.lines.count
      if rowsToDrop >= lineCount, rowsToDrop > 0 {
        rowsToDrop -= lineCount
        continue
      }
      var retainedBlock = indexed
      if rowsToDrop > 0 {
        firstLineOffset = rowsToDrop
        retainedBlock.block.text.lines = Array(
          retainedBlock.block.text.lines.dropFirst(rowsToDrop))
        rowsToDrop = 0
      }
      retained.append(retainedBlock)
    }

    guard let first = retained.first else {
      historyReplayWindow = nil
      return []
    }
    historyReplayWindow = HistoryReplayWindow(
      sessionID: model.sessionID, width: size.width,
      rawOutputMode: model.rawOutputMode, syntaxTheme: model.syntaxTheme,
      startIndex: first.sourceIndex, startBlockID: first.block.id,
      startLineOffset: firstLineOffset)
    return retained.map(\.block)
  }

  public func terminalHistoryDidReset() {
    historyReplayWindow = nil
    cachedInlineDocument = nil
  }

  internal var historyRenderCacheEntryCount: Int { historyRenderCache.count }
  internal var resizeReflowDeadlineForTesting: ContinuousClock.Instant? { resizeReflowDeadline }

  internal func makeResizeReflowDueForTesting() {
    if resizeReflowDeadline != nil { resizeReflowDeadline = resizeReflowClock.now }
  }

  private func historyEntryIsComplete(_ entry: TranscriptEntry) -> Bool {
    switch entry.content {
    case .assistant(_, let streaming), .reasoning(_, _, let streaming):
      return !streaming
    case .tool(let tool):
      return tool.status != .running
    default:
      return true
    }
  }

  private func makeTranscriptPager(
    backtrackCandidates: [RewindCandidate], selectedBacktrackIndex: Int? = nil
  ) -> CodexTranscriptPager {
    var pager = CodexTranscriptPager(
      backtrackCandidates: backtrackCandidates, selectedBacktrackIndex: selectedBacktrackIndex)
    pager.sourceEntries = model.entries
    guard model.entries.allSatisfy(historyEntryIsComplete),
      let width = cachedInlineDocument?.width ?? lastKnownTerminalWidth
    else { return pager }

    let highlightedID: String? = pager.highlightedUserFromEnd.flatMap { fromEnd in
      let users = model.entries.filter { if case .user = $0.content { true } else { false } }
      let index = users.count - 1 - fromEnd
      return users.indices.contains(index) ? users[index].id : nil
    }
    let size = Size(width: width, height: 1)
    let renderer = CodexScreen(snapshot: model.snapshot)
    let prepared = model.entries.indices.map {
      preparedHistoryBlock(at: $0, size: size, renderer: renderer, cacheResult: false)
    }
    let blocks = indexedHistoryBlocks(from: prepared).map(\.block)
    var lines: [Line] = []
    lines.reserveCapacity(blocks.reduce(0) { $0 + $1.text.lines.count })
    for block in blocks {
      if block.id == highlightedID {
        lines.append(
          contentsOf: block.text.lines.map { line in
            var highlighted = line
            highlighted.style = highlighted.style.patching(.init(modifiers: [.reversed]))
            return highlighted
          })
      } else {
        lines.append(contentsOf: block.text.lines)
      }
    }
    pager.cachedTranscriptLines = lines
    pager.cachedWidth = width
    return pager
  }

  public func update(_ event: TerminalEvent) async -> ApplicationUpdate {
    if case .resize(let size) = event,
      resizeReflowDeadline != nil || lastKnownTerminalWidth != size.width
    {
      resizeReflowDeadline = resizeReflowClock.now.advanced(by: resizeReflowDebounce)
      pendingResizeWidth = size.width
      historyReplayWindow = nil
      cachedInlineDocument = nil
    }
    if model.overlay != nil { return await updateOverlay(event) }
    if let popupUpdate = await updateSlashCommandPopup(event) { return popupUpdate }

    if case .key(let key) = event, key.kind != .release, key.key == .enter,
      key.modifiers == [.shift]
    {
      _ = model.handleComposerEvent(.paste("\n"))
      backtrackPrimed = false
      model.slashCommandSelection = 0
      model.slashPopupDismissed = false
      return .redraw
    }

    if case .key(let key) = event, key.kind != .release {
      var contexts: Set<CodexKeymapContext> = [.global, .chat]
      if !model.vimEnabled || model.vimMode == .insert { contexts.insert(.composer) }
      if let action = model.runtimeKeymap.action(for: key, contexts: contexts),
        let update = await performKeymapAction(action)
      {
        return update
      }
      if key.key == .pageUp, key.modifiers.isEmpty, !model.entries.isEmpty {
        var pager = makeTranscriptPager(backtrackCandidates: driver.rewindCandidates())
        pager.scrollUp(20)
        model.overlay = .transcript(pager)
        return .redraw
      }
    }

    if case .key(let key) = event, key.kind != .release, key.modifiers.isEmpty {
      if let selected = model.selectedImageAttachmentIndex {
        switch key.key {
        case .up:
          model.selectedImageAttachmentIndex = max(0, selected - 1)
          return .redraw
        case .down:
          model.selectedImageAttachmentIndex =
            selected + 1 < model.imageAttachments.count ? selected + 1 : nil
          return .redraw
        case .backspace, .delete:
          _ = model.removeSelectedImageAttachment()
          return .redraw
        case .escape:
          model.selectedImageAttachmentIndex = nil
          return .redraw
        default:
          model.selectedImageAttachmentIndex = nil
        }
      } else if key.key == .up, !model.imageAttachments.isEmpty {
        model.selectedImageAttachmentIndex = model.imageAttachments.count - 1
        return .redraw
      }
    }

    if case .key(let key) = event, key.kind != .release, key.key == .escape,
      key.modifiers.isEmpty, !model.isWorking, model.composer.text.isEmpty,
      !model.vimEnabled || model.vimMode == .normal
    {
      let candidates = driver.rewindCandidates()
      guard !candidates.isEmpty else {
        model.entries.append(TranscriptEntry(content: .notice("No messages to rewind to.")))
        return .redraw
      }
      if backtrackPrimed {
        model.overlay = .transcript(
          makeTranscriptPager(
            backtrackCandidates: candidates, selectedBacktrackIndex: candidates.count - 1))
        backtrackPrimed = false
        model.rightStatus = nil
      } else {
        backtrackPrimed = true
        model.rightStatus = "esc again to rewind"
      }
      return .redraw
    }

    if model.handleVimEvent(event) { return .redraw }

    if case .paste(let pastedPath) = event {
      do {
        let remoteImage = try await systemServices.remoteImage(pastedPath)
        let image: CodexImageAttachment?
        if let remoteImage {
          image = remoteImage
        } else {
          image = try await systemServices.imageFile(pastedPath, model.directory)
        }
        if let image {
          if driver.supportsImageInput {
            model.addImageAttachment(image)
          } else {
            model.entries.append(
              TranscriptEntry(
                content: .notice("The selected model does not support image input.")))
          }
          return .redraw
        }
      } catch {
        model.entries.append(
          TranscriptEntry(content: .error("Image attachment failed: \(error.localizedDescription)"))
        )
        return .redraw
      }
    }

    switch event {
    case .key(let key) where key.kind != .release:
      switch key.key {
      case .character("v") where key.modifiers.contains(.control):
        do {
          if let image = try await systemServices.clipboardImage() {
            if driver.supportsImageInput {
              model.addImageAttachment(image)
            } else {
              model.entries.append(
                TranscriptEntry(
                  content: .notice("The selected model does not support image input.")))
            }
          } else {
            model.entries.append(TranscriptEntry(content: .notice("No image found in clipboard.")))
          }
        } catch {
          model.entries.append(
            TranscriptEntry(
              content: .error("Clipboard image failed: \(error.localizedDescription)")))
        }
        return .redraw
      case .backspace where model.composer.text.isEmpty && !model.imageAttachments.isEmpty,
        .delete where model.composer.text.isEmpty && !model.imageAttachments.isEmpty:
        _ = model.removeLastImageAttachment()
        return .redraw
      case .up where model.composer.text.isEmpty:
        model.recallHistory(previous: true)
        return .redraw
      case .down where model.historyIndex != nil:
        model.recallHistory(previous: false)
        return .redraw
      case .character("c") where key.modifiers.contains(.control):
        if model.mode == .side {
          await driver.closeSideConversation()
          return .redraw
        }
        if model.isWorking {
          driver.interrupt()
          return .redraw
        }
        return .quit
      case .character("/") where key.modifiers.contains(.control):
        await driver.toggleSideConversation()
        return .redraw
      case .character("d") where key.modifiers.contains(.control) && model.composer.text.isEmpty:
        return .quit
      default:
        break
      }
    default:
      break
    }

    let composerChanged = model.handleComposerEvent(event)
    if composerChanged {
      backtrackPrimed = false
      model.slashCommandSelection = 0
      model.slashPopupDismissed = false
      if model.rightStatus == "esc again to rewind" { model.rightStatus = nil }
    }
    if composerChanged, let mention = activeComposerMention() {
      switch mention.sigil {
      case "@":
        await openFileMentionPicker(query: mention.query, queryCursor: mention.queryCursor)
      case "$":
        openSkillPicker(query: mention.query, queryCursor: mention.queryCursor)
      default:
        break
      }
      return .redraw
    }
    return composerChanged ? .redraw : .ignore
  }

  private func performKeymapAction(_ action: CodexKeymapAction) async -> ApplicationUpdate? {
    switch action {
    case .openTranscript:
      model.overlay = .transcript(
        makeTranscriptPager(backtrackCandidates: driver.rewindCandidates()))
      return .redraw
    case .openExternalEditor:
      externalEditorRequested = true
      return .suspend
    case .copy:
      await copyLastResponse()
      return .redraw
    case .clearTerminal:
      guard !model.isWorking else {
        model.entries.append(
          TranscriptEntry(content: .error("Ctrl+L is disabled while a task is in progress.")))
        return .redraw
      }
      model.entries.removeAll()
      model.overlay = nil
      return .resetTerminalHistory
    case .toggleVimMode:
      _ = model.toggleVimMode()
      return .redraw
    case .toggleRawOutput:
      await setRawOutputMode(!model.rawOutputMode, notify: false)
      return .redraw
    case .interruptTurn:
      guard model.isWorking else { return nil }
      driver.interrupt()
      return .redraw
    case .editQueuedMessage:
      guard let queued = driver.dequeueQueuedMessage(replacing: model.composer.text) else {
        return nil
      }
      model.composer = TextFieldState(text: queued)
      return .redraw
    case .submit:
      return await submitComposer(queue: false)
    case .queue:
      if model.isWorking { return await submitComposer(queue: true) }
      return completeSlashCommand() ? .redraw : nil
    case .toggleShortcuts:
      guard model.composer.text.isEmpty else { return nil }
      model.overlay = .shortcuts
      return .redraw
    case .historySearchPrevious:
      model.overlay = .historySearch(
        HistorySearch(originalDraft: model.composer, history: model.history))
      return .redraw
    case .historySearchNext:
      return nil
    }
  }

  private func submitComposer(queue: Bool) async -> ApplicationUpdate {
    guard let submission = model.takeComposerSubmission() else { return .ignore }
    let text = submission.text
    if text.hasPrefix("/") { return await runCommand(text) }
    if text.hasPrefix("!") { return await runShellCommand(String(text.dropFirst())) }

    if model.isWorking {
      if queue {
        driver.followUp(text, images: submission.images)
      } else {
        driver.steer(text, images: submission.images)
      }
    } else {
      driver.submit(text, images: submission.images)
    }
    return .redraw
  }

  private func runShellCommand(_ input: String) async -> ApplicationUpdate {
    let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !command.isEmpty else {
      model.entries.append(
        TranscriptEntry(
          content: .notice(
            "Prefix a command with ! to run it locally\nExample: !ls")))
      return .redraw
    }
    let agentWasRunning = driver.isRunning
    if !agentWasRunning {
      model.isWorking = true
      model.workingLabel = "Running local command"
    }
    let entryID = "local-shell-\(UUID().uuidString)"
    model.entries.append(
      TranscriptEntry(
        id: entryID,
        content: .tool(
          ToolActivity(
            callID: entryID, name: "shell", status: .running,
            presentation: .command(command: command, output: [], omittedLineCount: 0)))))
    do {
      let result = try await systemServices.localShell(command, model.directory)
      let lines = Self.shellOutputLines(stdout: result.stdout, stderr: result.stderr)
      let limit = 200
      let omitted = max(0, lines.count - limit)
      let shown = omitted == 0 ? lines : Array(lines.suffix(limit))
      let status: ToolActivityStatus =
        result.exitCode == 0 && !result.timedOut ? .succeeded : .failed
      if let index = model.entries.firstIndex(where: { $0.id == entryID }) {
        model.entries[index].content = .tool(
          ToolActivity(
            callID: entryID, name: "shell", output: shown, status: status,
            presentation: .command(
              command: command, output: shown, omittedLineCount: omitted)))
      }
    } catch {
      if let index = model.entries.firstIndex(where: { $0.id == entryID }) {
        model.entries[index].content = .tool(
          ToolActivity(
            callID: entryID, name: "shell", output: [error.localizedDescription], status: .failed,
            presentation: .command(
              command: command, output: [error.localizedDescription], omittedLineCount: 0)))
      }
    }
    model.isWorking = driver.isRunning
    model.workingLabel = "Working"
    return .redraw
  }

  private func settingChangeIsAllowed() -> Bool {
    guard !driver.isRunning else {
      model.rightStatus = "Finish the active turn before changing settings"
      return false
    }
    return true
  }

  private static func shellOutputLines(stdout: String, stderr: String) -> [String] {
    let combined = [stdout, stderr].filter { !$0.isEmpty }.joined(
      separator: stdout.isEmpty || stderr.isEmpty ? "" : "\n")
    guard !combined.isEmpty else { return [] }
    return combined.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  }

  private func activeSlashCommandSuggestions() -> [CodexSlashCommand] {
    guard !model.slashPopupDismissed else { return [] }
    let text = model.composer.text
    guard text.hasPrefix("/"), !text.dropFirst().contains(where: { $0.isWhitespace }) else {
      return []
    }
    return CodexSlashCommand.suggestions(
      for: text, isWorking: model.isWorking, mode: model.mode)
  }

  private func updateSlashCommandPopup(_ event: TerminalEvent) async -> ApplicationUpdate? {
    let suggestions = activeSlashCommandSuggestions()
    guard !suggestions.isEmpty, case .key(let key) = event, key.kind != .release else {
      return nil
    }
    switch key.key {
    case .up where key.modifiers.isEmpty,
      .character("p") where key.modifiers == [.control]:
      model.slashCommandSelection =
        (model.slashCommandSelection - 1 + suggestions.count) % suggestions.count
      return .redraw
    case .down where key.modifiers.isEmpty,
      .character("n") where key.modifiers == [.control]:
      model.slashCommandSelection = (model.slashCommandSelection + 1) % suggestions.count
      return .redraw
    case .escape where key.modifiers.isEmpty:
      model.slashPopupDismissed = true
      return .redraw
    case .tab where key.modifiers.isEmpty,
      .character("/") where key.modifiers.isEmpty:
      return completeSlashCommand() ? .redraw : .ignore
    case .enter where key.modifiers.isEmpty:
      guard let selected = suggestions[safe: model.slashCommandSelection] else { return .ignore }
      model.composer = TextFieldState(text: "/\(selected.name)")
      model.slashCommandSelection = 0
      return await submitComposer(queue: false)
    default:
      return nil
    }
  }

  private func completeSlashCommand() -> Bool {
    let suggestions = activeSlashCommandSuggestions()
    guard let suggestion = suggestions[safe: model.slashCommandSelection] else { return false }
    model.composer = TextFieldState(text: "/\(suggestion.name) ")
    model.slashCommandSelection = 0
    return true
  }

  private func runCommand(_ input: String) async -> ApplicationUpdate {
    let pieces = input.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
    guard let command = pieces.first else { return .redraw }
    let arguments =
      pieces.count > 1 ? pieces[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    if model.mode == .side,
      !["copy", "raw", "diff", "status", "usage", "mention", "ide"].contains(command)
    {
      model.entries.append(
        TranscriptEntry(
          content: .error(
            "'/\(command)' is unavailable in side conversations. Press Ctrl+C to return to the main thread first."
          )))
      return .redraw
    }
    switch command {
    case "quit":
      return .quit
    case "plan":
      driver.selectMode(model.mode == .plan ? .defaultMode : .plan)
      if !arguments.isEmpty { driver.submit(arguments) }
    case "side", "btw":
      do {
        try await driver.startSideConversation(prompt: arguments.isEmpty ? nil : arguments)
      } catch {
        model.entries.append(TranscriptEntry(content: .error(error.localizedDescription)))
      }
    case "clear", "new":
      do {
        try await driver.startNewSession()
        if !arguments.isEmpty { try await driver.renameSession(arguments) }
      } catch {
        appendSessionError(error)
      }
    case "status":
      let remaining = driver.contextRemainingPercent() ?? model.contextRemainingPercent
      model.contextRemainingPercent = remaining
      model.entries.append(
        TranscriptEntry(
          content: .notice(
            "Model: \(model.model) \(model.reasoningEffort) · Permissions: \(model.permissionMode.rawValue) · Directory: \(model.directory) · Context: \(remaining)%"
          )))
    case "model":
      let models = driver.availableModels
      if models.isEmpty {
        model.entries.append(
          TranscriptEntry(
            content: .notice(
              "No authenticated model providers are available.")))
      } else {
        let current =
          models.firstIndex {
            $0.modelID == model.model
              && (model.modelProvider.isEmpty || $0.provider == model.modelProvider)
          } ?? 0
        model.overlay = .models(ModelPicker(models: models, selectedIndex: current))
      }
    case "thinking", "verbose", "context", "queue", "tools":
      model.entries.append(
        TranscriptEntry(content: .notice(driver.runtimeCommand(command, arguments: arguments))))
    case "init":
      guard arguments.isEmpty else {
        model.entries.append(TranscriptEntry(content: .error("Usage: /init")))
        return .redraw
      }
      driver.submit(
        "Inspect this repository thoroughly, then create or improve AGENTS.md with concise, actionable instructions for coding agents. Preserve existing useful guidance and verify relevant commands before documenting them."
      )
    case "mention":
      await openFileMentionPicker(query: arguments)
    case "hotkeys":
      model.entries.append(
        TranscriptEntry(
          content: .notice(
            """
            Keyboard shortcuts
              Enter         submit or run selected command
              Esc           interrupt work or close a popup
              Ctrl+C        close a side conversation or exit
              Ctrl+/        switch main and side conversations
              Ctrl+R        search prompt history
              Option+R      toggle raw scrollback mode
              Up/Down       navigate history and popups
              Tab           complete or advance selection
            """)))
    case "help":
      let commands = CodexSlashCommand.builtins.map { "/\($0.name) — \($0.description)" }
      model.entries.append(
        TranscriptEntry(
          content: .notice((["Available slash commands"] + commands).joined(separator: "\n"))))
    case "permissions":
      model.overlay = .permissions(
        PermissionPicker(selectedIndex: model.permissionMode == .askForApproval ? 0 : 1))
    case "keymap":
      guard !model.isWorking else {
        model.entries.append(
          TranscriptEntry(content: .error("'/keymap' is unavailable while a task is running.")))
        return .redraw
      }
      guard arguments.isEmpty || arguments == "debug" else {
        model.entries.append(TranscriptEntry(content: .error("Usage: /keymap [debug]")))
        return .redraw
      }
      if arguments == "debug" {
        model.overlay = .keymapDebug(CodexKeymapDebug(runtime: model.runtimeKeymap))
      } else {
        model.overlay = .keymap(
          CodexKeymapPicker(configuration: model.runtimeKeymap.configuration))
      }
    case "vim":
      guard arguments.isEmpty else {
        model.entries.append(TranscriptEntry(content: .error("Usage: /vim")))
        return .redraw
      }
      let enabled = model.toggleVimMode()
      model.entries.append(
        TranscriptEntry(content: .notice(enabled ? "Vim mode enabled." : "Vim mode disabled.")))
    case "personality":
      model.overlay = .personality(
        PersonalityPicker(selectedIndex: model.personality == .friendly ? 0 : 1))
    case "theme":
      let themes = await systemServices.syntaxThemes()
      let selectedIndex = themes.firstIndex(where: { $0.name == model.syntaxTheme.name }) ?? 0
      model.overlay = .theme(
        ThemePicker(
          themes: themes, selectedIndex: selectedIndex,
          originalThemeName: model.syntaxTheme.name))
    case "review":
      if arguments.isEmpty {
        model.overlay = .review(ReviewPicker())
      } else {
        driver.submit("Review the current changes with these instructions: \(arguments)")
      }
    case "copy":
      await copyLastResponse()
    case "raw":
      switch arguments.lowercased() {
      case "":
        await setRawOutputMode(!model.rawOutputMode, notify: true)
      case "on":
        await setRawOutputMode(true, notify: true)
      case "off":
        await setRawOutputMode(false, notify: true)
      default:
        model.entries.append(TranscriptEntry(content: .error("Usage: /raw [on|off]")))
      }
    case "diff":
      model.entries.append(TranscriptEntry(content: .notice("Computing git diff…")))
      do {
        let diff = try await systemServices.gitDiff(model.directory)
        model.entries.removeAll {
          if case .notice("Computing git diff…") = $0.content { return true }
          return false
        }
        model.entries.append(
          TranscriptEntry(content: .assistant("```diff\n\(diff)\n```", streaming: false)))
      } catch {
        model.entries.removeAll {
          if case .notice("Computing git diff…") = $0.content { return true }
          return false
        }
        model.entries.append(
          TranscriptEntry(content: .error("Failed to compute diff: \(error.localizedDescription)")))
      }
    case "compact":
      await driver.compactSession()
    case "retry":
      if !driver.retryLastPrompt() {
        model.entries.append(TranscriptEntry(content: .notice("Nothing to retry.")))
      }
    case "rewind":
      let candidates = driver.rewindCandidates()
      if candidates.isEmpty {
        model.entries.append(TranscriptEntry(content: .notice("No messages to rewind to.")))
      } else {
        model.overlay = .rewind(RewindPicker(candidates: candidates))
      }
    case "goal":
      driver.goalCommand(arguments)
    case "agent":
      model.overlay = .agents(AgentPicker(threads: await driver.agentThreads()))
    case "skills":
      openSkillPicker(query: arguments)
    case "ps":
      model.overlay = .backgroundTasks(
        BackgroundTaskPicker(tasks: await driver.backgroundTasks()))
    case "usage":
      model.entries.append(TranscriptEntry(content: .notice(driver.usageSummary())))
    case "resume":
      let sessions = await driver.sessions()
      if sessions.isEmpty {
        model.entries.append(TranscriptEntry(content: .notice("No saved sessions found.")))
      } else {
        model.overlay = .sessions(
          SessionPicker(
            action: .resume, sessions: sessions,
            currentDirectory: model.directory))
      }
    case "fork":
      do {
        try await driver.activateSession(id: model.sessionID, fork: true)
        if !arguments.isEmpty { try await driver.renameSession(arguments) }
      } catch {
        appendSessionError(error)
      }
    case "rename":
      model.overlay = .rename(RenameThreadPrompt(name: model.threadTitle ?? ""))
    case "archive":
      model.overlay = .sessionConfirmation(SessionActionConfirmation(action: .archive))
    case "delete":
      model.overlay = .sessionConfirmation(SessionActionConfirmation(action: .delete))
    case "stop":
      let count = await driver.stopBackgroundTasks()
      model.entries.append(
        TranscriptEntry(
          content: .notice(
            count == 0
              ? "No background terminals are running" : "Stopped \(count) background terminal(s)"
          )))
    default:
      model.entries.append(
        TranscriptEntry(
          content: .error("Unknown command '/\(command)'. Type /help to list available commands.")))
    }
    return .redraw
  }

  public func performSuspendedAction() async {
    guard externalEditorRequested else { return }
    externalEditorRequested = false
    let seed = model.composerTextWithPendingPastes()
    do {
      var edited = try await systemServices.editDraft(seed)
      while edited.last?.isWhitespace == true { edited.removeLast() }
      model.applyExternalEdit(edited)
    } catch {
      let message =
        error is SystemServiceError
        ? error.localizedDescription : "Failed to open editor: \(error.localizedDescription)"
      model.entries.append(TranscriptEntry(content: .error(message)))
    }
  }

  private func copyLastResponse() async {
    guard
      let markdown = model.entries.reversed().compactMap({ entry -> String? in
        if case .assistant(let text, _) = entry.content { return text }
        return nil
      }).first, !markdown.isEmpty
    else {
      model.entries.append(TranscriptEntry(content: .error("No agent response to copy")))
      return
    }
    do {
      try await systemServices.copyToClipboard(markdown)
      model.entries.append(TranscriptEntry(content: .notice("Copied last message to clipboard")))
    } catch {
      model.entries.append(
        TranscriptEntry(content: .error("Copy failed: \(error.localizedDescription)")))
    }
  }

  private func setRawOutputMode(_ enabled: Bool, notify: Bool) async {
    model.rawOutputMode = enabled
    if notify {
      model.entries.append(
        TranscriptEntry(
          content: .notice(
            enabled
              ? "Raw output mode on: transcript text is shown for clean terminal selection."
              : "Raw output mode off: rich transcript rendering restored."
          )))
    }
    do {
      try await systemServices.saveRawOutputMode(enabled)
    } catch {
      model.entries.append(
        TranscriptEntry(
          content: .error("Failed to save raw output mode: \(error.localizedDescription)")))
    }
  }

  private func applyKeymapEdit(
    action: CodexKeymapAction, bindings: [CodexKeyBinding]?
  ) async {
    let previous = model.runtimeKeymap
    do {
      let candidate = try previous.replacing(action, with: bindings)
      try await systemServices.saveKeymap(candidate.configuration)
      model.runtimeKeymap = candidate
      let selected = CodexKeymapAction.allCases.firstIndex(of: action) ?? 0
      model.overlay = .keymap(
        CodexKeymapPicker(
          configuration: candidate.configuration, selectedIndex: selected))
      let message =
        bindings == nil
        ? "Removed custom shortcut for \(action.path)."
        : "Remapped \(action.path) to \(bindings!.map(\.canonicalName).joined(separator: ", "))."
      model.entries.append(TranscriptEntry(content: .notice(message)))
    } catch {
      model.entries.append(
        TranscriptEntry(content: .error("Shortcut not changed: \(error.localizedDescription)")))
      model.overlay = .keymapAction(
        CodexKeymapActionMenu(action: action, configuration: previous.configuration))
    }
  }

  private func updateOverlay(_ event: TerminalEvent) async -> ApplicationUpdate {
    if case .resize = event { return .redraw }
    if case .keymap(var picker) = model.overlay, case .paste(let text) = event {
      picker.query.append(contentsOf: text)
      picker.selectedIndex = 0
      picker.reconcileSelection()
      model.overlay = .keymap(picker)
      return .redraw
    }
    if case .requestUserInput(var request) = model.overlay {
      return updateRequestUserInput(&request, event: event)
    }
    if isComposerMentionPopup, eventInsertsWhitespace(event) {
      model.overlay = nil
      _ = model.handleComposerEvent(event)
      return .redraw
    }
    if case .fileMentions(var picker) = model.overlay {
      if picker.query.text.isEmpty, case .key(let key) = event, key.key == .backspace {
        model.overlay = nil
        _ = model.composer.handle(event)
        return .redraw
      }
      if case .key(let key) = event,
        (key.key == .left && picker.query.cursor == 0)
          || (key.key == .right && picker.query.cursor == picker.query.text.count)
      {
        model.overlay = nil
        _ = model.handleComposerEvent(event)
        return .redraw
      }
      let editsQuery: Bool
      switch event {
      case .paste:
        editsQuery = true
      case .key(let key):
        switch key.key {
        case .character, .backspace, .delete, .left, .right, .home, .end:
          editsQuery = true
        default:
          editsQuery = false
        }
      default:
        editsQuery = false
      }
      if editsQuery, picker.query.handle(event) {
        picker.selectedIndex = 0
        picker.reconcileSelection()
        synchronizeComposerMentionQuery(with: picker.query, sigil: "@")
        model.overlay = .fileMentions(picker)
        return .redraw
      }
    }
    if case .skills(var picker) = model.overlay {
      if picker.query.text.isEmpty, case .key(let key) = event, key.key == .backspace {
        model.overlay = nil
        _ = model.composer.handle(event)
        return .redraw
      }
      if case .key(let key) = event,
        (key.key == .left && picker.query.cursor == 0)
          || (key.key == .right && picker.query.cursor == picker.query.text.count)
      {
        model.overlay = nil
        _ = model.handleComposerEvent(event)
        return .redraw
      }
      let editsQuery: Bool
      switch event {
      case .paste:
        editsQuery = true
      case .key(let key):
        switch key.key {
        case .character, .backspace, .delete, .left, .right, .home, .end:
          editsQuery = true
        default:
          editsQuery = false
        }
      default:
        editsQuery = false
      }
      if editsQuery, picker.query.handle(event) {
        picker.selectedIndex = 0
        picker.reconcileSelection()
        synchronizeComposerMentionQuery(with: picker.query, sigil: "$")
        model.overlay = .skills(picker)
        return .redraw
      }
    }
    if case .theme(var picker) = model.overlay {
      let editsQuery: Bool
      switch event {
      case .paste:
        editsQuery = true
      case .key(let key):
        switch key.key {
        case .character, .backspace, .delete, .left, .right, .home, .end:
          editsQuery = true
        default:
          editsQuery = false
        }
      default:
        editsQuery = false
      }
      if editsQuery, picker.query.handle(event) {
        picker.selectedIndex = 0
        picker.reconcileSelection()
        if let selected = picker.selectedTheme { model.syntaxTheme = selected }
        model.overlay = .theme(picker)
        return .redraw
      }
    }
    guard case .key(let key) = event, key.kind != .release else { return .ignore }
    switch model.overlay {
    case .transcript(var pager):
      switch key.key {
      case .character("q"):
        model.overlay = nil
      case .character("t") where key.modifiers.contains(.control):
        model.overlay = nil
      case .escape, .left:
        if pager.backtrackCandidates.isEmpty {
          model.overlay = nil
        } else {
          let current = pager.selectedBacktrackIndex ?? pager.backtrackCandidates.count
          let selected = max(0, current - 1)
          pager.selectedBacktrackIndex = selected
          pager.scrollFromBottom = (pager.backtrackCandidates.count - 1 - selected) * 6
          model.overlay = .transcript(pager)
        }
      case .right:
        guard let selected = pager.selectedBacktrackIndex else { return .ignore }
        let next = min(pager.backtrackCandidates.count - 1, selected + 1)
        pager.selectedBacktrackIndex = next
        pager.scrollFromBottom = (pager.backtrackCandidates.count - 1 - next) * 6
        model.overlay = .transcript(pager)
      case .enter:
        guard let selected = pager.selectedBacktrackIndex,
          pager.backtrackCandidates.indices.contains(selected)
        else { return .ignore }
        do {
          let draft = try await driver.rewind(to: pager.backtrackCandidates[selected].id)
          model.applyExternalEdit(draft.text)
          model.imageAttachments = draft.images
          model.overlay = nil
        } catch {
          model.entries.append(
            TranscriptEntry(content: .error("Rewind failed: \(error.localizedDescription)")))
          model.overlay = nil
        }
      case .up, .character("k"):
        pager.scrollUp()
        model.overlay = .transcript(pager)
      case .down, .character("j"):
        pager.scrollDown()
        model.overlay = .transcript(pager)
      case .pageUp:
        pager.scrollUp(20)
        model.overlay = .transcript(pager)
      case .pageDown:
        pager.scrollDown(20)
        model.overlay = .transcript(pager)
      case .character("u") where key.modifiers.contains(.control):
        pager.scrollUp(10)
        model.overlay = .transcript(pager)
      case .character("d") where key.modifiers.contains(.control):
        pager.scrollDown(10)
        model.overlay = .transcript(pager)
      case .home:
        pager.jumpToTop()
        model.overlay = .transcript(pager)
      case .end:
        pager.jumpToBottom()
        model.overlay = .transcript(pager)
      default:
        return .ignore
      }
      return .redraw
    case .shortcuts:
      if key.key == .escape || key.key == .enter || key.key == .character("?") {
        model.overlay = nil
        return .redraw
      }
    case .approval(var request):
      switch key.key {
      case .escape:
        _ = driver.resolveApproval(requestID: request.id, decision: .cancel)
      case .up, .character("k"):
        request.selection.move(by: -1, itemCount: request.choices.count)
        model.overlay = .approval(request)
      case .down, .character("j"):
        request.selection.move(by: 1, itemCount: request.choices.count)
        model.overlay = .approval(request)
      case .enter:
        guard let choice = request.choices[safe: request.selectedIndex] else { return .ignore }
        _ = driver.resolveApproval(requestID: request.id, decision: choice.decision)
      case .character(let character):
        if let number = character.wholeNumberValue, number > 0, number <= request.choices.count {
          request.selection.select(number - 1, itemCount: request.choices.count)
          model.overlay = .approval(request)
        } else if let choice = request.choices.first(where: { $0.shortcut == String(character) }) {
          _ = driver.resolveApproval(requestID: request.id, decision: choice.decision)
        } else {
          return .ignore
        }
      default:
        return .ignore
      }
      return .redraw
    case .requestUserInput:
      break
    case .models(var picker):
      switch key.key {
      case .escape where !picker.query.isEmpty:
        picker.query = ""
        picker.selectedIndex = 0
        model.overlay = .models(picker)
      case .escape:
        model.overlay = nil
      case .up,
        .character("p") where key.modifiers.contains(.control):
        picker.selectedIndex = max(0, picker.selectedIndex - 1)
        model.overlay = .models(picker)
      case .down,
        .character("n") where key.modifiers.contains(.control):
        picker.selectedIndex = min(
          max(0, picker.filteredModels.count - 1), picker.selectedIndex + 1)
        model.overlay = .models(picker)
      case .home:
        picker.selectedIndex = 0
        model.overlay = .models(picker)
      case .end:
        picker.selectedIndex = max(0, picker.filteredModels.count - 1)
        model.overlay = .models(picker)
      case .pageUp:
        picker.selectedIndex = max(0, picker.selectedIndex - 10)
        model.overlay = .models(picker)
      case .pageDown:
        picker.selectedIndex = min(
          max(0, picker.filteredModels.count - 1), picker.selectedIndex + 10)
        model.overlay = .models(picker)
      case .backspace:
        if !picker.query.isEmpty { picker.query.removeLast() }
        picker.selectedIndex = 0
        model.overlay = .models(picker)
      case .character(let character)
      where key.modifiers.intersection([.control, .option, .command, .meta, .hyper]).isEmpty:
        picker.query.append(character)
        picker.selectedIndex = 0
        model.overlay = .models(picker)
      case .enter:
        guard let selected = picker.filteredModels[safe: picker.selectedIndex] else {
          return .ignore
        }
        let options = driver.reasoningOptions(modelID: selected.id)
        if options.isEmpty {
          guard settingChangeIsAllowed() else { return .redraw }
          driver.selectModel(id: selected.id)
          model.overlay = nil
        } else {
          let current = options.firstIndex(where: { $0.id == model.reasoningEffort }) ?? 0
          model.overlay = .reasoning(
            ReasoningPicker(
              modelID: selected.id, modelName: selected.modelID,
              options: options, selectedIndex: current))
        }
      default:
        return .ignore
      }
      return .redraw
    case .reasoning(var picker):
      switch key.key {
      case .escape:
        let models = driver.availableModels
        let current = models.firstIndex(where: { $0.id == picker.modelID }) ?? 0
        model.overlay = .models(ModelPicker(models: models, selectedIndex: current))
      case .up:
        picker.selectedIndex = max(0, picker.selectedIndex - 1)
        model.overlay = .reasoning(picker)
      case .down:
        picker.selectedIndex = min(picker.options.count - 1, picker.selectedIndex + 1)
        model.overlay = .reasoning(picker)
      case .enter:
        guard let option = picker.options[safe: picker.selectedIndex] else { return .ignore }
        guard settingChangeIsAllowed() else { return .redraw }
        driver.selectModel(id: picker.modelID, reasoningID: option.id)
        model.overlay = nil
      default:
        return .ignore
      }
      return .redraw
    case .permissions(var picker):
      if picker.confirmingFullAccess {
        switch key.key {
        case .escape:
          picker.confirmingFullAccess = false
          picker.selectedIndex = 1
          model.overlay = .permissions(picker)
        case .up, .down:
          picker.selectedIndex = picker.selectedIndex == 0 ? 1 : 0
          model.overlay = .permissions(picker)
        case .enter:
          if picker.selectedIndex == 0 {
            guard settingChangeIsAllowed() else { return .redraw }
            driver.selectPermissionMode(.fullAccess)
            model.overlay = nil
          } else {
            picker.confirmingFullAccess = false
            picker.selectedIndex = 1
            model.overlay = .permissions(picker)
          }
        default:
          return .ignore
        }
      } else {
        switch key.key {
        case .escape:
          model.overlay = nil
        case .up, .down:
          picker.selectedIndex = picker.selectedIndex == 0 ? 1 : 0
          model.overlay = .permissions(picker)
        case .enter:
          if picker.selectedIndex == 0 {
            guard settingChangeIsAllowed() else { return .redraw }
            driver.selectPermissionMode(.askForApproval)
            model.overlay = nil
          } else {
            picker.confirmingFullAccess = true
            picker.selectedIndex = 0
            model.overlay = .permissions(picker)
          }
        default:
          return .ignore
        }
      }
      return .redraw
    case .personality(var picker):
      switch key.key {
      case .escape:
        model.overlay = nil
      case .up, .down:
        picker.selectedIndex = picker.selectedIndex == 0 ? 1 : 0
        model.overlay = .personality(picker)
      case .enter:
        guard settingChangeIsAllowed() else { return .redraw }
        driver.selectPersonality(picker.selectedIndex == 0 ? .friendly : .pragmatic)
        model.overlay = nil
      default:
        return .ignore
      }
      return .redraw
    case .keymap(var picker):
      switch key.key {
      case .escape:
        model.overlay = nil
      case .left:
        picker.selectAdjacentTab(forward: false)
        model.overlay = .keymap(picker)
      case .right:
        picker.selectAdjacentTab(forward: true)
        model.overlay = .keymap(picker)
      case .up,
        .character("p") where key.modifiers.contains(.control),
        .character("k") where key.modifiers.contains(.control):
        picker.selectedIndex = max(0, picker.selectedIndex - 1)
        model.overlay = .keymap(picker)
      case .down,
        .character("n") where key.modifiers.contains(.control),
        .character("j") where key.modifiers.contains(.control):
        picker.selectedIndex = min(
          max(0, picker.filteredActions.count - 1), picker.selectedIndex + 1)
        model.overlay = .keymap(picker)
      case .home:
        picker.selectedIndex = 0
        model.overlay = .keymap(picker)
      case .end:
        picker.selectedIndex = max(0, picker.filteredActions.count - 1)
        model.overlay = .keymap(picker)
      case .pageUp:
        picker.selectedIndex = max(0, picker.selectedIndex - 10)
        model.overlay = .keymap(picker)
      case .pageDown:
        picker.selectedIndex = min(
          max(0, picker.filteredActions.count - 1), picker.selectedIndex + 10)
        model.overlay = .keymap(picker)
      case .enter:
        if picker.tab == .debug {
          model.overlay = .keymapDebug(CodexKeymapDebug(runtime: picker.runtime))
        } else {
          guard let action = picker.selectedAction else { return .ignore }
          model.overlay = .keymapAction(
            CodexKeymapActionMenu(action: action, configuration: picker.configuration))
        }
      case .backspace, .delete:
        if !picker.query.isEmpty { picker.query.removeLast() }
        picker.selectedIndex = 0
        model.overlay = .keymap(picker)
      case .character(let character)
      where key.modifiers.intersection([.control, .option, .command, .hyper, .meta]).isEmpty:
        picker.query.append(character)
        picker.selectedIndex = 0
        model.overlay = .keymap(picker)
      default:
        return .ignore
      }
      return .redraw
    case .keymapAction(var menu):
      switch key.key {
      case .escape:
        model.overlay = .keymap(
          CodexKeymapPicker(configuration: menu.configuration))
      case .up:
        menu.selectedIndex = max(0, menu.selectedIndex - 1)
        model.overlay = .keymapAction(menu)
      case .down:
        menu.selectedIndex = min(menu.operations.count - 1, menu.selectedIndex + 1)
        model.overlay = .keymapAction(menu)
      case .enter:
        let operation = menu.operations[menu.selectedIndex]
        switch operation {
        case .replaceAll, .addAlternate:
          model.overlay = .keymapCapture(
            CodexKeymapCapture(
              action: menu.action, operation: operation, configuration: menu.configuration))
        case .removeCustom:
          await applyKeymapEdit(action: menu.action, bindings: nil)
        case .back:
          model.overlay = .keymap(CodexKeymapPicker(configuration: menu.configuration))
        }
      default:
        return .ignore
      }
      return .redraw
    case .keymapDebug(var debug):
      if key.key == .character("c"), key.modifiers.contains(.control) {
        model.overlay = nil
        return .redraw
      }
      debug.inspect(key)
      model.overlay = .keymapDebug(debug)
      return key.kind == .release ? .ignore : .redraw
    case .keymapCapture(let capture):
      if key.key == .escape {
        model.overlay = .keymapAction(
          CodexKeymapActionMenu(
            action: capture.action, configuration: capture.configuration))
        return .redraw
      }
      guard key.kind == .press else { return .ignore }
      let binding: CodexKeyBinding
      do {
        binding = try CodexKeyBinding(event: key)
      } catch {
        model.entries.append(
          TranscriptEntry(content: .error("Cannot capture shortcut: \(error.localizedDescription)"))
        )
        return .redraw
      }
      let current =
        (try? CodexRuntimeKeymap(configuration: capture.configuration))?
        .bindings(for: capture.action) ?? []
      let bindings: [CodexKeyBinding]
      switch capture.operation {
      case .replaceAll:
        bindings = [binding]
      case .addAlternate:
        if current.contains(binding) {
          model.entries.append(
            TranscriptEntry(
              content: .notice(
                "No change: \(capture.action.path) already uses \(binding.canonicalName).")))
          model.overlay = .keymap(
            CodexKeymapPicker(configuration: capture.configuration))
          return .redraw
        }
        bindings = current + [binding]
      case .removeCustom, .back:
        return .ignore
      }
      await applyKeymapEdit(action: capture.action, bindings: bindings)
      return .redraw
    case .theme(var picker):
      switch key.key {
      case .escape:
        if let original = picker.themes.first(where: { $0.name == picker.originalThemeName }) {
          model.syntaxTheme = original
        }
        model.overlay = nil
      case .character("c") where key.modifiers.contains(.control):
        if let original = picker.themes.first(where: { $0.name == picker.originalThemeName }) {
          model.syntaxTheme = original
        }
        model.overlay = nil
      case .up:
        picker.selectedIndex = max(0, picker.selectedIndex - 1)
        if let selected = picker.selectedTheme { model.syntaxTheme = selected }
        model.overlay = .theme(picker)
      case .down:
        picker.selectedIndex = min(
          max(0, picker.filteredThemes.count - 1), picker.selectedIndex + 1)
        if let selected = picker.selectedTheme { model.syntaxTheme = selected }
        model.overlay = .theme(picker)
      case .pageUp:
        picker.selectedIndex = max(0, picker.selectedIndex - 10)
        if let selected = picker.selectedTheme { model.syntaxTheme = selected }
        model.overlay = .theme(picker)
      case .pageDown:
        picker.selectedIndex = min(
          max(0, picker.filteredThemes.count - 1), picker.selectedIndex + 10)
        if let selected = picker.selectedTheme { model.syntaxTheme = selected }
        model.overlay = .theme(picker)
      case .enter:
        guard let selected = picker.selectedTheme else { return .ignore }
        do {
          try await systemServices.saveSyntaxTheme(selected.name)
          model.syntaxTheme = selected
          model.overlay = nil
        } catch {
          model.entries.append(
            TranscriptEntry(
              content: .error("Failed to save syntax theme: \(error.localizedDescription)")))
        }
      default:
        return .ignore
      }
      return .redraw
    case .sessions(var picker):
      switch key.key {
      case .escape:
        model.overlay = nil
      case .up:
        picker.selection.move(by: -1, itemCount: picker.filteredSessions.count)
        model.overlay = .sessions(picker)
      case .down:
        picker.selection.move(by: 1, itemCount: picker.filteredSessions.count)
        model.overlay = .sessions(picker)
      case .pageUp:
        picker.selection.move(by: -10, itemCount: picker.filteredSessions.count)
        model.overlay = .sessions(picker)
      case .pageDown:
        picker.selection.move(by: 10, itemCount: picker.filteredSessions.count)
        model.overlay = .sessions(picker)
      case .tab:
        picker.showAllDirectories.toggle()
        picker.reconcileSelection()
        model.overlay = .sessions(picker)
      case .enter:
        guard let selected = picker.filteredSessions[safe: picker.selectedIndex] else {
          return .ignore
        }
        model.overlay = nil
        do {
          try await driver.activateSession(id: selected.id, fork: picker.action == .fork)
        } catch {
          appendSessionError(error)
        }
      default:
        if picker.query.handle(event) {
          picker.reconcileSelection()
          model.overlay = .sessions(picker)
        } else {
          return .ignore
        }
      }
      return .redraw
    case .rename(var prompt):
      switch key.key {
      case .escape:
        model.overlay = nil
      case .enter:
        let title = prompt.name.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .ignore }
        do {
          try await driver.renameSession(title)
          model.overlay = nil
        } catch {
          appendSessionError(error)
        }
      default:
        guard prompt.name.handle(event) else { return .ignore }
        model.overlay = .rename(prompt)
      }
      return .redraw
    case .sessionConfirmation(var confirmation):
      switch key.key {
      case .escape:
        model.overlay = nil
      case .up, .down:
        confirmation.selectedIndex = confirmation.selectedIndex == 0 ? 1 : 0
        model.overlay = .sessionConfirmation(confirmation)
      case .enter:
        guard confirmation.selectedIndex == 1 else {
          model.overlay = nil
          return .redraw
        }
        do {
          switch confirmation.action {
          case .archive: try await driver.archiveSession()
          case .delete: try await driver.deleteSession()
          }
          return .quit
        } catch {
          appendSessionError(error)
          return .redraw
        }
      default:
        return .ignore
      }
      return .redraw
    case .historySearch(var search):
      let previousBindings = model.runtimeKeymap.bindings(for: .historySearchPrevious)
      let nextBindings = model.runtimeKeymap.bindings(for: .historySearchNext)
      switch key.key {
      case .escape:
        model.composer = search.originalDraft
        model.overlay = nil
      case .enter:
        if let index = search.selectedIndex, search.matches.indices.contains(index) {
          model.composer = TextFieldState(text: search.matches[index])
        } else {
          model.composer = search.originalDraft
        }
        model.overlay = nil
      case _ where key.key == .up || previousBindings.contains(where: { $0.matches(key) }):
        guard !search.matches.isEmpty else { return .ignore }
        search.selectedIndex = min((search.selectedIndex ?? -1) + 1, search.matches.count - 1)
        model.overlay = .historySearch(search)
      case _ where key.key == .down || nextBindings.contains(where: { $0.matches(key) }):
        guard !search.matches.isEmpty else { return .ignore }
        search.selectedIndex = max((search.selectedIndex ?? 1) - 1, 0)
        model.overlay = .historySearch(search)
      default:
        guard search.query.handle(event) else { return .ignore }
        search.refresh(history: model.history)
        search.selectedIndex = search.matches.isEmpty ? nil : 0
        model.overlay = .historySearch(search)
      }
      return .redraw
    case .review(var picker):
      switch key.key {
      case .escape:
        model.overlay = nil
      case .up:
        picker.selectedIndex = max(0, picker.selectedIndex - 1)
        model.overlay = .review(picker)
      case .down:
        picker.selectedIndex = min(3, picker.selectedIndex + 1)
        model.overlay = .review(picker)
      case .enter:
        model.overlay = nil
        switch picker.selectedIndex {
        case 0:
          driver.submit(
            "Review the current changes against the base branch. Focus on actionable defects, regressions, and missing tests."
          )
        case 1:
          driver.submit(
            "Review all uncommitted changes. Focus on actionable defects, regressions, and missing tests."
          )
        case 2:
          driver.submit(
            "Review the most recent commit. Focus on actionable defects, regressions, and missing tests."
          )
        default:
          model.composer = TextFieldState(text: "/review ")
        }
      default:
        return .ignore
      }
      return .redraw
    case .agents(var picker):
      switch key.key {
      case .escape:
        model.overlay = nil
      case .up:
        picker.selectedIndex = max(0, picker.selectedIndex - 1)
        model.overlay = .agents(picker)
      case .down:
        picker.selectedIndex = min(max(0, picker.threads.count - 1), picker.selectedIndex + 1)
        model.overlay = .agents(picker)
      case .enter:
        guard let selected = picker.threads[safe: picker.selectedIndex] else { return .ignore }
        if selected.role == "main" {
          model.overlay = nil
        } else {
          model.overlay = .agentPreview(AgentThreadPreview(thread: selected))
        }
      default:
        return .ignore
      }
      return .redraw
    case .agentPreview(let preview):
      if key.key == .escape || (key.key == .left && !key.modifiers.contains(.option)) {
        model.overlay = .agents(AgentPicker(threads: await driver.agentThreads()))
        return .redraw
      }
      if key.modifiers.contains(.option), key.key == .left || key.key == .right {
        let threads = await driver.agentThreads()
        guard threads.count > 1,
          let current = threads.firstIndex(where: { $0.id == preview.thread.id })
        else { return .ignore }
        let next =
          key.key == .right
          ? (current + 1) % threads.count
          : (current == 0 ? threads.count - 1 : current - 1)
        let selected = threads[next]
        model.overlay =
          selected.role == "main" ? nil : .agentPreview(AgentThreadPreview(thread: selected))
        return .redraw
      }
      return .ignore
    case .backgroundTasks(var picker):
      switch key.key {
      case .escape, .enter:
        model.overlay = nil
      case .up:
        picker.selectedIndex = max(0, picker.selectedIndex - 1)
        model.overlay = .backgroundTasks(picker)
      case .down:
        picker.selectedIndex = min(max(0, picker.tasks.count - 1), picker.selectedIndex + 1)
        model.overlay = .backgroundTasks(picker)
      default:
        return .ignore
      }
      return .redraw
    case .skills(var picker):
      switch key.key {
      case .escape:
        model.overlay = nil
      case .up,
        .character("p") where key.modifiers.contains(.control):
        let count = picker.filteredSkills.count
        if count > 0 { picker.selectedIndex = (picker.selectedIndex - 1 + count) % count }
        model.overlay = .skills(picker)
      case .down,
        .character("n") where key.modifiers.contains(.control):
        let count = picker.filteredSkills.count
        if count > 0 { picker.selectedIndex = (picker.selectedIndex + 1) % count }
        model.overlay = .skills(picker)
      case .enter, .tab:
        guard let selected = picker.filteredSkills[safe: picker.selectedIndex] else {
          return .ignore
        }
        insertSkillMention(selected)
        model.overlay = nil
      default:
        return .ignore
      }
      return .redraw
    case .fileMentions(var picker):
      switch key.key {
      case .escape:
        model.overlay = nil
      case .up,
        .character("p") where key.modifiers.contains(.control):
        let count = picker.filteredFiles.count
        if count > 0 { picker.selectedIndex = (picker.selectedIndex - 1 + count) % count }
        model.overlay = .fileMentions(picker)
      case .down,
        .character("n") where key.modifiers.contains(.control):
        let count = picker.filteredFiles.count
        if count > 0 { picker.selectedIndex = (picker.selectedIndex + 1) % count }
        model.overlay = .fileMentions(picker)
      case .enter, .tab:
        guard let selected = picker.filteredFiles[safe: picker.selectedIndex] else {
          return .ignore
        }
        insertFileMention(selected)
        model.overlay = nil
      default:
        return .ignore
      }
      return .redraw
    case .rewind(var picker):
      switch key.key {
      case .escape:
        model.overlay = nil
      case .up:
        picker.selectedIndex = max(0, picker.selectedIndex - 1)
        model.overlay = .rewind(picker)
      case .down:
        picker.selectedIndex = min(max(0, picker.candidates.count - 1), picker.selectedIndex + 1)
        model.overlay = .rewind(picker)
      case .enter:
        guard let candidate = picker.candidates[safe: picker.selectedIndex] else { return .ignore }
        model.overlay = nil
        do {
          let draft = try await driver.rewind(to: candidate.id)
          model.composer = TextFieldState(text: draft.text)
          model.imageAttachments = draft.images
        } catch {
          appendSessionError(error)
        }
      default:
        return .ignore
      }
      return .redraw
    case nil:
      break
    }
    return .ignore
  }

  private func appendSessionError(_ error: Error) {
    model.overlay = nil
    model.entries.append(
      TranscriptEntry(content: .error("Session operation failed: \(error.localizedDescription)")))
  }

  private func openSkillPicker(query: String, queryCursor: Int? = nil) {
    let skills = driver.skills()
    if skills.isEmpty {
      model.entries.append(TranscriptEntry(content: .notice("No skills available.")))
    } else {
      var picker = SkillPicker(skills: skills, query: query)
      picker.query.cursor = min(max(0, queryCursor ?? query.count), query.count)
      model.overlay = .skills(picker)
    }
  }

  private func openFileMentionPicker(query: String, queryCursor: Int? = nil) async {
    do {
      let files = try await systemServices.projectFiles(model.directory)
      if files.isEmpty {
        model.entries.append(TranscriptEntry(content: .notice("No project files found.")))
      } else {
        var picker = FileMentionPicker(files: files, query: query)
        picker.query.cursor = min(max(0, queryCursor ?? query.count), query.count)
        model.overlay = .fileMentions(picker)
      }
    } catch {
      model.entries.append(
        TranscriptEntry(
          content: .error("File search failed: \(error.localizedDescription)")))
    }
  }

  private struct ComposerMention {
    var sigil: Character
    var tokenRange: Range<Int>
    var query: String
    var queryCursor: Int
  }

  private var isComposerMentionPopup: Bool {
    switch model.overlay {
    case .skills, .fileMentions: true
    default: false
    }
  }

  private func eventInsertsWhitespace(_ event: TerminalEvent) -> Bool {
    switch event {
    case .paste(let text):
      text.contains(where: \.isWhitespace)
    case .key(let key):
      if case .character(let character) = key.key { character.isWhitespace } else { false }
    default:
      false
    }
  }

  private func activeComposerMention(sigil requiredSigil: Character? = nil) -> ComposerMention? {
    let characters = Array(model.composer.text)
    let cursor = min(max(0, model.composer.cursor), characters.count)
    guard !characters.isEmpty else { return nil }

    var start = cursor
    while start > 0, !characters[start - 1].isWhitespace { start -= 1 }
    var end = cursor
    while end < characters.count, !characters[end].isWhitespace { end += 1 }
    guard start < characters.count else { return nil }

    let sigil = characters[start]
    guard sigil == "@" || sigil == "$", requiredSigil == nil || sigil == requiredSigil else {
      return nil
    }
    let queryStart = start + 1
    return ComposerMention(
      sigil: sigil,
      tokenRange: start..<end,
      query: String(characters[queryStart..<end]),
      queryCursor: max(0, cursor - queryStart))
  }

  private func synchronizeComposerMentionQuery(
    with query: TextFieldState, sigil: Character
  ) {
    guard let mention = activeComposerMention(sigil: sigil) else { return }
    let queryStart = mention.tokenRange.lowerBound + 1
    var composer = model.composer
    composer.delete(queryStart..<mention.tokenRange.upperBound)
    composer.moveCursor(to: queryStart)
    composer.insert(query.text)
    composer.moveCursor(to: queryStart + min(query.cursor, query.text.count))
    model.composer = composer
  }

  private func insertSkillMention(_ skill: SkillSummary) {
    replaceComposerMention(sigil: "$", replacement: skill.name)
  }

  private func insertFileMention(_ path: String) {
    replaceComposerMention(sigil: "@", replacement: path)
  }

  private func replaceComposerMention(sigil: Character, replacement: String) {
    let characters = Array(model.composer.text)
    if let mention = activeComposerMention(sigil: sigil) {
      let needsTrailingSpace =
        mention.tokenRange.upperBound == characters.count
        || !characters[mention.tokenRange.upperBound].isWhitespace
      let replacementText = "\(sigil)\(replacement)" + (needsTrailingSpace ? " " : "")
      var composer = model.composer
      composer.delete(mention.tokenRange)
      composer.moveCursor(to: mention.tokenRange.lowerBound)
      composer.insert(replacementText)
      model.composer = composer
      return
    }
    var composer = model.composer
    composer.moveCursor(to: composer.text.count)
    if !composer.text.isEmpty, composer.text.last?.isWhitespace != true { composer.insert(" ") }
    composer.insert("\(sigil)\(replacement) ")
    model.composer = composer
  }

  private func updateRequestUserInput(
    _ request: inout RequestUserInputRequest,
    event: TerminalEvent
  ) -> ApplicationUpdate {
    guard request.questions.indices.contains(request.currentIndex),
      request.answers.indices.contains(request.currentIndex)
    else { return .ignore }
    let question = request.questions[request.currentIndex]

    if case .paste = event, request.focus == .text {
      _ = request.answers[request.currentIndex].draft.handle(event)
      request.answers[request.currentIndex].isCommitted = false
      model.overlay = .requestUserInput(request)
      return .redraw
    }
    guard case .key(let key) = event, key.kind != .release else { return .ignore }

    switch key.key {
    case .escape:
      if request.focus == .text, !question.options.isEmpty {
        request.answers[request.currentIndex].draft = TextFieldState()
        request.answers[request.currentIndex].showsNotes = false
        request.answers[request.currentIndex].isCommitted = false
        request.focus = .options
      } else {
        driver.interrupt()
        return .redraw
      }
    case .tab where !question.options.isEmpty:
      if request.focus == .options {
        request.answers[request.currentIndex].selection.reconcile(
          itemCount: question.options.count)
        request.answers[request.currentIndex].showsNotes = true
        request.focus = .text
      } else {
        request.answers[request.currentIndex].draft = TextFieldState()
        request.answers[request.currentIndex].showsNotes = false
        request.answers[request.currentIndex].isCommitted = false
        request.focus = .options
      }
    case .up where request.focus == .options:
      request.answers[request.currentIndex].selection.move(
        by: -1, itemCount: question.options.count)
      request.answers[request.currentIndex].isCommitted = false
    case .down where request.focus == .options:
      request.answers[request.currentIndex].selection.move(
        by: 1, itemCount: question.options.count)
      request.answers[request.currentIndex].isCommitted = false
    case .left where request.focus == .options:
      moveQuestion(&request, by: -1)
    case .right where request.focus == .options:
      moveQuestion(&request, by: 1)
    case .character("p") where key.modifiers.contains(.control):
      moveQuestion(&request, by: -1)
    case .character("n") where key.modifiers.contains(.control):
      moveQuestion(&request, by: 1)
    case .enter:
      if !question.options.isEmpty {
        request.answers[request.currentIndex].selection.reconcile(
          itemCount: question.options.count)
      }
      request.answers[request.currentIndex].isCommitted = true
      if request.currentIndex + 1 < request.questions.count {
        moveQuestion(&request, by: 1)
      } else {
        _ = driver.submitUserInput(request)
        return .redraw
      }
    case .character(let character) where request.focus == .options:
      if let number = character.wholeNumberValue,
        (1...question.options.count).contains(number)
      {
        request.answers[request.currentIndex].selection.select(
          number - 1, itemCount: question.options.count)
        request.answers[request.currentIndex].isCommitted = false
      } else {
        return .ignore
      }
    default:
      guard request.focus == .text else { return .ignore }
      if request.answers[request.currentIndex].draft.handle(event) {
        request.answers[request.currentIndex].isCommitted = false
      } else {
        return .ignore
      }
    }
    model.overlay = .requestUserInput(request)
    return .redraw
  }

  private func moveQuestion(_ request: inout RequestUserInputRequest, by distance: Int) {
    guard !request.questions.isEmpty else { return }
    request.currentIndex =
      (request.currentIndex + distance % request.questions.count + request.questions.count)
      % request.questions.count
    request.focus = request.questions[request.currentIndex].options.isEmpty ? .text : .options
  }
}

extension Collection {
  fileprivate subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
