import Foundation
import Observation

@MainActor
@Observable
final class WatchRecorderViewModel {
  private let recorder: WatchAudioRecorder
  private let sync: WatchWatchConnectivityBroker
  private let userDefaults: UserDefaults
  private let deviceID: String

  private(set) var state: WatchRecorderState = .idle
  private(set) var currentDraft: WatchSessionDraft?
  private(set) var lastError: String?
  private(set) var lastTicketExpiry: Date?

  var canFinalizeSession: Bool {
    guard let currentDraft, !currentDraft.segments.isEmpty else { return false }
    return currentDraft.segments.allSatisfy { $0.uploadStatus == .uploaded }
  }

  init(
    recorder: WatchAudioRecorder = WatchAudioRecorder(),
    sync: WatchWatchConnectivityBroker = WatchWatchConnectivityBroker(),
    userDefaults: UserDefaults = .standard
  ) {
    self.recorder = recorder
    self.sync = sync
    self.userDefaults = userDefaults
    self.deviceID = userDefaults.string(forKey: "WatchDeviceID") ?? UUID().uuidString
    userDefaults.set(deviceID, forKey: "WatchDeviceID")

    sync.onUploadTicketReceived = { [weak self] ticket in
      guard let self else { return }
      Task {
        await self.consume(ticket: ticket)
      }
    }
  }

  func bootstrap() async {
    await sync.activate()
    restoreDraft()
  }

  func handlePrimaryTap() async {
    switch state {
    case .idle, .segmentStopped, .uploadSucceeded, .uploadFailed:
      if await retryPendingUploadIfNeeded() {
        return
      }
      await startRecording()
    case .recordingSegment:
      await stopRecording()
    case .awaitingUploadTicket, .uploadingDirect, .finalizingSession:
      break
    }
  }

  func finalizeSession() async {
    guard var draft = currentDraft, state != .recordingSegment else { return }
    guard !draft.segments.isEmpty else {
      lastError = "Record at least one segment before finalizing."
      return
    }
    guard draft.segments.allSatisfy({ $0.uploadStatus == .uploaded }) else {
      lastError = "Wait for all uploads to finish before finalizing."
      state = .uploadFailed
      return
    }

    state = .finalizingSession
    draft.endedAt = Date()
    lastError = nil

    await sync.sendFinalizeRequest(
      WatchFinalizePayload(
        sessionID: draft.sessionID,
        endedAt: draft.endedAt ?? .now,
        segmentCount: draft.segments.count,
        requestID: UUID()
      )
    )
    currentDraft = nil
    lastTicketExpiry = nil
    persistDraft()
    state = .idle
  }

  private func startRecording() async {
    do {
      if currentDraft == nil {
        let draft = WatchSessionDraft(
          sessionID: UUID(),
          sourceDeviceID: deviceID,
          startedAt: .now,
          endedAt: nil,
          segments: []
        )
        currentDraft = draft
        await sync.sendSessionStarted(
          WatchSessionStartedPayload(
            sessionID: draft.sessionID,
            sourceDeviceID: deviceID,
            startedAt: draft.startedAt,
            requestID: UUID()
          )
        )
      }

      _ = try await recorder.startRecording()
      state = .recordingSegment
      lastError = nil
      persistDraft()
    } catch {
      lastError = error.localizedDescription
      state = .uploadFailed
    }
  }

  private func stopRecording() async {
    guard var draft = currentDraft else { return }

    do {
      let finished = try await recorder.stopRecording()
      let segmentIndex = draft.segments.count
      let segment = SessionSegmentDraft(
        id: UUID(),
        sessionID: draft.sessionID,
        segmentIndex: segmentIndex,
        fileName: finished.fileURL.lastPathComponent,
        fileURL: finished.fileURL,
        startedAt: finished.startedAt,
        endedAt: finished.endedAt,
        durationMS: finished.durationMS,
        sha256: nil,
        uploadStatus: .pending,
        uploadAttempts: 0
      )
      draft.segments.append(segment)
      currentDraft = draft
      state = .awaitingUploadTicket
      persistDraft()

      await sync.sendSegmentStopped(
        WatchSegmentStoppedPayload(
          sessionID: draft.sessionID,
          segmentIndex: segmentIndex,
          fileName: finished.fileURL.lastPathComponent,
          durationMS: finished.durationMS,
          startedAt: finished.startedAt,
          endedAt: finished.endedAt,
          sha256: nil,
          requestID: UUID()
        )
      )
    } catch {
      lastError = error.localizedDescription
      state = .uploadFailed
    }
  }

