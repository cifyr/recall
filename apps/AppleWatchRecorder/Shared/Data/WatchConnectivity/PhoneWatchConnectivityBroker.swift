import Foundation
import OSLog

#if os(iOS)
import WatchConnectivity

@MainActor
final class PhoneWatchConnectivityBroker: NSObject, PhoneWatchSyncing {
  private let logger = Logger(subsystem: "com.caden.watchrecorder", category: "phone-watch-sync")
  private enum IncomingMessage: Sendable {
    case sessionStarted(WatchSessionStartedPayload)
    case segmentStopped(SessionSegmentDraft)
    case uploadStatus(WatchUploadStatusPayload)
    case finalizeRequested(WatchFinalizePayload)
  }

  var onSessionStarted: ((WatchSessionStartedPayload) -> Void)?
  var onSegmentMetadataReceived: ((SessionSegmentDraft) -> Void)?
  var onUploadStatusReceived: ((WatchUploadStatusPayload) -> Void)?
  var onFinalizeRequested: ((WatchFinalizePayload) -> Void)?
  var onSessionActivated: (() async -> Void)?

  private let session = WCSession.default

  override init() {
    super.init()
    session.delegate = self
  }

  func activate() async {
    guard WCSession.isSupported() else { return }
    logger.info("Activating phone WCSession")
    session.activate()
  }

  func sendAuthState(signedIn: Bool, debugMode: Bool) async {
    do {
      try session.updateApplicationContext(["signed_in": signedIn, "debug_mode": debugMode])
      logger.info("Phone sent auth state signedIn=\(signedIn, privacy: .public) debugMode=\(debugMode, privacy: .public)")
    } catch {
      logger.error("Phone failed to send auth state: \(error.localizedDescription, privacy: .public)")
    }
  }

  func sendUploadTicket(_ ticket: UploadTicket, requestID: UUID) async {
    send([
      "message": WatchTransferMessage.uploadTicketResponse.rawValue,
      "session_id": ticket.sessionID.uuidString,
      "segment_index": ticket.segmentIndex,
      "storage_path": ticket.storagePath,
      "signed_upload_url": ticket.signedUploadURL.absoluteString,
      "expires_at": ticket.expiresAt.ISO8601Format(),
      "request_id": requestID.uuidString,
    ])
  }

  func sendUploadStatus(_ payload: WatchUploadStatusPayload) async {
    send([
      "message": WatchTransferMessage.uploadStatus.rawValue,
      "session_id": payload.sessionID.uuidString,
      "segment_index": payload.segmentIndex,
      "status": payload.status.rawValue,
      "bytes": payload.bytes ?? 0,
      "error_code": payload.errorCode ?? "",
      "request_id": payload.requestID.uuidString,
    ])
  }

  func acknowledgeSession(_ payload: WatchSessionStartedPayload) async {
    send([
      "message": WatchTransferMessage.acknowledged.rawValue,
      "session_id": payload.sessionID.uuidString,
      "request_id": payload.requestID.uuidString,
    ])
  }

  private func send(_ dictionary: [String: Any]) {
    let message = (dictionary["message"] as? String) ?? "unknown"
    logger.info("Phone sending message=\(message, privacy: .public) reachable=\(self.session.isReachable, privacy: .public)")
    if session.isReachable {
      session.sendMessage(dictionary, replyHandler: nil) { [weak self] _ in
        Task { @MainActor in
          self?.logger.error("Phone sendMessage failed for message=\(message, privacy: .public); falling back to transferUserInfo")
          _ = self?.session.transferUserInfo(dictionary)
        }
      }
    } else {
      logger.info("Phone transferUserInfo for message=\(message, privacy: .public)")
      _ = session.transferUserInfo(dictionary)
    }
  }
}

