#if os(iOS)
import SwiftUI

struct SessionsListView: View {
  @State var viewModel: SessionsListViewModel
  @State private var showDeleteAllConfirmation = false
  let onOpenSession: (UUID) -> Void

  var body: some View {
    VStack(spacing: 0) {
      header

      ScrollView(showsIndicators: false) {
        LazyVStack(spacing: 10) {
          if viewModel.isLoading && viewModel.items.isEmpty {
            ProgressView("Loading Sessions")
              .tint(AppPalette.primary)
              .frame(maxWidth: .infinity, minHeight: 240)
          } else if viewModel.items.isEmpty {
            emptyState
          } else {
            ForEach(viewModel.items) { item in
              SessionRow(item: item) {
                onOpenSession(item.sessionID)
              }
            }
          }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 16)
      }
      .refreshable {
        await viewModel.load()
      }
    }
    .background(AppPalette.background.ignoresSafeArea())
    .overlay(alignment: .bottom) {
      if let errorMessage = viewModel.errorMessage {
        Text(errorMessage)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(AppPalette.destructive)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .background(AppPalette.background)
          .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .stroke(AppPalette.destructive.opacity(0.2), lineWidth: 1)
          )
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
          .padding(.horizontal, 16)
          .padding(.bottom, 12)
      }
    }
    .task {
      await viewModel.load()
    }
    .confirmationDialog("Remove all sessions?", isPresented: $showDeleteAllConfirmation, titleVisibility: .visible) {
      Button("Remove all", role: .destructive) {
        Task { await viewModel.deleteAllSessions() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This cannot be undone. All sessions will be deleted from the server.")
    }
  }

  private var header: some View {
    HStack {
      Text("Sessions")
        .font(.system(size: 28, weight: .semibold))
        .foregroundStyle(AppPalette.foreground)

      Spacer()

      if !viewModel.items.isEmpty {
        Button {
          showDeleteAllConfirmation = true
        } label: {
          Image(systemName: "trash")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(AppPalette.destructive)
        }
        .buttonStyle(.plain)
      }

      Button {
        Task {
          await viewModel.load()
        }
      } label: {
        ZStack {
          Circle()
            .fill(AppPalette.muted)
            .frame(width: 36, height: 36)

          Image(systemName: "arrow.clockwise")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(AppPalette.mutedForeground)
            .rotationEffect(.degrees(viewModel.isLoading ? 360 : 0))
            .animation(viewModel.isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: viewModel.isLoading)
        }
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 20)
    .padding(.top, 12)
    .padding(.bottom, 12)
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "mic.slash")
        .font(.system(size: 28))
        .foregroundStyle(AppPalette.mutedForeground)

      Text("No sessions yet")
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(AppPalette.foreground)

      Text("Record from the watch and completed sessions will appear here.")
        .font(.system(size: 14))
        .foregroundStyle(AppPalette.mutedForeground)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 56)
    .appCardStyle()
  }
}

private struct SessionRow: View {
  let item: SessionFeedItem
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .top, spacing: 12) {
          Text(Self.dateLabel(for: item.startedAt))
            .font(.system(size: 15))
            .foregroundStyle(AppPalette.foreground)

          Spacer(minLength: 8)

          let presentation = item.status.presentation
          Text(presentation.label)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(presentation.foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(presentation.background)
            .clipShape(Capsule())
        }
        .padding(.bottom, item.latestSummaryExcerpt == nil ? 10 : 8)

        if let excerpt = item.latestSummaryExcerpt {
          Text(excerpt)
            .font(.system(size: 13))
            .foregroundStyle(AppPalette.mutedForeground)
            .lineLimit(2)
            .padding(.bottom, 10)
        }

        HStack(spacing: 12) {
          detailChip(text: "\(item.segmentCount) segments", systemImage: "mic.fill")

          if let totalDurationMS = item.totalDurationMS {
            detailChip(
              text: Self.durationFormatter.string(from: TimeInterval(totalDurationMS) / 1000) ?? "-",
              systemImage: "waveform.path.ecg"
            )
          }
        }

        if let latestErrorCode = item.latestErrorCode {
          HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.system(size: 12))
            Text(latestErrorCode.replacingOccurrences(of: "_", with: " "))
              .font(.system(size: 12))
          }
          .foregroundStyle(AppPalette.destructive)
          .padding(.top, 10)
        }
      }
      .appCardStyle()
    }
    .buttonStyle(.plain)
  }

  private func detailChip(text: String, systemImage: String) -> some View {
    HStack(spacing: 4) {
      Image(systemName: systemImage)
        .font(.system(size: 11))
      Text(text)
        .font(.system(size: 12))
    }
    .foregroundStyle(AppPalette.mutedForeground)
  }

  private static func dateLabel(for date: Date) -> String {
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

  private static let durationFormatter: DateComponentsFormatter = {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.hour, .minute]
    formatter.unitsStyle = .abbreviated
    formatter.zeroFormattingBehavior = .dropAll
    return formatter
  }()
}
#endif
