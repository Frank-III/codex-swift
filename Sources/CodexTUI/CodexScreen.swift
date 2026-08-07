import Foundation
import Ratatui
import RatatuiSyntaxHighlighting

public struct CodexScreen: Widget, Hashable, Sendable {
  private static let syntaxHighlighter = TerminalSyntaxHighlighter()
  public var snapshot: CodexSnapshot

  public init(snapshot: CodexSnapshot) {
    self.snapshot = snapshot
  }

  public func render(in area: Rect, into frame: inout Frame) {
    guard !area.isEmpty else { return }
    defer {
      frame.placeCursor(
        at: cursorPosition(in: area, environment: frame.environment),
        style: cursorStyle(in: area, environment: frame.environment))
    }
    frame.buffer.fill(area, with: Cell(symbol: " "))

    let layout = layout(in: area)
    if let header = layout.header {
      renderHeader(
        in: header, lineOffset: layout.headerLineOffset, into: &frame.buffer,
        environment: frame.environment)
    }

    renderTranscript(in: layout.transcript, into: &frame.buffer, environment: frame.environment)
    if let overlay = snapshot.overlay, let overlayArea = layout.overlay {
      if !layout.composer.isEmpty {
        renderComposer(
          in: layout.composer, into: &frame.buffer, environment: frame.environment,
          showsFooter: false)
      }
      render(overlay, in: overlayArea, into: &frame.buffer, environment: frame.environment)
    } else {
      renderStatus(in: layout.status, into: &frame.buffer, environment: frame.environment)
      renderComposer(in: layout.composer, into: &frame.buffer, environment: frame.environment)
      renderSuggestions(in: layout.suggestions, into: &frame.buffer, environment: frame.environment)
    }
  }

  private func cursorPosition(in area: Rect, environment: RenderEnvironment) -> Position? {
    let screenLayout = layout(in: area)
    if let overlay = snapshot.overlay, overlayPlacement(for: overlay) != .composerPopup {
      guard let overlayArea = screenLayout.overlay else { return nil }
      return cursorPosition(for: overlay, in: overlayArea)
    }
    let composer = screenLayout.composer
    guard snapshot.selectedImageAttachmentIndex == nil,
      composer.width > 3, composer.height > 0
    else { return nil }
    let textLayout = composerTextLayout(width: Int(composer.width))
    let imageCount = min(3, snapshot.imageAttachments.count)
    let imageOffset = imageCount + (imageCount > 0 ? 1 : 0)
    let footerHeight = snapshot.overlay == nil && slashSuggestions().isEmpty ? 1 : 0
    let panelHeight = max(1, Int(composer.height) - footerHeight)
    let availableTextRows = max(1, panelHeight - 2 - imageOffset)
    let firstVisibleLine = max(0, textLayout.cursorLine - availableTextRows + 1)
    return Position(
      x: UInt16(
        clamping: min(
          Int(composer.right) - 2, Int(composer.x) + 2 + textLayout.cursorColumn)),
      y: UInt16(
        clamping: min(
          Int(composer.bottom) - 1,
          Int(composer.y) + 1 + imageOffset + textLayout.cursorLine - firstVisibleLine))
    )
  }

  private func cursorStyle(in area: Rect, environment: RenderEnvironment) -> CursorStyle {
    if let overlay = snapshot.overlay {
      if overlayPlacement(for: overlay) == .composerPopup { return .steadyBar }
      if let overlayArea = layout(in: area).overlay,
        cursorPosition(for: overlay, in: overlayArea) != nil
      {
        return .steadyBar
      }
    }
    return snapshot.vimEnabled && snapshot.vimMode == .insert ? .steadyBar : .defaultUserShape
  }

  private struct ScreenLayout {
    var header: Rect?
    var headerLineOffset: Int
    var transcript: Rect
    var suggestions: Rect
    var status: Rect
    var composer: Rect
    var overlay: Rect?
  }

  private enum OverlayPlacement {
    case replacesBottomPane
    case composerPopup
  }

  private struct StyledGlyph {
    var text: String
    var style: Style
    var width: Int
  }

  private struct ComposerTextLayout {
    var lines: [String]
    var cursorLine: Int
    var cursorColumn: Int
  }

  private func cursorPosition(for overlay: CodexOverlay, in area: Rect) -> Position? {
    switch overlay {
    case .requestUserInput(let request):
      guard request.questions.indices.contains(request.currentIndex),
        request.answers.indices.contains(request.currentIndex)
      else { return nil }
      let question = request.questions[request.currentIndex]
      let answer = request.answers[request.currentIndex]
      if question.options.isEmpty {
        return wrappedFieldCursor(answer.draft, prefix: "  › ", row: 4, in: area)
      }
      guard answer.showsNotes, request.focus == .text else { return nil }
      return wrappedFieldCursor(
        answer.draft, prefix: "  › ", row: question.options.count + 5, in: area)
    case .models(let picker):
      return singleLineFieldCursor(
        TextFieldState(text: picker.query), prefix: "  Search: ", row: 2, in: area)
    case .theme(let picker):
      return singleLineFieldCursor(picker.query, prefix: "  Search: ", row: 1, in: area)
    case .keymap(let picker):
      return singleLineFieldCursor(
        TextFieldState(text: picker.query), prefix: "  Search: ", row: 2, in: area)
    case .sessions(let picker):
      return singleLineFieldCursor(picker.query, prefix: "Search: ", row: 1, in: area)
    case .rename(let prompt):
      return singleLineFieldCursor(prompt.name, prefix: "▌ ", row: 2, in: area)
    case .historySearch(let search):
      return singleLineFieldCursor(search.query, prefix: "reverse-search: ", row: 0, in: area)
    default:
      return nil
    }
  }

  private func singleLineFieldCursor(
    _ field: TextFieldState, prefix: String, row: Int, in area: Rect
  ) -> Position? {
    guard area.width > 0, row >= 0, row < Int(area.height) else { return nil }
    let characters = Array(field.text)
    let column =
      TerminalWidth.of(prefix)
      + TerminalWidth.of(String(characters.prefix(min(field.cursor, characters.count))))
    return Position(
      x: UInt16(clamping: min(Int(area.right) - 1, Int(area.x) + column)),
      y: UInt16(clamping: Int(area.y) + row))
  }

  private func wrappedFieldCursor(
    _ field: TextFieldState, prefix: String, row: Int, in area: Rect
  ) -> Position? {
    guard area.width > 0, row >= 0, row < Int(area.height) else { return nil }
    let text = prefix + field.text
    let cursor = prefix.count + min(field.cursor, field.text.count)
    let layout = textCursorLayout(text: text, cursor: cursor, width: Int(area.width))
    return Position(
      x: UInt16(clamping: Int(area.x) + min(Int(area.width) - 1, layout.cursorColumn)),
      y: UInt16(
        clamping: min(Int(area.bottom) - 1, Int(area.y) + row + layout.cursorLine)))
  }

  private func textCursorLayout(text: String, cursor: Int, width: Int) -> ComposerTextLayout {
    let width = max(1, width)
    let characters = Array(text)
    var lines = [""]
    var lineWidth = 0
    var cursorLine = 0
    var cursorColumn = 0
    for (index, character) in characters.enumerated() {
      if character == "\n" {
        if index == cursor {
          cursorLine = lines.count - 1
          cursorColumn = lineWidth
        }
        lines.append("")
        lineWidth = 0
        continue
      }
      let startsWord = !character.isWhitespace && (index == 0 || characters[index - 1].isWhitespace)
      if startsWord, lineWidth > 0 {
        var wordWidth = 0
        var lookahead = index
        while lookahead < characters.count, !characters[lookahead].isWhitespace {
          wordWidth += max(0, TerminalWidth.of(String(characters[lookahead])))
          lookahead += 1
        }
        if lineWidth + wordWidth > width {
          lines.append("")
          lineWidth = 0
        }
      }
      let characterWidth = max(0, TerminalWidth.of(String(character)))
      if lineWidth > 0, lineWidth + characterWidth > width {
        lines.append("")
        lineWidth = 0
      }
      if index == cursor {
        cursorLine = lines.count - 1
        cursorColumn = lineWidth
      }
      lines[lines.count - 1].append(character)
      lineWidth += characterWidth
    }
    if cursor >= characters.count {
      cursorLine = lines.count - 1
      cursorColumn = lineWidth
    }
    return ComposerTextLayout(
      lines: lines, cursorLine: cursorLine, cursorColumn: min(width - 1, cursorColumn))
  }

  public func desiredHeight(width: Int) -> Int {
    let width = max(1, width)
    let transcriptHeight = transcriptDesiredHeight(width: width)
    let fullHeaderHeight = snapshot.showHeader ? 7 : 0
    let separatorHeight = fullHeaderHeight > 0 && transcriptHeight > 0 ? 1 : 0
    let imageCount = min(3, snapshot.imageAttachments.count)
    let imageHeight = imageCount + (imageCount > 0 ? 1 : 0)
    let panelHeight = 2 + imageHeight + composerTextLayout(width: width).lines.count

    let bottomHeight: Int
    if let overlay = snapshot.overlay {
      let composerHeight = overlayPlacement(for: overlay) == .composerPopup ? panelHeight : 0
      bottomHeight = composerHeight + desiredHeight(for: overlay, width: width)
    } else {
      let suggestions = slashSuggestions()
      let composerHeight = panelHeight + (suggestions.isEmpty ? 1 : 0)
      bottomHeight =
        statusLineCount(width: width) + composerHeight + slashSuggestionLines(width: width).count
    }

    return max(1, fullHeaderHeight + separatorHeight + transcriptHeight + bottomHeight)
  }

  private func layout(in area: Rect) -> ScreenLayout {
    let totalHeight = Int(area.height)
    let transcriptDesired = transcriptDesiredHeight(width: Int(area.width))
    let suggestions = slashSuggestions()
    let suggestionLines = slashSuggestionLines(width: Int(area.width))
    let imageCount = min(3, snapshot.imageAttachments.count)
    let imageHeight = imageCount + (imageCount > 0 ? 1 : 0)
    let panelHeight = 2 + imageHeight + composerTextLayout(width: Int(area.width)).lines.count
    let composerDesiredHeight = panelHeight + (suggestions.isEmpty ? 1 : 0)
    let statusDesiredHeight = statusLineCount(width: Int(area.width))

    if let overlay = snapshot.overlay {
      let keepsComposer = overlayPlacement(for: overlay) == .composerPopup
      let composerHeight = keepsComposer ? min(panelHeight, totalHeight) : 0
      let overlayHeight = min(
        desiredHeight(for: overlay, width: Int(area.width)),
        max(0, totalHeight - composerHeight))
      let bottomHeight = composerHeight + overlayHeight
      let history = historyAllocation(
        totalHeight: totalHeight, bottomHeight: bottomHeight,
        transcriptDesiredHeight: transcriptDesired)
      let regions = Layout(
        .vertical,
        constraints: [
          .length(UInt16(clamping: history.headerHeight)),
          .length(UInt16(clamping: history.separatorHeight)),
          .flex(1),
          .length(UInt16(clamping: composerHeight)),
          .length(UInt16(clamping: overlayHeight)),
        ]
      ).split(area)
      let empty = Rect(x: regions[3].x, y: regions[3].y, width: regions[3].width, height: 0)
      return ScreenLayout(
        header: history.headerHeight > 0 ? headerRect(in: regions[0]) : nil,
        headerLineOffset: history.headerLineOffset, transcript: regions[2],
        suggestions: empty, status: empty, composer: regions[3], overlay: regions[4])
    }

    let composerHeight = min(composerDesiredHeight, totalHeight)
    let statusHeight = min(
      statusDesiredHeight, max(0, totalHeight - composerHeight))
    let suggestionHeight = min(
      suggestionLines.count, max(0, totalHeight - composerHeight - statusHeight))
    let bottomHeight = composerHeight + statusHeight + suggestionHeight
    let history = historyAllocation(
      totalHeight: totalHeight, bottomHeight: bottomHeight,
      transcriptDesiredHeight: transcriptDesired)
    let regions = Layout(
      .vertical,
      constraints: [
        .length(UInt16(clamping: history.headerHeight)),
        .length(UInt16(clamping: history.separatorHeight)),
        .flex(1),
        .length(UInt16(clamping: statusHeight)),
        .length(UInt16(clamping: composerHeight)),
        .length(UInt16(clamping: suggestionHeight)),
      ]
    ).split(area)
    return ScreenLayout(
      header: history.headerHeight > 0 ? headerRect(in: regions[0]) : nil,
      headerLineOffset: history.headerLineOffset, transcript: regions[2],
      suggestions: regions[5], status: regions[3], composer: regions[4], overlay: nil)
  }

