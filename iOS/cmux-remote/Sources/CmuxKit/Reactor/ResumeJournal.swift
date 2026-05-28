public import Foundation
public import Logging

/// Persists the event cursor so reconnects (across foreground/background
/// transitions and app launches) can resume cleanly per the documented cmux
/// event-stream resume contract.
public actor ResumeJournal {

    public struct Entry: Codable, Sendable {
        public let hostID: UUID
        public var cursor: CmuxEventCursor
        public var updatedAt: Date

        public init(hostID: UUID, cursor: CmuxEventCursor, updatedAt: Date = Date()) {
            self.hostID = hostID
            self.cursor = cursor
            self.updatedAt = updatedAt
        }
    }

    private let storeURL: URL
    private let log: Logger
    private var cache: [UUID: Entry] = [:]
    private var loaded = false
    private var lastDiskWrite: Date = .distantPast
    private let minimumWriteInterval: TimeInterval

    public init(
        directory: URL,
        minimumWriteInterval: TimeInterval = 5,
        logger: Logger = CmuxLog.make("resume-journal")
    ) {
        self.storeURL = directory.appendingPathComponent("resume.json", isDirectory: false)
        self.log = logger
        self.minimumWriteInterval = minimumWriteInterval
    }

    public func cursor(for hostID: UUID) async -> CmuxEventCursor {
        await ensureLoaded()
        return cache[hostID]?.cursor ?? CmuxEventCursor()
    }

    public func record(hostID: UUID, cursor: CmuxEventCursor) async {
        await ensureLoaded()
        cache[hostID] = Entry(hostID: hostID, cursor: cursor, updatedAt: Date())
        // Debounce disk writes — the cursor advances on every event in the
        // hot path, and we don't need to fsync each one. Worst case on a
        // crash we replay a few seconds of events, which is exactly what
        // the resume contract is designed to handle.
        let now = Date()
        if now.timeIntervalSince(lastDiskWrite) > minimumWriteInterval {
            lastDiskWrite = now
            save()
        }
    }

    /// Flush the in-memory cache to disk. Call this on graceful shutdown
    /// (e.g. `applicationDidEnterBackground`).
    public func flush() async {
        await ensureLoaded()
        save()
        lastDiskWrite = Date()
    }

    public func reset(hostID: UUID) async {
        await ensureLoaded()
        cache.removeValue(forKey: hostID)
        save()
    }

    private func ensureLoaded() async {
        if loaded { return }
        loaded = true
        guard let data = try? Data(contentsOf: storeURL) else { return }
        do {
            let entries = try JSONDecoder().decode([Entry].self, from: data)
            for entry in entries { cache[entry.hostID] = entry }
        } catch {
            log.warning("could not decode resume journal", metadata: ["error": .string("\(error)")])
        }
    }

    private func save() {
        do {
            let payload = try JSONEncoder().encode(Array(cache.values))
            let parent = storeURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try payload.write(to: storeURL, options: .atomic)
        } catch {
            log.error("could not write resume journal", metadata: ["error": .string("\(error)")])
        }
    }
}
