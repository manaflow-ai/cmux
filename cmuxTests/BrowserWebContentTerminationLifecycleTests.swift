import AppKit
import CmuxBrowser
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the WebKit process termination callback boundary.
@MainActor
@Suite(.serialized)
struct BrowserWebContentTerminationLifecycleTests {
    @Test("Content termination revokes readiness for the retained WebView")
    func terminationRevokesCommittedDocumentReadiness() throws {
        let panel = BrowserPanel(workspaceId: UUID(), websiteDataStore: .nonPersistent())
        defer { panel.close() }
        let webView = panel.webView
        let delegate = try #require(webView.navigationDelegate as? BrowserNavigationDelegate)
        delegate.webView(webView, didCommit: nil)
        #expect(panel.automationDocumentReadiness.hasCommittedDocument(for: panel.webViewInstanceID))

        delegate.webViewWebContentProcessDidTerminate(webView)

        #expect(panel.webView === webView)
        #expect(!panel.automationDocumentReadiness.hasCommittedDocument(for: panel.webViewInstanceID))
    }

    @Test
    func terminationCallbackDoesNotReplaceWebViewInsideWebKitCallback() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "https://example.com/recovery")!
        )
        defer { panel.close() }

        let originalWebView = panel.webView
        guard let navigationDelegate = originalWebView.navigationDelegate as? BrowserNavigationDelegate else {
            Issue.record("BrowserPanel must install its navigation delegate before simulating termination")
            return
        }
        navigationDelegate.webViewWebContentProcessDidTerminate(originalWebView)

        #expect(panel.webView === originalWebView)
        #expect(originalWebView.navigationDelegate == nil)
    }

    @Test
    func recoverableTerminationBlocksHiddenDiscardUntilRecovery() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "https://example.com/recovery")!
        )
        defer { panel.close() }

        panel.noteWebViewVisibility(false, reason: "test.hidden")
        guard let navigationDelegate = panel.webView.navigationDelegate as? BrowserNavigationDelegate else {
            Issue.record("BrowserPanel must install its navigation delegate before simulating termination")
            return
        }
        navigationDelegate.webViewWebContentProcessDidTerminate(panel.webView)

        #expect(panel.hasRecoverableWebContentTermination)
        // Recovery starts a navigation immediately, so the loading blocker is
        // expected alongside the required web-content recovery blocker until
        // that navigation settles.
        #expect(
            panel.webViewLifecycleTopPayload()["discard_blockers"] as? [String] == [
                "webcontent_recovery",
                "loading",
            ]
        )
        #expect(!panel.discardHiddenWebViewForMemory(reason: "test.hidden_timer"))
    }

    @Test
    func systemMemoryPressureCanReclaimRecoverableHiddenWebView() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "https://example.com/recovery")!
        )
        defer { panel.close() }

        let expectedURL = URL(string: "https://example.com/recovery")!
        panel.restoreSessionNavigationHistory(
            backHistoryURLStrings: ["https://example.com/back"],
            forwardHistoryURLStrings: ["https://example.com/forward"],
            currentURLString: expectedURL.absoluteString
        )
        let expectedHistory = panel.sessionNavigationHistorySnapshot()
        panel.noteWebViewVisibility(false, reason: "test.hidden")
        guard let navigationDelegate = panel.webView.navigationDelegate as? BrowserNavigationDelegate else {
            Issue.record("BrowserPanel must install its navigation delegate before simulating termination")
            return
        }
        navigationDelegate.webViewWebContentProcessDidTerminate(panel.webView)

        #expect(panel.hasRecoverableWebContentTermination)
        #expect(panel.discardHiddenWebViewForSystemMemoryPressure(now: Date(timeIntervalSince1970: 10_000)))
        #expect(!panel.hasRecoverableWebContentTermination)
        #expect(!panel.shouldRenderWebView)

        panel.noteWebViewVisibility(true, reason: "test.reveal")

        #expect(panel.currentURL == expectedURL)
        let restoredHistory = panel.sessionNavigationHistorySnapshot()
        #expect(restoredHistory.backHistoryURLStrings == expectedHistory.backHistoryURLStrings)
        #expect(restoredHistory.forwardHistoryURLStrings == expectedHistory.forwardHistoryURLStrings)
    }

    @Test
    func recoveryPreservesActiveEmulatedViewportHost() throws {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "https://example.com/recovery")!
        )
        defer { panel.close() }

        let oldWebView = panel.webView
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 610))
        container.addSubview(oldWebView)
        let viewport = try #require(BrowserViewport(width: 1_280, height: 720))
        _ = try panel.setAutomationViewport(viewport).get()
        guard let navigationDelegate = oldWebView.navigationDelegate as? BrowserNavigationDelegate else {
            Issue.record("BrowserPanel must install its navigation delegate before simulating termination")
            return
        }
        navigationDelegate.webViewWebContentProcessDidTerminate(oldWebView)

        #expect(panel.webView === oldWebView)
        #expect(panel.recoverTerminatedWebContent(reason: "test"))
        #expect(panel.webView.superview === panel.viewportHostView)
        #expect(panel.webView.cmuxBrowserViewportPresentationView === panel.viewportHostView)
        #expect(panel.webView.cmuxBrowserViewportHostView === panel.viewportHostView)
        #expect(oldWebView.cmuxBrowserViewportHostView == nil)
    }

    @Test
    func recoveryPreservesRemoteWorkspaceWebsiteDataStore() {
        let storeIdentifier = UUID()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "https://example.com/recovery")!,
            isRemoteWorkspace: true,
            remoteWebsiteDataStoreIdentifier: storeIdentifier
        )
        defer { panel.close() }

        let originalStore = panel.webView.configuration.websiteDataStore
        let oldWebView = panel.webView
        guard let navigationDelegate = oldWebView.navigationDelegate as? BrowserNavigationDelegate else {
            Issue.record("BrowserPanel must install its navigation delegate before simulating termination")
            return
        }
        navigationDelegate.webViewWebContentProcessDidTerminate(oldWebView)
        #expect(panel.webView === oldWebView)
        #expect(panel.recoverTerminatedWebContent(reason: "test"))
        #expect(panel.webView.configuration.websiteDataStore === originalStore)
    }
}
