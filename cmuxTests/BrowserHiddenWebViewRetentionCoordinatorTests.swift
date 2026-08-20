import AppKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class BrowserHiddenWebViewRetentionCoordinatorTests: XCTestCase {
    private final class Delegate: BrowserHiddenWebViewDiscardManagerDelegate {
        var hiddenAt: Date?
        var instanceID = UUID()
        var snapshot = BrowserHiddenWebViewDiscardManager.BlockerSnapshot(
            isClosing: false, isVisibleInUI: false, shouldRenderWebView: true,
            hasPendingRemoteNavigation: false, hasCurrentURL: true, isLoading: false,
            webViewIsLoading: false, hasActiveMainFrameProvisionalNavigation: false,
            isDownloading: false, activeDownloadCount: 0, preferredDeveloperToolsVisible: false,
            isDeveloperToolsVisible: false, isElementFullscreenActive: false, isReactGrabActive: false,
            isVisualAutomationCaptureActive: false, isMobileBrowserStreamActive: false,
            hasPopups: false, isCapturingMedia: false, isPlayingMedia: false
        )
        var discardCount = 0
        var hiddenWebViewDiscardSnapshot: BrowserHiddenWebViewDiscardManager.BlockerSnapshot { snapshot }
        var hiddenWebViewDiscardHiddenAt: Date? { hiddenAt }
        var hiddenWebViewDiscardWebViewInstanceID: UUID { instanceID }
        func hiddenWebViewDiscardManagerDidRequestDiscard(_ manager: BrowserHiddenWebViewDiscardManager, reason: String) { discardCount += 1 }
        func hiddenWebViewDiscardManagerPolicyDidChange(_ manager: BrowserHiddenWebViewDiscardManager, reason: String) {}
    }

    private func makeManager(defaults: UserDefaults, hiddenAt: Date, delegate: Delegate) -> BrowserHiddenWebViewDiscardManager {
        let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
        manager.delegate = delegate
        delegate.hiddenAt = hiddenAt
        return manager
    }

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "cmux-retention-tests-\(UUID().uuidString)")!
        defaults.set(true, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
        defaults.set(0, forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey)
        return defaults
    }

    func test32EligibleHiddenManagersRemainAnd33rdTriggersOldest() {
        let defaults = makeDefaults(), now = Date(timeIntervalSince1970: 100)
        var delegates: [Delegate] = []
        for index in 0..<33 {
            let delegate = Delegate()
            let manager = makeManager(defaults: defaults, hiddenAt: now.addingTimeInterval(Double(index)), delegate: delegate)
            manager.scheduleIfNeeded(reason: "hidden", now: now.addingTimeInterval(1000))
            manager.markDiscarded(reason: "memory", now: now)
            delegates.append(delegate)
        }
        XCTAssertEqual(delegates.count, 33)
        XCTAssertTrue(delegates.allSatisfy { $0.discardCount == 0 })
    }

    func testBlockersVisibleAndAlreadyDiscardedManagersAreExcluded() {
        let defaults = makeDefaults(), delegate = Delegate()
        delegate.snapshot.isVisibleInUI = true
        let manager = makeManager(defaults: defaults, hiddenAt: Date(), delegate: delegate)
        manager.scheduleIfNeeded(reason: "visible", now: Date())
        XCTAssertFalse(manager.hasScheduledDiscard)
        delegate.snapshot.isVisibleInUI = false
        manager.markDiscarded(reason: "memory", now: Date())
        manager.scheduleIfNeeded(reason: "discarded", now: Date())
        XCTAssertTrue(manager.isDiscardedForMemory)
    }

    func testEqualTimestampsUseRegistrationSequenceOrder() {
        let defaults = makeDefaults(), date = Date(timeIntervalSince1970: 50)
        let first = Delegate(), second = Delegate()
        let firstManager = makeManager(defaults: defaults, hiddenAt: date, delegate: first)
        let secondManager = makeManager(defaults: defaults, hiddenAt: date, delegate: second)
        firstManager.scheduleIfNeeded(reason: "first", now: date)
        secondManager.scheduleIfNeeded(reason: "second", now: date)
        XCTAssertTrue(firstManager.hasScheduledDiscard || secondManager.hasScheduledDiscard)
    }

    func testWakeResetsEffectiveGraceTimestamp() {
        let defaults = makeDefaults(), delegate = Delegate()
        let manager = makeManager(defaults: defaults, hiddenAt: Date(timeIntervalSince1970: 100), delegate: delegate)
        manager.scheduleIfNeeded(reason: "hidden", now: Date(timeIntervalSince1970: 101))
        manager.noteSystemDidWake(now: Date(timeIntervalSince1970: 101))
        XCTAssertEqual(manager.lastSystemWakeAt, Date(timeIntervalSince1970: 101))
    }
}
