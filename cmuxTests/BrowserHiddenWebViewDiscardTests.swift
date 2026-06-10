import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Darwin
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


@MainActor
private final class BrowserHiddenWebViewDiscardTestDelegate: BrowserHiddenWebViewDiscardManagerDelegate {
    var snapshot: BrowserHiddenWebViewDiscardManager.BlockerSnapshot
    var hiddenAt: Date?
    var webViewInstanceID = UUID()
    var discardRequestCount = 0

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
    }

    func hiddenWebViewDiscardManagerPolicyDidChange(
        _ manager: BrowserHiddenWebViewDiscardManager,
        reason: String
    ) {}
}

@MainActor
private func makeHiddenWebViewDiscardBlockerSnapshot(
    hasActiveMainFrameProvisionalNavigation: Bool = false,
    isVisualAutomationCaptureActive: Bool = false,
    isCapturingMedia: Bool = false,
    isPlayingMedia: Bool = false
) -> BrowserHiddenWebViewDiscardManager.BlockerSnapshot {
    BrowserHiddenWebViewDiscardManager.BlockerSnapshot(
        isClosing: false,
        isVisibleInUI: false,
        shouldRenderWebView: true,
        hasPendingRemoteNavigation: false,
        hasCurrentURL: true,
        isLoading: false,
        webViewIsLoading: false,
        hasActiveMainFrameProvisionalNavigation: hasActiveMainFrameProvisionalNavigation,
        isDownloading: false,
        activeDownloadCount: 0,
        preferredDeveloperToolsVisible: false,
        isDeveloperToolsVisible: false,
        isElementFullscreenActive: false,
        isReactGrabActive: false,
        isVisualAutomationCaptureActive: isVisualAutomationCaptureActive,
        hasPopups: false,
        isCapturingMedia: isCapturingMedia,
        isPlayingMedia: isPlayingMedia
    )
}

