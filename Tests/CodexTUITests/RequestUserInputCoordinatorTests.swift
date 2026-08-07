import KWWKAI
import Ratatui
import Testing

@testable import CodexTUI

@MainActor
@Suite struct RequestUserInputCoordinatorTests {
  @Test func inactiveThreadQuestionWaitsUntilThatThreadIsVisible() async throws {
    let model = CodexSessionModel(snapshot: CodexSnapshot())
    let coordinator = RequestUserInputCoordinator(model: model)
    var isActive = false
    let task = Task {
      try await coordinator.request(
        id: "inactive-question",
        arguments: .object([
          "questions": .array([
            .object([
              "id": .string("q"), "header": .string("Choice"),
              "question": .string("Continue?"),
            ])
          ])
        ]),
        isActive: { isActive })
    }
    await Task.yield()

    #expect(model.overlay == nil)
    isActive = true
    coordinator.refreshPresentation()
    guard case .requestUserInput(let request) = model.overlay else {
      Issue.record("Expected the inactive question after switching threads")
      return
    }
    #expect(request.id == "inactive-question")
    #expect(coordinator.submit(request))
    _ = try await task.value
  }

  @Test func optionAndNotesBecomeStructuredToolAnswers() async throws {
    let model = CodexSessionModel()
    let coordinator = RequestUserInputCoordinator(model: model)
    let result = Task {
      try await coordinator.request(
        id: "request-1",
        arguments: [
          "questions": [
            [
              "id": "area",
              "header": "Area",
              "question": "Where should I start?",
              "options": [
                ["label": "Renderer", "description": "Work on rendering."],
                ["label": "Input", "description": "Work on keyboard input."],
              ],
            ]
          ]
        ])
    }
    await Task.yield()

    guard case .requestUserInput(var request) = model.overlay else {
      Issue.record("Expected request_user_input bottom pane")
      return
    }
    request.answers[0].selection.select(1, itemCount: 2)
    request.answers[0].draft = TextFieldState(text: "Preserve Vim bindings")
    request.answers[0].isCommitted = true
    #expect(coordinator.submit(request))

    let answers = try await result.value
    #expect(answers == ["area": ["Input", "user_note: Preserve Vim bindings"]])
    #expect(model.overlay == nil)
  }

  @Test func freeformAnswersAreReturnedWithoutANotePrefix() async throws {
    let model = CodexSessionModel()
    let coordinator = RequestUserInputCoordinator(model: model)
    let result = Task {
      try await coordinator.request(
        id: "request-1",
        arguments: [
          "questions": [
            ["id": "goal", "header": "Goal", "question": "Share details."]
          ]
        ])
    }
    await Task.yield()

    guard case .requestUserInput(var request) = model.overlay else {
      Issue.record("Expected request_user_input bottom pane")
      return
    }
    request.answers[0].draft = TextFieldState(text: "Match Codex exactly")
    request.answers[0].isCommitted = true
    #expect(coordinator.submit(request))
    #expect(try await result.value == ["goal": ["Match Codex exactly"]])
  }
}
