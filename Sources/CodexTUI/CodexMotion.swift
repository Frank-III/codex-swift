import Foundation
import TermLoom

enum CodexEffortTier: String, Hashable, Sendable {
  case max
  case ultra

  init?(reasoningEffort: String) {
    self.init(rawValue: reasoningEffort.lowercased())
  }

  var label: String { rawValue.uppercased() }
  var promptGlyph: String { self == .ultra ? "»" : "›" }
  var accent: Color { self == .ultra ? .rgb(186, 130, 255) : .rgb(255, 178, 66) }
  var hues: [(UInt8, UInt8, UInt8)] {
    switch self {
    case .max: [(255, 178, 66), (255, 214, 120), (255, 120, 60)]
    case .ultra: [(186, 130, 255), (255, 120, 220), (120, 170, 255)]
    }
  }
}

enum CodexIgnitionStyle: CaseIterable, Hashable, Sendable {
  case wave
  case aurora
  case pulse
}

struct CodexEffortAnimationFrame: Hashable, Sendable {
  var tier: CodexEffortTier
  var style: CodexIgnitionStyle
  var elapsedMilliseconds: Int
  var previousReasoningEffort: String

  var isFinished: Bool { elapsedMilliseconds >= CodexMotion.totalDurationMilliseconds }
}

enum CodexMotion {
  static let framesPerSecond: UInt64 = 30
  static let totalDurationMilliseconds = 2_500

  static func nextIgnitionStyle(after previous: CodexIgnitionStyle?) -> CodexIgnitionStyle {
    let choices = CodexIgnitionStyle.allCases.filter { $0 != previous }
    return choices.randomElement() ?? .wave
  }

  static func promptSpan(reasoningEffort: String) -> Span {
    guard let tier = CodexEffortTier(reasoningEffort: reasoningEffort) else {
      return Span("›", style: .init(modifiers: [.bold]))
    }
    return Span(tier.promptGlyph, style: .init(foreground: tier.accent, modifiers: [.bold]))
  }

  static func paintIgnition(
    _ animation: CodexEffortAnimationFrame, in area: Rect, into buffer: inout Buffer
  ) {
    guard !area.isEmpty else { return }
    let elapsed = Double(animation.elapsedMilliseconds) / 1_000
    let ignitionDuration: Double =
      switch (animation.style, animation.tier) {
      case (.wave, .max): 1.0
      case (.wave, .ultra): 1.3
      case (.aurora, .max): 1.3
      case (.aurora, .ultra): 1.6
      case (.pulse, .max): 0.9
      case (.pulse, .ultra): 1.25
      }
    guard elapsed > 0, elapsed < ignitionDuration else { return }

    for localX in 0..<area.width {
      let x = Double(localX)
      let width = Double(area.width)
      let strength: Double
      let hueIndex: Int
      switch animation.style {
      case .wave:
        let progress = ((elapsed - 0.10) / (animation.tier == .ultra ? 0.70 : 0.75))
          .clamped(to: 0...1)
        let center = easeInOut(progress) * (width + 18) - 9
        strength = crest(abs(x - center) / 9)
        hueIndex = 0
      case .aurora:
        let centers: [(Double, Double, Int)] =
          animation.tier == .ultra
          ? [(0.35, 0.15, 0), (-0.50, 0.60, 1), (0.75, 0.35, 2)]
          : [(0.35, 0.15, 0), (-0.50, 0.60, 1)]
        let samples = centers.map { speed, phase, index in
          let center = (0.5 + 0.38 * sin(2 * Double.pi * (speed * elapsed + phase))) * width
          return (crest(abs(x - center) / max(4, width * 0.22)), index)
        }
        let strongest = samples.max { $0.0 < $1.0 } ?? (0, 0)
        let envelope = min(elapsed / 0.25, (ignitionDuration - elapsed) / 0.40).clamped(to: 0...1)
        strength = strongest.0 * envelope * 0.82
        hueIndex = strongest.1
      case .pulse:
        let progress = ((elapsed - 0.10) / (animation.tier == .ultra ? 0.55 : 0.60))
          .clamped(to: 0...1)
        let radius = (1 - pow(1 - progress, 3)) * (width / 2 + 9)
        strength = crest(abs(abs(x - width / 2) - radius) / 4.5) * (1 - 0.6 * progress)
        hueIndex = 0
      }
      guard strength > 0.01 else { continue }
      let hue = animation.tier.hues[hueIndex]
      let background = (63.0, 67.0, 74.0)
      let alpha = min(0.55, strength * 0.55)
      let color = Color.rgb(
        blend(Double(hue.0), background.0, alpha),
        blend(Double(hue.1), background.1, alpha),
        blend(Double(hue.2), background.2, alpha))
      for localY in 0..<area.height {
        let position = Position(x: area.x + localX, y: area.y + localY)
        guard var cell = buffer.cell(at: position) else { continue }
        cell.style.background = color
        buffer[position] = cell
      }
    }
  }

  static func effortFooterLine(
    animation: CodexEffortAnimationFrame, current: Line, previous: Line, width: Int
  ) -> Line {
    let elapsed = animation.elapsedMilliseconds
    if elapsed < 620 {
      let progress = Double(elapsed) / 620
      let offset = Int((Double(width) * pow(progress, 3)).rounded())
      return Line {
        Span(String(repeating: " ", count: offset))
        for span in previous.spans { span }
      }
    }
    if elapsed < 2_020 {
      let labelElapsed = elapsed - 620
      let assemble = min(1, Double(labelElapsed) / 700)
      let letters = Array(animation.tier.label)
      let compactWidth = max(1, letters.count * 2 - 1)
      let spread = Int((Double(max(0, width - compactWidth)) * (1 - easeOut(assemble))).rounded())
      let gap = max(1, 1 + spread / max(1, letters.count - 1))
      let labelWidth = letters.count + gap * max(0, letters.count - 1)
      let left = max(0, (width - labelWidth) / 2)
      return Line {
        Span(String(repeating: " ", count: left))
        for (index, letter) in letters.enumerated() {
          Span(String(letter), style: .init(foreground: animation.tier.accent, modifiers: [.bold]))
          if index + 1 < letters.count { Span(String(repeating: " ", count: gap)) }
        }
      }
    }
    return current
  }

  private static func crest(_ distance: Double) -> Double {
    distance >= 1 ? 0 : 0.5 * (1 + cos(Double.pi * distance))
  }

  private static func easeInOut(_ value: Double) -> Double {
    value < 0.5 ? 4 * value * value * value : 1 - pow(-2 * value + 2, 3) / 2
  }

  private static func easeOut(_ value: Double) -> Double {
    1 - pow(1 - value.clamped(to: 0...1), 3)
  }

  private static func blend(_ foreground: Double, _ background: Double, _ alpha: Double) -> UInt8 {
    UInt8(clamping: Int((foreground * alpha + background * (1 - alpha)).rounded()))
  }
}

extension Comparable {
  fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}
