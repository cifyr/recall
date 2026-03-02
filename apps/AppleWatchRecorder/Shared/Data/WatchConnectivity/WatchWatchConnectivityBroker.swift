import Foundation
import OSLog

#if os(watchOS)
import WatchConnectivity

@MainActor
final class WatchWatchConnectivityBroker: NSObject, WatchPhoneSyncing {
  private let logger = Logger(subsystem: "com.caden.watchrecorder", category: "watch-phone-sync")
  private enum IncomingMessage: Sendable {
    case uploadTicket(UploadTicket)
    case uploadStatus(WatchUploadStatusPayload)
  }

  var onUploadTicketReceived: ((UploadTicket) -> Void)?
  var onUploadStatusReceived: ((WatchUploadStatusPayload) -> Void)?
  var onAuthStateReceived: ((_ signedIn: Bool, _ debugMode: Bool) -> Void)?
  private let session = WCSession.default

  override init() {
    super.init()
    session.delegate = self
  }

  func activate() async {
    guard WCSession.isSupported() else { return }
    logger.info("Activating watch WCSession")
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
    let message = (dictionary["message"] as? String) ?? "unknown"
    logger.info("Watch sending message=\(message, privacy: .public) reachable=\(self.session.isReachable, privacy: .public)")
    if session.isReachable {
      session.sendMessage(dictionary, replyHandler: nil) { [weak self] _ in
        Task { @MainActor in
          self?.logger.error("Watch sendMessage failed for message=\(message, privacy: .public); falling back to transferUserInfo")
          _ = self?.session.transferUserInfo(dictionary)
        }
      }
    } else {
      logger.info("Watch transferUserInfo for message=\(message, privacy: .public)")
      _ = session.transferUserInfo(dictionary)
    }
  }
}

extension WatchWatchConnectivityBroker: WCSessionDelegate {
  nonisolated func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    Logger(subsystem: "com.caden.watchrecorder", category: "watch-phone-sync")
      .info("Watch WCSession activated state=\(activationState.rawValue, privacy: .public) reachable=\(session.isReachable, privacy: .public) companionInstalled=\(session.isCompanionAppInstalled, privacy: .public) error=\(String(describing: error), privacy: .public)")
    let ctx = session.receivedApplicationContext
    if let signedIn = Self.parseSignedIn(from: ctx) {
      let debugMode = Self.parseDebugMode(from: ctx)
      Task { @MainActor in
        self.onAuthStateReceived?(signedIn, debugMode)
      }
    }
  }

  nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
    Logger(subsystem: "com.caden.watchrecorder", category: "watch-phone-sync")
      .info("Watch received applicationContext")
    if let signedIn = Self.parseSignedIn(from: applicationContext) {
      let debugMode = Self.parseDebugMode(from: applicationContext)
      Task { @MainActor in
        self.onAuthStateReceived?(signedIn, debugMode)
      }
    }
  }

  nonisolated private static func parseSignedIn(from context: [String: Any]) -> Bool? {
    guard let value = context["signed_in"] else { return nil }
    if let b = value as? Bool { return b }
    if let n = value as? NSNumber { return n.boolValue }
    return nil
  }

  nonisolated private static func parseDebugMode(from context: [String: Any]) -> Bool {
    if let b = context["debug_mode"] as? Bool { return b }
    if let n = context["debug_mode"] as? NSNumber { return n.boolValue }
    return false
  }

  nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
    Logger(subsystem: "com.caden.watchrecorder", category: "watch-phone-sync")
      .info("Watch WCSession reachability changed reachable=\(session.isReachable, privacy: .public)")
  }

  nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
    let message = (userInfo["message"] as? String) ?? "unknown"
    Logger(subsystem: "com.caden.watchrecorder", category: "watch-phone-sync")
      .info("Watch received userInfo message=\(message, privacy: .public)")
    guard let payload = Self.parseIncomingMessage(userInfo) else { return }
    Task { @MainActor in
      self.consume(payload)
    }
  }

  nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
    let messageName = (message["message"] as? String) ?? "unknown"
    Logger(subsystem: "com.caden.watchrecorder", category: "watch-phone-sync")
      .info("Watch received interactive message=\(messageName, privacy: .public)")
    guard let payload = Self.parseIncomingMessage(message) else { return }
    Task { @MainActor in
      self.consume(payload)
    }
  }

  private func consume(_ message: IncomingMessage) {
    switch message {
    case .uploadTicket(let ticket):
      onUploadTicketReceived?(ticket)
    case .uploadStatus(let payload):
      onUploadStatusReceived?(payload)
    }
  }

  nonisolated private static func parseIncomingMessage(_ dictionary: [String: Any]) -> IncomingMessage? {
    guard let message = dictionary["message"] as? String else { return nil }

    switch WatchTransferMessage(rawValue: message) {
    case .uploadTicketResponse:
      guard
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

    case .uploadStatus:
      guard
        let sessionIDString = dictionary["session_id"] as? String,
        let sessionID = UUID(uuidString: sessionIDString),
        let segmentIndex = dictionary["segment_index"] as? Int,
        let statusString = dictionary["status"] as? String,
        let status = SegmentUploadStatus(rawValue: statusString),
        let requestIDString = dictionary["request_id"] as? String,
        let requestID = UUID(uuidString: requestIDString)
      else { return nil }

      let bytes = (dictionary["bytes"] as? NSNumber)?.int64Value
      let errorCode = (dictionary["error_code"] as? String)?.nilIfEmpty

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

    default:
      return nil
    }
  }
}
#else
final class WatchWatchConnectivityBroker: WatchPhoneSyncing {
  var onUploadTicketReceived: ((UploadTicket) -> Void)?
  var onUploadStatusReceived: ((WatchUploadStatusPayload) -> Void)?
  var onAuthStateReceived: ((_ signedIn: Bool, _ debugMode: Bool) -> Void)?
  func activate() async {}
  func sendSessionStarted(_ payload: WatchSessionStartedPayload) async {}
  func sendSegmentStopped(_ payload: WatchSegmentStoppedPayload) async {}
  func sendUploadStatus(_ payload: WatchUploadStatusPayload) async {}
  func sendFinalizeRequest(_ payload: WatchFinalizePayload) async {}
}
#endif

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
