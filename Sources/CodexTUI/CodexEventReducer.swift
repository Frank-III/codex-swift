import Foundation
import KWWKAI
import KWWKAgent

@MainActor
public final class CodexEventReducer {
  public let model: CodexSessionModel

  private var responseID: String?
  private var startedAt: ContinuousClock.Instant?

  public init(model: CodexSessionModel) {
    self.model = model
  }

  public func consume(_ event: AgentEvent) {
    switch event {
    case .agentStart:
      model.isWorking = true
      model.workingLabel = "Working"
      model.elapsedSeconds = 0
      startedAt = .now

    case .agentEnd(_, let summary):
      model.isWorking = false
      model.elapsedSeconds = max(0, summary.durationMs / 1_000)
      finalizeStreamingEntries()
      responseID = nil
      startedAt = nil

    case .turnStart:
      responseID = UUID().uuidString

    case .turnEnd:
      finalizeStreamingEntries()

    case .messageStart(let message):
      if case .assistant = message, responseID == nil {
        responseID = UUID().uuidString
      }

    case .messageUpdate(let message, _):
      updateAssistant(message, streaming: true)
      updateElapsedTime()

    case .messageEnd(let message):
      if case .assistant(let assistant) = message {
        updateAssistant(assistant, streaming: false)
      }

    case .toolExecutionStart(let callID, let name, let arguments):
      upsertTool(
        ToolActivity(
          callID: callID,
          name: displayName(for: name),
          detail: argumentSummary(arguments),
          status: .running,
          presentation: presentation(for: name, arguments: arguments, result: nil)
        ))

    case .toolExecutionUpdate(let callID, let name, let arguments, let result):
      upsertTool(
        ToolActivity(
          callID: callID,
          name: displayName(for: name),
          detail: argumentSummary(arguments),
          output: displayLines(result),
          status: .running,
          presentation: presentation(for: name, arguments: arguments, result: result)
        ))

    case .toolExecutionEnd(let callID, let name, let result, let isError):
      upsertTool(
        ToolActivity(
          callID: callID,
          name: displayName(for: name),
          output: displayLines(result),
          status: isError ? .failed : .succeeded,
          presentation: presentation(
            for: name, arguments: nil, result: result, isError: isError)
        ))

    case .runtimeEvent(let runtimeEvent):
      appendNotice("Background activity: \(runtimeEvent.type)")

    case .compactStart(let count, _):
      model.workingLabel = "Compacting context"
      appendNotice("Compacting \(count) conversation messages…")

    case .compactEnd:
      model.workingLabel = "Working"
      appendNotice("Context compaction finished")

    case .streamRetry(let attempt, let delay, let reason):
      appendNotice("Connection retry \(attempt + 1) in \(formatDelay(delay)): \(reason)")

    case .streamRewind:
      removeStreamingEntries()

    case .verbose:
      break
    }
  }

  private func updateAssistant(_ message: AssistantMessage, streaming: Bool) {
    let id = responseID ?? UUID().uuidString
    responseID = id

    let text = message.content.compactMap { block -> String? in
      if case .text(let content) = block { return content.text }
      return nil
    }.joined()
    let thinking = message.content.compactMap { block -> String? in
      if case .thinking(let content) = block { return content.thinking }
      return nil
    }.joined()

    if !thinking.isEmpty {
      // Providers keep the accumulated reasoning block in every later text snapshot. Once text has
      // started, reasoning is a completed predecessor rather than a still-mutable cell; leaving it
      // marked streaming blocks committed assistant rows behind it for the rest of the turn.
      upsertReasoning(
        id: "\(id)-reasoning", text: thinking, streaming: streaming && text.isEmpty)
    }
    if !text.isEmpty {
      upsertAssistant(id: "\(id)-assistant", text: text, streaming: streaming)
    }
    if let error = message.errorMessage, !error.isEmpty {
      upsert(id: "\(id)-error", content: .error(error))
    }
  }

  private func upsert(id: String, content: TranscriptContent) {
    if let index = model.entries.firstIndex(where: { $0.id == id }) {
      model.entries[index].content = content
    } else {
      model.entries.append(TranscriptEntry(id: id, content: content))
    }
  }

  private func upsertReasoning(id: String, text: String, streaming: Bool) {
    if let index = model.entries.firstIndex(where: { $0.id == id }) {
      if streaming {
        var stream = model.entries[index].streamingMarkdown ?? CodexStreamingMarkdown()
        stream.update(fullSource: text)
        model.entries[index].streamingMarkdown = stream
        model.entries[index].content = .reasoning(
          summary: "Thinking", body: stream.visibleSource, streaming: true)
      } else {
        if var stream = model.entries[index].streamingMarkdown {
          _ = stream.finalize(fullSource: text)
        }
        model.entries[index].streamingMarkdown = nil
        model.entries[index].content = .reasoning(
          summary: "Thinking", body: text, streaming: false)
      }
      return
    }

    if streaming {
      var stream = CodexStreamingMarkdown()
      stream.update(fullSource: text)
      model.entries.append(
        TranscriptEntry(
          id: id,
          content: .reasoning(summary: "Thinking", body: stream.visibleSource, streaming: true),
          streamingMarkdown: stream))
    } else {
      model.entries.append(
        TranscriptEntry(
          id: id, content: .reasoning(summary: "Thinking", body: text, streaming: false)))
    }
  }

