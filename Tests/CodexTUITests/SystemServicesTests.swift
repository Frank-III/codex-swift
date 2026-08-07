import Foundation
import Testing

@testable import CodexTUI

@Suite struct SystemServicesTests {
  @Test func externalEditorCommandParsingAndTempFileRoundTripMatchUpstream() throws {
    #expect(
      try splitEditorCommand("code --wait 'profile name'") == ["code", "--wait", "profile name"])
    #expect(throws: SystemServiceError.self) { try splitEditorCommand("editor 'unterminated") }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "codex-swift-editor-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("editor.sh")
    try Data("#!/bin/sh\nprintf 'edited from process\\n' > \"$1\"\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let edited = try runExternalEditor(seed: "seed", environment: ["VISUAL": script.path])
    #expect(edited == "edited from process\n")
    #expect(throws: SystemServiceError.self) {
      try runExternalEditor(seed: "seed", environment: [:])
    }
  }

  @Test func gitDiffIncludesTrackedAndUntrackedFiles() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "codex-swift-diff-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try runGit(["init", "-q"], in: directory)
    try Data("before\n".utf8).write(to: directory.appendingPathComponent("tracked.txt"))
    try runGit(["add", "tracked.txt"], in: directory)
    try runGit(
      ["-c", "user.name=Codex", "-c", "user.email=codex@example.com", "commit", "-qm", "base"],
      in: directory)
    try Data("after\n".utf8).write(to: directory.appendingPathComponent("tracked.txt"))
    try Data("new\n".utf8).write(to: directory.appendingPathComponent("untracked.txt"))

    let diff = try await CodexSystemServices.live.gitDiff(directory.path)

    #expect(diff.contains("tracked.txt"))
    #expect(diff.contains("untracked.txt"))
    #expect(diff.contains("+after"))
    #expect(diff.contains("+new"))
  }

  @Test func projectFilesIncludesTrackedAndUntrackedButNotIgnoredFiles() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "codex-swift-files-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try runGit(["init", "-q"], in: directory)
    try Data("ignored.txt\n".utf8).write(to: directory.appendingPathComponent(".gitignore"))
    try Data("tracked\n".utf8).write(to: directory.appendingPathComponent("tracked.swift"))
    try runGit(["add", ".gitignore", "tracked.swift"], in: directory)
    try Data("new\n".utf8).write(to: directory.appendingPathComponent("new.swift"))
    try Data("ignored\n".utf8).write(to: directory.appendingPathComponent("ignored.txt"))

    let files = try await CodexSystemServices.live.projectFiles(directory.path)

    #expect(files == [".gitignore", "new.swift", "tracked.swift"])
  }

  @Test func pastedImagePathLoadsSupportedBytesForKwwk() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "codex-swift-image-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = try #require(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z3j8AAAAASUVORK5CYII="
      ))
    try source.write(to: directory.appendingPathComponent("shot.png"))

    let image = try #require(
      try await CodexSystemServices.live.imageFile("./shot.png", directory.path))

    #expect(!image.data.isEmpty)
    #expect(image.data.count <= 500 * 1_024)
    #expect(["image/png", "image/jpeg", "image/webp"].contains(image.mimeType))
    #expect(image.name == "shot.png")
    #expect(try await CodexSystemServices.live.imageFile("missing.png", directory.path) == nil)
    #expect(try await CodexSystemServices.live.imageFile("notes.txt", directory.path) == nil)
  }

  @Test func dataURLUsesKwwkImageNormalization() async throws {
    let base64 =
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z3j8AAAAASUVORK5CYII="
    let image = try #require(
      try await CodexSystemServices.live.remoteImage("data:image/png;base64,\(base64)"))

    #expect(!image.data.isEmpty)
    #expect(image.data.count <= 500 * 1_024)
    #expect(image.name == "pasted-image")
    #expect(try await CodexSystemServices.live.remoteImage("ordinary pasted text") == nil)
  }

  @Test func themeSettingsLoadCustomTextMateFilesAndPreserveOtherKeys() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(
      "codex-swift-theme-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let themesDirectory = home.appendingPathComponent("themes", isDirectory: true)
    try FileManager.default.createDirectory(at: themesDirectory, withIntermediateDirectories: true)
    let plist: [String: Any] = [
      "name": "My Theme",
      "settings": [
        ["settings": ["foreground": "#D0D0D0", "background": "#101010"]],
        ["scope": "keyword.control", "settings": ["foreground": "#FF00AA"]],
      ],
    ]
    let themeData = try PropertyListSerialization.data(
      fromPropertyList: plist, format: .xml, options: 0)
    try themeData.write(to: themesDirectory.appendingPathComponent("My.tmTheme"))
    let settingsURL = home.appendingPathComponent("settings.json")
    try Data("{\"other\":\"kept\",\"syntaxTheme\":\"github\"}".utf8).write(to: settingsURL)
    let store = CodexSettingsStore(home: home)

    #expect(store.availableThemes().contains { $0.name == "My Theme" })
    #expect(store.selectedTheme().name == "github")
    #expect(!store.rawOutputMode())
    try store.save(themeName: "My Theme")
    try store.save(rawOutputMode: true)

    let saved = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
    #expect(saved["syntaxTheme"] as? String == "My Theme")
    #expect(saved["other"] as? String == "kept")
    #expect(saved["rawOutputMode"] as? Bool == true)
    #expect(store.selectedTheme().name == "My Theme")
    #expect(store.rawOutputMode())
  }

  @Test func malformedSettingsAreRejectedWithoutBeingOverwritten() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(
      "codex-swift-invalid-settings-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let settingsURL = home.appendingPathComponent("settings.json")
    let malformed = Data("{not json".utf8)
    try malformed.write(to: settingsURL)
    let store = CodexSettingsStore(home: home)

    #expect(throws: SystemServiceError.self) { try store.keymap() }
    #expect(throws: SystemServiceError.self) {
      try store.save(keymap: CodexKeymapConfiguration())
    }
    #expect(try Data(contentsOf: settingsURL) == malformed)
  }

  @Test func malformedKeymapShapesAreRejectedWithoutBeingOverwritten() throws {
    for payload in [
      #"{"other":"kept","tuiKeymap":[]}"#,
      #"{"other":"kept","tuiKeymap":{"composer":[]}}"#,
    ] {
      let home = FileManager.default.temporaryDirectory.appendingPathComponent(
        "codex-swift-invalid-keymap-tests-\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: home) }
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
      let settingsURL = home.appendingPathComponent("settings.json")
      let original = Data(payload.utf8)
      try original.write(to: settingsURL)
      let store = CodexSettingsStore(home: home)

      #expect(throws: SystemServiceError.self) { try store.keymap() }
      #expect(throws: SystemServiceError.self) {
        try store.save(keymap: CodexKeymapConfiguration())
      }
      #expect(try Data(contentsOf: settingsURL) == original)
    }
  }

  @Test func keymapRoundTripPreservesUnrelatedSettingsAndNestedEntries() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(
      "codex-swift-keymap-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let settingsURL = home.appendingPathComponent("settings.json")
    try Data(
      """
      {"syntaxTheme":"github","rawOutputMode":true,"other":{"keep":[1,2,3]},"tuiKeymap":{"editor":{"move_left":["left"]},"composer":{"queue":["ctrl-q"]}}}
      """.utf8
    ).write(to: settingsURL)
    let store = CodexSettingsStore(home: home)
    var configuration = try store.keymap()
    #expect(configuration[.queue]?.map(\.canonicalName) == ["ctrl-q"])

    configuration[.submit] = []
    try store.save(keymap: configuration)

    let reloaded = try store.keymap()
    #expect(reloaded[.submit] == [])
    #expect(reloaded[.queue]?.map(\.canonicalName) == ["ctrl-q"])
    let saved = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
    #expect(saved["syntaxTheme"] as? String == "github")
    #expect(saved["rawOutputMode"] as? Bool == true)
    #expect((saved["other"] as? [String: Any])?["keep"] as? [Int] == [1, 2, 3])
    let keymap = try #require(saved["tuiKeymap"] as? [String: Any])
    #expect((keymap["editor"] as? [String: Any])?["move_left"] as? [String] == ["left"])
  }

  private func runGit(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = directory
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw SystemServiceError.commandFailed("git", process.terminationStatus, "")
    }
  }
}
