@preconcurrency import XCTest
import CmuxSettings
import CmuxSocketControl
import AppKit
import Combine
import CoreText
import WebKit
import Darwin
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


@MainActor
final class BrowserPanelWebViewLifecycleTests: XCTestCase {
    func testHiddenDiscardPolicyReadsUserDefaults() throws {
        let suiteName = "cmux.browserHiddenDiscardPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let hasEnabledEnvironmentOverride =
            ProcessInfo.processInfo.environment["CMUX_BROWSER_HIDDEN_WEBVIEW_DISCARD_ENABLED"] != nil
        let hasDelayEnvironmentOverride =
            ProcessInfo.processInfo.environment["CMUX_BROWSER_HIDDEN_WEBVIEW_DISCARD_DELAY_SECONDS"] != nil

        if !hasEnabledEnvironmentOverride {
            XCTAssertEqual(
                BrowserHiddenWebViewDiscardPolicy.isEnabled(defaults: defaults),
                BrowserHiddenWebViewDiscardPolicy.defaultEnabled
            )
        }
        if !hasDelayEnvironmentOverride {
            XCTAssertEqual(
                BrowserHiddenWebViewDiscardPolicy.hiddenDelay(defaults: defaults),
                BrowserHiddenWebViewDiscardPolicy.defaultHiddenDelay
            )
        }

        defaults.set(false, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
        defaults.set(42.5, forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey)

        if !hasEnabledEnvironmentOverride {
            XCTAssertEqual(defaults.object(forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey) as? Bool, false)
            XCTAssertFalse(BrowserHiddenWebViewDiscardPolicy.isEnabled(defaults: defaults))
        }
        if !hasDelayEnvironmentOverride {
            XCTAssertEqual(BrowserHiddenWebViewDiscardPolicy.hiddenDelay(defaults: defaults), 42.5)

            defaults.set(7200, forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey)
            XCTAssertEqual(
                BrowserHiddenWebViewDiscardPolicy.hiddenDelay(defaults: defaults),
                BrowserHiddenWebViewDiscardPolicy.maximumHiddenDelay
            )

            defaults.set(-1, forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey)
            XCTAssertEqual(
                BrowserHiddenWebViewDiscardPolicy.hiddenDelay(defaults: defaults),
                BrowserHiddenWebViewDiscardPolicy.defaultHiddenDelay
            )
        }
    }

    func testLifecycleDistinguishesDeferredURLFromNewTab() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "https://example.test/")!,
            renderInitialNavigation: false,
            isRemoteWorkspace: false
        )
        defer { panel.close() }

        XCTAssertEqual(panel.webViewLifecycleState, .deferredURL)

        panel.noteWebViewVisibility(true, reason: "test.visible")

        XCTAssertEqual(panel.webViewLifecycleState, .deferredURL)
    }

    func testBackgroundInitialNavigationOwnsHeadlessWebKitHostBeforeViewAppears() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "about:blank")!,
            preloadInitialNavigationInBackground: true,
            isRemoteWorkspace: false
        )
        defer { panel.close() }

        XCTAssertTrue(panel.shouldRenderWebView)
        XCTAssertEqual(panel.webViewLifecycleState, .liveHidden)
        XCTAssertTrue(panel.hasBackgroundPreloadHost)
        XCTAssertNotNil(panel.webView.window)
        XCTAssertEqual(panel.webView.window?.isVisible, true)
        XCTAssertLessThan(panel.webView.window?.frame.minX ?? 0, -9_000)
    }

    func testBackgroundInitialNavigationDoesNotExposeHiddenHostAsModalParent() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "about:blank")!,
            preloadInitialNavigationInBackground: true,
            isRemoteWorkspace: false
        )
        defer { panel.close() }

        XCTAssertTrue(panel.hasBackgroundPreloadHost)
        XCTAssertNotNil(panel.webView.window)
        XCTAssertNil(browserInteractiveModalHostWindow(for: panel.webView))
    }

    func testBackgroundPreloadHostStaysOpenUntilWebViewHasRealWindow() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "about:blank")!,
            preloadInitialNavigationInBackground: true,
            isRemoteWorkspace: false
        )
        defer { panel.close() }

        XCTAssertTrue(panel.hasBackgroundPreloadHost)
        panel.webView.removeFromSuperview()

        XCTAssertNil(panel.webView.window)

        panel.releaseBackgroundPreloadHostIfAttachedToRealWindow(reason: "test.detached")

        XCTAssertTrue(panel.hasBackgroundPreloadHost)
    }

    func testBackgroundPreloadIsConsumedByInitialNavigation() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "about:blank")!,
            preloadInitialNavigationInBackground: true,
            isRemoteWorkspace: false
        )
        defer { panel.close() }

        XCTAssertTrue(panel.hasBackgroundPreloadHost)

        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let realHostWindow = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        defer {
            realHostWindow.contentView = nil
            realHostWindow.close()
        }
        let contentView = NSView(frame: frame)
        realHostWindow.contentView = contentView
        panel.webView.removeFromSuperview()
        contentView.addSubview(panel.webView)

        panel.releaseBackgroundPreloadHostIfAttachedToRealWindow(reason: "test.realWindow")

        XCTAssertFalse(panel.hasBackgroundPreloadHost)

        panel.webView.removeFromSuperview()
        realHostWindow.contentView = nil
        panel.navigate(to: URL(string: "about:blank#second")!)

        XCTAssertFalse(panel.hasBackgroundPreloadHost)
    }

    func testLifecycleTracksVisibleHiddenAndClosingStates() {
        let hiddenAt = Date(timeIntervalSince1970: 100)
        let duplicateHiddenAt = hiddenAt.addingTimeInterval(10)
        let now = hiddenAt.addingTimeInterval(11.25)
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "https://example.test/")!,
            isRemoteWorkspace: false
        )

        XCTAssertEqual(panel.webViewLifecycleState, .liveHidden)

        panel.noteWebViewVisibility(true, reason: "test.visible", now: hiddenAt)
        XCTAssertEqual(panel.webViewLifecycleState, .liveVisible)

        panel.noteWebViewVisibility(false, reason: "test.hidden", now: hiddenAt)
        XCTAssertEqual(panel.webViewLifecycleState, .liveHidden)
        panel.noteWebViewVisibility(
            false,
            reason: "test.hidden.duplicate",
            now: duplicateHiddenAt,
            recordIfUnchanged: true
        )

        let payload = panel.webViewLifecycleTopPayload(now: now)
        XCTAssertEqual(payload["state"] as? String, "live_hidden")
        XCTAssertEqual(payload["visible_in_ui"] as? Bool, false)
        XCTAssertEqual(payload["should_render"] as? Bool, true)
        XCTAssertEqual(payload["last_visibility_change_reason"] as? String, "test.hidden")
        XCTAssertEqual(payload["hidden_duration_ms"] as? Int, 11250)

        panel.close()
        XCTAssertEqual(panel.webViewLifecycleState, .closing)
    }

    func testDiscardReplacesHiddenWebViewAndRestoresOnDemand() {
        let discardedAt = Date(timeIntervalSince1970: 200)
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "about:blank")!,
            isRemoteWorkspace: false
        )
        defer { panel.close() }

        let deadline = Date().addingTimeInterval(1.0)
        while panel.webView.isLoading,
              RunLoop.main.run(mode: .default, before: deadline),
              Date() < deadline {}
        XCTAssertFalse(panel.webView.isLoading, "Timed out waiting for about:blank to finish loading")

        panel.noteWebViewVisibility(false, reason: "test.hidden", now: discardedAt)
        let originalWebView = panel.webView

        XCTAssertTrue(panel.discardHiddenWebViewForMemory(reason: "test.discard", now: discardedAt))
        XCTAssertFalse(panel.webView === originalWebView)
        XCTAssertFalse(panel.shouldRenderWebView)
        XCTAssertEqual(panel.webViewLifecycleState, .discarded)

        let discardedPayload = panel.webViewLifecycleTopPayload(now: discardedAt)
        XCTAssertEqual(discardedPayload["state"] as? String, "discarded")
        XCTAssertEqual(discardedPayload["last_discard_reason"] as? String, "test.discard")
        XCTAssertNotNil(discardedPayload["discarded_at"] as? String)

        var observedStates: [BrowserWebViewLifecycleState] = []
        var cancellable: AnyCancellable?
        cancellable = panel.$webViewLifecycleState.sink { state in
            observedStates.append(state)
        }
        defer { cancellable?.cancel() }

        XCTAssertTrue(panel.restoreDiscardedWebViewIfNeeded(reason: "test.restore"))
        XCTAssertTrue(panel.shouldRenderWebView)
        XCTAssertEqual(panel.webViewLifecycleState, .liveHidden)
        XCTAssertFalse(observedStates.contains(.newTab), "Restore emitted unexpected states: \(observedStates)")

        panel.noteWebViewVisibility(true, reason: "test.visible")
        XCTAssertEqual(panel.webViewLifecycleState, .liveVisible)
    }

    /// Regression guard for the issue #5303 render loop: `BrowserPanelView.onAppear`
    /// re-fired on every CoreAnimation commit and re-asserted webview visibility,
    /// which restored + re-navigated the webview repeatedly. Once the webview is live
    /// and visible, redundant visibility notifications (the shape a spurious appear
    /// produces) must be no-ops: no lifecycle churn and no webview replacement, so no
    /// re-navigation is issued.
    func testRedundantVisibleNotificationsDoNotChurnLiveWebView() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "about:blank")!,
            isRemoteWorkspace: false
        )
        defer { panel.close() }

        let deadline = Date().addingTimeInterval(1.0)
        while panel.webView.isLoading,
              RunLoop.main.run(mode: .default, before: deadline),
              Date() < deadline {}
        XCTAssertFalse(panel.webView.isLoading, "Timed out waiting for about:blank to finish loading")

        panel.noteWebViewVisibility(true, reason: "test.visible.first")
        XCTAssertEqual(panel.webViewLifecycleState, .liveVisible)

        let webViewAfterFirst = panel.webView
        let instanceIDAfterFirst = panel.webViewInstanceID
        let reasonAfterFirst = panel.webViewLastVisibilityChangeReason
        let changeAtAfterFirst = panel.webViewLastVisibilityChangeAt

        var observedStates: [BrowserWebViewLifecycleState] = []
        var cancellable: AnyCancellable?
        cancellable = panel.$webViewLifecycleState.dropFirst().sink { state in
            observedStates.append(state)
        }
        defer { cancellable?.cancel() }

        // Simulate `.onAppear` re-firing many times in one commit storm.
        for index in 0..<32 {
            panel.noteWebViewVisibility(true, reason: "test.visible.spurious-\(index)")
        }

        XCTAssertEqual(panel.webViewLifecycleState, .liveVisible)
        XCTAssertTrue(observedStates.isEmpty, "Redundant visible notes churned lifecycle: \(observedStates)")
        XCTAssertTrue(panel.webView === webViewAfterFirst, "A live webview must not be replaced by redundant visibility notes")
        XCTAssertEqual(panel.webViewInstanceID, instanceIDAfterFirst)
        XCTAssertEqual(
            panel.webViewLastVisibilityChangeReason,
            reasonAfterFirst,
            "Redundant visible notes must early-return without recording a new transition"
        )
        XCTAssertEqual(panel.webViewLastVisibilityChangeAt, changeAtAfterFirst)
    }

    func testRestoredHistoryBackDoesNotEmitNewTabLifecycleState() {
        let discardedAt = Date(timeIntervalSince1970: 300)
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "about:blank")!,
            isRemoteWorkspace: false
        )
        defer { panel.close() }

        let deadline = Date().addingTimeInterval(1.0)
        while panel.webView.isLoading,
              RunLoop.main.run(mode: .default, before: deadline),
              Date() < deadline {}
        XCTAssertFalse(panel.webView.isLoading, "Timed out waiting for about:blank to finish loading")

        panel.restoreSessionNavigationHistory(
            backHistoryURLStrings: ["https://example.test/back"],
            forwardHistoryURLStrings: [],
            currentURLString: "https://example.test/current"
        )
        XCTAssertTrue(panel.canGoBack)

        panel.noteWebViewVisibility(false, reason: "test.hidden", now: discardedAt)
        XCTAssertTrue(panel.discardHiddenWebViewForMemory(reason: "test.discard", now: discardedAt))
        XCTAssertEqual(panel.webViewLifecycleState, .discarded)

        var observedStates: [BrowserWebViewLifecycleState] = []
        var cancellable: AnyCancellable?
        cancellable = panel.$webViewLifecycleState.sink { state in
            observedStates.append(state)
        }
        defer { cancellable?.cancel() }

        panel.goBack()

        XCTAssertFalse(observedStates.contains(.newTab), "Back restore emitted unexpected states: \(observedStates)")
        XCTAssertEqual(panel.webViewLifecycleState, .liveHidden)
    }
}

