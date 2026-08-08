import Foundation
import TermLoom

public enum CodexKeymapContext: String, CaseIterable, Codable, Hashable, Sendable {
  case global
  case chat
  case composer

  public var label: String {
    switch self {
    case .global: "App"
    case .chat: "Chat"
    case .composer: "Composer"
    }
  }
}

public enum CodexKeymapAction: String, CaseIterable, Codable, Hashable, Sendable {
  case openTranscript = "open_transcript"
  case openExternalEditor = "open_external_editor"
  case copy
  case clearTerminal = "clear_terminal"
  case toggleVimMode = "toggle_vim_mode"
  case toggleRawOutput = "toggle_raw_output"
  case interruptTurn = "interrupt_turn"
  case editQueuedMessage = "edit_queued_message"
  case submit
  case queue
  case toggleShortcuts = "toggle_shortcuts"
  case historySearchPrevious = "history_search_previous"
  case historySearchNext = "history_search_next"

  public var context: CodexKeymapContext {
    switch self {
    case .openTranscript, .openExternalEditor, .copy, .clearTerminal, .toggleVimMode,
      .toggleRawOutput:
      .global
    case .interruptTurn, .editQueuedMessage: .chat
    case .submit, .queue, .toggleShortcuts, .historySearchPrevious, .historySearchNext: .composer
    }
  }

  public var label: String {
    switch self {
    case .openTranscript: "Open transcript"
    case .openExternalEditor: "Open external editor"
    case .copy: "Copy last response"
    case .clearTerminal: "Clear terminal"
    case .toggleVimMode: "Toggle Vim mode"
    case .toggleRawOutput: "Toggle raw output"
    case .interruptTurn: "Interrupt turn"
    case .editQueuedMessage: "Edit queued message"
    case .submit: "Submit message"
    case .queue: "Queue follow-up"
    case .toggleShortcuts: "Show shortcuts"
    case .historySearchPrevious: "Search history backward"
    case .historySearchNext: "Search history forward"
    }
  }

  public var description: String {
    switch self {
    case .openTranscript: "Open the transcript overlay"
    case .openExternalEditor: "Open the current draft in an external editor"
    case .copy: "Copy the last agent response to the clipboard"
    case .clearTerminal: "Clear the terminal UI"
    case .toggleVimMode: "Turn Vim composer mode on or off"
    case .toggleRawOutput: "Toggle copy-friendly transcript rendering"
    case .interruptTurn: "Stop the active turn"
    case .editQueuedMessage: "Move the latest queued message into the composer"
    case .submit: "Send the composer text"
    case .queue: "Queue the composer text while a turn is active"
    case .toggleShortcuts: "Open the keyboard shortcut reference"
    case .historySearchPrevious: "Open reverse prompt-history search"
    case .historySearchNext: "Move toward newer prompt-history matches"
    }
  }

  public var path: String { "tui.keymap.\(context.rawValue).\(rawValue)" }

  public var defaultBindings: [CodexKeyBinding] {
    switch self {
    case .openTranscript:
      [CodexKeyBinding(.character("t"), modifiers: [.control])]
    case .openExternalEditor:
      [CodexKeyBinding(.character("g"), modifiers: [.control])]
    case .copy:
      [CodexKeyBinding(.character("o"), modifiers: [.control])]
    case .clearTerminal:
      [CodexKeyBinding(.character("l"), modifiers: [.control])]
    case .toggleVimMode:
      []
    case .toggleRawOutput:
      [CodexKeyBinding(.character("r"), modifiers: [.option])]
    case .interruptTurn:
      [CodexKeyBinding(.escape)]
    case .editQueuedMessage:
      [
        CodexKeyBinding(.up, modifiers: [.option]),
        CodexKeyBinding(.left, modifiers: [.shift]),
      ]
    case .submit:
      [CodexKeyBinding(.enter)]
    case .queue:
      [CodexKeyBinding(.tab)]
    case .toggleShortcuts:
      [CodexKeyBinding(.character("?")), CodexKeyBinding(.character("?"), modifiers: [.shift])]
    case .historySearchPrevious:
      [CodexKeyBinding(.character("r"), modifiers: [.control])]
    case .historySearchNext:
      [CodexKeyBinding(.character("s"), modifiers: [.control])]
    }
  }
}

