import Foundation
import KWWKAI
import KWWKAgent
import TermLoomSyntaxHighlighting

#if canImport(AppKit)
  import AppKit
#endif

public struct CodexSystemServices: Sendable {
  public var gitDiff: @Sendable (_ directory: String) async throws -> String
  public var copyToClipboard: @Sendable (_ text: String) async throws -> Void
  public var editDraft: @Sendable (_ seed: String) async throws -> String
  public var projectFiles: @Sendable (_ directory: String) async throws -> [String]
  public var imageFile:
    @Sendable (_ pastedPath: String, _ directory: String) async throws -> CodexImageAttachment?
  public var clipboardImage: @MainActor @Sendable () async throws -> CodexImageAttachment?
  public var remoteImage: @Sendable (_ pastedValue: String) async throws -> CodexImageAttachment?
  public var localShell:
    @Sendable (_ command: String, _ directory: String) async throws -> BashExecutionResult
  public var syntaxThemes: @Sendable () async -> [SyntaxTheme]
  public var loadSyntaxTheme: @Sendable () async throws -> SyntaxTheme
  public var saveSyntaxTheme: @Sendable (_ name: String) async throws -> Void
  public var loadRawOutputMode: @Sendable () async throws -> Bool
  public var saveRawOutputMode: @Sendable (_ enabled: Bool) async throws -> Void
  public var loadKeymap: @Sendable () async throws -> CodexKeymapConfiguration
  public var saveKeymap: @Sendable (_ configuration: CodexKeymapConfiguration) async throws -> Void

  public init(
    gitDiff: @escaping @Sendable (_ directory: String) async throws -> String,
    copyToClipboard: @escaping @Sendable (_ text: String) async throws -> Void,
    editDraft: @escaping @Sendable (_ seed: String) async throws -> String = { $0 },
    projectFiles: @escaping @Sendable (_ directory: String) async throws -> [String] = { _ in [] },
    imageFile:
      @escaping @Sendable (_ pastedPath: String, _ directory: String) async throws ->
      CodexImageAttachment? = { _, _ in nil },
    clipboardImage: @escaping @MainActor @Sendable () async throws -> CodexImageAttachment? = {
      nil
    },
    remoteImage:
      @escaping @Sendable (_ pastedValue: String) async throws ->
      CodexImageAttachment? = { _ in nil },
    localShell:
      @escaping @Sendable (_ command: String, _ directory: String) async throws ->
      BashExecutionResult = { command, directory in
        try await LocalBashOperations(
          cwd: directory,
          shellPath: ProcessInfo.processInfo.environment["SHELL"] ?? kwwkDefaultShellPath,
          environment: ProcessInfo.processInfo.environment
        ).execute(command: command, timeout: 120_000, cancellation: nil)
      },
    syntaxThemes: @escaping @Sendable () async -> [SyntaxTheme] = { SyntaxTheme.builtins },
    loadSyntaxTheme: @escaping @Sendable () async throws -> SyntaxTheme = {
      SyntaxTheme.named(SyntaxTheme.defaultName)!
    },
    saveSyntaxTheme: @escaping @Sendable (_ name: String) async throws -> Void = { _ in },
    loadRawOutputMode: @escaping @Sendable () async throws -> Bool = { false },
    saveRawOutputMode: @escaping @Sendable (_ enabled: Bool) async throws -> Void = { _ in },
    loadKeymap: @escaping @Sendable () async throws -> CodexKeymapConfiguration = { .init() },
    saveKeymap:
      @escaping @Sendable (_ configuration: CodexKeymapConfiguration) async throws -> Void = { _ in
      }
  ) {
    self.gitDiff = gitDiff
    self.copyToClipboard = copyToClipboard
    self.editDraft = editDraft
    self.projectFiles = projectFiles
    self.imageFile = imageFile
    self.clipboardImage = clipboardImage
    self.remoteImage = remoteImage
    self.localShell = localShell
    self.syntaxThemes = syntaxThemes
    self.loadSyntaxTheme = loadSyntaxTheme
    self.saveSyntaxTheme = saveSyntaxTheme
    self.loadRawOutputMode = loadRawOutputMode
    self.saveRawOutputMode = saveRawOutputMode
    self.loadKeymap = loadKeymap
    self.saveKeymap = saveKeymap
  }

