import Foundation

struct EventIngestResponse: Decodable {
  let accepted: Int
  let rejected: Int
}

struct EventIngestRequest: Encodable {
  let events: [Payload]

  struct Payload: Encodable {
    let eventID: UUID
    let eventName: String
    let eventVersion: Int
    let occurredAt: Date
    let appSessionID: UUID?
    let conversationSessionID: UUID?
    let properties: [String: String]

    enum CodingKeys: String, CodingKey {
      case eventID = "event_id"
      case eventName = "event_name"
      case eventVersion = "event_version"
      case occurredAt = "occurred_at"
      case appSessionID = "app_session_id"
      case conversationSessionID = "conversation_session_id"
      case properties
    }
  }
}

actor TelemetryClient: TelemetryRecording {
  private let edgeClient: EdgeFunctionClient?
  private let deviceID: String

  init(edgeClient: EdgeFunctionClient?, deviceID: String) {
    self.edgeClient = edgeClient
    self.deviceID = deviceID
  }

  func track(_ events: [TelemetryEvent]) async {
    guard let edgeClient, !events.isEmpty else { return }
    let request = EventIngestRequest(
      events: events.map {
        EventIngestRequest.Payload(
          eventID: $0.eventID,
          eventName: $0.eventName,
          eventVersion: $0.eventVersion,
          occurredAt: $0.occurredAt,
          appSessionID: $0.appSessionID,
          conversationSessionID: $0.conversationSessionID,
          properties: $0.properties
        )
      }
    )

    do {
      _ = try await edgeClient.invoke(
        function: "ingest-events",
        body: request,
        requestIdentity: .make(),
        deviceID: deviceID
      ) as EventIngestResponse
    } catch {
      #if DEBUG
      print("Telemetry ingest failed: \(error)")
      #endif
    }
  }
}
