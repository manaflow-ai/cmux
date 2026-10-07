public import Foundation

/// Where the composer state lives between launches.
public protocol TerminalComposePersisting: Sendable {
    func load() -> Data?
    func save(_ data: Data)
    func remove()
}

/// One file, protected until the first unlock after boot (drafts may hold
/// prompts the user would not want readable from a locked, never-unlocked
/// phone), excluded from backups.
public struct FileTerminalComposePersistence: TerminalComposePersisting {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `Application Support/cmux/terminal-compose.json`.
    public static func standard() -> FileTerminalComposePersistence {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return FileTerminalComposePersistence(url: base.appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("terminal-compose.json"))
    }

    public func load() -> Data? {
        try? Data(contentsOf: url)
    }

    public func save(_ data: Data) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        let options: Data.WritingOptions = [.atomic]
        #endif
        guard (try? data.write(to: url, options: options)) != nil else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var marked = url
        try? marked.setResourceValues(values)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