public struct CodexKeyBinding: Hashable, Sendable, Codable, CustomStringConvertible {
  public var key: Key
  public var modifiers: KeyModifiers

  public init(_ key: Key, modifiers: KeyModifiers = []) {
    if case .character(let character) = key,
      let normalized = String(character).lowercased().first
    {
      self.key = .character(normalized)
    } else {
      self.key = key
    }
    self.modifiers = modifiers
  }

  public init(event: KeyEvent) throws {
    let supportedModifiers: KeyModifiers = [.control, .option, .shift, .command, .hyper, .meta]
    guard event.modifiers.subtracting(supportedModifiers).isEmpty else {
      throw CodexKeymapError.invalidBinding("terminal modifier")
    }
    switch event.key {
    case .keypad, .media, .unidentified:
      throw CodexKeymapError.invalidBinding("terminal key")
    case .function(let number) where !(1...24).contains(number):
      throw CodexKeymapError.invalidBinding("f\(number)")
    default:
      self.init(event.key, modifiers: event.modifiers)
    }
  }

  public var description: String { canonicalName }

  public var canonicalName: String {
    var parts: [String] = []
    if modifiers.contains(.control) { parts.append("ctrl") }
    if modifiers.contains(.option) { parts.append("alt") }
    if modifiers.contains(.shift) { parts.append("shift") }
    if modifiers.contains(.command) { parts.append("super") }
    if modifiers.contains(.hyper) { parts.append("hyper") }
    if modifiers.contains(.meta) { parts.append("meta") }
    parts.append(Self.keyName(key))
    return parts.joined(separator: "-")
  }

  public init(canonicalName: String) throws {
    var remainder = canonicalName.lowercased()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    var modifiers: KeyModifiers = []
    let prefixes: [(String, KeyModifiers)] = [
      ("ctrl-", .control), ("alt-", .option), ("shift-", .shift),
      ("super-", .command), ("cmd-", .command), ("hyper-", .hyper), ("meta-", .meta),
    ]
    var consumed = true
    while consumed {
      consumed = false
      for (prefix, modifier) in prefixes where remainder.hasPrefix(prefix) {
        guard !modifiers.contains(modifier) else {
          throw CodexKeymapError.invalidBinding(canonicalName)
        }
        modifiers.insert(modifier)
        remainder.removeFirst(prefix.count)
        consumed = true
        break
      }
    }
    guard !remainder.isEmpty, let key = Self.parseKey(remainder) else {
      throw CodexKeymapError.invalidBinding(canonicalName)
    }
    self.init(key, modifiers: modifiers)
  }

  public func matches(_ event: KeyEvent) -> Bool {
    let candidate = CodexKeyBinding(event.key, modifiers: event.modifiers)
    return event.kind != .release && key == candidate.key && modifiers == candidate.modifiers
  }

  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    try self.init(canonicalName: value)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(canonicalName)
  }

  private static func keyName(_ key: Key) -> String {
    switch key {
    case .character(let character): String(character).lowercased()
    case .enter: "enter"
    case .escape: "esc"
    case .tab: "tab"
    case .backspace: "backspace"
    case .delete: "delete"
    case .insert: "insert"
    case .up: "up"
    case .down: "down"
    case .left: "left"
    case .right: "right"
    case .home: "home"
    case .end: "end"
    case .pageUp: "page-up"
    case .pageDown: "page-down"
    case .function(let number): "f\(number)"
    case .capsLock: "caps-lock"
    case .scrollLock: "scroll-lock"
    case .numLock: "num-lock"
    case .printScreen: "print-screen"
    case .pause: "pause"
    case .menu: "menu"
    case .keypad, .media, .unidentified: "unsupported"
    }
  }

  private static func parseKey(_ name: String) -> Key? {
    switch name {
    case "enter", "return": return .enter
    case "esc", "escape": return .escape
    case "tab": return .tab
    case "backspace": return .backspace
    case "delete", "del": return .delete
    case "insert": return .insert
    case "up": return .up
    case "down": return .down
    case "left": return .left
    case "right": return .right
    case "home": return .home
    case "end": return .end
    case "page-up", "pageup": return .pageUp
    case "page-down", "pagedown": return .pageDown
    case "caps-lock": return .capsLock
    case "scroll-lock": return .scrollLock
    case "num-lock": return .numLock
    case "print-screen": return .printScreen
    case "pause": return .pause
    case "menu": return .menu
    default:
      if name.hasPrefix("f"), let number = Int(name.dropFirst()), (1...24).contains(number) {
        return .function(number)
      }
      if name.count == 1, let character = name.first { return .character(character) }
      return nil
    }
  }
}