  public static let live = Self(
    gitDiff: { directory in
      try await Task.detached { try computeGitDiff(directory: directory) }.value
    },
    copyToClipboard: { text in
      try await Task.detached {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(text.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
          throw SystemServiceError.commandFailed("pbcopy", process.terminationStatus, "")
        }
      }.value
    },
    editDraft: { seed in
      try await Task.detached { try runExternalEditor(seed: seed) }.value
    },
    projectFiles: { directory in
      try await Task.detached { try listProjectFiles(directory: directory) }.value
    },
    imageFile: { pastedPath, directory in
      try await Task.detached {
        try loadImageFile(pastedPath: pastedPath, directory: directory)
      }.value
    },
    clipboardImage: {
      try clipboardImageFromPasteboard()
    },
    remoteImage: { pastedValue in
      try await loadRemoteImage(pastedValue)
    },
    localShell: { command, directory in
      try await LocalBashOperations(
        cwd: directory,
        shellPath: ProcessInfo.processInfo.environment["SHELL"] ?? kwwkDefaultShellPath,
        environment: ProcessInfo.processInfo.environment
      ).execute(command: command, timeout: 120_000, cancellation: nil)
    },
    syntaxThemes: { CodexSettingsStore().availableThemes() },
    loadSyntaxTheme: { CodexSettingsStore().selectedTheme() },
    saveSyntaxTheme: { try CodexSettingsStore().save(themeName: $0) },
    loadRawOutputMode: { CodexSettingsStore().rawOutputMode() },
    saveRawOutputMode: { try CodexSettingsStore().save(rawOutputMode: $0) },
    loadKeymap: { try CodexSettingsStore().keymap() },
    saveKeymap: { try CodexSettingsStore().save(keymap: $0) })

  public static let disabled = Self(
    gitDiff: { _ in "" },
    copyToClipboard: { _ in },
    editDraft: { $0 },
    projectFiles: { _ in [] },
    imageFile: { _, _ in nil },
    clipboardImage: { nil },
    remoteImage: { _ in nil },
    localShell: { _, _ in BashExecutionResult(stdout: "", stderr: "", exitCode: 0) },
    syntaxThemes: { SyntaxTheme.builtins },
    loadSyntaxTheme: { SyntaxTheme.named(SyntaxTheme.defaultName)! },
    saveSyntaxTheme: { _ in },
    loadRawOutputMode: { false },
    saveRawOutputMode: { _ in },
    loadKeymap: { .init() },
    saveKeymap: { _ in })
}

private func codexHomeURL() -> URL {
  let environment = ProcessInfo.processInfo.environment
  if let configured = environment["CODEX_SWIFT_HOME"], !configured.isEmpty {
    return URL(fileURLWithPath: configured, isDirectory: true)
  }
  return FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".codex-swift", isDirectory: true)
}

struct CodexSettingsStore: Sendable {
  var home: URL

  init(home: URL = codexHomeURL()) {
    self.home = home
  }

