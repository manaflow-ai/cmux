import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A create response that already carries the machine's private address and attach
/// block registers a routable provider on the spot, so the first terminal never waits
/// for a fleet read or the attach endpoint.
@MainActor
@Suite(.serialized)
struct CmuxTuiSurfaceProviderRegistryCreationTests {
    private static let route = "ws://10.16.0.7:1337/v1/link"

    private func machine(_ id: String, ipv4: String? = nil, ipv6: String? = nil) -> VMSummary {
        var summary = VMSummary(id: id, provider: "freestyle", status: "running", image: "fixture", createdAt: 0, base: nil)
        summary.addressIPv4 = ipv4
        summary.addressIPv6 = ipv6
        return summary
    }

    private func attach(trustedCarrier: Bool, receivedAt: Date = Date()) -> VMCreateAttach {
        VMCreateAttach(
            route: Self.route, session: "cloud", trustedCarrier: trustedCarrier, daemonBuild: nil,
            guestToolsBaked: false, readiness: "dial", receivedAt: receivedAt
        )
    }

    private func fixture() -> (catalog: SurfaceCatalog, paths: CloudTuiClientPaths, links: CloudMachineLinkManager, registry: CmuxTuiSurfaceProviderRegistry, lists: () -> Int) {
        let catalog = SurfaceCatalog()
        let paths = CloudTuiClientPaths(home: URL(fileURLWithPath: "/tmp/cmux-registry-\(UUID().uuidString)"))
        let links = CloudMachineLinkManager(paths: paths, clientURL: nil, hub: nil, hostThemeColors: { nil })
        let counter = Counter()
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: links,
            allowsBackgroundWork: { false },
            listPage: { counter.increment(); return VMListPage(vms: [], limits: nil) },
            refreshProvider: { _, _ in true }
        )
        registry.start(catalog: catalog)
        return (catalog, paths, links, registry, { counter.value })
    }

    @Test("A receipt with addresses registers a provider, stores the route and the carrier marker, with zero fleet reads")
    func receiptWithAttachRegistersARoutableProviderWithoutDiscovery() async throws {
        let (catalog, paths, links, registry, lists) = fixture()
        defer { Task { await registry.accessDidEnd() } }
        let summary = machine("vm-fresh", ipv4: "10.16.0.7", ipv6: "fd00:4::7")
        let attach = attach(trustedCarrier: true)

        let provider = await registry.recordCreatedMachine(summary, attach: attach, scope: registry.creationScope)

        #expect(provider != nil)
        #expect(registry.provider(machineID: "vm-fresh") === provider)
        #expect(catalog.provider(for: .cloud("vm-fresh")) === provider)
        #expect(catalog.machines[.cloud("vm-fresh")]?.privateAddress == "10.16.0.7")
        #expect(lists() == 0)
        #expect(await registry.privateRoute(machineID: "vm-fresh") == Self.route)
        #expect(lists() == 0, "a registered receipt never triggers the fleet read the old open path needed")
        #expect(await links.privateAddresses(for: "vm-fresh") == ["10.16.0.7", "fd00:4::7"])
        #expect(paths.deviceFingerprint(for: "vm-fresh") == CloudTuiClientPaths.carrierDeviceMarker,
                "a trusted listener lets the first link dial --carrier without the attach endpoint")
        #expect(registry.cachedCreateAttach(machineID: "vm-fresh") == attach)
        #expect(registry.cachedCreateAttach(machineID: "vm-fresh", now: attach.receivedAt.addingTimeInterval(599)) == attach)
        #expect(registry.cachedCreateAttach(machineID: "vm-fresh", now: attach.receivedAt.addingTimeInterval(601)) == nil,
                "the CLI answers from this block only while it is fresh")

        // A stale fleet page must not prune the registration before discovery observes it.
        #expect(await registry.refresh(force: true))
        #expect(registry.provider(machineID: "vm-fresh") === provider)
        #expect(catalog.machines[.cloud("vm-fresh")] != nil)
        #expect(await links.privateRoute(for: "vm-fresh") == Self.route,
                "the stale page must not drop the route the create response supplied either")

        // A replay keeps the registered provider instead of replacing it.
        let replayed = await registry.recordCreatedMachine(summary, attach: attach, scope: registry.creationScope)
        #expect(replayed === provider)
        #expect(catalog.machines.count == 1)
    }

    @Test("An untrusted attach block registers the provider but leaves the control plane in charge of the first link")
    func untrustedAttachDoesNotSaveTheCarrierMarker() async throws {
        let (_, paths, _, registry, lists) = fixture()
        defer { Task { await registry.accessDidEnd() } }
        let provider = await registry.recordCreatedMachine(
            machine("vm-plain", ipv4: "10.16.0.8"), attach: attach(trustedCarrier: false), scope: registry.creationScope
        )
        #expect(provider != nil)
        #expect(paths.deviceFingerprint(for: "vm-plain") == nil)
        #expect(registry.cachedCreateAttach(machineID: "vm-plain")?.trustedCarrier == false)
        #expect(lists() == 0)
    }

    @Test("A receipt without addresses stays a friendly name until discovery, as before")
    func receiptWithoutAddressesRemainsAReceipt() async throws {
        let (catalog, paths, _, registry, lists) = fixture()
        defer { Task { await registry.accessDidEnd() } }
        var summary = machine("vm-nameonly")
        summary.slug = "bright-teal-otter"
        let provider = await registry.recordCreatedMachine(summary, attach: nil, scope: registry.creationScope)
        #expect(provider == nil)
        #expect(registry.provider(machineID: "vm-nameonly") == nil)
        #expect(catalog.snapshot.machines.first?.name == "bright-teal-otter")
        #expect(registry.cachedCreateAttach(machineID: "vm-nameonly") == nil)
        #expect(paths.deviceFingerprint(for: "vm-nameonly") == nil)
        #expect(lists() == 0)
    }

    @Test("Receipts from another account scope, or after teardown, register nothing")
    func receiptsRespectTheCreationScope() async throws {
        let (catalog, _, _, registry, _) = fixture()
        let scope = registry.creationScope
        await registry.accessDidEnd()
        let late = await registry.recordCreatedMachine(
            machine("vm-late", ipv4: "10.16.0.9"), attach: attach(trustedCarrier: true), scope: scope
        )
        #expect(late == nil)
        #expect(catalog.machines.isEmpty)
        #expect(registry.cachedCreateAttach(machineID: "vm-late") == nil)
        registry.start(catalog: catalog)
        let wrongScope = await registry.recordCreatedMachine(
            machine("vm-late", ipv4: "10.16.0.9"), attach: attach(trustedCarrier: true), scope: scope
        )
        #expect(wrongScope == nil)
        #expect(catalog.machines.isEmpty)
        await registry.accessDidEnd()
    }

    @Test("Deleting a machine drops its cached receipt with its provider")
    func deletionClearsTheCachedReceipt() async throws {
        let (_, _, _, registry, _) = fixture()
        defer { Task { await registry.accessDidEnd() } }
        _ = await registry.recordCreatedMachine(
            machine("vm-gone", ipv4: "10.16.0.10"), attach: attach(trustedCarrier: true), scope: registry.creationScope
        )
        #expect(registry.cachedCreateAttach(machineID: "vm-gone") != nil)
        registry.machineWasDeleted("vm-gone")
        #expect(registry.provider(machineID: "vm-gone") == nil)
        #expect(registry.cachedCreateAttach(machineID: "vm-gone") == nil)
    }

    /// Lock-free counter for the `listPage` closure, which runs on the main actor.
    @MainActor
    private final class Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }
}
