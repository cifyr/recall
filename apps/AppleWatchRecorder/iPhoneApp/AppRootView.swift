#if os(iOS)
import SwiftUI

enum AppTab: Hashable {
  case sessions
  case health
}

enum AppRoute: Hashable {
  case session(UUID)
}

enum AppPalette {
  static let background = Color.white
  static let foreground = Color(red: 3 / 255, green: 2 / 255, blue: 19 / 255)
  static let primary = Color(red: 3 / 255, green: 2 / 255, blue: 19 / 255)
  static let primaryForeground = Color.white
  static let muted = Color(red: 236 / 255, green: 236 / 255, blue: 240 / 255)
  static let mutedForeground = Color(red: 113 / 255, green: 113 / 255, blue: 130 / 255)
  static let accent = Color(red: 233 / 255, green: 235 / 255, blue: 239 / 255)
  static let border = Color.black.opacity(0.1)
  static let inputBackground = Color(red: 243 / 255, green: 243 / 255, blue: 245 / 255)
  static let destructive = Color(red: 212 / 255, green: 24 / 255, blue: 61 / 255)
  static let successBackground = Color(red: 240 / 255, green: 253 / 255, blue: 244 / 255)
  static let successBorder = Color(red: 187 / 255, green: 247 / 255, blue: 208 / 255)
  static let successText = Color(red: 21 / 255, green: 128 / 255, blue: 61 / 255)
}

struct CardContainerStyle: ViewModifier {
  func body(content: Content) -> some View {
    content
      .padding(16)
      .background(AppPalette.background)
      .overlay(
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .stroke(AppPalette.border, lineWidth: 1)
      )
      .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
  }
}

extension View {
  func appCardStyle() -> some View {
    modifier(CardContainerStyle())
  }
}

struct SessionStatusPresentation {
  let label: String
  let background: Color
  let foreground: Color
}

extension SessionStatus {
  var presentation: SessionStatusPresentation {
    switch self {
    case .summarized:
      return .init(
        label: "Completed",
        background: Color.green.opacity(0.14),
        foreground: Color(red: 21 / 255, green: 128 / 255, blue: 61 / 255)
      )
    case .failed:
      return .init(
        label: "Failed",
        background: AppPalette.destructive.opacity(0.12),
        foreground: AppPalette.destructive
      )
    case .syncPending:
      return .init(
        label: "Pending",
        background: Color.orange.opacity(0.14),
        foreground: Color.orange
      )
    case .uploaded, .transcribing, .transcribed, .summarizing:
      return .init(
        label: "Processing",
        background: Color.blue.opacity(0.12),
        foreground: Color.blue
      )
    }
  }
}

struct AppTabBar: View {
  @Binding var selectedTab: AppTab

  var body: some View {
    HStack {
      tabButton(tab: .sessions, title: "Sessions", systemImage: "mic.fill")
      Spacer(minLength: 16)
      tabButton(tab: .health, title: "Health", systemImage: "waveform.path.ecg")
    }
    .padding(.horizontal, 28)
    .padding(.top, 10)
    .padding(.bottom, 10)
    .background(.ultraThinMaterial)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(AppPalette.border)
        .frame(height: 1)
    }
  }

  private func tabButton(tab: AppTab, title: String, systemImage: String) -> some View {
    let isSelected = selectedTab == tab

    return Button {
      selectedTab = tab
    } label: {
      VStack(spacing: 2) {
        Image(systemName: systemImage)
          .font(.system(size: 18, weight: .medium))
        Text(title)
          .font(.system(size: 10, weight: .medium))
      }
      .frame(maxWidth: .infinity)
      .foregroundStyle(isSelected ? AppPalette.primary : AppPalette.mutedForeground)
      .padding(.vertical, 2)
    }
    .buttonStyle(.plain)
  }
}

private struct CenteredStateView: View {
  let systemImage: String
  let title: String
  let isSpinning: Bool
  @State private var iconRotation = 0.0

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: systemImage)
        .font(.system(size: 30, weight: .medium))
        .foregroundStyle(AppPalette.mutedForeground)
        .rotationEffect(.degrees(iconRotation))
        .onAppear {
          guard isSpinning else { return }
          withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
            iconRotation = 360
          }
        }

      Text(title)
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(AppPalette.mutedForeground)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AppPalette.background.ignoresSafeArea())
  }
}

private struct MainTabShell: View {
  @Bindable var appModel: AppModel
  @State private var selectedTab: AppTab = .sessions
  @State private var path: [AppRoute] = []

  var body: some View {
    NavigationStack(path: $path) {
      rootContent
        .background(AppPalette.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: AppRoute.self) { route in
          switch route {
          case let .session(sessionID):
            SessionDetailView(
              viewModel: SessionDetailViewModel(
                repository: appModel.repository,
                sessionID: sessionID
              )
            )
          }
        }
    }
  }

  @ViewBuilder
  private var rootContent: some View {
    Group {
      switch selectedTab {
      case .sessions:
        SessionsListView(
          viewModel: SessionsListViewModel(repository: appModel.repository, telemetry: appModel.telemetry),
          onOpenSession: { sessionID in
            path.append(.session(sessionID))
          }
        )
      case .health:
        DebugHealthView(
          repository: appModel.repository,
          queueStore: appModel.queueStore,
          deviceID: appModel.deviceID,
          userEmail: appModel.authSession?.email,
          onSignOut: { await appModel.signOut() },
          onSyncWithWatch: { await appModel.syncWatchAuthState() },
          isWatchDebugModeEnabled: Binding(
            get: { appModel.isDebugModeEnabled },
            set: { appModel.isDebugModeEnabled = $0 }
          )
        )
      }
    }
    .safeAreaInset(edge: .bottom) {
      AppTabBar(selectedTab: $selectedTab)
    }
    .overlay(alignment: .bottom) {
      if let bootstrapError = appModel.bootstrapError {
        Text(bootstrapError)
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
          .padding(.bottom, 76)
      }
    }
  }
}

struct AppRootView: View {
  @Bindable var appModel: AppModel
  @State private var authCoordinator: AuthCoordinator?

  var body: some View {
    Group {
      if appModel.isBootstrapping {
        CenteredStateView(systemImage: "wifi", title: "Connecting...", isSpinning: false)
      } else if let authCoordinator {
        if appModel.authSession == nil && !appModel.isDemoModeEnabled {
          AuthView(coordinator: authCoordinator) {
            appModel.enableDemoMode()
          }
        } else {
          MainTabShell(appModel: appModel)
        }
      } else {
        CenteredStateView(systemImage: "arrow.triangle.2.circlepath", title: "Loading...", isSpinning: true)
      }
    }
    .background(AppPalette.background.ignoresSafeArea())
    .task {
      if authCoordinator == nil {
        authCoordinator = AuthCoordinator(authProvider: appModel.authClient) { session in
          appModel.authSession = session
          Task {
            await appModel.completeSignIn()
          }
        }
      }
    }
  }
}
#endif
