import Foundation

#if os(iOS)
import WatchConnectivity

@MainActor
final class PhoneWatchConnectivityBroker: NSObject, PhoneWatchSyncing {
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

  private let session = WCSession.default

  override init() {
    super.init()
    session.delegate = self
  }

  func activate() async {
    guard WCSession.isSupported() else { return }
    session.activate()
  }

  func sendUploadTicket(_ ticket: UploadTicket, requestID: UUID) async {
    let payload: [String: Any] = [
      "message": WatchTransferMessage.uploadTicketResponse.rawValue,
      "session_id": ticket.sessionID.uuidString,
      "segment_index": ticket.segmentIndex,
      "storage_path": ticket.storagePath,
      "signed_upload_url": ticket.signedUploadURL.absoluteString,
      "expires_at": ticket.expiresAt.ISO8601Format(),
      "request_id": requestID.uuidString,
    ]

    if session.isReachable {
      session.sendMessage(payload, replyHandler: nil)
    } else {
      session.transferUserInfo(payload)
    }
  }

  func acknowledgeSession(_ payload: WatchSessionStartedPayload) async {
    session.transferUserInfo([
      "message": WatchTransferMessage.acknowledged.rawValue,
      "session_id": payload.sessionID.uuidString,
      "request_id": payload.requestID.uuidString,
    ])
  }
}

extension PhoneWatchConnectivityBroker: WCSessionDelegate {
  nonisolated func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {}

  nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

  nonisolated func sessionDidDeactivate(_ session: WCSession) {
    session.activate()
  }

  nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
    guard let payload = Self.parseIncomingMessage(userInfo) else { return }
    Task { @MainActor in
      self.consume(payload)
    }
  }

  nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
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
  func activate() async {}
  func sendUploadTicket(_ ticket: UploadTicket, requestID: UUID) async {}
  func acknowledgeSession(_ payload: WatchSessionStartedPayload) async {}
}
#endif

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
