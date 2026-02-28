import XCTest
@testable import AppleWatchRecorder

final class SessionModelDecodingTests: XCTestCase {
  func testSessionFeedItemDTOMapsToModel() throws {
    let json = """
    {
      "session_id": "11111111-1111-1111-1111-111111111111",
      "started_at": "2026-02-28T12:00:00Z",
      "ended_at": "2026-02-28T12:15:00Z",
      "status": "summarized",
      "segment_count": 3,
      "total_duration_ms": 300000,
      "user_notes": "Follow up next week",
      "latest_summary_excerpt": "Discussed the watch upload flow",
      "question_count": 2,
      "latest_error_code": null,
      "updated_at": "2026-02-28T12:20:00Z"
    }
    """

    let dto = try JSONCoding.decoder.decode(SessionFeedItemDTO.self, from: Data(json.utf8))
    let model = dto.model()

    XCTAssertEqual(model.status, .summarized)
    XCTAssertEqual(model.segmentCount, 3)
    XCTAssertEqual(model.questionCount, 2)
    XCTAssertEqual(model.userNotes, "Follow up next week")
  }
}
