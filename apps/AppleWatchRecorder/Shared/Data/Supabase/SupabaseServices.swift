import Foundation
import OSLog

#if canImport(Supabase)
import Supabase
#endif

private struct NotesUpdateRequest: Encodable {
  let sessionID: UUID
  let notes: String

  enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case notes
  }
}

private struct AskSessionRequest: Encodable {
  let sessionID: UUID
  let question: String
  let includeUserNotes: Bool

  enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case question
    case includeUserNotes = "include_user_notes"
  }
}

private struct FinalizeSessionRequest: Encodable {
  let sessionID: UUID
  let finalizeReason: String

  enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case finalizeReason = "finalize_reason"
  }
}

private struct CreateUploadTicketRequest: Encodable {
  let sessionID: UUID
  let segmentIndex: Int
  let contentType: String

  enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case segmentIndex = "segment_index"
    case contentType = "content_type"
  }
}

private struct CreateUploadTicketResponse: Decodable {
  let sessionID: UUID
  let segmentIndex: Int
  let storagePath: String
  let signedUploadURL: URL
  let expiresAt: Date

  enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case segmentIndex = "segment_index"
    case storagePath = "storage_path"
    case signedUploadURL = "signed_upload_url"
    case expiresAt = "expires_at"
  }
}

private struct HealthSnapshotRequest: Encodable {
  let deviceID: String

  enum CodingKeys: String, CodingKey {
    case deviceID = "device_id"
  }
}

private struct HealthSnapshotResponse: Decodable {
  let currentDeviceID: String
  let lastSyncErrors: [String]
  let weeklySpendPercent: Double
  let dailyAudioUsageSeconds: Int

  enum CodingKeys: String, CodingKey {
    case currentDeviceID = "current_device_id"
    case lastSyncErrors = "last_sync_errors"
    case weeklySpendPercent = "weekly_spend_percent"
    case dailyAudioUsageSeconds = "daily_audio_usage_seconds"
  }
}

private struct GenericSuccessResponse: Decodable {
  let sessionID: UUID?
  let notesUpdated: Bool?

  enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case notesUpdated = "notes_updated"
  }
}

private struct PostgrestSessionUpsert: Encodable {
  let id: UUID
  let userID: UUID
  let sourceDeviceID: String
  let startedAt: Date
  let endedAt: Date?
  let status: SessionStatus
  let requestID: UUID

  enum CodingKeys: String, CodingKey {
    case id
    case userID = "user_id"
    case sourceDeviceID = "source_device_id"
    case startedAt = "started_at"
    case endedAt = "ended_at"
    case status
    case requestID = "request_id"
  }
}

private struct PostgrestSegmentUpsert: Encodable {
  let sessionID: UUID
  let userID: UUID
  let segmentIndex: Int
  let storagePath: String
  let uploadStatus: SegmentUploadStatus
  let uploadedFrom: String
  let durationMS: Int
  let contentSHA256: String?
  let startedAt: Date
  let endedAt: Date
  let requestID: UUID

  enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case userID = "user_id"
    case segmentIndex = "segment_index"
    case storagePath = "storage_path"
    case uploadStatus = "upload_status"
    case uploadedFrom = "uploaded_from"
    case durationMS = "duration_ms"
    case contentSHA256 = "content_sha256"
    case startedAt = "started_at"
    case endedAt = "ended_at"
    case requestID = "request_id"
  }
}

private struct PostgrestDeviceUpsert: Encodable {
  let userID: UUID
  let deviceID: String
  let platform: String
  let appVersion: String
  let osVersion: String
  let lastSeenAt: Date

  enum CodingKeys: String, CodingKey {
    case userID = "user_id"
    case deviceID = "device_id"
    case platform
    case appVersion = "app_version"
    case osVersion = "os_version"
    case lastSeenAt = "last_seen_at"
  }
}

