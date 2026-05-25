public import Foundation

/// App-group-backed cache that the main app writes on every snapshot
/// update and the widget extension reads from `getTimeline`. Lives in
/// `CmuxKit` so both the app target and the widget extension can use it
/// without importing each other.
public struct CmuxWidgetEntry: Codable, Sendable, Hashable {
    public let date: Date
    public let workspaceTitle: String
    public let branch: String?
    public let unread: Int
    public let host: String

    public init(
        date: Date,
        workspaceTitle: String,
        branch: String?,
        unread: Int,
        host: String
    ) {
        self.date = date
        self.workspaceTitle = workspaceTitle
        self.branch = branch
        self.unread = unread
        self.host = host
    }
}

public final class CmuxWidgetStateStore: @unchecked Sendable {
    public static let shared = CmuxWidgetStateStore(
        appGroup: "group.com.cmuxterm.remote"
    )

    private let fileURL: URL

    public init(appGroup: String) {
        let dir = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) ?? FileManager.default.temporaryDirectory
        self.fileURL = dir.appendingPathComponent("widget-state.json", isDirectory: false)
    }

    public func write(_ entry: CmuxWidgetEntry) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    public func load() -> CmuxWidgetEntry? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(CmuxWidgetEntry.self, from: data)
    }
}
