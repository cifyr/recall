import Foundation

struct RequestIdentity: Sendable {
  let requestID: UUID
  let correlationID: UUID
  let idempotencyKey: UUID

  static func make() -> RequestIdentity {
    let requestID = UUID()
    return RequestIdentity(
      requestID: requestID,
      correlationID: UUID(),
      idempotencyKey: requestID
    )
  }
}

struct LoadSessionsUseCase: Sendable {
  let repository: SessionRepository

  func callAsFunction() async throws -> [SessionFeedItem] {
    try await repository.loadSessions()
  }
}

struct FinalizeSessionUseCase: Sendable {
  let repository: SessionRepository

  func callAsFunction(sessionID: UUID) async throws {
    try await repository.finalizeSession(sessionID: sessionID)
  }
}

struct AskQuestionUseCase: Sendable {
  let repository: SessionRepository

  func callAsFunction(sessionID: UUID, question: String, includeUserNotes: Bool) async throws -> AskSessionResponse {
    try await repository.askQuestion(
      sessionID: sessionID,
      question: question,
      includeUserNotes: includeUserNotes
    )
  }
}