actor SupabaseAuthClient: AuthProviding {
  private let configuration: AppConfiguration
  private let authStorageKey: String
  private let logger = Logger(subsystem: "com.caden.watchrecorder", category: "supabase-auth")
  private(set) var session: AuthSession?

  #if canImport(Supabase)
  private lazy var client: SupabaseClient? = {
    guard let url = configuration.supabaseURL, !configuration.supabaseKey.isEmpty else { return nil }
    let options = SupabaseClientOptions(
      auth: .init(
        redirectToURL: configuration.redirectURL,
        storageKey: authStorageKey,
        autoRefreshToken: true,
        emitLocalSessionAsInitialSession: true
      )
    )
    return SupabaseClient(supabaseURL: url, supabaseKey: configuration.supabaseKey, options: options)
  }()
  #endif

  init(configuration: AppConfiguration) {
    self.configuration = configuration
    let host = configuration.supabaseURL?.host() ?? "unconfigured"
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.caden.watchrecorder"
    authStorageKey = "\(bundleIdentifier).supabase.auth.\(host)"
  }

  nonisolated var isConfigured: Bool { configuration.isConfigured }

  func currentSession() async -> AuthSession? {
    guard isConfigured else { return session }
    #if canImport(Supabase)
    guard let client else {
      logger.error("[auth] currentSession: client is nil")
      return session
    }
    do {
      let activeSession = try await validSession(using: client)
      let mapped = mapSession(activeSession)
      await client.auth.startAutoRefresh()
      session = mapped
      logger.info("[auth] currentSession: token valid, user=\(mapped.userID.uuidString.prefix(8), privacy: .public)")
      return mapped
    } catch {
      logger.error("[auth] currentSession failed: \(error.localizedDescription, privacy: .public)")
      session = nil
      return nil
    }
    #else
    return session
    #endif
  }

  func refreshSession() async -> AuthSession? {
    guard isConfigured else { return session }
    #if canImport(Supabase)
    guard let client else {
      logger.error("[auth] refreshSession: client is nil")
      return session
    }
    do {
      let refreshedSession = try await client.auth.refreshSession()
      let mapped = mapSession(refreshedSession)
      await client.auth.startAutoRefresh()
      session = mapped
      logger.info("[auth] refreshSession succeeded, user=\(mapped.userID.uuidString.prefix(8), privacy: .public)")
      return mapped
    } catch {
      logger.error("[auth] refreshSession failed: \(error.localizedDescription, privacy: .public)")
      session = nil
      return nil
    }
    #else
    return session
    #endif
  }

  func restoreSession() async {
    guard isConfigured else { return }
    #if canImport(Supabase)
    _ = await currentSession()
    #endif
  }

  func sendEmailCode(to email: String) async throws {
    guard isConfigured else { throw NetworkError.notConfigured }
    #if canImport(Supabase)
    guard let client else { throw NetworkError.notConfigured }
    try await client.auth.signInWithOTP(email: email)
    #else
    throw NetworkError.notConfigured
    #endif
  }

  func verifyEmailCode(email: String, code: String) async throws {
    guard isConfigured else { throw NetworkError.notConfigured }
    #if canImport(Supabase)
    guard let client else { throw NetworkError.notConfigured }
    let response = try await client.auth.verifyOTP(
      email: email,
      token: code,
      type: .email
    )
    let authSession: Session?
    if let responseSession = response.session {
      authSession = responseSession
    } else {
      authSession = try? await validSession(using: client)
    }
    guard let authSession else {
      throw NetworkError.invalidResponse
    }
    await client.auth.startAutoRefresh()
    session = mapSession(authSession)
    #else
    throw NetworkError.notConfigured
    #endif
  }

  func signOut() async throws {
    #if canImport(Supabase)
    await client?.auth.stopAutoRefresh()
    try await client?.auth.signOut()
    #endif
    session = nil
  }

  #if canImport(Supabase)
  private func validSession(using client: SupabaseClient) async throws -> Session {
    let activeSession = try await client.auth.session
    if activeSession.isExpired {
      return try await client.auth.refreshSession(refreshToken: activeSession.refreshToken)
    }
    return activeSession
  }

  private func mapSession(_ session: Session) -> AuthSession {
    AuthSession(
      userID: UUID(uuidString: String(describing: session.user.id)) ?? UUID(),
      email: session.user.email,
      accessToken: session.accessToken
    )
  }
  #endif
}

