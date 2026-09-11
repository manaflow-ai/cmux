import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct SurfaceCatalogQueryServiceTests {
    @Test("A just-created machine is discovered before its seeded terminal is resolved")
    func refreshedReadDiscoversMissingCloudProvider() async throws {
        let catalog = SurfaceCatalog()
        let machine = SurfaceMachineID.cloud("vm-new")
        let provider = try CloudCatalogQueryTestProvider(machine: machine, catalog: catalog)
        var discoveries: [String] = []
        let query = SurfaceCatalogQueryService(catalog: catalog) { id in
            discoveries.append(id)
            catalog.register(provider)
        }

        // vm.create has returned, but the periodic fleet read has not registered
        // its provider. This is the surface.catalog request vm new uses next.
        #expect(catalog.provider(for: machine) == nil)
        let result = await query.read(machine: machine, refresh: true)

        #expect(discoveries == ["vm-new"])
        #expect(provider.forcedRefreshes == [true])
        #expect(result.catalog.machines.map(\.id) == [machine])
        #expect(result.catalog.resources.map(\.id.key) == ["term-seeded"])
        #expect(result.catalog.projections.isEmpty)
        // Both socket envelopes must support the same existing-terminal open;
        // an undiscovered provider used to make this return .unavailable.
        for cloudOnly in [false, true] {
            let payload = TerminalController.surfaceCatalogPayload(result, machine: machine, cloudOnly: cloudOnly)
            #expect(VMRemoteWorkspaceResolver().resolveVMMachineTerminal(machine: machine.rawValue, catalog: payload)
                == .resolved(workspaceID: "ws-1", terminalID: "term-seeded", tabID: "tab-1"))
        }
    }

    @Test("A cached catalog read does not discover or wake an unknown machine")
    func cachedReadRemainsReadOnly() async {
        let catalog = SurfaceCatalog()
        var discoveries: [String] = []
        let query = SurfaceCatalogQueryService(catalog: catalog) { discoveries.append($0) }

        let result = await query.read(machine: .cloud("vm-new"), refresh: false)

        #expect(discoveries.isEmpty)
        #expect(result.catalog == .empty)
    }

    @Test("Refreshing a known machine never waits on another machine's link")
    func knownProviderSkipsFleetDiscoveryAndOtherProviders() async throws {
        let catalog = SurfaceCatalog()
        let requested = try CloudCatalogQueryTestProvider(machine: .cloud("vm-requested"), catalog: catalog)
        let unrelated = try CloudCatalogQueryTestProvider(machine: .cloud("vm-unrelated"), catalog: catalog)
        catalog.register(requested)
        catalog.register(unrelated)
        var discoveries: [String] = []
        let query = SurfaceCatalogQueryService(catalog: catalog) { discoveries.append($0) }

        _ = await query.read(machine: requested.machine, refresh: true)

        #expect(discoveries.isEmpty)
        #expect(requested.forcedRefreshes == [true])
        #expect(unrelated.forcedRefreshes.isEmpty)
    }

    @Test("Failed discovery stays unavailable after one attempt and creates no resources")
    func failedDiscoveryDoesNotInventAnEmptyRemoteSession() async {
        let catalog = SurfaceCatalog()
        let machine = SurfaceMachineID.cloud("vm-missing")
        var discoveries: [String] = []
        let query = SurfaceCatalogQueryService(catalog: catalog) { discoveries.append($0) }

        let result = await query.read(machine: machine, refresh: true)
        let payload = TerminalController.surfaceCatalogPayload(result, machine: machine)

        #expect(discoveries == [machine.rawValue])
        #expect(result.catalog == .empty)
        #expect(VMRemoteWorkspaceResolver().resolveVMMachineTerminal(machine: machine.rawValue, catalog: payload) == .unavailable)
    }

    @Test("A missing local provider never triggers Cloud discovery")
    func localReadStaysLocal() async {
        let catalog = SurfaceCatalog()
        var discoveries: [String] = []
        let query = SurfaceCatalogQueryService(catalog: catalog) { discoveries.append($0) }

        _ = await query.read(machine: .local, refresh: true)

        #expect(discoveries.isEmpty)
    }

    @Test("An unfiltered refresh still refreshes the registered catalog")
    func unfilteredReadRefreshesKnownProviders() async throws {
        let catalog = SurfaceCatalog()
        let provider = try CloudCatalogQueryTestProvider(machine: .cloud("vm-known"), catalog: catalog)
        catalog.register(provider)
        var discoveries: [String] = []
        let query = SurfaceCatalogQueryService(catalog: catalog) { discoveries.append($0) }

        let result = await query.read(machine: nil, refresh: true)

        #expect(discoveries.isEmpty)
        #expect(provider.forcedRefreshes == [true])
        #expect(result.catalog.resources.count == 1)
    }
}
