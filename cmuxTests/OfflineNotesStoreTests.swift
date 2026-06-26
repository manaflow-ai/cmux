import Foundation
import XCTest

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

@MainActor
final class OfflineNotesStoreTests: XCTestCase {
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

    func testNotesSurviveRestartAndIgnoreWhitespace() async throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = makeStore(fileURL: url, reachability: FakeReachability(isOnline: false), autostart: false)
        XCTAssertNil(first.addNote("   \n  "))
        let note = first.addNote("ship the offline notes feature")
        XCTAssertNotNil(note)
        XCTAssertEqual(first.notes.count, 1)
        // Persistence is coalesced + off-main; wait for the write to land on disk.
        await first.waitForPendingPersist()

        // A fresh store instance (simulating an app restart) reloads from disk.
        let reloaded = makeStore(fileURL: url, reachability: FakeReachability(isOnline: false), autostart: false)
        XCTAssertEqual(reloaded.notes.count, 1)
        XCTAssertEqual(reloaded.notes.first?.text, "ship the offline notes feature")
        XCTAssertEqual(reloaded.notes.first?.status, .pending)
    }

    func testSendingNotesResetToPendingOnLoad() throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Simulate a note left mid-flight by a crash/relaunch.
        let stuck = OfflineNote(text: "interrupted", status: .sending)
        let data = try OfflineNotesStore.encoder.encode([stuck])
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)

        let store = makeStore(fileURL: url, reachability: FakeReachability(isOnline: false), autostart: false)
        XCTAssertEqual(store.notes.first?.status, .pending)
    }

    // MARK: - Connectivity-gated flush

    func testOfflineDoesNotFlush() async throws {
        let dispatcher = FakeDispatcher()
        let store = makeStore(fileURL: nil, dispatcher: dispatcher, reachability: FakeReachability(isOnline: false))
        store.addNote("queued while offline")

        await store.flush() // no-op while offline

        XCTAssertTrue(dispatcher.dispatched.isEmpty)
        XCTAssertEqual(store.notes.first?.status, .pending)
    }

    func testRegainingConnectivityFlushesPendingNotes() async throws {
        let dispatcher = FakeDispatcher()
        let reachability = FakeReachability(isOnline: false)
        let store = makeStore(fileURL: nil, dispatcher: dispatcher, reachability: reachability)
        store.addNote("first")
        store.addNote("second")

        reachability.setOnline(true) // triggers the auto-flush on reconnect

        await waitUntil { store.notes.allSatisfy { $0.status == .sent } }
        XCTAssertEqual(dispatcher.dispatched.count, 2)
        XCTAssertEqual(store.sentCount, 2)
        XCTAssertEqual(store.pendingCount, 0)
        XCTAssertNotNil(store.notes.first?.sentAt)
    }

    // MARK: - Failure + retry

    func testFailedDispatchIsRetryable() async throws {
        let dispatcher = FakeDispatcher()
        dispatcher.shouldFail = true
        let reachability = FakeReachability(isOnline: false)
        let store = makeStore(fileURL: nil, dispatcher: dispatcher, reachability: reachability)
        let note = store.addNote("flaky note")
        let id = try XCTUnwrap(note?.id)

        reachability.setOnline(true)
        await waitUntil { store.notes.first?.status == .failed }

        XCTAssertEqual(store.notes.first?.status, .failed)
        XCTAssertEqual(store.notes.first?.attemptCount, 1)
        XCTAssertNotNil(store.notes.first?.lastError)
        XCTAssertEqual(store.failedCount, 1)

        // Recover and retry.
        dispatcher.shouldFail = false
        store.retry(id: id)
        await waitUntil { store.notes.first?.status == .sent }

        XCTAssertEqual(store.notes.first?.status, .sent)
        XCTAssertEqual(store.notes.first?.attemptCount, 2)
        XCTAssertEqual(dispatcher.dispatched.count, 2)
    }

    // MARK: - Reentrancy

    func testConcurrentFlushesDispatchEachNoteOnce() async throws {
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
        XCTAssertEqual(dispatcher.dispatched.count, 2)
    }

    // MARK: - Housekeeping

    func testClearSentRemovesOnlySentNotes() async throws {
        let dispatcher = FakeDispatcher()
        let reachability = FakeReachability(isOnline: false)
        let store = makeStore(fileURL: nil, dispatcher: dispatcher, reachability: reachability)
        store.addNote("will send")
        reachability.setOnline(true)
        await waitUntil { store.sentCount == 1 }

        reachability.setOnline(false)
        store.addNote("still pending")

        store.clearSent()
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.notes.first?.text, "still pending")
        XCTAssertEqual(store.notes.first?.status, .pending)
    }
}
