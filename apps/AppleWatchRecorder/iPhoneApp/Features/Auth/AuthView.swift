import SwiftUI

struct AuthView: View {
  @Bindable var coordinator: AuthCoordinator
  let onUseDemoMode: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Spacer()

      Text("Apple Watch Recorder")
        .font(.largeTitle.bold())

      Text("Enter your email on iPhone, request a one-time code, then capture from the watch while Supabase handles storage, transcript, summaries, and Q&A.")
        .foregroundStyle(.secondary)

      if coordinator.isConfigured {
        VStack(alignment: .leading, spacing: 16) {
          TextField("Email address", text: $coordinator.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

          Button(coordinator.sendButtonTitle) {
            Task {
              await coordinator.sendCode()
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(coordinator.isLoading || !coordinator.canSendCode)

          if coordinator.isAwaitingCode {
            TextField("6-digit code", text: $coordinator.verificationCode)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .keyboardType(.numberPad)
              .textContentType(.oneTimeCode)
              .padding(.horizontal, 14)
              .padding(.vertical, 12)
              .background(Color(uiColor: .secondarySystemBackground))
              .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button("Verify Code") {
              Task {
                await coordinator.verifyCode()
              }
            }
            .buttonStyle(.borderedProminent)
            .disabled(coordinator.isLoading || !coordinator.canVerifyCode)

            Button("Use Different Email") {
              coordinator.editEmailAddress()
            }
            .buttonStyle(.bordered)
            .disabled(coordinator.isLoading)
          }

          Button("Use Demo Data Instead") {
            onUseDemoMode()
          }
          .buttonStyle(.bordered)
        }
      } else {
        VStack(alignment: .leading, spacing: 8) {
          Text("Supabase is not configured.")
            .font(.headline)
          Text("Add `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, and `EDGE_FUNCTION_BASE_URL` to the app Info.plist to enable live auth.")
            .foregroundStyle(.secondary)
        }

        Button("Use Demo Data") {
          onUseDemoMode()
        }
        .buttonStyle(.borderedProminent)
      }

      if coordinator.isLoading {
        ProgressView()
      }

      if let errorMessage = coordinator.errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
        Text("If the email from Supabase still contains a magic link instead of a 6-digit code, update the Supabase Magic Link template to include `{{ .Token }}`.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      if let infoMessage = coordinator.infoMessage {
        Text(infoMessage)
          .foregroundStyle(.green)
          .font(.footnote)
      }

      Spacer()
    }
    .padding(24)
    .navigationTitle("Sign In")
  }
}