  private func historyAllocation(
    totalHeight: Int, bottomHeight: Int, transcriptDesiredHeight: Int
  ) -> (headerLineOffset: Int, headerHeight: Int, separatorHeight: Int, transcriptHeight: Int) {
    let fullHeaderHeight = snapshot.showHeader ? 7 : 0
    let fullSeparatorHeight = fullHeaderHeight > 0 && transcriptDesiredHeight > 0 ? 1 : 0
    let available = max(0, totalHeight - bottomHeight)
    var overflow = max(
      0, fullHeaderHeight + fullSeparatorHeight + transcriptDesiredHeight - available)
    let headerLineOffset = min(fullHeaderHeight, overflow)
    overflow -= headerLineOffset
    let separatorOffset = min(fullSeparatorHeight, overflow)
    overflow -= separatorOffset
    let transcriptOffset = min(transcriptDesiredHeight, overflow)
    return (
      headerLineOffset,
      fullHeaderHeight - headerLineOffset,
      fullSeparatorHeight - separatorOffset,
      transcriptDesiredHeight - transcriptOffset
    )
  }

  private func headerRect(in row: Rect) -> Rect {
    Rect(
      x: row.x, y: row.y, width: min(row.width, UInt16(clamping: headerDesiredWidth())),
      height: min(7, row.height))
  }

  private func headerDesiredWidth() -> Int {
    let tier = snapshot.serviceTier.map { "   \($0)" } ?? ""
    let values = [
      ">_ OpenAI Codex (v\(snapshot.version))",
      "model:       \(snapshot.model) \(snapshot.reasoningEffort)\(tier)   /model to change",
      "directory:   \(displayPath(snapshot.directory))",
      "permissions: \(snapshot.permissionMode.rawValue)",
    ]
    return (values.map { TerminalWidth.of($0) }.max() ?? 0) + 4
  }

  private func slashSuggestions() -> [CodexSlashCommand] {
    let text = snapshot.composer.text
    guard !snapshot.slashPopupDismissed, text.hasPrefix("/"),
      !text.dropFirst().contains(where: { $0.isWhitespace })
    else { return [] }
    return CodexSlashCommand.suggestions(
      for: text, isWorking: snapshot.isWorking, mode: snapshot.mode)
  }

  private func slashSuggestionLines(width: Int) -> [Line] {
    let suggestions = slashSuggestions()
    guard width > 0, !suggestions.isEmpty else { return [] }
    let selected = min(max(0, snapshot.slashCommandSelection), suggestions.count - 1)
    let itemCount = min(8, suggestions.count)
    let start = min(max(0, selected - itemCount + 1), max(0, suggestions.count - itemCount))
    let visible = suggestions[start..<min(suggestions.count, start + itemCount)]
    let nameWidth = suggestions.map { TerminalWidth.of("/\($0.name)") }.max() ?? 0
    let descriptionColumn = min(width, 2 + nameWidth + 3)
    let descriptionWidth = max(1, width - descriptionColumn)
    let selectionStyle = Style(foreground: .cyan, modifiers: [.bold])
    var lines: [Line] = []
    for (offset, command) in visible.enumerated() {
      let isSelected = start + offset == selected
      let commandText = "/\(command.name)"
      let descriptions = wrapWords(command.description, width: descriptionWidth)
      let firstDescription = descriptions.first ?? ""
      lines.append(
        Line {
          Span("  ")
          Span(commandText, style: isSelected ? selectionStyle : .plain)
          Span(
            String(
              repeating: " ",
              count: max(3, nameWidth - TerminalWidth.of(commandText) + 3)))
          Span(
            firstDescription,
            style: isSelected ? selectionStyle : .init(modifiers: [.dim]))
        })
      for continuation in descriptions.dropFirst() {
        lines.append(
          Line {
            Span(String(repeating: " ", count: descriptionColumn))
            Span(
              continuation,
              style: isSelected ? selectionStyle : .init(modifiers: [.dim]))
          })
      }
    }
    return lines
  }

  private func transcriptDesiredHeight(width: Int) -> Int {
    guard width > 0 else { return 0 }
    let lines = renderedTranscriptLines(width: width)
    guard !lines.isEmpty else { return 0 }
    return Paragraph(
      Text(lines), wrap: snapshot.rawOutputMode ? .character : .word,
      trimLeadingWhitespace: false
    ).lineCount(width: UInt16(clamping: width))
  }

  private func overlayPlacement(for overlay: CodexOverlay) -> OverlayPlacement {
    switch overlay {
    case .fileMentions, .skills:
      .composerPopup
    default:
      .replacesBottomPane
    }
  }

  private func desiredHeight(for overlay: CodexOverlay, width: Int) -> Int {
    switch overlay {
    case .approval(let request):
      return 5 + request.choices.count + (request.reason == nil ? 0 : 2)
        + (request.command == nil ? 0 : 2)
    case .requestUserInput(let request):
      guard request.questions.indices.contains(request.currentIndex) else { return 1 }
      let question = request.questions[request.currentIndex]
      return max(
        10, question.options.count + (request.answers[request.currentIndex].showsNotes ? 9 : 6))
    case .models(let picker):
      return min(15, picker.filteredModels.count + 6)
    case .reasoning(let picker):
      return min(14, picker.options.count + 5)
    case .permissions(let picker):
      return picker.confirmingFullAccess ? 13 : 12
    case .personality:
      return 8
    case .theme:
      return 18
    case .keymap:
      return 16
    case .keymapAction:
      return 14
    case .keymapCapture:
      return 8
    case .keymapDebug:
      return 14
    case .transcript:
      return Int.max
    case .sessions:
      return 16
    case .rename:
      return 6
    case .sessionConfirmation:
      return 10
    case .historySearch:
      return 4
    case .review:
      return 11
    case .agents:
      return 14
    case .agentPreview:
      return 18
    case .backgroundTasks:
      return 14
    case .skills(let picker):
      let filtered = picker.filteredSkills
      guard !filtered.isEmpty else { return 6 }
      let groups = selectionMenuRowGroups(
        filtered.map { ($0.name, $0.description) }, selectedIndex: picker.selectedIndex,
        width: max(1, width))
      return min(14, 5 + groups.reduce(0) { $0 + $1.count })
    case .fileMentions(let picker):
      let filtered = picker.filteredFiles
      guard !filtered.isEmpty else { return 6 }
      let groups = selectionMenuRowGroups(
        filtered.map { ($0, "") }, selectedIndex: picker.selectedIndex, width: max(1, width))
      return min(14, 5 + groups.reduce(0) { $0 + $1.count })
    case .rewind(let picker):
      return min(16, picker.candidates.count + 5)
    case .shortcuts:
      return 10
    }
  }

  private func renderHeader(
    in area: Rect, lineOffset: Int, into buffer: inout Buffer,
    environment: RenderEnvironment
  ) {
    guard !area.isEmpty, area.width >= 4 else { return }
    let innerWidth = max(0, Int(area.width) - 4)
    let tier = snapshot.serviceTier.map { "   \($0)" } ?? ""
    let modelValue = fit(
      "\(snapshot.model) \(snapshot.reasoningEffort)\(tier)   /model to change",
      width: max(0, innerWidth - 13))
    let directoryValue = fit(displayPath(snapshot.directory), width: max(0, innerWidth - 13))
    let permissionsValue = fit(snapshot.permissionMode.rawValue, width: max(0, innerWidth - 13))
    let rows = [
      Line {
        Span("╭")
        Span(String(repeating: "─", count: max(0, Int(area.width) - 2)))
        Span("╮")
      },
      Line {
        Span("│ ")
        Span(">_ ", style: .init(foreground: .magenta, modifiers: [.bold]))
        Span("OpenAI Codex", style: .init(modifiers: [.bold]))
        Span(" (v\(snapshot.version))", style: .init(modifiers: [.dim]))
        Span(padding(after: ">_ OpenAI Codex (v\(snapshot.version))", to: innerWidth))
        Span(" │")
      },
      framed("", innerWidth: innerWidth),
      Line {
        Span("│ ")
        Span("model:       ", style: .init(modifiers: [.dim]))
        Span(modelValue, style: .init(modifiers: [.bold]))
        Span(padding(after: "model:       \(modelValue)", to: innerWidth))
        Span(" │")
      },
      Line {
        Span("│ ")
        Span("directory:   ", style: .init(modifiers: [.dim]))
        Span(directoryValue)
        Span(padding(after: "directory:   \(directoryValue)", to: innerWidth))
        Span(" │")
      },
      Line {
        Span("│ ")
        Span("permissions: ", style: .init(modifiers: [.dim]))
        Span(permissionsValue)
        Span(padding(after: "permissions: \(permissionsValue)", to: innerWidth))
        Span(" │")
      },
      Line {
        Span("╰")
        Span(String(repeating: "─", count: max(0, Int(area.width) - 2)))
        Span("╯")
      },
    ]
    Text(Array(rows.dropFirst(lineOffset).prefix(Int(area.height))))
      .render(in: area, into: &buffer, environment: environment)
  }

  private func renderTranscript(
    in area: Rect, into buffer: inout Buffer, environment: RenderEnvironment
  ) {
    guard !area.isEmpty else { return }
    let lines = renderedTranscriptLines(width: Int(area.width))
    guard !lines.isEmpty else { return }
    let paragraph = Paragraph(
      Text(lines), wrap: snapshot.rawOutputMode ? .character : .word,
      trimLeadingWhitespace: false)
    let total = paragraph.lineCount(width: area.width)
    var visible = paragraph
    visible.scroll = UInt16(clamping: max(0, total - Int(area.height)))
    visible.render(in: area, into: &buffer, environment: environment)
  }

  private func fit(_ text: String, width: Int) -> String {
    guard width > 0 else { return "" }
    guard TerminalWidth.of(text) > width else { return text }
    if width == 1 { return "…" }
    var result = ""
    var used = 0
    for character in text {
      let characterWidth = TerminalWidth.of(character)
      guard used + characterWidth <= width - 1 else { break }
      result.append(character)
      used += characterWidth
    }
    return result + "…"
  }

  private func renderedTranscriptLines(
    width: Int, highlightedUserFromEnd: Int? = nil,
    entries sourceEntries: [TranscriptEntry]? = nil
  ) -> [Line] {
    let entries = sourceEntries ?? snapshot.entries
    let userEntries = entries.filter {
      if case .user = $0.content { true } else { false }
    }
    let highlightedID = highlightedUserFromEnd.flatMap { offset -> String? in
      let index = userEntries.count - 1 - offset
      return userEntries.indices.contains(index) ? userEntries[index].id : nil
    }
    var lines: [Line] = []
    var index = 0
    var previousWasUser = false
    while index < entries.count {
      let entry = entries[index]
      let currentIsUser: Bool = if case .user = entry.content { true } else { false }
      if !lines.isEmpty, !previousWasUser, !currentIsUser { lines.append(Line("")) }
      let entryStart = lines.count
      if snapshot.rawOutputMode {
        lines.append(contentsOf: rawTranscriptLines(for: entry.content))
        index += 1
      } else if case .tool(let tool) = entry.content,
        case .exploration = tool.presentation
      {
        var actions: [ExplorationAction] = []
        var isActive = false
        while index < entries.count,
          case .tool(let candidate) = entries[index].content,
          case .exploration(let action) = candidate.presentation
        {
          actions.append(action)
          isActive = isActive || candidate.status == .running
          index += 1
        }
        lines.append(contentsOf: explorationLines(actions, isActive: isActive))
      } else {
        lines.append(contentsOf: transcriptLines(for: entry.content, width: width))
        index += 1
      }
      if entry.id == highlightedID {
        for lineIndex in entryStart..<lines.count {
          lines[lineIndex].style = lines[lineIndex].style.patching(.init(modifiers: [.reversed]))
        }
      }
      previousWasUser = currentIsUser
    }
    return lines
  }

  func terminalHistoryLines(
    for entry: TranscriptEntry, width: Int, sourceContinuation: Bool = false
  ) -> [Line] {
    if snapshot.rawOutputMode { return rawTranscriptLines(for: entry.content) }
    switch entry.content {
    case .assistant(let source, _):
      return assistantMessageLines(
        source, width: width, streaming: false, continuation: sourceContinuation)
    case .reasoning(let summary, let body, _):
      return reasoningLines(
        body?.isEmpty == false ? body! : summary, width: width, streaming: false,
        continuation: sourceContinuation)
    default:
      return transcriptLines(for: entry.content, width: width)
    }
  }

