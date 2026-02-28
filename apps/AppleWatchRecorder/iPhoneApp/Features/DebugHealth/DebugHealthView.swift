import SwiftUI

struct DebugHealthView: View {
  let repository: any SessionRepository
  let queueStore: QueueStore
  let deviceID: String

  @State private var snapshot: DeviceHealthSnapshot?
  @State private var queueDepth = 0
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      List {
        Section("Device") {
          Label(snapshot?.currentDeviceID ?? deviceID, systemImage: "iphone")
        }

        Section("Queue") {
          Label("\(queueDepth)", systemImage: "tray.full")
        }

        Section("Usage") {
          Label("\(snapshot?.dailyAudioUsageSeconds ?? 0) sec", systemImage: "waveform")
          Label("\(Int(snapshot?.weeklySpendPercent ?? 0))%", systemImage: "dollarsign.circle")
        }

        if let snapshot, !snapshot.lastSyncErrors.isEmpty {
          Section("Last Sync Errors") {
            ForEach(snapshot.lastSyncErrors, id: \.self) { error in
              Text(error)
                .foregroundStyle(.red)
            }
          }
        }
      }
      .navigationTitle("Health")
      .overlay(alignment: .bottom) {
        if let errorMessage {
          Text(errorMessage)
            .font(.footnote)
            .foregroundStyle(.red)
            .padding()
        }
      }
      .task {
        await reload()
      }
      .refreshable {
        await reload()
      }
    }
  }

  private func reload() async {
    do {
      queueDepth = try await queueStore.count()
      snapshot = try await repository.healthSnapshot(deviceID: deviceID)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
