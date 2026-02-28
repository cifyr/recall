import Foundation

#if os(watchOS)
import WatchConnectivity

@MainActor
final class WatchWatchConnectivityBroker: NSObject, WatchPhoneSyncing {
  private enum IncomingMessage: Sendable {
    case uploadTicket(UploadTicket)
  }

  var onUploadTicketReceived: ((UploadTicket) -> Void)?
  private let session = WCSession.default

  override init() {
    super.init()
    session.delegate = self
  }

  func activate() async {
    guard WCSession.isSupported() else { return }
    session.activate()
  }

  func sendSessionStarted(_ payload: WatchSessionStartedPayload) async {
    send([
      "message": WatchTransferMessage.sessionStarted.rawValue,
      "session_id": payload.sessionID.uuidString,
      "source_device_id": payload.sourceDeviceID,
      "started_at": payload.startedAt.ISO8601Format(),
      "request_id": payload.requestID.uuidString,
    ])
  }

  func sendSegmentStopped(_ payload: WatchSegmentStoppedPayload) async {
    send([
      "message": WatchTransferMessage.segmentStopped.rawValue,
      "session_id": payload.sessionID.uuidString,
      "segment_index": payload.segmentIndex,
      "file_name": payload.fileName,
      "duration_ms": payload.durationMS,
      "started_at": payload.startedAt.ISO8601Format(),
      "ended_at": payload.endedAt.ISO8601Format(),
      "sha256": payload.sha256 ?? "",
      "request_id": payload.requestID.uuidString,
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

  func sendFinalizeRequest(_ payload: WatchFinalizePayload) async {
    send([
      "message": WatchTransferMessage.finalizeRequested.rawValue,
      "session_id": payload.sessionID.uuidString,
      "ended_at": payload.endedAt.ISO8601Format(),
      "segment_count": payload.segmentCount,
      "request_id": payload.requestID.uuidString,
    ])
  }

  private func send(_ dictionary: [String: Any]) {
    if session.isReachable {
      session.sendMessage(dictionary, replyHandler: nil)
    } else {
      session.transferUserInfo(dictionary)
    }
  }
}

extension WatchWatchConnectivityBroker: WCSessionDelegate {
  nonisolated func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {}

  nonisolated func sessionReachabilityDidChange(_ session: WCSession) {}

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
    case .uploadTicket(let ticket):
      onUploadTicketReceived?(ticket)
    }
  }

  nonisolated private static func parseIncomingMessage(_ dictionary: [String: Any]) -> IncomingMessage? {
    guard
      let message = dictionary["message"] as? String,
      WatchTransferMessage(rawValue: message) == .uploadTicketResponse,
      let sessionIDString = dictionary["session_id"] as? String,
      let sessionID = UUID(uuidString: sessionIDString),
      let segmentIndex = dictionary["segment_index"] as? Int,
      let storagePath = dictionary["storage_path"] as? String,
      let urlString = dictionary["signed_upload_url"] as? String,
      let url = URL(string: urlString),
      let expiresAtString = dictionary["expires_at"] as? String,
      let expiresAt = ISO8601DateFormatter().date(from: expiresAtString)
    else { return nil }

    return .uploadTicket(
      UploadTicket(
        sessionID: sessionID,
        segmentIndex: segmentIndex,
        storagePath: storagePath,
        signedUploadURL: url,
        expiresAt: expiresAt
      )
    )
  }
}
#else
final class WatchWatchConnectivityBroker: WatchPhoneSyncing {
  var onUploadTicketReceived: ((UploadTicket) -> Void)?
  func activate() async {}
  func sendSessionStarted(_ payload: WatchSessionStartedPayload) async {}
  func sendSegmentStopped(_ payload: WatchSegmentStoppedPayload) async {}
  func sendUploadStatus(_ payload: WatchUploadStatusPayload) async {}
  func sendFinalizeRequest(_ payload: WatchFinalizePayload) async {}
}
#endif
