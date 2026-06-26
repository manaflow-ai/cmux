import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private final class MemoryPressureHiddenWebViewDiscardTestDelegate: BrowserHiddenWebViewDiscardManagerDelegate {
    var snapshot: BrowserHiddenWebViewDiscardManager.BlockerSnapshot
    var hiddenAt: Date?
    var webViewInstanceID = UUID()
    var discardRequestCount = 0
    var lastDiscardReason: String?

    init(snapshot: BrowserHiddenWebViewDiscardManager.BlockerSnapshot, hiddenAt: Date?) {
        self.snapshot = snapshot
        self.hiddenAt = hiddenAt
    }

    var hiddenWebViewDiscardSnapshot: BrowserHiddenWebViewDiscardManager.BlockerSnapshot {
        snapshot
    }

    var hiddenWebViewDiscardHiddenAt: Date? {
        hiddenAt
    }

    var hiddenWebViewDiscardWebViewInstanceID: UUID {
        webViewInstanceID
    }

    func hiddenWebViewDiscardManagerDidRequestDiscard(
        _ manager: BrowserHiddenWebViewDiscardManager,
        reason: String
    ) {
        discardRequestCount += 1
        lastDiscardReason = reason
    }

    func hiddenWebViewDiscardManagerPolicyDidChange(
        _ manager: BrowserHiddenWebViewDiscardManager,
        reason: String
    ) {}
}

@MainActor
private final class ManualHiddenWebViewDiscardScheduler {
    private var scheduled: [(id: UUID, delay: TimeInterval, handler: @MainActor () -> Void)] = []

    var scheduledCount: Int {
        scheduled.count
    }

    var scheduledDelays: [TimeInterval] {
        scheduled.map { $0.delay }
    }

    func schedule(
        after delay: TimeInterval,
        handler: @escaping @MainActor () -> Void
    ) -> BrowserHiddenWebViewDiscardManager.ScheduledDiscardCancel {
        let id = UUID()
        scheduled.append((id: id, delay: delay, handler: handler))
        return { [weak self] in
            self?.scheduled.removeAll { $0.id == id }
        }
    }

    func fireNext() throws {
        let next = try #require(scheduled.first)
        scheduled.removeFirst()
        next.handler()
    }
}

@MainActor
private func makeMemoryPressureHiddenWebViewDiscardBlockerSnapshot(
    isActiveInWorkspace: Bool = false
) -> BrowserHiddenWebViewDiscardManager.BlockerSnapshot {
    BrowserHiddenWebViewDiscardManager.BlockerSnapshot(
        isClosing: false,
        isActiveInWorkspace: isActiveInWorkspace,
        isVisibleInUI: false,
        shouldRenderWebView: true,
        hasPendingRemoteNavigation: false,
        hasCurrentURL: true,
        isLoading: false,
        webViewIsLoading: false,
        hasActiveMainFrameProvisionalNavigation: false,
        isDownloading: false,
        activeDownloadCount: 0,
        preferredDeveloperToolsVisible: false,
        isDeveloperToolsVisible: false,
        isElementFullscreenActive: false,
        isReactGrabActive: false,
        isVisualAutomationCaptureActive: false,
        hasPopups: false,
        isCapturingMedia: false,
        isPlayingMedia: false
    )
}

