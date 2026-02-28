import Foundation

enum SessionStatus: String, Codable, CaseIterable, Sendable {
  case syncPending = "sync_pending"
  case uploaded
  case transcribing
  case transcribed
  case summarizing
  case summarized
  case failed
}

enum SegmentUploadStatus: String, Codable, CaseIterable, Sendable {
  case pending
  case ticketIssued = "ticket_issued"
  case uploading
  case uploaded
  case failed
}

enum SummaryKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case `default` = "say_prompt_default"
  case actionItems = "say_prompt_action_items"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .default:
      return "Summary"
    case .actionItems:
      return "Action Items"
    }
  }
}

enum QueueOperationKind: String, Codable, CaseIterable, Sendable {
  case upsertSession
  case upsertSegment
  case requestUploadTicket
  case reconcileUpload
  case finalizeSession
  case retryPipeline
}

enum WatchTransferMessage: String, Codable, CaseIterable, Sendable {
  case sessionStarted
  case segmentStopped
  case uploadTicketResponse
  case uploadStatus
  case finalizeRequested
  case acknowledged
}

enum WatchRecorderState: String, Codable, CaseIterable, Sendable {
  case idle
  case recordingSegment
  case segmentStopped
  case awaitingUploadTicket
  case uploadingDirect
  case uploadSucceeded
  case uploadFailed
  case finalizingSession
}

struct AuthSession: Codable, Equatable, Sendable {
  let userID: UUID
  let email: String?
  let accessToken: String
}

struct SessionFeedItem: Identifiable, Codable, Hashable, Sendable {
  let sessionID: UUID
  let startedAt: Date
  let endedAt: Date?
  let status: SessionStatus
  let segmentCount: Int
  let totalDurationMS: Int?
  let userNotes: String?
  let latestSummaryExcerpt: String?
  let questionCount: Int
  let latestErrorCode: String?
  let updatedAt: Date

  var id: UUID { sessionID }
}

struct SummaryRecord: Identifiable, Codable, Hashable, Sendable {
  let summaryID: UUID
  let promptName: String
  let promptVersion: Int
  let summaryText: String
  let model: String?
  let createdAt: Date

  var id: UUID { summaryID }

  var kind: SummaryKind? {
    SummaryKind(rawValue: promptName)
  }
}

struct QuestionRecord: Identifiable, Codable, Hashable, Sendable {
  let questionID: UUID
  let question: String
  let answer: String?
  let status: String
  let model: String?
  let createdAt: Date
  let answeredAt: Date?

  var id: UUID { questionID }
}

struct SessionDetail: Identifiable, Codable, Hashable, Sendable {
  let sessionID: UUID
  let startedAt: Date
  let endedAt: Date?
  let status: SessionStatus
  let segmentCount: Int
  let totalDurationMS: Int?
  let latestErrorCode: String?
  let latestErrorMessage: String?
  let transcriptText: String?
  let transcriptLanguage: String?
  let transcriptModel: String?
  let userNotes: String?
  let summaries: [SummaryRecord]
  let questions: [QuestionRecord]

  var id: UUID { sessionID }
}

struct QueueRecord: Identifiable, Codable, Hashable, Sendable {
  let queueID: UUID
  let operationKind: QueueOperationKind
  let sessionID: UUID?
  let segmentIndex: Int?
  let payloadJSON: String
  let fileURL: URL?
  let attemptCount: Int
  let nextAttemptAt: Date
  let lastErrorCode: String?
  let lastErrorMessage: String?
  let createdAt: Date
  let updatedAt: Date

  var id: UUID { queueID }
}

struct UploadTicket: Codable, Hashable, Sendable {
  let sessionID: UUID
  let segmentIndex: Int
  let storagePath: String
  let signedUploadURL: URL
  let expiresAt: Date
}

struct SessionSegmentDraft: Identifiable, Codable, Hashable, Sendable {
  let id: UUID
  let sessionID: UUID
  let segmentIndex: Int
  let fileName: String
  let fileURL: URL
  let startedAt: Date
  let endedAt: Date
  let durationMS: Int
  let sha256: String?
  var uploadStatus: SegmentUploadStatus
  var uploadAttempts: Int
}

struct WatchSessionDraft: Codable, Hashable, Sendable {
  let sessionID: UUID
  let sourceDeviceID: String
  let startedAt: Date
  var endedAt: Date?
  var segments: [SessionSegmentDraft]
}

struct DeviceHealthSnapshot: Codable, Hashable, Sendable {
  let currentDeviceID: String
  let queueDepth: Int
  let lastSyncErrors: [String]
  let weeklySpendPercent: Double
  let dailyAudioUsageSeconds: Int
}

struct TelemetryEvent: Codable, Hashable, Sendable {
  let eventID: UUID
  let eventName: String
  let eventVersion: Int
  let occurredAt: Date
  let appSessionID: UUID?
  let conversationSessionID: UUID?
  let properties: [String: String]
}

struct WatchSessionStartedPayload: Codable, Hashable, Sendable {
  let sessionID: UUID
  let sourceDeviceID: String
  let startedAt: Date
  let requestID: UUID
}

struct WatchSegmentStoppedPayload: Codable, Hashable, Sendable {
  let sessionID: UUID
  let segmentIndex: Int
  let fileName: String
  let durationMS: Int
  let startedAt: Date
  let endedAt: Date
  let sha256: String?
  let requestID: UUID
}

struct WatchUploadTicketResponsePayload: Codable, Hashable, Sendable {
  let sessionID: UUID
  let segmentIndex: Int
  let storagePath: String
  let signedUploadURL: URL
  let expiresAt: Date
  let requestID: UUID
}

struct WatchUploadStatusPayload: Codable, Hashable, Sendable {
  let sessionID: UUID
  let segmentIndex: Int
  let status: SegmentUploadStatus
  let bytes: Int64?
  let errorCode: String?
  let requestID: UUID
}

struct WatchFinalizePayload: Codable, Hashable, Sendable {
  let sessionID: UUID
  let endedAt: Date
  let segmentCount: Int
  let requestID: UUID
}
