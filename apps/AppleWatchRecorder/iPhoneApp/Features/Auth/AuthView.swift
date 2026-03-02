#if os(iOS)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct AuthView: View {
  @Bindable var coordinator: AuthCoordinator
  let onUseDemoMode: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ScrollView(showsIndicators: false) {
        VStack(alignment: .leading, spacing: 0) {
          header

          if let errorMessage = coordinator.errorMessage {
            messageBanner(
              text: errorMessage,
              background: AppPalette.destructive.opacity(0.08),
              border: AppPalette.destructive.opacity(0.2),
              foreground: AppPalette.destructive
            )

            Text("If the email from Supabase still contains a magic link instead of a 6-digit code, update the Supabase Magic Link template to include `{{ .Token }}`.")
              .font(.system(size: 12))
              .foregroundStyle(AppPalette.mutedForeground)
              .padding(.top, 10)
              .padding(.bottom, 18)
          }

          if let infoMessage = coordinator.infoMessage {
            messageBanner(
              text: infoMessage,
              background: AppPalette.successBackground,
              border: AppPalette.successBorder,
              foreground: AppPalette.successText
            )
            .padding(.bottom, 18)
          }

          if coordinator.isConfigured {
            liveAuthContent
          } else {
            unconfiguredContent
          }

          Spacer(minLength: 24)
        }
        .padding(.horizontal, 24)
        .padding(.top, 32)
        .padding(.bottom, 20)
      }

      Button {
        onUseDemoMode()
      } label: {
        Text(coordinator.isConfigured ? "Use Demo Data Instead" : "Use Demo Data")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(AppPalette.mutedForeground)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 14)
          .background(AppPalette.background)
          .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .stroke(AppPalette.border, lineWidth: 1)
          )
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 24)
      .padding(.bottom, 24)
    }
    .background(AppPalette.background.ignoresSafeArea())
    .toolbar(.hidden, for: .navigationBar)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 0) {
      ZStack {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(AppPalette.primary)
          .frame(width: 56, height: 56)

        Image(systemName: "checkmark.shield.fill")
          .font(.system(size: 28, weight: .medium))
          .foregroundStyle(AppPalette.primaryForeground)
      }
      .padding(.bottom, 20)

      Text("Sign In")
        .font(.system(size: 32, weight: .semibold))
        .foregroundStyle(AppPalette.foreground)
        .padding(.bottom, 8)

      Text("Enter your email to receive a one-time verification code. No password needed.")
        .font(.system(size: 15))
        .foregroundStyle(AppPalette.mutedForeground)
        .padding(.bottom, 28)
    }
  }

  private var liveAuthContent: some View {
    VStack(alignment: .leading, spacing: 16) {
      fieldLabel("Email Address")

      iconTextField(
        text: $coordinator.emailAddress,
        placeholder: "you@example.com",
        systemImage: "envelope",
        disabled: coordinator.isAwaitingCode || coordinator.isLoading,
        keyboardType: .emailAddress,
        textContentType: .emailAddress
      )

      primaryButton(
        title: coordinator.isLoading && !coordinator.isAwaitingCode ? "Sending..." : coordinator.sendButtonTitle,
        disabled: coordinator.isLoading || !coordinator.canSendCode
      ) {
        Task {
          await coordinator.sendCode()
        }
      }

      if coordinator.isAwaitingCode {
        VStack(alignment: .leading, spacing: 14) {
          fieldLabel("Verification Code")

          TextField("000000", text: $coordinator.verificationCode)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .multilineTextAlignment(.center)
            .tracking(8)
            .font(.system(size: 20, weight: .medium, design: .default))
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(AppPalette.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .disabled(coordinator.isLoading)

          primaryButton(
            title: coordinator.isLoading ? "Verifying..." : "Verify Code",
            disabled: coordinator.isLoading || !coordinator.canVerifyCode
          ) {
            Task {
              await coordinator.verifyCode()
            }
          }

          Button {
            coordinator.editEmailAddress()
          } label: {
            HStack(spacing: 6) {
              Image(systemName: "arrow.left")
                .font(.system(size: 13, weight: .medium))
              Text("Use Different Email")
                .font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(AppPalette.mutedForeground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
          }
          .buttonStyle(.plain)
        }
        .padding(.top, 4)
      }

      if coordinator.isLoading {
        ProgressView()
          .tint(AppPalette.primary)
          .padding(.top, 4)
      }
    }
  }

  private var unconfiguredContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Supabase is not configured.")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(AppPalette.foreground)
      Text("Add `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, and `EDGE_FUNCTION_BASE_URL` to the app Info.plist to enable live auth.")
        .font(.system(size: 15))
        .foregroundStyle(AppPalette.mutedForeground)
    }
  }

  private func fieldLabel(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 13))
      .foregroundStyle(AppPalette.mutedForeground)
  }

  private func iconTextField(
    text: Binding<String>,
    placeholder: String,
    systemImage: String,
    disabled: Bool,
    keyboardType: UIKeyboardType,
    textContentType: UITextContentType?
  ) -> some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.system(size: 18))
        .foregroundStyle(AppPalette.mutedForeground)

      TextField(placeholder, text: text)
        .keyboardType(keyboardType)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .textContentType(textContentType)
        .font(.system(size: 15))
        .disabled(disabled)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 14)
    .background(AppPalette.inputBackground)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .opacity(disabled ? 0.6 : 1)
  }

  private func primaryButton(title: String, disabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(AppPalette.primaryForeground)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(AppPalette.primary)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(disabled ? 0.5 : 1)
    }
    .buttonStyle(.plain)
    .disabled(disabled)
  }

  private func messageBanner(
    text: String,
    background: Color,
    border: Color,
    foreground: Color
  ) -> some View {
    Text(text)
      .font(.system(size: 14))
      .foregroundStyle(foreground)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .background(background)
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(border, lineWidth: 1)
      )
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}
#endif
