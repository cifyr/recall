import XCTest
@testable import AppleWatchRecorder

final class SupabaseSessionRepositoryTests: XCTestCase {
  override func tearDown() {
    MockURLProtocol.requestHandler = nil
    super.tearDown()
  }

  func testLoadSessionsPreservesQueryItemsInRequestURL() async throws {
    let expectedPath = "/rest/v1/session_feed_view"
    let expectedQueryItems = [
      URLQueryItem(name: "select", value: "*"),
      URLQueryItem(name: "order", value: "started_at.desc"),
    ]

    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, expectedPath)
      XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems, expectedQueryItems)

      let body = """
      [
        {
          "session_id": "11111111-1111-1111-1111-111111111111",
          "started_at": "2026-02-28T12:00:00Z",
          "ended_at": "2026-02-28T12:15:00Z",
          "status": "summarized",
          "segment_count": 1,
          "total_duration_ms": 60000,
          "user_notes": null,
          "latest_summary_excerpt": "Smoke summary",
          "question_count": 0,
          "latest_error_code": null,
          "updated_at": "2026-02-28T12:20:00Z"
        }
      ]
      """
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(body.utf8)
      )
    }

    let repository = makeRepository()
    let sessions = try await repository.loadSessions()

    XCTAssertEqual(sessions.count, 1)
    XCTAssertEqual(sessions.first?.sessionID.uuidString.lowercased(), "11111111-1111-1111-1111-111111111111")
  }

  func testLoadSessionDetailPreservesQueryItemsInRequestURL() async throws {
    let sessionID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let expectedPath = "/rest/v1/session_detail_view"
    let expectedQueryItems = [
      URLQueryItem(name: "select", value: "*"),
      URLQueryItem(name: "session_id", value: "eq.\(sessionID.uuidString.lowercased())"),
    ]

    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, expectedPath)
      XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems, expectedQueryItems)

      let body = """
      [
        {
          "session_id": "\(sessionID.uuidString.lowercased())",
          "started_at": "2026-02-28T12:00:00Z",
          "ended_at": "2026-02-28T12:15:00Z",
          "status": "summarized",
          "segment_count": 1,
          "total_duration_ms": 60000,
          "latest_error_code": null,
          "latest_error_message": null,
          "transcript_text": "Transcript",
          "transcript_language": "en",
          "transcript_model": "whisper-1",
          "user_notes": "Notes",
          "summaries": [],
          "questions": []
        }
      ]
      """
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(body.utf8)
      )
    }

    let repository = makeRepository()
    let detail = try await repository.loadSessionDetail(sessionID: sessionID)

    XCTAssertEqual(detail.sessionID, sessionID)
    XCTAssertEqual(detail.transcriptText, "Transcript")
  }

  func testCreateUploadTicketRetriesOnceAfterUnauthorizedByRefreshingSession() async throws {
    let sessionID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    let authProvider = AuthProviderStub()
    let urlSessionConfiguration = URLSessionConfiguration.ephemeral
    urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
    let urlSession = URLSession(configuration: urlSessionConfiguration)

    var requestCount = 0
    MockURLProtocol.requestHandler = { request in
      requestCount += 1
      XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "test-key")
      XCTAssertNotNil(request.value(forHTTPHeaderField: "x-request-id"))
      if requestCount == 1 {
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer stale-token")
        return (
          HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
          Data(#"{"code":401,"message":"Invalid JWT"}"#.utf8)
        )
      }

      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer refreshed-token")
      let body = """
      {
        "ok": true,
        "data": {
          "session_id": "\(sessionID.uuidString.lowercased())",
          "segment_index": 0,
          "storage_path": "u/test/s/\(sessionID.uuidString)/segments/0.m4a",
          "signed_upload_url": "https://example.com/upload",
          "expires_at": "2026-02-28T13:00:00Z"
        },
        "meta": {
          "request_id": "44444444-4444-4444-4444-444444444444"
        }
      }
      """
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(body.utf8)
      )
    }

    let configuration = AppConfiguration(
      supabaseURL: URL(string: "https://example.supabase.co")!,
      supabaseKey: "test-key",
      edgeFunctionBaseURL: nil,
      redirectURL: nil
    )
    let edgeClient = EdgeFunctionClient(
      configuration: configuration,
      sessionProvider: { forceRefresh in
        if forceRefresh {
          return await authProvider.refreshSession()
        }
        return await authProvider.currentSession()
      },
      urlSession: urlSession
    )
    let repository = SupabaseSessionRepository(
      configuration: configuration,
      authProvider: authProvider,
      edgeClient: edgeClient,
      urlSession: urlSession
    )

    let ticket = try await repository.createUploadTicket(sessionID: sessionID, segmentIndex: 0)

    XCTAssertEqual(ticket.sessionID, sessionID)
    XCTAssertEqual(ticket.segmentIndex, 0)
    XCTAssertEqual(requestCount, 2)
    let refreshCount = await authProvider.refreshCount()
    XCTAssertEqual(refreshCount, 1)
  }

  private func makeRepository() -> SupabaseSessionRepository {
    let configuration = AppConfiguration(
      supabaseURL: URL(string: "https://example.supabase.co")!,
      supabaseKey: "test-key",
      edgeFunctionBaseURL: nil,
      redirectURL: nil
    )
    let authProvider = AuthProviderStub()
    let edgeClient = EdgeFunctionClient(configuration: configuration) { forceRefresh in
      if forceRefresh {
        return await authProvider.refreshSession()
      }
      return await authProvider.currentSession()
    }

    let urlSessionConfiguration = URLSessionConfiguration.ephemeral
    urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]

    return SupabaseSessionRepository(
      configuration: configuration,
      authProvider: authProvider,
      edgeClient: edgeClient,
      urlSession: URLSession(configuration: urlSessionConfiguration)
    )
  }
}

private actor AuthProviderStub: AuthProviding {
  nonisolated var isConfigured: Bool { true }
  private var refreshCalls = 0
  private var currentToken = "stale-token"

  func currentSession() async -> AuthSession? {
    AuthSession(
      userID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
      email: "test@example.com",
      accessToken: currentToken
    )
  }

  func refreshSession() async -> AuthSession? {
    refreshCalls += 1
    currentToken = "refreshed-token"
    return AuthSession(
      userID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
      email: "test@example.com",
      accessToken: currentToken
    )
  }

  func restoreSession() async {}
  func sendEmailCode(to email: String) async throws {}
  func verifyEmailCode(email: String, code: String) async throws {}
  func signOut() async throws {}

  func refreshCount() -> Int {
    refreshCalls
  }
}

private final class MockURLProtocol: URLProtocol {
  nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let handler = Self.requestHandler else {
      XCTFail("Missing request handler")
      return
    }

    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}
