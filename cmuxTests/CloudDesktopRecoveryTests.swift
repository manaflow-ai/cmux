import CmuxSettings
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Cloud Desktop input recovery (https://github.com/manaflow-ai/cmux/issues/12290):
/// a viewer that lost its RFB session is never presented as connected, and a
/// replaced browser carrier rebinds the live document. Split from
/// CloudDesktopAccessTests so that file stays within its length budget.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudDesktopRecoveryTests {
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
        let live = LiveWorkspaceFixture()
        defer { live.tearDown() }
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
        let provider = provider(store: store, catalog: SurfaceCatalog(live: live))
        let browser = BrowserPanel(workspaceId: live.id(), websiteDataStore: .nonPersistent())
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
        browser.cloudDesktopRouteDidChange()
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

    /// https://github.com/manaflow-ai/cmux/issues/12290
    @Test("A viewer that lost its session is never presented as a connected desktop")
    func desktopReconnectingIsNotPresentedAsConnected() async throws {
        let model = CloudPortAccessModel(
            target: .init(host: "10.0.0.7", port: 6901), coordinator: nil, wake: {},
            startForward: { _ in 46_901 }, stopForward: {}, route: .loopback
        )
        let browser = BrowserPanel(workspaceId: UUID(), websiteDataStore: .nonPersistent())
        defer { browser.close() }
        let state = browser.cloudAccess
        state.configure(model: model, url: try #require(URL(string: "http://10.0.0.7:6901/vnc.html?path=websockify")))
        model.connect()
        #expect(await wait { model.isReady })
        let local = try #require(state.nextURL())
        state.didCommit(url: local)
        state.didFinish(url: local)
        #expect(state.showsPage)

        state.desktopConnectionDidChange(url: local, state: .reconnecting)
        #expect(!state.showsPage, "noVNC drops every pointer event while it is not connected")
        #expect(state.desktopStatusMessage != nil, "The pane says the desktop is reconnecting")
        #expect(state.desktopFailure == nil, "A first retry is not yet a failure")
        #expect(!state.showsFailureAlert, "A transient reconnect does not raise a modal")

        state.desktopConnectionDidChange(url: local, state: .disconnected)
        #expect(!state.showsPage)

        state.desktopConnectionDidChange(url: local, state: .connected)
        #expect(state.showsPage && state.desktopStatusMessage == nil)
        await model.retire()
    }

    /// The viewer retries on its own, so recovery is driven by an observed
    /// endpoint change rather than by a timer: one re-resolve per episode, and
    /// a reload only when the carrier the document carries is actually gone.
    @Test("Desktop recovery rebinds on a replaced carrier and stops on an unchanged one")
    func desktopRecoveryPolicyRebindsOnlyOnEndpointChange() {
        let first = CloudBrowserProxyEndpoint(host: "127.0.0.1", port: 47_101, username: "c", password: "a")
        let replacement = CloudBrowserProxyEndpoint(host: "127.0.0.1", port: 47_202, username: "c", password: "b")
        var policy = CloudDesktopRecoveryPolicy()

        var action = policy.viewerDidReport(.disconnected)
        #expect(action == .idle, "An unbound document has no carrier to compare against")

        policy.documentDidBind(to: first)
        action = policy.viewerDidReport(.reconnecting)
        #expect(action == .resolveEndpoint)
        action = policy.viewerDidReport(.disconnected)
        #expect(action == .idle, "One endpoint re-resolve per disconnected episode")

        action = policy.routeDidChange(currentEndpoint: first)
        #expect(action == .idle, "A live carrier is not a reason to reload the document")
        action = policy.routeDidChange(currentEndpoint: replacement)
        #expect(action == .rebind)
        #expect(policy.boundEndpoint == replacement)

        // A late callback cannot reintroduce the carrier the rebind replaced.
        action = policy.routeDidChange(currentEndpoint: replacement)
        #expect(action == .idle)
        action = policy.viewerDidReport(.connected)
        #expect(action == .idle)
        #expect(policy.rebindsWithoutConnection == 0, "A working session clears the rebind budget")
    }

    @Test("Rebinding stops once fresh carriers keep failing, and reports the failure")
    func desktopRecoveryStopsAfterRepeatedRebinds() {
        var policy = CloudDesktopRecoveryPolicy()
        policy.documentDidBind(to: CloudBrowserProxyEndpoint(host: "127.0.0.1", port: 47_000, username: "c", password: "p"))
        for index in 1...CloudDesktopRecoveryPolicy.rebindLimit {
            let resolve = policy.viewerDidReport(.disconnected)
            #expect(resolve == .resolveEndpoint)
            let next = CloudBrowserProxyEndpoint(
                host: "127.0.0.1", port: UInt16(47_000 + index), username: "c", password: "p"
            )
            let rebind = policy.routeDidChange(currentEndpoint: next)
            #expect(rebind == .rebind)
        }
        #expect(policy.hasExhaustedRebinds)
        let exhausted = policy.viewerDidReport(.disconnected)
        #expect(exhausted == .idle, "The endpoint is demonstrably not what is broken")
    }

    @Test("The noVNC bridge reports a lost session, not only connect and failure")
    func desktopBridgeReportsLostSession() async throws {
        let failed = CloudLinkFirstValue<Bool>()
        let connected = CloudLinkFirstValue<Bool>()
        let reconnecting = CloudLinkFirstValue<Bool>()
        let disconnected = CloudLinkFirstValue<Bool>()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        defer { webView.stopLoading() }
        let url = try #require(URL(string: "http://127.0.0.1:46901/vnc.html"))
        CloudDesktopConnectionObserver.install(on: webView, documentIdentity: "lost-session") { _, state, _ in
            switch state {
            case .failed: failed.resolve(true)
            case .connected: connected.resolve(true)
            case .reconnecting: reconnecting.resolve(true)
            case .disconnected: disconnected.resolve(true)
            }
        }
        // Start in the error state the bridge already reports. Awaiting that
        // first report proves the real document committed and the injected
        // script is live, so the class changes below cannot race against the
        // initial empty document and be thrown away with it.
        webView.loadHTMLString("""
            <!doctype html><html><body>
            <div id="noVNC_status" class="noVNC_open noVNC_status_error">Failed to connect</div>
            <div id="noVNC_container"></div>
            </body></html>
            """, baseURL: url)
        #expect(await failed.result == true)

        _ = try await webView.evaluateJavaScript("document.documentElement.classList.add('noVNC_connected')")
        #expect(await connected.result == true)

        // Clear the error status too, so the report reflects the retry rather
        // than the stale failure the document started in.
        _ = try await webView.evaluateJavaScript("""
            document.documentElement.classList.remove('noVNC_connected');
            document.getElementById('noVNC_status').className = '';
            document.documentElement.classList.add('noVNC_reconnecting');
            """)
        #expect(await reconnecting.result == true,
                "A silently retrying viewer must not still read as connected")

        _ = try await webView.evaluateJavaScript("document.documentElement.classList.remove('noVNC_reconnecting')")
        #expect(await disconnected.result == true)
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
}
