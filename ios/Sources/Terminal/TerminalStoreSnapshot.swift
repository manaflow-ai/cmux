import Foundation

struct TerminalStoreSnapshot: Codable, Equatable, Sendable {
    var version = 1
    var hosts: [TerminalHost]
    var workspaces: [TerminalWorkspace]
    var selectedWorkspaceID: TerminalWorkspace.ID?

    static func empty() -> Self {
        Self(
            hosts: [],
            workspaces: [],
            selectedWorkspaceID: nil
        )
    }

    static func seed() -> Self {
        Self(
            hosts: [
                TerminalHost(
                    name: String(
                        localized: "terminal.seed.mac_mini",
                        defaultValue: "Mac Mini"
                    ),
                    hostname: "cmux-macmini",
                    username: "cmux",
                    symbolName: "desktopcomputer",
                    palette: .mint,
                    sortIndex: 0
                )
            ],
            workspaces: [],
            selectedWorkspaceID: nil
        )
    }
}

protocol TerminalSnapshotPersisting {
    func load() -> TerminalStoreSnapshot
    func save(_ snapshot: TerminalStoreSnapshot) throws
}

final class TerminalSnapshotStore: TerminalSnapshotPersisting {
    private let fileURL: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> TerminalStoreSnapshot {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? decoder.decode(TerminalStoreSnapshot.self, from: data) else {
            return .empty()
        }

        return snapshot
    }

    func save(_ snapshot: TerminalStoreSnapshot) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func defaultFileURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            FileManager.default.temporaryDirectory
        return baseURL.appendingPathComponent("terminal-store.json")
    }
}

final class InMemoryTerminalSnapshotStore: TerminalSnapshotPersisting {
    private var snapshot: TerminalStoreSnapshot

    init(snapshot: TerminalStoreSnapshot = .seed()) {
        self.snapshot = snapshot
    }

    func load() -> TerminalStoreSnapshot {
        snapshot
    }

    func save(_ snapshot: TerminalStoreSnapshot) throws {
        self.snapshot = snapshot
    }
}