@MainActor
private func withMemoryPressureHiddenWebViewDiscardPolicyEnabled(
    hiddenDelay: TimeInterval = BrowserHiddenWebViewDiscardPolicy.defaultHiddenDelay,
    _ body: (UserDefaults) throws -> Void
) rethrows {
    let suiteName = "com.cmux.BrowserHiddenWebViewDiscardMemoryPressureTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(true, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
    defaults.set(hiddenDelay, forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    try body(defaults)
}

@MainActor
@Suite(.serialized)
struct BrowserHiddenWebViewDiscardMemoryPressureTests {
    @Test func systemMemoryPressureRequestsImmediateHiddenWebViewDiscard() {
        withMemoryPressureHiddenWebViewDiscardPolicyEnabled { defaults in
            let now = Date(timeIntervalSince1970: 1_000)
            let snapshot = makeMemoryPressureHiddenWebViewDiscardBlockerSnapshot()
            let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
            let delegate = MemoryPressureHiddenWebViewDiscardTestDelegate(
                snapshot: snapshot,
                hiddenAt: now.addingTimeInterval(-10)
            )
            manager.delegate = delegate

            #expect(manager.requestImmediateDiscardIfSafe(reason: "system_memory_pressure", now: now))

            #expect(!manager.hasScheduledDiscard)
            #expect(delegate.discardRequestCount == 1)
            #expect(delegate.lastDiscardReason == "system_memory_pressure")
        }
    }

    @Test func systemMemoryPressureDoesNotDiscardBeforeHiddenStateIsRecorded() {
        withMemoryPressureHiddenWebViewDiscardPolicyEnabled { defaults in
            let now = Date(timeIntervalSince1970: 1_500)
            let snapshot = makeMemoryPressureHiddenWebViewDiscardBlockerSnapshot()
            let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
            let delegate = MemoryPressureHiddenWebViewDiscardTestDelegate(
                snapshot: snapshot,
                hiddenAt: nil
            )
            manager.delegate = delegate

            #expect(!manager.requestImmediateDiscardIfSafe(reason: "system_memory_pressure", now: now))

            #expect(manager.hasScheduledDiscard)
            #expect(delegate.discardRequestCount == 0)
            #expect(delegate.lastDiscardReason == nil)
        }
    }

    @Test func systemMemoryPressureDefersImmediateDiscardDuringPostWakeWindow() {
        withMemoryPressureHiddenWebViewDiscardPolicyEnabled { defaults in
            let wakeAt = Date(timeIntervalSince1970: 2_000)
            let pressureAt = wakeAt.addingTimeInterval(1)
            let snapshot = makeMemoryPressureHiddenWebViewDiscardBlockerSnapshot()
            let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
            let delegate = MemoryPressureHiddenWebViewDiscardTestDelegate(
                snapshot: snapshot,
                hiddenAt: wakeAt.addingTimeInterval(-7_200)
            )
            manager.delegate = delegate

            manager.noteSystemDidWake(now: wakeAt)
            #expect(!manager.requestImmediateDiscardIfSafe(reason: "system_memory_pressure", now: pressureAt))

            #expect(manager.hasScheduledDiscard)
            #expect(delegate.discardRequestCount == 0)
            #expect(delegate.lastDiscardReason == nil)
        }
    }

    @Test func delayedDiscardRechecksActiveWorkspaceBlockerBeforeDiscarding() throws {
        try withMemoryPressureHiddenWebViewDiscardPolicyEnabled { defaults in
            let scheduler = ManualHiddenWebViewDiscardScheduler()
            let manager = BrowserHiddenWebViewDiscardManager(
                policyDefaults: defaults,
                scheduleDiscardTimer: { delay, handler in
                    scheduler.schedule(after: delay, handler: handler)
                }
            )
            let now = Date(timeIntervalSince1970: 3_000)
            let delegate = MemoryPressureHiddenWebViewDiscardTestDelegate(
                snapshot: makeMemoryPressureHiddenWebViewDiscardBlockerSnapshot(),
                hiddenAt: now
            )
            manager.delegate = delegate

            manager.scheduleIfNeeded(reason: "test.delayed", now: now)
            #expect(manager.hasScheduledDiscard)
            #expect(scheduler.scheduledCount == 1)
            #expect(scheduler.scheduledDelays == [BrowserHiddenWebViewDiscardPolicy.defaultHiddenDelay])

            delegate.snapshot = makeMemoryPressureHiddenWebViewDiscardBlockerSnapshot(isActiveInWorkspace: true)
            try scheduler.fireNext()
            #expect(!manager.hasScheduledDiscard)
            #expect(scheduler.scheduledCount == 0)
            #expect(delegate.discardRequestCount == 0)

            delegate.snapshot = makeMemoryPressureHiddenWebViewDiscardBlockerSnapshot()
            delegate.hiddenAt = now
            manager.scheduleIfNeeded(reason: "test.delayed.unblocked", now: now)
            #expect(manager.hasScheduledDiscard)
            #expect(scheduler.scheduledCount == 1)
            try scheduler.fireNext()
            #expect(delegate.discardRequestCount == 1)
            #expect(delegate.lastDiscardReason == "test.delayed.unblocked")
        }
    }
}
