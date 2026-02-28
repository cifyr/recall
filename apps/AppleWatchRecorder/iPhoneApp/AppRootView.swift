import SwiftUI

struct AppRootView: View {
  @Bindable var appModel: AppModel
  @State private var authCoordinator: AuthCoordinator?

  var body: some View {
    Group {
      if appModel.isBootstrapping {
        ProgressView("Connecting")
      } else if let authCoordinator {
        if appModel.authSession == nil && !appModel.isDemoModeEnabled {
          NavigationStack {
            AuthView(coordinator: authCoordinator) {
              appModel.enableDemoMode()
            }
          }
        } else {
          MainTabShell(appModel: appModel)
        }
      } else {
        ProgressView("Loading")
      }
    }
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

private struct MainTabShell: View {
  @Bindable var appModel: AppModel

  var body: some View {
    TabView {
      SessionsListView(
        viewModel: SessionsListViewModel(repository: appModel.repository, telemetry: appModel.telemetry)
      )
      .tabItem {
        Label("Sessions", systemImage: "waveform.badge.mic")
      }

      DebugHealthView(
        repository: appModel.repository,
        queueStore: appModel.queueStore,
        deviceID: appModel.deviceID
      )
      .tabItem {
        Label("Health", systemImage: "stethoscope")
      }
    }
  }
}