actor PreviewSessionRepository: SessionRepository {
  private var sessions: [SessionFeedItem]
  private var details: [UUID: SessionDetail]

  init() {
    let sessionID = UUID()
    sessions = [
      SessionFeedItem(
        sessionID: sessionID,
        startedAt: .now.addingTimeInterval(-1800),
        endedAt: .now.addingTimeInterval(-1200),
        status: .summarized,
        segmentCount: 3,
        totalDurationMS: 420_000,
        userNotes: "Budget numbers are still pending.",
        latestSummaryExcerpt: "Discussed a watch-first recorder flow with Supabase-backed transcription.",
        questionCount: 1,
        latestErrorCode: nil,
        updatedAt: .now
      ),
    ]
    details = [
      sessionID: SessionDetail(
        sessionID: sessionID,
        startedAt: .now.addingTimeInterval(-1800),
        endedAt: .now.addingTimeInterval(-1200),
        status: .summarized,
        segmentCount: 3,
        totalDurationMS: 420_000,
        latestErrorCode: nil,
        latestErrorMessage: nil,
        transcriptText: "This is preview transcript content for the session detail screen.",
        transcriptLanguage: "en",
        transcriptModel: "whisper-1",
        userNotes: "Budget numbers are still pending.",
        summaries: [
          SummaryRecord(
            summaryID: UUID(),
            promptName: SummaryKind.default.rawValue,
            promptVersion: 1,
            summaryText: "The conversation covered the Apple Watch capture surface and the Supabase processing pipeline.",
            model: "gpt-4o-mini",
            createdAt: .now
          ),
          SummaryRecord(
            summaryID: UUID(),
            promptName: SummaryKind.actionItems.rawValue,
            promptVersion: 1,
            summaryText: "1. Implement the Supabase schema. 2. Build the watch recorder. 3. Test TestFlight pairing.",
            model: "gpt-4o-mini",
            createdAt: .now
          ),
        ],
        questions: []
      ),
    ]
  }

  func registerDevice(platform: String, deviceID: String) async throws {}
  func loadSessions() async throws -> [SessionFeedItem] { sessions }
  func loadSessionDetail(sessionID: UUID) async throws -> SessionDetail { details[sessionID] ?? details.values.first! }
  func deleteAllSessions() async throws {}
  func upsertSession(_ draft: WatchSessionDraft) async throws {}
  func upsertSegment(_ segment: SessionSegmentDraft, userID: UUID) async throws {}
  func createUploadTicket(sessionID: UUID, segmentIndex: Int) async throws -> UploadTicket {
    UploadTicket(
      sessionID: sessionID,
      segmentIndex: segmentIndex,
      storagePath: "u/demo/s/\(sessionID.uuidString)/segments/\(segmentIndex).m4a",
      signedUploadURL: URL(string: "https://example.com/upload")!,
      expiresAt: .now.addingTimeInterval(600)
    )
  }
  func markSegmentUploaded(sessionID: UUID, segmentIndex: Int, uploadedFrom: String, bytes: Int64?) async throws {}
  func finalizeSession(sessionID: UUID) async throws {}
  func retryPipeline(sessionID: UUID) async throws {}
  func updateNotes(sessionID: UUID, notes: String) async throws {
    guard var detail = details[sessionID] else { return }
    detail = SessionDetail(
      sessionID: detail.sessionID,
      startedAt: detail.startedAt,
      endedAt: detail.endedAt,
      status: detail.status,
      segmentCount: detail.segmentCount,
      totalDurationMS: detail.totalDurationMS,
      latestErrorCode: detail.latestErrorCode,
      latestErrorMessage: detail.latestErrorMessage,
      transcriptText: detail.transcriptText,
      transcriptLanguage: detail.transcriptLanguage,
      transcriptModel: detail.transcriptModel,
      userNotes: notes,
      summaries: detail.summaries,
      questions: detail.questions
    )
    details[sessionID] = detail
  }
  func askQuestion(sessionID: UUID, question: String, includeUserNotes: Bool) async throws -> AskSessionResponse {
    AskSessionResponse(questionID: UUID(), sessionID: sessionID, answer: "Preview answer for: \(question)", model: "gpt-4o-mini")
  }
  func healthSnapshot(deviceID: String) async throws -> DeviceHealthSnapshot {
    DeviceHealthSnapshot(
      currentDeviceID: deviceID,
      queueDepth: 0,
      lastSyncErrors: [],
      weeklySpendPercent: 12,
      dailyAudioUsageSeconds: 900
    )
  }
}