  private func transcriptLines(for content: TranscriptContent, width: Int) -> [Line] {
    switch content {
    case .user(let text):
      return userMessageLines(text, width: width)
    case .assistant(let text, let streaming):
      return assistantMessageLines(text, width: width, streaming: streaming)
    case .reasoning(let summary, let body, let streaming):
      return reasoningLines(
        body?.isEmpty == false ? body! : summary, width: width, streaming: streaming)
    case .tool(let tool):
      switch tool.presentation {
      case .command(let command, let output, let omittedLineCount):
        return commandLines(
          command: command, output: output, omittedLineCount: omittedLineCount,
          status: tool.status, width: width)
      case .exploration(let action):
        return explorationLines([action], isActive: tool.status == .running)
      case .edit(let path, let additions, let deletions, let lines):
        return editLines(
          path: path, additions: additions, deletions: deletions, lines: lines, width: width)
      case .editFailure(let path, let output):
        var lines = prefixed(
          "Failed to apply edit", first: "✘ ", rest: "  ",
          prefixStyle: .init(foreground: .red, modifiers: [.bold]),
          bodyStyle: .init(foreground: .red, modifiers: [.bold]))
        if !path.isEmpty {
          lines += prefixed(path, first: "  └ ", rest: "    ", bodyStyle: .init(modifiers: [.dim]))
        }
        for line in output.suffix(8) {
          lines += prefixed(line, first: "  └ ", rest: "    ", bodyStyle: .init(foreground: .red))
        }
        return lines
      case .generic:
        break
      }
      let color: Color =
        switch tool.status {
        case .running: .cyan
        case .succeeded: .green
        case .failed: .red
        case .interrupted: .gray
        }
      var title = tool.name
      if !tool.detail.isEmpty { title += " \(tool.detail)" }
      if let duration = tool.durationMilliseconds { title += " (\(formatDuration(duration)))" }
      var result = prefixed(
        title, first: "• ", rest: "  ", prefixStyle: .init(foreground: color, modifiers: [.bold]))
      for output in tool.output {
        result += prefixed(output, first: "  └ ", rest: "    ", bodyStyle: .init(modifiers: [.dim]))
      }
      return result
    case .approvalDecision(let record):
      return approvalDecisionLines(record)
    case .notice(let text):
      return prefixed(text, first: "  ", rest: "  ", bodyStyle: .init(modifiers: [.dim]))
    case .error(let text):
      return prefixed(
        text, first: "! ", rest: "  ", prefixStyle: .init(foreground: .red, modifiers: [.bold]),
        bodyStyle: .init(foreground: .red))
    }
  }

  private func rawTranscriptLines(for content: TranscriptContent) -> [Line] {
    switch content {
    case .user(let source):
      return rawLines(from: sanitizeUserText(source).trimmingCharacters(in: .newlines))
    case .assistant(let source, _):
      return rawLines(from: source)
    case .reasoning(let summary, let body, _):
      return rawLines(
        from: (body?.isEmpty == false ? body! : summary).trimmingCharacters(
          in: .whitespacesAndNewlines))
    case .tool(let tool):
      switch tool.presentation {
      case .command(let command, let output, let omittedLineCount):
        var lines = [Line("$ \(command)")]
        if omittedLineCount > 0 { lines.append(Line("… +\(omittedLineCount) lines")) }
        lines.append(contentsOf: output.map(Line.init))
        return lines
      case .exploration(let action):
        let path = action.path.map { " in \($0)" } ?? ""
        return [Line("\(action.kind.rawValue) \(action.subject)\(path)")]
      case .edit(let path, let additions, let deletions, let diffLines):
        var lines = [Line("Edited \(path) (+\(additions) -\(deletions))")]
        lines.append(
          contentsOf: diffLines.map { line in
            let prefix =
              switch line.kind {
              case .addition: "+"
              case .deletion: "-"
              case .context: " "
              case .separator: ""
              }
            return Line(prefix + line.text)
          })
        return lines
      case .editFailure(let path, let output):
        return [Line("Failed to apply edit\(path.isEmpty ? "" : " to \(path)")")]
          + output.map(Line.init)
      case .generic:
        var title = tool.name
        if !tool.detail.isEmpty { title += " \(tool.detail)" }
        return [Line(title)] + tool.output.map(Line.init)
      }
    case .approvalDecision(let record):
      let subject =
        switch record.subject {
        case .command(let command): command
        case .fileChange(let path): path
        }
      let action =
        switch record.decision {
        case .approveOnce: "Approved once"
        case .approveForSession: "Approved for this session"
        case .decline: "Declined"
        case .cancel: "Canceled"
        }
      return [Line("\(action): \(subject)")]
    case .notice(let source), .error(let source):
      return rawLines(from: source)
    }
  }

  private func rawLines(from source: String) -> [Line] {
    guard !source.isEmpty else { return [] }
    var parts = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if source.hasSuffix("\n") { parts.removeLast() }
    return parts.map(Line.init)
  }

  private func approvalDecisionLines(_ record: ApprovalDecisionRecord) -> [Line] {
    let subject: String =
      switch record.subject {
      case .command(let command): command
      case .fileChange(let path): path
      }
    switch record.decision {
    case .approveOnce:
      return [
        Line {
          Span("✔ ", style: .init(foreground: .green))
          Span("You ")
          Span("approved", style: .init(modifiers: [.bold]))
          Span(" codex to run ")
          Span(subject, style: .init(modifiers: [.dim]))
          Span(" this time", style: .init(modifiers: [.bold]))
        }
      ]
    case .approveForSession:
      return [
        Line {
          Span("✔ ", style: .init(foreground: .green))
          Span("You ")
          Span("approved", style: .init(modifiers: [.bold]))
          Span(" codex to run ")
          Span(subject, style: .init(modifiers: [.dim]))
          Span(" every time this session", style: .init(modifiers: [.bold]))
        }
      ]
    case .decline:
      return [
        Line {
          Span("✗ ", style: .init(foreground: .red))
          Span("You ")
          Span("did not approve", style: .init(modifiers: [.bold]))
          Span(" codex to run ")
          Span(subject, style: .init(modifiers: [.dim]))
        }
      ]
    case .cancel:
      return [
        Line {
          Span("✗ ", style: .init(foreground: .red))
          Span("You ")
          Span("canceled", style: .init(modifiers: [.bold]))
          Span(" the request to run ")
          Span(subject, style: .init(modifiers: [.dim]))
        }
      ]
    }
  }

  private func userMessageLines(_ source: String, width: Int) -> [Line] {
    let background = Color.rgb(63, 67, 74)
    let style = Style(background: background)
    let sanitized = sanitizeUserText(source).trimmingCharacters(in: .newlines)
    guard !sanitized.isEmpty else { return [] }
    let padding = String(repeating: " ", count: max(1, width))
    var result = [Line(padding, style: style)]
    var isFirst = true
    for physicalLine in sanitized.split(separator: "\n", omittingEmptySubsequences: false) {
      let chunks = hangingWrap(
        String(physicalLine), firstWidth: max(1, width - 3), restWidth: max(1, width - 3))
      for chunk in chunks {
        result.append(
          Line(style: style) {
            Span(
              isFirst ? "› " : "  ",
              style: .init(background: background, modifiers: isFirst ? [.bold, .dim] : []))
            Span(chunk, style: style)
          })
        isFirst = false
      }
    }
    result.append(Line(padding, style: style))
    return result
  }

  private func assistantMessageLines(
    _ source: String, width: Int, streaming: Bool, continuation: Bool = false
  ) -> [Line] {
    markdownLines(
      source, width: width, firstPrefix: continuation ? "  " : "• ", restPrefix: "  ",
      prefixStyle: .init(modifiers: [.dim]),
      overlay: streaming ? .plain : .plain)
  }

  private func reasoningLines(
    _ source: String, width: Int, streaming: Bool, continuation: Bool = false
  ) -> [Line] {
    markdownLines(
      source, width: width, firstPrefix: continuation ? "  " : "• ", restPrefix: "  ",
      prefixStyle: .init(modifiers: [.dim]),
      overlay: .init(modifiers: [.dim, .italic]))
  }

  private func sanitizeUserText(_ source: String) -> String {
    var result = ""
    var iterator = source.makeIterator()
    while let character = iterator.next() {
      if character == "\u{1B}" {
        guard iterator.next() == "[" else { continue }
        while let control = iterator.next() {
          if control >= "@" && control <= "~" { break }
        }
      } else if character == "\n" || character == "\t" || !character.isASCII
        || character.asciiValue.map({ $0 >= 0x20 && $0 != 0x7F }) == true
      {
        result.append(character)
      }
    }
    return result
  }

