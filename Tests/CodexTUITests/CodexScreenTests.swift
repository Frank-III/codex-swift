import Foundation
import TermLoom
import TermLoomSyntaxHighlighting
import TermLoomTestSupport
import Testing

@testable import CodexTUI

@Suite struct CodexScreenTests {
  @Test func multilineComposerExpandsWithoutEatingLinesAndKeepsCursorVisible() throws {
    let composer = TextFieldState(text: "first line\nsecond line", cursor: 22)
    let snapshot = CodexSnapshot(
      model: "deepseek-v4-flash", reasoningEffort: "high", directory: "/tmp",
      composer: composer, showHeader: false)
    let screen = CodexScreen(snapshot: snapshot)
    let area = Rect(x: 0, y: 0, width: 48, height: 8)
    var frame = Frame(buffer: Buffer(area: area))

    frame.render(screen, in: area)

    let rows = frame.buffer.lines(trimmingTrailingWhitespace: true)

    let first = try #require(rows.firstIndex { $0.contains("› first line") })
    #expect(rows[first + 1].contains("second line"))
    #expect(frame.cursorPosition?.y == Int(first + 1))
    #expect(frame.buffer[Position(x: 0, y: first)].style.background == .rgb(63, 67, 74))
    #expect(frame.buffer[Position(x: 47, y: first)].style.background == .rgb(63, 67, 74))
  }

  @Test func cappedViewportAnchorsComposerBelowFlexibleTranscriptSpace() throws {
    let snapshot = CodexSnapshot(
      model: "gpt-5.6-sol", reasoningEffort: "medium", directory: "/tmp/project",
      showHeader: true)
    let screen = CodexScreen(snapshot: snapshot)
    let area = Rect(x: 0, y: 0, width: 80, height: 22)
    var buffer = Buffer(area: area)

    screen.render(in: area, into: &buffer, environment: RenderEnvironment())

    let rows = buffer.lines(trimmingTrailingWhitespace: true)
    let composerRow = try #require(rows.firstIndex { $0.contains("› Find and fix") })
    #expect(composerRow >= 18)
    #expect(rows.prefix(7).contains { $0.contains("OpenAI Codex") })
  }

  @Test func skillPopupKeepsHardwareCursorInComposer() throws {
    let snapshot = CodexSnapshot(
      composer: TextFieldState(text: "$", cursor: 1),
      overlay: .skills(
        SkillPicker(
          skills: [SkillSummary(name: "swift", description: "Swift help", path: "/swift")])),
      showHeader: false)
    let screen = CodexScreen(snapshot: snapshot)
    let area = Rect(x: 0, y: 0, width: 80, height: 12)

    var frame = Frame(buffer: Buffer(area: area))
    frame.render(screen, in: area)
    let position = try #require(frame.cursorPosition)
    #expect(position.x == 3)
    #expect(position.y == 4)
    #expect(screen.desiredHeight(width: 80) == 9)
    #expect(screen.desiredHeight(width: 20) >= 9)
    #expect(frame.cursorStyle == .steadyBar)
  }

  @Test func skillPopupTracksVariableHeightSelectionAndPreservesAbsoluteNumbers() throws {
    let skills = (1...10).map { index in
      SkillSummary(
        name: "skill-\(index)",
        description: "A deliberately long description for skill \(index) that wraps across rows.",
        path: "/skill-\(index)")
    }
    let snapshot = CodexSnapshot(
      composer: TextFieldState(text: "$", cursor: 1),
      overlay: .skills(SkillPicker(skills: skills, selectedIndex: 8)), showHeader: false)
    let screen = CodexScreen(snapshot: snapshot)
    let area = Rect(x: 0, y: 0, width: 48, height: 14)
    var buffer = Buffer(area: area)

    screen.render(in: area, into: &buffer, environment: RenderEnvironment())

    let rows = buffer.lines(trimmingTrailingWhitespace: true)
    #expect(rows.contains { $0.contains("› 9. skill-9") })
    #expect(!rows.contains { $0.contains("› 1. skill-9") })
  }

  @Test func vimInsertModeRequestsUpstreamSteadyBarCursor() throws {
    var terminal = try Terminal(backend: TestBackend(width: 60, height: 5))
    let insert = CodexScreen(
      snapshot: CodexSnapshot(vimEnabled: true, vimMode: .insert, showHeader: false))
    try terminal.draw { $0.render(insert) }
    #expect(terminal.backend.cursorStyle == .steadyBar)

    let normal = CodexScreen(
      snapshot: CodexSnapshot(vimEnabled: true, vimMode: .normal, showHeader: false))
    try terminal.draw { $0.render(normal) }
    #expect(terminal.backend.cursorStyle == .defaultUserShape)
  }

  @Test func vimNormalModeAppearsInTheComposerFooter() {
    let snapshot = CodexSnapshot(
      model: "gpt-5.6-sol", reasoningEffort: "medium", vimEnabled: true, vimMode: .normal,
      directory: "/tmp/project", composer: TextFieldState(text: "change this", cursor: 0),
      showHeader: false)
    assertWidget(CodexScreen(snapshot: snapshot), size: Size(width: 72, height: 5)) {
      """
      │                                                                        │
      │                                                                        │
      │› change this                                                           │
      │                                                                        │
      │  gpt-5.6-sol medium · /tmp/project                        Vim: Normal  │
      """
    }
  }

  @Test func rawOutputMatchesCodexCopyFriendlyTranscript() {
    let snapshot = CodexSnapshot(
      model: "gpt-5.6-sol", reasoningEffort: "medium", rawOutputMode: true,
      directory: "/tmp/project",
      entries: [
        TranscriptEntry(content: .user("Please format this\nfor copying")),
        TranscriptEntry(
          content: .assistant(
            "- first item\n- second item\n\n| Col | Value |\n| --- | --- |\n| code | `x = 1` |\n\n```text\ncopy me\n```",
            streaming: false)),
        TranscriptEntry(
          content: .tool(
            ToolActivity(
              callID: "inspect", name: "Called", detail: "workspace.inspect({path: README.md})",
              output: ["structured output", "second line"], status: .succeeded))),
      ],
      showHeader: false)

    assertWidget(CodexScreen(snapshot: snapshot), size: Size(width: 64, height: 22)) {
      """
      │Please format this                                              │
      │for copying                                                     │
      │- first item                                                    │
      │- second item                                                   │
      │                                                                │
      │| Col | Value |                                                 │
      │| --- | --- |                                                   │
      │| code | `x = 1` |                                              │
      │                                                                │
      │```text                                                         │
      │copy me                                                         │
      │```                                                             │
      │                                                                │
      │Called workspace.inspect({path: README.md})                     │
      │structured output                                               │
      │second line                                                     │
      │                                                                │
      │                                                                │
      │                                                                │
      │› Find and fix a bug in @filename                               │
      │                                                                │
      │  gpt-5.6-sol medium · /tmp/project                             │
      """
    }
  }

