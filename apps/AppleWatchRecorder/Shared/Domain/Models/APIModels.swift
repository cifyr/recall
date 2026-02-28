import Foundation

struct APIEnvelope<DataType: Decodable>: Decodable {
  let ok: Bool
  let data: DataType
  let meta: APIMeta
}

struct APIMeta: Decodable {
  let requestID: UUID

  enum CodingKeys: String, CodingKey {
    case requestID = "request_id"
  }
}

struct SessionFeedItemDTO: Decodable {
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

  enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case startedAt = "started_at"
    case endedAt = "ended_at"
    case status
    case segmentCount = "segment_count"
    case totalDurationMS = "total_duration_ms"
    case userNotes = "user_notes"
    case latestSummaryExcerpt = "latest_summary_excerpt"
    case questionCount = "question_count"
    case latestErrorCode = "latest_error_code"
    case updatedAt = "updated_at"
  }

  func model() -> SessionFeedItem {
    SessionFeedItem(
      sessionID: sessionID,
      startedAt: startedAt,
      endedAt: endedAt,
      status: status,
      segmentCount: segmentCount,
      totalDurationMS: totalDurationMS,
      userNotes: userNotes,
      latestSummaryExcerpt: latestSummaryExcerpt,
      questionCount: questionCount,
      latestErrorCode: latestErrorCode,
      updatedAt: updatedAt
    )
  }
}

struct SummaryRecordDTO: Decodable {
  let summaryID: UUID
  let promptName: String
  let promptVersion: Int
  let summaryText: String
  let model: String?
  let createdAt: Date

  enum CodingKeys: String, CodingKey {
    case summaryID = "summary_id"
    case promptName = "prompt_name"
    case promptVersion = "prompt_version"
    case summaryText = "summary_text"
    case model
    case createdAt = "created_at"
  }

  func modelValue() -> SummaryRecord {
    SummaryRecord(
      summaryID: summaryID,
      promptName: promptName,
      promptVersion: promptVersion,
      summaryText: summaryText,
      model: model,
      createdAt: createdAt
    )
  }
}

struct QuestionRecordDTO: Decodable {
  let questionID: UUID
  let question: String
  let answer: String?
  let status: String
  let model: String?
  let createdAt: Date
  let answeredAt: Date?

  enum CodingKeys: String, CodingKey {
    case questionID = "question_id"
    case question
    case answer
    case status
    case model
    case createdAt = "created_at"
    case answeredAt = "answered_at"
  }

  func modelValue() -> QuestionRecord {
    QuestionRecord(
      questionID: questionID,
      question: question,
      answer: answer,
      status: status,
      model: model,
      createdAt: createdAt,
      answeredAt: answeredAt
    )
  }
}

struct SessionDetailDTO: Decodable {
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
  let summaries: [SummaryRecordDTO]
  let questions: [QuestionRecordDTO]

  enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case startedAt = "started_at"
    case endedAt = "ended_at"
    case status
    case segmentCount = "segment_count"
    case totalDurationMS = "total_duration_ms"
    case latestErrorCode = "latest_error_code"
    case latestErrorMessage = "latest_error_message"
    case transcriptText = "transcript_text"
    case transcriptLanguage = "transcript_language"
    case transcriptModel = "transcript_model"
    case userNotes = "user_notes"
    case summaries
    case questions
  }

  func model() -> SessionDetail {
    SessionDetail(
      sessionID: sessionID,
      startedAt: startedAt,
      endedAt: endedAt,
      status: status,
      segmentCount: segmentCount,
      totalDurationMS: totalDurationMS,
      latestErrorCode: latestErrorCode,
      latestErrorMessage: latestErrorMessage,
      transcriptText: transcriptText,
      transcriptLanguage: transcriptLanguage,
      transcriptModel: transcriptModel,
      userNotes: userNotes,
      summaries: summaries.map { $0.modelValue() },
      questions: questions.map { $0.modelValue() }
    )
  }
}

struct AskSessionResponse: Decodable {
  let questionID: UUID
  let sessionID: UUID
  let answer: String
  let model: String

  enum CodingKeys: String, CodingKey {
    case questionID = "question_id"
    case sessionID = "session_id"
    case answer
    case model
  }
}
