import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("External application window lifecycle")
struct ExternalApplicationWindowTrackerTests {
    @MainActor
    private final class DeliveryState {
        var refreshCallIsActive = false
        var movedEventWasSynchronous = false
    }
    /// The companion remains visible after Command-Tab, so its window identity
    /// must survive that transition until the target actually disappears.
    @Test @MainActor func detectsClosedWindowAfterAnotherApplicationActivates() async {
        let initial = ExternalApplicationWindowTracker.Snapshot(
            windowID: 17,
            ownerProcessIdentifier: 42,
            frame: CGRect(x: 80, y: 120, width: 900, height: 700)
        )
        let tracker = ExternalApplicationWindowTracker(
            bundleIdentifier: "com.example.Target",
            primaryScreenMaxY: 1_200,
            dependencies: .init(
                frontWindow: { _, _ in initial },
                window: { _, _, _ in nil }
            ),
            missingSampleLimit: 2,
            automaticUpdatesEnabled: false
        )
        let (events, continuation) = AsyncStream<ExternalApplicationWindowTracker.Event>.makeStream()
        var lastEvent: ExternalApplicationWindowTracker.Event?
        tracker.start {
            lastEvent = $0
            continuation.yield($0)
        }
        defer {
            tracker.stop()
            continuation.finish()
        }
        tracker.handleApplicationActivation(
            bundleIdentifier: "com.example.Target",
            processIdentifier: 42
        )
        for await event in events {
            if event == .visible(initial) { break }
        }

        tracker.handleApplicationActivation(
            bundleIdentifier: "com.example.Other",
            processIdentifier: 91
        )
        tracker.refreshTrackedWindow()
        tracker.refreshTrackedWindow()

        #expect(lastEvent == .unavailable)
    }

    private final class WindowSnapshotBox: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot: ExternalApplicationWindowTracker.Snapshot

        init(_ snapshot: ExternalApplicationWindowTracker.Snapshot) {
            self.snapshot = snapshot
        }

        func load() -> ExternalApplicationWindowTracker.Snapshot {
            lock.lock()
            defer { lock.unlock() }
            return snapshot
        }

        func store(_ snapshot: ExternalApplicationWindowTracker.Snapshot) {
            lock.lock()
            self.snapshot = snapshot
            lock.unlock()
        }
    }

    @Test @MainActor func externalApplicationWindowTrackerPublishesOnlyForItsActiveTarget() async {
        let expectedSnapshot = ExternalApplicationWindowTracker.Snapshot(
            windowID: 17,
            ownerProcessIdentifier: 42,
            frame: NSRect(x: 80, y: 120, width: 900, height: 700)
        )
        let movedSnapshot = ExternalApplicationWindowTracker.Snapshot(
            windowID: 17,
            ownerProcessIdentifier: 42,
            frame: NSRect(x: 121, y: 168, width: 900, height: 700)
        )
        let snapshotBox = WindowSnapshotBox(expectedSnapshot)
        let dependencies = ExternalApplicationWindowTracker.Dependencies(
            frontWindow: { processIdentifier, _ in
                processIdentifier == 42 ? expectedSnapshot : nil
            },
            window: { _, processIdentifier, _ in
                processIdentifier == 42 ? snapshotBox.load() : nil
            }
        )
        let tracker = ExternalApplicationWindowTracker(
            bundleIdentifier: "com.example.Target",
            primaryScreenMaxY: 1_200,
            dependencies: dependencies,
            automaticUpdatesEnabled: false
        )
        var events: [ExternalApplicationWindowTracker.Event] = []
        let delivery = DeliveryState()
        tracker.start { event in
            events.append(event)
            if event == .visible(movedSnapshot) {
                delivery.movedEventWasSynchronous = delivery.refreshCallIsActive
            }
        }
        defer { tracker.stop() }

        tracker.handleApplicationActivation(
            bundleIdentifier: "com.example.Target",
            processIdentifier: 42
        )
        var receivedSnapshot: ExternalApplicationWindowTracker.Snapshot?
        let acquisitionDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while ContinuousClock.now < acquisitionDeadline {
            if let event = events.last(where: {
                if case .visible = $0 { return true }
                return false
            }), case .visible(let snapshot) = event {
                receivedSnapshot = snapshot
                break
            }
            await Task.yield()
        }
        #expect(receivedSnapshot == expectedSnapshot)

        snapshotBox.store(movedSnapshot)
        delivery.refreshCallIsActive = true
        tracker.refreshTrackedWindow()
        delivery.refreshCallIsActive = false
        #expect(events.last == .visible(movedSnapshot))
        #expect(delivery.movedEventWasSynchronous)

        let eventCountBeforeUnchangedRefresh = events.count
        tracker.refreshTrackedWindow()
        #expect(events.count == eventCountBeforeUnchangedRefresh)

        tracker.handleApplicationActivation(
            bundleIdentifier: "com.example.Other",
            processIdentifier: 91
        )
        #expect(events.last == .hidden)
    }

}