  private func upsertAssistant(id: String, text: String, streaming: Bool) {
    if let index = model.entries.firstIndex(where: { $0.id == id }) {
      if streaming {
        var stream = model.entries[index].streamingMarkdown ?? CodexStreamingMarkdown()
        stream.update(fullSource: text)
        model.entries[index].streamingMarkdown = stream
        model.entries[index].content = .assistant(stream.visibleSource, streaming: true)
      } else {
        if var stream = model.entries[index].streamingMarkdown {
          _ = stream.finalize(fullSource: text)
        }
        model.entries[index].streamingMarkdown = nil
        model.entries[index].content = .assistant(text, streaming: false)
      }
      return
    }

    if streaming {
      var stream = CodexStreamingMarkdown()
      stream.update(fullSource: text)
      model.entries.append(
        TranscriptEntry(
          id: id, content: .assistant(stream.visibleSource, streaming: true),
          streamingMarkdown: stream))
    } else {
      model.entries.append(TranscriptEntry(id: id, content: .assistant(text, streaming: false)))
    }
  }

  private func upsertTool(_ tool: ToolActivity) {
    let id = "tool-\(tool.callID)"
    if let index = model.entries.firstIndex(where: { $0.id == id }),
      case .tool(let previous) = model.entries[index].content
    {
      var merged = tool
      if merged.detail.isEmpty { merged.detail = previous.detail }
      if merged.output.isEmpty { merged.output = previous.output }
      if case .generic = merged.presentation { merged.presentation = previous.presentation }
      if case .command(let command, let output, let omitted) = merged.presentation,
        case .command(let previousCommand, let previousOutput, let previousOmitted) =
          previous.presentation
      {
        merged.presentation = .command(
          command: command.isEmpty ? previousCommand : command,
          output: output.isEmpty ? previousOutput : output,
          omittedLineCount: output.isEmpty ? previousOmitted : omitted)
      } else if case .exploration(let action) = merged.presentation,
        case .exploration(let previousAction) = previous.presentation,
        action.subject.isEmpty
      {
        merged.presentation = .exploration(previousAction)
      } else if case .edit(let path, let additions, let deletions, let lines) = merged.presentation,
        case .edit(let previousPath, _, _, _) = previous.presentation,
        path.isEmpty
      {
        merged.presentation = .edit(
          path: previousPath, additions: additions, deletions: deletions, lines: lines)
      } else if case .editFailure(let path, let output) = merged.presentation,
        case .edit(let previousPath, _, _, _) = previous.presentation,
        path.isEmpty
      {
        merged.presentation = .editFailure(path: previousPath, output: output)
      }
      model.entries[index].content = .tool(merged)
    } else {
      model.entries.append(TranscriptEntry(id: id, content: .tool(tool)))
    }
  }

  private func appendNotice(_ text: String) {
    model.entries.append(TranscriptEntry(content: .notice(text)))
  }

  private func finalizeStreamingEntries() {
    for index in model.entries.indices {
      switch model.entries[index].content {
      case .assistant(let text, true):
        if var stream = model.entries[index].streamingMarkdown {
          let finalized = stream.finalize()
          model.entries[index].content = .assistant(finalized, streaming: false)
          model.entries[index].streamingMarkdown = nil
        } else {
          model.entries[index].content = .assistant(text, streaming: false)
        }
      case .reasoning(let summary, let body, true):
        if var stream = model.entries[index].streamingMarkdown {
          let finalized = stream.finalize()
          model.entries[index].content = .reasoning(
            summary: summary, body: finalized, streaming: false)
          model.entries[index].streamingMarkdown = nil
        } else {
          model.entries[index].content = .reasoning(
            summary: summary, body: body, streaming: false)
        }
      default:
        break
      }
    }
  }

  private func removeStreamingEntries() {
    model.entries.removeAll { entry in
      switch entry.content {
      case .assistant(_, true), .reasoning(_, _, true): true
      default: false
      }
    }
  }

  private func updateElapsedTime() {
    guard let startedAt else { return }
    let duration = startedAt.duration(to: .now)
    model.elapsedSeconds = Int(duration.components.seconds)
  }

  private func displayName(for toolName: String) -> String {
    switch toolName.lowercased() {
    case "bash", "shell", "exec_command": "Ran"
    case "read", "read_file": "Read"
    case "write", "write_file", "apply_patch": "Edited"
    case "grep", "search", "rg": "Searched"
    default: toolName
    }
  }

  private func argumentSummary(_ value: JSONValue) -> String {
    if case .object(let object) = value {
      for key in ["command", "cmd", "path", "query", "pattern"] {
        if case .string(let text)? = object[key] { return text }
      }
    }
    return ""
  }

