#if os(iOS)
import Foundation
import Observation

@MainActor
@Observable
final class AuthCoordinator {
  enum Step: Equatable {
    case emailEntry
    case codeEntry
  }

  private let authProvider: any AuthProviding
  private let onSessionChange: @MainActor (AuthSession?) -> Void

  var step: Step = .emailEntry
  var emailAddress = ""
  var verificationCode = ""
  var isLoading = false
  var errorMessage: String?
  var infoMessage: String?
  private(set) var pendingEmail: String?

  init(
    authProvider: any AuthProviding,
    onSessionChange: @escaping @MainActor (AuthSession?) -> Void
  ) {
    self.authProvider = authProvider
    self.onSessionChange = onSessionChange
  }

  var isConfigured: Bool { authProvider.isConfigured }
  var isAwaitingCode: Bool { step == .codeEntry }
  var sendButtonTitle: String { isAwaitingCode ? "Resend Code" : "Send Code" }
  var canSendCode: Bool { isValidEmail(normalizedEmail) }
  var canVerifyCode: Bool { isAwaitingCode && normalizedCode.count >= 6 }

  func sendCode() async {
    errorMessage = nil
    infoMessage = nil

    guard isValidEmail(normalizedEmail) else {
      errorMessage = "Enter a valid email address."
      return
    }

    isLoading = true
    defer { isLoading = false }

    do {
      try await authProvider.sendEmailCode(to: normalizedEmail)
      emailAddress = normalizedEmail
      pendingEmail = normalizedEmail
      verificationCode = ""
      step = .codeEntry
      infoMessage = "A login code was sent to \(normalizedEmail)."
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func verifyCode() async {
    errorMessage = nil
    infoMessage = nil

    guard let pendingEmail else {
      errorMessage = "Request a code first."
      step = .emailEntry
      return
    }

    guard normalizedCode.count >= 6 else {
      errorMessage = "Enter the 6-digit code from your email."
      return
    }

    isLoading = true
    defer { isLoading = false }

    do {
      try await authProvider.verifyEmailCode(email: pendingEmail, code: normalizedCode)
      let session = await authProvider.currentSession()
      onSessionChange(session)
      errorMessage = nil
      infoMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func editEmailAddress() {
    step = .emailEntry
    pendingEmail = nil
    verificationCode = ""
    errorMessage = nil
    infoMessage = nil
  }

  private var normalizedEmail: String {
    emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private var normalizedCode: String {
    verificationCode
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: " ", with: "")
  }

  private func isValidEmail(_ value: String) -> Bool {
    value.contains("@") && value.contains(".")
  }
}
#endif