  private func markdownLines(
    _ source: String, width: Int, firstPrefix: String, restPrefix: String,
    prefixStyle: Style, overlay: Style
  ) -> [Line] {
    let source = source.trimmingCharacters(in: .newlines)
    guard !source.isEmpty else { return [] }
    let fence = String(repeating: String(UnicodeScalar(96)!), count: 3)
    var result: [Line] = []
    var firstRenderedLine = true
    var inCodeFence = false
    var codeLanguage: String?
    let rawLines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var rawIndex = 0

    while rawIndex < rawLines.count {
      let rawLine = rawLines[rawIndex]
      if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
        if !inCodeFence {
          let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
          let label = String(trimmed.dropFirst(fence.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
          codeLanguage = label.isEmpty ? nil : label
        } else {
          codeLanguage = nil
        }
        inCodeFence.toggle()
        rawIndex += 1
        continue
      }
      if !inCodeFence, rawIndex + 1 < rawLines.count,
        let header = markdownTableRow(rawLine),
        markdownTableDelimiter(rawLines[rawIndex + 1], columns: header.count)
      {
        var rows: [[String]] = []
        var end = rawIndex + 2
        while end < rawLines.count, let row = markdownTableRow(rawLines[end]),
          row.count == header.count
        {
          rows.append(row)
          end += 1
        }
        for var tableLine in markdownTableLines(
          header: header, rows: rows, width: max(1, width - 2), overlay: overlay)
        {
          tableLine.spans.insert(
            Span(
              firstRenderedLine ? firstPrefix : restPrefix,
              style: firstRenderedLine ? prefixStyle : .plain),
            at: 0)
          result.append(tableLine)
          firstRenderedLine = false
        }
        rawIndex = end
        continue
      }
      if rawLine.isEmpty {
        result.append(Line(""))
        rawIndex += 1
        continue
      }

      var content = rawLine
      var blockStyle = overlay
      if !inCodeFence {
        let hashes = content.prefix(while: { $0 == "#" }).count
        if hashes > 0, content.dropFirst(hashes).first == " " {
          content = String(content.dropFirst(hashes + 1))
          blockStyle = blockStyle.patching(.init(modifiers: [.bold]))
        }
      }

      let sourceSpans =
        inCodeFence
        ? Self.syntaxHighlighter.highlight(
          content, language: codeLanguage, theme: snapshot.syntaxTheme
        ).map { Span($0.content, style: blockStyle.patching($0.style)) }
        : inlineMarkdownSpans(content, overlay: blockStyle)
      let chunks = wrapStyledSpans(sourceSpans, width: max(1, width - 2))
      let leadingWhitespace = String(content.prefix(while: \.isWhitespace))
      for (chunkIndex, chunk) in chunks.enumerated() {
        var line = Line {
          Span(
            firstRenderedLine ? firstPrefix : restPrefix,
            style: firstRenderedLine ? prefixStyle : .plain)
          if chunkIndex > 0, !leadingWhitespace.isEmpty { Span(leadingWhitespace) }
        }
        for span in chunk { line = line.pushSpan(span) }
        result.append(line)
        firstRenderedLine = false
      }
      rawIndex += 1
    }
    return result
  }

  private func markdownTableRow(_ source: String) -> [String]? {
    let trimmed = source.trimmingCharacters(in: .whitespaces)
    guard trimmed.contains("|") else { return nil }
    var body = trimmed
    if body.hasPrefix("|") { body.removeFirst() }
    if body.hasSuffix("|") { body.removeLast() }
    let cells = body.split(separator: "|", omittingEmptySubsequences: false).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    return cells.count > 1 ? cells : nil
  }

  private func markdownTableDelimiter(_ source: String, columns: Int) -> Bool {
    guard let cells = markdownTableRow(source), cells.count == columns else { return false }
    return cells.allSatisfy { cell in
      let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
      return core.count >= 3 && core.allSatisfy { $0 == "-" }
    }
  }

  private func markdownTableLines(
    header: [String], rows: [[String]], width: Int, overlay: Style
  ) -> [Line] {
    let styledHeader = header.map {
      inlineMarkdownSpans($0, overlay: overlay.adding(.bold))
    }
    let styledRows = rows.map { row in
      row.map { inlineMarkdownSpans($0, overlay: overlay) }
    }
    let widths = header.indices.map { column in
      ([styledHeader[column]] + styledRows.map { $0[column] }).map {
        $0.reduce(0) { $0 + $1.width }
      }.max() ?? 0
    }
    let gap = 2
    let required = widths.reduce(0, +) + gap * max(0, widths.count - 1)
    if required <= width {
      func rowLine(_ cells: [[Span]]) -> Line {
        var spans: [Span] = []
        for column in cells.indices {
          spans.append(contentsOf: cells[column])
          if column + 1 < cells.count {
            let cellWidth = cells[column].reduce(0) { $0 + $1.width }
            spans.append(Span(String(repeating: " ", count: widths[column] - cellWidth + gap)))
          }
        }
        var line = Line("")
        line.spans = spans
        return line
      }
      var lines = [rowLine(styledHeader)]
      lines.append(
        Line(
          widths.map { String(repeating: "─", count: $0) }.joined(
            separator: String(repeating: " ", count: gap)),
          style: .init(modifiers: [.dim])))
      lines.append(contentsOf: styledRows.map(rowLine))
      return lines
    }

    var lines: [Line] = []
    for (rowIndex, row) in styledRows.enumerated() {
      if rowIndex > 0 { lines.append(Line("")) }
      for column in header.indices {
        let label = header[column].trimmingCharacters(in: .whitespaces)
        var spans = [Span("\(label): ", style: overlay.adding(.bold))]
        spans.append(contentsOf: row[column])
        let wrapped = wrapStyledSpans(spans, width: width)
        for chunk in wrapped {
          var line = Line("")
          line.spans = chunk
          lines.append(line)
        }
      }
    }
    return lines
  }

  private func wrapStyledSpans(_ spans: [Span], width: Int) -> [[Span]] {
    var glyphs: [StyledGlyph] = []
    for span in spans {
      for character in span.content {
        let text = String(character)
        glyphs.append(StyledGlyph(text: text, style: span.style, width: TerminalWidth.of(text)))
      }
    }
    guard !glyphs.isEmpty else { return [[]] }
    var result: [[Span]] = []
    var start = 0
    while start < glyphs.count {
      var end = start
      var used = 0
      var lastWhitespace: Int?
      while end < glyphs.count, used + glyphs[end].width <= width {
        used += glyphs[end].width
        if glyphs[end].text.first?.isWhitespace == true { lastWhitespace = end }
        end += 1
      }
      if end < glyphs.count, let whitespace = lastWhitespace, whitespace >= start {
        end = whitespace
      }
      if end == start { end += 1 }
      var line: [Span] = []
      for glyph in glyphs[start..<end] {
        if var last = line.last, last.style == glyph.style {
          last.content += glyph.text
          line[line.count - 1] = last
        } else {
          line.append(Span(glyph.text, style: glyph.style))
        }
      }
      result.append(line)
      start = end
      while start < glyphs.count, glyphs[start].text.first?.isWhitespace == true { start += 1 }
    }
    return result
  }

  private func inlineMarkdownSpans(_ source: String, overlay: Style) -> [Span] {
    var result: [Span] = []
    var buffer = ""
    var style = overlay
    var index = source.startIndex

    func flush() {
      guard !buffer.isEmpty else { return }
      result.append(Span(buffer, style: style))
      buffer = ""
    }

    while index < source.endIndex {
      let remainder = source[index...]
      if remainder.hasPrefix("**") {
        flush()
        style =
          style.modifiers.contains(.bold)
          ? style.removing(.bold) : style.adding(.bold)
        index = source.index(index, offsetBy: 2)
      } else if remainder.hasPrefix("~~") {
        flush()
        style =
          style.modifiers.contains(.crossedOut)
          ? style.removing(.crossedOut) : style.adding(.crossedOut)
        index = source.index(index, offsetBy: 2)
      } else if source[index] == "*" {
        flush()
        style =
          style.modifiers.contains(.italic)
          ? style.removing(.italic) : style.adding(.italic)
        index = source.index(after: index)
      } else if source[index].unicodeScalars.first?.value == 96 {
        flush()
        if style.foreground == .lightCyan {
          style.foreground = overlay.foreground
        } else {
          style.foreground = .lightCyan
        }
        index = source.index(after: index)
      } else if source[index] == "[",
        let close = source[index...].firstIndex(of: "]"),
        close < source.index(before: source.endIndex),
        source[source.index(after: close)] == "(",
        let end = source[source.index(after: close)...].firstIndex(of: ")")
      {
        flush()
        let label = String(source[source.index(after: index)..<close])
        result.append(
          Span(
            label,
            style: overlay.patching(
              .init(foreground: .cyan, modifiers: [.underlined]))))
        index = source.index(after: end)
      } else {
        buffer.append(source[index])
        index = source.index(after: index)
      }
    }
    flush()
    return result
  }

  private func commandLines(
    command: String, output: [String], omittedLineCount: Int, status: ToolActivityStatus,
    width: Int
  ) -> [Line] {
    let bullet: Color = status == .failed ? .red : status == .running ? .yellow : .green
    let title = status == .running ? "Running " : "Ran "
    let headerWidth = 2 + TerminalWidth.of(title)
    let firstCommandWidth = max(1, width - headerWidth)
    let continuationWidth = max(1, width - 4)
    var commandChunks: [String] = []
    for (index, physicalLine) in command.split(
      separator: "\n", omittingEmptySubsequences: false
    ).enumerated() {
      let wrapWidth = index == 0 ? firstCommandWidth : continuationWidth
      commandChunks += hangingWrap(
        String(physicalLine), firstWidth: wrapWidth, restWidth: wrapWidth)
    }
    var result: [Line] = []
    let visibleCommandChunks = Array(commandChunks.prefix(3))
    for (index, chunk) in visibleCommandChunks.enumerated() {
      var line = Line {
        if index == 0 {
          Span("• ", style: .init(foreground: bullet, modifiers: [.bold]))
          Span(title, style: .init(modifiers: [.bold]))
        } else {
          Span("  │ ", style: .init(modifiers: [.dim]))
        }
      }
      for span in shellSpans(chunk) { line = line.pushSpan(span) }
      result.append(line)
    }
    if commandChunks.count > 3 {
      result.append(
        Line {
          Span("  │ ", style: .init(modifiers: [.dim]))
          Span("… +\(commandChunks.count - 3) lines", style: .init(modifiers: [.dim]))
        })
    }
    if output.isEmpty, status != .running {
      result.append(
        Line {
          Span("  └ ", style: .init(modifiers: [.dim]))
          Span("(no output)", style: .init(modifiers: [.dim]))
        })
      return result
    }

    var wrappedOutput: [String] = []
    for outputLine in output {
      wrappedOutput += hangingWrap(
        outputLine, firstWidth: max(1, width - 4), restWidth: max(1, width - 4))
    }
    let outputRows: [(text: String, omitted: Int?)]
    if wrappedOutput.count <= 5 {
      outputRows = wrappedOutput.map { ($0, nil) }
    } else {
      let omitted = omittedLineCount + wrappedOutput.count - 4
      outputRows =
        wrappedOutput.prefix(2).map { ($0, nil) }
        + [("", omitted)]
        + wrappedOutput.suffix(2).map { ($0, nil) }
    }
    for (index, row) in outputRows.enumerated() {
      result.append(
        Line {
          Span(index == 0 ? "  └ " : "    ", style: .init(modifiers: [.dim]))
          if let omitted = row.omitted {
            Span(
              "… +\(omitted) lines (ctrl + t to view transcript)",
              style: .init(modifiers: [.dim]))
          } else {
            Span(row.text, style: .init(modifiers: [.dim]))
          }
        })
    }
    return result
  }

  private func hangingWrap(_ text: String, firstWidth: Int, restWidth: Int) -> [String] {
    var result: [String] = []
    var remainder = text[...]
    var width = firstWidth
    while !remainder.isEmpty {
      var used = 0
      var end = remainder.startIndex
      var lastWhitespace: String.Index?
      while end < remainder.endIndex {
        let next = remainder.index(after: end)
        let character = String(remainder[end..<next])
        let characterWidth = TerminalWidth.of(character)
        if used + characterWidth > width { break }
        used += characterWidth
        if remainder[end].isWhitespace { lastWhitespace = end }
        end = next
      }
      if end == remainder.endIndex {
        result.append(String(remainder))
        break
      }
      let split = lastWhitespace ?? end
      result.append(String(remainder[..<split]))
      remainder = remainder[split...].drop(while: \.isWhitespace)
      width = restWidth
    }
    return result.isEmpty ? [""] : result
  }

  private func explorationLines(_ actions: [ExplorationAction], isActive: Bool) -> [Line] {
    var result = [
      Line {
        Span(
          "• ",
          style: isActive ? .init(foreground: .yellow) : .init(modifiers: [.dim]))
        Span(isActive ? "Exploring" : "Explored", style: .init(modifiers: [.bold]))
      }
    ]
    var rendered: [(kind: ExplorationActionKind, subject: String, path: String?)] = []
    var index = 0
    while index < actions.count {
      let action = actions[index]
      if action.kind == .read {
        var names: [String] = []
        while index < actions.count, actions[index].kind == .read {
          let name = actions[index].subject
          if !names.contains(name) { names.append(name) }
          index += 1
        }
        rendered.append((.read, names.joined(separator: ", "), nil))
      } else {
        rendered.append((action.kind, action.subject, action.path))
        index += 1
      }
    }
    for (index, action) in rendered.enumerated() {
      result.append(
        Line {
          Span(index == 0 ? "  └ " : "    ", style: .init(modifiers: [.dim]))
          Span(action.kind.rawValue, style: .init(foreground: .cyan))
          if !action.subject.isEmpty { Span(" \(action.subject)") }
          if let path = action.path {
            Span(" in ", style: .init(modifiers: [.dim]))
            Span(path)
          }
        })
    }
    return result
  }

  private func editLines(
    path: String, additions: Int, deletions: Int, lines: [DiffLine], width: Int
  ) -> [Line] {
    var result = [
      Line {
        Span("• ", style: .init(modifiers: [.dim]))
        Span("Edited ", style: .init(modifiers: [.bold]))
        Span(displayPath(path))
        Span(" (")
        Span("+\(additions)", style: .init(foreground: .green))
        Span(" ")
        Span("-\(deletions)", style: .init(foreground: .red))
        Span(")")
      }
    ]
    let numberWidth = max(1, String(lines.compactMap(\.lineNumber).max() ?? 0).count)
    for diff in lines {
      if diff.kind == .separator {
        result.append(Line("    ⋮", style: .init(modifiers: [.dim])))
        continue
      }
      let background: Color? =
        diff.kind == .addition
        ? .rgb(33, 58, 43)
        : diff.kind == .deletion ? .rgb(74, 34, 29) : nil
      let marker = diff.kind == .addition ? "+" : diff.kind == .deletion ? "-" : " "
      let number = diff.lineNumber.map(String.init) ?? ""
      var line = Line(style: .init(background: background)) {
        Span("    ")
        Span(
          String(repeating: " ", count: max(0, numberWidth - number.count)) + number,
          style: .init(modifiers: [.dim]))
        Span(" \(marker)", style: .init(modifiers: [.dim]))
      }
      for span in Self.syntaxHighlighter.highlight(
        diff.text.replacingOccurrences(of: "\t", with: "    "),
        language: TerminalSyntaxHighlighter.language(forPath: path),
        theme: snapshot.syntaxTheme,
        background: background)
      {
        line = line.pushSpan(span)
      }
      let used = line.width
      if used < width { line = line.pushSpan(Span(String(repeating: " ", count: width - used))) }
      result.append(line)
    }
    return result
  }

  private func shellSpans(_ command: String) -> [Span] {
    Self.syntaxHighlighter.highlight(
      command, language: "bash", theme: snapshot.syntaxTheme)
  }

  private func displayPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
  }

  private func renderSuggestions(
    in area: Rect, into buffer: inout Buffer, environment: RenderEnvironment
  ) {
    guard !area.isEmpty else { return }
    Text(Array(slashSuggestionLines(width: Int(area.width)).prefix(Int(area.height))))
      .render(in: area, into: &buffer, environment: environment)
  }

