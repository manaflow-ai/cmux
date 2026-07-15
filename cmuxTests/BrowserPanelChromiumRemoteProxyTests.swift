import CmuxCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Regression coverage for Chromium remote-workspace loopback proxying: a
// `.chromium` surface in a remote workspace must launch its Content Shell with
// the workspace's SOCKS proxy and rewrite loopback URLs to the proxy alias
// domain, matching the WebKit engine's `proxyConfigurations` +
// `remoteProxyPreparedRequest` behavior. Without this, `http://localhost:...`
// in a remote-workspace Chromium pane dials the Mac's own loopback and fails
// with ERR_CONNECTION_REFUSED.
//
// Tests drive `activateChromiumIfNeeded` through the DEBUG activation
// interceptor, which reports the launch URL and `--proxy-server` value without
// spawning a Content Shell process. The suite is @MainActor with no suspension
// points, so no `.serialized` is needed.
@MainActor
@Suite("Chromium remote-workspace loopback proxy")
struct BrowserPanelChromiumRemoteProxyTests {
    private static let endpoint = BrowserProxyEndpoint(host: "127.0.0.1", port: 42817)
    private static let localhostURL = URL(string: "http://localhost:3000/app")!
    private static let aliasURLString = "http://cmux-loopback.localtest.me:3000/app"

    private struct CapturedLaunch {
        var initialURL: String
        var proxyServer: String?
    }

    private func capturingActivation(
        of panel: BrowserPanel,
        _ body: () -> Void
    ) -> CapturedLaunch? {
        var captured: CapturedLaunch?
        panel.chromiumActivationInterceptorForTesting = { initialURL, proxyServer in
            captured = CapturedLaunch(initialURL: initialURL, proxyServer: proxyServer)
        }
        body()
        panel.chromiumActivationInterceptorForTesting = nil
        return captured
    }

    @Test func remotePaneLaunchesWithSocksProxyAndAliasURL() throws {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: Self.localhostURL,
            proxyEndpoint: Self.endpoint,
            isRemoteWorkspace: true,
            engineKind: .chromium
        )
        let launch = try #require(capturingActivation(of: panel) {
            panel.activateChromiumIfNeeded()
        })
        #expect(launch.proxyServer == "socks5://127.0.0.1:42817")
        #expect(launch.initialURL == Self.aliasURLString)
    }

    @Test func remotePaneDefersLaunchUntilProxyEndpointArrives() throws {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: Self.localhostURL,
            isRemoteWorkspace: true,
            engineKind: .chromium
        )
        var captured: CapturedLaunch?
        panel.chromiumActivationInterceptorForTesting = { initialURL, proxyServer in
            captured = CapturedLaunch(initialURL: initialURL, proxyServer: proxyServer)
        }
        defer { panel.chromiumActivationInterceptorForTesting = nil }

        panel.activateChromiumIfNeeded()
        #expect(captured == nil)

        panel.setRemoteProxyEndpoint(Self.endpoint)
        let launch = try #require(captured)
        #expect(launch.proxyServer == "socks5://127.0.0.1:42817")
        #expect(launch.initialURL == Self.aliasURLString)
    }

    @Test func localPaneLaunchesDirectWithUnmodifiedURL() throws {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: Self.localhostURL,
            engineKind: .chromium
        )
        let launch = try #require(capturingActivation(of: panel) {
            panel.activateChromiumIfNeeded()
        })
        #expect(launch.proxyServer == nil)
        #expect(launch.initialURL == Self.localhostURL.absoluteString)
    }

    @Test func remotePaneNonLoopbackURLIsNotRewritten() throws {
        let url = URL(string: "https://example.com/")!
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: url,
            proxyEndpoint: Self.endpoint,
            isRemoteWorkspace: true,
            engineKind: .chromium
        )
        let launch = try #require(capturingActivation(of: panel) {
            panel.activateChromiumIfNeeded()
        })
        #expect(launch.proxyServer == "socks5://127.0.0.1:42817")
        #expect(launch.initialURL == url.absoluteString)
    }

    @Test func remotePaneOmnibarShowsLocalhostFormForAliasNavigation() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            proxyEndpoint: Self.endpoint,
            isRemoteWorkspace: true,
            engineKind: .chromium
        )
        // Session not yet up: navigation records the URL for deferred load.
        panel.navigate(to: URL(string: Self.aliasURLString)!)
        #expect(panel.currentURL == Self.localhostURL)
    }
}
