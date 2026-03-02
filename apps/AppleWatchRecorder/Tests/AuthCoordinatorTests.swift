import XCTest
@testable import AppleWatchRecorder

final class AuthCoordinatorTests: XCTestCase {
  @MainActor
  func testSendCodeNormalizesEmailAndTransitionsToCodeEntry() async {
    let authProvider = AuthProviderSpy()
    let coordinator = AuthCoordinator(authProvider: authProvider) { _ in }

    coordinator.emailAddress = "  Test.User@Example.com "
    await coordinator.sendCode()

    let sentEmails = await authProvider.sentEmails()
    XCTAssertEqual(coordinator.step, .codeEntry)
    XCTAssertEqual(coordinator.pendingEmail, "test.user@example.com")
    XCTAssertEqual(sentEmails, ["test.user@example.com"])
    XCTAssertEqual(coordinator.infoMessage, "A login code was sent to test.user@example.com.")
  }

  @MainActor
  func testVerifyCodeCreatesSessionAndPublishesIt() async {
    let authProvider = AuthProviderSpy()
    let expectation = expectation(description: "session published")
    var publishedSession: AuthSession?

    let coordinator = AuthCoordinator(authProvider: authProvider) { session in
      publishedSession = session
      expectation.fulfill()
    }

    coordinator.emailAddress = "test@example.com"
    await coordinator.sendCode()
    coordinator.verificationCode = "123456"

    await coordinator.verifyCode()
    await fulfillment(of: [expectation], timeout: 1.0)

    let verifiedEmail = await authProvider.verifiedEmail()
    let verifiedCode = await authProvider.verifiedCode()
    XCTAssertEqual(verifiedEmail, "test@example.com")
    XCTAssertEqual(verifiedCode, "123456")
    XCTAssertEqual(publishedSession?.email, "test@example.com")
  }
}

private actor AuthProviderSpy: AuthProviding {
  nonisolated var isConfigured: Bool { true }

  private var session: AuthSession?
  private var sentEmailValues: [String] = []
  private var verifiedEmailValue: String?
  private var verifiedCodeValue: String?

  func currentSession() async -> AuthSession? {
    session
  }

  func refreshSession() async -> AuthSession? {
    session
  }

  func restoreSession() async {}

  func sendEmailCode(to email: String) async throws {
    sentEmailValues.append(email)
  }

  func verifyEmailCode(email: String, code: String) async throws {
    verifiedEmailValue = email
    verifiedCodeValue = code
    session = AuthSession(
      userID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
      email: email,
      accessToken: "token"
    )
  }

  func signOut() async throws {
    session = nil
  }

  func sentEmails() -> [String] {
    sentEmailValues
  }

  func verifiedEmail() -> String? {
    verifiedEmailValue
  }

  func verifiedCode() -> String? {
    verifiedCodeValue
  }
}