public struct CodexKeymapConfiguration: Codable, Hashable, Sendable {
  public var global: [CodexKeymapAction: [CodexKeyBinding]]
  public var chat: [CodexKeymapAction: [CodexKeyBinding]]
  public var composer: [CodexKeymapAction: [CodexKeyBinding]]

  public init(
    global: [CodexKeymapAction: [CodexKeyBinding]] = [:],
    chat: [CodexKeymapAction: [CodexKeyBinding]] = [:],
    composer: [CodexKeymapAction: [CodexKeyBinding]] = [:]
  ) {
    self.global = global
    self.chat = chat
    self.composer = composer
  }

  public subscript(action: CodexKeymapAction) -> [CodexKeyBinding]? {
    get {
      switch action.context {
      case .global: global[action]
      case .chat: chat[action]
      case .composer: composer[action]
      }
    }
    set {
      switch action.context {
      case .global: global[action] = newValue
      case .chat: chat[action] = newValue
      case .composer: composer[action] = newValue
      }
    }
  }

  enum CodingKeys: String, CodingKey { case global, chat, composer }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    global = try Self.decode(.global, from: container)
    chat = try Self.decode(.chat, from: container)
    composer = try Self.decode(.composer, from: container)
    try validateContextKeys()
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try Self.encode(global, for: .global, to: &container)
    try Self.encode(chat, for: .chat, to: &container)
    try Self.encode(composer, for: .composer, to: &container)
  }

  private static func decode(
    _ key: CodingKeys, from container: KeyedDecodingContainer<CodingKeys>
  ) throws -> [CodexKeymapAction: [CodexKeyBinding]] {
    let raw = try container.decodeIfPresent([String: [CodexKeyBinding]].self, forKey: key) ?? [:]
    return try Dictionary(
      uniqueKeysWithValues: raw.map { name, bindings in
        guard let action = CodexKeymapAction(rawValue: name) else {
          throw CodexKeymapError.unknownAction("\(key.stringValue).\(name)")
        }
        return (action, bindings)
      })
  }

  private static func encode(
    _ values: [CodexKeymapAction: [CodexKeyBinding]], for context: CodexKeymapContext,
    to container: inout KeyedEncodingContainer<CodingKeys>
  ) throws {
    let raw = Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
    if !raw.isEmpty {
      try container.encode(raw, forKey: CodingKeys(rawValue: context.rawValue)!)
    }
  }

  private func validateContextKeys() throws {
    for (context, values) in [
      (CodexKeymapContext.global, global), (.chat, chat), (.composer, composer),
    ] {
      if let action = values.keys.first(where: { $0.context != context }) {
        throw CodexKeymapError.unknownAction("\(context.rawValue).\(action.rawValue)")
      }
    }
  }
}

public struct CodexRuntimeKeymap: Hashable, Sendable {
  public var configuration: CodexKeymapConfiguration

  public init(configuration: CodexKeymapConfiguration = .init()) throws {
    self.configuration = configuration
    try validate()
  }

  public func bindings(for action: CodexKeymapAction) -> [CodexKeyBinding] {
    configuration[action] ?? action.defaultBindings
  }

  public func isCustomized(_ action: CodexKeymapAction) -> Bool {
    configuration[action] != nil
  }

