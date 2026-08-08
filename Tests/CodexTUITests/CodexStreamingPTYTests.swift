import Darwin
import Foundation
import KWWKAI
import KWWKAgent
import TermLoom
import Testing

@testable import CodexTUI

@Suite(.serialized) @MainActor struct CodexStreamingPTYTests {
  @Test func streamingCancellationAndResizeRemainStableOnARealPTY() throws {
    let pair = try PTYPair(columns: 80, rows: 24)
    defer { pair.close() }
    try pair.writeToMaster("\u{1B}[12;1R")
    let drainer = pair.startDrainingOutput()
    defer { drainer.cancel() }

    let output = FileHandle(fileDescriptor: pair.slave, closeOnDealloc: false)
    let session = try TerminalSession(inputDescriptor: pair.slave, output: output)
    defer { try? session.restore() }

    var terminal = try Terminal(
      backend: ANSIBackend(output: output, viewportHeight: 12))
    let model = CodexSessionModel(snapshot: CodexSnapshot(showHeader: false))
    let reducer = CodexEventReducer(model: model)
    reducer.consume(.turnStart)

    let pending = assistant("uncommitted-fragment")
    reducer.consume(
      .messageUpdate(
        message: pending,
        assistantMessageEvent: .textDelta(
          contentIndex: 0, delta: "uncommitted-fragment", partial: pending)))
    var frame = try terminal.draw { $0.render(CodexScreen(snapshot: model.snapshot)) }
    #expect(!text(in: frame.buffer).contains("uncommitted-fragment"))

    let tableSource = "committed line\n| A | B |\n|---|---|\n| unfinished"
    let table = assistant(tableSource)
    reducer.consume(
      .messageUpdate(
        message: table,
        assistantMessageEvent: .textDelta(
          contentIndex: 0, delta: tableSource, partial: table)))
    frame = try terminal.draw { $0.render(CodexScreen(snapshot: model.snapshot)) }
    #expect(text(in: frame.buffer).contains("committed line"))
    #expect(!text(in: frame.buffer).contains("unfinished"))

    try pair.resize(columns: 42, rows: 18)
    frame = try terminal.draw { $0.render(CodexScreen(snapshot: model.snapshot)) }
    #expect(frame.buffer.area.width == 42)
    #expect(frame.buffer.area.height == 12)
    #expect(text(in: frame.buffer).contains("committed line"))

    try pair.resize(columns: 36, rows: 7)
    frame = try terminal.draw { $0.render(CodexScreen(snapshot: model.snapshot)) }
    #expect(frame.buffer.area == Rect(x: 0, y: 0, width: 36, height: 7))
    #expect(text(in: frame.buffer).contains("A  B"))
    #expect(!text(in: frame.buffer).contains("unfinished"))

    try pair.resize(columns: 96, rows: 30)
    frame = try terminal.draw { $0.render(CodexScreen(snapshot: model.snapshot)) }
    #expect(frame.buffer.area == Rect(x: 0, y: 0, width: 96, height: 12))
    #expect(text(in: frame.buffer).contains("committed line"))

    reducer.consume(.streamRewind)
    frame = try terminal.draw { $0.render(CodexScreen(snapshot: model.snapshot)) }
    #expect(!text(in: frame.buffer).contains("committed line"))
    #expect(model.entries.isEmpty)
  }

  private func assistant(_ source: String) -> AssistantMessage {
    AssistantMessage(
      content: [.text(TextContent(text: source))], api: "test", provider: "test", model: "test")
  }

  private func text(in buffer: Buffer) -> String {
    var result = ""
    for y in 0..<buffer.area.height {
      for x in 0..<buffer.area.width {
        result += buffer[Position(x: x, y: y)].symbol
      }
    }
    return result
  }
}

private final class PTYPair {
  let master: Int32
  let slave: Int32

  init(columns: UInt16, rows: UInt16) throws {
    var master: Int32 = -1
    var slave: Int32 = -1
    var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
    guard openpty(&master, &slave, nil, nil, &size) == 0 else {
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    self.master = master
    self.slave = slave
  }

  func writeToMaster(_ text: String) throws {
    let bytes = Array(text.utf8)
    let written = bytes.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
    guard written == bytes.count else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
  }

  func startDrainingOutput() -> DispatchSourceRead {
    _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
    let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: .global())
    source.setEventHandler { [master] in
      var buffer = [UInt8](repeating: 0, count: 4096)
      while Darwin.read(master, &buffer, buffer.count) > 0 {}
    }
    source.resume()
    return source
  }

  func resize(columns: UInt16, rows: UInt16) throws {
    var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
    guard ioctl(slave, TIOCSWINSZ, &size) == 0 else {
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
  }

  func close() {
    Darwin.close(master)
    Darwin.close(slave)
  }
}
