import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
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
        #expect(CloudPortRoutePlan.privateURL("https://localhost:8443/a%20b?q=%2F#frag", address: "fd12::7")?.absoluteString == "https://[fd12::7]:8443/a%20b?q=%2F#frag")
        #expect(CloudPortRoutePlan.privateURL("http://10.0.0.4:3000/path", address: "10.0.0.7")?.host == "10.0.0.7")
    }

    @Test("Explicit forwards preserve URL components and reject TLS host replacement")
    func explicitForwardURL() {
        #expect(CloudPortRoutePlan.localURL(rewriting: "http://10.0.0.7:3000/path?x=1#frag", toLoopbackPort: 41000)?.absoluteString == "http://127.0.0.1:41000/path?x=1#frag")
        #expect(CloudPortRoutePlan.localURL(rewriting: "https://10.0.0.7:8443", toLoopbackPort: 41000) == nil)
        #expect(CloudPortRoutePlan.localURL(rewriting: "file:///tmp/file", toLoopbackPort: 41000) == nil)
    }

    @Test("Opening and copying wait for VPN without creating a listener")
    func passiveOpenThenVPN() async {
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

    @Test("Forwarding is explicit, visible across panes, and can be stopped")
    func explicitForwardAndStop() async {
        var starts = 0
        var stops = 0
        let model = makeModel(forward: { _ in starts += 1; return 42000 }, stop: { stops += 1 })
        let store = CloudPortAccessStore()
        let first = store.model(machineID: "vm-1", target: model.target) { model }
        let second = store.model(machineID: "vm-1", target: model.target) { Issue.record("Duplicate port model"); return model }
        #expect(first === second)
        model.forward()
        #expect(await wait { model.phase == .forwarded(42000) })
        #expect(starts == 1 && model.localAddress == "127.0.0.1:42000")
        #expect(second.prefersForwarding)
        await model.stop()
        #expect(stops == 1 && model.localAddress == nil && model.phase == .needsVPN)
        await store.remove(machineID: "vm-1")
        #expect(model.phase == .closed && store.models.isEmpty)
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
        })
        model.forward()
        _ = await started.result
        await model.stop()
        resume.resolve(true)
        #expect(model.phase == .needsVPN && model.localAddress == nil)
        await model.retire()
    }

    private func makeModel(
        wake: @escaping @MainActor () async throws -> Void = {},
        forward: @escaping @MainActor (CloudPortForwardTarget) async throws -> UInt16 = { _ in 41000 },
        stop: @escaping @MainActor () async -> Void = {}
    ) -> CloudPortAccessModel {
        CloudPortAccessModel(machineID: "vm-1", target: CloudPortForwardTarget(host: "10.0.0.7", port: 3000), coordinator: nil, wake: wake, startForward: forward, stopForward: stop)
    }

    private func wait(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        return condition()
    }
}
