import Foundation
import KWWKAI
import KWWKAgent

private struct RequestUserInputToolError: LocalizedError {
  var message: String
  var errorDescription: String? { message }
}

@MainActor
public final class RequestUserInputCoordinator {
  private struct Pending {
    var request: RequestUserInputRequest
    var continuation: CheckedContinuation<[String: [String]], Never>
    var cancellationRegistration: CancellationRegistration?
    var isActive: @MainActor () -> Bool
  }

  private let model: CodexSessionModel
  private var pending: [Pending] = []

  public init(model: CodexSessionModel) {
    self.model = model
  }

  public func makeTool(
    isActive: @escaping @MainActor () -> Bool = { true }
  ) -> AgentTool {
    AgentTool(
      name: "request_user_input",
      label: "request_user_input",
      description:
        "Ask the user one to three short questions and wait for their answers. Use options when choices are mutually exclusive.",
      parameters: [
        "type": "object",
        "properties": [
          "questions": [
            "type": "array",
            "minItems": 1,
            "maxItems": 3,
            "items": [
              "type": "object",
              "properties": [
                "id": ["type": "string"],
                "header": ["type": "string"],
                "question": ["type": "string"],
                "options": [
                  "type": "array",
                  "items": [
                    "type": "object",
                    "properties": [
                      "label": ["type": "string"],
                      "description": ["type": "string"],
                    ],
                    "required": ["label", "description"],
                  ],
                ],
              ],
              "required": ["id", "header", "question"],
            ],
          ]
        ],
        "required": ["questions"],
      ],
      execute: { [weak self] callID, arguments, cancellation, _ in
        guard let self else {
          throw RequestUserInputToolError(message: "User input coordinator is unavailable")
        }
        let answers = try await self.request(
          id: callID, arguments: arguments, cancellation: cancellation, isActive: isActive)
        let answerObject = Dictionary(
          uniqueKeysWithValues: answers.map { id, values in
            (id, JSONValue.object(["answers": .array(values.map(JSONValue.string))]))
          })
        let details = JSONValue.object(["answers": .object(answerObject)])
        let data = try JSONEncoder().encode(details)
        return AgentToolResult(
          content: [.text(TextContent(text: String(decoding: data, as: UTF8.self)))],
          details: details,
          uiDisplay: ["Answered \(answers.count) question\(answers.count == 1 ? "" : "s")"])
      })
  }

  func request(
    id: String,
    arguments: JSONValue,
    cancellation: CancellationHandle? = nil,
    isActive: @escaping @MainActor () -> Bool = { true }
  ) async throws -> [String: [String]] {
    let questions = try parseQuestions(arguments)
    if cancellation?.isCancelled == true { return [:] }
    return await withCheckedContinuation { continuation in
      let request = RequestUserInputRequest(id: id, questions: questions)
      pending.append(Pending(request: request, continuation: continuation, isActive: isActive))
      if let cancellation {
        let registration = cancellation.onCancel { [weak self] _ in
          Task { @MainActor [weak self] in self?.cancel(requestID: id) }
        }
        if let index = pending.firstIndex(where: { $0.request.id == id }) {
          pending[index].cancellationRegistration = registration
        }
      }
      presentNextIfNeeded()
    }
  }

  @discardableResult
  public func submit(_ request: RequestUserInputRequest) -> Bool {
    guard let index = pending.firstIndex(where: { $0.request.id == request.id }) else {
      return false
    }
    let answers = Dictionary(
      uniqueKeysWithValues: request.questions.indices.map { questionIndex in
        let question = request.questions[questionIndex]
        let answer = request.answers[questionIndex]
        var values: [String] = []
        if !question.options.isEmpty, answer.isCommitted,
          let selected = answer.selection.selectedIndex,
          question.options.indices.contains(selected)
        {
          values.append(question.options[selected].label)
        }
        let note = answer.draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.isCommitted, !note.isEmpty {
          values.append(question.options.isEmpty ? note : "user_note: \(note)")
        }
        return (question.id, values)
      })
    finish(index: index, answers: answers)
    return true
  }

  public func cancelAll() {
    let requests = pending
    pending.removeAll()
    if case .requestUserInput = model.overlay { model.overlay = nil }
    for request in requests {
      request.cancellationRegistration?.cancel()
      request.continuation.resume(returning: [:])
    }
  }

  public func refreshPresentation() {
    if case .requestUserInput = model.overlay { model.overlay = nil }
    presentNextIfNeeded()
  }

  private func finish(index: Int, answers: [String: [String]]) {
    let request = pending.remove(at: index)
    request.cancellationRegistration?.cancel()
    if case .requestUserInput(let visible) = model.overlay, visible.id == request.request.id {
      model.overlay = nil
    }
    request.continuation.resume(returning: answers)
    presentNextIfNeeded()
  }

  private func cancel(requestID: String) {
    guard let index = pending.firstIndex(where: { $0.request.id == requestID }) else { return }
    finish(index: index, answers: [:])
  }

  private func presentNextIfNeeded() {
    guard model.overlay == nil,
      let request = pending.first(where: { $0.isActive() })?.request
    else { return }
    model.overlay = .requestUserInput(request)
  }

  private func parseQuestions(_ arguments: JSONValue) throws -> [RequestUserInputQuestion] {
    guard case .object(let object) = arguments,
      case .array(let rawQuestions)? = object["questions"],
      (1...3).contains(rawQuestions.count)
    else {
      throw RequestUserInputToolError(message: "request_user_input requires 1 to 3 questions")
    }
    return try rawQuestions.map { value in
      guard case .object(let question) = value,
        case .string(let id)? = question["id"],
        case .string(let header)? = question["header"],
        case .string(let prompt)? = question["question"]
      else {
        throw RequestUserInputToolError(message: "Each question requires id, header, and question")
      }
      let options: [RequestUserInputOption]
      if case .array(let rawOptions)? = question["options"] {
        options = try rawOptions.map { value in
          guard case .object(let option) = value,
            case .string(let label)? = option["label"]
          else {
            throw RequestUserInputToolError(message: "Each option requires a label")
          }
          let description: String
          if case .string(let value)? = option["description"] {
            description = value
          } else {
            description = ""
          }
          return RequestUserInputOption(label: label, description: description)
        }
      } else {
        options = []
      }
      return RequestUserInputQuestion(
        id: id, header: header, question: prompt, options: options)
    }
  }
}
