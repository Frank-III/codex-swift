public struct CodexSlashCommand: Hashable, Sendable {
  public var name: String
  public var description: String
  public var availableDuringTask: Bool

  public init(_ name: String, _ description: String, availableDuringTask: Bool = true) {
    self.name = name
    self.description = description
    self.availableDuringTask = availableDuringTask
  }

  public static let builtins: [Self] = [
    Self("model", "choose what model and reasoning effort to use"),
    Self("thinking", "show or set KWWK reasoning and thinking display"),
    Self("verbose", "toggle KWWK provider diagnostics"),
    Self("context", "show context-window usage"),
    Self("queue", "show or clear queued steering messages"),
    Self("tools", "list tools available to the KWWK agent"),
    Self("init", "explore the repository and create AGENTS.md", availableDuringTask: false),
    Self("hotkeys", "show keyboard shortcuts"),
    Self("help", "list available slash commands"),
    Self("permissions", "choose what Codex is allowed to do"),
    Self("keymap", "remap TUI shortcuts", availableDuringTask: false),
    Self("vim", "toggle Vim mode for the composer", availableDuringTask: false),
    Self("personality", "choose how Codex communicates"),
    Self("review", "review my current changes and find issues", availableDuringTask: false),
    Self("rename", "rename the current thread"),
    Self("archive", "archive the current thread and exit", availableDuringTask: false),
    Self("delete", "permanently delete the current thread", availableDuringTask: false),
    Self("new", "start a new chat during a conversation", availableDuringTask: false),
    Self("resume", "resume a saved chat"),
    Self("fork", "fork the current chat", availableDuringTask: false),
    Self("compact", "summarize conversation to preserve context", availableDuringTask: false),
    Self("retry", "resubmit the last failed or interrupted prompt", availableDuringTask: false),
    Self("rewind", "rewind the conversation to a prior message", availableDuringTask: false),
    Self("plan", "switch to Plan mode", availableDuringTask: false),
    Self("goal", "set or view the goal for a long-running task"),
    Self("agent", "switch the active agent thread"),
    Self("side", "start an ephemeral side conversation"),
    Self("btw", "start a side conversation in an ephemeral fork"),
    Self("copy", "copy last response as markdown"),
    Self("raw", "toggle raw scrollback mode for copy-friendly terminal selection"),
    Self("diff", "show git diff including untracked files"),
    Self("mention", "mention a file"),
    Self("status", "show session configuration and token usage"),
    Self("usage", "view account usage"),
    Self("theme", "choose a syntax highlighting theme", availableDuringTask: false),
    Self("skills", "browse and mention skills"),
    Self("ps", "list background terminals"),
    Self("stop", "stop all background terminals"),
    Self("clear", "clear the terminal and start a new chat", availableDuringTask: false),
    Self("quit", "exit Codex"),
  ]

  public static func suggestions(
    for input: String, isWorking: Bool, mode: CodexMode = .defaultMode
  ) -> [Self] {
    guard input.hasPrefix("/") else { return [] }
    let query = input.dropFirst().lowercased()
    return builtins.filter {
      (query.isEmpty || $0.name.hasPrefix(query)) && (!isWorking || $0.availableDuringTask)
        && (mode != .side
          || ["copy", "raw", "diff", "mention", "status", "usage"].contains($0.name))
    }
  }
}