  @Test func themePickerMatchesUpstreamNarrowPreview() {
    let themes = [SyntaxTheme.named("dracula")!, SyntaxTheme.named("github")!]
    let snapshot = CodexSnapshot(
      syntaxTheme: themes[0],
      overlay: .theme(
        ThemePicker(themes: themes, selectedIndex: 0, originalThemeName: themes[0].name)),
      showHeader: false)
    let buffer = assertWidget(CodexScreen(snapshot: snapshot), size: Size(width: 72, height: 18)) {
      """
      │  Select Syntax Theme                                                   │
      │  Search: Type to filter                                                │
      │  Custom .tmTheme files can be added to ~/.codex-swift/themes.          │
      │                                                                        │
      │› dracula                                                               │
      │  github                                                                │
      │                                                                        │
      │  enter confirm  esc cancel                                             │
      │                                                                        │
      │                                                                        │
      │                                                                        │
      │                                                                        │
      │                                                                        │
      │                                                                        │
      │12   fn greet(name: &str) -> String {                                   │
      │13 -     format!("Hello, {}!", name)                                    │
      │13 +     format!("Hello, {name}!")                                      │
      │14   }                                                                  │
      """
    }
    #expect(buffer[Position(x: 0, y: 14)].style.background == .rgb(40, 42, 54))
    #expect(buffer[Position(x: 5, y: 14)].style.foreground == .rgb(255, 121, 198))
  }

  @Test func sideConversationComposerAndFooterMatchCodexContext() {
    let snapshot = CodexSnapshot(
      model: "gpt-5.6-sol", reasoningEffort: "default", directory: "/tmp/project",
      mode: .side, showHeader: false)
    assertWidget(CodexScreen(snapshot: snapshot), size: Size(width: 80, height: 5)) {
      """
      │                                                                                │
      │                                                                                │
      │› Check recently modified functions for compatibility                           │
      │                                                                                │
      │  gpt-5.6-sol default Side from main thread · ctrl + / to switch · ctrl + c to c│
      """
    }
  }

  @Test func archiveConfirmationMatchesCodexPopup() {
    let snapshot = CodexSnapshot(
      overlay: .sessionConfirmation(SessionActionConfirmation(action: .archive)),
      showHeader: false)
    assertWidget(CodexScreen(snapshot: snapshot), size: Size(width: 80, height: 10)) {
      """
      │  Archive this session?                                                         │
      │  Are you sure? This will archive the current session and exit Codex            │
      │                                                                                │
      │› 1. No, don't archive      Return to the current session                       │
      │  2. Yes, archive and exit  Archive this session now                            │
      │                                                                                │
      │  Press enter to confirm or esc to go back                                      │
      │                                                                                │
      │                                                                                │
      │                                                                                │
      """
    }
  }

  @Test func fileMentionPickerMatchesCodexPopup() {
    let snapshot = CodexSnapshot(
      composer: TextFieldState(text: "@Codex"),
      overlay: .fileMentions(
        FileMentionPicker(
          files: ["Sources/CodexTUI/CodexScreen.swift", "Tests/CodexTUITests.swift"],
          query: "Codex")),
      showHeader: false)
    assertWidget(CodexScreen(snapshot: snapshot), size: Size(width: 70, height: 10)) {
      """
      │                                                                      │
      │› @Codex                                                              │
      │                                                                      │
      │  Mention a file                                                      │
      │  Search: Codex                                                       │
      │                                                                      │
      │› 1. Sources/CodexTUI/CodexScreen.swift                               │
      │  2. Tests/CodexTUITests.swift                                        │
      │                                                                      │
      │  Press enter to mention or esc to go back                            │
      """
    }
  }

  @Test func rewindPickerExplainsThatTheExistingBranchIsPreserved() {
    let snapshot = CodexSnapshot(
      overlay: .rewind(
        RewindPicker(candidates: [
          RewindCandidate(id: 0, preview: "inspect the renderer"),
          RewindCandidate(id: 4, preview: "[1 image] match this Codex screen"),
        ])),
      showHeader: false)
    assertWidget(CodexScreen(snapshot: snapshot), size: Size(width: 76, height: 10)) {
      """
      │                                                                            │
      │                                                                            │
      │                                                                            │
      │  Branch from message                                                       │
      │  The existing path is preserved as another branch.                         │
      │                                                                            │
      │  inspect the renderer                                                      │
      │› [1 image] match this Codex screen                                         │
      │                                                                            │
      │  Press enter to branch or esc to cancel                                    │
      """
    }
  }

  @Test func sessionTreeUsesCodexBranchChromeAndMarksTheActiveLeaf() {
    let root = CodexSessionEntryID(rawValue: "root")
    let answer = CodexSessionEntryID(rawValue: "answer")
    let oldBranch = CodexSessionEntryID(rawValue: "old")
    let active = CodexSessionEntryID(rawValue: "active")
    let tree = CodexSessionTreeSnapshot(
      sessionID: "session",
      items: [
        CodexSessionTreeItem(
          id: root, parentID: nil, timestamp: 1, depth: 0, kind: .user,
          preview: "Design the session tree", isOnActiveBranch: true, hasChildren: true,
          label: "start"),
        CodexSessionTreeItem(
          id: answer, parentID: root, timestamp: 2, depth: 1, kind: .assistant,
          preview: "Let's keep every path", isOnActiveBranch: true, hasChildren: true,
          label: nil),
        CodexSessionTreeItem(
          id: oldBranch, parentID: answer, timestamp: 3, depth: 2, kind: .user,
          preview: "Try the discarded path", isOnActiveBranch: false, hasChildren: false,
          label: nil),
        CodexSessionTreeItem(
          id: active, parentID: answer, timestamp: 4, depth: 2, kind: .user,
          preview: "Keep the active path", isOnActiveBranch: true, hasChildren: false,
          label: nil),
      ], activeLeafID: active, selectedEditableEntryID: nil)
    let snapshot = CodexSnapshot(
      overlay: .sessionTree(SessionTreePicker(snapshot: tree, selectedID: active)),
      showHeader: false)

    assertWidget(CodexScreen(snapshot: snapshot), size: Size(width: 84, height: 14)) {
      """
      │                                                                                    │
      │                                                                                    │
      │                                                                                    │
      │                                                                                    │
      │  Session tree                                                                      │
      │  Search: Type to filter                                                            │
      │                                                                                    │
      │  ├ you: Design the session tree  [start]                                           │
      │  │ ├ codex: Let's keep every path                                                  │
      │  │ │ └ you: Try the discarded path                                                 │
      │› │ │ ● you: Keep the active path                                                   │
      │                                                                                    │
      │  ↑↓ navigate  enter branch/continue  type to filter  esc cancel                    │
      │                                                                                    │
      """
    }
  }

