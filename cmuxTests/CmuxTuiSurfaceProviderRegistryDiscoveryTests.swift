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

    @Test("Retired registries reject new work even while background Cloud remains enabled")
    func signOutStopsAllNewDiscoveryUntilRestart() async {
        let catalog = SurfaceCatalog()
        var allowed = false
        var lists = 0
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            wireGuardHub: nil,
            allowsBackgroundWork: { allowed },
            listPage: {
                lists += 1
                return VMListPage(vms: [machine("vm-known")], limits: nil)
            },
            refreshProvider: { _, _ in }
        )
        registry.start(catalog: catalog)
        _ = await registry.providerRefreshingIfMissing(machineID: "vm-known")
        allowed = true
        await registry.accessDidEnd()
        registry.syncPollingToActivationPolicy()
        let pollingAfterSignOut = registry.isPolling
        allowed = false
        registry.syncPollingToActivationPolicy()

        #expect(!pollingAfterSignOut)
        #expect(await registry.providerRefreshingIfMissing(machineID: "vm-known") == nil)
        #expect(await registry.refresh(force: true) == false)
        #expect(lists == 1)
        #expect(catalog.snapshot == .empty)

        await registry.resumeAfterSignIn()
        #expect(await registry.providerRefreshingIfMissing(machineID: "vm-known") != nil)
        #expect(lists == 2)
        await registry.accessDidEnd()
    }

    @Test("A create overlapping an older fleet read gets a post-create discovery")
    func missingMachineWaitsForAFreshPage() async {
        let catalog = SurfaceCatalog()
        let requested = CloudLinkFirstValue<Bool>()
        let release = CloudLinkFirstValue<Bool>()
        let waiterStarted = CloudLinkFirstValue<Bool>()
        var lists = 0
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            wireGuardHub: nil,
            allowsBackgroundWork: { false },
            listPage: {
                lists += 1
                if lists == 1 {
                    requested.resolve(true)
                    _ = await release.result
                    return VMListPage(vms: [], limits: nil)
                }
                return VMListPage(vms: [machine("vm-new")], limits: nil)
            },
            refreshProvider: { _, _ in }
        )
        registry.start(catalog: catalog)
        let background = Task { await registry.refresh(force: false) }
        _ = await requested.result
        let discovery = Task {
            waiterStarted.resolve(true)
            return await registry.providerRefreshingIfMissing(machineID: "vm-new") != nil
        }
        _ = await waiterStarted.result
        release.resolve(true)

        #expect(await discovery.value)
        _ = await background.value
        #expect(lists == 2)
        await registry.accessDidEnd()
    }

    @Test("Sign-in waits for retiring transports before discovering another account")
    func signInWaitsForTeardown() async {
        let catalog = SurfaceCatalog()
        let closing = CloudLinkFirstValue<Bool>()
        let release = CloudLinkFirstValue<Bool>()
        let resuming = CloudLinkFirstValue<Bool>()
        var lists = 0
        var resumed = false
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            wireGuardHub: nil,
            allowsBackgroundWork: { false },
            listPage: {
                lists += 1
                return VMListPage(vms: [machine("vm-next-account")], limits: nil)
            },
            refreshProvider: { _, _ in },
            closeTransports: {
                closing.resolve(true)
                _ = await release.result
            }
        )
        registry.start(catalog: catalog)
        let retiring = Task { await registry.accessDidEnd() }
        _ = await closing.result
        let signIn = Task {
            resuming.resolve(true)
            await registry.resumeAfterSignIn()
            resumed = true
        }
        _ = await resuming.result
        #expect(!resumed)
        #expect(await registry.refresh(force: true) == false)
        #expect(await registry.providerRefreshingIfMissing(machineID: "vm-next-account") == nil)
        #expect(lists == 0)
        #expect(catalog.snapshot == .empty)
        release.resolve(true)
        await retiring.value
        await signIn.value
        #expect(await registry.providerRefreshingIfMissing(machineID: "vm-next-account") != nil)
        #expect(lists == 1)
        await registry.accessDidEnd()
    }

    @Test("A list that finishes after sign-out cannot register its machines")
    func signOutInvalidatesPendingDiscovery() async {
        let catalog = SurfaceCatalog()
        let requested = CloudLinkFirstValue<Bool>()
        let release = CloudLinkFirstValue<Bool>()
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            wireGuardHub: nil,
            allowsBackgroundWork: { false },
            listPage: {
                requested.resolve(true)
                _ = await release.result
                return VMListPage(vms: [machine("vm-late")], limits: nil)
            },
            refreshProvider: { _, _ in Issue.record("Retired discovery must not refresh a provider") }
        )
        registry.start(catalog: catalog)
        let discovery = Task { await registry.providerRefreshingIfMissing(machineID: "vm-late") }
        let started = await boundedResult(requested)

        await registry.accessDidEnd()
        release.resolve(true)
        let result = await discovery.value

        #expect(started)
        #expect(result == nil)
        #expect(catalog.snapshot == .empty)
    }

    @Test("Sign-out retires forced waiters before they can start another fleet read", arguments: [false, true])
    func signOutRetiresForcedWaiters(fullRefresh: Bool) async {
        let catalog = SurfaceCatalog()
        let requested = CloudLinkFirstValue<Bool>()
        let release = CloudLinkFirstValue<Bool>()
        let waiterStarted = CloudLinkFirstValue<Bool>()
        var lists = 0
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            wireGuardHub: nil,
            allowsBackgroundWork: { false },
            listPage: {
                lists += 1
                requested.resolve(true)
                _ = await release.result
                return VMListPage(vms: [machine("vm-retired")], limits: nil)
            },
            refreshProvider: { _, _ in Issue.record("Sign-out must retire waiting refreshes") }
        )
        registry.start(catalog: catalog)
        let first = Task { await registry.refresh(force: false) }
        let started = await boundedResult(requested)
        let waiter = Task {
            // This MainActor task enters the registry before the test resumes.
            waiterStarted.resolve(true)
            if fullRefresh { return await registry.refresh(force: true) }
            return await registry.providerRefreshingIfMissing(machineID: "vm-retired") != nil
        }
        let waiting = await boundedResult(waiterStarted)
        await registry.accessDidEnd()
        release.resolve(true)
        let firstResult = await first.value
        let waiterResult = await waiter.value

        #expect(started && waiting)
        #expect(!firstResult && !waiterResult)
        #expect(lists == 1, "A pre-sign-out waiter must not begin a new account operation")
        #expect(catalog.snapshot == .empty)
        await registry.accessDidEnd()
    }

    @Test("Missing-machine discovery leaves known providers to their owning refresh pass")
    func discoveryDoesNotRewriteAnUnrelatedProvider() async throws {
        let catalog = SurfaceCatalog()
        let started = CloudLinkFirstValue<Bool>()
        let release = CloudLinkFirstValue<Bool>()
        var older = machine("vm-older")
        older.displayName = "Original name"
        var page = VMListPage(vms: [older], limits: nil)
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            wireGuardHub: nil,
            allowsBackgroundWork: { false },
            listPage: { page },
            refreshProvider: { _, _ in
                started.resolve(true)
                _ = await release.result
            }
        )
        registry.start(catalog: catalog)
        let background = Task { await registry.refresh(force: false) }
        let refreshing = await boundedResult(started)
        older.displayName = "Updated name"
        page = VMListPage(vms: [older, machine("vm-new")], limits: nil)
        let found = await registry.providerRefreshingIfMissing(machineID: "vm-new")
        let nameDuringRefresh = registry.provider(machineID: "vm-older")?.info.name
        release.resolve(true)
        _ = await background.value

        #expect(refreshing && found != nil)
        #expect(nameDuringRefresh == "Original name", "Discovery must not invalidate a known provider's suspended snapshot work")
        _ = await registry.refresh(force: true)
        #expect(registry.provider(machineID: "vm-older")?.info.name == "Updated name")
        await registry.accessDidEnd()
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
