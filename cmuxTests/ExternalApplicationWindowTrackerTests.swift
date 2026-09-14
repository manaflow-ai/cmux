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
            primaryScreenMaxY: { 1_200 },
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

    private final class ValueBox<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot: Value

        init(_ snapshot: Value) {
            self.snapshot = snapshot
        }

        func load() -> Value {
            lock.lock()
            defer { lock.unlock() }
            return snapshot
        }

        func store(_ snapshot: Value) {
            lock.lock()
            self.snapshot = snapshot
            lock.unlock()
        }
    }

    @Test @MainActor func offscreenTargetResumesWithoutLosingItsWindowIdentity() {
        let initial = ExternalApplicationWindowSnapshot(
            windowID: 17, ownerProcessIdentifier: 42,
            frame: CGRect(x: 80, y: 120, width: 900, height: 700)
        )
        let front = ValueBox(initial)
        let current = ValueBox(initial)
        let tracker = ExternalApplicationWindowTracker(
            bundleIdentifier: "com.example.Target",
            dependencies: .init(
                frontWindow: { _, _ in front.load() },
                window: { id, _, _ in id == initial.windowID ? current.load() : nil }
            ),
            automaticUpdatesEnabled: false
        )
        var events: [ExternalApplicationWindowEvent] = []
        tracker.start { events.append($0) }
        defer { tracker.stop() }
        tracker.handleApplicationActivation(bundleIdentifier: "com.example.Target", processIdentifier: 42)
        tracker.handleApplicationActivation(bundleIdentifier: "com.example.Other", processIdentifier: 91)
        front.store(.init(windowID: 99, ownerProcessIdentifier: 42, frame: initial.frame))
        current.store(.init(
            windowID: 17, ownerProcessIdentifier: 42, frame: initial.frame, isOnScreen: false
        ))
        for _ in 0..<20 { tracker.refreshTrackedWindow() }
        #expect(events.last == .offscreen)
        #expect(!events.contains(.unavailable))

        current.store(initial)
        tracker.handleApplicationActivation(bundleIdentifier: "com.example.Target", processIdentifier: 42)
        #expect(events.last == .visible(initial))
    }

    @Test @MainActor func terminationOnlyAppliesToTheTrackedProcess() {
        let snapshot = ExternalApplicationWindowSnapshot(
            windowID: 17, ownerProcessIdentifier: 42, frame: .zero
        )
        let tracker = ExternalApplicationWindowTracker(
            bundleIdentifier: "com.example.Target",
            dependencies: .init(frontWindow: { _, _ in snapshot }, window: { _, _, _ in snapshot }),
            automaticUpdatesEnabled: false
        )
        var last: ExternalApplicationWindowEvent?
        tracker.start { last = $0 }
        defer { tracker.stop() }
        tracker.handleApplicationActivation(bundleIdentifier: "com.example.Target", processIdentifier: 42)
        tracker.handleApplicationTermination(processIdentifier: 91)
        #expect(last == .visible(snapshot))
        tracker.handleApplicationTermination(processIdentifier: 42)
        #expect(last == .unavailable)
    }

    @Test @MainActor func laterSamplesUseTheCurrentDisplayCoordinateOrigin() {
        let height = ValueBox<CGFloat>(1_200)
        let read: @Sendable (pid_t, CGFloat) -> ExternalApplicationWindowSnapshot? = { pid, maxY in
            .init(windowID: 17, ownerProcessIdentifier: pid,
                  frame: CGRect(x: 0, y: maxY - 200, width: 100, height: 100))
        }
        let tracker = ExternalApplicationWindowTracker(
            bundleIdentifier: "com.example.Target",
            primaryScreenMaxY: { height.load() },
            dependencies: .init(frontWindow: read, window: { _, pid, maxY in read(pid, maxY) }),
            automaticUpdatesEnabled: false
        )
        var latest: ExternalApplicationWindowSnapshot?
        tracker.start { if case .visible(let snapshot) = $0 { latest = snapshot } }
        defer { tracker.stop() }
        tracker.handleApplicationActivation(bundleIdentifier: "com.example.Target", processIdentifier: 42)
        #expect(latest?.frame.minY == 1_000)
        height.store(900)
        tracker.refreshTrackedWindow()
        #expect(latest?.frame.minY == 700)
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
        let snapshotBox = ValueBox(expectedSnapshot)
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
            primaryScreenMaxY: { 1_200 },
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
