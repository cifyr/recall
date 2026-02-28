import SwiftUI

@main
struct WatchRecorderApp: App {
  var body: some Scene {
    WindowGroup {
      WatchRootView(viewModel: WatchRecorderViewModel())
    }
  }
}
