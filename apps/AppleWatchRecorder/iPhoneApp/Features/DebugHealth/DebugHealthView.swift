import SwiftUI

#if os(iOS)
struct DebugHealthView: View {
  let repository: any SessionRepository
  let queueStore: QueueStore
  let deviceID: String
  let userEmail: String?
  let onSignOut: () async -> Void
  let onSyncWithWatch: () async -> Void
  @Binding var isWatchDebugModeEnabled: Bool

  @State private var snapshot: DeviceHealthSnapshot?
  @State private var queueDepth = 0
  @State private var errorMessage: String?
  @State private var isRefreshing = false
  @State private var isSigningOut = false
  @State private var isSyncingWithWatch = false

  private let columns = [
    GridItem(.flexible(), spacing: 10),
    GridItem(.flexible(), spacing: 10),
  ]

  var body: some View {
    VStack(spacing: 0) {
      header

      ScrollView(showsIndicators: false) {
        VStack(alignment: .leading, spacing: 12) {
          LazyVGrid(columns: columns, spacing: 10) {
            metricCard(
              systemImage: "iphone",
              label: "Device ID",
              value: abbreviatedDeviceID,
              accentBackground: Color.blue.opacity(0.12),
              accentForeground: Color.blue
            )

            metricCard(
              systemImage: "externaldrive",
              label: "Queue Depth",
              value: "\(queueDepth) items",
              accentBackground: Color.purple.opacity(0.12),
              accentForeground: Color.purple
            )

            metricCard(
              systemImage: "clock",
              label: "Daily Audio Usage",
              value: formatDuration(snapshot?.dailyAudioUsageSeconds ?? 0),
              accentBackground: Color.orange.opacity(0.12),
              accentForeground: Color.orange
            )

            metricCard(
              systemImage: "dollarsign",
              label: "Weekly Spend",
              value: "\(Int(snapshot?.weeklySpendPercent ?? 0))%",
              accentBackground: Color.green.opacity(0.12),
              accentForeground: Color.green
            )
          }

          VStack(alignment: .leading, spacing: 6) {
            Text("Full Device ID")
              .font(.system(size: 12))
              .foregroundStyle(AppPalette.mutedForeground)
            Text(snapshot?.currentDeviceID ?? deviceID)
              .font(.system(size: 12, weight: .medium, design: .monospaced))
              .foregroundStyle(AppPalette.foreground)
              .textSelection(.enabled)
          }
          .appCardStyle()

          if let snapshot, !snapshot.lastSyncErrors.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
              HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                  .font(.system(size: 14))
                  .foregroundStyle(AppPalette.destructive)
                Text("Last Sync Errors")
                  .font(.system(size: 14, weight: .medium))
                  .foregroundStyle(AppPalette.foreground)
              }

              VStack(alignment: .leading, spacing: 8) {
                ForEach(snapshot.lastSyncErrors, id: \.self) { error in
                  Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(AppPalette.destructive)
                }
              }
            }
            .appCardStyle()
          }

          accountSection
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 16)
      }
      .refreshable {
        await reload()
      }
    }
    .background(AppPalette.background.ignoresSafeArea())
    .overlay(alignment: .bottom) {
      if let errorMessage {
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
      await reload()
    }
  }

  private var header: some View {
    HStack {
      Text("Health")
        .font(.system(size: 28, weight: .semibold))
        .foregroundStyle(AppPalette.foreground)

      Spacer()

      Button {
        Task { await reload() }
      } label: {
        ZStack {
          Circle()
            .fill(AppPalette.muted)
            .frame(width: 36, height: 36)

          Image(systemName: "arrow.clockwise")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(AppPalette.mutedForeground)
            .rotationEffect(.degrees(isRefreshing ? 360 : 0))
            .animation(isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isRefreshing)
        }
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 20)
    .padding(.top, 12)
    .padding(.bottom, 12)
  }

  private var abbreviatedDeviceID: String {
    let value = snapshot?.currentDeviceID ?? deviceID
    return value.count > 8 ? "\(value.prefix(8))..." : value
  }

  private var accountSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: "person.crop.circle")
          .font(.system(size: 14))
          .foregroundStyle(AppPalette.mutedForeground)
        Text("Account")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(AppPalette.foreground)
      }

      if let userEmail {
        Text(userEmail)
          .font(.system(size: 13))
          .foregroundStyle(AppPalette.mutedForeground)
      }

      Toggle(isOn: $isWatchDebugModeEnabled) {
        HStack(spacing: 6) {
          Image(systemName: "ladybug")
            .font(.system(size: 13, weight: .medium))
          Text("Watch Debug Mode")
            .font(.system(size: 14, weight: .medium))
        }
        .foregroundStyle(AppPalette.foreground)
      }
      .tint(AppPalette.primary)
      .padding(.vertical, 4)

      Button {
        guard !isSyncingWithWatch else { return }
        isSyncingWithWatch = true
        Task {
          await onSyncWithWatch()
          isSyncingWithWatch = false
        }
      } label: {
        HStack(spacing: 6) {
          if isSyncingWithWatch {
            ProgressView()
              .tint(AppPalette.primary)
              .controlSize(.small)
          } else {
            Image(systemName: "applewatch")
              .font(.system(size: 13, weight: .medium))
          }
          Text("Sync with Watch")
            .font(.system(size: 14, weight: .medium))
        }
        .foregroundStyle(AppPalette.primary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(AppPalette.primary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      }
      .buttonStyle(.plain)
      .disabled(isSyncingWithWatch)

      Button {
        guard !isSigningOut else { return }
        isSigningOut = true
        Task {
          await onSignOut()
          isSigningOut = false
        }
      } label: {
        HStack(spacing: 6) {
          if isSigningOut {
            ProgressView()
              .tint(AppPalette.destructive)
              .controlSize(.small)
          } else {
            Image(systemName: "rectangle.portrait.and.arrow.right")
              .font(.system(size: 13, weight: .medium))
          }
          Text("Sign Out")
            .font(.system(size: 14, weight: .medium))
        }
        .foregroundStyle(AppPalette.destructive)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(AppPalette.destructive.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      }
      .buttonStyle(.plain)
      .disabled(isSigningOut)
    }
    .appCardStyle()
  }

  private func metricCard(
    systemImage: String,
    label: String,
    value: String,
    accentBackground: Color,
    accentForeground: Color
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      ZStack {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(accentBackground)
          .frame(width: 36, height: 36)

        Image(systemName: systemImage)
          .font(.system(size: 18, weight: .medium))
          .foregroundStyle(accentForeground)
      }
      .padding(.bottom, 12)

      Text(label)
        .font(.system(size: 12))
        .foregroundStyle(AppPalette.mutedForeground)
        .padding(.bottom, 2)

      Text(value)
        .font(.system(size: 15))
        .foregroundStyle(AppPalette.foreground)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .appCardStyle()
  }

  private func formatDuration(_ seconds: Int) -> String {
    let minutes = seconds / 60
    let remainder = seconds % 60
    return "\(minutes)m \(remainder)s"
  }

  private func reload() async {
    isRefreshing = true
    defer { isRefreshing = false }

    do {
      queueDepth = try await queueStore.count()
      snapshot = try await repository.healthSnapshot(deviceID: deviceID)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
#endif
