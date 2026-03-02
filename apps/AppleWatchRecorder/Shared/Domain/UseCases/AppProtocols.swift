import Foundation

protocol SessionRepository: Sendable {
  func registerDevice(platform: String, deviceID: String) async throws
  func loadSessions() async throws -> [SessionFeedItem]
  func loadSessionDetail(sessionID: UUID) async throws -> SessionDetail
  func deleteAllSessions() async throws
  func upsertSession(_ draft: WatchSessionDraft) async throws
  func upsertSegment(_ segment: SessionSegmentDraft, userID: UUID) async throws
  func createUploadTicket(sessionID: UUID, segmentIndex: Int) async throws -> UploadTicket
  func markSegmentUploaded(sessionID: UUID, segmentIndex: Int, uploadedFrom: String, bytes: Int64?) async throws
  func finalizeSession(sessionID: UUID) async throws
  func retryPipeline(sessionID: UUID) async throws
  func updateNotes(sessionID: UUID, notes: String) async throws
  func askQuestion(sessionID: UUID, question: String, includeUserNotes: Bool) async throws -> AskSessionResponse
  func healthSnapshot(deviceID: String) async throws -> DeviceHealthSnapshot
}

protocol AuthProviding: AnyObject, Sendable {
  var isConfigured: Bool { get }
  func currentSession() async -> AuthSession?
  func refreshSession() async -> AuthSession?
  func restoreSession() async
  func sendEmailCode(to email: String) async throws
  func verifyEmailCode(email: String, code: String) async throws
  func signOut() async throws
}

protocol TelemetryRecording: Sendable {
  func track(_ events: [TelemetryEvent]) async
}

protocol QueueStoreProtocol: Sendable {
  func enqueue(_ record: QueueRecord) async throws
  func update(_ record: QueueRecord) async throws
  func remove(queueID: UUID) async throws
  func allRecords() async throws -> [QueueRecord]
  func count() async throws -> Int
}

@MainActor
protocol PhoneWatchSyncing: AnyObject {
  var onSessionStarted: ((WatchSessionStartedPayload) -> Void)? { get set }
  var onSegmentMetadataReceived: ((SessionSegmentDraft) -> Void)? { get set }
  var onUploadStatusReceived: ((WatchUploadStatusPayload) -> Void)? { get set }
  var onFinalizeRequested: ((WatchFinalizePayload) -> Void)? { get set }
  var onSessionActivated: (() async -> Void)? { get set }
  func activate() async
  func sendAuthState(signedIn: Bool, debugMode: Bool) async
  func sendUploadTicket(_ ticket: UploadTicket, requestID: UUID) async
  func sendUploadStatus(_ payload: WatchUploadStatusPayload) async
  func acknowledgeSession(_ payload: WatchSessionStartedPayload) async
}

@MainActor
protocol WatchPhoneSyncing: AnyObject {
  var onUploadTicketReceived: ((UploadTicket) -> Void)? { get set }
  var onUploadStatusReceived: ((WatchUploadStatusPayload) -> Void)? { get set }
  var onAuthStateReceived: ((_ signedIn: Bool, _ debugMode: Bool) -> Void)? { get set }
  func activate() async
  func sendSessionStarted(_ payload: WatchSessionStartedPayload) async
  func sendSegmentStopped(_ payload: WatchSegmentStoppedPayload) async
  func sendUploadStatus(_ payload: WatchUploadStatusPayload) async
  func sendFinalizeRequest(_ payload: WatchFinalizePayload) async
}
