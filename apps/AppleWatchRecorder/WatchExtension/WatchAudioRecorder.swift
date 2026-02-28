import Foundation

#if os(watchOS)
import AVFoundation

actor WatchAudioRecorder {
  struct FinishedSegment: Sendable {
    let fileURL: URL
    let startedAt: Date
    let endedAt: Date
    let durationMS: Int
  }

  private var recorder: AVAudioRecorder?
  private var startedAt: Date?

  func startRecording() throws -> URL {
    let audioSession = AVAudioSession.sharedInstance()
    try audioSession.setCategory(.playAndRecord, mode: .default)
    try audioSession.setActive(true)

    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("m4a")

    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
      AVSampleRateKey: 44_100,
      AVNumberOfChannelsKey: 1,
      AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]

    recorder = try AVAudioRecorder(url: fileURL, settings: settings)
    recorder?.prepareToRecord()
    recorder?.record()
    startedAt = Date()
    return fileURL
  }

  func stopRecording() throws -> FinishedSegment {
    guard let recorder, let startedAt else {
      throw NSError(domain: "WatchAudioRecorder", code: 0, userInfo: [NSLocalizedDescriptionKey: "Recorder is not active"])
    }

    recorder.stop()
    let endedAt = Date()
    let durationMS = Int(endedAt.timeIntervalSince(startedAt) * 1000)
    let fileURL = recorder.url
    self.recorder = nil
    self.startedAt = nil
    return FinishedSegment(fileURL: fileURL, startedAt: startedAt, endedAt: endedAt, durationMS: durationMS)
  }
}
#else
actor WatchAudioRecorder {
  struct FinishedSegment: Sendable {
    let fileURL: URL
    let startedAt: Date
    let endedAt: Date
    let durationMS: Int
  }

  func startRecording() throws -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("segment.m4a")
  }

  func stopRecording() throws -> FinishedSegment {
    FinishedSegment(
      fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("segment.m4a"),
      startedAt: .now,
      endedAt: .now,
      durationMS: 0
    )
  }
}
#endif