@MainActor
private func withHiddenWebViewDiscardPolicyEnabled(_ body: () -> Void) {
    let defaults = UserDefaults.standard
    let previousEnabled = defaults.object(forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
    defaults.set(true, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
    defer {
        if let previousEnabled {
            defaults.set(previousEnabled, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
        } else {
            defaults.removeObject(forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
        }
    }
    body()
}

@MainActor
@Suite(.serialized)
struct BrowserHiddenWebViewDiscardMediaPlaybackTests {
    /// Regression coverage for https://github.com/manaflow-ai/cmux/issues/5409:
    /// a hidden pane that is actively playing media (e.g. a backgrounded YouTube
    /// video) must be exempted from memory discard so switching workspaces does
    /// not stop playback or reload the page. The media_capture blocker only
    /// covers camera/mic capture, not <video>/<audio> playback.
    @Test func activeMediaPlaybackBlocksHiddenWebViewDiscardScheduling() {
        withHiddenWebViewDiscardPolicyEnabled {
            let snapshot = makeHiddenWebViewDiscardBlockerSnapshot(isPlayingMedia: true)
            let manager = BrowserHiddenWebViewDiscardManager()
            let delegate = BrowserHiddenWebViewDiscardTestDelegate(snapshot: snapshot, hiddenAt: Date())
            manager.delegate = delegate

            #expect(manager.blockers(for: snapshot) == ["media_playback"])

            manager.scheduleIfNeeded(reason: "test.hidden")

            #expect(!manager.hasScheduledDiscard)
            #expect(delegate.discardRequestCount == 0)
        }
    }

    /// An idle hidden pane (no playing media) must still be eligible for discard
    /// so the memory bound from https://github.com/manaflow-ai/cmux/issues/4539
    /// is preserved.
    @Test func idlePaneWithoutMediaPlaybackStillSchedulesHiddenWebViewDiscard() {
        withHiddenWebViewDiscardPolicyEnabled {
            let snapshot = makeHiddenWebViewDiscardBlockerSnapshot(isPlayingMedia: false)
            let manager = BrowserHiddenWebViewDiscardManager()
            let delegate = BrowserHiddenWebViewDiscardTestDelegate(snapshot: snapshot, hiddenAt: Date())
            manager.delegate = delegate

            #expect(manager.blockers(for: snapshot) == [])

            manager.scheduleIfNeeded(reason: "test.hidden")

            #expect(manager.hasScheduledDiscard)
            #expect(delegate.discardRequestCount == 0)
        }
    }
}

@MainActor
final class BrowserHiddenWebViewDiscardManagerTests: XCTestCase {
    private var previousEnabled: Any?

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        previousEnabled = defaults.object(forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
        defaults.set(true, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        if let previousEnabled {
            defaults.set(previousEnabled, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
        } else {
            defaults.removeObject(forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
        }
        super.tearDown()
    }

    func testActiveMediaCaptureBlocksHiddenWebViewDiscardScheduling() {
        let snapshot = makeHiddenWebViewDiscardBlockerSnapshot(isCapturingMedia: true)
        let manager = BrowserHiddenWebViewDiscardManager()
        let delegate = BrowserHiddenWebViewDiscardTestDelegate(snapshot: snapshot, hiddenAt: Date())
        manager.delegate = delegate

        XCTAssertEqual(manager.blockers(for: snapshot), ["media_capture"])

        manager.scheduleIfNeeded(reason: "test.hidden")

        XCTAssertFalse(manager.hasScheduledDiscard)
        XCTAssertEqual(delegate.discardRequestCount, 0)
    }

    func testVisualAutomationCaptureBlocksHiddenWebViewDiscardScheduling() {
        let snapshot = makeHiddenWebViewDiscardBlockerSnapshot(isVisualAutomationCaptureActive: true)

        let manager = BrowserHiddenWebViewDiscardManager()
        let delegate = BrowserHiddenWebViewDiscardTestDelegate(snapshot: snapshot, hiddenAt: Date())
        manager.delegate = delegate

        XCTAssertEqual(manager.blockers(for: snapshot), ["visual_automation"])

        manager.scheduleIfNeeded(reason: "test.visualAutomation")

        XCTAssertFalse(manager.hasScheduledDiscard)
        XCTAssertEqual(delegate.discardRequestCount, 0)
    }

    // Regression coverage for https://github.com/manaflow-ai/cmux/issues/5261:
    // a main-frame provisional navigation (e.g. a cross-origin process swap in
    // flight) must block a hidden-webview discard from replacing the WKWebView.
    func testMainFrameProvisionalNavigationBlocksHiddenWebViewDiscardScheduling() {
        let snapshot = makeHiddenWebViewDiscardBlockerSnapshot(
            hasActiveMainFrameProvisionalNavigation: true
        )
        let manager = BrowserHiddenWebViewDiscardManager()
        let delegate = BrowserHiddenWebViewDiscardTestDelegate(snapshot: snapshot, hiddenAt: Date())
        manager.delegate = delegate

        XCTAssertEqual(manager.blockers(for: snapshot), ["provisional_navigation"])

        manager.scheduleIfNeeded(reason: "test.provisional")

        XCTAssertFalse(manager.hasScheduledDiscard)
        XCTAssertEqual(delegate.discardRequestCount, 0)
    }

    // Regression coverage for https://github.com/manaflow-ai/cmux/issues/5261:
    // a discard countdown that elapsed across system sleep must restart from
    // wake instead of discarding the webview immediately after wake, while
    // WebKit pages are still reconnecting/renavigating.
    func testSystemWakeRestartsHiddenWebViewDiscardCountdown() {
        let snapshot = makeHiddenWebViewDiscardBlockerSnapshot()
        let manager = BrowserHiddenWebViewDiscardManager()
        let delegate = BrowserHiddenWebViewDiscardTestDelegate(
            snapshot: snapshot,
            hiddenAt: Date(timeIntervalSinceNow: -7200)
        )
        manager.delegate = delegate

        manager.noteSystemDidWake(now: Date())
        manager.scheduleIfNeeded(reason: "test.postWake")

        XCTAssertEqual(delegate.discardRequestCount, 0)
        XCTAssertTrue(manager.hasScheduledDiscard)
    }

    // Regression coverage for https://github.com/manaflow-ai/cmux/issues/5261:
    // sleep cancels an armed discard countdown and blocks re-arming until wake,
    // and wake re-arms a fresh countdown without discarding.
    func testSystemSleepCancelsArmedHiddenWebViewDiscard() {
        let snapshot = makeHiddenWebViewDiscardBlockerSnapshot()
        let manager = BrowserHiddenWebViewDiscardManager()
        let delegate = BrowserHiddenWebViewDiscardTestDelegate(snapshot: snapshot, hiddenAt: Date())
        manager.delegate = delegate

        manager.scheduleIfNeeded(reason: "test.hidden")
        XCTAssertTrue(manager.hasScheduledDiscard)

        manager.noteSystemWillSleep()
        XCTAssertFalse(manager.hasScheduledDiscard)
        XCTAssertEqual(manager.blockers(for: snapshot), ["system_sleeping"])

        manager.scheduleIfNeeded(reason: "test.whileSleeping")
        XCTAssertFalse(manager.hasScheduledDiscard)
        XCTAssertEqual(delegate.discardRequestCount, 0)

        manager.noteSystemDidWake(now: Date())
        XCTAssertTrue(manager.hasScheduledDiscard)
        XCTAssertEqual(manager.blockers(for: snapshot), [])
        XCTAssertEqual(delegate.discardRequestCount, 0)
    }
}

