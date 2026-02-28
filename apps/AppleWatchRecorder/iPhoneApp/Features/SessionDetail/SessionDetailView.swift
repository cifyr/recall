import SwiftUI

struct SessionDetailView: View {
  @State var viewModel: SessionDetailViewModel
  @State private var shareText = ""
  @State private var showingShareSheet = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        if let detail = viewModel.detail {
          header(detail)
          transcript(detail)
          summaries(detail)
          notes
          questions(detail)
        } else if viewModel.isLoading {
          ProgressView("Loading Detail")
        }
      }
      .padding()
    }
    .navigationTitle("Session")
    .toolbar {
      if viewModel.detail?.status == .failed {
        Button("Retry") {
          Task { await viewModel.retryPipeline() }
        }
      }
    }
    .task {
      await viewModel.load()
    }
    .sheet(isPresented: $showingShareSheet) {
      ShareSheet(text: shareText)
    }
  }

  @ViewBuilder
  private func header(_ detail: SessionDetail) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(detail.startedAt, style: .date)
        .font(.title3.weight(.semibold))
      Text(detail.status.rawValue.replacingOccurrences(of: "_", with: " "))
        .foregroundStyle(.secondary)
      if let latestErrorMessage = detail.latestErrorMessage {
        Text(latestErrorMessage)
          .font(.footnote)
          .foregroundStyle(.red)
      }
    }
  }

  @ViewBuilder
  private func transcript(_ detail: SessionDetail) -> some View {
    SectionCard(title: "Transcript") {
      Text(detail.transcriptText ?? "Transcript pending.")
        .textSelection(.enabled)
      actionButtons(for: detail.transcriptText ?? "")
    }
  }

  @ViewBuilder
  private func summaries(_ detail: SessionDetail) -> some View {
    ForEach(detail.summaries) { summary in
      SectionCard(title: summary.kind?.title ?? summary.promptName) {
        Text(summary.summaryText)
          .textSelection(.enabled)
        actionButtons(for: summary.summaryText)
      }
    }
  }

  private var notes: some View {
    SectionCard(title: "Notes") {
      TextEditor(text: $viewModel.notesDraft)
        .frame(minHeight: 120)
        .scrollContentBackground(.hidden)
        .background(Color(.secondarySystemBackground))
      Button(viewModel.isSavingNotes ? "Saving..." : "Save Notes") {
        Task { await viewModel.saveNotes() }
      }
      .disabled(viewModel.isSavingNotes)
    }
  }

  @ViewBuilder
  private func questions(_ detail: SessionDetail) -> some View {
    SectionCard(title: "Q&A") {
      AskQuestionComposer(question: $viewModel.questionDraft, isSubmitting: viewModel.isAsking) {
        Task { await viewModel.askQuestion() }
      }

      ForEach(detail.questions) { question in
        VStack(alignment: .leading, spacing: 8) {
          Text(question.question)
            .font(.headline)
          Text(question.answer ?? "Pending answer")
            .foregroundStyle(.secondary)
          actionButtons(for: question.answer ?? "")
        }
        .padding(.vertical, 8)
        Divider()
      }
    }
  }

  @ViewBuilder
  private func actionButtons(for text: String) -> some View {
    HStack {
      Button("Copy") {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
      }
      Button("Share") {
        shareText = text
        showingShareSheet = true
      }
    }
    .font(.caption.weight(.semibold))
  }
}

private struct SectionCard<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.headline)
      content
    }
    .padding()
    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

#if canImport(UIKit)
private struct ShareSheet: UIViewControllerRepresentable {
  let text: String

  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: [text], applicationActivities: nil)
  }

  func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#else
private struct ShareSheet: View {
  let text: String
  var body: some View { Text(text) }
}
#endif
