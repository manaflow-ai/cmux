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
    @Test("Route readiness drives cold open and cached retry without a SwiftUI phase update")
    func automaticallyNavigatesAfterRouteReadiness() async throws {
        let ready = CloudLinkFirstValue<Bool>()
        var starts = 0
        let model = CloudPortAccessModel(target: .init(host: "10.0.0.7", port: 6901), coordinator: nil,
            wake: {}, startForward: { _ in
                _ = await ready.result
                starts += 1
                return 46901
            }, stopForward: {}, route: .loopback)
        let state = CloudBrowserAccessState()
        state.configure(model: model, url: URL(string: "http://10.0.0.7:6901/vnc.html")!)
        var navigations: [URL] = []
        state.automaticallyNavigate { navigations.append($0) }
        model.connect()
        state.configure(model: model, url: URL(string: "http://10.0.0.7:6901/vnc.html")!)
        #expect(navigations.isEmpty, "A slow route cannot invent a completed navigation")
        ready.resolve(true)
        #expect(await wait { navigations.count == 1 })
        let url = try #require(navigations.first)
        state.didCommit(url: url)
        state.didFinish(url: url)
        state.desktopConnectionDidChange(url: url, isConnected: true)
        state.retry()
        #expect(await wait { starts == 2 && navigations.count == 2 })
        #expect(navigations[1] == url)
        state.leave()
        model.retry()
        #expect(await wait { starts == 3 })
        #expect(navigations.count == 2, "A retired document cannot navigate after leaving Cloud")
        await model.retire()
    }

    @Test("A finished noVNC page without RFB readiness reaches a retryable deadline")
    func desktopReadinessDeadline() async throws {
        let clock = CloudCommandDeadlineClock()
        let model = CloudPortAccessModel(target: .init(host: "10.0.0.7", port: 6901), coordinator: nil,
            wake: {}, startForward: { _ in 46901 }, stopForward: {}, route: .loopback)
        let state = CloudBrowserAccessState(clock: clock)
        state.configure(model: model, url: URL(string: "http://10.0.0.7:6901/vnc.html")!)
        model.connect()
        #expect(await wait { model.isReady })
        let url = try #require(state.nextURL())
        state.didCommit(url: url)
        state.didFinish(url: url)
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(46))
        #expect(await wait { state.showsFailureAlert })
        #expect(!state.desktopConnected)
        state.retry()
        #expect(state.failureMessage == nil)
        state.leave()
        await model.retire()
    }

    @Test("Automatic reconnect attempts do not extend the display deadline")
    func reconnectDoesNotResetDeadline() async throws {
        let clock = CloudCommandDeadlineClock()
        let model = CloudPortAccessModel(target: .init(host: "10.0.0.7", port: 6901), coordinator: nil,
            wake: {}, startForward: { _ in 46901 }, stopForward: {}, route: .loopback)
        let state = CloudBrowserAccessState(clock: clock)
        state.configure(model: model, url: URL(string: "http://10.0.0.7:6901/vnc.html")!)
        model.connect()
        #expect(await wait { model.isReady })
        let url = try #require(state.nextURL())
        state.didCommit(url: url)
        state.desktopConnectionIsConnecting(url: url)
        await clock.waitUntilSleeping()
        state.desktopConnectionIsConnecting(url: url)
        clock.advance(by: .seconds(46))
        #expect(await wait { state.showsFailureAlert })
        await model.retire()
    }

    @Test("A cancelled old navigation cannot cancel a newer display attempt")
    func cancellationUsesNavigationIdentity() async throws {
        let old = NSObject(), current = NSObject()
        let model = CloudPortAccessModel(target: .init(host: "10.0.0.7", port: 6901), coordinator: nil,
            wake: {}, startForward: { _ in 46901 }, stopForward: {}, route: .loopback)
        let state = CloudBrowserAccessState()
        state.configure(model: model, url: URL(string: "http://10.0.0.7:6901/vnc.html")!)
        model.connect()
        #expect(await wait { model.isReady })
        let url = try #require(state.nextURL())
        state.didStart(url: url, navigationID: ObjectIdentifier(current))
        state.didCancel(navigationID: ObjectIdentifier(old))
        #expect(state.error == nil)
        state.didCancel(navigationID: ObjectIdentifier(current))
        #expect(state.error != nil && !state.showsPage)
        state.didCommit(url: url, navigationID: ObjectIdentifier(current))
        state.desktopConnectionDidChange(url: url, isConnected: true)
        #expect(!state.showsPage && !state.desktopConnected)
        state.leave()
        await model.retire()
    }

    @Test("A connected noVNC document is ready even before WebKit's finish callback", arguments: [6901, 6902])
    func desktopConnectionCompletesReadiness(port: Int) async throws {
        let model = CloudPortAccessModel(target: .init(host: "10.0.0.7", port: port), coordinator: nil,
            wake: {}, startForward: { _ in UInt16(40_000 + port) }, stopForward: {}, route: .loopback)
        let state = CloudBrowserAccessState()
        let remote = try #require(URL(string: "http://10.0.0.7:\(port)/vnc.html"))
        state.configure(model: model, url: remote,
                        resourceID: SurfaceResourceID(machine: .cloud("display-test"), kind: .display, key: "display:\(port == 6901 ? 1 : 2)"))
        model.connect()
        #expect(await wait { model.isReady })
        let url = try #require(state.nextURL())
        state.didCommit(url: url)
        state.desktopConnectionDidChange(url: url, isConnected: true)
        #expect(state.showsPage, "A live RFB connection is stronger evidence than document finish")
        state.configure(model: model, url: remote)
        #expect(state.resourceID?.key == "display:\(port == 6901 ? 1 : 2)",
                "Rebinding an existing WebView preserves the display identity")
        let reboundURL = try #require(state.nextURL())
        state.didCommit(url: reboundURL)
        state.desktopConnectionDidChange(url: url, isConnected: false)
        #expect(state.showsFailureAlert)
        state.desktopConnectionDidChange(url: url, isConnected: true)
        #expect(!state.showsFailureAlert && state.showsPage)
        await model.retire()
    }

    @Test("A stale finish cannot complete the requested Cloud document")
    func ignoresForeignFinish() async throws {
        let model = CloudPortAccessModel(target: .init(host: "10.0.0.7", port: 6901), coordinator: nil,
            wake: {}, startForward: { _ in 46901 }, stopForward: {}, route: .loopback)
        let state = CloudBrowserAccessState()
        state.configure(model: model, url: URL(string: "http://10.0.0.7:6901/vnc.html")!)
        model.connect()
        #expect(await wait { model.isReady })
        let url = try #require(state.nextURL())
        state.didCommit(url: url)
        state.didFinish(url: URL(string: "http://10.0.0.8:6901/vnc.html"))
        #expect(!state.showsPage)
        await model.retire()
    }

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

    @Test("Leaving a Cloud page clears its resource provenance")
    func leavingCloudClearsResourceIdentity() {
        let state = CloudBrowserAccessState()
        let model = CloudPortAccessModel(target: .init(host: "10.0.0.7", port: 6901), coordinator: nil,
            wake: {}, startForward: { _ in 46901 }, stopForward: {}, route: .loopback)
        let display = SurfaceResourceID(machine: .cloud("a"), kind: .display, key: "display:1")
        state.configure(model: model, url: URL(string: "http://10.0.0.7:6901/vnc.html")!, resourceID: display)
        #expect(state.resourceID == display)
        state.leave()
        #expect(state.resourceID == nil)
        #expect(!state.retainsCloudResourceForDuplication)
    }

    @Test("An unavailable Cloud placeholder retains its resource for duplication")
    func unavailableCloudRetainsResourceIdentity() {
        let state = CloudBrowserAccessState()
        let model = CloudPortAccessModel(target: .init(host: "10.0.0.7", port: 6901), coordinator: nil,
            wake: {}, startForward: { _ in 46901 }, stopForward: {}, route: .loopback)
        let display = SurfaceResourceID(machine: .cloud("a"), kind: .display, key: "display:1")
        state.configure(model: model, url: URL(string: "http://10.0.0.7:6901/vnc.html")!, resourceID: display)
        state.showUnavailable("display unavailable")
        #expect(state.resourceID == display)
        #expect(state.retainsCloudResourceForDuplication)
        state.leave()
        #expect(state.resourceID == nil)
    }

    @Test("Leaving Cloud for an external page drops stale session provenance")
    func externalNavigationDropsCloudSessionResource() {
        let browser = BrowserPanel(workspaceId: UUID(), websiteDataStore: .nonPersistent())
        defer { browser.close() }
        let model = CloudPortAccessModel(target: .init(host: "10.0.0.7", port: 6902), coordinator: nil,
            wake: {}, startForward: { _ in 46902 }, stopForward: {}, route: .loopback)
        let display = SurfaceResourceID(machine: .cloud("a"), kind: .display, key: "display:2")
        browser.cloudAccess.configure(model: model, url: URL(string: "http://10.0.0.7:6902/vnc.html")!, resourceID: display)
        #expect(browser.cloudResourceForSession == display)
        browser.leaveCloudResourceForLocalNavigation()
        #expect(browser.cloudResourceForSession == nil)
    }

    @Test("A delayed Cloud restore keeps the saved path and query")
    func delayedCloudRestoreKeepsSavedURL() throws {
        let browser = BrowserPanel(workspaceId: UUID(), websiteDataStore: .nonPersistent())
        defer { browser.close() }
        browser.pendingCloudRestoreURL = try #require(URL(string: "http://10.0.0.7:8000/projects/123?tab=logs#tail"))
        let target = try #require(URL(string: "http://10.0.0.7:8000/"))
        #expect(browser.cloudRestoreURL(on: target).absoluteString == "http://10.0.0.7:8000/projects/123?tab=logs#tail")
    }

    @Test("Display restore ignores untrusted noVNC host and port query items")
    func displayRestoreFiltersTransportQuery() throws {
        let browser = BrowserPanel(workspaceId: UUID(), websiteDataStore: .nonPersistent())
        defer { browser.close() }
        let model = CloudPortAccessModel(target: .init(host: "10.0.0.7", port: 6902), coordinator: nil,
            wake: {}, startForward: { _ in 46902 }, stopForward: {}, route: .loopback)
        let display = SurfaceResourceID(machine: .cloud("a"), kind: .display, key: "display:2")
        browser.cloudAccess.configure(model: model, url: URL(string: "http://10.0.0.7:6902/vnc.html")!, resourceID: display)
        browser.pendingCloudRestoreURL = try #require(URL(string: "http://10.0.0.7:6902/vnc.html?host=evil.test&port=9999&path=websockify"))
        let target = try #require(URL(string: "http://10.0.0.7:6902/vnc.html?path=websockify"))
        let restored = browser.cloudRestoreURL(on: target)
        #expect(restored.host == "10.0.0.7" && restored.port == 6902)
        #expect(restored.query?.contains("host=") != true && restored.query?.contains("port=") != true)
        #expect(restored.query?.contains("path=websockify") == true)
    }

    @Test("A browser Cloud resource cannot retain ownership after its service port changes")
    func browserResourceOwnsOnlyItsPort() throws {
        let endpoint = CloudBrowserProxyEndpoint(host: "127.0.0.1", port: 48000, username: "u", password: "p")
        let model = CloudPortAccessModel(target: .init(host: "10.0.0.7", port: 3000), coordinator: nil,
            wake: {}, startForward: { _ in 47000 }, stopForward: {},
            startBrowserProxy: { endpoint })
        let state = CloudBrowserAccessState()
        state.configure(model: model, url: URL(string: "http://10.0.0.7:3000/")!,
                        resourceID: SurfaceResourceID(machine: .cloud("a"), kind: .browser, key: "port:3000"))
        #expect(state.owns(try #require(URL(string: "http://10.0.0.7:3000/"))))
        #expect(!state.owns(try #require(URL(string: "http://10.0.0.7:8000/"))))
    }

    @Test("A forwarded /vnc.html URL is not a display when its resource is a browser")
    func nonDisplayVNCPathDoesNotUseDesktopReadiness() {
        let state = CloudBrowserAccessState()
        let model = CloudPortAccessModel(target: .init(host: "10.0.0.7", port: 8000), coordinator: nil,
            wake: {}, startForward: { _ in 48000 }, stopForward: {}, route: .loopback)
        state.configure(model: model, url: URL(string: "http://10.0.0.7:8000/vnc.html")!,
                        resourceID: SurfaceResourceID(machine: .cloud("a"), kind: .browser, key: "port:8000"))
        #expect(!state.isDesktop)
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
