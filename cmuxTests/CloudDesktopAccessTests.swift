import CmuxSettings
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Exercise the provider's real browser configuration path, including the
/// shared model lookup, rather than manually starting a forward in the test.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudDesktopAccessTests {
    @Test("Desktop failure can be dismissed and Retry re-establishes the shared route")
    func desktopFailureRecovery() async throws {
        var starts = 0
        let model = CloudPortAccessModel(
            target: .init(host: "10.0.0.7", port: 6901), coordinator: nil, wake: {},
            startForward: { _ in starts += 1; return 46_901 }, stopForward: {}, route: .loopback
        )
        let browser = BrowserPanel(workspaceId: UUID(), websiteDataStore: .nonPersistent())
        defer { browser.close() }
        let state = browser.cloudAccess
        state.configure(model: model, url: URL(string: "http://10.0.0.7:6901/vnc.html?path=websockify")!)
        model.connect()
        #expect(await wait { model.isReady })
        let local = try #require(state.nextURL())
        state.didCommit(url: local)
        state.didFinish(url: local)
        state.desktopConnectionDidChange(url: URL(string: "http://127.0.0.1:46902/vnc.html")!, isConnected: false)
        #expect(!state.showsFailureAlert, "A stale listener cannot fail the new page")
        state.desktopConnectionDidChange(url: local, isConnected: false)
        #expect(state.showsFailureAlert && state.showsPage)
        state.dismissFailure()
        state.desktopConnectionDidChange(url: local, isConnected: false)
        #expect(!state.showsFailureAlert, "The same failure cannot reopen a dismissed modal")
        _ = browser.reload()
        #expect(await wait { model.isReady && starts == 2 })
        #expect(state.desktopFailure == nil && state.nextURL() == local)
        state.didCommit(url: local)
        state.desktopConnectionDidChange(url: local, isConnected: false)
        #expect(state.showsFailureAlert, "A failed explicit retry is a new attempt")
        state.desktopConnectionDidChange(url: local, isConnected: true)
        #expect(!state.showsFailureAlert)
        browser.hardReload()
        #expect(await wait { model.isReady && starts == 3 })
        await model.retire()
    }

    @Test("The noVNC status bridge observes failures after the HTTP document loads")
    func desktopStatusBridge() async throws {
        let failed = CloudLinkFirstValue<Bool>()
        let connected = CloudLinkFirstValue<Bool>()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        defer { webView.stopLoading() }
        let url = URL(string: "http://127.0.0.1:46901/vnc.html")!
        CloudDesktopConnectionObserver.install(on: webView) { reportedURL, isConnected in
            #expect(reportedURL == url)
            if isConnected { connected.resolve(true) } else { failed.resolve(true) }
        }
        webView.loadHTMLString("""
            <!doctype html><html><body>
            <div id="noVNC_status" class="noVNC_open noVNC_status_error">Failed to connect</div>
            <div id="noVNC_container"></div>
            </body></html>
            """, baseURL: url)
        #expect(await failed.result == true)
        _ = try await webView.evaluateJavaScript("document.documentElement.classList.add('noVNC_connected')")
        #expect(await connected.result == true)
    }

    @Test("Every Cloud website retains its requested URL through bootstrap commits",
          arguments: ["http://10.0.0.7:6901/vnc.html", "http://10.0.0.7:3000/", "https://10.0.0.7:8443/app"])
    func desktopRetainsPendingServiceIdentity(rawURL: String) async throws {
        let store = CloudPortAccessStore()
        let catalog = SurfaceCatalog()
        let readiness = CloudLinkFirstValue<CloudBrowserProxyEndpoint>()
        let remote = try #require(URL(string: rawURL))
        let target = CloudPortForwardTarget(host: "10.0.0.7", port: remote.port!)
        let model = store.model(machineID: "test-desktop", target: target, scheme: remote.scheme!) {
            CloudPortAccessModel(
                target: target, coordinator: nil, wake: {},
                startForward: { _ in Issue.record("Unexpected legacy route"); return 1 },
                stopForward: {}, startBrowserProxy: {
                    guard let endpoint = await readiness.result else { throw CancellationError() }
                    return endpoint
                }
            )
        }
        let provider = provider(store: store, catalog: catalog)
        let browser = BrowserPanel(workspaceId: UUID(), websiteDataStore: .nonPersistent())
        defer { browser.close(); readiness.resolve(nil) }
        // A delayed bootstrap commit from the original WebView must not replace
        // the Cloud identity while its authenticated replacement is being prepared.
        browser.webView.loadHTMLString("<title>bootstrap</title>", baseURL: nil)
        provider.configureBrowser(browser, url: remote)
        browser.webView.loadHTMLString("<title>bootstrap</title>", baseURL: nil)
        _ = try await firstTitle(browser, equals: "bootstrap")
        #expect(!model.isReady)
        #expect(browser.currentURL == remote)
        #expect(browser.preferredURLStringForSessionSnapshot() == remote.absoluteString)
        await store.remove(machineID: "test-desktop")
    }

    @Test("A saved Cloud browser URL never retains an ephemeral loopback port")
    func sessionSnapshotUsesPrivateServiceAddress() {
        let local = URL(string: "http://127.0.0.1:46901/vnc.html?path=websockify&resize=remote")!
        let remote = URL(string: "http://10.0.0.7:6901/vnc.html?path=websockify&resize=remote")!
        let browser = BrowserPanel(
            workspaceId: UUID(), initialURL: local, renderInitialNavigation: false,
            websiteDataStore: .nonPersistent()
        )
        defer { browser.close() }
        let model = CloudPortAccessModel(
            target: .init(host: "10.0.0.7", port: 6901), coordinator: nil, wake: {},
            startForward: { _ in 46_901 }, stopForward: {}, route: .loopback
        )
        browser.cloudAccess.configure(model: model, url: remote)
        #expect(browser.preferredURLStringForSessionSnapshot() == remote.absoluteString)
    }

    @Test("Desktop bootstrap does not paint WebKit's default white background")
    func desktopBackgroundUsesNativeBackingUntilCanvasPaints() async throws {
        let browser = BrowserPanel(workspaceId: UUID(), websiteDataStore: .nonPersistent())
        defer { browser.close() }
        let model = CloudPortAccessModel(
            target: .init(host: "10.0.0.7", port: 6901), coordinator: nil,
            wake: {}, startForward: { _ in 46_901 }, stopForward: {}, route: .loopback
        )
        let url = try #require(URL(string: CmuxTuiSurfaceProvider.privateDesktopURL(privateAddress: "10.0.0.7")))
        browser.cloudAccess.configure(model: model, url: url)
        model.connect()
        #expect(await wait { model.isReady })
        browser.navigate(to: try #require(browser.cloudAccess.nextURL()))
        #expect(browser.webView.value(forKey: "drawsBackground") as? Bool == false)
        browser.navigate(to: URL(string: "https://example.com")!)
        #expect(browser.webView.value(forKey: "drawsBackground") as? Bool == true,
                "Ordinary websites still need WebKit's normal document background")
        await model.retire()
    }

    @Test("Opening Desktop starts exactly one HTTP route without system VPN",
          arguments: [CloudTunnelState.off, .awaitingApproval, .starting, .up, .stopping, .failed("VPN failed")])
    func desktopMaterializationStartsForward(state: CloudTunnelState) async throws {
        let store = CloudPortAccessStore()
        let target = CloudPortForwardTarget(host: "10.0.0.7", port: 6901)
        var starts = 0
        var stops = 0
        let model = store.model(machineID: "test-desktop", target: target) {
            CloudPortAccessModel(target: target, coordinator: nil, wake: {}, startForward: { _ in
                starts += 1
                return 46_901
            }, stopForward: { stops += 1 }, route: .loopback)
        }
        model.acceptTunnelState(state)
        let catalog = SurfaceCatalog()
        let provider = provider(store: store, catalog: catalog)
        let first = BrowserPanel(workspaceId: UUID(), websiteDataStore: .nonPersistent())
        let second = BrowserPanel(workspaceId: UUID(), websiteDataStore: .nonPersistent())
        defer { first.close(); second.close() }
        let remote = try #require(URL(string: CmuxTuiSurfaceProvider.privateDesktopURL(privateAddress: target.host)))

        provider.configureBrowser(first, url: remote)
        provider.configureBrowser(second, url: remote)
        #expect(first.cloudAccess.model === second.cloudAccess.model)
        #expect(await wait { model.isReady })
        #expect(starts == 1)
        let local = try #require(first.cloudAccess.nextURL())
        #expect(local.absoluteString == "http://127.0.0.1:46901/vnc.html?path=websockify&autoconnect=1&resize=remote&reconnect=1&reconnect_delay=2000")
        first.cloudAccess.didCommit(url: local)
        first.cloudAccess.didFinish(url: local)
        #expect(first.cloudAccess.showsPage)
        first.cloudAccess.leave()
        #expect(second.cloudAccess.nextURL() == local)
        #expect(stops == 0, "Closing one pane must not retire the shared route")
        await store.remove(machineID: "test-desktop")
        #expect(stops == 1 && model.phase == .closed)
    }

    @Test("A private-origin deny rule cannot be bypassed by the loopback rewrite")
    func deniedPrivateOriginCreatesNoForward() {
        let store = CloudPortAccessStore()
        let catalog = SurfaceCatalog()
        let policy = BrowserURLAllowlistPolicy(managedPatterns: ["allowed.example"], allowsLocalhost: true)
        let provider = provider(store: store, catalog: catalog, policy: policy)
        let browser = BrowserPanel(workspaceId: UUID(), websiteDataStore: .nonPersistent())
        defer { browser.close() }
        provider.configureBrowser(browser, url: URL(string: "http://10.0.0.7:6901/vnc.html")!)
        #expect(policy.allowsTrustedInternalURL(URL(string: "http://127.0.0.1:46901")!))
        #expect(browser.cloudAccess.unavailable != nil)
        #expect(browser.cloudAccess.model == nil && store.models.isEmpty)
    }

    @Test("HTTP and HTTPS access share neither navigation state nor cleanup")
    func schemeOwnership() async throws {
        let store = CloudPortAccessStore()
        let catalog = SurfaceCatalog()
        let provider = provider(store: store, catalog: catalog)
        let http = provider.accessModel(port: 8443, address: "10.0.0.7", scheme: "HTTP")
        let https = provider.accessModel(port: 8443, address: "10.0.0.7", scheme: "https")
        #expect(http !== https)
        #expect(http.route == .browserProxy && https.route == .browserProxy)
        #expect(http.usesBrowserProxy && https.usesBrowserProxy)
        https.acceptTunnelState(.off)
        https.connect()
        #expect(https.phase == .connecting, "HTTPS keeps its private origin through the browser proxy")
        await store.remove(machineID: "test-desktop")
    }

    @Test("A failed private network reports its actual error inline")
    func privateNetworkFailureIsVisible() {
        let coordinator = CloudTunnelCoordinator(
            backend: .networkExtension(extensionBundleIdentifier: "test.cloud.desktop"),
            controller: FakeTunnelController(), enroller: FakeTunnelEnroller(), consumers: FakeTunnelConsumers()
        )
        let model = CloudPortAccessModel(
            target: .init(host: "10.0.0.7", port: 443), coordinator: coordinator,
            wake: {}, startForward: { _ in 42_000 }, stopForward: {}
        )
        model.acceptTunnelState(.failed("Permission refused"))
        #expect(model.failureMessage?.contains("Permission refused") == true)
        model.acceptTunnelState(.awaitingApproval)
        #expect(model.failureMessage?.isEmpty == false)
    }

    /// https://github.com/manaflow-ai/cmux/issues/12290
    ///
    /// The desktop page reaches its machine through a per-VM browser carrier
    /// whose loopback port and WebSocket token are injected into the document
    /// when it loads. noVNC reuses whatever the document was built with for its
    /// own `reconnect=1` retries, so a replaced carrier leaves the viewer
    /// dialing a port that no longer exists and silently dropping every click.
    /// The page URL cannot catch this: it is the machine's private address,
    /// which is identical across carrier restarts.
    @Test("A replaced browser carrier rebinds the live desktop document")
    func desktopRebindsAfterCarrierReplacement() async throws {
        let store = CloudPortAccessStore()
        let target = CloudPortForwardTarget(host: "10.0.0.7", port: 6901)
        let first = CloudBrowserProxyEndpoint(
            host: "127.0.0.1", port: 47_101, username: "cmux", password: "first", websocketToken: "token-first"
        )
        let replacement = CloudBrowserProxyEndpoint(
            host: "127.0.0.1", port: 47_202, username: "cmux", password: "second", websocketToken: "token-second"
        )
        var carrierStarts = 0
        let model = store.model(machineID: "test-desktop", target: target) {
            CloudPortAccessModel(
                target: target, coordinator: nil, wake: {},
                startForward: { _ in
                    Issue.record("The desktop route must not fall back to a loopback forward")
                    return 1
                },
                stopForward: {},
                startBrowserProxy: {
                    carrierStarts += 1
                    return carrierStarts <= 1 ? first : replacement
                }
            )
        }
        let provider = provider(store: store, catalog: SurfaceCatalog())
        let browser = BrowserPanel(workspaceId: UUID(), websiteDataStore: .nonPersistent())
        defer { browser.close() }
        let remote = try #require(URL(string: CmuxTuiSurfaceProvider.privateDesktopURL(privateAddress: target.host)))

        provider.configureBrowser(browser, url: remote)
        #expect(await wait { model.browserProxy == first })
        let local = try #require(browser.cloudAccess.nextURL())
        browser.navigate(to: local)
        browser.cloudAccess.didCommit(url: local)
        browser.cloudAccess.didFinish(url: local)
        #expect(bridgesCarrierPort(browser, port: first.port), "The first document carries the first carrier")

        // The shared carrier is replaced while the page URL stays identical.
        model.retry()
        #expect(await wait { model.browserProxy == replacement })
        // What the Cloud browser view re-runs on every route phase change.
        if let next = browser.cloudAccess.nextURL() { browser.navigate(to: next) }

        #expect(
            bridgesCarrierPort(browser, port: replacement.port),
            "A live desktop document must not keep dialing the replaced carrier"
        )
        #expect(!bridgesCarrierPort(browser, port: first.port), "The dead carrier's credentials must be dropped")
        await store.remove(machineID: "test-desktop")
    }

    /// The injected document-start bridge rewrites the VM WebSocket to the
    /// carrier's loopback port, so the port in its source is the route the
    /// live document will actually dial.
    private func bridgesCarrierPort(_ browser: BrowserPanel, port: UInt16) -> Bool {
        browser.webView.configuration.userContentController.userScripts.contains {
            $0.source.contains("__cmuxCloudWebSocketBridgeInstalled") && $0.source.contains("String(\(port))")
        }
    }

    private func provider(
        store: CloudPortAccessStore,
        catalog: SurfaceCatalog,
        policy: BrowserURLAllowlistPolicy = .init(managedPatterns: nil)
    ) -> CmuxTuiSurfaceProvider {
        var summary = VMSummary(id: "test-desktop", provider: "freestyle", status: "running", image: "cmux-devbox", createdAt: 0, base: nil)
        summary.addressIPv4 = "10.0.0.7"
        return CmuxTuiSurfaceProvider(
            summary: summary,
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            catalog: catalog,
            portAccessStore: store,
            browserPolicy: { policy }
        )
    }

    private func wait(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        return predicate()
    }

    private func firstTitle(_ browser: BrowserPanel, equals expected: String) async throws -> String? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        var title: String?
        while ContinuousClock.now < deadline {
            title = try await browser.webView.evaluateJavaScript("document.title") as? String
            if title == expected { return title }
            try await Task.sleep(for: .milliseconds(10))
        }
        return title
    }
}