  private func displayLines(_ result: AgentToolResult) -> [String] {
    if let display = result.uiDisplay, !display.isEmpty { return display }
    return result.content.compactMap { block in
      if case .text(let content) = block { return content.text }
      return nil
    }.flatMap { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
      .prefix(8).map { $0 }
  }

  private func presentation(
    for toolName: String, arguments: JSONValue?, result: AgentToolResult?, isError: Bool = false
  ) -> ToolPresentation {
    let name = toolName.lowercased()
    let object: [String: JSONValue]
    if case .object(let value)? = arguments { object = value } else { object = [:] }

    if ["bash", "shell", "exec_command"].contains(name) {
      let command = string(in: object, keys: ["command", "cmd"]) ?? ""
      let allOutput = result.map(rawLines) ?? []
      return .command(
        command: command, output: allOutput, omittedLineCount: 0)
    }

    if ["read", "read_file", "grep", "search", "rg", "find", "ls"].contains(name) {
      let kind: ExplorationActionKind =
        if ["read", "read_file"].contains(name) { .read } else if name == "ls" { .list } else {
          .search
        }
      let subject =
        string(in: object, keys: ["query", "pattern", "glob", "path"])
        ?? argumentSummary(arguments ?? .object([:]))
      let path = string(in: object, keys: ["path"])
      return .exploration(
        ExplorationAction(
          kind: kind, subject: subject,
          path: path == subject || path == "." ? nil : path))
    }

    if ["edit", "write", "write_file", "apply_patch"].contains(name) {
      let path = string(in: object, keys: ["path"]) ?? ""
      if isError {
        return .editFailure(path: path, output: result.map(rawLines) ?? [])
      }
      guard let result, let patch = detailString(result, key: "patch") else {
        return .edit(path: path, additions: 0, deletions: 0, lines: [])
      }
      let parsed = parseUnifiedDiff(patch)
      return .edit(
        path: pathFromPatch(patch) ?? path, additions: parsed.additions,
        deletions: parsed.deletions, lines: parsed.lines)
    }

    return .generic
  }

  private func string(in object: [String: JSONValue], keys: [String]) -> String? {
    for key in keys where object[key] != nil {
      if case .string(let value)? = object[key] { return value }
    }
    return nil
  }

  private func rawLines(_ result: AgentToolResult) -> [String] {
    result.content.compactMap { block in
      if case .text(let content) = block { return content.text }
      return nil
    }.flatMap { text -> [String] in
      guard !text.isEmpty else { return [] }
      var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
      if text.hasSuffix("\n"), lines.last == "" { lines.removeLast() }
      return lines
    }
  }

  private func detailString(_ result: AgentToolResult, key: String) -> String? {
    guard case .object(let details)? = result.details,
      case .string(let value)? = details[key]
    else { return nil }
    return value
  }

  private func pathFromPatch(_ patch: String) -> String? {
    patch.split(separator: "\n").first(where: { $0.hasPrefix("+++ ") }).map {
      String($0.dropFirst(4)).replacingOccurrences(of: "b/", with: "", options: .anchored)
    }
  }

  private func parseUnifiedDiff(_ patch: String) -> (
    lines: [DiffLine], additions: Int, deletions: Int
  ) {
    var lines: [DiffLine] = []
    var additions = 0
    var deletions = 0
    var oldLine = 0
    var newLine = 0
    var sawHunk = false

    for raw in patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
      if raw.hasPrefix("@@") {
        let pieces = raw.split(separator: " ")
        oldLine = pieces.count > 1 ? rangeStart(String(pieces[1])) : 0
        newLine = pieces.count > 2 ? rangeStart(String(pieces[2])) : 0
        if sawHunk { lines.append(DiffLine(lineNumber: nil, kind: .separator, text: "⋮")) }
        sawHunk = true
      } else if sawHunk, raw.hasPrefix("+") {
        lines.append(DiffLine(lineNumber: newLine, kind: .addition, text: String(raw.dropFirst())))
        newLine += 1
        additions += 1
      } else if sawHunk, raw.hasPrefix("-") {
        lines.append(DiffLine(lineNumber: oldLine, kind: .deletion, text: String(raw.dropFirst())))
        oldLine += 1
        deletions += 1
      } else if sawHunk, raw.hasPrefix(" ") {
        lines.append(DiffLine(lineNumber: newLine, kind: .context, text: String(raw.dropFirst())))
        oldLine += 1
        newLine += 1
      }
    }
    return (lines, additions, deletions)
  }

  private func rangeStart(_ range: String) -> Int {
    Int(range.dropFirst().split(separator: ",", maxSplits: 1).first ?? "0") ?? 0
  }

  private func formatDelay(_ milliseconds: UInt64) -> String {
    milliseconds < 1_000
      ? "\(milliseconds)ms"
      : String(format: "%.1fs", Double(milliseconds) / 1_000)
  }
}
