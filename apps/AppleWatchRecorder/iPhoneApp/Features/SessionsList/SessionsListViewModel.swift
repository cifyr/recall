#if os(iOS)
import Foundation
import Observation

@MainActor
@Observable
final class SessionsListViewModel {
  let repository: any SessionRepository
  let telemetry: any TelemetryRecording

  var items: [SessionFeedItem] = []
  var isLoading = false
  var errorMessage: String?

  init(repository: any SessionRepository, telemetry: any TelemetryRecording) {
    self.repository = repository
    self.telemetry = telemetry
  }

  func load() async {
    isLoading = true
    defer { isLoading = false }

    do {
      items = try await repository.loadSessions()
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func deleteAllSessions() async {
    isLoading = true
    defer { isLoading = false }
    do {
      try await repository.deleteAllSessions()
      items = []
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
#endif
