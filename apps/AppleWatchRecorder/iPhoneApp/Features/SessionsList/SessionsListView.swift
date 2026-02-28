import SwiftUI

struct SessionsListView: View {
  @State var viewModel: SessionsListViewModel

  var body: some View {
    NavigationStack {
      Group {
        if viewModel.isLoading && viewModel.items.isEmpty {
          ProgressView("Loading Sessions")
        } else {
          List(viewModel.items) { item in
            NavigationLink {
              SessionDetailView(
                viewModel: SessionDetailViewModel(
                  repository: viewModel.repository,
                  sessionID: item.sessionID
                )
              )
            } label: {
              SessionRow(item: item)
            }
          }
          .refreshable {
            await viewModel.load()
          }
        }
      }
      .navigationTitle("Sessions")
      .overlay(alignment: .bottom) {
        if let errorMessage = viewModel.errorMessage {
          Text(errorMessage)
            .font(.footnote)
            .foregroundStyle(.red)
            .padding(12)
        }
      }
      .task {
        await viewModel.load()
      }
    }
  }
}

private struct SessionRow: View {
  let item: SessionFeedItem

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(item.startedAt, style: .time)
          .font(.headline)
        Spacer()
        Text(item.status.rawValue.replacingOccurrences(of: "_", with: " "))
          .font(.caption.weight(.semibold))
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(statusColor.opacity(0.12), in: Capsule())
      }

      if let excerpt = item.latestSummaryExcerpt {
        Text(excerpt)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      HStack(spacing: 12) {
        Label("\(item.segmentCount) segments", systemImage: "rectangle.stack")
        if let totalDurationMS = item.totalDurationMS {
          Label(Self.durationFormatter.string(from: TimeInterval(totalDurationMS / 1000)) ?? "-", systemImage: "timer")
        }
        if item.latestErrorCode != nil {
          Label("Sync issue", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }

  private var statusColor: Color {
    switch item.status {
    case .summarized:
      return .green
    case .failed:
      return .red
    default:
      return .orange
    }
  }

  private static let durationFormatter: DateComponentsFormatter = {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.hour, .minute, .second]
    formatter.unitsStyle = .abbreviated
    return formatter
  }()
}
