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
        #expect(http.route == .loopback && https.route == .privateNetwork)
        https.acceptTunnelState(.off)
        https.connect()
        #expect(https.phase == .needsVPN)
        #expect(https.failureMessage != nil)
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
}
