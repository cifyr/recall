import Foundation
import Observation

@MainActor
@Observable
final class SessionDetailViewModel {
  private let repository: any SessionRepository
  let sessionID: UUID

  var detail: SessionDetail?
  var isLoading = false
  var isSavingNotes = false
  var isRetrying = false
  var isAsking = false
  var notesDraft = ""
  var questionDraft = ""
  var errorMessage: String?

  init(repository: any SessionRepository, sessionID: UUID) {
    self.repository = repository
    self.sessionID = sessionID
  }

  func load() async {
    isLoading = true
    defer { isLoading = false }

    do {
      detail = try await repository.loadSessionDetail(sessionID: sessionID)
      notesDraft = detail?.userNotes ?? ""
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func saveNotes() async {
    isSavingNotes = true
    defer { isSavingNotes = false }

    do {
      try await repository.updateNotes(sessionID: sessionID, notes: notesDraft)
      await load()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func askQuestion() async {
    guard !questionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    isAsking = true
    defer { isAsking = false }

    do {
      _ = try await repository.askQuestion(sessionID: sessionID, question: questionDraft, includeUserNotes: true)
      questionDraft = ""
      await load()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func retryPipeline() async {
    isRetrying = true
    defer { isRetrying = false }

    do {
      try await repository.retryPipeline(sessionID: sessionID)
      await load()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
