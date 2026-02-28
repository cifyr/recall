import SwiftUI

struct WatchRootView: View {
  @State var viewModel: WatchRecorderViewModel
  @State private var now = Date()

  var body: some View {
    VStack(spacing: 12) {
      AnalogRecordingIndicator(isRecording: viewModel.state == .recordingSegment, date: now)
        .frame(width: 112, height: 112)

      Text(statusText)
        .font(.footnote.weight(.semibold))
        .multilineTextAlignment(.center)

      Button {
        Task { await viewModel.handlePrimaryTap() }
      } label: {
        Image(systemName: primaryButtonSymbol)
          .font(.title2)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 10)
      }
      .buttonStyle(.borderedProminent)
      .tint(viewModel.state == .recordingSegment ? .red : .green)

      Button("Finalize Session") {
        Task { await viewModel.finalizeSession() }
      }
      .buttonStyle(.bordered)
      .disabled(viewModel.state == .recordingSegment || !viewModel.canFinalizeSession)

      if let lastError = viewModel.lastError {
        Text(lastError)
          .font(.caption2)
          .foregroundStyle(.red)
      }
    }
    .padding()
    .task {
      await viewModel.bootstrap()
    }
    .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { value in
      now = value
    }
  }

  private var statusText: String {
    switch viewModel.state {
    case .idle:
      return "Ready"
    case .recordingSegment:
      return "Recording"
    case .segmentStopped, .awaitingUploadTicket:
      return "Pending Upload"
    case .uploadingDirect:
      return "Uploading"
    case .uploadFailed:
      return "Upload Failed"
    case .uploadSucceeded:
      return "Uploaded"
    case .finalizingSession:
      return "Finalizing"
    }
  }

  private var primaryButtonSymbol: String {
    switch viewModel.state {
    case .recordingSegment:
      return "stop.fill"
    case .uploadFailed:
      return "arrow.clockwise"
    default:
      return "mic.fill"
    }
  }
}
