import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("External application window lifecycle")
struct ExternalApplicationWindowTrackerTests {
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
                window: { _, _, _ in nil },
                sleep: { _ in }
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
}