extension PhoneWatchConnectivityBroker: WCSessionDelegate {
  nonisolated func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    Logger(subsystem: "com.caden.watchrecorder", category: "phone-watch-sync")
      .info("Phone WCSession activated state=\(activationState.rawValue, privacy: .public) reachable=\(session.isReachable, privacy: .public) paired=\(session.isPaired, privacy: .public) watchInstalled=\(session.isWatchAppInstalled, privacy: .public) error=\(String(describing: error), privacy: .public)")
    if activationState == .activated {
      Task { @MainActor in
        await self.onSessionActivated?()
      }
    }
  }

  nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

  nonisolated func sessionDidDeactivate(_ session: WCSession) {
    Logger(subsystem: "com.caden.watchrecorder", category: "phone-watch-sync")
      .info("Phone WCSession didDeactivate; reactivating")
    session.activate()
  }

  nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
    let message = (userInfo["message"] as? String) ?? "unknown"
    Logger(subsystem: "com.caden.watchrecorder", category: "phone-watch-sync")
      .info("Phone received userInfo message=\(message, privacy: .public)")
    guard let payload = Self.parseIncomingMessage(userInfo) else { return }
    Task { @MainActor in
      self.consume(payload)
    }
  }

  nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
    let messageName = (message["message"] as? String) ?? "unknown"
    Logger(subsystem: "com.caden.watchrecorder", category: "phone-watch-sync")
      .info("Phone received interactive message=\(messageName, privacy: .public)")
    guard let payload = Self.parseIncomingMessage(message) else { return }
    Task { @MainActor in
      self.consume(payload)
    }
  }

  private func consume(_ message: IncomingMessage) {
    switch message {
    case .sessionStarted(let payload):
      onSessionStarted?(payload)
    case .segmentStopped(let draft):
      onSegmentMetadataReceived?(draft)
    case .uploadStatus(let payload):
      onUploadStatusReceived?(payload)
    case .finalizeRequested(let payload):
      onFinalizeRequested?(payload)
    }
  }

  nonisolated private static func parseIncomingMessage(_ userInfo: [String: Any]) -> IncomingMessage? {
    guard let message = userInfo["message"] as? String else { return nil }

    switch WatchTransferMessage(rawValue: message) {
    case .sessionStarted:
      guard
        let sessionIDString = userInfo["session_id"] as? String,
        let sessionID = UUID(uuidString: sessionIDString),
        let sourceDeviceID = userInfo["source_device_id"] as? String,
        let startedAtString = userInfo["started_at"] as? String,
        let startedAt = ISO8601DateFormatter().date(from: startedAtString),
        let requestIDString = userInfo["request_id"] as? String,
        let requestID = UUID(uuidString: requestIDString)
      else { return nil }
      return .sessionStarted(
        WatchSessionStartedPayload(
          sessionID: sessionID,
          sourceDeviceID: sourceDeviceID,
          startedAt: startedAt,
          requestID: requestID
        )
      )

    case .segmentStopped:
      guard
        let sessionIDString = userInfo["session_id"] as? String,
        let sessionID = UUID(uuidString: sessionIDString),
        let segmentIndex = userInfo["segment_index"] as? Int,
        let fileName = userInfo["file_name"] as? String,
        let durationMS = userInfo["duration_ms"] as? Int,
        let startedAtString = userInfo["started_at"] as? String,
        let endedAtString = userInfo["ended_at"] as? String,
        let startedAt = ISO8601DateFormatter().date(from: startedAtString),
        let endedAt = ISO8601DateFormatter().date(from: endedAtString)
      else { return nil }

      let draft = SessionSegmentDraft(
        id: UUID(),
        sessionID: sessionID,
        segmentIndex: segmentIndex,
        fileName: fileName,
        fileURL: URL(fileURLWithPath: fileName),
        startedAt: startedAt,
        endedAt: endedAt,
        durationMS: durationMS,
        sha256: userInfo["sha256"] as? String,
        uploadStatus: .pending,
        uploadAttempts: 0
      )
      return .segmentStopped(draft)

    case .uploadStatus:
      guard
        let sessionIDString = userInfo["session_id"] as? String,
        let sessionID = UUID(uuidString: sessionIDString),
        let segmentIndex = userInfo["segment_index"] as? Int,
        let statusString = userInfo["status"] as? String,
        let status = SegmentUploadStatus(rawValue: statusString),
        let requestIDString = userInfo["request_id"] as? String,
        let requestID = UUID(uuidString: requestIDString)
      else { return nil }

      let bytes = (userInfo["bytes"] as? NSNumber)?.int64Value
      let errorCode = (userInfo["error_code"] as? String)?.nilIfEmpty

      return .uploadStatus(
        WatchUploadStatusPayload(
          sessionID: sessionID,
          segmentIndex: segmentIndex,
          status: status,
          bytes: bytes,
          errorCode: errorCode,
          requestID: requestID
        )
      )

    case .finalizeRequested:
      guard
        let sessionIDString = userInfo["session_id"] as? String,
        let sessionID = UUID(uuidString: sessionIDString),
        let endedAtString = userInfo["ended_at"] as? String,
        let endedAt = ISO8601DateFormatter().date(from: endedAtString),
        let segmentCount = userInfo["segment_count"] as? Int,
        let requestIDString = userInfo["request_id"] as? String,
        let requestID = UUID(uuidString: requestIDString)
      else { return nil }
      return .finalizeRequested(
        WatchFinalizePayload(
          sessionID: sessionID,
          endedAt: endedAt,
          segmentCount: segmentCount,
          requestID: requestID
        )
      )

    default:
      return nil
    }
  }
}
#else
final class PhoneWatchConnectivityBroker: PhoneWatchSyncing {
  var onSessionStarted: ((WatchSessionStartedPayload) -> Void)?
  var onSegmentMetadataReceived: ((SessionSegmentDraft) -> Void)?
  var onUploadStatusReceived: ((WatchUploadStatusPayload) -> Void)?
  var onFinalizeRequested: ((WatchFinalizePayload) -> Void)?
  var onSessionActivated: (() async -> Void)?
  func activate() async {}
  func sendAuthState(signedIn: Bool, debugMode: Bool) async {}
  func sendUploadTicket(_ ticket: UploadTicket, requestID: UUID) async {}
  func sendUploadStatus(_ payload: WatchUploadStatusPayload) async {}
  func acknowledgeSession(_ payload: WatchSessionStartedPayload) async {}
}
#endif

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
