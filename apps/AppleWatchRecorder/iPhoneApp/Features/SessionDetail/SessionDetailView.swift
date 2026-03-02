#if os(iOS)
import SwiftUI

struct SessionDetailView: View {
  @Environment(\.dismiss) private var dismiss
  @State var viewModel: SessionDetailViewModel
  @State private var shareText = ""
  @State private var showingShareSheet = false

  var body: some View {
    VStack(spacing: 0) {
      topBar

      ScrollView(showsIndicators: false) {
        VStack(alignment: .leading, spacing: 12) {
          if let detail = viewModel.detail {
            headerCard(detail)
            transcriptCard(detail)
            summaryCards(detail)
            notesCard
            qaCard(detail)
          } else if viewModel.isLoading {
            ProgressView("Loading Detail")
              .tint(AppPalette.primary)
              .frame(maxWidth: .infinity, minHeight: 240)
          }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 24)
      }
    }
    .background(AppPalette.background.ignoresSafeArea())
    .toolbar(.hidden, for: .navigationBar)
    .task {
      await viewModel.load()
    }
    .sheet(isPresented: $showingShareSheet) {
      ShareSheet(text: shareText)
    }
  }

  private var topBar: some View {
    ZStack {
      Text("Session Detail")
        .font(.system(size: 15, weight: .regular))
        .foregroundStyle(AppPalette.foreground)

      HStack {
        Button {
          dismiss()
        } label: {
          ZStack {
            Circle()
              .fill(AppPalette.muted)
              .frame(width: 36, height: 36)

            Image(systemName: "arrow.left")
              .font(.system(size: 16, weight: .medium))
              .foregroundStyle(AppPalette.foreground)
          }
        }
        .buttonStyle(.plain)

        Spacer()

        if viewModel.detail?.status == .failed {
          Button {
            Task { await viewModel.retryPipeline() }
          } label: {
            HStack(spacing: 6) {
              Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 12, weight: .medium))
              Text("Retry")
                .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(AppPalette.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(AppPalette.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          }
          .buttonStyle(.plain)
        } else {
          Color.clear
            .frame(width: 36, height: 36)
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 8)
    .padding(.bottom, 10)
  }

  private func headerCard(_ detail: SessionDetail) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top) {
        Text(dateLabel(for: detail.startedAt))
          .font(.system(size: 15))
          .foregroundStyle(AppPalette.foreground)

        Spacer()

        let presentation = detail.status.presentation
        Text(presentation.label)
          .font(.system(size: 13))
          .foregroundStyle(statusForeground(detail.status))
      }

      if let latestErrorMessage = detail.latestErrorMessage {
        Text(latestErrorMessage)
          .font(.system(size: 13))
          .foregroundStyle(AppPalette.destructive)
      }
    }
    .appCardStyle()
  }

  private func transcriptCard(_ detail: SessionDetail) -> some View {
    detailCard(
      title: "Transcript",
      systemImage: "doc.text"
    ) {
      Text(detail.transcriptText ?? "Transcript pending.")
        .font(.system(size: 13))
        .foregroundStyle(AppPalette.mutedForeground)
        .textSelection(.enabled)

      if let transcriptText = detail.transcriptText, !transcriptText.isEmpty {
        actionButtons(for: transcriptText)
      }
    }
  }

  private func summaryCards(_ detail: SessionDetail) -> some View {
    ForEach(detail.summaries) { summary in
      detailCard(
        title: summary.kind?.title ?? summary.promptName,
        systemImage: "checklist"
      ) {
        Text(summary.summaryText)
          .font(.system(size: 13))
          .foregroundStyle(AppPalette.mutedForeground)
          .textSelection(.enabled)

        actionButtons(for: summary.summaryText)
      }
    }
  }

  private var notesCard: some View {
    detailCard(
      title: "Notes",
      systemImage: "note.text"
    ) {
      TextEditor(text: $viewModel.notesDraft)
        .frame(minHeight: 92)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .scrollContentBackground(.hidden)
        .background(AppPalette.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

      Button {
        Task { await viewModel.saveNotes() }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "square.and.arrow.down")
            .font(.system(size: 12, weight: .medium))
          Text(viewModel.isSavingNotes ? "Saving..." : "Save Notes")
            .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(AppPalette.primaryForeground)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AppPalette.primary)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .opacity(viewModel.isSavingNotes ? 0.8 : 1)
      }
      .buttonStyle(.plain)
      .disabled(viewModel.isSavingNotes)
    }
  }

  private func qaCard(_ detail: SessionDetail) -> some View {
    detailCard(
      title: "Ask a Question",
      systemImage: "message"
    ) {
      HStack(alignment: .bottom, spacing: 8) {
        TextEditor(text: $viewModel.questionDraft)
          .frame(minHeight: 74)
          .padding(.horizontal, 8)
          .padding(.vertical, 6)
          .scrollContentBackground(.hidden)
          .background(AppPalette.inputBackground)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

        Button {
          Task { await viewModel.askQuestion() }
        } label: {
          ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .fill(AppPalette.primary)
              .frame(width: 40, height: 40)

            if viewModel.isAsking {
              ProgressView()
                .tint(AppPalette.primaryForeground)
            } else {
              Image(systemName: "paperplane.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppPalette.primaryForeground)
            }
          }
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isAsking || viewModel.questionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .opacity(viewModel.isAsking || viewModel.questionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
      }

      if !detail.questions.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(detail.questions) { question in
            VStack(alignment: .leading, spacing: 8) {
              Divider()
                .padding(.bottom, 12)

              Text("Q: \(question.question)")
                .font(.system(size: 13))
                .foregroundStyle(AppPalette.foreground)

              Text(question.answer ?? "Pending answer")
                .font(.system(size: 13))
                .foregroundStyle(AppPalette.mutedForeground)

              actionButtons(for: question.answer ?? "")
            }
          }
        }
      }
    }
  }

  private func detailCard<Content: View>(
    title: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: systemImage)
          .font(.system(size: 14))
          .foregroundStyle(AppPalette.mutedForeground)
        Text(title)
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(AppPalette.foreground)
      }

      content()
    }
    .appCardStyle()
  }

  private func actionButtons(for text: String) -> some View {
    HStack(spacing: 8) {
      Button {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
      } label: {
        actionChip(systemImage: "doc.on.doc", title: "Copy")
      }
      .buttonStyle(.plain)

      Button {
        shareText = text
        showingShareSheet = true
      } label: {
        actionChip(systemImage: "square.and.arrow.up", title: "Share")
      }
      .buttonStyle(.plain)
    }
  }

  private func actionChip(systemImage: String, title: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: systemImage)
        .font(.system(size: 12))
      Text(title)
        .font(.system(size: 12, weight: .medium))
    }
    .foregroundStyle(AppPalette.mutedForeground)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(AppPalette.muted)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private func statusForeground(_ status: SessionStatus) -> Color {
    status.presentation.foreground
  }

  private func dateLabel(for date: Date) -> String {
    let calendar = Calendar.current
    let timeFormatter = DateFormatter()
    timeFormatter.dateFormat = "h:mm a"

    if calendar.isDateInToday(date) {
      return "Today, \(timeFormatter.string(from: date))"
    }

    if calendar.isDateInYesterday(date) {
      return "Yesterday, \(timeFormatter.string(from: date))"
    }

    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d, h:mm a"
    return formatter.string(from: date)
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
#endif
