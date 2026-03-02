import SwiftUI

struct WatchRootView: View {
  @State var viewModel: WatchRecorderViewModel

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { _ in
      ZStack {
        Color.black.ignoresSafeArea()

        if viewModel.phoneSignedIn {
          AnalogRecordingIndicator(
            date: Date(),
            handVisibility: handVisibility
          )
          .ignoresSafeArea()

          if viewModel.state == .uploading {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
              .stroke(Color.red, lineWidth: 3)
              .ignoresSafeArea()
          }

          if viewModel.debugMode {
            debugOverlay
          }
        } else {
          VStack(spacing: 8) {
            Text("Sign in on iPhone")
              .font(.headline)
              .foregroundStyle(.white)
            Text("Open the iPhone app and sign in to upload recordings.")
              .font(.caption)
              .multilineTextAlignment(.center)
              .foregroundStyle(.white.opacity(0.9))
              .padding(.horizontal, 16)
          }
        }
      }
      .contentShape(Rectangle())
      .onTapGesture {
        guard viewModel.phoneSignedIn else { return }
        Task { await viewModel.handleTap() }
      }
      .onLongPressGesture(minimumDuration: 0.7) {
        guard viewModel.phoneSignedIn else { return }
        Task { await viewModel.handleLongPress() }
      }
    }
    .task {
      await viewModel.bootstrap()
    }
  }

  @ViewBuilder
  private var debugOverlay: some View {
    if viewModel.state == .uploading {
      VStack {
        Spacer()
        Text("Uploading…")
          .font(.caption)
          .foregroundStyle(.white.opacity(0.9))
          .padding(.bottom, 12)
      }
    }

    if viewModel.state == .paused {
      VStack {
        Spacer()
        Text("Paused")
          .font(.caption)
          .foregroundStyle(.white.opacity(0.7))
          .padding(.bottom, 12)
      }
    }

    if viewModel.state == .error, let message = viewModel.lastError {
      VStack {
        Spacer()
        Text(message)
          .font(.caption2)
          .multilineTextAlignment(.center)
          .foregroundStyle(.white)
          .padding(.horizontal, 8)
          .padding(.bottom, 12)
      }
    }
  }

  private var handVisibility: ClockHandVisibility {
    switch viewModel.state {
    case .recording, .starting:
      return .hourMinute
    case .idle, .paused, .uploading, .error:
      return .all
    }
  }
}