  private func renderStatus(
    in area: Rect, into buffer: inout Buffer, environment: RenderEnvironment
  ) {
    guard !area.isEmpty else { return }
    var rows: [Line] = []
    if snapshot.isWorking {
      rows.append(
        Line {
          Span("• ", style: .init(modifiers: [.dim]))
          Span(snapshot.workingLabel)
          Span(" (\(formatElapsed(snapshot.elapsedSeconds)) • ", style: .init(modifiers: [.dim]))
          Span("esc", style: .init(modifiers: [.dim]))
          Span(" to interrupt • ctrl-t transcript)", style: .init(modifiers: [.dim]))
        })
    }
    if snapshot.isWorking, !snapshot.queuedMessages.isEmpty { rows.append(Line("")) }
    if !snapshot.queuedMessages.isEmpty {
      rows.append(
        Line {
          Span("• ", style: .init(modifiers: [.dim]))
          Span("Queued follow-up inputs")
        })
    }
    for message in snapshot.queuedMessages {
      let preview = queuePreviewLines(message, width: Int(area.width))
      rows += Array(preview.prefix(3))
      if preview.count > 3 {
        rows.append(Line("    …", style: .init(modifiers: [.dim, .italic])))
      }
    }
    if !snapshot.queuedMessages.isEmpty {
      rows.append(
        Line {
          Span("    ⌥ + ↑", style: .init(modifiers: [.dim]))
          Span(" edit last queued message", style: .init(modifiers: [.dim]))
        })
    }
    Text(rows).render(in: area, into: &buffer, environment: environment)
  }

  private func composerTextLayout(width: Int) -> ComposerTextLayout {
    let contentWidth = max(1, width - 3)
    let characters = Array(snapshot.composer.text)
    var lines = [""]
    var lineWidth = 0
    var cursorLine = 0
    var cursorColumn = 0

    for (index, character) in characters.enumerated() {
      if character == "\n" {
        if index == snapshot.composer.cursor {
          cursorLine = lines.count - 1
          cursorColumn = lineWidth
        }
        lines.append("")
        lineWidth = 0
        continue
      }

      let startsWord =
        !character.isWhitespace
        && (index == 0 || characters[index - 1].isWhitespace)
      if startsWord, lineWidth > 0 {
        var wordWidth = 0
        var lookahead = index
        while lookahead < characters.count,
          !characters[lookahead].isWhitespace
        {
          wordWidth += max(0, TerminalWidth.of(String(characters[lookahead])))
          lookahead += 1
        }
        if lineWidth + wordWidth > contentWidth {
          lines.append("")
          lineWidth = 0
        }
      }

      let characterWidth = max(0, TerminalWidth.of(String(character)))
      if lineWidth > 0, lineWidth + characterWidth > contentWidth {
        lines.append("")
        lineWidth = 0
      }
      if index == snapshot.composer.cursor {
        cursorLine = lines.count - 1
        cursorColumn = lineWidth
      }
      if character.isWhitespace, lineWidth == 0 { continue }
      lines[lines.count - 1].append(character)
      lineWidth += characterWidth
    }
    if snapshot.composer.cursor >= characters.count {
      cursorLine = lines.count - 1
      cursorColumn = lineWidth
    }
    return ComposerTextLayout(
      lines: lines, cursorLine: cursorLine, cursorColumn: min(contentWidth, cursorColumn))
  }

  private func visibleImageAttachments() -> [(index: Int, attachment: CodexImageAttachment)] {
    let count = snapshot.imageAttachments.count
    guard count > 0 else { return [] }
    let visibleCount = min(3, count)
    let start: Int
    if let selected = snapshot.selectedImageAttachmentIndex {
      start = min(max(0, selected), count - visibleCount)
    } else {
      start = count - visibleCount
    }
    return (start..<(start + visibleCount)).map { ($0, snapshot.imageAttachments[$0]) }
  }

  private func renderComposer(
    in area: Rect, into buffer: inout Buffer, environment: RenderEnvironment,
    showsFooter: Bool = true
  ) {
    guard !area.isEmpty else { return }
    let textLayout = composerTextLayout(width: Int(area.width))
    let attachments = visibleImageAttachments()
    let imageHeight = attachments.count + (attachments.isEmpty ? 0 : 1)
    let footerHeight = showsFooter && slashSuggestions().isEmpty ? 1 : 0
    let desiredPanelHeight = 2 + imageHeight + textLayout.lines.count
    let panelHeight = min(
      desiredPanelHeight, max(1, Int(area.height) - footerHeight))
    let panel = Rect(
      x: area.x, y: area.y, width: area.width, height: UInt16(panelHeight))
    let panelStyle = Style(background: .rgb(63, 67, 74))
    buffer.fill(panel, with: Cell(symbol: " ", style: panelStyle))

    for (row, item) in attachments.enumerated()
    where row + 1 < panelHeight {
      let isSelected = snapshot.selectedImageAttachmentIndex == item.index
      let rowStyle =
        isSelected
        ? panelStyle.patching(.init(modifiers: [.reversed])) : panelStyle
      let rowArea = Rect(
        x: panel.x, y: UInt16(clamping: Int(panel.y) + 1 + row), width: panel.width,
        height: 1)
      if isSelected { buffer.fill(rowArea, with: Cell(symbol: " ", style: rowStyle)) }
      Line(style: rowStyle) {
        Span(isSelected ? "› " : "  ", style: .init(modifiers: isSelected ? [.bold] : []))
        Span("[Image #\(item.index + 1)]", style: .init(foreground: .cyan))
        Span(" \(item.attachment.name)", style: .init(modifiers: [.dim]))
      }.render(in: rowArea, into: &buffer, environment: environment)
    }

    let textStartY = Int(panel.y) + 1 + imageHeight
    let availableTextRows = max(0, panelHeight - 2 - imageHeight)
    let firstVisibleLine = max(0, textLayout.cursorLine - max(1, availableTextRows) + 1)
    let visibleLines = textLayout.lines.dropFirst(firstVisibleLine).prefix(availableTextRows)
    let placeholder =
      snapshot.mode == .side
      ? "Check recently modified functions for compatibility"
      : "Find and fix a bug in @filename"
    for (row, line) in visibleLines.enumerated() {
      let displayed = snapshot.composer.text.isEmpty ? placeholder : line
      let textStyle: Style = snapshot.composer.text.isEmpty ? .init(modifiers: [.dim]) : .plain
      Line(style: panelStyle) {
        Span(row == 0 ? "› " : "  ", style: .init(modifiers: row == 0 ? [.bold] : []))
        Span(displayed, style: textStyle)
      }
      .render(
        in: Rect(
          x: area.x, y: UInt16(clamping: textStartY + row), width: area.width,
          height: 1),
        into: &buffer, environment: environment)
    }
    guard footerHeight > 0, area.height > UInt16(panelHeight) else { return }
    let footerY = area.bottom - 1
    let left =
      snapshot.mode == .side
      ? "  \(snapshot.model) \(snapshot.reasoningEffort)"
      : "  \(snapshot.model) \(snapshot.reasoningEffort) · \(displayPath(snapshot.directory))"
    let baseRight =
      snapshot.mode == .side
      ? "Side from main thread · ctrl + / to switch · ctrl + c to close"
      : snapshot.rightStatus ?? ""
    let vimIndicator = snapshot.vimEnabled ? "Vim: \(snapshot.vimMode.rawValue)" : ""
    let right = [baseRight, vimIndicator].filter { !$0.isEmpty }.joined(separator: " | ")
    let gap = max(1, Int(area.width) - TerminalWidth.of(left) - TerminalWidth.of(right) - 2)
    Line {
      Span("  \(snapshot.model)", style: .init(foreground: .yellow))
      Span(" \(snapshot.reasoningEffort)")
      if snapshot.mode != .side {
        Span(" · ", style: .init(modifiers: [.dim]))
        Span(displayPath(snapshot.directory), style: .init(foreground: .green))
      }
      Span(String(repeating: " ", count: gap))
      if !right.isEmpty {
        Span(
          right,
          style: .init(
            foreground: snapshot.vimMode == .insert && snapshot.vimEnabled ? .green : .magenta))
      }
      Span("  ")
    }.render(
      in: Rect(x: area.x, y: footerY, width: area.width, height: 1),
      into: &buffer, environment: environment)
  }

