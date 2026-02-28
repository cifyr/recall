import Foundation

#if canImport(GRDB)
import GRDB
#endif

actor QueueStore: QueueStoreProtocol {
  #if canImport(GRDB)
  private let databaseQueue: DatabaseQueue?
  #endif
  private var memoryRecords: [UUID: QueueRecord] = [:]

  init(databasePath: String? = nil) {
    #if canImport(GRDB)
    if let databasePath {
      databaseQueue = try? DatabaseQueue(path: databasePath)
      try? databaseQueue?.write { database in
        try database.create(table: "sync_queue", ifNotExists: true) { table in
          table.column("queue_id", .text).primaryKey()
          table.column("payload_json", .text).notNull()
          table.column("file_url", .text)
          table.column("attempt_count", .integer).notNull()
          table.column("next_attempt_at", .datetime).notNull()
          table.column("last_error_code", .text)
          table.column("last_error_message", .text)
          table.column("created_at", .datetime).notNull()
          table.column("updated_at", .datetime).notNull()
          table.column("operation_kind", .text).notNull()
          table.column("session_id", .text)
          table.column("segment_index", .integer)
        }
      }
    } else {
      databaseQueue = nil
    }
    #endif
  }

  func enqueue(_ record: QueueRecord) async throws {
    memoryRecords[record.queueID] = record
  }

  func update(_ record: QueueRecord) async throws {
    memoryRecords[record.queueID] = record
  }

  func remove(queueID: UUID) async throws {
    memoryRecords.removeValue(forKey: queueID)
  }

  func allRecords() async throws -> [QueueRecord] {
    Array(memoryRecords.values).sorted { $0.nextAttemptAt < $1.nextAttemptAt }
  }

  func count() async throws -> Int {
    memoryRecords.count
  }
}
