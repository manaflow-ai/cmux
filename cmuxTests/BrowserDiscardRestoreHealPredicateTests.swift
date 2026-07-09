import AppKit
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Pure-predicate coverage for the discard-restore heal decision helpers in
/// BrowserDiscardRestoreHeal (blank-shell healing gates and restore-stall
/// detection). Broader panel-level restore-retry behavior lives in
/// BrowserDiscardedWebViewRestoreRetryTests.
@MainActor
struct BrowserDiscardRestoreHealPredicateTests {
    @Test func pureRestoreHealPredicatesCoverBlankShellAndStalledCases() throws {
        let intentURL = try #require(URL(string: "http://127.0.0.1:7777/app"))
        let aboutBlankURL = try #require(URL(string: "about:blank"))
        let mixedCaseAboutBlankURL = try #require(URL(string: "ABOUT:BLANK"))

        #expect(BrowserPanel.isAboutBlankURL(aboutBlankURL))
        #expect(BrowserPanel.isAboutBlankURL(mixedCaseAboutBlankURL))
        #expect(!BrowserPanel.isAboutBlankURL(intentURL))
        #expect(!BrowserPanel.isAboutBlankURL(nil))

        #expect(BrowserPanel.shouldHealBlankShell(
            shouldRenderWebView: true,
            isClosing: false,
            hasPendingRemoteNavigation: false,
            isWebViewLoading: false,
            isMainFrameProvisionalNavigationActive: false,
            hasCommittedDocument: false,
            isNavigationBlockedPendingConsent: false,
            hasRecoverableWebContentTermination: false,
            userStoppedLoad: false,
            isShowingErrorPage: false,
            intentURL: intentURL
        ))
        #expect(!BrowserPanel.shouldHealBlankShell(
            shouldRenderWebView: true,
            isClosing: false,
            hasPendingRemoteNavigation: false,
            isWebViewLoading: false,
            isMainFrameProvisionalNavigationActive: false,
            hasCommittedDocument: true,
            isNavigationBlockedPendingConsent: false,
            hasRecoverableWebContentTermination: false,
            userStoppedLoad: false,
            isShowingErrorPage: false,
            intentURL: intentURL
        ))
        #expect(!BrowserPanel.shouldHealBlankShell(
            shouldRenderWebView: true,
            isClosing: false,
            hasPendingRemoteNavigation: false,
            isWebViewLoading: false,
            isMainFrameProvisionalNavigationActive: false,
            hasCommittedDocument: false,
            isNavigationBlockedPendingConsent: false,
            hasRecoverableWebContentTermination: false,
            userStoppedLoad: false,
            isShowingErrorPage: false,
            intentURL: aboutBlankURL
        ))
        #expect(!BrowserPanel.shouldHealBlankShell(
            shouldRenderWebView: true,
            isClosing: false,
            hasPendingRemoteNavigation: true,
            isWebViewLoading: false,
            isMainFrameProvisionalNavigationActive: false,
            hasCommittedDocument: false,
            isNavigationBlockedPendingConsent: false,
            hasRecoverableWebContentTermination: false,
            userStoppedLoad: false,
            isShowingErrorPage: false,
            intentURL: intentURL
        ))
        #expect(!BrowserPanel.shouldHealBlankShell(
            shouldRenderWebView: true,
            isClosing: false,
            hasPendingRemoteNavigation: false,
            isWebViewLoading: false,
            isMainFrameProvisionalNavigationActive: false,
            hasCommittedDocument: false,
            isNavigationBlockedPendingConsent: false,
            hasRecoverableWebContentTermination: false,
            userStoppedLoad: false,
            isShowingErrorPage: false,
            intentURL: nil
        ))
        #expect(!BrowserPanel.shouldHealBlankShell(
            shouldRenderWebView: true,
            isClosing: false,
            hasPendingRemoteNavigation: false,
            isWebViewLoading: false,
            isMainFrameProvisionalNavigationActive: false,
            hasCommittedDocument: false,
            isNavigationBlockedPendingConsent: true,
            hasRecoverableWebContentTermination: false,
            userStoppedLoad: false,
            isShowingErrorPage: false,
            intentURL: intentURL
        ))
        // A crashed WebContent process must wait for the user's explicit
        // Reload; blank-shell healing never auto-navigates over that gate.
        #expect(!BrowserPanel.shouldHealBlankShell(
            shouldRenderWebView: true,
            isClosing: false,
            hasPendingRemoteNavigation: false,
            isWebViewLoading: false,
            isMainFrameProvisionalNavigationActive: false,
            hasCommittedDocument: false,
            isNavigationBlockedPendingConsent: false,
            hasRecoverableWebContentTermination: true,
            userStoppedLoad: false,
            isShowingErrorPage: false,
            intentURL: intentURL
        ))
        // A load the user explicitly stopped before first commit must stay
        // stopped; a reveal never heals over the Stop.
        #expect(!BrowserPanel.shouldHealBlankShell(
            shouldRenderWebView: true,
            isClosing: false,
            hasPendingRemoteNavigation: false,
            isWebViewLoading: false,
            isMainFrameProvisionalNavigationActive: false,
            hasCommittedDocument: false,
            isNavigationBlockedPendingConsent: false,
            hasRecoverableWebContentTermination: false,
            userStoppedLoad: true,
            isShowingErrorPage: false,
            intentURL: intentURL
        ))
        // The browser's own error page is content awaiting the user's Reload;
        // a reveal never heals over it into re-requesting the failed URL.
        #expect(!BrowserPanel.shouldHealBlankShell(
            shouldRenderWebView: true,
            isClosing: false,
            hasPendingRemoteNavigation: false,
            isWebViewLoading: false,
            isMainFrameProvisionalNavigationActive: false,
            hasCommittedDocument: false,
            isNavigationBlockedPendingConsent: false,
            hasRecoverableWebContentTermination: false,
            userStoppedLoad: false,
            isShowingErrorPage: true,
            intentURL: intentURL
        ))

        #expect(BrowserPanel.isQueuedRemoteRestoreInFlight(
            isDiscardedForMemory: true,
            hasPendingRemoteNavigation: true,
            forceRestartPendingRestore: false
        ))
        #expect(!BrowserPanel.isQueuedRemoteRestoreInFlight(
            isDiscardedForMemory: true,
            hasPendingRemoteNavigation: true,
            forceRestartPendingRestore: true
        ))
        #expect(!BrowserPanel.isQueuedRemoteRestoreInFlight(
            isDiscardedForMemory: false,
            hasPendingRemoteNavigation: true,
            forceRestartPendingRestore: false
        ))
        #expect(!BrowserPanel.isQueuedRemoteRestoreInFlight(
            isDiscardedForMemory: true,
            hasPendingRemoteNavigation: false,
            forceRestartPendingRestore: false
        ))

        #expect(BrowserPanel.isRestoreStalled(
            isRestoreNavigationPending: true,
            isWebViewLoading: false,
            isMainFrameProvisionalNavigationActive: false,
            hasPendingRemoteNavigation: false,
            hasCommittedDocument: false
        ))
        #expect(!BrowserPanel.isRestoreStalled(
            isRestoreNavigationPending: true,
            isWebViewLoading: true,
            isMainFrameProvisionalNavigationActive: false,
            hasPendingRemoteNavigation: false,
            hasCommittedDocument: false
        ))
        #expect(!BrowserPanel.isRestoreStalled(
            isRestoreNavigationPending: true,
            isWebViewLoading: false,
            isMainFrameProvisionalNavigationActive: false,
            hasPendingRemoteNavigation: true,
            hasCommittedDocument: false
        ))
        #expect(!BrowserPanel.isRestoreStalled(
            isRestoreNavigationPending: true,
            isWebViewLoading: false,
            isMainFrameProvisionalNavigationActive: false,
            hasPendingRemoteNavigation: false,
            hasCommittedDocument: true
        ))
    }

}