  private func render(
    _ overlay: CodexOverlay, in area: Rect, into buffer: inout Buffer,
    environment: RenderEnvironment
  ) {
    guard !area.isEmpty else { return }
    switch overlay {
    case .shortcuts:
      Text {
        Line { Span("Keyboard shortcuts", style: .init(modifiers: [.bold])) }
        Line("")
        Line {
          Span("enter", style: .init(foreground: .cyan))
          Span("  send message")
        }
        Line {
          Span("tab", style: .init(foreground: .cyan))
          Span("    queue follow-up")
        }
        Line {
          Span("esc", style: .init(foreground: .cyan))
          Span("    interrupt or close")
        }
        Line {
          Span("ctrl-c", style: .init(foreground: .cyan))
          Span(" quit when idle")
        }
        Line {
          Span("!", style: .init(foreground: .cyan))
          Span("      run a local shell command")
        }
      }.render(in: area, into: &buffer, environment: environment)
    case .approval(let approval):
      var rows: [Line] = [
        Line(""),
        Line {
          Span("  ")
          Span(approval.title, style: .init(modifiers: [.bold]))
        },
        Line(""),
      ]
      if let reason = approval.reason {
        rows += [
          Line {
            Span("  Reason: ")
            Span(reason, style: .init(modifiers: [.italic]))
          },
          Line(""),
        ]
      }
      if let command = approval.command {
        rows += [
          Line {
            Span("  $ ")
            for span in shellSpans(command) { span }
          },
          Line(""),
        ]
      }
      for (index, choice) in approval.choices.enumerated() {
        let selected = index == approval.selectedIndex
        let selectedStyle = Style(foreground: .cyan, modifiers: [.bold])
        rows.append(
          Line {
            Span(
              selected ? "› " : "  ", style: selected ? selectedStyle : .plain)
            Span("\(index + 1). ", style: selected ? selectedStyle : .plain)
            Span(choice.title, style: selected ? selectedStyle : .plain)
            if let detail = choice.detail { Span(" — \(detail)", style: .init(modifiers: [.dim])) }
            if let shortcut = choice.shortcut {
              Span(" (\(shortcut))", style: selected ? selectedStyle : .init(modifiers: [.dim]))
            }
          })
      }
      rows += [
        Line(""),
        Line("  Press enter to confirm or esc to cancel", style: .init(modifiers: [.dim])),
      ]
      Paragraph(Text(rows), wrap: .word, trimLeadingWhitespace: false)
        .render(in: area, into: &buffer, environment: environment)
    case .requestUserInput(let request):
      renderRequestUserInput(request, in: area, into: &buffer, environment: environment)
    case .models(let picker):
      let models = picker.filteredModels
      let visibleRows = max(1, Int(area.height) - 6)
      let start = min(
        max(0, picker.selectedIndex - visibleRows / 2),
        max(0, models.count - visibleRows))
      let end = min(models.count, start + visibleRows)
      var rows: [Line] = [
        Line { Span("  Select Model and Effort", style: .init(modifiers: [.bold])) },
        Line(
          "  Models from pi/KWWK catalogs for authenticated providers",
          style: .init(modifiers: [.dim])),
        Line {
          Span("  Search: ", style: .init(modifiers: [.dim]))
          Span(picker.query.isEmpty ? "type to filter" : picker.query)
        },
        Line(""),
      ]
      if models.isEmpty {
        rows.append(Line("  No matching models", style: .init(modifiers: [.dim])))
      }
      for index in start..<end {
        let model = models[index]
        let selected = index == picker.selectedIndex
        let style = selected ? Style(foreground: .cyan, modifiers: [.bold]) : .plain
        let isCurrent =
          model.modelID == snapshot.model
          && (snapshot.modelProvider.isEmpty || model.provider == snapshot.modelProvider)
        let suffix = isCurrent ? " (current)" : ""
        rows.append(
          Line {
            Span(selected ? "› " : "  ", style: style)
            Span("\(index + 1). \(model.modelID)\(suffix)", style: style)
            Span("  \(model.name)", style: .init(modifiers: [.dim]))
            Span("  [\(model.provider)]", style: .init(modifiers: [.dim]))
          })
      }
      rows += [
        Line(""),
        Line("  Press enter to confirm or esc to go back", style: .init(modifiers: [.dim])),
      ]
      Paragraph(Text(rows), wrap: .word, trimLeadingWhitespace: false)
        .render(in: area, into: &buffer, environment: environment)
    case .reasoning(let picker):
      var rows: [Line] = [
        Line {
          Span("  ")
          Span("Select Reasoning Level for \(picker.modelName)", style: .init(modifiers: [.bold]))
        },
        Line(""),
      ]
      let items = picker.options.map { option in
        let defaultSuffix = option.isDefault ? " (default)" : ""
        let currentSuffix = option.id == snapshot.reasoningEffort ? " (current)" : ""
        return ("\(option.label)\(defaultSuffix)\(currentSuffix)", option.description)
      }
      rows += selectionMenuRows(items, selectedIndex: picker.selectedIndex, width: Int(area.width))
      rows += [
        Line(""),
        Line("  Press enter to confirm or esc to go back", style: .init(modifiers: [.dim])),
      ]
      Paragraph(Text(rows), wrap: .word, trimLeadingWhitespace: false)
        .render(in: area, into: &buffer, environment: environment)
    case .permissions(let picker):
      renderPermissions(picker, in: area, into: &buffer, environment: environment)
    case .personality(let picker):
      var rows: [Line] = [
        Line { Span("  Select Personality", style: .init(modifiers: [.bold])) },
        Line("  Choose a communication style for Codex.", style: .init(modifiers: [.dim])),
        Line(""),
      ]
      let personalities: [CodexPersonality] = [.friendly, .pragmatic]
      let items = personalities.map { personality in
        (
          "\(personality.rawValue)\(personality == snapshot.personality ? " (current)" : "")",
          personality.description
        )
      }
      rows += selectionMenuRows(
        items, selectedIndex: picker.selectedIndex, width: Int(area.width))
      rows += [
        Line(""),
        Line("  Press enter to confirm or esc to go back", style: .init(modifiers: [.dim])),
      ]
      Paragraph(Text(rows), wrap: .word, trimLeadingWhitespace: false)
        .render(in: area, into: &buffer, environment: environment)
    case .theme(let picker):
      renderThemePicker(picker, in: area, into: &buffer, environment: environment)
    case .keymap(let picker):
      let actions = picker.filteredActions
      let visibleRows = max(1, Int(area.height) - 6)
      let tabs = CodexKeymapTab.allCases.map { tab in
        let label = tab.label(
          customizedCount: picker.customizedCount, unboundCount: picker.unboundCount)
        return tab == picker.tab ? "[\(label)]" : label
      }.joined(separator: "  ")
      let start = min(
        max(0, picker.selectedIndex - visibleRows / 2), max(0, actions.count - visibleRows))
      let end = min(actions.count, start + visibleRows)
      var rows: [Line] = [
        Line { Span("  Keymap", style: .init(modifiers: [.bold])) },
        Line("  \(tabs)", style: .init(modifiers: [.dim])),
        Line {
          Span("  Search: ", style: .init(modifiers: [.dim]))
          Span(picker.query.isEmpty ? "Type to search shortcuts" : picker.query)
        },
        Line(""),
      ]
      if picker.tab == .debug {
        rows.append(
          Line("› Inspect keypresses", style: .init(foreground: .cyan, modifiers: [.bold])))
        rows.append(
          Line(
            "  Press enter, then press any key to inspect what the terminal sends.",
            style: .init(modifiers: [.dim])))
      } else if actions.isEmpty {
        let message = picker.query.isEmpty ? "No shortcuts in this group" : "No matching shortcuts"
        rows.append(Line("  \(message)", style: .init(modifiers: [.dim])))
      } else {
        for index in start..<end {
          let action = actions[index]
          let selected = index == picker.selectedIndex
          let style = selected ? Style(foreground: .cyan, modifiers: [.bold]) : .plain
          let bindings = picker.runtime.bindings(for: action)
          let marker = picker.runtime.isCustomized(action) ? "*" : (bindings.isEmpty ? "-" : " ")
          let binding =
            bindings.isEmpty ? "unbound" : bindings.map(\.canonicalName).joined(separator: ", ")
          rows.append(
            Line {
              Span(selected ? "›" : " ", style: style)
              Span(
                marker,
                style: picker.runtime.isCustomized(action)
                  ? .init(foreground: .cyan) : .init(modifiers: [.dim]))
              Span(
                " \(action.context.label.padding(toLength: 10, withPad: " ", startingAt: 0))",
                style: .init(modifiers: [.dim]))
              Span(action.label, style: style)
              Span("  \(binding)", style: .init(modifiers: [.dim]))
            })
        }
      }
      rows += [
        Line(""),
        Line(
          "  ←/→ group  ↑/↓ navigate  enter select  * custom  - unbound  esc close",
          style: .init(modifiers: [.dim])),
      ]
      Paragraph(Text(rows), wrap: .character, trimLeadingWhitespace: false)
        .render(in: area, into: &buffer, environment: environment)
    case .keymapAction(let menu):
      let runtime = menu.runtime
      let bindings = runtime.bindings(for: menu.action)
      var rows: [Line] = [
        Line("  Edit Shortcut", style: .init(modifiers: [.bold])),
        Line(""),
        Line { Span("  \(menu.action.label)", style: .init(modifiers: [.bold])) },
        Line("  Context: \(menu.action.context.label)", style: .init(modifiers: [.dim])),
        Line {
          Span("  Current: ", style: .init(modifiers: [.dim]))
          Span(
            bindings.isEmpty ? "unbound" : bindings.map(\.canonicalName).joined(separator: ", "),
            style: .init(foreground: .cyan))
        },
        Line(
          "  Source: \(runtime.isCustomized(menu.action) ? "Custom root override" : "Default keymap")",
          style: .init(modifiers: [.dim])),
        Line("  \(menu.action.path)", style: .init(foreground: .cyan)),
        Line(""),
      ]
      for (index, operation) in menu.operations.enumerated() {
        let selected = index == menu.selectedIndex
        let style = selected ? Style(foreground: .cyan, modifiers: [.bold]) : .plain
        let label: String
        switch operation {
        case .replaceAll: label = bindings.isEmpty ? "Set key" : "Replace all bindings"
        case .addAlternate: label = "Add alternate binding"
        case .removeCustom: label = "Remove custom binding"
        case .back: label = "Back to shortcuts"
        }
        rows.append(
          Line {
            Span(selected ? "› " : "  ", style: style)
            Span(label, style: style)
          })
      }
      rows += [
        Line(""),
        Line("  Changes write root tui.keymap.* overrides", style: .init(modifiers: [.dim])),
      ]
      Paragraph(Text(rows), wrap: .word, trimLeadingWhitespace: false)
        .render(in: area, into: &buffer, environment: environment)
    case .keymapCapture(let capture):
      Text {
        Line("  Set Shortcut", style: .init(modifiers: [.bold]))
        Line("")
        Line { Span("  \(capture.action.label)", style: .init(modifiers: [.bold])) }
        Line("  Press the new key binding.")
        Line(
          "  One terminal key event is captured; chords are not supported.",
          style: .init(modifiers: [.dim]))
        Line("")
        Line("  esc cancel", style: .init(modifiers: [.dim]))
      }.render(in: area, into: &buffer, environment: environment)
    case .keymapDebug(let debug):
      var rows: [Line] = [
        Line("  Keypress Inspector", style: .init(modifiers: [.bold])),
        Line(
          "  Press any key to see what Codex receives. Esc is inspected; Ctrl+C closes.",
          style: .init(modifiers: [.dim])),
        Line(
          "  Tip: Codex can only inspect keys your terminal sends.",
          style: .init(modifiers: [.dim])),
        Line(""),
      ]
      if let rawEvent = debug.rawEvent {
        rows.append(
          Line {
            Span("  Detected: ", style: .init(modifiers: [.dim]))
            Span(debug.detected?.canonicalName ?? "unsupported", style: .init(foreground: .cyan))
          })
        rows.append(
          Line {
            Span("  Config key: ", style: .init(modifiers: [.dim]))
            Span(debug.detected?.canonicalName ?? "unsupported", style: .init(foreground: .cyan))
          })
        rows.append(Line("  Raw event: \(rawEvent)", style: .init(modifiers: [.dim])))
        rows.append(Line(""))
        rows.append(Line("  Assigned actions:", style: .init(modifiers: [.dim])))
        if debug.matches.isEmpty {
          rows.append(Line("    none", style: .init(modifiers: [.dim])))
        } else {
          rows += debug.matches.map { match in
            Line(
              "    - \(match.action.context.rawValue).\(match.action.rawValue) (\(match.action.label)) - \(match.action.description) [\(match.source)]",
              style: .init(modifiers: [.dim]))
          }
        }
      } else {
        rows.append(Line("  Waiting for a keypress...", style: .init(foreground: .cyan)))
      }
      Paragraph(Text(rows), wrap: .word, trimLeadingWhitespace: false)
        .render(in: area, into: &buffer, environment: environment)
    case .transcript(let pager):
      guard area.height >= 3 else { return }
      Line(" T R A N S C R I P T", style: .init(modifiers: [.bold]))
        .render(
          in: Rect(x: area.x, y: area.y, width: area.width, height: 1), into: &buffer,
          environment: environment)
      let contentArea = Rect(
        x: area.x, y: area.y + 1, width: area.width, height: area.height - 2)
      let percent: Int
      if !snapshot.rawOutputMode, pager.cachedWidth == contentArea.width,
        let cached = pager.cachedTranscriptLines
      {
        let viewport = ScrollViewport(
          totalRows: cached.count,
          viewportRows: Int(contentArea.height),
          offsetFromEnd: pager.scrollFromBottom)
        Paragraph(
          Text(Array(cached[viewport.visibleRange])), wrap: .none,
          trimLeadingWhitespace: false
        ).render(in: contentArea, into: &buffer, environment: environment)
        percent = viewport.progressPercent
      } else {
        let lines = renderedTranscriptLines(
          width: Int(contentArea.width), highlightedUserFromEnd: pager.highlightedUserFromEnd,
          entries: pager.sourceEntries)
        var paragraph = Paragraph(
          Text(lines), wrap: snapshot.rawOutputMode ? .character : .word,
          trimLeadingWhitespace: false)
        let total = paragraph.lineCount(width: contentArea.width)
        let maxScroll = max(0, total - Int(contentArea.height))
        let distance = min(maxScroll, pager.scrollFromBottom)
        let scroll = maxScroll - distance
        paragraph.scroll = UInt16(clamping: scroll)
        paragraph.render(in: contentArea, into: &buffer, environment: environment)
        percent =
          maxScroll == 0 ? 100 : Int((Double(scroll) / Double(maxScroll) * 100).rounded())
      }
      let footer: String
      if let selected = pager.selectedBacktrackIndex,
        pager.backtrackCandidates.indices.contains(selected)
      {
        footer =
          area.width < 80
          ? "─ esc/← older  → newer  enter rewind  q cancel "
          : "─ esc/← older  → newer  enter rewind  q cancel · \(pager.backtrackCandidates[selected].preview) "
      } else {
        footer =
          area.width < 80
          ? "─ ↑/↓ scroll  pgup/dn page  home/end  esc close  \(percent)% "
          : "─ ↑/↓ scroll  pgup/pgdn page  home/end jump  ctrl-t/esc close  \(percent)% "
      }
      Line(footer, style: .init(modifiers: [.dim]))
        .render(
          in: Rect(x: area.x, y: area.bottom - 1, width: area.width, height: 1), into: &buffer,
          environment: environment)
    case .sessions(let picker):
      renderSessionPicker(picker, in: area, into: &buffer, environment: environment)
    case .rename(let prompt):
      Text {
        Line {
          Span("▌ ", style: .init(foreground: .magenta))
          Span("Rename thread", style: .init(modifiers: [.bold]))
        }
        Line("▌", style: .init(foreground: .magenta))
        Line {
          Span("▌ ", style: .init(foreground: .magenta))
          Span(prompt.name.text)
        }
        Line("")
        Line("Press enter to confirm or esc to go back", style: .init(modifiers: [.dim]))
      }.render(in: area, into: &buffer, environment: environment)
    case .sessionConfirmation(let confirmation):
      let deleting = confirmation.action == .delete
      let choices =
        deleting
        ? [
          ("No, keep this session", "Return to the current session"),
          ("Yes, delete and exit", "Permanently delete this session now"),
        ]
        : [
          ("No, don't archive", "Return to the current session"),
          ("Yes, archive and exit", "Archive this session now"),
        ]
      var rows: [Line] = [
        Line(
          "  \(deleting ? "Delete" : "Archive") this session?", style: .init(modifiers: [.bold])),
        Line(
          "  \(deleting ? "Cannot be undone. Subagent threads will also be deleted." : "Are you sure? This will archive the current session and exit Codex")"
        ),
        Line(""),
      ]
      rows += selectionMenuRows(
        choices, selectedIndex: confirmation.selectedIndex, width: Int(area.width))
      rows += [
        Line(""),
        Line("  Press enter to confirm or esc to go back", style: .init(modifiers: [.dim])),
      ]
      Text(rows).render(in: area, into: &buffer, environment: environment)
    case .historySearch(let search):
      let preview = search.selectedIndex.flatMap {
        search.matches.indices.contains($0) ? search.matches[$0] : nil
      }
      Text {
        Line {
          Span("reverse-search: ", style: .init(foreground: .cyan, modifiers: [.bold]))
          Span(search.query.text)
        }
        Line(preview ?? "No matching history", style: .init(modifiers: [.dim]))
        Line("")
        Line(
          "ctrl-r older  ctrl-s newer  enter accept  esc cancel", style: .init(modifiers: [.dim]))
      }.render(in: area, into: &buffer, environment: environment)
    case .review(let picker):
      var rows: [Line] = [
        Line("  Select a review preset", style: .init(modifiers: [.bold])),
        Line(""),
      ]
      rows += selectionMenuRows(
        [
          ("Review against a base branch", "(PR Style)"),
          ("Review uncommitted changes", "Review the current working tree"),
          ("Review a commit", "Review the most recent commit"),
          ("Custom review instructions", "Type your own review focus"),
        ], selectedIndex: picker.selectedIndex, width: Int(area.width))
      rows += [
        Line(""),
        Line("  Press enter to confirm or esc to go back", style: .init(modifiers: [.dim])),
      ]
      Text(rows).render(in: area, into: &buffer, environment: environment)
    case .agents(let picker):
      var rows: [Line] = [
        Line("  Subagents", style: .init(modifiers: [.bold])),
        Line(
          "  Select an agent to watch. ⌥ + ← previous, ⌥ + → next.",
          style: .init(modifiers: [.dim])),
        Line(""),
      ]
      for (index, thread) in picker.threads.enumerated() {
        let selected = index == picker.selectedIndex
        let selectedStyle = selected ? Style(foreground: .cyan, modifiers: [.bold]) : .plain
        let isMain = thread.role == "main"
        let name = isMain ? "Main [default]" : "\(thread.name) [\(thread.role)]"
        let current = isMain ? " (current)" : ""
        let dotStyle: Style =
          thread.status == "running"
          ? .init(foreground: .green)
          : .init(
            modifiers: [.dim])
        rows.append(
          Line {
            Span(selected ? "› " : "  ", style: selectedStyle)
            Span("\(index + 1). ", style: selectedStyle)
            Span("•", style: dotStyle)
            Span(" \(name)\(current)", style: selectedStyle)
            Span("  \(thread.id)", style: .init(modifiers: [.dim]))
          })
      }
      rows += [
        Line(""),
        Line("  Press enter to confirm or esc to go back", style: .init(modifiers: [.dim])),
      ]
      Paragraph(Text(rows), wrap: .word, trimLeadingWhitespace: false)
        .render(in: area, into: &buffer, environment: environment)
    case .agentPreview(let preview):
      var rows: [Line] = [
        Line {
          Span("  Watching \(preview.thread.name)", style: .init(modifiers: [.bold]))
          Span("  \(preview.thread.status)", style: .init(foreground: .cyan))
        },
        Line(
          "  View only · \(preview.thread.description)", style: .init(modifiers: [.dim])),
        Line(""),
      ]
      for entry in preview.thread.entries {
        rows += transcriptLines(for: entry.content, width: Int(area.width))
        rows.append(Line(""))
      }
      rows.append(
        Line(
          "  ⌥ + ← previous  ⌥ + → next  esc return to agent list",
          style: .init(modifiers: [.dim])))
      var paragraph = Paragraph(Text(rows), wrap: .word, trimLeadingWhitespace: false)
      let total = paragraph.lineCount(width: area.width)
      paragraph.scroll = UInt16(clamping: max(0, total - Int(area.height)))
      paragraph.render(in: area, into: &buffer, environment: environment)
    case .backgroundTasks(let picker):
      var rows: [Line] = [
        Line("  Background terminals", style: .init(modifiers: [.bold])),
        Line(""),
      ]
      if picker.tasks.isEmpty {
        rows.append(Line("  No background terminals", style: .init(modifiers: [.dim])))
      } else {
        let items = picker.tasks.map {
          ("\($0.label) [\($0.status)]", "\($0.kind) · \($0.id)")
        }
        rows += selectionMenuRows(
          items, selectedIndex: picker.selectedIndex, width: Int(area.width))
        if picker.tasks.indices.contains(picker.selectedIndex) {
          let output = picker.tasks[picker.selectedIndex].output
          if !output.isEmpty {
            rows += [Line(""), Line("  Recent output", style: .init(modifiers: [.bold]))]
            rows += output.split(separator: "\n").suffix(4).map {
              Line("  \($0)", style: .init(modifiers: [.dim]))
            }
          }
        }
      }
      rows += [Line(""), Line("  esc close", style: .init(modifiers: [.dim]))]
      Paragraph(Text(rows), wrap: .word, trimLeadingWhitespace: false)
        .render(in: area, into: &buffer, environment: environment)
    case .skills(let picker):
      var rows: [Line] = [
        Line("  Skills", style: .init(modifiers: [.bold])),
        Line {
          Span("  Search: ", style: .init(modifiers: [.dim]))
          Span(picker.query.text.isEmpty ? "Type to filter" : picker.query.text)
        },
        Line(""),
      ]
      let filtered = picker.filteredSkills
      if filtered.isEmpty {
        rows.append(Line("  No matching skills", style: .init(modifiers: [.dim])))
      } else {
        let items = filtered.map { ($0.name, $0.description) }
        let groups = selectionMenuRowGroups(
          items, selectedIndex: picker.selectedIndex, width: Int(area.width))
        let viewport = SelectionViewport.fitting(
          itemHeights: groups.map(\.count), selectedIndex: picker.selectedIndex,
          capacity: max(1, Int(area.height) - 5))
        rows += viewport.range.flatMap { groups[$0] }
      }
      rows += [
        Line(""),
        Line("  Press enter to mention or esc to go back", style: .init(modifiers: [.dim])),
      ]
      Paragraph(Text(rows), wrap: .word, trimLeadingWhitespace: false)
        .render(in: area, into: &buffer, environment: environment)
    case .fileMentions(let picker):
      var rows: [Line] = [
        Line("  Mention a file", style: .init(modifiers: [.bold])),
        Line {
          Span("  Search: ", style: .init(modifiers: [.dim]))
          Span(picker.query.text.isEmpty ? "Type to filter" : picker.query.text)
        },
        Line(""),
      ]
      let filtered = picker.filteredFiles
      if filtered.isEmpty {
        rows.append(Line("  No matching files", style: .init(modifiers: [.dim])))
      } else {
        let groups = selectionMenuRowGroups(
          filtered.map { ($0, "") }, selectedIndex: picker.selectedIndex,
          width: Int(area.width))
        let viewport = SelectionViewport.fitting(
          itemHeights: groups.map(\.count), selectedIndex: picker.selectedIndex,
          capacity: max(1, Int(area.height) - 5))
        rows += viewport.range.flatMap { groups[$0] }
      }
      rows += [
        Line(""),
        Line("  Press enter to mention or esc to go back", style: .init(modifiers: [.dim])),
      ]
      Paragraph(Text(rows), wrap: .word, trimLeadingWhitespace: false)
        .render(in: area, into: &buffer, environment: environment)
    case .rewind(let picker):
      var rows: [Line] = [
        Line("  Rewind to message", style: .init(modifiers: [.bold])),
        Line(
          "  The selected message and everything after it will be removed.",
          style: .init(modifiers: [.dim])),
        Line(""),
      ]
      let visibleRows = max(1, Int(area.height) - 5)
      let start = min(
        max(0, picker.selectedIndex - visibleRows / 2),
        max(0, picker.candidates.count - visibleRows))
      let end = min(picker.candidates.count, start + visibleRows)
      for index in start..<end {
        let candidate = picker.candidates[index]
        let selected = index == picker.selectedIndex
        let style = selected ? Style(foreground: .cyan, modifiers: [.bold]) : .plain
        rows.append(
          Line {
            Span(selected ? "› " : "  ", style: style)
            Span(candidate.preview, style: style)
          })
      }
      rows += [
        Line(""),
        Line("  Press enter to rewind or esc to cancel", style: .init(modifiers: [.dim])),
      ]
      Paragraph(Text(rows), wrap: .word, trimLeadingWhitespace: false)
        .render(in: area, into: &buffer, environment: environment)
    }
  }