  @Test func agentPickerMatchesUpstreamWatchSurface() {
    let snapshot = CodexSnapshot(
      overlay: .agents(
        AgentPicker(threads: [
          AgentThreadSummary(
            id: "root", name: "Main", role: "main", status: "idle",
            description: "Primary conversation"),
          AgentThreadSummary(
            id: "child", name: "/root/worker", role: "worker", status: "running",
            description: "Inspect sources"),
        ])),
      showHeader: false)
    assertWidget(CodexScreen(snapshot: snapshot), size: Size(width: 80, height: 9)) {
      """
      │  Subagents                                                                     │
      │  Select an agent to watch. ⌥ + ← previous, ⌥ + → next.                         │
      │                                                                                │
      │› 1. • Main [default] (current)  root                                           │
      │  2. • /root/worker [worker]  child                                             │
      │                                                                                │
      │  Press enter to confirm or esc to go back                                      │
      │                                                                                │
      │                                                                                │
      """
    }
  }

  @Test func imageAttachmentRendersInsideCodexComposer() {
    let snapshot = CodexSnapshot(
      model: "gpt-5.6-sol", reasoningEffort: "medium", directory: "/tmp/project",
      composer: TextFieldState(text: "Explain this screenshot"),
      imageAttachments: [
        CodexImageAttachment(data: Data([1, 2, 3]), mimeType: "image/png", name: "shot.png")
      ], showHeader: false)
    assertWidget(CodexScreen(snapshot: snapshot), size: Size(width: 60, height: 10)) {
      """
      │                                                            │
      │                                                            │
      │                                                            │
      │                                                            │
      │                                                            │
      │  [Image #1] shot.png                                       │
      │                                                            │
      │› Explain this screenshot                                   │
      │                                                            │
      │  gpt-5.6-sol medium · /tmp/project                         │
      """
    }
  }

  @Test func selectedImageAttachmentHasAVisibleDeletionTargetAndHidesTextCursor() {
    let snapshot = CodexSnapshot(
      model: "gpt-5.6-sol", reasoningEffort: "medium", directory: "/tmp/project",
      composer: TextFieldState(text: "c"),
      imageAttachments: [
        CodexImageAttachment(data: Data([1, 2, 3]), mimeType: "image/png", name: "shot.png")
      ],
      selectedImageAttachmentIndex: 0, showHeader: false)
    let screen = CodexScreen(snapshot: snapshot)
    assertWidget(screen, size: Size(width: 60, height: 10)) {
      """
      │                                                            │
      │                                                            │
      │                                                            │
      │                                                            │
      │                                                            │
      │› [Image #1] shot.png                                       │
      │                                                            │
      │› c                                                         │
      │                                                            │
      │  gpt-5.6-sol medium · /tmp/project                         │
      """
    }
    let area = Rect(x: 0, y: 0, width: 60, height: 10)
    var frame = Frame(buffer: Buffer(area: area))
    frame.render(screen, in: area)
    #expect(frame.cursorPosition == nil)
  }

  @Test func initialConversationChrome() {
    let snapshot = CodexSnapshot(
      version: "0.1.0",
      model: "gpt-5.5",
      reasoningEffort: "high",
      directory: "/tmp/project"
    )
    assertWidget(CodexScreen(snapshot: snapshot), size: Size(width: 60, height: 12)) {
      """
      │╭──────────────────────────────────────────────╮            │
      ││ >_ OpenAI Codex (v0.1.0)                     │            │
      ││                                              │            │
      ││ model:       gpt-5.5 high   /model to change │            │
      ││ directory:   /tmp/project                    │            │
      ││ permissions: Ask for approval                │            │
      │╰──────────────────────────────────────────────╯            │
      │                                                            │
      │                                                            │
      │› Find and fix a bug in @filename                           │
      │                                                            │
      │  gpt-5.5 high · /tmp/project                               │
      """
    }
  }

