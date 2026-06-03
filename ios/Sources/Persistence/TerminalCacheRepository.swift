import Foundation
import OSLog

private let log = Logger(subsystem: "ai.manaflow.cmux.ios", category: "persistence.terminal-cache")

final class TerminalCacheRepository: TerminalSnapshotPersisting {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func load() -> TerminalStoreSnapshot {
        do {
            return try database.readTerminalSnapshot()
        } catch {
            #if DEBUG
            log.error("Failed to load terminal snapshot from SQLite: \(error.localizedDescription, privacy: .public)")
            #endif
            return .empty()
        }
    }

    func save(_ snapshot: TerminalStoreSnapshot) throws {
        try database.writeTerminalSnapshot(snapshot)
    }
}