  private func renderThemePicker(
    _ picker: ThemePicker, in area: Rect, into buffer: inout Buffer,
    environment: RenderEnvironment
  ) {
    let wide = area.width >= 94
    let listWidth = wide ? max(40, Int(area.width) / 2) : Int(area.width)
    let listArea = Rect(
      x: area.x, y: area.y, width: UInt16(clamping: listWidth),
      height: wide ? area.height : UInt16(clamping: max(0, Int(area.height) - 4)))
    let themes = picker.filteredThemes
    let visibleCount = max(1, Int(listArea.height) - 6)
    let start = min(
      max(0, picker.selectedIndex - visibleCount / 2), max(0, themes.count - visibleCount))
    let end = min(themes.count, start + visibleCount)
    var rows: [Line] = [
      Line("  Select Syntax Theme", style: .init(modifiers: [.bold])),
      Line {
        Span("  Search: ", style: .init(modifiers: [.dim]))
        Span(
          picker.query.text.isEmpty ? "Type to filter" : picker.query.text,
          style: picker.query.text.isEmpty ? .init(modifiers: [.dim]) : .plain)
      },
      Line(
        "  Custom .tmTheme files can be added to ~/.codex-swift/themes.",
        style: .init(modifiers: [.dim])),
      Line(""),
    ]
    if themes.isEmpty {
      rows.append(Line("  No matching themes", style: .init(modifiers: [.dim])))
    } else {
      for index in start..<end {
        let theme = themes[index]
        let selected = index == picker.selectedIndex
        let style = selected ? Style(foreground: .cyan, modifiers: [.bold]) : .plain
        rows.append(
          Line {
            Span(selected ? "› " : "  ", style: style)
            Span(theme.name, style: style)
            if theme.sourceURL != nil { Span("  custom", style: .init(modifiers: [.dim])) }
          })
      }
    }
    rows += [
      Line(""),
      Line("  enter confirm  esc cancel", style: .init(modifiers: [.dim])),
    ]
    Text(rows).render(in: listArea, into: &buffer, environment: environment)

    let previewArea: Rect
    let previewRows: [(Int, Character, String)]
    if wide {
      previewArea = Rect(
        x: UInt16(clamping: Int(area.x) + listWidth), y: area.y,
        width: UInt16(clamping: Int(area.width) - listWidth), height: area.height)
      previewRows = [
        (31, " ", "fn summarize(users: &[User]) -> String {"),
        (32, "-", "    let active = users.iter().filter(|u| u.is_active).count();"),
        (32, "+", "    let active = users.iter().filter(|u| u.is_active()).count();"),
        (33, " ", "    let names: Vec<&str> = users.iter().map(User::name).take(3).collect();"),
        (34, "-", "    format!(\"{} active: {}\", active, names.join(\", \"))"),
        (34, "+", "    format!(\"{active} active users: {}\", names.join(\", \"))"),
        (35, "+", "        .trim()"),
        (36, " ", "}"),
      ]
    } else {
      previewArea = Rect(
        x: area.x, y: UInt16(clamping: Int(area.y) + Int(area.height) - 4),
        width: area.width, height: 4)
      previewRows = [
        (12, " ", "fn greet(name: &str) -> String {"),
        (13, "-", "    format!(\"Hello, {}!\", name)"),
        (13, "+", "    format!(\"Hello, {name}!\")"),
        (14, " ", "}"),
      ]
    }
    renderThemePreview(
      previewRows, in: previewArea, theme: snapshot.syntaxTheme, wide: wide,
      into: &buffer, environment: environment)
  }

