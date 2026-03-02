import Foundation

#if os(watchOS)
@preconcurrency import AVFoundation
import os

actor WatchAudioRecorder {
  struct FinishedRecording: Sendable {
    let fileURL: URL
    let startedAt: Date
    let endedAt: Date
    let durationMS: Int
  }

  private var recorder: AVAudioRecorder?
  private var startedAt: Date?

  var isRecording: Bool { recorder?.isRecording == true }
  var isPaused: Bool { recorder != nil && !(recorder?.isRecording ?? false) }

  private let logger = Logger(subsystem: "com.caden.watchrecorder", category: "WatchAudioRecorder")

  enum RecorderError: LocalizedError, Sendable {
    case alreadyRecording
    case notRecording
    case microphonePermissionDenied
    case audioSessionActivationFailed(String)
    case recorderInitFailed(String)

    var errorDescription: String? {
      switch self {
      case .alreadyRecording:
        return "Recording is already in progress"
      case .notRecording:
        return "No active recording to stop or pause"
      case .microphonePermissionDenied:
        return "Microphone permission denied. Enable it in Settings > Privacy > Microphone."
      case .audioSessionActivationFailed(let message):
        return "Failed to activate audio session: \(message)"
      case .recorderInitFailed(let message):
        return "Failed to initialize recorder: \(message)"
      }
    }
  }

  private func ensureMicrophonePermission() async throws {
    let status = AVAudioApplication.shared.recordPermission
    logger.info("[mic] Current permission status: \(String(describing: status), privacy: .public)")
    switch status {
    case .granted:
      return
    case .denied:
      logger.error("[mic] Permission previously denied")
      throw RecorderError.microphonePermissionDenied
    case .undetermined:
      logger.info("[mic] Requesting permission…")
      let granted = await AVAudioApplication.requestRecordPermission()
      logger.info("[mic] User responded: granted=\(granted, privacy: .public)")
      if !granted { throw RecorderError.microphonePermissionDenied }
    @unknown default:
      logger.error("[mic] Unknown permission state")
      throw RecorderError.microphonePermissionDenied
    }
  }

  func preflightMicrophonePermission() async throws {
    logger.info("[preflight] Checking microphone permission")
    try await ensureMicrophonePermission()
    logger.info("[preflight] Microphone permission OK")
  }

  /// Pre-acquires the audio hardware so the first tap-to-record is instant.
  func warmUpAudioSession() {
    logger.info("[warmup] Pre-activating audio session")
    let audioSession = AVAudioSession.sharedInstance()
    do {
      try audioSession.setCategory(.playAndRecord, mode: .default)
      try audioSession.setActive(true)
      logger.info("[warmup] Audio session ready")
    } catch {
      logger.error("[warmup] Audio session warmup failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  func startRecording() async throws -> URL {
    logger.info("[start] startRecording called, recorder=\(self.recorder == nil ? "nil" : "exists", privacy: .public)")

    if recorder != nil {
      logger.error("[start] Recorder already exists — aborting")
      throw RecorderError.alreadyRecording
    }

    try await ensureMicrophonePermission()

    // Ensure session is active (no-op if already warmed up during bootstrap).
    let audioSession = AVAudioSession.sharedInstance()
    do {
      try audioSession.setCategory(.playAndRecord, mode: .default)
      try audioSession.setActive(true)
      logger.info("[start] Audio session confirmed active")
    } catch {
      logger.error("[start] Audio session activation failed: \(error.localizedDescription, privacy: .public)")
      throw RecorderError.audioSessionActivationFailed(error.localizedDescription)
    }

    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("wav")

    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 44_100,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false
    ]

    do {
      recorder = try AVAudioRecorder(url: fileURL, settings: settings)
      recorder?.prepareToRecord()
      let started = recorder?.record() ?? false
      if started {
        startedAt = Date()
        logger.info("[start] Recording started -> \(fileURL.lastPathComponent, privacy: .public)")
        return fileURL
      } else {
        recorder = nil
        logger.error("[start] AVAudioRecorder.record() returned false")
        throw RecorderError.recorderInitFailed("record() returned false")
      }
    } catch {
      recorder = nil
      logger.error("[start] AVAudioRecorder init failed: \(error.localizedDescription, privacy: .public)")
      throw RecorderError.recorderInitFailed(error.localizedDescription)
    }
  }

  func pauseRecording() {
    logger.info("[pause] pauseRecording called, isRecording=\(self.isRecording, privacy: .public)")
    recorder?.pause()
    logger.info("[pause] Recorder paused")
  }

  func resumeRecording() {
    logger.info("[resume] resumeRecording called, recorder=\(self.recorder == nil ? "nil" : "exists", privacy: .public)")
    recorder?.record()
    logger.info("[resume] Recorder resumed")
  }

  func stopRecording() throws -> FinishedRecording {
    logger.info("[stop] stopRecording called, recorder=\(self.recorder == nil ? "nil" : "exists", privacy: .public), startedAt=\(String(describing: self.startedAt), privacy: .public)")

    guard let recorder, let startedAt else {
      logger.error("[stop] No active recorder or startedAt is nil")
      throw RecorderError.notRecording
    }

    recorder.stop()
    let endedAt = Date()
    let durationMS = Int(endedAt.timeIntervalSince(startedAt) * 1000)
    let fileURL = recorder.url
    self.recorder = nil
    self.startedAt = nil

    let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
    logger.info("[stop] Recording stopped: file=\(fileURL.lastPathComponent, privacy: .public) duration=\(durationMS, privacy: .public)ms size=\(fileSize, privacy: .public)bytes")

    // Keep the audio session active so the next recording starts instantly.

    return FinishedRecording(fileURL: fileURL, startedAt: startedAt, endedAt: endedAt, durationMS: durationMS)
  }

  func discardRecording() {
    logger.info("[discard] Discarding current recording, recorder=\(self.recorder == nil ? "nil" : "exists", privacy: .public)")
    if let recorder {
      let url = recorder.url
      recorder.stop()
      try? FileManager.default.removeItem(at: url)
      logger.info("[discard] Removed file: \(url.lastPathComponent, privacy: .public)")
    }
    self.recorder = nil
    self.startedAt = nil
    do {
      try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    } catch {
      logger.error("[discard] Failed to deactivate audio session: \(error.localizedDescription, privacy: .public)")
    }
  }
}
#else
actor WatchAudioRecorder {
  struct FinishedRecording: Sendable {
    let fileURL: URL
    let startedAt: Date
    let endedAt: Date
    let durationMS: Int
  }

  var isRecording: Bool { false }
  var isPaused: Bool { false }

  func preflightMicrophonePermission() async throws {}
  func warmUpAudioSession() {}
  func startRecording() async throws -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("segment.wav")
  }
  func pauseRecording() {}
  func resumeRecording() {}
  func stopRecording() throws -> FinishedRecording {
    FinishedRecording(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("segment.wav"), startedAt: .now, endedAt: .now, durationMS: 0)
  }
  func discardRecording() {}
}
#endif
