import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud port recovery", .timeLimit(.minutes(1)))
struct CloudPortRecoveryTests {
    @Test("Retry reads one machine's metadata and installs its current private route")
    func refreshMissingAddress() async throws {
        let catalog = SurfaceCatalog()
        let links = CloudMachineLinkManager(clientURL: nil, hostThemeColors: { nil })
        var requested: [String] = []
        let provider = CmuxTuiSurfaceProvider(summary: summary(), links: links, catalog: catalog,
            loadPortSummary: { id in
                requested.append(id)
                return summary(address: "10.0.0.7")
            })
        catalog.register(provider)
        #expect(provider.info.portDiscoveryState == .unavailable(.privateAddress))
        try await provider.refreshPortMetadata()
        #expect(requested == ["port-owner"])
        #expect(provider.info.privateAddress == "10.0.0.7")
        #expect(await links.privateAddresses(for: "port-owner") == ["10.0.0.7"])
        await provider.stop()
    }

    @Test("An explicit catalog refresh opts into demand-driven port discovery")
    func explicitRefreshRequestsDiscovery() async {
        let catalog = SurfaceCatalog()
        let links = CloudMachineLinkManager(clientURL: nil, hostThemeColors: { nil })
        let provider = CmuxTuiSurfaceProvider(
            summary: summary(address: "10.0.0.7"), links: links, catalog: catalog
        )
        catalog.register(provider)
        #expect(!provider.portDiscovery.mayScan)
        await catalog.refresh(machine: .cloud("port-owner"), force: true)
        #expect(provider.portDiscovery.mayScan)
        await provider.stop()
    }

    @Test("A metadata result from before retirement cannot revive a provider")
    func lateMetadataIsRejected() async throws {
        let catalog = SurfaceCatalog()
        let links = CloudMachineLinkManager(clientURL: nil, hostThemeColors: { nil })
        let started = CloudLinkFirstValue<Bool>()
        let resume = CloudLinkFirstValue<Bool>()
        let provider = CmuxTuiSurfaceProvider(summary: summary(), links: links, catalog: catalog,
            loadPortSummary: { _ in
                started.resolve(true)
                _ = await resume.result
                return summary(address: "10.0.0.7")
            })
        catalog.register(provider)
        let refresh = Task { try await provider.refreshPortMetadata() }
        _ = await started.result
        await provider.stop()
        resume.resolve(true)
        do {
            try await refresh.value
            Issue.record("A retired provider accepted a late machine summary")
        } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(provider.info.privateAddress == nil)
        #expect(await links.privateAddresses(for: "port-owner").isEmpty)
    }

    @Test("A foreign summary never changes the machine's address")
    func foreignMetadataIsRejected() async {
        let catalog = SurfaceCatalog()
        let links = CloudMachineLinkManager(clientURL: nil, hostThemeColors: { nil })
        let provider = CmuxTuiSurfaceProvider(summary: summary(), links: links, catalog: catalog,
            loadPortSummary: { _ in summary(id: "foreign", address: "10.0.0.8") })
        catalog.register(provider)
        do {
            try await provider.refreshPortMetadata()
            Issue.record("A foreign summary was accepted")
        } catch {}
        #expect(provider.info.privateAddress == nil)
        #expect(await links.privateAddresses(for: "port-owner").isEmpty)
        await provider.stop()
    }

    @Test("Leaving a failed route cancels and fences its pending retry")
    func retryCannotOverrideNewNavigation() async {
        let state = CloudBrowserAccessState()
        let started = CloudLinkFirstValue<Bool>()
        let resume = CloudLinkFirstValue<Bool>()
        let finished = CloudLinkFirstValue<Bool>()
        var published = false
        state.showUnavailable("Missing address") { [weak state] request in
            started.resolve(true)
            _ = await resume.result
            if state?.isCurrentUnavailableRetry(request) == true { published = true }
            finished.resolve(true)
        }
        state.retryUnavailable()
        _ = await started.result
        state.leave()
        resume.resolve(true)
        _ = await finished.result
        #expect(!published && state.unavailable == nil && state.unavailableRetryAction == nil)
    }

    @Test("In-app proxy access ignores every system VPN phase", arguments: [
        CloudTunnelState.off, .starting, .awaitingApproval, .up, .stopping, .failed("VPN denied")
    ])
    func vpnDoesNotGatePort(_ vpn: CloudTunnelState) async {
        var attempts = 0
        let model = CloudPortAccessModel(target: CloudPortForwardTarget(host: "10.0.0.7", port: 3000),
            coordinator: nil, wake: {}, startForward: { _ in Issue.record("Unexpected system forward"); return 1 },
            stopForward: {}, startBrowserProxy: {
                attempts += 1
                if attempts == 1 { throw URLError(.cannotConnectToHost) }
                return CloudBrowserProxyEndpoint(host: "127.0.0.1", port: 42001, username: "fixture", password: "fixture")
            })
        model.acceptTunnelState(vpn)
        model.connectBrowser()
        #expect(await wait { model.failureMessage != nil })
        model.retry()
        #expect(await wait { model.isReady })
        #expect(attempts == 2 && model.usesBrowserProxy)
        model.acceptTunnelState(.off)
        #expect(model.isReady)
        await model.retire()
    }

    private func summary(id: String = "port-owner", address: String? = nil) -> VMSummary {
        VMSummary(id: id, provider: "freestyle", status: "running", image: "fixture", createdAt: 0,
            base: nil, addressIPv4: address)
    }

    private func wait(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        return condition()
    }
}
