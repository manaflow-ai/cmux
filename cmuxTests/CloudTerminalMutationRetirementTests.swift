import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud terminal retirement regression", .timeLimit(.minutes(1)))
struct CloudTerminalMutationRetirementTests {
    @Test("Suspension cancels an admitted turn before it can mutate the machine")
    func suspensionCancelsAnAdmittedMutation() async {
        let catalog = SurfaceCatalog()
        let provider = CmuxTuiSurfaceProvider(
            summary: VMSummary(
                id: "retirement-\(UUID())", provider: "freestyle", status: "running",
                image: "fixture", createdAt: 0, base: nil
            ),
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            catalog: catalog
        )
        catalog.register(provider)
        defer {
            provider.suspendForFeatureFlag()
            catalog.unregister(machine: provider.machine)
        }
        var mutated = false
        let admitted = provider.terminalMutationQueue.enqueue { mutated = true }
        provider.suspendForFeatureFlag()
        #expect(admitted.isCancelled)
        await #expect(throws: CancellationError.self) { try await admitted.value }
        #expect(!mutated)
    }
}
