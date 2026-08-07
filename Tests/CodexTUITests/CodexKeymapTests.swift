import Ratatui
import Testing

@testable import CodexTUI

@Suite struct CodexKeymapTests {
  @Test func canonicalBindingsRoundTripTerminalKeys() throws {
    let bindings = [
      CodexKeyBinding(.enter),
      CodexKeyBinding(.character("r"), modifiers: [.control]),
      CodexKeyBinding(.up, modifiers: [.option, .shift]),
      CodexKeyBinding(.pageDown),
      CodexKeyBinding(.function(24), modifiers: [.command]),
    ]

    for binding in bindings {
      #expect(try CodexKeyBinding(canonicalName: binding.canonicalName) == binding)
    }
    #expect(try CodexKeyBinding(canonicalName: "escape").canonicalName == "esc")
    #expect(throws: CodexKeymapError.self) { try CodexKeyBinding(canonicalName: "f25") }
  }

  @Test func configurationDistinguishesDefaultsOverridesAndExplicitUnbinding() throws {
    var configuration = CodexKeymapConfiguration()
    var runtime = try CodexRuntimeKeymap(configuration: configuration)
    #expect(runtime.bindings(for: .submit) == [CodexKeyBinding(.enter)])
    #expect(!runtime.isCustomized(.submit))

    configuration[.submit] = [CodexKeyBinding(.character("x"), modifiers: [.control])]
    runtime = try CodexRuntimeKeymap(configuration: configuration)
    #expect(runtime.bindings(for: .submit).map(\.canonicalName) == ["ctrl-x"])
    #expect(runtime.isCustomized(.submit))

    configuration[.submit] = []
    runtime = try CodexRuntimeKeymap(configuration: configuration)
    #expect(runtime.bindings(for: .submit).isEmpty)
    #expect(runtime.isCustomized(.submit))
  }

  @Test func conflictsAreRejectedBeforeRuntimeReplacement() throws {
    let runtime = try CodexRuntimeKeymap()
    #expect(throws: CodexKeymapError.self) {
      try runtime.replacing(.submit, with: [CodexKeyBinding(.tab)])
    }
    #expect(runtime.bindings(for: .submit) == [CodexKeyBinding(.enter)])
  }

  @Test func fixedApplicationShortcutsCannotBeShadowed() throws {
    let runtime = try CodexRuntimeKeymap()
    let reserved = [
      CodexKeyBinding(.character("c"), modifiers: [.control]),
      CodexKeyBinding(.character("d"), modifiers: [.control]),
      CodexKeyBinding(.character("v"), modifiers: [.control]),
      CodexKeyBinding(.character("/"), modifiers: [.control]),
    ]

    for binding in reserved {
      #expect(throws: CodexKeymapError.self) {
        try runtime.replacing(.submit, with: [binding])
      }
    }
  }

  @Test func pickerSearchesStableNamesDescriptionsBindingsAndSource() throws {
    var configuration = CodexKeymapConfiguration()
    configuration[.submit] = [CodexKeyBinding(.character("x"), modifiers: [.control])]

    #expect(
      CodexKeymapPicker(configuration: configuration, query: "ctrl-x").filteredActions == [.submit])
    #expect(
      CodexKeymapPicker(configuration: configuration, query: "custom").filteredActions == [.submit])
    #expect(
      CodexKeymapPicker(configuration: configuration, query: "queued").filteredActions
        .contains(.editQueuedMessage))
    #expect(
      CodexKeymapPicker(configuration: configuration, query: "history_search_next")
        .filteredActions == [.historySearchNext])
  }

  @Test func pickerTabsFilterCountsAndWrapInUpstreamOrder() {
    var configuration = CodexKeymapConfiguration()
    configuration[.submit] = []
    configuration[.toggleRawOutput] = [CodexKeyBinding(.function(2))]
    var picker = CodexKeymapPicker(configuration: configuration)

    #expect(picker.customizedCount == 2)
    #expect(picker.unboundCount == 2)
    #expect(picker.filteredActions == CodexKeymapAction.allCases)

    picker.selectAdjacentTab(forward: true)
    #expect(picker.tab == .common)
    #expect(picker.filteredActions == [.interruptTurn, .submit, .queue])
    picker.selectAdjacentTab(forward: true)
    #expect(picker.tab == .customized)
    #expect(picker.filteredActions == [.toggleRawOutput, .submit])
    picker.selectAdjacentTab(forward: true)
    #expect(picker.tab == .unbound)
    #expect(picker.filteredActions == [.toggleVimMode, .submit])
    picker.selectAdjacentTab(forward: true)
    #expect(picker.tab == .app)
    #expect(picker.filteredActions.allSatisfy { $0.context != .composer })
    picker.selectAdjacentTab(forward: false)
    #expect(picker.tab == .unbound)

    picker = CodexKeymapPicker(configuration: configuration, tab: .debug)
    picker.selectAdjacentTab(forward: true)
    #expect(picker.tab == .all)
  }
}
