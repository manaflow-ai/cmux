import Foundation

/// Which terminal tabs still run on a placeholder session and must move to
/// their live session once one exists (design/terminal R1-0). A page built
/// before live data (a launch restore opens the workspace before the link and
/// the workspace tree are up) gets the connecting placeholder; nothing asked
/// for that page again, so it said "Connecting to <Mac>…" until the user left
/// and reopened the workspace. Every live-data change now offers the
/// placeholder tabs their live session. Portable rules, unit tested.
public struct TerminalTabUpgrade: Sendable {
    /// Tabs whose page shows a placeholder, with the workspace they belong to.
    public private(set) var placeholders: [String: String] = [:]

    public init() {}

    /// A tab's host was built, on a live session or a placeholder.
    public mutating func built(tabID: String, workspaceID: String, live: Bool) {
        placeholders[tabID] = live ? nil : workspaceID
    }

    /// The tab's host went away (closed, cooled, reset).
    public mutating func removed(tabID: String) {
        placeholders[tabID] = nil
    }

    public mutating func reset() {
        placeholders = [:]
    }

    /// Live data changed: the placeholder tabs that now have a live session
    /// (`hasLiveSession`), in a stable order.
    public func upgradable(hasLiveSession: (String) -> Bool) -> [String] {
        placeholders.keys.sorted().filter(hasLiveSession)
    }
}

/// The last frame of each terminal tab, kept on disk so a cold launch that
/// restores a tab shows it (dimmed, under "Connecting…") instead of skeleton
/// rows until the Mac's terminal is attached (design/terminal R1-0).
public struct TerminalFrameStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `Caches/cnx-terminal-frames`.
    public static var standard: TerminalFrameStore {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return TerminalFrameStore(directory: caches.appendingPathComponent("cnx-terminal-frames", isDirectory: true))
    }

    /// One file per tab; the id is reduced to safe file name characters.
    public func url(for tabID: String) -> URL {
        let safe = String(tabID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "_" })
        return directory.appendingPathComponent(safe.isEmpty ? "_" : safe).appendingPathExtension("jpg")
    }

    public func save(_ data: Data, for tabID: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(for: tabID), options: .atomic)
    }

    public func load(_ tabID: String) -> Data? {
        try? Data(contentsOf: url(for: tabID))
    }

    public func remove(_ tabID: String) {
        try? FileManager.default.removeItem(at: url(for: tabID))
    }
}