  func availableThemes() -> [SyntaxTheme] {
    var themes = SyntaxTheme.builtins
    let directory = home.appendingPathComponent("themes", isDirectory: true)
    let urls =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    for url in urls where url.pathExtension.lowercased() == "tmtheme" {
      if let theme = try? SyntaxTheme.textMateTheme(at: url) {
        themes.removeAll { $0.name == theme.name }
        themes.append(theme)
      }
    }
    return themes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  func selectedTheme() -> SyntaxTheme {
    let selected = (try? settings())?["syntaxTheme"] as? String
    let themes = availableThemes()
    return themes.first { $0.name == selected }
      ?? SyntaxTheme.named(SyntaxTheme.defaultName)!
  }

  func rawOutputMode() -> Bool {
    (try? settings())?["rawOutputMode"] as? Bool ?? false
  }

  func save(themeName: String) throws {
    try save(key: "syntaxTheme", value: themeName)
  }

  func save(rawOutputMode: Bool) throws {
    try save(key: "rawOutputMode", value: rawOutputMode)
  }

  func keymap() throws -> CodexKeymapConfiguration {
    let root = try settings()
    guard let persisted = root["tuiKeymap"] else { return .init() }
    guard let raw = persisted as? [String: Any] else {
      throw SystemServiceError.invalidSettings("'tuiKeymap' must be a JSON object")
    }
    var supported: [String: Any] = [:]
    for context in CodexKeymapContext.allCases {
      guard let persistedContext = raw[context.rawValue] else { continue }
      guard let values = persistedContext as? [String: Any] else {
        throw SystemServiceError.invalidSettings(
          "'tuiKeymap.\(context.rawValue)' must be a JSON object")
      }
      let actions = Dictionary(
        uniqueKeysWithValues: CodexKeymapAction.allCases
          .filter { $0.context == context }
          .compactMap { action in values[action.rawValue].map { (action.rawValue, $0) } })
      if !actions.isEmpty { supported[context.rawValue] = actions }
    }
    let data = try JSONSerialization.data(withJSONObject: supported)
    return try JSONDecoder().decode(CodexKeymapConfiguration.self, from: data)
  }

  func save(keymap: CodexKeymapConfiguration) throws {
    let root = try settings()
    let existingKeymap = root["tuiKeymap"]
    guard existingKeymap == nil || existingKeymap is [String: Any] else {
      throw SystemServiceError.invalidSettings("'tuiKeymap' must be a JSON object")
    }
    var persisted = existingKeymap as? [String: Any] ?? [:]
    let encoded = try JSONEncoder().encode(keymap)
    let replacement = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
    for context in CodexKeymapContext.allCases {
      let existingContext = persisted[context.rawValue]
      guard existingContext == nil || existingContext is [String: Any] else {
        throw SystemServiceError.invalidSettings(
          "'tuiKeymap.\(context.rawValue)' must be a JSON object")
      }
      var values = existingContext as? [String: Any] ?? [:]
      for action in CodexKeymapAction.allCases where action.context == context {
        values.removeValue(forKey: action.rawValue)
      }
      if let replacements = replacement[context.rawValue] as? [String: Any] {
        for (action, bindings) in replacements { values[action] = bindings }
      }
      if values.isEmpty {
        persisted.removeValue(forKey: context.rawValue)
      } else {
        persisted[context.rawValue] = values
      }
    }
    try save(key: "tuiKeymap", value: persisted)
  }

  private func settings() throws -> [String: Any] {
    let destination = home.appendingPathComponent("settings.json")
    guard FileManager.default.fileExists(atPath: destination.path) else { return [:] }
    do {
      let data = try Data(contentsOf: destination)
      guard let settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw SystemServiceError.invalidSettings("settings.json must contain a JSON object")
      }
      return settings
    } catch let error as SystemServiceError {
      throw error
    } catch {
      throw SystemServiceError.invalidSettings(
        "could not read settings.json: \(error.localizedDescription)")
    }
  }

  private func save(key: String, value: Any) throws {
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let destination = home.appendingPathComponent("settings.json")
    let temporary = home.appendingPathComponent("settings-" + UUID().uuidString + ".tmp")
    var settings = try settings()
    settings[key] = value
    let data = try JSONSerialization.data(
      withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: temporary, options: .atomic)
    if FileManager.default.fileExists(atPath: destination.path) {
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: destination)
    }
  }
}

public enum SystemServiceError: Error, LocalizedError, Sendable {
  case notGitRepository
  case commandFailed(String, Int32, String)
  case remoteImageFailed(String)
  case externalEditor(String)
  case invalidSettings(String)

  public var errorDescription: String? {
    switch self {
    case .notGitRepository: "`/diff` — not inside a git repository"
    case .commandFailed(let command, let status, let message):
      "\(command) failed with status \(status)\(message.isEmpty ? "" : ": \(message)")"
    case .remoteImageFailed(let reason): "Remote image failed: \(reason)"
    case .externalEditor(let reason): reason
    case .invalidSettings(let reason): "Invalid settings.json: \(reason). Fix the file and retry."
    }
  }
}

private struct CommandOutput: Sendable {
  var status: Int32
  var stdout: Data
  var stderr: Data
}

func runExternalEditor(
  seed: String, environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> String {
  guard
    let raw = [environment["VISUAL"], environment["EDITOR"]]
      .compactMap({ $0?.isEmpty == false ? $0 : nil }).first
  else {
    throw SystemServiceError.externalEditor(
      "Cannot open external editor: set $VISUAL or $EDITOR before starting Codex.")
  }
  let command = try splitEditorCommand(raw)
  guard let program = command.first else {
    throw SystemServiceError.externalEditor("Failed to open editor: editor command is empty")
  }

  let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
    "codex-swift-editor-\(UUID().uuidString).md")
  defer { try? FileManager.default.removeItem(at: temporary) }
  try Data(seed.utf8).write(to: temporary, options: .atomic)

  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = [program] + command.dropFirst() + [temporary.path]
  process.standardInput = FileHandle.standardInput
  process.standardOutput = FileHandle.standardOutput
  process.standardError = FileHandle.standardError
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    throw SystemServiceError.externalEditor(
      "Failed to open editor: editor exited with status \(process.terminationStatus)")
  }
  return try String(contentsOf: temporary, encoding: .utf8)
}

