import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
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
  private var watchSessionStarts: [UUID: WatchSessionStartedPayload] = [:]

  init(bundle: Bundle = .main) {
    configuration = .current(bundle: bundle)
    authClient = SupabaseAuthClient(configuration: configuration)
    deviceID = SupabaseSessionRepository.deviceID

    let edgeClient = EdgeFunctionClient(
      configuration: configuration,
      sessionProvider: { [authClient] in
        await authClient.currentSession()
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
  }

  func bootstrap() async {
    isBootstrapping = true
    defer { isBootstrapping = false }

    await authClient.restoreSession()
    authSession = await authClient.currentSession()
    repository = authSession != nil ? liveRepository : (configuration.isConfigured ? liveRepository : previewRepository)

    do {
      if authSession != nil || !configuration.isConfigured {
        try await repository.registerDevice(platform: "iphone", deviceID: deviceID)
      }
      await phoneWatchSync.activate()
      bootstrapError = nil
    } catch {
      bootstrapError = error.localizedDescription
    }
  }

  func refreshAuthState() async {
    authSession = await authClient.currentSession()
  }

  func completeSignIn() async {
    isDemoModeEnabled = false
    authSession = await authClient.currentSession()
    repository = liveRepository
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
  }

  func signOut() async {
    do {
      try await authClient.signOut()
      authSession = nil
      repository = configuration.isConfigured ? liveRepository : previewRepository
    } catch {
      bootstrapError = error.localizedDescription
    }
  }

  private func handleIncomingWatchSegment(_ segment: SessionSegmentDraft) async {
    guard let authSession else { return }

    let sessionStart = watchSessionStarts[segment.sessionID]
    let draft = WatchSessionDraft(
      sessionID: segment.sessionID,
      sourceDeviceID: sessionStart?.sourceDeviceID ?? "watch",
      startedAt: sessionStart?.startedAt ?? segment.startedAt,
      endedAt: nil,
      segments: [segment]
    )

    do {
      // Only create or correct the session row from an explicit start payload or the first segment.
      if sessionStart != nil || segment.segmentIndex == 0 {
        try await repository.upsertSession(draft)
      }
      try await repository.upsertSegment(segment, userID: authSession.userID)
      let ticket = try await repository.createUploadTicket(
        sessionID: segment.sessionID,
        segmentIndex: segment.segmentIndex
      )
      await phoneWatchSync.sendUploadTicket(ticket, requestID: UUID())
    } catch {
      bootstrapError = error.localizedDescription
    }
  }

  private func handleWatchSessionStarted(_ payload: WatchSessionStartedPayload) async {
    guard authSession != nil else { return }

    watchSessionStarts[payload.sessionID] = payload

    do {
      try await repository.upsertSession(
        WatchSessionDraft(
          sessionID: payload.sessionID,
          sourceDeviceID: payload.sourceDeviceID,
          startedAt: payload.startedAt,
          endedAt: nil,
          segments: []
        )
      )
      await phoneWatchSync.acknowledgeSession(payload)
      bootstrapError = nil
    } catch {
      bootstrapError = error.localizedDescription
    }
  }

  private func handleIncomingUploadStatus(_ payload: WatchUploadStatusPayload) async {
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
      bootstrapError = error.localizedDescription
    }
  }

  private func handleFinalizeRequest(_ payload: WatchFinalizePayload) async {
    guard authSession != nil else { return }

    do {
      try await repository.finalizeSession(sessionID: payload.sessionID)
      watchSessionStarts[payload.sessionID] = nil
      bootstrapError = nil
    } catch {
      bootstrapError = error.localizedDescription
    }
  }
}
