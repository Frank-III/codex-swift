import CodexTUI
import Darwin
import Foundation
import Ratatui

@main
struct CodexBenchmarkMain {
  private struct CycleResult {
    var insertionCount: Int
    var insertedRows: Int
  }

  @MainActor
  static func main() async throws {
    let options = parseOptions(Array(CommandLine.arguments.dropFirst()))
    let width = options.width
    let height = options.height
    let size = Size(width: width, height: height)
    let rssAtLaunch = residentBytes()

    let generationStart = now()
    let application = CodexLargeSessionFixture.makeApplication(turns: options.turns)
    let generationMilliseconds = milliseconds(since: generationStart)
    let fixtureSummary = CodexLargeSessionFixture.Summary(
      turns: options.turns,
      entries: application.model.entries.count,
      sourceBytes: sourceBytes(in: application.model.entries))
    let rssAfterFixture = residentBytes()

    var runtime = InlineDocumentRuntime<String>()
    var terminal = try Terminal(backend: TestBackend(width: width, height: height))

    let coldStart = now()
    let cold = try renderCycle(
      application: application, size: size, runtime: &runtime, terminal: &terminal)
    let coldMilliseconds = milliseconds(since: coldStart)
    let rssAfterCold = residentBytes()

    var interactionSamples: [Double] = []
    interactionSamples.reserveCapacity(options.iterations)
    for iteration in 0..<options.iterations {
      let event: TerminalEvent =
        iteration.isMultiple(of: 2)
        ? .key(KeyEvent(.character("x")))
        : .key(KeyEvent(.backspace))
      let start = now()
      _ = await application.update(event)
      _ = try renderCycle(
        application: application, size: size, runtime: &runtime, terminal: &terminal)
      interactionSamples.append(milliseconds(since: start))
    }
    let rssAfterInteractions = residentBytes()

    application.model.entries.append(
      TranscriptEntry(
        id: "benchmark-appended-user",
        content: .user("Please verify one more incremental update without replaying old history.")))
    application.model.entries.append(
      TranscriptEntry(
        id: "benchmark-appended-assistant",
        content: .assistant(
          """
          Verified the incremental path. Only these newly appended semantic blocks should produce native
          history insertions; the earlier session remains stable and should not be re-emitted.
          """,
          streaming: false)))
    let appendStart = now()
    let append = try renderCycle(
      application: application, size: size, runtime: &runtime, terminal: &terminal)
    let appendMilliseconds = milliseconds(since: appendStart)

    let reflowSize = Size(width: options.reflowWidth, height: height)
    var reflowTerminal = try Terminal(
      backend: TestBackend(width: reflowSize.width, height: reflowSize.height))
    let reflowStart = now()
    let reflow = try renderCycle(
      application: application, size: reflowSize, runtime: &runtime, terminal: &reflowTerminal)
    let reflowMilliseconds = milliseconds(since: reflowStart)
    let rssAfterReflow = residentBytes()

    _ = await application.update(.key(KeyEvent(.character("t"), modifiers: [.control])))
    let pagerCache: (rows: Int, width: Int?) =
      if case .transcript(let pager) =
        application.model.overlay
      {
        (pager.cachedTranscriptLines?.count ?? 0, pager.cachedWidth)
      } else {
        (0, nil)
      }
    let pagerCacheWidth = pagerCache.width.map(String.init) ?? "none"
    var pagerTerminal = try Terminal(
      backend: TestBackend(width: reflowSize.width, height: reflowSize.height))
    let pagerOpenStart = now()
    _ = try pagerTerminal.draw { frame in frame.render(application.body) }
    let pagerOpenMilliseconds = milliseconds(since: pagerOpenStart)
    if case .transcript(var pager) = application.model.overlay {
      pager.scrollUp()
      application.model.overlay = .transcript(pager)
    }
    let pagerScrollStart = now()
    _ = try pagerTerminal.draw { frame in frame.render(application.body) }
    let pagerScrollMilliseconds = milliseconds(since: pagerScrollStart)
    let rssAfterPager = residentBytes()
    application.model.overlay = nil

    print("Codex large-session benchmark (release builds recommended)")
    print(
      "  fixture:        \(fixtureSummary.turns) turns, \(fixtureSummary.entries) entries, \(formatBytes(fixtureSummary.sourceBytes)) source"
    )
    print(
      "  viewport:       \(options.width)x\(options.height), reflow width \(options.reflowWidth)")
    print("  generation:     \(formatMilliseconds(generationMilliseconds))")
    print(
      "  cold frame:     \(formatMilliseconds(coldMilliseconds)), \(cold.insertedRows) history rows in \(cold.insertionCount) insertions"
    )
    print(
      "  key + frame:    p50 \(formatMilliseconds(percentile(interactionSamples, 0.50))), p95 \(formatMilliseconds(percentile(interactionSamples, 0.95))), max \(formatMilliseconds(interactionSamples.max() ?? 0)) over \(options.iterations) events"
    )
    print(
      "  append frame:   \(formatMilliseconds(appendMilliseconds)), \(append.insertedRows) new rows in \(append.insertionCount) insertions"
    )
    print(
      "  width reflow:   \(formatMilliseconds(reflowMilliseconds)), \(reflow.insertedRows) replay rows"
    )
    print(
      "  pager cache:    \(pagerCache.rows) rows at width \(pagerCacheWidth)"
    )
    print("  pager open:     \(formatMilliseconds(pagerOpenMilliseconds))")
    print("  pager scroll:   \(formatMilliseconds(pagerScrollMilliseconds))")
    print("  RSS launch:     \(formatBytes(rssAtLaunch))")
    print(
      "  RSS fixture:    \(formatBytes(rssAfterFixture)) (+\(formatBytes(max(0, rssAfterFixture - rssAtLaunch))))"
    )
    print(
      "  RSS cold:       \(formatBytes(rssAfterCold)) (+\(formatBytes(max(0, rssAfterCold - rssAfterFixture))))"
    )
    print("  RSS interaction:\(formatBytes(rssAfterInteractions))")
    print("  RSS reflow:     \(formatBytes(rssAfterReflow))")
    print("  RSS pager:      \(formatBytes(rssAfterPager))")

    let p95 = percentile(interactionSamples, 0.95)
    if p95 <= 16.7 {
      print("  verdict:        responsive at 60 Hz budget (p95 <= 16.7 ms)")
    } else if p95 <= 50 {
      print("  verdict:        usable, but misses a 60 Hz response budget")
    } else {
      print("  verdict:        lag is likely visible during ordinary editing")
    }
  }

