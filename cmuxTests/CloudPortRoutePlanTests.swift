import CmuxCloudBannerCore
import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CloudPortRoutePlanTests {
    private let machine = SurfaceMachineID.cloud("vm-1")

    @Test("A port open uses the private address without starting forwarding")
    func privateAddressIsDefault() {
        let resource = CmuxTuiSnapshotParser.portBrowser(machine: machine, port: 3000)
        #expect(CloudPortRoutePlan.plan(resource: resource, privateAddress: "10.0.0.7") == .privateDirect(remoteURL: "http://10.0.0.7:3000"))
    }

    @Test("Missing private addresses never fall back to a public or local forward")
    func noAutomaticFallback() {
        let resource = CmuxTuiSnapshotParser.portBrowser(machine: machine, port: 3000)
        guard case .unsupported = CloudPortRoutePlan.plan(resource: resource, privateAddress: nil) else {
            Issue.record("A missing private address must show connection guidance")
            return
        }
    }

    @Test("Private routing keeps paths, ports, queries, and fragments")
    func privateURLKeepsComponents() {
        let policy = CloudPortRoutePolicy()
        #expect(policy.privateURL("https://localhost:8443/a%20b?q=%2F#frag", address: "fd12::7")?.absoluteString == "https://[fd12::7]:8443/a%20b?q=%2F#frag")
        #expect(policy.privateURL("http://10.0.0.4:3000/path", address: "10.0.0.7")?.host == "10.0.0.7")
    }

    @Test("Explicit forwards preserve URL components and reject TLS host replacement")
    func explicitForwardURL() {
        let policy = CloudPortRoutePolicy()
        #expect(policy.localURL(rewriting: "http://10.0.0.7:3000/path?x=1#frag", toLoopbackPort: 41000)?.absoluteString == "http://127.0.0.1:41000/path?x=1#frag")
        #expect(policy.localURL(rewriting: "https://10.0.0.7:8443", toLoopbackPort: 41000) == nil)
        #expect(policy.localURL(rewriting: "file:///tmp/file", toLoopbackPort: 41000) == nil)
    }

    @Test("Direct private access waits for VPN without creating a listener")
    func privateRouteWaitsForVPN() async {
        var forwards = 0
        var wakes = 0
        let model = makeModel(wake: { wakes += 1 }, forward: { _ in forwards += 1; return 41000 })
        let page = CloudBrowserAccessState()
        page.configure(model: model, url: URL(string: "http://10.0.0.7:3000/path")!)
        #expect(!page.showsPage)
        #expect(page.nextURL() == nil)
        #expect(forwards == 0 && wakes == 0)
        model.acceptTunnelState(.up)
        #expect(await wait { model.phase == .direct })
        #expect(wakes == 1 && forwards == 0)
        let url = page.nextURL()
        #expect(url?.absoluteString == "http://10.0.0.7:3000/path")
        #expect(!page.showsPage, "Native loading UI remains until WebKit finishes")
        page.didCommit(url: url)
        page.didFinish(url: url)
        #expect(page.showsPage)
        model.acceptTunnelState(.off)
        #expect(!page.showsPage && page.nextURL() == nil)
        #expect(forwards == 0)
        await model.retire()
    }

    @Test("Forwarding is shared across panes and can be stopped")
    func explicitForwardAndStop() async {
        var starts = 0
        var stops = 0
        let model = makeModel(forward: { _ in starts += 1; return 42000 }, stop: { stops += 1 }, route: .loopback)
        let store = CloudPortAccessStore()
        let first = store.model(machineID: "vm-1", target: model.target) { model }
        let second = store.model(machineID: "vm-1", target: model.target) { Issue.record("Duplicate port model"); return model }
        #expect(first === second)
        model.connect()
        #expect(await wait { model.phase == .forwarded(42000) })
        #expect(starts == 1 && model.localAddress == "127.0.0.1:42000")
        #expect(second.route == .loopback)
        await model.stop()
        #expect(stops == 1 && model.localAddress == nil && model.phase == .needsVPN)
        await store.remove(machineID: "vm-1")
        #expect(model.phase == .closed && store.models.isEmpty)
    }

    @Test("HTTP and HTTPS panes do not share an HTTP-only access state")
    func accessModelsSeparateSchemes() {
        let store = CloudPortAccessStore()
        let target = CloudPortForwardTarget(host: "10.0.0.7", port: 8443)
        let http = store.model(machineID: "vm-1", target: target, scheme: "http") {
            makeModel(port: 8443)
        }
        let https = store.model(machineID: "vm-1", target: target, scheme: "https") {
            makeModel(port: 8443)
        }
        #expect(http !== https)
        #expect(store.models.count == 2)
    }

    @Test("Proxy models separate origins on the same machine and port")
    func accessModelsSeparateTargetHosts() {
        let store = CloudPortAccessStore()
        let privateOrigin = store.model(
            machineID: "vm-1",
            target: CloudPortForwardTarget(host: "10.0.0.7", port: 8443),
            scheme: "https"
        ) { makeModel(port: 8443) }
        let loopbackOrigin = store.model(
            machineID: "vm-1",
            target: CloudPortForwardTarget(host: "localhost", port: 8443),
            scheme: "https"
        ) { makeModel(port: 8443) }
        #expect(privateOrigin !== loopbackOrigin)
        #expect(store.models.count == 2)
    }

    @Test("Desktop can use the authenticated loopback forward while VPN is off")
    func desktopForwardWorksWithoutVPN() async throws {
        var wakes = 0
        var starts = 0
        let model = makeModel(port: CmuxTuiSnapshotParser.desktopPort, wake: { wakes += 1 }, forward: { _ in
            starts += 1
            return 46_901
        }, route: .loopback)
        let page = CloudBrowserAccessState()
        let remote = URL(string: CmuxTuiSurfaceProvider.privateDesktopURL(privateAddress: "10.0.0.7"))!
        page.configure(model: model, url: remote)
        model.connect()

        #expect(await wait { model.phase == .forwarded(46_901) })
        #expect(wakes == 1 && starts == 1)
        let local = try #require(page.nextURL())
        #expect(local.host == "127.0.0.1")
        #expect(local.port == 46_901)
        #expect(local.path == "/vnc.html")
        #expect(local.query?.contains("path=websockify") == true)
        #expect(local.query?.contains("reconnect_delay=2000") == true)
        await model.retire()
    }

    @Test("Cloud loopback browsers keep the machine-local origin across forwarding")
    func cloudLoopbackBrowserKeepsOrigin() async throws {
        let model = makeModel(forward: { _ in 46_902 }, route: .loopback)
        let state = CloudBrowserAccessState()
        let remote = try #require(URL(string: "http://localhost:4312/health?check=1"))
        state.configure(model: model, url: remote)
        model.connect()
        #expect(await wait { model.phase == .forwarded(46_902) })
        let local = try #require(state.nextURL())
        #expect(local.host == "127.0.0.1")
        #expect(local.port == 46_902)
        state.didCommit(url: local)
        state.didFinish(url: local)
        #expect(state.owns(local))
        #expect(state.sessionURL(currentURL: local) == remote)
        await model.retire()
    }

    @Test("Cloud HTTPS localhost uses the authenticated proxy and keeps its origin")
    func cloudHTTPSLoopbackBrowserKeepsOrigin() async throws {
        let endpoint = CloudBrowserProxyEndpoint(
            host: "127.0.0.1", port: 46_903, username: "fixture", password: "secret"
        )
        let model = CloudPortAccessModel(
            target: CloudPortForwardTarget(host: "localhost", port: 8443),
            coordinator: nil,
            wake: {},
            startForward: { _ in Issue.record("HTTPS localhost must not use the HTTP-only forward"); return 46_904 },
            stopForward: {},
            route: .browserProxy,
            startBrowserProxy: { endpoint },
            preservesRemoteHost: true
        )
        let remote = try #require(URL(string: "https://localhost:8443/health"))
        model.connect()
        #expect(await wait { model.phase == .proxied(endpoint) })
        #expect(model.url(for: remote) == remote)
        await model.retire()
    }

    @Test("Cloud HTTP localhost uses the guest browser carrier instead of a Mac listener")
    func cloudHTTPLoopbackUsesAuthenticatedBrowserCarrier() async throws {
        let endpoint = CloudBrowserProxyEndpoint(
            host: "127.0.0.1", port: 46_905, username: "fixture", password: "secret"
        )
        let model = CloudPortAccessModel(
            target: CloudPortForwardTarget(host: "cmux-loopback.localtest.me", port: 3000),
            coordinator: nil,
            wake: {},
            startForward: { _ in Issue.record("Cloud HTTP localhost must not create a Mac listener"); return 46_906 },
            stopForward: {},
            route: .remoteBrowser,
            startBrowserProxy: { endpoint },
            preservesRemoteHost: true
        )
        let state = CloudBrowserAccessState()
        let remote = try #require(URL(string: "http://localhost:3000/"))
        state.configure(model: model, url: remote, resourceID: SurfaceResourceID(
            machine: .cloud("cloud-http-fixture"), kind: .browser, key: "browser-session"
        ))
        model.connect()
        #expect(await wait { model.phase == .proxied(endpoint) })
        #expect(model.usesRemoteNetwork)
        let wireURL = try #require(state.nextURL())
        #expect(wireURL.host == "cmux-loopback.localtest.me")
        #expect(state.owns(wireURL))
        state.didCommit(url: wireURL)
        state.didFinish(url: wireURL)
        #expect(state.sessionURL(currentURL: wireURL) == remote)
        await model.retire()
    }

    @Test("Cloud daemon browsers keep a public origin through the machine carrier")
    func cloudDaemonBrowserKeepsPublicOrigin() async throws {
        let endpoint = CloudBrowserProxyEndpoint(
            host: "127.0.0.1", port: 46_907, username: "fixture", password: "secret"
        )
        let model = CloudPortAccessModel(
            target: CloudPortForwardTarget(host: "example.com", port: 4312),
            coordinator: nil,
            wake: {},
            startForward: { _ in Issue.record("Daemon browser must not use a local forward"); return 46_906 },
            stopForward: {},
            route: .remoteBrowser,
            startBrowserProxy: { endpoint },
            preservesRemoteHost: true
        )
        let remote = try #require(URL(string: "http://example.com:4312/health"))
        let state = CloudBrowserAccessState()
        state.configure(model: model, url: remote)
        model.connect()
        #expect(await wait { model.phase == .proxied(endpoint) })
        #expect(state.nextURL() == remote)
        await model.retire()
    }

    @Test("An explicit direct route preserves the document origin")
    func directRouteKeepsPublicOrigin() async throws {
        let model = CloudPortAccessModel(
            target: .init(host: "10.0.0.7", port: 443), coordinator: nil,
            wake: {}, startForward: { _ in throw CancellationError() }, stopForward: {},
            route: .direct
        )
        let remote = try #require(URL(string: "https://example.test/document?source=direct#section"))
        model.connect()
        #expect(await wait { model.isReady })
        #expect(model.url(for: remote) == remote)
        await model.retire()
    }

    @Test("A daemon browser saves guest localhost after navigating from a public page",
          arguments: ["http", "https"])
    func publicPageToLocalhostKeepsGuestOrigin(scheme: String) async throws {
        let endpoint = CloudBrowserProxyEndpoint(
            host: "127.0.0.1", port: 46_908, username: "fixture", password: "secret"
        )
        let model = CloudPortAccessModel(
            target: .init(host: "example.test", port: 443), coordinator: nil,
            wake: {}, startForward: { _ in throw CancellationError() }, stopForward: {},
            route: .remoteBrowser, startBrowserProxy: { endpoint }, preservesRemoteHost: true
        )
        let resource = SurfaceResourceID(machine: machine, kind: .browser, key: "browser-navigate")
        let state = CloudBrowserAccessState()
        let initial = try #require(URL(string: "\(scheme)://example.test/start"))
        state.configure(model: model, url: initial, resourceID: resource)
        model.connect()
        #expect(await wait { model.isReady })
        let first = try #require(state.nextURL())
        state.didCommit(url: first)
        state.didFinish(url: first)
        let guest = try #require(URL(string: "http://localhost:3000/page?step=2#result"))
        let wire = try #require(state.rewrittenLoopbackURL(guest))
        #expect(wire.host == "cmux-loopback.localtest.me")
        #expect(state.displayURL(wire) == guest)
        state.didStart(url: wire)
        state.didCommit(url: wire)
        state.didFinish(url: wire)
        #expect(state.remoteURL == guest)
        #expect(state.sessionURL(currentURL: wire) == guest)
        #expect(state.resourceID == resource)
        #expect(state.showsPage)
        state.leave()
        await model.retire()
    }

    @Test("SSH forward readiness preserves the submitted request")
    func forwardedRequestKeepsMethodHeadersAndBody() async throws {
        var listenerPort: UInt16 = 46_902
        let model = makeModel(forward: { _ in listenerPort }, route: .loopback)
        let state = CloudBrowserAccessState()
        let remote = URL(string: "http://10.0.0.7:3000/submit")!
        var request = URLRequest(url: remote)
        request.httpMethod = "POST"
        request.httpBody = Data("name=cmux".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        state.configure(model: model, url: remote, request: request)
        var navigations: [URLRequest] = []
        state.automaticallyNavigateRequest { request in
            navigations.append(request)
            // BrowserPanel records even the readiness callback's request
            // before WebKit starts, commits, and finishes the navigation.
            state.rememberNavigationRequest(request)
            state.didStart(url: request.url)
            state.didCommit(url: request.url)
            state.didFinish(url: request.url)
        }

        model.connect()
        #expect(await wait { navigations.count == 1 })
        let forwarded = try #require(navigations.first)
        #expect(forwarded.url?.host == "127.0.0.1")
        #expect(forwarded.url?.port == 46_902)
        #expect(forwarded.httpMethod == "POST")
        #expect(forwarded.httpBody == Data("name=cmux".utf8))
        #expect(forwarded.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(state.showsPage)
        #expect(state.sessionURL(currentURL: forwarded.url) == remote)
        #expect(state.nextRequest() == nil)

        // A dead SSH child is replaced on a new listener. The route must
        // replay the same request template instead of silently downgrading it
        // to a GET with no body.
        listenerPort = 46_904
        model.retry()
        #expect(await wait { navigations.count == 2 })
        let replayed = try #require(navigations.last)
        #expect(state.isRetiredListener(forwarded.url!), "A forward restart must retain the previous listener identity")
        #expect(!state.owns(forwarded.url!), "A retired listener must not retain the current route's ownership")
        #expect(state.owns(remote))
        #expect(!state.owns(URL(string: "http://10.0.0.8:3000/submit")!))
        #expect(!state.owns(URL(string: "http://10.0.0.7:3001/submit")!))
        #expect(replayed.url?.port == 46_904)
        #expect(replayed.httpMethod == "POST")
        #expect(replayed.httpBody == Data("name=cmux".utf8))
        #expect(replayed.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")

        // A later user navigation replaces the replay template, so recovery
        // cannot resurrect the earlier form submission.
        let followUp = URLRequest(url: URL(string: "http://10.0.0.7:3000/other?q=next#section")!)
        state.rememberNavigationRequest(followUp)
        state.didStart(url: followUp.url)
        state.didCommit(url: followUp.url)
        state.didFinish(url: followUp.url)
        #expect(state.showsPage)
        #expect(state.sessionURL(currentURL: followUp.url)?.absoluteString == "http://10.0.0.7:3000/other?q=next#section")
        #expect(state.nextRequest() == nil)
        listenerPort = 46_905
        model.retry()
        #expect(await wait { navigations.count == 3 })
        let latest = try #require(navigations.last)
        #expect(latest.url?.port == 46_905)
        #expect(latest.url?.path == "/other")
        #expect(latest.url?.query == "q=next")
        #expect(latest.url?.fragment == "section")
        #expect(latest.httpMethod == "GET")
        #expect(latest.httpBody == nil)
        #expect(state.showsPage)
        await model.retire()
    }

    @Test("SSH loopback aliases keep ownership of the ready service")
    func loopbackAliasesShareServiceIdentity() async throws {
        let model = makeModel(forward: { _ in 46_903 }, route: .loopback)
        let state = CloudBrowserAccessState()
        state.configure(model: model, url: URL(string: "http://127.0.0.1:3000")!)
        #expect(state.remoteURL?.absoluteString == "http://localhost:3000")
        model.connect()
        #expect(await wait { model.isReady })
        let listener = try #require(state.nextURL())
        #expect(state.owns(listener))
        #expect(state.owns(URL(string: "http://localhost:3000")!))
        #expect(state.owns(URL(string: "http://[::1]:3000")!))
        #expect(!state.owns(URL(string: "http://localhost:3001")!))
        #expect(!state.owns(URL(string: "https://localhost:3000")!))
        #expect(!state.owns(URL(string: "http://example.test:3000")!))
        #expect(!state.owns(URL(string: "http://example.test:46903")!))
        await model.retire()
    }

    @Test("A freshly forwarded listener keeps the logical URL before navigation bookkeeping")
    func displayURLMapsCurrentListenerBeforeNavigationIsRecorded() async throws {
        let model = makeModel(forward: { _ in 51_629 }, route: .loopback)
        let state = CloudBrowserAccessState()
        let logical = URL(string: "http://localhost:3000/projects/123?tab=logs#tail")!
        state.configure(model: model, url: logical)
        model.connect()
        #expect(await wait { model.phase == .forwarded(51_629) })

        let listener = URL(string: "http://127.0.0.1:51629/projects/123?tab=logs#tail")!
        #expect(state.displayURL(listener) == logical)
        await model.retire()
    }

    @Test("The omnibar and session history show the SSH service, not its forward listener")
    func panelLiveURLReadersShowLogicalSSHService() async throws {
        let model = makeModel(port: 3500, forward: { _ in 50_604 }, route: .loopback)
        let panel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false)
        // A terminal link printed by `python3 -m http.server 3500`.
        panel.cloudAccess.configure(model: model, url: URL(string: "http://[::]:3500/")!)
        model.connect()
        #expect(await wait { model.phase == .forwarded(50_604) })
        _ = try #require(panel.cloudAccess.nextRequest())

        // WebKit's live URL is the local listener. Every chrome reader of it
        // (omnibar text, focus/edit buffer, reload, session history) must keep
        // the stable service origin the user would see on the SSH host.
        let listener = URL(string: "http://127.0.0.1:50604/docs/?q=1")!
        #expect(panel.restorableDisplayURLForCurrentErrorPage(liveURL: listener)?.absoluteString
            == "http://localhost:3500/docs/?q=1")
        await model.retire()
    }

    @Test("HTTP stays on the authenticated hub across every system VPN state",
          arguments: [CloudTunnelState.off, .awaitingApproval, .starting, .up, .stopping, .failed("VPN failed")])
    func httpIsIndependentOfVPN(state: CloudTunnelState) async {
        var starts = 0
        let model = makeModel(forward: { _ in starts += 1; return 42_000 }, route: .loopback)
        model.acceptTunnelState(state)
        model.connect()
        #expect(await wait { model.phase == .forwarded(42_000) })
        model.acceptTunnelState(.off)
        model.connect()
        #expect(model.phase == .forwarded(42_000) && starts == 1)
        await model.retire()
    }

    @Test("Retry recovers a failed HTTP connection without changing its transport")
    func retryFailedForward() async {
        var starts = 0
        let model = makeModel(forward: { _ in
            starts += 1
            if starts == 1 { throw TestForwardError.unavailable }
            return 42_000
        }, route: .loopback)
        model.connect()
        #expect(await wait { model.failureMessage != nil })
        model.acceptTunnelState(.up)
        #expect(model.failureMessage != nil)
        model.retry()
        #expect(await wait { model.phase == .forwarded(42_000) })
        #expect(starts == 2)
        await model.retire()
    }

    @Test("HTTPS never creates a listener when its private network disconnects")
    func httpsKeepsCertificateIdentity() async {
        var starts = 0
        let model = makeModel(forward: { _ in starts += 1; return 42_000 })
        model.acceptTunnelState(.up)
        #expect(await wait { model.phase == .direct })
        model.acceptTunnelState(.off)
        model.retry()
        #expect(model.phase == .needsVPN && starts == 0)
        model.acceptTunnelState(.up)
        #expect(await wait { model.phase == .direct })
        await model.retire()
    }

    @Test("A failed load returns to native connection UI")
    func failedLoadShowsControls() async {
        let model = makeModel()
        model.acceptTunnelState(.up)
        #expect(await wait { model.phase == .direct })
        let state = CloudBrowserAccessState()
        let url = URL(string: "http://10.0.0.7:3000")!
        state.configure(model: model, url: url)
        _ = state.nextURL()
        state.didFail(url: url, message: "Connection refused")
        #expect(!state.showsPage && state.error == "Connection refused")
        state.retry()
        #expect(state.error == nil)
        await model.retire()
    }

    @Test("An unavailable route exposes a retry action")
    func unavailableRouteCanRetry() async {
        var retries = 0
        let state = CloudBrowserAccessState()
        state.showUnavailable("Private address unavailable", retry: { _ in retries += 1 })
        #expect(state.unavailableRetryAction != nil)
        state.unavailableRetryAction?()
        #expect(await wait { retries == 1 })
    }

    @Test("A canceled forward cannot publish a late local address")
    func stopDuringStart() async {
        let started = CloudLinkFirstValue<Bool>()
        let resume = CloudLinkFirstValue<Bool>()
        let model = makeModel(forward: { _ in
            started.resolve(true)
            _ = await resume.result
            return 43000
        }, route: .loopback)
        model.connect()
        _ = await started.result
        let stopping = Task { await model.stop() }
        #expect(await wait { model.phase == .stopping })
        resume.resolve(true)
        await stopping.value
        #expect(model.phase == .needsVPN && model.localAddress == nil)
        await model.retire()
    }

    @Test("Cloud browser opening starts app-owned access without a system VPN")
    func cloudBrowserStartsUserspaceAccess() async throws {
        let live = LiveWorkspaceFixture()
        defer { live.tearDown() }
        let catalog = SurfaceCatalog(live: live)
        let links = CloudMachineLinkManager(clientURL: nil, hostThemeColors: { nil })
        let provider = CmuxTuiSurfaceProvider(
            summary: VMSummary(id: "vm-userspace", provider: "freestyle", status: "running", image: "fixture", createdAt: 0, base: nil, addressIPv4: "10.16.0.7"),
            links: links,
            catalog: catalog
        )
        catalog.register(provider)
        let panel = BrowserPanel(workspaceId: live.id(), websiteDataStore: .nonPersistent())
        defer { panel.close() }
        provider.configureBrowser(panel, url: URL(string: "http://10.16.0.7:8000/path?q=1#fragment")!)
        let model = try #require(panel.cloudAccess.model)
        #expect(model.phase == .connecting, "Opening a Cloud port must start userspace access, never wait for VPN approval")
        #expect(panel.currentURL?.absoluteString == "http://10.16.0.7:8000/path?q=1#fragment")
        await provider.stop()
    }

    @Test("Userspace pages ignore system VPN changes and share an existing connection")
    func userspaceAccessIsIndependentOfVPN() async throws {
        var starts = 0
        let endpoint = CloudBrowserProxyEndpoint(host: "127.0.0.1", port: 42001, username: "fixture", password: "secret")
        let model = CloudPortAccessModel(
            target: CloudPortForwardTarget(host: "10.16.0.7", port: 8000),
            coordinator: nil, wake: {}, startForward: { _ in Issue.record("Browser opened explicit forward"); return 42002 },
            stopForward: {}, startBrowserProxy: { starts += 1; return endpoint }
        )
        model.connectBrowser()
        #expect(await wait { model.isReady })
        #expect(starts == 1)
        model.acceptTunnelState(.off)
        model.acceptTunnelState(.failed("System VPN unavailable"))
        #expect(model.isReady)
        let url = try #require(URL(string: "http://10.16.0.7:8000/a?q=1#part"))
        #expect(model.url(for: url) == url)
        #expect(model.localAddress == nil)
        model.connectBrowser()
        #expect(starts == 1, "Opening a second pane must not reconnect the first")
        model.retry()
        #expect(await wait { starts == 2 && model.isReady })
        await model.retire()
        #expect(!model.isReady)
    }

    private func makeModel(
        port: Int = 3000,
        coordinator: CloudTunnelCoordinator? = nil,
        wake: @escaping @MainActor () async throws -> Void = {},
        forward: @escaping @MainActor (CloudPortForwardTarget) async throws -> UInt16 = { _ in 41000 },
        stop: @escaping @MainActor () async -> Void = {},
        route: CloudPortAccessRoute = .privateNetwork
    ) -> CloudPortAccessModel {
        CloudPortAccessModel(target: CloudPortForwardTarget(host: "10.0.0.7", port: port), coordinator: coordinator, wake: wake, startForward: forward, stopForward: stop, route: route)
    }

    private enum TestForwardError: Error { case unavailable }

    private func wait(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        return condition()
    }
}
