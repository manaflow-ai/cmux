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
