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
private func makeMemoryPressureHiddenWebViewDiscardBlockerSnapshot(
    hasActiveMainFrameProvisionalNavigation: Bool = false,
    isVisibleInUI: Bool = false,
    preferredDeveloperToolsVisible: Bool = false,
    isDeveloperToolsVisible: Bool = false,
    isCapturingMedia: Bool = false,
    hasAudibleMedia: Bool = false
) -> BrowserHiddenWebViewDiscardManager.BlockerSnapshot {
    BrowserHiddenWebViewDiscardManager.BlockerSnapshot(
        isClosing: false,
        isVisibleInUI: isVisibleInUI,
        shouldRenderWebView: true,
        hasPendingRemoteNavigation: false,
        hasCurrentURL: true,
        isLoading: false,
        webViewIsLoading: false,
        hasActiveMainFrameProvisionalNavigation: hasActiveMainFrameProvisionalNavigation,
        isDownloading: false,
        activeDownloadCount: 0,
        preferredDeveloperToolsVisible: preferredDeveloperToolsVisible,
        isDeveloperToolsVisible: isDeveloperToolsVisible,
        isElementFullscreenActive: false,
        isReactGrabActive: false,
        isVisualAutomationCaptureActive: false,
        hasPopups: false,
        isCapturingMedia: isCapturingMedia,
        hasAudibleMedia: hasAudibleMedia
    )
}

@MainActor
private func withMemoryPressureHiddenWebViewDiscardPolicyEnabled(_ body: (UserDefaults) -> Void) {
    let suiteName = "com.cmux.BrowserHiddenWebViewDiscardMemoryPressureTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(true, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
    defaults.set(
        BrowserHiddenWebViewDiscardPolicy.defaultHiddenDelay,
        forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey
    )
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    body(defaults)
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

    @Test func blockedHiddenPaneRechecksAndDiscardsAfterBlockerClears() {
        withMemoryPressureHiddenWebViewDiscardPolicyEnabled { defaults in
            let now = Date(timeIntervalSince1970: 3_000)
            let blockedSnapshot = makeMemoryPressureHiddenWebViewDiscardBlockerSnapshot(
                hasActiveMainFrameProvisionalNavigation: true
            )
            let clearSnapshot = makeMemoryPressureHiddenWebViewDiscardBlockerSnapshot()
            let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
            let delegate = MemoryPressureHiddenWebViewDiscardTestDelegate(
                snapshot: blockedSnapshot,
                hiddenAt: now.addingTimeInterval(-7_200)
            )
            manager.delegate = delegate

            manager.scheduleIfNeeded(reason: "test.blocked", now: now)

            #expect(!manager.hasScheduledDiscard)
            #expect(manager.hasScheduledBlockedRecheck)
            #expect(delegate.discardRequestCount == 0)

            delegate.snapshot = clearSnapshot
            #expect(manager.performBlockedRecheckNow(now: now.addingTimeInterval(60)))

            #expect(!manager.hasScheduledBlockedRecheck)
            #expect(delegate.discardRequestCount == 1)
            #expect(delegate.lastDiscardReason == "blocked_recheck")
        }
    }

    @Test func terminalBlockersDoNotArmBlockedRecheck() {
        withMemoryPressureHiddenWebViewDiscardPolicyEnabled { defaults in
            let now = Date(timeIntervalSince1970: 3_500)
            let visibleManager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
            let visibleDelegate = MemoryPressureHiddenWebViewDiscardTestDelegate(
                snapshot: makeMemoryPressureHiddenWebViewDiscardBlockerSnapshot(isVisibleInUI: true),
                hiddenAt: now.addingTimeInterval(-7_200)
            )
            visibleManager.delegate = visibleDelegate

            visibleManager.scheduleIfNeeded(reason: "test.visible", now: now)

            #expect(!visibleManager.hasScheduledDiscard)
            #expect(!visibleManager.hasScheduledBlockedRecheck)

            let discardedManager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
            let discardedDelegate = MemoryPressureHiddenWebViewDiscardTestDelegate(
                snapshot: makeMemoryPressureHiddenWebViewDiscardBlockerSnapshot(),
                hiddenAt: now.addingTimeInterval(-7_200)
            )
            discardedManager.delegate = discardedDelegate
            discardedManager.markDiscarded(reason: "test.discarded", now: now)

            discardedManager.scheduleIfNeeded(reason: "test.discarded", now: now)

            #expect(!discardedManager.hasScheduledDiscard)
            #expect(!discardedManager.hasScheduledBlockedRecheck)
        }
    }

    @Test func blockedRecheckDelayIsNeverLessThanSixtySeconds() {
        let policy = BrowserHiddenWebViewDiscardPolicy.ResolvedPolicy(
            isEnabled: true,
            hiddenDelay: 0
        )

        #expect(BrowserHiddenWebViewDiscardManager.blockedRecheckDelay(for: policy) == 60)
    }

    @Test func developerToolsLiveProbeBlocksHiddenWebViewDiscard() {
        withMemoryPressureHiddenWebViewDiscardPolicyEnabled { defaults in
            let snapshot = makeMemoryPressureHiddenWebViewDiscardBlockerSnapshot(
                preferredDeveloperToolsVisible: false,
                isDeveloperToolsVisible: true
            )
            let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)

            #expect(manager.blockers(for: snapshot) == ["developer_tools"])
        }
    }

    @Test func developerToolsPreferenceOnlyDoesNotBlockHiddenWebViewDiscard() {
        withMemoryPressureHiddenWebViewDiscardPolicyEnabled { defaults in
            let snapshot = makeMemoryPressureHiddenWebViewDiscardBlockerSnapshot(
                preferredDeveloperToolsVisible: true,
                isDeveloperToolsVisible: false
            )
            let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)

            #expect(manager.blockers(for: snapshot) == [])
        }
    }
}