  @MainActor
  private static func renderCycle(
    application: CodexApplication,
    size: Size,
    runtime: inout InlineDocumentRuntime<String>,
    terminal: inout Terminal<TestBackend>
  ) throws -> CycleResult {
    _ = application.desiredInlineViewportHeight(size: size)
    let document = application.inlineDocument(size: size)
    let body = application.body
    let insertions = document.map { runtime.reconcile($0, width: size.width) } ?? []
    _ = try terminal.draw { frame in
      frame.render(body)
    }
    return CycleResult(
      insertionCount: insertions.count,
      insertedRows: insertions.reduce(0) { $0 + $1.text.lines.count })
  }

  private struct Options {
    var turns = 1_000
    var iterations = 100
    var width = 120
    var height = 22
    var reflowWidth = 88
  }

  private static func parseOptions(_ arguments: [String]) -> Options {
    var options = Options()
    var index = 0
    while index < arguments.count {
      let value = arguments[index]
      let next = index + 1 < arguments.count ? Int(arguments[index + 1]) : nil
      switch value {
      case "--turns" where next != nil:
        options.turns = max(0, next!)
        index += 2
      case "--iterations" where next != nil:
        options.iterations = max(1, next!)
        index += 2
      case "--width" where next != nil:
        options.width = max(1, next!)
        index += 2
      case "--height" where next != nil:
        options.height = max(1, next!)
        index += 2
      case "--reflow-width" where next != nil:
        options.reflowWidth = max(1, next!)
        index += 2
      default:
        index += 1
      }
    }
    return options
  }

  private static func sourceBytes(in entries: [TranscriptEntry]) -> Int {
    entries.reduce(into: 0) { total, entry in
      total += String(describing: entry.content).utf8.count
    }
  }

  private static func now() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
  }

  private static func milliseconds(since start: UInt64) -> Double {
    Double(now() - start) / 1_000_000
  }

  private static func percentile(_ values: [Double], _ quantile: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * quantile).rounded())))
    return sorted[index]
  }

  private static func residentBytes() -> Int {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
      }
    }
    return result == KERN_SUCCESS ? Int(info.resident_size) : 0
  }

  private static func formatBytes(_ bytes: Int) -> String {
    let value = Double(bytes)
    if bytes >= 1_073_741_824 { return String(format: "%.2f GiB", value / 1_073_741_824) }
    if bytes >= 1_048_576 { return String(format: "%.1f MiB", value / 1_048_576) }
    if bytes >= 1_024 { return String(format: "%.1f KiB", value / 1_024) }
    return "\(bytes) B"
  }

  private static func formatMilliseconds(_ value: Double) -> String {
    String(format: "%.2f ms", value)
  }
}
