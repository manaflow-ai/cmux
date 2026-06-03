import Foundation

final class InboxCacheRepository {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func load() throws -> [UnifiedInboxItem] {
        try database.readCachedInboxItems()
    }

    func save(_ items: [UnifiedInboxItem]) throws {
        try database.replaceCachedInboxItems(items)
    }

    func loadWorkspaceRows() throws -> [AppDatabase.WorkspaceInboxRow] {
        try database.readWorkspaceInboxRows()
    }
}