func splitEditorCommand(_ raw: String) throws -> [String] {
  var words: [String] = []
  var word = ""
  var quote: Character?
  var escaping = false
  var hasWord = false

  func appendWord() {
    guard hasWord else { return }
    words.append(word)
    word = ""
    hasWord = false
  }

  for character in raw {
    if escaping {
      word.append(character)
      hasWord = true
      escaping = false
    } else if character == "\\", quote != "'" {
      escaping = true
      hasWord = true
    } else if let activeQuote = quote {
      if character == activeQuote {
        quote = nil
      } else {
        word.append(character)
        hasWord = true
      }
    } else if character == "'" || character == "\"" {
      quote = character
      hasWord = true
    } else if character.isWhitespace {
      appendWord()
    } else {
      word.append(character)
      hasWord = true
    }
  }
  guard quote == nil, !escaping else {
    throw SystemServiceError.externalEditor("Failed to open editor: failed to parse editor command")
  }
  appendWord()
  return words
}

private func computeGitDiff(directory: String) throws -> String {
  let inside = try run(
    ["git", "rev-parse", "--is-inside-work-tree"], directory: directory,
    acceptedStatuses: [0])
  guard
    String(decoding: inside.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      == "true"
  else { throw SystemServiceError.notGitRepository }

  let safety = [
    "-c", "core.hooksPath=/dev/null", "-c", "diff.external=", "-c", "core.fsmonitor=false",
  ]
  let diffArguments =
    [
      "git"
    ] + safety + [
      "diff", "--no-textconv", "--no-ext-diff", "--submodule=short",
      "--ignore-submodules=dirty", "--color=never",
    ]
  let tracked = try run(diffArguments, directory: directory, acceptedStatuses: [0, 1])
  let untracked = try run(
    ["git"] + safety + ["ls-files", "--others", "--exclude-standard", "-z"],
    directory: directory, acceptedStatuses: [0])
  let paths = untracked.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
  var result = String(decoding: tracked.stdout, as: UTF8.self)
  for path in paths {
    let output = try run(
      ["git"] + safety + [
        "diff", "--no-textconv", "--no-ext-diff", "--no-index", "--color=never", "--",
        "/dev/null", path,
      ], directory: directory, acceptedStatuses: [0, 1])
    result += String(decoding: output.stdout, as: UTF8.self)
  }
  return result.isEmpty ? "No changes." : result
}

private func listProjectFiles(directory: String) throws -> [String] {
  let output = try run(
    [
      "git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "ls-files",
      "--cached", "--others", "--exclude-standard", "-z",
    ], directory: directory, acceptedStatuses: [0, 128])
  if output.status == 0 {
    return Array(
      Set(output.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
    ).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  guard
    let enumerator = FileManager.default.enumerator(
      at: URL(fileURLWithPath: directory),
      includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants])
  else { return [] }
  var files: [String] = []
  for case let url as URL in enumerator {
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
    if values?.isDirectory == true,
      [".build", "node_modules", "Pods"].contains(url.lastPathComponent)
    {
      enumerator.skipDescendants()
    } else if values?.isRegularFile == true {
      var relative = String(url.path.dropFirst(directory.count))
      if relative.hasPrefix("/") { relative.removeFirst() }
      files.append(relative)
    }
  }
  return files.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
}

private func loadImageFile(
  pastedPath: String, directory: String
) throws -> CodexImageAttachment? {
  var path = pastedPath.trimmingCharacters(in: .whitespacesAndNewlines)
  if path.count >= 2,
    (path.hasPrefix("\"") && path.hasSuffix("\""))
      || (path.hasPrefix("'") && path.hasSuffix("'"))
  {
    path.removeFirst()
    path.removeLast()
  }
  if path.hasPrefix("~/") {
    path = FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst())
  } else if !path.hasPrefix("/") {
    path = URL(fileURLWithPath: directory).appendingPathComponent(path).path
  }
  let mimeType: String
  switch URL(fileURLWithPath: path).pathExtension.lowercased() {
  case "png": mimeType = "image/png"
  case "jpg", "jpeg": mimeType = "image/jpeg"
  case "gif": mimeType = "image/gif"
  case "webp": mimeType = "image/webp"
  default: return nil
  }
  var isDirectory: ObjCBool = false
  guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
    !isDirectory.boolValue
  else { return nil }
  return try normalizedAttachment(
    data: Data(contentsOf: URL(fileURLWithPath: path)), fallbackMimeType: mimeType,
    name: URL(fileURLWithPath: path).lastPathComponent)
}

@MainActor
private func clipboardImageFromPasteboard() throws -> CodexImageAttachment? {
  #if canImport(AppKit)
    let pasteboard = NSPasteboard.general
    if let png = pasteboard.data(forType: .png) {
      return try normalizedAttachment(
        data: png, fallbackMimeType: "image/png", name: "clipboard.png")
    }
    if let tiff = pasteboard.data(forType: .tiff),
      let representation = NSBitmapImageRep(data: tiff),
      let png = representation.representation(using: .png, properties: [:])
    {
      return try normalizedAttachment(
        data: png, fallbackMimeType: "image/png", name: "clipboard.png")
    }
  #endif
  return nil
}

private func loadRemoteImage(_ pastedValue: String) async throws -> CodexImageAttachment? {
  let value = pastedValue.trimmingCharacters(in: .whitespacesAndNewlines)
  if value.lowercased().hasPrefix("data:image/"),
    let comma = value.firstIndex(of: ","),
    value[..<comma].lowercased().hasSuffix(";base64"),
    let data = Data(base64Encoded: String(value[value.index(after: comma)...]))
  {
    let header = value[value.index(value.startIndex, offsetBy: 5)..<comma]
    let mimeType = String(header.split(separator: ";", maxSplits: 1)[0])
    return try normalizedAttachment(
      data: data, fallbackMimeType: mimeType, name: "pasted-image")
  }
  guard !value.contains(where: \Character.isWhitespace), let url = URL(string: value),
    let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
  else { return nil }

  var request = URLRequest(url: url, timeoutInterval: 30)
  request.setValue("codex-swift/0.1", forHTTPHeaderField: "User-Agent")
  let (data, response) = try await URLSession.shared.data(for: request)
  guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode)
  else { throw SystemServiceError.remoteImageFailed("server returned a non-success response") }
  guard data.count <= 100 * 1_024 * 1_024 else {
    throw SystemServiceError.remoteImageFailed("download exceeds the 100 MiB image limit")
  }
  let mimeType = response.mimeType ?? "application/octet-stream"
  guard mimeType.lowercased().hasPrefix("image/") else { return nil }
  let name = url.lastPathComponent.isEmpty ? "remote-image" : url.lastPathComponent
  return try normalizedAttachment(data: data, fallbackMimeType: mimeType, name: name)
}

private func normalizedAttachment(
  data: Data, fallbackMimeType: String, name: String
) throws -> CodexImageAttachment {
  let normalized = try ImageNormalizer.normalize(data)
  guard let bytes = Data(base64Encoded: normalized.content.data) else {
    throw SystemServiceError.remoteImageFailed("KWWK returned invalid normalized image data")
  }
  return CodexImageAttachment(
    data: bytes,
    mimeType: normalized.content.mimeType.isEmpty
      ? fallbackMimeType : normalized.content.mimeType,
    name: name)
}

private func run(
  _ arguments: [String], directory: String, acceptedStatuses: Set<Int32>
) throws -> CommandOutput {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = arguments
  process.currentDirectoryURL = URL(fileURLWithPath: directory)
  let stdout = Pipe()
  let stderr = Pipe()
  process.standardOutput = stdout
  process.standardError = stderr
  try process.run()
  let out = stdout.fileHandleForReading.readDataToEndOfFile()
  let error = stderr.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard acceptedStatuses.contains(process.terminationStatus) else {
    throw SystemServiceError.commandFailed(
      arguments.joined(separator: " "), process.terminationStatus,
      String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
  }
  return CommandOutput(status: process.terminationStatus, stdout: out, stderr: error)
}
