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
    _ body: (UserDefaults) -> Void
) {
    let suiteName = "com.cmux.BrowserHiddenWebViewDiscardMemoryPressureTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(true, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
    defaults.set(hiddenDelay, forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey)
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

    @Test func delayedDiscardRechecksActiveWorkspaceBlockerBeforeDiscarding() {
        withMemoryPressureHiddenWebViewDiscardPolicyEnabled(hiddenDelay: 0.05) { defaults in
            let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
            let delegate = MemoryPressureHiddenWebViewDiscardTestDelegate(
                snapshot: makeMemoryPressureHiddenWebViewDiscardBlockerSnapshot(),
                hiddenAt: Date()
            )
            manager.delegate = delegate

            manager.scheduleIfNeeded(reason: "test.delayed")
            #expect(manager.hasScheduledDiscard)

            delegate.snapshot = makeMemoryPressureHiddenWebViewDiscardBlockerSnapshot(isActiveInWorkspace: true)
            let blockedDeadline = Date().addingTimeInterval(1)
            while manager.hasScheduledDiscard, Date() < blockedDeadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            #expect(!manager.hasScheduledDiscard)
            #expect(delegate.discardRequestCount == 0)

            delegate.snapshot = makeMemoryPressureHiddenWebViewDiscardBlockerSnapshot()
            delegate.hiddenAt = Date()
            manager.scheduleIfNeeded(reason: "test.delayed.unblocked")
            let discardDeadline = Date().addingTimeInterval(1)
            while delegate.discardRequestCount == 0, Date() < discardDeadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            #expect(delegate.discardRequestCount == 1)
            #expect(delegate.lastDiscardReason == "test.delayed.unblocked")
        }
    }
}