  public func action(for event: KeyEvent, contexts: Set<CodexKeymapContext>) -> CodexKeymapAction? {
    CodexKeymapAction.allCases.first {
      contexts.contains($0.context) && bindings(for: $0).contains { $0.matches(event) }
    }
  }

  public func replacing(
    _ action: CodexKeymapAction, with bindings: [CodexKeyBinding]?
  ) throws -> CodexRuntimeKeymap {
    var candidate = configuration
    candidate[action] = bindings
    return try CodexRuntimeKeymap(configuration: candidate)
  }

  public func validate() throws {
    let reserved: [CodexKeyBinding: String] = [
      CodexKeyBinding(.character("c"), modifiers: [.control]): "fixed.interrupt_or_quit",
      CodexKeyBinding(.character("d"), modifiers: [.control]): "fixed.quit",
      CodexKeyBinding(.character("v"), modifiers: [.control]): "fixed.paste_image",
      CodexKeyBinding(.character("/"), modifiers: [.control]): "fixed.side_conversation",
    ]
    var owners: [CodexKeyBinding: CodexKeymapAction] = [:]
    for action in CodexKeymapAction.allCases {
      for binding in bindings(for: action) {
        if let reservedAction = reserved[binding] {
          throw CodexKeymapError.conflict(binding.canonicalName, reservedAction, action.path)
        }
        if let owner = owners[binding], owner != action {
          throw CodexKeymapError.conflict(binding.canonicalName, owner.path, action.path)
        }
        owners[binding] = action
      }
    }
  }
}

public enum CodexKeymapError: Error, LocalizedError, Hashable, Sendable {
  case invalidBinding(String)
  case unknownAction(String)
  case conflict(String, String, String)

  public var errorDescription: String? {
    switch self {
    case .invalidBinding(let binding): "Invalid key binding '\(binding)'."
    case .unknownAction(let action): "Unsupported keymap action '\(action)'."
    case .conflict(let binding, let first, let second):
      "Shortcut '\(binding)' conflicts between \(first) and \(second)."
    }
  }
}

public enum CodexKeymapTab: String, CaseIterable, Hashable, Sendable {
  case all
  case common
  case customized
  case unbound
  case app
  case composer
  case debug

  public func label(customizedCount: Int, unboundCount: Int) -> String {
    switch self {
    case .all: "All"
    case .common: "Common"
    case .customized: "Customized (\(customizedCount))"
    case .unbound: "Unbound (\(unboundCount))"
    case .app: "App"
    case .composer: "Composer"
    case .debug: "Debug"
    }
  }
}

public struct CodexKeymapPicker: Hashable, Sendable {
  public var configuration: CodexKeymapConfiguration
  public var query: String
  public var selectedIndex: Int
  public var tab: CodexKeymapTab

  public init(
    configuration: CodexKeymapConfiguration, query: String = "", selectedIndex: Int = 0,
    tab: CodexKeymapTab = .all
  ) {
    self.configuration = configuration
    self.query = query
    self.selectedIndex = selectedIndex
    self.tab = tab
    reconcileSelection()
  }

  public var runtime: CodexRuntimeKeymap { try! CodexRuntimeKeymap(configuration: configuration) }

  public var filteredActions: [CodexKeymapAction] {
    let tabActions = CodexKeymapAction.allCases.filter(matchesActiveTab)
    let needle = query.lowercased()
    guard !needle.isEmpty else { return tabActions }
    return tabActions.filter { action in
      let source = runtime.isCustomized(action) ? "custom" : "default"
      let binding = runtime.bindings(for: action).map(\.canonicalName).joined(separator: " ")
      return [
        action.context.label, action.context.rawValue, action.rawValue, action.label,
        action.description, binding, source,
      ]
      .contains { $0.lowercased().contains(needle) }
    }
  }

  public var selectedAction: CodexKeymapAction? {
    let actions = filteredActions
    return actions.indices.contains(selectedIndex) ? actions[selectedIndex] : nil
  }
  public var customizedCount: Int { CodexKeymapAction.allCases.count(where: runtime.isCustomized) }
  public var unboundCount: Int {
    CodexKeymapAction.allCases.count { runtime.bindings(for: $0).isEmpty }
  }

