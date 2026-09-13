import AppKit
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
    @Test
    func terminationCallbackDoesNotReplaceWebViewInsideWebKitCallback() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "https://example.com/recovery")!
        )
        defer { panel.close() }

        let originalWebView = panel.webView
        panel.webView.navigationDelegate?.webViewWebContentProcessDidTerminate?(originalWebView)

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
        panel.webView.navigationDelegate?.webViewWebContentProcessDidTerminate?(panel.webView)

        #expect(panel.hasRecoverableWebContentTermination)
        #expect(panel.webViewLifecycleTopPayload()["discard_blockers"] as? [String] == ["webcontent_recovery"])
        #expect(!panel.discardHiddenWebViewForMemory(reason: "test.hidden_timer"))
    }

    @Test
    func systemMemoryPressureCanReclaimRecoverableHiddenWebView() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "https://example.com/recovery")!
        )
        defer { panel.close() }

        panel.noteWebViewVisibility(false, reason: "test.hidden")
        panel.webView.navigationDelegate?.webViewWebContentProcessDidTerminate?(panel.webView)

        #expect(panel.hasRecoverableWebContentTermination)
        #expect(panel.discardHiddenWebViewForSystemMemoryPressure(now: Date(timeIntervalSince1970: 10_000)))
        #expect(!panel.hasRecoverableWebContentTermination)
        #expect(!panel.shouldRenderWebView)
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
        panel.webView.navigationDelegate?.webViewWebContentProcessDidTerminate?(oldWebView)

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
        panel.webView.navigationDelegate?.webViewWebContentProcessDidTerminate?(oldWebView)
        #expect(panel.webView === oldWebView)
        #expect(panel.recoverTerminatedWebContent(reason: "test"))
        #expect(panel.webView.configuration.websiteDataStore === originalStore)
    }
}
