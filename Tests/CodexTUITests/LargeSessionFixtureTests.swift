import CodexTUI
import Testing

@Suite struct LargeSessionFixtureTests {
  @Test func fixtureIsDeterministicAndExercisesRealTranscriptShapes() {
    let first = CodexLargeSessionFixture.makeEntries(turns: 41)
    let second = CodexLargeSessionFixture.makeEntries(turns: 41)

    #expect(first == second)
    #expect(first.count == 208)
    #expect(Set(first.map(\.id)).count == first.count)
    #expect(first.contains { if case .user = $0.content { true } else { false } })
    #expect(first.contains { if case .reasoning = $0.content { true } else { false } })
    #expect(
      first.contains {
        if case .tool(let tool) = $0.content, case .command = tool.presentation {
          true
        } else {
          false
        }
      })
    #expect(
      first.contains {
        if case .tool(let tool) = $0.content, case .edit = tool.presentation {
          true
        } else {
          false
        }
      })
    #expect(first.contains { if case .assistant = $0.content { true } else { false } })
    #expect(first.contains { if case .notice = $0.content { true } else { false } })
  }

  @MainActor
  @Test func populatingFixtureProducesAnIdleInteractiveSession() {
    let application = CodexLargeSessionFixture.makeApplication(turns: 3, directory: "/tmp/project")

    #expect(application.model.entries.count == 15)
    #expect(application.model.directory == "/tmp/project")
    #expect(application.model.model == "gpt-5.6-sol")
    #expect(application.model.reasoningEffort == "medium")
    #expect(!application.model.isWorking)
  }
}