  public mutating func selectAdjacentTab(forward: Bool) {
    let tabs = CodexKeymapTab.allCases
    guard let index = tabs.firstIndex(of: tab) else { return }
    tab = tabs[(index + (forward ? 1 : tabs.count - 1)) % tabs.count]
    selectedIndex = 0
    reconcileSelection()
  }

  public mutating func reconcileSelection() {
    selectedIndex = min(max(0, selectedIndex), max(0, filteredActions.count - 1))
  }

  private func matchesActiveTab(_ action: CodexKeymapAction) -> Bool {
    switch tab {
    case .all: true
    case .common: [.submit, .interruptTurn, .queue].contains(action)
    case .customized: runtime.isCustomized(action)
    case .unbound: runtime.bindings(for: action).isEmpty
    case .app: action.context != .composer
    case .composer: action.context == .composer
    case .debug: false
    }
  }
}

public struct CodexKeymapDebugMatch: Hashable, Sendable {
  public var action: CodexKeymapAction
  public var source: String
}

public struct CodexKeymapDebug: Hashable, Sendable {
  public var runtime: CodexRuntimeKeymap
  public var detected: CodexKeyBinding?
  public var rawEvent: String?
  public var matches: [CodexKeymapDebugMatch]

  public init(runtime: CodexRuntimeKeymap) {
    self.runtime = runtime
    detected = nil
    rawEvent = nil
    matches = []
  }

  public mutating func inspect(_ event: KeyEvent) {
    guard event.kind != .release else { return }
    detected = try? CodexKeyBinding(event: event)
    rawEvent = Self.rawEventDescription(event)
    matches = CodexKeymapAction.allCases.compactMap { action in
      guard runtime.bindings(for: action).contains(where: { $0.matches(event) }) else { return nil }
      return CodexKeymapDebugMatch(
        action: action, source: runtime.isCustomized(action) ? "Custom" : "Default")
    }
  }

  private static func rawEventDescription(_ event: KeyEvent) -> String {
    let modifiers: [(KeyModifiers, String)] = [
      (.control, "ctrl"), (.option, "alt"), (.shift, "shift"), (.command, "super"),
      (.hyper, "hyper"), (.meta, "meta"),
    ]
    let modifierLabel = modifiers.compactMap { event.modifiers.contains($0.0) ? $0.1 : nil }
      .joined(separator: "|")
    let key =
      (try? CodexKeyBinding(event: event).canonicalName.split(separator: "-").last.map(String.init))
      ?? "unsupported"
    return
      "code=\(key), modifiers=\(modifierLabel.isEmpty ? "none" : modifierLabel), kind=\(event.kind)"
  }
}

public enum CodexKeymapEditOperation: Hashable, Sendable {
  case replaceAll
  case addAlternate
  case removeCustom
  case back
}

public struct CodexKeymapActionMenu: Hashable, Sendable {
  public var action: CodexKeymapAction
  public var configuration: CodexKeymapConfiguration
  public var selectedIndex: Int

  public init(
    action: CodexKeymapAction, configuration: CodexKeymapConfiguration, selectedIndex: Int = 0
  ) {
    self.action = action
    self.configuration = configuration
    self.selectedIndex = selectedIndex
  }

  public var runtime: CodexRuntimeKeymap { try! CodexRuntimeKeymap(configuration: configuration) }
  public var operations: [CodexKeymapEditOperation] {
    var result: [CodexKeymapEditOperation] = [.replaceAll, .addAlternate]
    if runtime.isCustomized(action) { result.append(.removeCustom) }
    result.append(.back)
    return result
  }
}

public struct CodexKeymapCapture: Hashable, Sendable {
  public var action: CodexKeymapAction
  public var operation: CodexKeymapEditOperation
  public var configuration: CodexKeymapConfiguration

  public init(
    action: CodexKeymapAction, operation: CodexKeymapEditOperation,
    configuration: CodexKeymapConfiguration
  ) {
    self.action = action
    self.operation = operation
    self.configuration = configuration
  }
}
