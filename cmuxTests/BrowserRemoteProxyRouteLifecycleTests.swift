import CmuxCore
import WebKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class BrowserRemoteProxyRouteLifecycleTests: XCTestCase {
    func testRemoteWorkspaceKeepsProxyRouteWhileReplacementEndpointIsPending() {
        let remoteWorkspaceId = UUID()
        let panel = BrowserPanel(
            workspaceId: remoteWorkspaceId,
            isRemoteWorkspace: true,
            remoteWebsiteDataStoreIdentifier: remoteWorkspaceId
        )
        panel.setRemoteProxyEndpoint(BrowserProxyEndpoint(host: "127.0.0.1", port: 9876))
        XCTAssertEqual(panel.webView.configuration.websiteDataStore.proxyConfigurations.count, 2)
        let connectedWebView = panel.webView

        panel.setRemoteProxyEndpoint(nil)
        panel.navigate(to: URL(string: "http://localhost:3000/pending")!)

        XCTAssertFalse(panel.webView === connectedWebView)
        XCTAssertEqual(panel.webView.configuration.websiteDataStore.proxyConfigurations.count, 2)
        XCTAssertTrue(panel.hasPendingRemoteNavigation)
        XCTAssertNil(panel.webView.url)
    }
}