  private func consume(ticket: UploadTicket) async {
    guard var draft = currentDraft else { return }
    guard let index = draft.segments.firstIndex(where: { $0.segmentIndex == ticket.segmentIndex }) else { return }

    lastTicketExpiry = ticket.expiresAt
    state = .uploadingDirect
    var segment = draft.segments[index]
    segment.uploadAttempts += 1
    segment.uploadStatus = .uploading
    draft.segments[index] = segment
    currentDraft = draft
    persistDraft()

    do {
      var request = URLRequest(url: ticket.signedUploadURL)
      request.httpMethod = "PUT"
      request.setValue("audio/m4a", forHTTPHeaderField: "Content-Type")
      let (_, response) = try await URLSession.shared.upload(for: request, fromFile: segment.fileURL)
      guard let httpResponse = response as? HTTPURLResponse, (200 ..< 300).contains(httpResponse.statusCode) else {
        throw NSError(domain: "WatchRecorder", code: 0, userInfo: [NSLocalizedDescriptionKey: "Direct upload failed"])
      }

      if var refreshed = currentDraft,
         let refreshedIndex = refreshed.segments.firstIndex(where: { $0.segmentIndex == ticket.segmentIndex }) {
        refreshed.segments[refreshedIndex].uploadStatus = .uploaded
        currentDraft = refreshed
      }
      state = .uploadSucceeded
      lastError = nil
      persistDraft()

      let fileAttributes = try? FileManager.default.attributesOfItem(atPath: segment.fileURL.path)
      let bytes = (fileAttributes?[.size] as? NSNumber)?.int64Value
      await sync.sendUploadStatus(
        WatchUploadStatusPayload(
          sessionID: ticket.sessionID,
          segmentIndex: ticket.segmentIndex,
          status: .uploaded,
          bytes: bytes,
          errorCode: nil,
          requestID: UUID()
        )
      )
      state = .idle
    } catch {
      lastError = error.localizedDescription
      state = .uploadFailed
      await sync.sendUploadStatus(
        WatchUploadStatusPayload(
          sessionID: ticket.sessionID,
          segmentIndex: ticket.segmentIndex,
          status: .failed,
          bytes: nil,
          errorCode: "direct_upload_failed",
          requestID: UUID()
        )
      )
    }
  }

  private func restoreDraft() {
    guard let data = userDefaults.data(forKey: "WatchSessionDraft") else { return }
    currentDraft = try? JSONCoding.decoder.decode(WatchSessionDraft.self, from: data)
    if currentDraft?.segments.contains(where: { $0.uploadStatus != .uploaded }) == true {
      state = .uploadFailed
    }
  }

  private func persistDraft() {
    guard let currentDraft else {
      userDefaults.removeObject(forKey: "WatchSessionDraft")
      return
    }
    let data = try? JSONCoding.encoder.encode(currentDraft)
    userDefaults.set(data, forKey: "WatchSessionDraft")
  }

  @discardableResult
  private func retryPendingUploadIfNeeded() async -> Bool {
    guard let draft = currentDraft else { return false }
    guard let segment = draft.segments.first(where: { $0.uploadStatus != .uploaded }) else { return false }

    state = .awaitingUploadTicket
    lastError = nil
    await sync.sendSegmentStopped(
      WatchSegmentStoppedPayload(
        sessionID: draft.sessionID,
        segmentIndex: segment.segmentIndex,
        fileName: segment.fileName,
        durationMS: segment.durationMS,
        startedAt: segment.startedAt,
        endedAt: segment.endedAt,
        sha256: segment.sha256,
        requestID: UUID()
      )
    )
    return true
  }
}
