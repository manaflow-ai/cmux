import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private func withBrowserDiscardRestoreRetryPolicyEnabled(_ body: (UserDefaults) -> Void) {
    let suiteName = "com.cmux.BrowserDiscardedWebViewRestoreRetryTests.\(UUID().uuidString)"
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
private func makeDiscardRestoreRetryBlockerSnapshot() -> BrowserHiddenWebViewDiscardManager.BlockerSnapshot {
    BrowserHiddenWebViewDiscardManager.BlockerSnapshot(
        isClosing: false,
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
@discardableResult
private func waitForDiscardRestoreRetryWebViewToSettle(
    _ panel: BrowserPanel,
    timeout: TimeInterval = 5.0
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while panel.webView.isLoading || panel.isLoading,
          Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return !panel.webView.isLoading && !panel.isLoading
}

@MainActor
@Suite(.serialized)
struct BrowserDiscardedWebViewRestoreRetryTests {
    @Test func discardedManagerRetriesWhenRestoreNeverStartsOrCommits() {
        // RED(#7504): a restore closure that never starts navigation must not consume discard state.
        withBrowserDiscardRestoreRetryPolicyEnabled { defaults in
            let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
            manager.markDiscarded(reason: "test.discard", now: Date(timeIntervalSince1970: 100))

            var restoreCount = 0
            #expect(manager.restoreIfNeeded(reason: "test.restore1") {
                restoreCount += 1
            })

            #expect(manager.isDiscardedForMemory)
            #expect(restoreCount == 1)

            #expect(manager.restoreIfNeeded(reason: "test.restore2") {
                restoreCount += 1
            })
            #expect(restoreCount == 2)
        }
    }

    @Test func browserPanelRetriesDiscardedRestoreAfterConnectionRefused() throws {
        // RED(#7504): connection-refused restore must leave the pane retryable on the next restore touch.
        let url = try #require(URL(string: "http://127.0.0.1:1/cmux-issue-7504"))
        let discardedAt = Date(timeIntervalSince1970: 200)
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: url,
            isRemoteWorkspace: false
        )
        defer { panel.close() }

        #expect(waitForDiscardRestoreRetryWebViewToSettle(panel))

        panel.noteWebViewVisibility(false, reason: "test.hidden", now: discardedAt)
        let originalWebView = panel.webView

        #expect(panel.discardHiddenWebViewForMemory(reason: "test.discard", now: discardedAt))
        #expect(panel.webView !== originalWebView)

        #expect(panel.restoreDiscardedWebViewIfNeeded(reason: "test.restore1"))
        _ = waitForDiscardRestoreRetryWebViewToSettle(panel)

        #expect(panel.restoreDiscardedWebViewIfNeeded(reason: "test.restore2"))
    }
}
