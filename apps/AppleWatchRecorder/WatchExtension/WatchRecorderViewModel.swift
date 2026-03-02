import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class WatchRecorderViewModel {
  private let logger = Logger(subsystem: "com.caden.watchrecorder", category: "watch-recorder")
  private let recorder: WatchAudioRecorder
  private let sync: WatchWatchConnectivityBroker
  private let userDefaults: UserDefaults
  private let fileManager: FileManager
  private let deviceID: String

  private(set) var state: WatchRecorderState = .idle
  private(set) var phoneSignedIn = false
  private(set) var debugMode = false
  private(set) var lastError: String?

  private var sessionID: UUID?
  private var recordingStartedAt: Date?
  private var recordingFileURL: URL?
  private var ticketTimeoutTask: Task<Void, Never>?

  init(
    recorder: WatchAudioRecorder = WatchAudioRecorder(),
    sync: WatchWatchConnectivityBroker = WatchWatchConnectivityBroker(),
    userDefaults: UserDefaults = .standard,
    fileManager: FileManager = .default
  ) {
    self.recorder = recorder
    self.sync = sync
    self.userDefaults = userDefaults
    self.fileManager = fileManager
    self.deviceID = userDefaults.string(forKey: "WatchDeviceID") ?? UUID().uuidString
    userDefaults.set(deviceID, forKey: "WatchDeviceID")

    sync.onUploadTicketReceived = { [weak self] ticket in
      guard let self else { return }
      Task { await self.handleUploadTicket(ticket) }
    }
    sync.onUploadStatusReceived = { [weak self] payload in
      guard let self else { return }
      Task { await self.handlePhoneUploadStatus(payload) }
    }
    sync.onAuthStateReceived = { [weak self] signedIn, debugMode in
      self?.logger.info("[vm] Auth state received from phone: signedIn=\(signedIn, privacy: .public) debugMode=\(debugMode, privacy: .public)")
      self?.phoneSignedIn = signedIn
      self?.debugMode = debugMode
    }
  }

  // MARK: - Bootstrap

  func bootstrap() async {
    logger.info("[vm] Bootstrapping watch recorder")
    await sync.activate()
    // Run mic preflight + audio warmup off the main actor with a delay so the
    // watch face renders and feels responsive first. The 9s warmup blocks a
    // background thread; delaying it avoids competing with initial Canvas/Metal setup.
    Task.detached(priority: .utility) { [recorder] in
      try? await Task.sleep(for: .seconds(2))
      do {
        try await recorder.preflightMicrophonePermission()
        await recorder.warmUpAudioSession()
      } catch {
        // Logged inside recorder
      }
    }
  }

  // MARK: - Gesture handlers

  func handleTap() async {
    logger.info("[vm] handleTap — current state=\(self.state.rawValue, privacy: .public)")
    switch state {
    case .idle, .error:
      state = .starting
      await startRecording()
    case .recording:
      await pauseRecording()
    case .paused:
      await resumeRecording()
    case .starting, .uploading:
      logger.info("[vm] Ignoring tap during \(self.state.rawValue, privacy: .public)")
    }
  }

  func handleLongPress() async {
    logger.info("[vm] handleLongPress — current state=\(self.state.rawValue, privacy: .public)")
    switch state {
    case .recording, .paused:
      await finalizeAndUpload()
    case .starting:
      logger.info("[vm] Long-press ignored while starting")
    case .error:
      if recordingFileURL != nil {
        logger.info("[vm] Retrying upload from error state")
        await beginUploadSequence()
      } else {
        logger.info("[vm] No file to retry, resetting to idle")
        resetToIdle()
      }
    case .idle, .uploading:
      logger.info("[vm] Long-press ignored in state=\(self.state.rawValue, privacy: .public)")
    }
  }

  // MARK: - Recording

  private func startRecording() async {
    logger.info("[vm] startRecording")
    do {
      let sid = UUID()
      sessionID = sid
      recordingStartedAt = Date()

      let url = try await recorder.startRecording()
      recordingFileURL = url
      state = .recording
      lastError = nil
      logger.info("[vm] Recording started sessionID=\(sid.uuidString, privacy: .public) file=\(url.lastPathComponent, privacy: .public)")

      await sync.sendSessionStarted(
        WatchSessionStartedPayload(
          sessionID: sid,
          sourceDeviceID: deviceID,
          startedAt: recordingStartedAt ?? .now,
          requestID: UUID()
        )
      )
    } catch {
      logger.error("[vm] startRecording failed: \(error.localizedDescription, privacy: .public)")
      lastError = error.localizedDescription
      state = .error
    }
  }

  private func pauseRecording() async {
    logger.info("[vm] pauseRecording")
    await recorder.pauseRecording()
    state = .paused
  }

  private func resumeRecording() async {
    logger.info("[vm] resumeRecording")
    await recorder.resumeRecording()
    state = .recording
  }

  // MARK: - Finalize & upload

  private func finalizeAndUpload() async {
    logger.info("[vm] finalizeAndUpload")
    do {
      let finished = try await recorder.stopRecording()
      recordingFileURL = finished.fileURL
      logger.info("[vm] Recording stopped: duration=\(finished.durationMS, privacy: .public)ms file=\(finished.fileURL.lastPathComponent, privacy: .public)")
      await beginUploadSequence()
    } catch {
      logger.error("[vm] stopRecording failed: \(error.localizedDescription, privacy: .public)")
      lastError = error.localizedDescription
      state = .error
    }
  }

  private func beginUploadSequence() async {
    guard let sessionID, let fileURL = recordingFileURL else {
      logger.error("[vm] beginUploadSequence: no sessionID or fileURL")
      lastError = "No recording to upload."
      state = .error
      return
    }

    state = .uploading
    lastError = nil

    let fileSize = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
    logger.info("[vm] Requesting upload ticket sessionID=\(sessionID.uuidString, privacy: .public) file=\(fileURL.lastPathComponent, privacy: .public) size=\(fileSize, privacy: .public)")

    scheduleTicketTimeout(sessionID: sessionID)
    await sync.sendSegmentStopped(
      WatchSegmentStoppedPayload(
        sessionID: sessionID,
        segmentIndex: 0,
        fileName: fileURL.lastPathComponent,
        durationMS: Int((recordingStartedAt.map { Date().timeIntervalSince($0) * 1000 }) ?? 0),
        startedAt: recordingStartedAt ?? .now,
        endedAt: Date(),
        sha256: nil,
        requestID: UUID()
      )
    )
  }

  // MARK: - Incoming messages

  private func handleUploadTicket(_ ticket: UploadTicket) async {
    logger.info("[vm] Received upload ticket sessionID=\(ticket.sessionID.uuidString, privacy: .public) expires=\(ticket.expiresAt.ISO8601Format(), privacy: .public)")
    ticketTimeoutTask?.cancel()

    guard state == .uploading else {
      logger.info("[vm] Ignoring ticket — state is \(self.state.rawValue, privacy: .public)")
      return
    }

    guard let fileURL = recordingFileURL, fileManager.fileExists(atPath: fileURL.path) else {
      logger.error("[vm] File missing for upload")
      lastError = "Recorded audio file is missing."
      state = .error
      await sync.sendUploadStatus(
        WatchUploadStatusPayload(
          sessionID: ticket.sessionID, segmentIndex: 0,
          status: .failed, bytes: nil, errorCode: "local_file_missing", requestID: UUID()
        )
      )
      return
    }

    do {
      var request = URLRequest(url: ticket.signedUploadURL)
      request.httpMethod = "PUT"
      request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
      logger.info("[vm] Uploading file \(fileURL.lastPathComponent, privacy: .public) to \(ticket.signedUploadURL.host() ?? "unknown", privacy: .public)")

      let (responseData, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(data: responseData, encoding: .utf8) ?? ""
        logger.error("[vm] Upload HTTP \(code, privacy: .public): \(body, privacy: .public)")
        throw NSError(domain: "WatchRecorder", code: code, userInfo: [NSLocalizedDescriptionKey: "Upload failed (HTTP \(code))"])
      }

      let fileAttributes = try? fileManager.attributesOfItem(atPath: fileURL.path)
      let bytes = (fileAttributes?[.size] as? NSNumber)?.int64Value
      logger.info("[vm] Upload succeeded, bytes=\(bytes ?? 0, privacy: .public)")

      await sync.sendUploadStatus(
        WatchUploadStatusPayload(
          sessionID: ticket.sessionID, segmentIndex: 0,
          status: .uploaded, bytes: bytes, errorCode: nil, requestID: UUID()
        )
      )

      // Give the phone time to PATCH the segment status to 'uploaded' in the DB
      // before we request finalization (which checks segment statuses).
      try? await Task.sleep(for: .milliseconds(500))
      await sendFinalizeAndReset(sessionID: ticket.sessionID)
    } catch {
      logger.error("[vm] Upload failed: \(error.localizedDescription, privacy: .public)")
      lastError = error.localizedDescription
      state = .error
      await sync.sendUploadStatus(
        WatchUploadStatusPayload(
          sessionID: ticket.sessionID, segmentIndex: 0,
          status: .failed, bytes: nil, errorCode: "direct_upload_failed", requestID: UUID()
        )
      )
    }
  }

  private func handlePhoneUploadStatus(_ payload: WatchUploadStatusPayload) async {
    logger.info("[vm] Phone upload status: segment=\(payload.segmentIndex, privacy: .public) status=\(payload.status.rawValue, privacy: .public) error=\(payload.errorCode ?? "nil", privacy: .public)")

    if payload.status == .failed {
      ticketTimeoutTask?.cancel()
      if payload.errorCode == "phone_not_signed_in" {
        phoneSignedIn = false
      }
      lastError = userFacingMessage(for: payload.errorCode)
      state = .error
    }
  }

  // MARK: - Finalize

  private func sendFinalizeAndReset(sessionID: UUID) async {
    logger.info("[vm] Sending finalize for session=\(sessionID.uuidString, privacy: .public)")
    await sync.sendFinalizeRequest(
      WatchFinalizePayload(
        sessionID: sessionID,
        endedAt: Date(),
        segmentCount: 1,
        requestID: UUID()
      )
    )
    cleanupRecordingFile()
    resetToIdle()
    logger.info("[vm] Session finalized and reset to idle")
  }

  // MARK: - Helpers

  private func resetToIdle() {
    state = .idle
    sessionID = nil
    recordingStartedAt = nil
    lastError = nil
    ticketTimeoutTask?.cancel()
    logger.info("[vm] Reset to idle")
  }

  private func cleanupRecordingFile() {
    guard let url = recordingFileURL else { return }
    try? fileManager.removeItem(at: url)
    recordingFileURL = nil
    logger.info("[vm] Cleaned up recording file")
  }

  private func scheduleTicketTimeout(sessionID: UUID) {
    ticketTimeoutTask?.cancel()
    ticketTimeoutTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(60))
      guard let self, self.state == .uploading, self.sessionID == sessionID else { return }
      self.logger.error("[vm] Upload ticket timeout for session=\(sessionID.uuidString, privacy: .public)")
      self.lastError = "Open the iPhone app, sign in if needed, then try again."
      self.state = .error
    }
  }

  private func userFacingMessage(for errorCode: String?) -> String {
    switch errorCode {
    case "phone_not_signed_in":
      return "Sign in on iPhone to upload recordings."
    case "ticket_issue_failed":
      return "Sign in on iPhone and try again."
    case "session_access_denied", "segment_access_denied":
      return "Sign in on iPhone to upload recordings."
    default:
      return errorCode ?? "Upload failed."
    }
  }
}
