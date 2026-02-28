import XCTest
@testable import AppleWatchRecorder

final class QueueRecordTests: XCTestCase {
  func testQueueRecordIdentityAndOrderingFields() {
    let now = Date()
    let record = QueueRecord(
      queueID: UUID(),
      operationKind: .finalizeSession,
      sessionID: UUID(),
      segmentIndex: 0,
      payloadJSON: "{}",
      fileURL: nil,
      attemptCount: 1,
      nextAttemptAt: now.addingTimeInterval(30),
      lastErrorCode: "network_error",
      lastErrorMessage: "Timed out",
      createdAt: now,
      updatedAt: now
    )

    XCTAssertEqual(record.operationKind, .finalizeSession)
    XCTAssertEqual(record.lastErrorCode, "network_error")
  }
}