actor SupabaseSessionRepository: SessionRepository {
  private let configuration: AppConfiguration
  private let authProvider: AuthProviding
  private let edgeClient: EdgeFunctionClient
  private let urlSession: URLSession

  init(configuration: AppConfiguration, authProvider: AuthProviding, edgeClient: EdgeFunctionClient, urlSession: URLSession = .shared) {
    self.configuration = configuration
    self.authProvider = authProvider
    self.edgeClient = edgeClient
    self.urlSession = urlSession
  }

  func registerDevice(platform: String, deviceID: String) async throws {
    guard
      let session = await authProvider.currentSession(),
      let baseURL = configuration.supabaseURL
    else { throw NetworkError.unauthorized }

    let payload = PostgrestDeviceUpsert(
      userID: session.userID,
      deviceID: deviceID,
      platform: platform,
      appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
      osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
      lastSeenAt: .now
    )
    try await postgrestWrite(
      baseURL: baseURL,
      table: "user_devices",
      payload: payload,
      accessToken: session.accessToken,
      onConflict: "user_id,device_id"
    )
  }

  func loadSessions() async throws -> [SessionFeedItem] {
    guard
      let session = await authProvider.currentSession(),
      let baseURL = configuration.supabaseURL
    else { return [] }

    let path = "/rest/v1/session_feed_view?select=*&order=started_at.desc"
    let items: [SessionFeedItemDTO] = try await postgrestRead(
      baseURL: baseURL,
      path: path,
      accessToken: session.accessToken
    )
    return items.map { $0.model() }
  }

  func deleteAllSessions() async throws {
    guard
      let session = await authProvider.currentSession(),
      let baseURL = configuration.supabaseURL
    else { throw NetworkError.unauthorized }
    try await postgrestDelete(
      baseURL: baseURL,
      table: "conversation_sessions",
      query: "user_id=eq.\(session.userID.uuidString)",
      accessToken: session.accessToken
    )
  }

  func loadSessionDetail(sessionID: UUID) async throws -> SessionDetail {
    guard
      let session = await authProvider.currentSession(),
      let baseURL = configuration.supabaseURL
    else { throw NetworkError.unauthorized }

    let path = "/rest/v1/session_detail_view?select=*&session_id=eq.\(sessionID.uuidString)"
    let items: [SessionDetailDTO] = try await postgrestRead(
      baseURL: baseURL,
      path: path,
      accessToken: session.accessToken
    )
    guard let detail = items.first else { throw NetworkError.invalidResponse }
    return detail.model()
  }

  func upsertSession(_ draft: WatchSessionDraft) async throws {
    guard
      let session = await authProvider.currentSession(),
      let baseURL = configuration.supabaseURL
    else { throw NetworkError.unauthorized }

    let payload = PostgrestSessionUpsert(
      id: draft.sessionID,
      userID: session.userID,
      sourceDeviceID: draft.sourceDeviceID,
      startedAt: draft.startedAt,
      endedAt: draft.endedAt,
      status: .syncPending,
      requestID: UUID()
    )
    try await postgrestWrite(
      baseURL: baseURL,
      table: "conversation_sessions",
      payload: payload,
      accessToken: session.accessToken,
      onConflict: "id"
    )
  }

  func upsertSegment(_ segment: SessionSegmentDraft, userID: UUID) async throws {
    guard let baseURL = configuration.supabaseURL else { throw NetworkError.notConfigured }
    guard let session = await authProvider.currentSession() else { throw NetworkError.unauthorized }

    let payload = PostgrestSegmentUpsert(
      sessionID: segment.sessionID,
      userID: userID,
      segmentIndex: segment.segmentIndex,
      storagePath: "u/\(session.userID.uuidString)/s/\(segment.sessionID.uuidString)/segments/\(segment.segmentIndex).m4a",
      uploadStatus: segment.uploadStatus,
      uploadedFrom: "watch",
      durationMS: segment.durationMS,
      contentSHA256: segment.sha256,
      startedAt: segment.startedAt,
      endedAt: segment.endedAt,
      requestID: UUID()
    )
    try await postgrestWrite(
      baseURL: baseURL,
      table: "conversation_segments",
      payload: payload,
      accessToken: session.accessToken,
      onConflict: "session_id,segment_index"
    )
  }

  func createUploadTicket(sessionID: UUID, segmentIndex: Int) async throws -> UploadTicket {
    let response: CreateUploadTicketResponse = try await edgeClient.invoke(
      function: "create-upload-ticket",
      body: CreateUploadTicketRequest(sessionID: sessionID, segmentIndex: segmentIndex, contentType: "audio/wav"),
      requestIdentity: .make(),
      deviceID: Self.deviceID
    )
    return UploadTicket(
      sessionID: response.sessionID,
      segmentIndex: response.segmentIndex,
      storagePath: response.storagePath,
      signedUploadURL: response.signedUploadURL,
      expiresAt: response.expiresAt
    )
  }

  func markSegmentUploaded(sessionID: UUID, segmentIndex: Int, uploadedFrom: String, bytes: Int64?) async throws {
    guard
      let session = await authProvider.currentSession(),
      let baseURL = configuration.supabaseURL
    else { throw NetworkError.unauthorized }

    struct UpdatePayload: Encodable {
      let uploadStatus: SegmentUploadStatus
      let uploadedFrom: String
      let bytes: Int64?

      enum CodingKeys: String, CodingKey {
        case uploadStatus = "upload_status"
        case uploadedFrom = "uploaded_from"
        case bytes
      }
    }

    try await postgrestPatch(
      baseURL: baseURL,
      table: "conversation_segments",
      query: "session_id=eq.\(sessionID.uuidString)&segment_index=eq.\(segmentIndex)",
      payload: UpdatePayload(uploadStatus: .uploaded, uploadedFrom: uploadedFrom, bytes: bytes),
      accessToken: session.accessToken
    )
  }

  func finalizeSession(sessionID: UUID) async throws {
    let _: GenericSuccessResponse = try await edgeClient.invoke(
      function: "finalize-session",
      body: FinalizeSessionRequest(sessionID: sessionID, finalizeReason: "user_long_press"),
      requestIdentity: .make(),
      deviceID: Self.deviceID
    )
  }

  func retryPipeline(sessionID: UUID) async throws {
    try await finalizeSession(sessionID: sessionID)
  }

  func updateNotes(sessionID: UUID, notes: String) async throws {
    let _: GenericSuccessResponse = try await edgeClient.invoke(
      function: "update-session-notes",
      body: NotesUpdateRequest(sessionID: sessionID, notes: notes),
      requestIdentity: .make(),
      deviceID: Self.deviceID
    )
  }

  func askQuestion(sessionID: UUID, question: String, includeUserNotes: Bool) async throws -> AskSessionResponse {
    try await edgeClient.invoke(
      function: "ask-session",
      body: AskSessionRequest(sessionID: sessionID, question: question, includeUserNotes: includeUserNotes),
      requestIdentity: .make(),
      deviceID: Self.deviceID
    )
  }

  func healthSnapshot(deviceID: String) async throws -> DeviceHealthSnapshot {
    let response: HealthSnapshotResponse = try await edgeClient.invoke(
      function: "health-snapshot",
      body: HealthSnapshotRequest(deviceID: deviceID),
      requestIdentity: .make(),
      deviceID: deviceID
    )
    return DeviceHealthSnapshot(
      currentDeviceID: response.currentDeviceID,
      queueDepth: 0,
      lastSyncErrors: response.lastSyncErrors,
      weeklySpendPercent: response.weeklySpendPercent,
      dailyAudioUsageSeconds: response.dailyAudioUsageSeconds
    )
  }

  private func postgrestRead<Output: Decodable>(baseURL: URL, path: String, accessToken: String) async throws -> Output {
    guard let url = URL(string: path, relativeTo: baseURL) else {
      throw NetworkError.invalidResponse
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue(configuration.supabaseKey, forHTTPHeaderField: "apikey")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let (data, response) = try await urlSession.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw NetworkError.invalidResponse
    }
    guard (200 ..< 300).contains(httpResponse.statusCode) else {
      throw NetworkError.server(code: httpResponse.statusCode, message: String(data: data, encoding: .utf8) ?? "Read failed")
    }
    return try JSONCoding.decoder.decode(Output.self, from: data)
  }

  private func postgrestWrite<Payload: Encodable>(
    baseURL: URL,
    table: String,
    payload: Payload,
    accessToken: String,
    onConflict: String
  ) async throws {
    var components = URLComponents(url: baseURL.appending(path: "/rest/v1/\(table)"), resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "on_conflict", value: onConflict),
    ]
    guard let url = components?.url else { throw NetworkError.invalidResponse }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = try JSONCoding.encoder.encode([payload])
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue(configuration.supabaseKey, forHTTPHeaderField: "apikey")
    let (data, response) = try await urlSession.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw NetworkError.invalidResponse
    }
    guard (200 ..< 300).contains(httpResponse.statusCode) else {
      throw NetworkError.server(code: httpResponse.statusCode, message: String(data: data, encoding: .utf8) ?? "Write failed")
    }
  }

  private func postgrestPatch<Payload: Encodable>(
    baseURL: URL,
    table: String,
    query: String,
    payload: Payload,
    accessToken: String
  ) async throws {
    guard let url = URL(string: "/rest/v1/\(table)?\(query)", relativeTo: baseURL) else {
      throw NetworkError.invalidResponse
    }
    var request = URLRequest(url: url)
    request.httpMethod = "PATCH"
    request.httpBody = try JSONCoding.encoder.encode(payload)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue(configuration.supabaseKey, forHTTPHeaderField: "apikey")
    let (data, response) = try await urlSession.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw NetworkError.invalidResponse
    }
    guard (200 ..< 300).contains(httpResponse.statusCode) else {
      throw NetworkError.server(code: httpResponse.statusCode, message: String(data: data, encoding: .utf8) ?? "Patch failed")
    }
  }

  private func postgrestDelete(baseURL: URL, table: String, query: String, accessToken: String) async throws {
    let url = baseURL.appending(path: "/rest/v1/\(table)").appending(queryItems: query.split(separator: "&").map {
      let parts = $0.split(separator: "=", maxSplits: 1)
      return URLQueryItem(name: String(parts[0]), value: parts.count > 1 ? String(parts[1]) : "")
    })
    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue(configuration.supabaseKey, forHTTPHeaderField: "apikey")
    request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
    let (data, response) = try await urlSession.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw NetworkError.invalidResponse
    }
    guard (200 ..< 300).contains(httpResponse.statusCode) else {
      throw NetworkError.server(code: httpResponse.statusCode, message: String(data: data, encoding: .utf8) ?? "Delete failed")
    }
  }

  nonisolated static var deviceID: String {
    if let saved = UserDefaults.standard.string(forKey: "CurrentDeviceID") {
      return saved
    }
    let generated = UUID().uuidString
    UserDefaults.standard.set(generated, forKey: "CurrentDeviceID")
    return generated
  }
}
