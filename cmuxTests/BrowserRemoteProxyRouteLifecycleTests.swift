import CmuxCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct BrowserRemoteProxyRouteLifecycleTests {
    @Test
    func testRemoteWorkspaceKeepsProxyRouteWhileReplacementEndpointIsPending() {
        let remoteWorkspaceId = UUID()
        let panel = BrowserPanel(
            workspaceId: remoteWorkspaceId,
            isRemoteWorkspace: true,
            remoteWebsiteDataStoreIdentifier: remoteWorkspaceId
        )
        panel.setRemoteProxyEndpoint(BrowserProxyEndpoint(host: "127.0.0.1", port: 9876))
        #expect(panel.webView.configuration.websiteDataStore.proxyConfigurations.count == 2)
        let connectedWebView = panel.webView

        panel.setRemoteProxyEndpoint(nil)
        panel.navigate(to: URL(string: "http://localhost:3000/pending")!)

        #expect(panel.webView !== connectedWebView)
        #expect(panel.webView.configuration.websiteDataStore.proxyConfigurations.count == 2)
        #expect(panel.hasPendingRemoteNavigation)
        #expect(panel.webView.url == nil)
    }

    @Test
    func testRemoteProxyLossPreservesAnAlreadyDiscardedTab() {
        let remoteWorkspaceId = UUID()
        let panel = BrowserPanel(
            workspaceId: remoteWorkspaceId,
            isRemoteWorkspace: true,
            remoteWebsiteDataStoreIdentifier: remoteWorkspaceId
        )
        panel.setRemoteProxyEndpoint(BrowserProxyEndpoint(host: "127.0.0.1", port: 9876))
        panel.hiddenWebViewDiscardManager.markDiscarded(reason: "test.discard", now: Date())
        #expect(panel.hiddenWebViewDiscardManager.isDiscardedForMemory)
        let discardedWebView = panel.webView

        panel.setRemoteProxyEndpoint(nil)

        #expect(panel.webView === discardedWebView)
        #expect(panel.hiddenWebViewDiscardManager.isDiscardedForMemory)
    }
}
