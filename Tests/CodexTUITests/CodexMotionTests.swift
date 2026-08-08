import TermLoom
import Testing

@testable import CodexTUI

@Suite struct CodexMotionTests {
  @Test func maxAndUltraUsePersistentTierAccents() {
    let max = CodexMotion.promptSpan(reasoningEffort: "max")
    let ultra = CodexMotion.promptSpan(reasoningEffort: "ultra")
    let high = CodexMotion.promptSpan(reasoningEffort: "high")

    #expect(max.content == "›")
    #expect(max.style.foreground == .rgb(255, 178, 66))
    #expect(ultra.content == "»")
    #expect(ultra.style.foreground == .rgb(186, 130, 255))
    #expect(high == Span("›", style: .init(modifiers: [.bold])))
  }

  @Test func ignitionStylesNeverRepeatImmediately() {
    for style in CodexIgnitionStyle.allCases {
      #expect(CodexMotion.nextIgnitionStyle(after: style) != style)
    }
  }

  @Test func maxFooterTransitionAssemblesTheTierLabel() {
    let animation = CodexEffortAnimationFrame(
      tier: .max, style: .wave, elapsedMilliseconds: 1_320,
      previousReasoningEffort: "high")
    let line = CodexMotion.effortFooterLine(
      animation: animation, current: Line("gpt max"), previous: Line("gpt high"), width: 30)

    #expect(line.content.contains("M A X"))
  }

  @Test func ignitionPaintsBackgroundWithoutReplacingDraftGlyphs() {
    let area = Rect(x: 0, y: 0, width: 40, height: 3)
    var buffer = Buffer(area: area)
    buffer.setString("› keep my draft", at: Position(x: 0, y: 1))
    let before = buffer.lines()
    let animation = CodexEffortAnimationFrame(
      tier: .ultra, style: .wave, elapsedMilliseconds: 420,
      previousReasoningEffort: "high")

    CodexMotion.paintIgnition(animation, in: area, into: &buffer)

    #expect(buffer.lines() == before)
    #expect(area.positions().contains { buffer[$0].style.background != nil })
  }
}
