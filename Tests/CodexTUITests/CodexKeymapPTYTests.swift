#if canImport(Darwin)
  import Darwin
  import Foundation
  import Ratatui
  import Testing

  @testable import CodexTUI

  @MainActor
  @Suite(.serialized) struct CodexKeymapPTYTests {
    @Test func realPTYOptionSequenceCanBeCapturedPersistedAndReloaded() async throws {
      var master: Int32 = -1
      var slave: Int32 = -1
      var window = winsize()
      window.ws_col = 80
      window.ws_row = 24
      #expect(openpty(&master, &slave, nil, nil, &window) == 0)
      guard master >= 0, slave >= 0 else { return }
      defer {
        close(master)
        close(slave)
      }

      let cursorReport = Array("\u{1B}[1;1R".utf8)
      _ = cursorReport.withUnsafeBytes { write(master, $0.baseAddress, $0.count) }
      let session = try TerminalSession(
        viewport: .inline(height: 8), inputDescriptor: slave,
        output: FileHandle(fileDescriptor: slave, closeOnDealloc: false))
      defer { try? session.restore() }
      var input = session.makeInput()

      let optionX = Array("\u{1B}x".utf8)
      #expect(
        optionX.withUnsafeBytes { write(master, $0.baseAddress, $0.count) } == optionX.count)
      let event = try #require(try input.readEvent(timeoutMilliseconds: 100))
      guard case .key(let key) = event else {
        Issue.record("Expected a decoded key event")
        return
      }
      #expect(try CodexKeyBinding(event: key).canonicalName == "alt-x")

      let home = FileManager.default.temporaryDirectory.appendingPathComponent(
        "codex-swift-keymap-pty-tests-\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: home) }
      let store = CodexSettingsStore(home: home)
      let model = CodexSessionModel()
      model.overlay = .keymapCapture(
        CodexKeymapCapture(
          action: .submit, operation: .replaceAll,
          configuration: model.runtimeKeymap.configuration))
      let application = CodexApplication(
        model: model, driver: CodexDemoDriver(model: model),
        systemServices: CodexSystemServices(
          gitDiff: { _ in "" }, copyToClipboard: { _ in },
          saveKeymap: { try store.save(keymap: $0) }))

      #expect(await application.update(event) == .redraw)
      #expect(model.runtimeKeymap.bindings(for: .submit).map(\.canonicalName) == ["alt-x"])
      let reloaded = try CodexRuntimeKeymap(configuration: store.keymap())
      #expect(reloaded.bindings(for: .submit).map(\.canonicalName) == ["alt-x"])

      model.overlay = .keymapDebug(CodexKeymapDebug(runtime: reloaded))
      #expect(await application.update(event) == .redraw)
      guard case .keymapDebug(let report) = model.overlay else {
        Issue.record("Expected PTY event in keypress inspector")
        return
      }
      #expect(report.detected?.canonicalName == "alt-x")
      #expect(report.matches == [CodexKeymapDebugMatch(action: .submit, source: "Custom")])

      var controlC: UInt8 = 3
      #expect(write(master, &controlC, 1) == 1)
      let closeEvent = try #require(try input.readEvent(timeoutMilliseconds: 100))
      #expect(await application.update(closeEvent) == .redraw)
      #expect(model.overlay == nil)
    }
  }
#endif
