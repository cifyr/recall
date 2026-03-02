#if os(iOS)
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class AppModel {
  private let logger = Logger(subsystem: "com.caden.watchrecorder", category: "app-model")
  let configuration: AppConfiguration
  let authClient: SupabaseAuthClient
  let queueStore: QueueStore
  private let liveRepository: any SessionRepository
  private let previewRepository: any SessionRepository
  var repository: any SessionRepository
  let phoneWatchSync: PhoneWatchConnectivityBroker
  let telemetry: TelemetryClient
  let deviceID: String

  var authSession: AuthSession?
  var isDemoModeEnabled = false
  var isBootstrapping = true
  var bootstrapError: String?

  var isDebugModeEnabled: Bool {
    get { UserDefaults.standard.bool(forKey: "WatchDebugMode") }
    set {
      UserDefaults.standard.set(newValue, forKey: "WatchDebugMode")
      Task { await phoneWatchSync.sendAuthState(signedIn: authSession != nil, debugMode: newValue) }
    }
  }

  private var watchSessionStarts: [UUID: WatchSessionStartedPayload] = [:]

  init(bundle: Bundle = .main) {
    configuration = .current(bundle: bundle)
    authClient = SupabaseAuthClient(configuration: configuration)
    deviceID = SupabaseSessionRepository.deviceID

    let edgeClient = EdgeFunctionClient(
      configuration: configuration,
      sessionProvider: { [authClient] forceRefresh in
        if forceRefresh {
          return await authClient.refreshSession()
        }
        return await authClient.currentSession()
      }
    )
    telemetry = TelemetryClient(edgeClient: configuration.isConfigured ? edgeClient : nil, deviceID: deviceID)
    queueStore = QueueStore()

    if configuration.isConfigured {
      liveRepository = SupabaseSessionRepository(
        configuration: configuration,
        authProvider: authClient,
        edgeClient: edgeClient
      )
    } else {
      liveRepository = PreviewSessionRepository()
    }
    previewRepository = PreviewSessionRepository()
    repository = configuration.isConfigured ? liveRepository : previewRepository

    phoneWatchSync = PhoneWatchConnectivityBroker()
    phoneWatchSync.onSessionStarted = { [weak self] payload in
      guard let self else { return }
      Task {
        await self.handleWatchSessionStarted(payload)
      }
    }
    phoneWatchSync.onSegmentMetadataReceived = { [weak self] segment in
      guard let self else { return }
      Task {
        await self.handleIncomingWatchSegment(segment)
      }
    }
    phoneWatchSync.onUploadStatusReceived = { [weak self] payload in
      guard let self else { return }
      Task {
        await self.handleIncomingUploadStatus(payload)
      }
    }
    phoneWatchSync.onFinalizeRequested = { [weak self] payload in
      guard let self else { return }
      Task {
        await self.handleFinalizeRequest(payload)
      }
    }
    phoneWatchSync.onSessionActivated = { [weak self] in
      guard let self else { return }
      await self.phoneWatchSync.sendAuthState(signedIn: self.authSession != nil, debugMode: self.isDebugModeEnabled)
    }
  }

  func bootstrap() async {
    isBootstrapping = true
    defer { isBootstrapping = false }

    await authClient.restoreSession()
    authSession = await authClient.currentSession()
    repository = authSession != nil ? liveRepository : (configuration.isConfigured ? liveRepository : previewRepository)
    await phoneWatchSync.activate()
    // Auth state is sent when WCSession activation completes (onSessionActivated)

    do {
      if authSession != nil || !configuration.isConfigured {
        try await repository.registerDevice(platform: "iphone", deviceID: deviceID)
      }
      bootstrapError = nil
    } catch {
      bootstrapError = error.localizedDescription
    }
  }

  func refreshAuthState() async {
    authSession = await authClient.currentSession()
  }

  /// Resends auth state to the watch so it can recover from sync issues.
  func syncWatchAuthState() async {
    await phoneWatchSync.sendAuthState(signedIn: authSession != nil, debugMode: isDebugModeEnabled)
  }

  func completeSignIn() async {
    isDemoModeEnabled = false
    authSession = await authClient.currentSession()
    repository = liveRepository
    await phoneWatchSync.activate()
    await phoneWatchSync.sendAuthState(signedIn: true, debugMode: isDebugModeEnabled)
    do {
      try await repository.registerDevice(platform: "iphone", deviceID: deviceID)
      bootstrapError = nil
    } catch {
      bootstrapError = error.localizedDescription
    }
  }

  func enableDemoMode() {
    isDemoModeEnabled = true
    authSession = nil
    repository = previewRepository
    Task {
      await phoneWatchSync.sendAuthState(signedIn: false, debugMode: isDebugModeEnabled)
    }
  }

  func signOut() async {
    do {
      try await authClient.signOut()
      authSession = nil
      repository = configuration.isConfigured ? liveRepository : previewRepository
      await phoneWatchSync.sendAuthState(signedIn: false, debugMode: isDebugModeEnabled)
    } catch {
      bootstrapError = error.localizedDescription
    }
  }

  private func handleIncomingWatchSegment(_ segment: SessionSegmentDraft) async {
    logger.info("Handling watch segment session=\(segment.sessionID.uuidString, privacy: .public) segment=\(segment.segmentIndex, privacy: .public)")

    // Always force-refresh auth to guarantee a fresh JWT for upload operations
    logger.info("Force-refreshing auth before upload…")
    authSession = await authClient.refreshSession()
    if authSession == nil {
      logger.info("Refresh returned nil, trying currentSession…")
      authSession = await authClient.currentSession()
    }
    guard let freshSession = authSession else {
      logger.error("No auth session available after refresh — user not signed in")
      bootstrapError = "Sign in on iPhone to upload watch recordings."
      await phoneWatchSync.sendUploadStatus(
        WatchUploadStatusPayload(
          sessionID: segment.sessionID,
          segmentIndex: segment.segmentIndex,
          status: .failed,
          bytes: nil,
          errorCode: "phone_not_signed_in",
          requestID: UUID()
        )
      )
      return
    }
    logger.info("Auth ready: user=\(freshSession.userID.uuidString.prefix(8), privacy: .public)")

    let sessionStart = watchSessionStarts[segment.sessionID]
    let draft = WatchSessionDraft(
      sessionID: segment.sessionID,
      sourceDeviceID: sessionStart?.sourceDeviceID ?? "watch",
      startedAt: sessionStart?.startedAt ?? segment.startedAt,
      endedAt: nil,
      segments: [segment],
      uploadSegment: segment
    )

    do {
      try await performSegmentUpload(segment: segment, draft: draft, userID: freshSession.userID, sessionStart: sessionStart)
    } catch {
      if isAuthError(error) {
        logger.info("Got 401 for session=\(segment.sessionID.uuidString, privacy: .public); force-refreshing auth and retrying once more")
        self.authSession = await authClient.refreshSession()
        if let retrySession = self.authSession {
          do {
            try await performSegmentUpload(segment: segment, draft: draft, userID: retrySession.userID, sessionStart: sessionStart)
            return
          } catch {
            logger.error("Retry also failed session=\(segment.sessionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
          }
        } else {
          logger.error("Auth refresh returned nil on retry — user session may be fully expired")
        }
      }

      logger.error("Failed handling watch segment session=\(segment.sessionID.uuidString, privacy: .public) segment=\(segment.segmentIndex, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
      bootstrapError = error.localizedDescription
      let errorCode = uploadFailureCode(for: error)
      await phoneWatchSync.sendUploadStatus(
        WatchUploadStatusPayload(
          sessionID: segment.sessionID,
          segmentIndex: segment.segmentIndex,
          status: .failed,
          bytes: nil,
          errorCode: errorCode,
          requestID: UUID()
        )
      )
    }
  }

  private func performSegmentUpload(segment: SessionSegmentDraft, draft: WatchSessionDraft, userID: UUID, sessionStart: WatchSessionStartedPayload?) async throws {
    if sessionStart != nil || segment.segmentIndex == 0 {
      try await repository.upsertSession(draft)
    }
    try await repository.upsertSegment(segment, userID: userID)
    let ticket = try await repository.createUploadTicket(
      sessionID: segment.sessionID,
      segmentIndex: segment.segmentIndex
    )
    logger.info("Created upload ticket for session=\(segment.sessionID.uuidString, privacy: .public) segment=\(segment.segmentIndex, privacy: .public)")
    await phoneWatchSync.sendUploadTicket(ticket, requestID: UUID())
  }

  private func isAuthError(_ error: Error) -> Bool {
    if case NetworkError.unauthorized = error { return true }
    if case let NetworkError.server(code, _) = error, code == 401 { return true }
    let desc = error.localizedDescription
    return desc.contains("401") && desc.lowercased().contains("unauthorized")
  }

  private func handleWatchSessionStarted(_ payload: WatchSessionStartedPayload) async {
    guard authSession != nil else { return }

    watchSessionStarts[payload.sessionID] = payload
    logger.info("Handling watch session start session=\(payload.sessionID.uuidString, privacy: .public)")

    do {
      try await repository.upsertSession(
        WatchSessionDraft(
          sessionID: payload.sessionID,
          sourceDeviceID: payload.sourceDeviceID,
          startedAt: payload.startedAt,
          endedAt: nil,
          segments: [],
          uploadSegment: nil
        )
      )
      await phoneWatchSync.acknowledgeSession(payload)
      bootstrapError = nil
    } catch {
      logger.error("Failed handling watch session start session=\(payload.sessionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
      bootstrapError = error.localizedDescription
    }
  }

  private func handleIncomingUploadStatus(_ payload: WatchUploadStatusPayload) async {
    logger.info("Handling watch upload status session=\(payload.sessionID.uuidString, privacy: .public) segment=\(payload.segmentIndex, privacy: .public) status=\(payload.status.rawValue, privacy: .public) errorCode=\(payload.errorCode ?? "", privacy: .public)")
    if authSession == nil { authSession = await authClient.currentSession() }
    guard authSession != nil else { return }

    do {
      if payload.status == .uploaded {
        try await repository.markSegmentUploaded(
          sessionID: payload.sessionID,
          segmentIndex: payload.segmentIndex,
          uploadedFrom: "watch",
          bytes: payload.bytes
        )
        bootstrapError = nil
      } else if payload.status == .failed {
        bootstrapError = payload.errorCode ?? "Watch upload failed."
      }
    } catch {
      logger.error("Failed handling watch upload status session=\(payload.sessionID.uuidString, privacy: .public) segment=\(payload.segmentIndex, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
      bootstrapError = error.localizedDescription
    }
  }

  private func handleFinalizeRequest(_ payload: WatchFinalizePayload) async {
    logger.info("Handling finalize request session=\(payload.sessionID.uuidString, privacy: .public)")
    if authSession == nil { authSession = await authClient.refreshSession() }
    guard authSession != nil else {
      logger.error("Cannot finalize — no auth session")
      return
    }

    do {
      try await repository.finalizeSession(sessionID: payload.sessionID)
      watchSessionStarts[payload.sessionID] = nil
      bootstrapError = nil
    } catch {
      logger.error("Failed finalizing session=\(payload.sessionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
      bootstrapError = error.localizedDescription
    }
  }

  private func uploadFailureCode(for error: Error) -> String {
    if case let NetworkError.server(code, message) = error {
      if code == 401 {
        return "phone_not_signed_in"
      }
      if code == 403 {
        if message.contains("conversation_sessions") && message.contains("row-level security") {
          return "session_access_denied"
        }
        if message.contains("conversation_segments") && message.contains("row-level security") {
          return "segment_access_denied"
        }
      }
    }
    return "ticket_issue_failed"
  }
}
#endif