  @Test func narrowHeaderTruncatesContentWithoutDroppingItsBorder() throws {
    let snapshot = CodexSnapshot(
      model: "gpt-5.6-sol", reasoningEffort: "medium",
      directory: "/Users/new/projects/learn_swift/codex-swift")
    var terminal = try Terminal(backend: TestBackend(width: 40, height: 12))
    let frame = try terminal.draw { $0.render(CodexScreen(snapshot: snapshot)) }

    #expect(frame.buffer[Position(x: 39, y: 3)].symbol == "│")
    #expect(frame.buffer[Position(x: 39, y: 4)].symbol == "│")
    #expect(
      (0..<40).map { frame.buffer[Position(x: Int($0), y: 4)].symbol }.joined().contains("…"))
  }

  @Test func slashPopupRendersBelowComposerWithUpstreamSelectionStyle() throws {
    let snapshot = CodexSnapshot(
      composer: TextFieldState(text: "/"), showHeader: false, slashCommandSelection: 1)
    var terminal = try Terminal(backend: TestBackend(width: 80, height: 14))
    let frame = try terminal.draw { $0.render(CodexScreen(snapshot: snapshot)) }
    let rows = (0..<14).map { y in
      (0..<80).map { x in
        frame.buffer[Position(x: x, y: y)].symbol
      }.joined()
    }
    let composerRow = try #require(rows.firstIndex { $0.contains("› /") })
    let selectedRow = try #require(rows.firstIndex { $0.contains("/thinking") })
    #expect(composerRow < selectedRow)
    let selectedCell = frame.buffer[Position(x: 2, y: selectedRow)]
    #expect(selectedCell.style.foreground == .cyan)
    #expect(selectedCell.style.modifiers.contains(.bold))
  }

  @Test func tallSlashPopupScrollsHeaderLikeUpstreamInlineHistory() throws {
    let snapshot = CodexSnapshot(
      directory: "/Users/new/projects/learn_swift/codex-swift",
      composer: TextFieldState(text: "/"))
    var terminal = try Terminal(backend: TestBackend(width: 48, height: 20))
    let frame = try terminal.draw { $0.render(CodexScreen(snapshot: snapshot)) }
    let rows = (0..<20).map { y in
      (0..<48).map { x in
        frame.buffer[Position(x: x, y: y)].symbol
      }.joined()
    }
    let headerBottom = try #require(rows.firstIndex { $0.contains("╰─") })
    let composerRow = try #require(rows.firstIndex { $0.contains("› /") })
    #expect(headerBottom < composerRow)
    #expect(!rows.contains { $0.contains(">_ OpenAI Codex") })
    #expect(rows.contains { $0.contains("/model") })
  }

  @Test func markdownTablesUseAlignedCodexRowsWhenTheyFit() {
    let snapshot = CodexSnapshot(
      model: "gpt-5.6-sol", reasoningEffort: "medium", directory: "/tmp/project",
      entries: [
        TranscriptEntry(
          content: .assistant(
            """
            | Layer | Owner |
            | --- | --- |
            | Agent runtime | KWWK |
            | Terminal UI | TermLoom Swift |
            """, streaming: false))
      ], showHeader: false)
    assertWidget(CodexScreen(snapshot: snapshot), size: Size(width: 50, height: 10)) {
      """
      │• Layer          Owner                            │
      │  ─────────────  ──────────────                   │
      │  Agent runtime  KWWK                             │
      │  Terminal UI    TermLoom Swift                   │
      │                                                  │
      │                                                  │
      │                                                  │
      │› Find and fix a bug in @filename                 │
      │                                                  │
      │  gpt-5.6-sol medium · /tmp/project               │
      """
    }
  }

  @Test func markdownTablesBecomeRecordsAtNarrowWidths() {
    let snapshot = CodexSnapshot(
      model: "gpt-5.6-sol", reasoningEffort: "medium", directory: "/tmp/project",
      entries: [
        TranscriptEntry(
          content: .assistant(
            """
            | Layer | Owner |
            | --- | --- |
            | Agent runtime | KWWK |
            | Terminal UI | TermLoom Swift |
            """, streaming: false))
      ], showHeader: false)
    assertWidget(CodexScreen(snapshot: snapshot), size: Size(width: 24, height: 12)) {
      """
      │• Layer: Agent runtime  │
      │  Owner: KWWK           │
      │                        │
      │  Layer: Terminal UI    │
      │  Owner: TermLoom Swift │
      │                        │
      │                        │
      │                        │
      │                        │
      │› Find and fix a bug in │
      │                        │
      │  gpt-5.6-sol medium · /│
      """
    }
  }

  @Test func activeConversationShowsToolsQueueAndStatus() {
    let snapshot = CodexSnapshot(
      version: "0.1.0",
      model: "gpt-5.5",
      reasoningEffort: "high",
      directory: "/tmp/project",
      entries: [
        TranscriptEntry(content: .user("Find the renderer and explain it.")),
        TranscriptEntry(
          content: .reasoning(
            summary: "Inspecting the workspace", body: nil, streaming: false)),
        TranscriptEntry(
          content: .tool(
            ToolActivity(
              callID: "1", name: "Searched", detail: "Sources",
              output: ["Found 12 Swift files"], status: .succeeded,
              durationMilliseconds: 840))),
        TranscriptEntry(
          content: .assistant(
            "The renderer uses a retained buffer and emits only changed cells.", streaming: true)),
      ],
      isWorking: true,
      elapsedSeconds: 3,
      queuedMessages: ["Also add a regression test"],
      contextRemainingPercent: 96,
      rightStatus: "Goal achieved (4h 25m)",
      showHeader: false
    )
    assertWidget(CodexScreen(snapshot: snapshot), size: Size(width: 64, height: 16)) {
      """
      │• Inspecting the workspace                                      │
      │                                                                │
      │• Searched Sources (840ms)                                      │
      │  └ Found 12 Swift files                                        │
      │                                                                │
      │• The renderer uses a retained buffer and emits only changed    │
      │  cells.                                                        │
      │• Working (3s • esc to interrupt • ctrl-t transcript)           │
      │                                                                │
      │• Queued follow-up inputs                                       │
      │  ↳ Also add a regression test                                  │
      │    ⌥ + ↑ edit last queued message                              │
      │                                                                │
      │› Find and fix a bug in @filename                               │
      │                                                                │
      │  gpt-5.5 high · /tmp/project           Goal achieved (4h 25m)  │
      """
    }
  }

  @Test func approvalWorkflow() {
    let snapshot = CodexSnapshot(
      model: "gpt-5.6-sol",
      reasoningEffort: "medium",
      directory: "/tmp/project",
      overlay: .approval(
        ApprovalRequest(
          title: "Would you like to run this command?",
          reason: "The command writes outside the workspace.",
          command: "git push origin main",
          choices: [
            ApprovalChoice("Yes, run it", shortcut: "y"),
            ApprovalChoice("Yes, and don't ask again", shortcut: "a"),
            ApprovalChoice("No, and tell Codex what to do differently", shortcut: "n"),
          ],
          selectedIndex: 1
        ))
    )
    assertWidget(CodexScreen(snapshot: snapshot), size: Size(width: 68, height: 19)) {
      """
      │╭────────────────────────────────────────────────────╮              │
      ││ >_ OpenAI Codex (v0.1.0)                           │              │
      ││                                                    │              │
      ││ model:       gpt-5.6-sol medium   /model to change │              │
      ││ directory:   /tmp/project                          │              │
      ││ permissions: Ask for approval                      │              │
      │╰────────────────────────────────────────────────────╯              │
      │                                                                    │
      │  Would you like to run this command?                               │
      │                                                                    │
      │  Reason: The command writes outside the workspace.                 │
      │                                                                    │
      │  $ git push origin main                                            │
      │                                                                    │
      │  1. Yes, run it (y)                                                │
      │› 2. Yes, and don't ask again (a)                                   │
      │  3. No, and tell Codex what to do differently (n)                  │
      │                                                                    │
      │  Press enter to confirm or esc to cancel                           │
      """
    }
  }

  @Test func requestUserInputOptionsMatchCodexBottomPane() {
    let snapshot = CodexSnapshot(
      overlay: .requestUserInput(
        RequestUserInputRequest(
          id: "request-1",
          questions: [
            RequestUserInputQuestion(
              id: "area",
              header: "Area",
              question: "Choose an option.",
              options: [
                RequestUserInputOption(label: "Option 1", description: "First choice."),
                RequestUserInputOption(label: "Option 2", description: "Second choice."),
                RequestUserInputOption(label: "Option 3", description: "Third choice."),
              ])
          ])),
      showHeader: false)

    assertWidget(CodexScreen(snapshot: snapshot), size: Size(width: 80, height: 10)) {
      """
      │                                                                                │
      │  Question 1/1 (1 unanswered)                                                   │
      │  Choose an option.                                                             │
      │                                                                                │
      │  › 1. Option 1  First choice.                                                  │
      │    2. Option 2  Second choice.                                                 │
      │    3. Option 3  Third choice.                                                  │
      │                                                                                │
      │  tab to add notes | enter to submit all | esc to interrupt                     │
      │                                                                                │
      """
    }
  }

  @Test func editableReplacementOverlaysExposeHardwareCaretGeometry() {
    var request = RequestUserInputRequest(
      id: "request-1",
      questions: [
        RequestUserInputQuestion(id: "answer", header: "Answer", question: "Explain.")
      ])
    request.answers[0].draft = TextFieldState(text: "界ab", cursor: 1)
    let requestScreen = CodexScreen(
      snapshot: CodexSnapshot(overlay: .requestUserInput(request), showHeader: false))
    let requestArea = Rect(x: 0, y: 0, width: 20, height: 10)
    var requestFrame = Frame(buffer: Buffer(area: requestArea))
    requestFrame.render(requestScreen, in: requestArea)
    #expect(requestFrame.cursorPosition == Position(x: 6, y: 4))
    #expect(requestFrame.cursorStyle == .steadyBar)

    let renameScreen = CodexScreen(
      snapshot: CodexSnapshot(
        overlay: .rename(RenameThreadPrompt(name: "界ab")), showHeader: false))
    let renameArea = Rect(x: 0, y: 0, width: 20, height: 6)
    var renameFrame = Frame(buffer: Buffer(area: renameArea))
    renameFrame.render(renameScreen, in: renameArea)
    #expect(renameFrame.cursorPosition == Position(x: 6, y: 2))
    #expect(renameFrame.cursorStyle == .steadyBar)
  }

  @Test func modelPickerShowsProviderTagsAndSearchQuery() {
    let models = [
      CodexModelOption(
        id: "openai::gpt", modelID: "gpt", name: "GPT", provider: "openai",
        contextWindow: 100_000, supportsReasoning: true),
      CodexModelOption(
        id: "anthropic::claude", modelID: "claude-sonnet", name: "Claude Sonnet",
        provider: "anthropic", contextWindow: 200_000, supportsReasoning: true),
    ]
    let snapshot = CodexSnapshot(
      model: "claude-sonnet", modelProvider: "anthropic",
      overlay: .models(ModelPicker(models: models, query: "anthropic")), showHeader: false)
    assertWidget(CodexScreen(snapshot: snapshot), size: Size(width: 82, height: 10)) {
      """
      │                                                                                  │
      │                                                                                  │
      │                                                                                  │
      │  Select Model and Effort                                                         │
      │  Models from pi/KWWK catalogs for authenticated providers                        │
      │  Search: anthropic                                                               │
      │                                                                                  │
      │› 1. claude-sonnet (current)  Claude Sonnet  [anthropic]                          │
      │                                                                                  │
      │  Press enter to confirm or esc to go back                                        │
      """
    }
  }

  @Test func sessionPickerColumnsStayAlignedForWideDirectories() throws {
    let now = Int64(Date().timeIntervalSince1970 * 1_000)
    let sessions = [
      CodexSessionSummary(
        id: "ascii", title: "ASCII title", directory: "/tmp/abcdefghijklmnopqrstu",
        createdAt: now, updatedAt: now, messageCount: 1),
      CodexSessionSummary(
        id: "wide", title: "Wide title", directory: "/tmp/界界界界界界界界界界",
        createdAt: now, updatedAt: now, messageCount: 1),
    ]
    let screen = CodexScreen(
      snapshot: CodexSnapshot(
        overlay: .sessions(SessionPicker(action: .resume, sessions: sessions)),
        showHeader: false))
    let area = Rect(x: 0, y: 0, width: 100, height: 16)
    var frame = Frame(buffer: Buffer(area: area))

    frame.render(screen, in: area)

    func position(of value: String) -> Position? {
      let symbols = value.map(String.init)
      guard !symbols.isEmpty else { return nil }
      for y in area.y..<area.bottom {
        for x in area.x...(area.right - symbols.count) {
          guard
            symbols.indices.allSatisfy({ offset in
              frame.buffer[Position(x: x + offset, y: y)].symbol == symbols[offset]
            })
          else { continue }
          return Position(x: x, y: y)
        }
      }
      return nil
    }

    let ascii = try #require(position(of: "ASCII title"))
    let wide = try #require(position(of: "Wide title"))
    #expect(ascii.x == wide.x)
  }

  @Test func reasoningPickerMatchesCodexSelectionSurface() {
    let options = [
      CodexReasoningOption(
        id: "low", label: "Low", description: "Fast responses with lighter reasoning"),
      CodexReasoningOption(
        id: "medium", label: "Medium",
        description: "Balances speed and reasoning depth for everyday tasks", isDefault: true),
      CodexReasoningOption(
        id: "high", label: "High", description: "Greater reasoning depth for complex problems"),
      CodexReasoningOption(
        id: "xhigh", label: "Extra high",
        description: "Extra high reasoning depth for complex problems"),
      CodexReasoningOption(
        id: "max", label: "Max",
        description: "For difficult problems when quality matters more than speed · higher usage"),
    ]
    let snapshot = CodexSnapshot(
      model: "gpt-5.6-sol", reasoningEffort: "high",
      overlay: .reasoning(
        ReasoningPicker(
          modelID: "openai::gpt-5.6-sol", modelName: "gpt-5.6-sol",
          options: options, selectedIndex: 2)),
      showHeader: false)

    assertWidget(CodexScreen(snapshot: snapshot), size: Size(width: 80, height: 12)) {
      """
      │                                                                                │
      │                                                                                │
      │  Select Reasoning Level for gpt-5.6-sol                                        │
      │                                                                                │
      │  1. Low               Fast responses with lighter reasoning                    │
      │  2. Medium (default)  Balances speed and reasoning depth for everyday tasks    │
      │› 3. High (current)    Greater reasoning depth for complex problems             │
      │  4. Extra high        Extra high reasoning depth for complex problems          │
      │  5. Max               For difficult problems when quality matters more than    │
      │                       speed · higher usage                                     │
      │                                                                                │
      │  Press enter to confirm or esc to go back                                      │
      """
    }
  }

  @Test func maxReasoningIgnitionAssemblesFooterAndAccentsPrompt() {
    let snapshot = CodexSnapshot(reasoningEffort: "max", showHeader: false)
    let animation = CodexEffortAnimationFrame(
      tier: .max, style: .wave, elapsedMilliseconds: 1_320,
      previousReasoningEffort: "high")
    let area = Rect(x: 0, y: 0, width: 60, height: 9)
    var frame = Frame(buffer: Buffer(area: area))

    frame.render(CodexScreen(snapshot: snapshot, effortAnimation: animation), in: area)

    guard let composerRow = frame.buffer.lines().firstIndex(where: { $0.contains("Find and fix") })
    else {
      Issue.record("Expected composer row")
      return
    }
    #expect(frame.buffer[Position(x: 0, y: composerRow)].symbol == "›")
    #expect(frame.buffer[Position(x: 0, y: composerRow)].style.foreground == .rgb(255, 178, 66))
    #expect(frame.buffer.lines().contains(where: { $0.contains("M A X") }))
  }

  @Test func permissionsPickerMatchesCodexSelectionSurface() {
    let snapshot = CodexSnapshot(
      permissionMode: .askForApproval,
      overlay: .permissions(PermissionPicker(selectedIndex: 0)),
      showHeader: false)

    assertWidget(CodexScreen(snapshot: snapshot), size: Size(width: 80, height: 12)) {
      """
      │  Update Model Permissions                                                      │
      │                                                                                │
      │› 1. Ask for approval (current)  Codex can read and edit files in the current   │
      │                                 workspace, and run commands. Approval is       │
      │                                 required to access the internet or edit other  │
      │                                 files.                                         │
      │  2. Full Access                 Codex can edit files outside this workspace    │
      │                                 and access the internet without asking for     │
      │                                 approval. Exercise caution when using.         │
      │                                                                                │
      │  Press enter to confirm or esc to go back                                      │
      │                                                                                │
      """
    }
  }

  @Test func personalityPickerMatchesCodexSelectionSurface() {
    let snapshot = CodexSnapshot(
      personality: .pragmatic,
      overlay: .personality(PersonalityPicker(selectedIndex: 1)),
      showHeader: false)

    assertWidget(CodexScreen(snapshot: snapshot), size: Size(width: 80, height: 8)) {
      """
      │  Select Personality                                                            │
      │  Choose a communication style for Codex.                                       │
      │                                                                                │
      │  1. Friendly             Warm, collaborative, and helpful.                     │
      │› 2. Pragmatic (current)  Concise, task-focused, and direct.                    │
      │                                                                                │
      │  Press enter to confirm or esc to go back                                      │
      │                                                                                │
      """
    }
  }

  @Test func conversationReflowsAtNarrowTerminalWidth() {
    let snapshot = CodexSnapshot(
      model: "gpt-5.6-sol",
      reasoningEffort: "medium",
      directory: "/tmp/project",
      entries: [
        TranscriptEntry(content: .user("Explain whether inline terminal resizing is safe.")),
        TranscriptEntry(
          content: .assistant(
            "The retained buffer is rebuilt at the new width and the transcript reflows.",
            streaming: false)),
      ],
      showHeader: false
    )
    assertWidget(CodexScreen(snapshot: snapshot), size: Size(width: 38, height: 10)) {
      """
      │› Explain whether inline terminal     │
      │  resizing is safe.                   │
      │                                      │
      │• The retained buffer is rebuilt at   │
      │  the new width and the transcript    │
      │  reflows.                            │
      │                                      │
      │› Find and fix a bug in @filename     │
      │                                      │
      │  gpt-5.6-sol medium · /tmp/project   │
      """
    }
  }

  @Test func workingQueueAndGoalMatchModernCodexChrome() {
    let snapshot = CodexSnapshot(
      model: "gpt-5.6-sol",
      reasoningEffort: "medium",
      directory: "~/projects/learn_swift/termloom",
      isWorking: true,
      elapsedSeconds: 353,
      queuedMessages: [
        "[Image #1]\nand codex is very fucking cool when it comes to rendering so we want those as well"
      ],
      rightStatus: "Goal achieved (4h 25m)",
      showHeader: false
    )
    assertWidget(CodexScreen(snapshot: snapshot), size: Size(width: 120, height: 14)) {
      """
      │                                                                                                                        │
      │                                                                                                                        │
      │                                                                                                                        │
      │                                                                                                                        │
      │• Working (5m 53s • esc to interrupt • ctrl-t transcript)                                                               │
      │                                                                                                                        │
      │• Queued follow-up inputs                                                                                               │
      │  ↳ [Image #1]                                                                                                          │
      │    and codex is very fucking cool when it comes to rendering so we want those as well                                  │
      │    ⌥ + ↑ edit last queued message                                                                                      │
      │                                                                                                                        │
      │› Find and fix a bug in @filename                                                                                       │
      │                                                                                                                        │
      │  gpt-5.6-sol medium · ~/projects/learn_swift/termloom                                          Goal achieved (4h 25m)  │
      """
    }
  }

  @Test func semanticToolHistoryMatchesCodexCells() {
    let snapshot = CodexSnapshot(
      model: "gpt-5.6-sol",
      reasoningEffort: "medium",
      directory: "~/projects/learn_swift/codex-swift",
      entries: [
        TranscriptEntry(
          content: .tool(
            ToolActivity(
              callID: "run-1", name: "Ran", status: .succeeded,
              presentation: .command(
                command:
                  "find -L \"$HOME/.pi/agent\" -maxdepth 2 -type f | sort && jq '{defaultProvider, defaultModel}' settings.json",
                output: (1...10).map { "output \($0)" },
                omittedLineCount: 0)))),
        TranscriptEntry(
          content: .tool(
            ToolActivity(
              callID: "search-1", name: "Searched", status: .succeeded,
              presentation: .exploration(
                ExplorationAction(
                  kind: .search, subject: "thinkingLevel",
                  path: "CodingAgentBuilder.swift"))))),
        TranscriptEntry(
          content: .tool(
            ToolActivity(
              callID: "read-1", name: "Read", status: .succeeded,
              presentation: .exploration(
                ExplorationAction(kind: .read, subject: "CodingAgentBuilder.swift"))))),
        TranscriptEntry(
          content: .tool(
            ToolActivity(
              callID: "edit-1", name: "Edited", status: .succeeded,
              presentation: .edit(
                path:
                  "/Users/new/projects/learn_swift/codex-swift/Sources/CodexTUI/CodexRuntime.swift",
                additions: 5,
                deletions: 2,
                lines: [
                  DiffLine(
                    lineNumber: 32, kind: .context,
                    text: "requestedProvider: environment[\"CODEX_SWIFT_PROVIDER\"],"),
                  DiffLine(
                    lineNumber: 33, kind: .deletion,
                    text: "requestedModel: environment[\"CODEX_SWIFT_MODEL\"]"),
                  DiffLine(
                    lineNumber: 33, kind: .addition,
                    text:
                      "requestedModel: environment[\"CODEX_SWIFT_MODEL\"] ?? piCodex?.preferredModel"
                  ),
                  DiffLine(
                    lineNumber: 34, kind: .addition, text: "let thinkingLevel = ThinkingLevel("),
                  DiffLine(
                    lineNumber: 35, kind: .addition,
                    text: "  rawValue: piCodex?.thinkingLevel ?? \"high\""),
                  DiffLine(lineNumber: 36, kind: .addition, text: ") ?? .high"),
                  DiffLine(lineNumber: nil, kind: .separator, text: "⋮"),
                  DiffLine(lineNumber: 50, kind: .deletion, text: "reasoningEffort: \"high\","),
                  DiffLine(
                    lineNumber: 54, kind: .addition,
                    text: "reasoningEffort: thinkingLevel.rawValue,"),
                ])))),
      ],
      showHeader: false
    )
    let buffer = assertWidget(
      CodexScreen(snapshot: snapshot), size: Size(width: 120, height: 27)
    ) {
      """
      │• Ran find -L "$HOME/.pi/agent" -maxdepth 2 -type f | sort && jq '{defaultProvider, defaultModel}' settings.json        │
      │  └ output 1                                                                                                            │
      │    output 2                                                                                                            │
      │    … +6 lines (ctrl + t to view transcript)                                                                            │
      │    output 9                                                                                                            │
      │    output 10                                                                                                           │
      │                                                                                                                        │
      │• Explored                                                                                                              │
      │  └ Search thinkingLevel in CodingAgentBuilder.swift                                                                    │
      │    Read CodingAgentBuilder.swift                                                                                       │
      │                                                                                                                        │
      │• Edited ~/projects/learn_swift/codex-swift/Sources/CodexTUI/CodexRuntime.swift (+5 -2)                                 │
      │    32  requestedProvider: environment["CODEX_SWIFT_PROVIDER"],                                                         │
      │    33 -requestedModel: environment["CODEX_SWIFT_MODEL"]                                                                │
      │    33 +requestedModel: environment["CODEX_SWIFT_MODEL"] ?? piCodex?.preferredModel                                     │
      │    34 +let thinkingLevel = ThinkingLevel(                                                                              │
      │    35 +  rawValue: piCodex?.thinkingLevel ?? "high"                                                                    │
      │    36 +) ?? .high                                                                                                      │
      │    ⋮                                                                                                                   │
      │    50 -reasoningEffort: "high",                                                                                        │
      │    54 +reasoningEffort: thinkingLevel.rawValue,                                                                        │
      │                                                                                                                        │
      │                                                                                                                        │
      │                                                                                                                        │
      │› Find and fix a bug in @filename                                                                                       │
      │                                                                                                                        │
      │  gpt-5.6-sol medium · ~/projects/learn_swift/codex-swift                                                               │
      """
    }

    #expect(buffer[Position(x: 8, y: 13)].style.background == .rgb(74, 34, 29))
    #expect(buffer[Position(x: 8, y: 14)].style.background == .rgb(33, 58, 43))
  }

  // Ported from Codex's single-line command continuation snapshot.
  @Test func commandWrappingMatchesCodexExecCellSnapshot() {
    let snapshot = CodexSnapshot(
      model: "m",
      reasoningEffort: "high",
      directory: "/p",
      entries: [
        TranscriptEntry(
          content: .tool(
            ToolActivity(
              callID: "wrap", name: "Ran", status: .succeeded,
              presentation: .command(
                command: "a_very_long_token_without_spaces_to_force_wrapping",
                output: [],
                omittedLineCount: 0))))
      ],
      showHeader: false
    )
    assertWidget(CodexScreen(snapshot: snapshot), size: Size(width: 24, height: 9)) {
      """
      │• Ran a_very_long_token_│
      │  │ without_spaces_to_  │
      │  │ force_wrapping      │
      │  └ (no output)         │
      │                        │
      │                        │
      │› Find and fix a bug in │
      │                        │
      │  m high · /p           │
      """
    }
  }

  // Ported from Codex's coalesced-read history snapshot.
  @Test func explorationGroupingMatchesCodexExecCellSnapshot() {
    let snapshot = CodexSnapshot(
      model: "m",
      reasoningEffort: "high",
      directory: "/p",
      entries: [
        TranscriptEntry(
          content: .tool(
            ToolActivity(
              callID: "search", name: "Search", status: .succeeded,
              presentation: .exploration(
                ExplorationAction(kind: .search, subject: "shimmer_spans"))))),
        TranscriptEntry(
          content: .tool(
            ToolActivity(
              callID: "read-1", name: "Read", status: .succeeded,
              presentation: .exploration(
                ExplorationAction(kind: .read, subject: "shimmer.rs"))))),
        TranscriptEntry(
          content: .tool(
            ToolActivity(
              callID: "read-2", name: "Read", status: .succeeded,
              presentation: .exploration(
                ExplorationAction(kind: .read, subject: "status_indicator_widget.rs"))))),
      ],
      showHeader: false
    )
    assertWidget(CodexScreen(snapshot: snapshot), size: Size(width: 58, height: 9)) {
      """
      │• Explored                                                │
      │  └ Search shimmer_spans                                  │
      │    Read shimmer.rs, status_indicator_widget.rs           │
      │                                                          │
      │                                                          │
      │                                                          │
      │› Find and fix a bug in @filename                         │
      │                                                          │
      │  m high · /p                                             │
      """
    }
  }

  @Test func messageCellsFollowCodexPaddingMarkdownAndReasoningStyles() {
    let snapshot = CodexSnapshot(
      model: "gpt-5.6-sol",
      reasoningEffort: "medium",
      directory: "/tmp/project",
      entries: [
        TranscriptEntry(content: .user("Please inspect **Codex**.\u{1B}[13;2:3u")),
        TranscriptEntry(
          content: .assistant(
            "The renderer keeps **bold text** and [links](https://example.com).",
            streaming: false)),
        TranscriptEntry(
          content: .reasoning(
            summary: "Plan",
            body: "Compare the upstream **history cells**.",
            streaming: false)),
      ],
      showHeader: false
    )
    let buffer = assertWidget(
      CodexScreen(snapshot: snapshot), size: Size(width: 64, height: 14)
    ) {
      """
      │                                                                │
      │› Please inspect **Codex**.                                     │
      │                                                                │
      │• The renderer keeps bold text and links.                       │
      │                                                                │
      │• Compare the upstream history cells.                           │
      │                                                                │
      │                                                                │
      │                                                                │
      │                                                                │
      │                                                                │
      │› Find and fix a bug in @filename                               │
      │                                                                │
      │  gpt-5.6-sol medium · /tmp/project                             │
      """
    }

    #expect(buffer[Position(x: 0, y: 0)].style.background == .rgb(63, 67, 74))
    #expect(buffer[Position(x: 0, y: 1)].style.background == .rgb(63, 67, 74))
    #expect(buffer[Position(x: 0, y: 2)].style.background == .rgb(63, 67, 74))
    #expect(buffer[Position(x: 62, y: 0)].style.background == .rgb(63, 67, 74))
    #expect(buffer[Position(x: 62, y: 1)].style.background == .rgb(63, 67, 74))
    #expect(buffer[Position(x: 62, y: 2)].style.background == .rgb(63, 67, 74))
    #expect(buffer[Position(x: 63, y: 0)].style.background == nil)
    #expect(buffer[Position(x: 63, y: 1)].style.background == nil)
    #expect(buffer[Position(x: 63, y: 2)].style.background == nil)
    #expect(buffer[Position(x: 21, y: 3)].style.modifiers.contains(.bold))
    #expect(buffer[Position(x: 35, y: 3)].style.foreground == .cyan)
    #expect(buffer[Position(x: 35, y: 3)].style.modifiers.contains(.underlined))
    #expect(buffer[Position(x: 2, y: 5)].style.modifiers.contains([.dim, .italic]))
    #expect(buffer[Position(x: 23, y: 5)].style.modifiers.contains(.bold))
  }

  @Test func transcriptPagerShowsTheLiveStreamingTailAndPagerChrome() {
    let snapshot = CodexSnapshot(
      entries: [
        TranscriptEntry(content: .user("Can you inspect this?")),
        TranscriptEntry(content: .assistant("I am **streaming** the answer.", streaming: true)),
      ], overlay: .transcript(CodexTranscriptPager()), showHeader: false)

    assertWidget(CodexScreen(snapshot: snapshot), size: Size(width: 76, height: 10)) {
      """
      │ T R A N S C R I P T                                                        │
      │                                                                            │
      │› Can you inspect this?                                                     │
      │                                                                            │
      │• I am streaming the answer.                                                │
      │                                                                            │
      │                                                                            │
      │                                                                            │
      │                                                                            │
      │─ ↑/↓ scroll  pgup/dn page  home/end  esc close  100%                       │
      """
    }
  }

  @Test func keymapPickerShowsBindingsSearchAndCustomizationMarkers() throws {
    var configuration = CodexKeymapConfiguration()
    configuration[.submit] = [CodexKeyBinding(.character("x"), modifiers: [.control])]
    configuration[.historySearchNext] = []
    let snapshot = CodexSnapshot(
      overlay: .keymap(CodexKeymapPicker(configuration: configuration)), showHeader: false)

    assertWidget(CodexScreen(snapshot: snapshot), size: Size(width: 76, height: 16)) {
      """
      │  Keymap                                                                    │
      │  [All]  Common  Customized (2)  Unbound (2)  App  Composer  Debug          │
      │  Search: Type to search shortcuts                                          │
      │                                                                            │
      │›  App       Open transcript  ctrl-t                                        │
      │   App       Open external editor  ctrl-g                                   │
      │   App       Copy last response  ctrl-o                                     │
      │   App       Clear terminal  ctrl-l                                         │
      │ - App       Toggle Vim mode  unbound                                       │
      │   App       Toggle raw output  alt-r                                       │
      │   Chat      Interrupt turn  esc                                            │
      │   Chat      Edit queued message  alt-up, shift-left                        │
      │ * Composer  Submit message  ctrl-x                                         │
      │   Composer  Queue follow-up  tab                                           │
      │                                                                            │
      │  ←/→ group  ↑/↓ navigate  enter select  * custom  - unbound  esc close     │
      """
    }
  }

  @Test func keymapDebugShowsDetectedKeyRawEventAndAssignedSource() throws {
    var configuration = CodexKeymapConfiguration()
    configuration[.submit] = [CodexKeyBinding(.character("x"), modifiers: [.option])]
    var debug = CodexKeymapDebug(runtime: try CodexRuntimeKeymap(configuration: configuration))
    debug.inspect(KeyEvent(.character("x"), modifiers: [.option]))
    let snapshot = CodexSnapshot(overlay: .keymapDebug(debug), showHeader: false)

    assertWidget(CodexScreen(snapshot: snapshot), size: Size(width: 100, height: 12)) {
      """
      │  Keypress Inspector                                                                                │
      │  Press any key to see what Codex receives. Esc is inspected; Ctrl+C closes.                        │
      │  Tip: Codex can only inspect keys your terminal sends.                                             │
      │                                                                                                    │
      │  Detected: alt-x                                                                                   │
      │  Config key: alt-x                                                                                 │
      │  Raw event: code=x, modifiers=alt, kind=press                                                      │
      │                                                                                                    │
      │  Assigned actions:                                                                                 │
      │    - composer.submit (Submit message) - Send the composer text [Custom]                            │
      │                                                                                                    │
      │                                                                                                    │
      """
    }
  }

  @Test func keymapActionMenuExplainsEffectiveSourceAndConfigPath() {
    let snapshot = CodexSnapshot(
      overlay: .keymapAction(
        CodexKeymapActionMenu(action: .submit, configuration: .init())), showHeader: false)

    assertWidget(CodexScreen(snapshot: snapshot), size: Size(width: 76, height: 14)) {
      """
      │  Edit Shortcut                                                             │
      │                                                                            │
      │  Submit message                                                            │
      │  Context: Composer                                                         │
      │  Current: enter                                                            │
      │  Source: Default keymap                                                    │
      │  tui.keymap.composer.submit                                                │
      │                                                                            │
      │› Replace all bindings                                                      │
      │  Add alternate binding                                                     │
      │  Back to shortcuts                                                         │
      │                                                                            │
      │  Changes write root tui.keymap.* overrides                                 │
      │                                                                            │
      """
    }
  }

  @Test func keymapCaptureIsExplicitlySingleKeyAndCancelable() {
    let snapshot = CodexSnapshot(
      overlay: .keymapCapture(
        CodexKeymapCapture(
          action: .submit, operation: .replaceAll, configuration: .init())),
      showHeader: false)

    assertWidget(CodexScreen(snapshot: snapshot), size: Size(width: 76, height: 8)) {
      """
      │  Set Shortcut                                                              │
      │                                                                            │
      │  Submit message                                                            │
      │  Press the new key binding.                                                │
      │  One terminal key event is captured; chords are not supported.             │
      │                                                                            │
      │  esc cancel                                                                │
      │                                                                            │
      """
    }
  }

  // Ported from Codex's status_widget_active snapshot.
  @Test func activeStatusAndComposerGeometryMatchCodexSnapshot() {
    let snapshot = CodexSnapshot(
      model: "gpt-5.6-sol",
      reasoningEffort: "default",
      directory: "/tmp/project",
      isWorking: true,
      workingLabel: "Analyzing",
      elapsedSeconds: 0,
      showHeader: false
    )
    let buffer = assertWidget(CodexScreen(snapshot: snapshot), size: Size(width: 80, height: 7)) {
      """
      │                                                                                │
      │                                                                                │
      │• Analyzing (0s • esc to interrupt • ctrl-t transcript)                         │
      │                                                                                │
      │› Find and fix a bug in @filename                                               │
      │                                                                                │
      │  gpt-5.6-sol default · /tmp/project                                            │
      """
    }
    #expect(buffer[Position(x: 0, y: 2)].style.background == nil)
    #expect(buffer[Position(x: 0, y: 4)].style.background == .rgb(63, 67, 74))
    #expect(buffer[Position(x: 0, y: 5)].style.background == .rgb(63, 67, 74))
    #expect(buffer[Position(x: 0, y: 6)].style.background == nil)
  }
}