private final class BrowserDiscardRestorePolicyCancelAlert: NSAlert {
    var response: NSApplication.ModalResponse = .alertThirdButtonReturn

    override func runModal() -> NSApplication.ModalResponse {
        response
    }
}

private final class BrowserDiscardRestoreDeferredPolicyAlert: NSAlert {
    var completionHandler: ((NSApplication.ModalResponse) -> Void)?

    override func beginSheetModal(
        for sheetWindow: NSWindow,
        completionHandler handler: ((NSApplication.ModalResponse) -> Void)?
    ) {
        completionHandler = handler
    }

    override func runModal() -> NSApplication.ModalResponse {
        .alertThirdButtonReturn
    }
}

@MainActor
struct BrowserDiscardRestorePolicyCancelTests {
    @Test func stalledRestoreClearsTrackedNavigationBeforeReactivation() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: nil,
            renderInitialNavigation: false
        )
        defer { panel.close() }

        panel.hiddenWebViewDiscardManager.markDiscarded(
            reason: "test.discard",
            now: Date(timeIntervalSince1970: 100)
        )
        panel.hiddenWebViewDiscardManager.noteRestoreNavigationStarted(reason: "test.restore")
        panel.pendingDiscardRestoreNavigation = WKNavigation()

        #expect(panel.restoreDiscardedWebViewIfNeeded(reason: "test.reveal"))

        #expect(panel.pendingDiscardRestoreNavigation == nil)
        #expect(panel.webViewLifecycleTopPayload()["restore_pending"] as? Bool == false)
        #expect(panel.webViewLifecycleTopPayload()["state"] as? String != "discarded")
    }

    @Test func cancelledExternalAppPromptDoesNotReportTerminalRestore() throws {
        let url = try #require(URL(string: "cmux-issue-7504-external://open"))
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: nil,
            renderInitialNavigation: false
        )
        defer { panel.close() }

        var terminalCancellationCount = 0
        let result = browserHandleExternalNavigation(
            url,
            source: "test",
            webView: panel.webView,
            loadFallbackRequest: { _ in Issue.record("custom scheme should not use a browser fallback") },
            presentAlert: { _, _, completion, _ in completion(.alertSecondButtonReturn) },
            onTerminalExternalNavigation: { terminalCancellationCount += 1 }
        )

        #expect(result == .externalPrompt)
        #expect(terminalCancellationCount == 0)
    }

    @Test func staleRestoreCancelDoesNotClearCurrentAttemptedRequest() throws {
        let staleURL = try #require(URL(string: "https://example.com/cmux-issue-7504-stale"))
        let currentURL = try #require(URL(string: "https://example.com/cmux-issue-7504-current"))
        let staleNavigation = WKNavigation()
        let currentNavigation = WKNavigation()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: nil,
            renderInitialNavigation: false
        )
        defer { panel.close() }

        panel.restoreSessionSnapshot(SessionBrowserPanelSnapshot(
            urlString: staleURL.absoluteString,
            profileID: nil,
            shouldRenderWebView: true,
            pageZoom: 1.0,
            developerToolsVisible: false,
            backHistoryURLStrings: [],
            forwardHistoryURLStrings: []
        ))
        panel.hiddenWebViewDiscardManager.noteRestoreNavigationStarted(reason: "test.current")
        panel.pendingDiscardRestoreNavigation = currentNavigation
        panel.navigationDelegate?.recordAttemptedRequest(URLRequest(url: currentURL))

        panel.navigationDelegate?.didCancelProvisionalNavigation?(panel.webView, staleNavigation)

        #expect(panel.navigationDelegate?.lastAttemptedURL == currentURL)
        #expect(panel.webViewLifecycleTopPayload()["restore_pending"] as? Bool == true)

        panel.navigationDelegate?.didCancelProvisionalNavigation?(panel.webView, currentNavigation)

        #expect(panel.navigationDelegate?.lastAttemptedURL == nil)
        #expect(panel.webViewLifecycleTopPayload()["restore_pending"] as? Bool == false)
    }

    @Test func cancelledInsecureHTTPPromptKeepsDiscardRestoreRetryable() throws {
        let url = try #require(URL(string: "http://example.com/cmux-issue-7504-insecure-prompt"))
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: nil,
            renderInitialNavigation: false
        )
        defer {
            panel.resetInsecureHTTPAlertHooksForTesting()
            panel.close()
        }

        panel.restoreSessionSnapshot(SessionBrowserPanelSnapshot(
            urlString: url.absoluteString,
            profileID: nil,
            shouldRenderWebView: true,
            pageZoom: 1.0,
            developerToolsVisible: false,
            backHistoryURLStrings: [],
            forwardHistoryURLStrings: []
        ))
        panel.hiddenWebViewDiscardManager.markDiscarded(
            reason: "test.discard",
            now: Date(timeIntervalSince1970: 200)
        )
        panel.noteDiscardedWebViewRestoreNavigationStarted()
        panel.navigationDelegate?.recordAttemptedRequest(URLRequest(url: url))
        panel.configureInsecureHTTPAlertHooksForTesting(
            alertFactory: {
                let alert = BrowserDiscardRestorePolicyCancelAlert()
                alert.response = .alertThirdButtonReturn
                return alert
            },
            windowProvider: { nil }
        )

        panel.navigationDelegate?.handleBlockedInsecureHTTPNavigation?(URLRequest(url: url), .currentTab)
        panel.navigationDelegate?.didCancelProvisionalNavigation?(panel.webView, nil)

        let payload = panel.webViewLifecycleTopPayload()
        #expect(payload["state"] as? String == "discarded")
        #expect(payload["restore_pending"] as? Bool == false)
        #expect((payload["discard_blockers"] as? [String])?.contains("already_discarded") == true)
        #expect(panel.restoreDiscardedWebViewIfNeeded(reason: "test.reveal"))
    }

    @Test func failedInsecureHTTPExternalOpenDoesNotReportTerminalRestore() throws {
        let url = try #require(URL(string: "http://example.com/cmux-issue-7504-open-failure"))
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: nil,
            renderInitialNavigation: false
        )
        defer { panel.close() }

        var resolutions: [BrowserInsecureHTTPNavigationResolution] = []
        var openedURL: URL?
        panel.handleInsecureHTTPAlertResponse(
            .alertFirstButtonReturn,
            alert: nil,
            host: "example.com",
            request: URLRequest(url: url),
            url: url,
            intent: .currentTab,
            recordTypedNavigation: false,
            openExternalURL: { url in
                openedURL = url
                return false
            },
            onResolution: { resolutions.append($0) }
        )

        #expect(openedURL == url)
        #expect(resolutions.isEmpty)
    }

    @Test func terminalPolicyCompletionAfterProvisionalCancelCompletesDiscardRestore() throws {
        let url = try #require(URL(string: "http://example.com/cmux-issue-7504-delayed-policy-terminal"))
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: nil,
            renderInitialNavigation: false
        )
        defer { panel.close() }

        panel.restoreSessionSnapshot(SessionBrowserPanelSnapshot(
            urlString: url.absoluteString,
            profileID: nil,
            shouldRenderWebView: true,
            pageZoom: 1.0,
            developerToolsVisible: false,
            backHistoryURLStrings: [],
            forwardHistoryURLStrings: []
        ))
        panel.hiddenWebViewDiscardManager.markDiscarded(
            reason: "test.discard",
            now: Date(timeIntervalSince1970: 250)
        )
        panel.noteDiscardedWebViewRestoreNavigationStarted()
        let restoreAttemptID = try #require(panel.currentDiscardRestoreAttemptID)
        panel.navigationDelegate?.recordAttemptedRequest(URLRequest(url: url))

        panel.navigationDelegate?.didCancelProvisionalNavigation?(panel.webView, nil)
        #expect(panel.webViewLifecycleTopPayload()["restore_pending"] as? Bool == false)
        #expect(panel.webViewLifecycleTopPayload()["state"] as? String == "discarded")

        panel.navigationDelegate?.didCancelNavigationPolicy?(panel.webView, .terminal(restoreAttemptID: restoreAttemptID))

        let payload = panel.webViewLifecycleTopPayload()
        #expect(payload["state"] as? String != "discarded")
        #expect(payload["restore_pending"] as? Bool == false)
        #expect(!panel.restoreDiscardedWebViewIfNeeded(reason: "test.reveal"))
    }

    @Test func staleInsecureHTTPPromptDoesNotCompleteNewerRestore() throws {
        let url = try #require(URL(string: "http://example.com/cmux-issue-7504-stale-prompt"))
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: nil,
            renderInitialNavigation: false
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer {
            panel.resetInsecureHTTPAlertHooksForTesting()
            window.close()
            panel.close()
        }

        panel.restoreSessionSnapshot(SessionBrowserPanelSnapshot(
            urlString: url.absoluteString,
            profileID: nil,
            shouldRenderWebView: true,
            pageZoom: 1.0,
            developerToolsVisible: false,
            backHistoryURLStrings: [],
            forwardHistoryURLStrings: []
        ))
        panel.hiddenWebViewDiscardManager.markDiscarded(
            reason: "test.discard",
            now: Date(timeIntervalSince1970: 300)
        )
        panel.noteDiscardedWebViewRestoreNavigationStarted()
        panel.pendingDiscardRestoreNavigation = WKNavigation()
        panel.navigationDelegate?.recordAttemptedRequest(URLRequest(url: url))

        let alert = BrowserDiscardRestoreDeferredPolicyAlert()
        panel.configureInsecureHTTPAlertHooksForTesting(
            alertFactory: { alert },
            windowProvider: { window }
        )
        panel.navigationDelegate?.handleBlockedInsecureHTTPNavigation?(URLRequest(url: url), .currentTab)
        let staleCompletion = try #require(alert.completionHandler)

        panel.noteDiscardedWebViewRestoreNavigationDidNotCommit(reason: "test.old_cancel")
        let currentNavigation = WKNavigation()
        panel.noteDiscardedWebViewRestoreNavigationStarted()
        panel.pendingDiscardRestoreNavigation = currentNavigation
        panel.navigationDelegate?.recordAttemptedRequest(URLRequest(url: url))

        staleCompletion(.alertThirdButtonReturn)

        let payload = panel.webViewLifecycleTopPayload()
        #expect(panel.pendingDiscardRestoreNavigation === currentNavigation)
        #expect(payload["restore_pending"] as? Bool == true)
        #expect((payload["discard_blockers"] as? [String])?.contains("already_discarded") == true)
    }
}
