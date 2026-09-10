import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct CmuxTuiSurfaceProviderRegistryDiscoveryTests {
    @Test("Discovering a new VM does not wait for another VM's blocked refresh")
    func missingProviderDiscoveryDoesNotWaitForUnrelatedLinks() async {
        let catalog = SurfaceCatalog()
        let olderRefreshStarted = CloudLinkFirstValue<Bool>()
        let releaseOlderRefresh = CloudLinkFirstValue<Bool>()
        let discoveryFinished = CloudLinkFirstValue<Bool>()
        var page = VMListPage(vms: [machine("vm-older")], limits: nil)
        var listCalls = 0
        var refreshed: [String] = []
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            wireGuardHub: nil,
            allowsBackgroundWork: { false },
            listPage: {
                listCalls += 1
                return page
            },
            refreshProvider: { provider, _ in
                refreshed.append(provider.machine.rawValue)
                if provider.machine == .cloud("vm-older") {
                    olderRefreshStarted.resolve(true)
                    _ = await releaseOlderRefresh.result
                }
            }
        )
        registry.start(catalog: catalog)
        let background = Task { await registry.refresh(force: false) }
        let started = await boundedResult(olderRefreshStarted)
        page = VMListPage(vms: [machine("vm-older"), machine("vm-new")], limits: nil)
        let discovery = Task {
            let found = await registry.providerRefreshingIfMissing(machineID: "vm-new")
            discoveryFinished.resolve(found != nil)
        }

        let completedBeforeOlderLink = await boundedResult(discoveryFinished)
        let refreshedBeforeRelease = refreshed
        // Always release the fixture before asserting, including on the red
        // revision, so a failed expectation cannot leave a task hanging.
        releaseOlderRefresh.resolve(true)
        await discovery.value
        _ = await background.value

        #expect(started)
        #expect(completedBeforeOlderLink)
        #expect(listCalls == 2)
        #expect(refreshedBeforeRelease == ["vm-older"])
        #expect(refreshed == ["vm-older"], "Discovery must not start link work for any provider")
        #expect(registry.provider(machineID: "vm-new") != nil)
        await registry.accessDidEnd()
    }

    @Test("Looking up a known provider neither lists machines nor refreshes links")
    func knownProviderLookupStaysLocal() async {
        let catalog = SurfaceCatalog()
        var lists = 0
        var refreshes = 0
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            wireGuardHub: nil,
            allowsBackgroundWork: { false },
            listPage: {
                lists += 1
                return VMListPage(vms: [machine("vm-known")], limits: nil)
            },
            refreshProvider: { _, _ in refreshes += 1 }
        )
        registry.start(catalog: catalog)
        _ = await registry.providerRefreshingIfMissing(machineID: "vm-known")
        let first = registry.provider(machineID: "vm-known")
        let again = await registry.providerRefreshingIfMissing(machineID: "vm-known")

        #expect(first != nil && first === again)
        #expect(lists == 1)
        #expect(refreshes == 0)
        await registry.accessDidEnd()
    }

    @Test("A failed machine list preserves existing providers without refreshing them")
    func discoveryFailureKeepsTheKnownCatalog() async {
        let catalog = SurfaceCatalog()
        var page: VMListPage? = VMListPage(vms: [machine("vm-known")], limits: nil)
        var refreshes = 0
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            wireGuardHub: nil,
            allowsBackgroundWork: { false },
            listPage: { page },
            refreshProvider: { _, _ in refreshes += 1 }
        )
        registry.start(catalog: catalog)
        _ = await registry.providerRefreshingIfMissing(machineID: "vm-known")
        page = nil

        let missing = await registry.providerRefreshingIfMissing(machineID: "vm-new")

        #expect(missing == nil)
        #expect(registry.provider(machineID: "vm-known") != nil)
        #expect(catalog.snapshot.machines.map(\.id) == [.cloud("vm-known")])
        #expect(refreshes == 0)
        await registry.accessDidEnd()
    }

    private func machine(_ id: String) -> VMSummary {
        VMSummary(id: id, provider: "freestyle", status: "running", image: "fixture", createdAt: 0, base: nil)
    }

    /// Wait on a signal with a failure deadline, never a settling delay.
    private func boundedResult(_ signal: CloudLinkFirstValue<Bool>) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await signal.result ?? false }
            group.addTask {
                try? await ContinuousClock().sleep(for: .seconds(2))
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
    }
}
