import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Reachability stub the store can be driven by deterministically.
@MainActor
private final class FakeReachability: OfflineNotesReachabilityMonitoring {
    private(set) var isOnline: Bool
    var onChange: (@MainActor (Bool) -> Void)?

    init(isOnline: Bool) {
        self.isOnline = isOnline
    }

    func start() {}
    func stop() {}

    /// Simulates a connectivity transition, notifying observers like `NWPathMonitor` would.
    func setOnline(_ value: Bool) {
        guard isOnline != value else { return }
        isOnline = value
        onChange?(value)
    }
}

/// Dispatcher stub that records hand-offs and can be told to fail.
@MainActor
private final class FakeDispatcher: OfflineNoteDispatching {
    var shouldFail = false
    var error: Error = OfflineNoteDispatchError.noActiveWorkspace
    private(set) var dispatched: [OfflineNote] = []

    func dispatch(_ note: OfflineNote) async throws {
        dispatched.append(note)
        if shouldFail {
            throw error
        }
    }
}

@Suite @MainActor
struct OfflineNotesStoreTests {
    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-notes-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("offline-notes.json", isDirectory: false)
    }

    private func makeStore(
        fileURL: URL?,
        dispatcher: FakeDispatcher = FakeDispatcher(),
        reachability: FakeReachability,
        autostart: Bool = true
    ) -> OfflineNotesStore {
        OfflineNotesStore(
            fileURL: fileURL,
            dispatcher: dispatcher,
            reachability: reachability,
            autostart: autostart
        )
    }

    /// Polls until `condition` holds or the timeout elapses, yielding so any
    /// fire-and-forget flush task can run on the main actor.
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Persistence

    @Test
    func notesSurviveRestartAndIgnoreWhitespace() async throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = makeStore(fileURL: url, reachability: FakeReachability(isOnline: false), autostart: false)
        #expect(first.addNote("   \n  ") == nil)
        let note = first.addNote("ship the offline notes feature")
        #expect(note != nil)
        #expect(first.notes.count == 1)
        // Persistence is coalesced + off-main; wait for the write to land on disk.
        await first.waitForPendingPersist()

        // A fresh store instance (simulating an app restart) reloads from disk.
        let reloaded = makeStore(fileURL: url, reachability: FakeReachability(isOnline: false), autostart: false)
        #expect(reloaded.notes.count == 1)
        #expect(reloaded.notes.first?.text == "ship the offline notes feature")
        #expect(reloaded.notes.first?.status == .pending)
    }

    @Test
    func sendingNotesResetToPendingOnLoad() throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Simulate a note left mid-flight by a crash/relaunch.
        let stuck = OfflineNote(text: "interrupted", status: .sending)
        let data = try OfflineNotesStore.makeEncoder().encode([stuck])
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)

        let store = makeStore(fileURL: url, reachability: FakeReachability(isOnline: false), autostart: false)
        #expect(store.notes.first?.status == .pending)
    }

    // MARK: - Connectivity-gated flush

    @Test
    func offlineDoesNotFlush() async throws {
        let dispatcher = FakeDispatcher()
        let store = makeStore(fileURL: nil, dispatcher: dispatcher, reachability: FakeReachability(isOnline: false))
        store.addNote("queued while offline")

        await store.flush() // no-op while offline

        #expect(dispatcher.dispatched.isEmpty)
        #expect(store.notes.first?.status == .pending)
    }

    @Test
    func regainingConnectivityFlushesPendingNotes() async throws {
        let dispatcher = FakeDispatcher()
        let reachability = FakeReachability(isOnline: false)
        let store = makeStore(fileURL: nil, dispatcher: dispatcher, reachability: reachability)
        store.addNote("first")
        store.addNote("second")

        reachability.setOnline(true) // triggers the auto-flush on reconnect

        await waitUntil { store.notes.allSatisfy { $0.status == .sent } }
        #expect(dispatcher.dispatched.count == 2)
        #expect(store.sentCount == 2)
        #expect(store.pendingCount == 0)
        #expect(store.notes.first?.sentAt != nil)
    }

    @Test
    func captureWhileOnlineDispatchesImmediately() async throws {
        let dispatcher = FakeDispatcher()
        let reachability = FakeReachability(isOnline: false)
        let store = makeStore(fileURL: nil, dispatcher: dispatcher, reachability: reachability)
        reachability.setOnline(true) // store is now online with an empty queue

        store.addNote("captured while online")

        await waitUntil { store.notes.first?.status == .sent }
        #expect(dispatcher.dispatched.count == 1)
        #expect(store.notes.first?.status == .sent)
    }

    // MARK: - Failure + retry

    @Test
    func failedDispatchIsRetryable() async throws {
        let dispatcher = FakeDispatcher()
        dispatcher.shouldFail = true
        let reachability = FakeReachability(isOnline: false)
        let store = makeStore(fileURL: nil, dispatcher: dispatcher, reachability: reachability)
        let note = store.addNote("flaky note")
        let id = try #require(note?.id)

        reachability.setOnline(true)
        await waitUntil { store.notes.first?.status == .failed }

        #expect(store.notes.first?.status == .failed)
        #expect(store.notes.first?.attemptCount == 1)
        #expect(store.notes.first?.lastError != nil)
        #expect(store.failedCount == 1)

        // Recover and retry.
        dispatcher.shouldFail = false
        store.retry(id: id)
        await waitUntil { store.notes.first?.status == .sent }

        #expect(store.notes.first?.status == .sent)
        #expect(store.notes.first?.attemptCount == 2)
        #expect(dispatcher.dispatched.count == 2)
    }

    // MARK: - Reentrancy

    @Test
    func concurrentFlushesDispatchEachNoteOnce() async throws {
        let dispatcher = FakeDispatcher()
        let reachability = FakeReachability(isOnline: false)
        let store = makeStore(fileURL: nil, dispatcher: dispatcher, reachability: reachability)
        store.addNote("a")
        store.addNote("b")
        reachability.setOnline(true)

        // Two overlapping flushes must not double-dispatch.
        async let firstFlush: Void = store.flush()
        async let secondFlush: Void = store.flush()
        _ = await (firstFlush, secondFlush)

        await waitUntil { store.notes.allSatisfy { $0.status == .sent } }
        #expect(dispatcher.dispatched.count == 2)
    }

    // MARK: - Housekeeping

    @Test
    func clearSentRemovesOnlySentNotes() async throws {
        let dispatcher = FakeDispatcher()
        let reachability = FakeReachability(isOnline: false)
        let store = makeStore(fileURL: nil, dispatcher: dispatcher, reachability: reachability)
        store.addNote("will send")
        reachability.setOnline(true)
        await waitUntil { store.sentCount == 1 }

        reachability.setOnline(false)
        store.addNote("still pending")

        store.clearSent()
        #expect(store.notes.count == 1)
        #expect(store.notes.first?.text == "still pending")
        #expect(store.notes.first?.status == .pending)
    }

    // MARK: - Bounded growth

    @Test
    func longNoteIsTruncatedToCap() {
        let store = makeStore(fileURL: nil, reachability: FakeReachability(isOnline: false))
        let huge = String(repeating: "a", count: OfflineNotesStore.maxNoteLength + 50)
        let note = store.addNote(huge)
        #expect(note?.text.count == OfflineNotesStore.maxNoteLength)
    }

    @Test
    func cliArgumentParsesNotesMode() {
        #expect(RightSidebarMode.from(cliArgument: "notes") == .notes)
        #expect(RightSidebarMode.from(cliArgument: "NOTES") == .notes)
    }

    @Test
    func captureRecordsWorkspaceBinding() {
        let store = makeStore(fileURL: nil, reachability: FakeReachability(isOnline: false))
        let workspaceID = UUID()
        let note = store.addNote("bound note", workspaceID: workspaceID)
        #expect(note?.workspaceID == workspaceID)
    }

    @Test
    func queueAppliesBackpressureWhenFull() {
        let store = makeStore(fileURL: nil, reachability: FakeReachability(isOnline: false))
        for index in 0..<OfflineNotesStore.maxTotalNotes {
            _ = store.addNote("note \(index)")
        }
        #expect(store.notes.count == OfflineNotesStore.maxTotalNotes)
        // The queue is full of pending notes (none sent to reclaim), so further
        // captures are refused rather than growing unbounded.
        #expect(store.addNote("one too many") == nil)
        #expect(store.notes.count == OfflineNotesStore.maxTotalNotes)
    }

    @Test
    func sentNotesArePrunedToCapPreservingOldestEviction() async throws {
        let dispatcher = FakeDispatcher()
        let reachability = FakeReachability(isOnline: false)
        let store = makeStore(fileURL: nil, dispatcher: dispatcher, reachability: reachability)

        let total = OfflineNotesStore.maxRetainedSentNotes + 5
        var oldestID: UUID?
        for index in 0..<total {
            let note = store.addNote("note \(index)")
            if index == 0 { oldestID = note?.id }
        }

        reachability.setOnline(true)
        await waitUntil(timeout: 8.0) { store.sentCount == OfflineNotesStore.maxRetainedSentNotes }

        #expect(dispatcher.dispatched.count == total)
        #expect(store.sentCount == OfflineNotesStore.maxRetainedSentNotes)
        #expect(store.notes.count == OfflineNotesStore.maxRetainedSentNotes)
        // The oldest sent note is the one evicted.
        let evicted = try #require(oldestID)
        #expect(!store.notes.contains { $0.id == evicted })
    }
}
