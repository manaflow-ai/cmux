import Foundation

/// Which events the person has read, kept across relaunches for every event, including
/// open asks (the archive keeps only finished turns, and the Mac re-reports asks unread).
public struct FeedReadMarks: Sendable {
    public let url: URL
    /// The most marks kept.
    static let limit = 500

    public init(url: URL) {
        self.url = url
    }

    public static var standard: FeedReadMarks {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return FeedReadMarks(url: base.appending(path: "Feed", directoryHint: .isDirectory).appending(path: "read.json"))
    }

    public func load() -> [String] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    }

    public func save(_ ids: [String]) {
        guard let data = try? JSONEncoder().encode(Array(ids.suffix(Self.limit))) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }
}
