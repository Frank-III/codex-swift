import CodexTUI
import Darwin
import Foundation
import TermLoom

@main
struct CodexSwiftMain {
  @MainActor
  static func main() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let app: CodexApplication
    if let largeLiveIndex = arguments.firstIndex(of: "--large-live") {
      let turns = arguments.dropFirst(largeLiveIndex + 1).first.flatMap(Int.init) ?? 1_000
      app = await CodexRuntime.live()
      CodexLargeSessionFixture.populate(app.model, turns: turns)
    } else if let largeDemoIndex = arguments.firstIndex(of: "--large-demo") {
      let turns = arguments.dropFirst(largeDemoIndex + 1).first.flatMap(Int.init) ?? 1_000
      app = CodexLargeSessionFixture.makeApplication(turns: turns)
    } else if arguments.contains("--demo") {
      app = CodexRuntime.demo()
    } else {
      app = await CodexRuntime.live()
    }

    do {
      // The retained viewport is the live composer/streaming surface. Committed source-backed history
      // is inserted immediately above it and naturally continues into native terminal scrollback.
      try await app.run(viewport: .inline(height: 1))
    } catch {
      FileHandle.standardError.write(Data("codex-swift: \(error)\n".utf8))
      exit(1)
    }
  }
}
