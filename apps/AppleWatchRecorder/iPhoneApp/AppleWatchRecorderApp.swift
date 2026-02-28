import SwiftUI

@main
struct AppleWatchRecorderApp: App {
  @State private var appModel = AppModel()

  var body: some Scene {
    WindowGroup {
      AppRootView(appModel: appModel)
        .task {
          await appModel.bootstrap()
        }
    }
  }
}