  private func renderThemePreview(
    _ previewRows: [(Int, Character, String)], in area: Rect, theme: SyntaxTheme, wide: Bool,
    into buffer: inout Buffer, environment: RenderEnvironment
  ) {
    guard !area.isEmpty else { return }
    if let background = theme.background {
      buffer.setStyle(.init(background: background), in: area)
    }
    let code = previewRows.map(\.2).joined(separator: "\n")
    let highlighted = Self.syntaxHighlighter.highlightLines(
      code, language: "rust", theme: theme)
    let topPadding = wide ? max(1, (Int(area.height) - previewRows.count) / 2) : 0
    var rows = Array(repeating: Line(""), count: topPadding)
    for (index, preview) in previewRows.enumerated() {
      let background: Color? =
        preview.1 == "+" ? .rgb(33, 58, 43) : preview.1 == "-" ? .rgb(74, 34, 29) : theme.background
      let overlay = Style(
        background: background, modifiers: preview.1 == "-" ? [.dim] : [])
      var line = Line(style: .init(background: background)) {
        if wide { Span("  ") }
        Span(String(format: "%2d", preview.0), style: overlay.adding(.dim))
        Span(" \(preview.1) ", style: overlay.adding(.dim))
      }
      let spans = highlighted.indices.contains(index) ? highlighted[index] : [Span(preview.2)]
      for span in spans {
        line = line.pushSpan(Span(span.content, style: overlay.patching(span.style)))
      }
      rows.append(line)
    }
    Text(rows).render(in: area, into: &buffer, environment: environment)
  }

  private func renderSessionPicker(
    _ picker: SessionPicker, in area: Rect, into buffer: inout Buffer,
    environment: RenderEnvironment
  ) {
    let sessions = picker.filteredSessions
    let visibleCount = max(1, Int(area.height) - 7)
    let start = min(
      max(0, picker.selectedIndex - visibleCount / 2), max(0, sessions.count - visibleCount))
    let end = min(sessions.count, start + visibleCount)
    var rows: [Line] = [
      Line(picker.action.title, style: .init(modifiers: [.bold])),
      Line {
        Span("Search: ", style: .init(modifiers: [.dim]))
        Span(
          picker.query.text.isEmpty ? "Type to search" : picker.query.text,
          style: picker.query.text.isEmpty ? .init(modifiers: [.dim]) : .plain)
      },
      Line(""),
      Line(
        "  Created  Updated     CWD               Conversation", style: .init(modifiers: [.dim])),
    ]
    if sessions.isEmpty {
      rows.append(Line("  No matching sessions", style: .init(modifiers: [.dim])))
    } else {
      for index in start..<end {
        let session = sessions[index]
        let selected = index == picker.selectedIndex
        let style = selected ? Style(foreground: .cyan, modifiers: [.bold]) : .plain
        rows.append(
          Line {
            Span(selected ? "› " : "  ", style: style)
            Span(
              relativeTime(session.createdAt).padding(
                toLength: 9, withPad: " ", startingAt: 0),
              style: .init(modifiers: [.dim]))
            Span(
              relativeTime(session.updatedAt).padding(
                toLength: 12, withPad: " ", startingAt: 0),
              style: .init(modifiers: [.dim])
            )
            Span(
              compactPath(session.directory).padding(
                toLength: 18, withPad: " ", startingAt: 0),
              style: .init(modifiers: [.dim]))
            Span(session.title, style: style)
          })
      }
    }
    rows += [
      Line(""),
      Line(
        "enter \(picker.action == .fork ? "fork" : "resume")  tab \(picker.showAllDirectories ? "current directory" : "all directories")  esc cancel",
        style: .init(modifiers: [.dim])),
    ]
    Text(rows).render(in: area, into: &buffer, environment: environment)
  }

  private func relativeTime(_ milliseconds: Int64) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince1970) - Int(milliseconds / 1_000))
    if seconds < 60 { return "now" }
    if seconds < 3_600 { return "\(seconds / 60)m ago" }
    if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
    return "\(seconds / 86_400)d ago"
  }

  private func compactPath(_ path: String) -> String {
    let display = displayPath(path)
    let width = 16
    guard TerminalWidth.of(display) > width else { return display }
    return "…" + String(display.suffix(width - 1))
  }

  private func renderPermissions(
    _ picker: PermissionPicker,
    in area: Rect,
    into buffer: inout Buffer,
    environment: RenderEnvironment
  ) {
    let choices: [(String, String)]
    var rows: [Line]
    if picker.confirmingFullAccess {
      rows = [
        Line { Span("  Enable full access?", style: .init(modifiers: [.bold])) },
        Line(""),
        Line(
          "  Codex can edit any file on your computer and run commands with network, without your approval.",
          style: .init(foreground: .red)),
        Line(""),
      ]
      choices = [
        ("Yes, continue anyway", "Apply full access for this session"),
        ("Cancel", "Go back without enabling full access"),
      ]
    } else {
      rows = [
        Line { Span("  Update Model Permissions", style: .init(modifiers: [.bold])) },
        Line(""),
      ]
      choices = [
        (
          "Ask for approval\(snapshot.permissionMode == .askForApproval ? " (current)" : "")",
          "Codex can read and edit files in the current workspace, and run commands. Approval is required to access the internet or edit other files."
        ),
        (
          "Full Access\(snapshot.permissionMode == .fullAccess ? " (current)" : "")",
          "Codex can edit files outside this workspace and access the internet without asking for approval. Exercise caution when using."
        ),
      ]
    }
    rows += selectionMenuRows(choices, selectedIndex: picker.selectedIndex, width: Int(area.width))
    rows += [
      Line(""),
      Line("  Press enter to confirm or esc to go back", style: .init(modifiers: [.dim])),
    ]
    Paragraph(Text(rows), wrap: .word, trimLeadingWhitespace: false)
      .render(in: area, into: &buffer, environment: environment)
  }

  private func selectionMenuRows(
    _ items: [(String, String)], selectedIndex: Int, width: Int
  ) -> [Line] {
    selectionMenuRowGroups(items, selectedIndex: selectedIndex, width: width).flatMap { $0 }
  }

  private func selectionMenuRowGroups(
    _ items: [(String, String)], selectedIndex: Int, width: Int
  ) -> [[Line]] {
    let nameWidth = items.map { TerminalWidth.of($0.0) }.max() ?? 0
    return items.enumerated().map { index, item in
      let selected = index == selectedIndex
      let style = selected ? Style(foreground: .cyan, modifiers: [.bold]) : .plain
      let namePadding = String(
        repeating: " ", count: max(0, nameWidth - TerminalWidth.of(item.0)))
      let prefix = "\(index + 1). \(item.0)\(namePadding)  "
      let indentation = 2 + TerminalWidth.of(prefix)
      let descriptionWidth = max(1, width - indentation)
      let chunks = hangingWrap(
        item.1, firstWidth: descriptionWidth, restWidth: descriptionWidth)
      return chunks.enumerated().map { chunkIndex, chunk in
        if chunkIndex == 0 {
          return Line {
            Span(selected ? "› " : "  ", style: style)
            Span(prefix, style: style)
            Span(chunk, style: .init(modifiers: [.dim]))
          }
        }
        return Line {
          Span(String(repeating: " ", count: indentation))
          Span(chunk, style: .init(modifiers: [.dim]))
        }
      }
    }
  }

  private func renderRequestUserInput(
    _ request: RequestUserInputRequest,
    in area: Rect,
    into buffer: inout Buffer,
    environment: RenderEnvironment
  ) {
    guard request.questions.indices.contains(request.currentIndex),
      request.answers.indices.contains(request.currentIndex)
    else { return }
    let question = request.questions[request.currentIndex]
    let answer = request.answers[request.currentIndex]
    let selected = answer.selection.selectedIndex ?? 0
    let selectedStyle = Style(foreground: .cyan, modifiers: [.bold])
    var rows = [
      Line(""),
      Line(
        "  Question \(request.currentIndex + 1)/\(request.questions.count) (\(request.unansweredCount) unanswered)"
      ),
      Line("  \(question.question)"),
      Line(""),
    ]
    if question.options.isEmpty {
      let value = answer.draft.text.isEmpty ? "Type your answer (optional)" : answer.draft.text
      rows.append(
        Line {
          Span("  › ", style: selectedStyle)
          Span(value, style: answer.draft.text.isEmpty ? .init(modifiers: [.dim]) : .plain)
        })
    } else {
      let labelWidth = question.options.map { TerminalWidth.of($0.label) }.max() ?? 0
      for (index, option) in question.options.enumerated() {
        let isSelected = request.focus == .options && index == selected
        let style = isSelected ? selectedStyle : Style.plain
        let padding = String(
          repeating: " ", count: max(0, labelWidth - TerminalWidth.of(option.label)))
        rows.append(
          Line {
            Span(isSelected ? "  › " : "    ", style: style)
            Span("\(index + 1). ", style: style)
            Span(option.label, style: style)
            Span(padding)
            if !option.description.isEmpty {
              Span("  \(option.description)", style: .init(modifiers: [.dim]))
            }
          })
      }
      if answer.showsNotes {
        rows += [Line("")]
        let value = answer.draft.text.isEmpty ? "Add notes" : answer.draft.text
        rows.append(
          Line {
            Span("  › ", style: request.focus == .text ? selectedStyle : .plain)
            Span(value, style: answer.draft.text.isEmpty ? .init(modifiers: [.dim]) : .plain)
          })
      }
    }
    rows.append(Line(""))
    var hints: [String] = []
    if !question.options.isEmpty {
      hints.append(answer.showsNotes ? "tab or esc to clear notes" : "tab to add notes")
    }
    hints.append(
      request.currentIndex + 1 == request.questions.count
        ? "enter to submit all" : "enter to submit answer")
    if request.questions.count > 1 { hints.append("←/→ to navigate questions") }
    hints.append("esc to interrupt")
    rows.append(Line("  \(hints.joined(separator: " | "))", style: .init(modifiers: [.dim])))
    Paragraph(Text(rows), wrap: .word, trimLeadingWhitespace: false)
      .render(in: area, into: &buffer, environment: environment)
  }

  private func prefixed(
    _ text: String,
    first: String,
    rest: String,
    prefixStyle: Style = .plain,
    bodyStyle: Style = .plain
  ) -> [Line] {
    let components = text.split(separator: "\n", omittingEmptySubsequences: false)
    return components.enumerated().map { index, component in
      Line {
        Span(index == 0 ? first : rest, style: prefixStyle)
        Span(String(component), style: bodyStyle)
      }
    }
  }

  private func framed(_ text: String, innerWidth: Int) -> Line {
    Line {
      Span("│ ")
      Span(text)
      Span(padding(after: text, to: innerWidth))
      Span(" │")
    }
  }

  private func padding(after text: String, to width: Int) -> String {
    String(repeating: " ", count: max(0, width - TerminalWidth.of(text)))
  }

  private func formatDuration(_ milliseconds: Int) -> String {
    milliseconds < 1_000
      ? "\(milliseconds)ms" : String(format: "%.1fs", Double(milliseconds) / 1_000)
  }

  private func formatElapsed(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3_600 { return String(format: "%dm %02ds", seconds / 60, seconds % 60) }
    return String(
      format: "%dh %02dm %02ds", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
  }

  private func formatContext(_ tokens: Int) -> String {
    tokens >= 1_000_000
      ? String(format: "%.1fM", Double(tokens) / 1_000_000)
      : "\(tokens / 1_000)K"
  }

  private func statusLineCount(width: Int) -> Int {
    var count = snapshot.isWorking ? 1 : 0
    if snapshot.isWorking, !snapshot.queuedMessages.isEmpty { count += 1 }
    if !snapshot.queuedMessages.isEmpty {
      count += 2
      let contentWidth = max(1, width - 4)
      for message in snapshot.queuedMessages {
        let wrapped = wrapWords(message, width: contentWidth).count
        count += min(4, wrapped)
      }
    }
    return count
  }

  private func queuePreviewLines(_ message: String, width: Int) -> [Line] {
    wrapWords(message, width: max(1, width - 4)).enumerated().map { index, text in
      Line {
        Span(index == 0 ? "  ↳ " : "    ", style: .init(modifiers: [.dim]))
        Span(text, style: .init(modifiers: [.dim, .italic]))
      }
    }
  }

  private func wrapWords(_ text: String, width: Int) -> [String] {
    guard width > 0 else { return [] }
    var result: [String] = []
    for sourceLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let words = sourceLine.split(whereSeparator: \.isWhitespace).map(String.init)
      guard !words.isEmpty else {
        result.append("")
        continue
      }
      var line = ""
      for word in words {
        let candidate = line.isEmpty ? word : "\(line) \(word)"
        if TerminalWidth.of(candidate) <= width {
          line = candidate
        } else {
          if !line.isEmpty { result.append(line) }
          line = word
        }
      }
      if !line.isEmpty { result.append(line) }
    }
    return result.isEmpty ? [""] : result
  }
}
