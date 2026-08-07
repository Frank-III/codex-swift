import Foundation

/// Source-backed state for one streaming Markdown response.
///
/// This mirrors upstream Codex's newline-gated two-region controller:
/// `codex-rs/tui/src/markdown_stream.rs` commits only complete source lines, while
/// `codex-rs/tui/src/streaming/controller.rs` divides those lines into an append-only stable prefix
/// and a mutable tail. Pipe-table candidates are held using the state machine from
/// `codex-rs/tui/src/streaming/table_holdback.rs` so later rows may reshape earlier columns.
public struct CodexStreamingMarkdown: Hashable, Sendable {
  public private(set) var receivedSource: String
  public private(set) var committedSource: String
  public private(set) var pendingSource: String
  public private(set) var stableSource: String
  public private(set) var mutableTailSource: String

  private var scanner: TableHoldbackScanner

  public init() {
    receivedSource = ""
    committedSource = ""
    pendingSource = ""
    stableSource = ""
    mutableTailSource = ""
    scanner = TableHoldbackScanner()
  }

  /// Source currently safe to display. An unterminated source line is intentionally excluded.
  public var visibleSource: String { stableSource + mutableTailSource }

  public var hasMutableTail: Bool { !mutableTailSource.isEmpty }

  /// Accept the provider's latest accumulated response snapshot.
  ///
  /// KWWK message updates carry the full partial message, rather than only a delta. Append-only
  /// snapshots are reduced to their suffix. A provider rewrite resets and deterministically replays
  /// the source instead of mixing incompatible prefixes.
  public mutating func update(fullSource: String) {
    if fullSource.hasPrefix(receivedSource) {
      let delta = String(fullSource.dropFirst(receivedSource.count))
      receivedSource = fullSource
      push(delta: delta)
    } else {
      reset()
      receivedSource = fullSource
      push(delta: fullSource)
    }
  }

  /// Flush the final canonical source, including a last line without a newline.
  public mutating func finalize(fullSource: String? = nil) -> String {
    if let fullSource { update(fullSource: fullSource) }
    stableSource = receivedSource
    mutableTailSource = ""
    committedSource = receivedSource
    pendingSource = ""
    return receivedSource
  }

  private mutating func push(delta: String) {
    guard !delta.isEmpty else { return }
    pendingSource += delta
    guard let newline = pendingSource.lastIndex(of: "\n") else { return }

    let commitEnd = pendingSource.index(after: newline)
    let completed = String(pendingSource[..<commitEnd])
    pendingSource = String(pendingSource[commitEnd...])
    committedSource += completed
    scanner.push(completed)
    partitionCommittedSource()
  }

  private mutating func partitionCommittedSource() {
    guard let holdbackStart = scanner.holdbackStart else {
      stableSource = committedSource
      mutableTailSource = ""
      return
    }
    let boundary = committedSource.utf8.index(
      committedSource.utf8.startIndex,
      offsetBy: min(holdbackStart, committedSource.utf8.count))
    let sourceBoundary = String.Index(boundary, within: committedSource) ?? committedSource.endIndex
    stableSource = String(committedSource[..<sourceBoundary])
    mutableTailSource = String(committedSource[sourceBoundary...])
  }

  private mutating func reset() {
    self = CodexStreamingMarkdown()
  }
}

private struct TableHoldbackScanner: Hashable, Sendable {
  private enum FenceKind: Hashable, Sendable {
    case outside
    case markdown(marker: Character, count: Int)
    case other(marker: Character, count: Int)
  }

  private struct PreviousLine: Hashable, Sendable {
    var sourceStart: Int
    var fenceKind: FenceKind
    var isHeader: Bool

    var scansTables: Bool {
      if case .other = fenceKind { false } else { true }
    }
  }

  private var sourceOffset = 0
  private var fenceKind: FenceKind = .outside
  private var previousLine: PreviousLine?
  private var pendingHeaderStart: Int?
  private var confirmedTableStart: Int?

  var holdbackStart: Int? { confirmedTableStart ?? pendingHeaderStart }

  mutating func push(_ source: String) {
    for line in source.split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
      pushLine(String(line), sourceLength: line.utf8.count + 1)
    }
  }

  private mutating func pushLine(_ line: String, sourceLength: Int) {
    let sourceStart = sourceOffset
    let scansTables = if case .other = fenceKind { false } else { true }
    let candidate = scansTables ? tableCells(line) : nil
    let isHeader = candidate != nil
    let isDelimiter = candidate?.allSatisfy(isDelimiterCell) == true

    if confirmedTableStart == nil,
      let previousLine,
      previousLine.scansTables,
      scansTables,
      previousLine.isHeader,
      isDelimiter
    {
      confirmedTableStart = previousLine.sourceStart
      pendingHeaderStart = nil
    }

    if confirmedTableStart == nil, !line.trimmingCharacters(in: .whitespaces).isEmpty {
      pendingHeaderStart = scansTables && isHeader && !isDelimiter ? sourceStart : nil
    }

    previousLine = PreviousLine(
      sourceStart: sourceStart, fenceKind: fenceKind, isHeader: isHeader && !isDelimiter)
    advanceFence(with: line)
    sourceOffset += sourceLength
  }

  private mutating func advanceFence(with line: String) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard let marker = trimmed.first, marker == "`" || marker == "~" else { return }
    let count = trimmed.prefix(while: { $0 == marker }).count
    guard count >= 3 else { return }

    switch fenceKind {
    case .outside:
      let suffix = trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).lowercased()
      fenceKind =
        suffix.isEmpty || ["md", "markdown"].contains(suffix)
        ? .markdown(marker: marker, count: count)
        : .other(marker: marker, count: count)
    case .markdown(let openingMarker, let openingCount),
      .other(let openingMarker, let openingCount):
      if marker == openingMarker, count >= openingCount { fenceKind = .outside }
    }
  }
}

private func tableCells(_ source: String) -> [String]? {
  let stripped = stripBlockquotePrefix(source).trimmingCharacters(in: .whitespaces)
  guard stripped.contains("|") else { return nil }
  var body = stripped
  if body.hasPrefix("|") { body.removeFirst() }
  if body.hasSuffix("|") { body.removeLast() }
  let cells = body.split(separator: "|", omittingEmptySubsequences: false).map {
    $0.trimmingCharacters(in: .whitespaces)
  }
  return cells.count > 1 ? cells : nil
}

private func isDelimiterCell(_ cell: String) -> Bool {
  let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
  return core.count >= 3 && core.allSatisfy { $0 == "-" }
}

private func stripBlockquotePrefix(_ source: String) -> String {
  var remainder = source[...]
  while true {
    remainder = remainder.drop(while: { $0 == " " || $0 == "\t" })
    guard remainder.first == ">" else { return String(remainder) }
    remainder = remainder.dropFirst()
    if remainder.first == " " { remainder = remainder.dropFirst() }
  }
}
