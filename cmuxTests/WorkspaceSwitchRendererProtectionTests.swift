import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct WorkspaceSwitchRendererProtectionTests {
    @Test
    func rendererProtectionOwnerExpiresWithCoordinator() {
        var ownerIsAlive: (() -> Bool)?
        var coordinator: WorkspaceSwitchCoordinator? = WorkspaceSwitchCoordinator(
            beginRendererProtection: { _, _, liveness in
                ownerIsAlive = liveness
            },
            endRendererProtection: { _ in }
        )
        coordinator?.selectionWillCommit(
            from: UUID(), to: UUID(),
            targetSurfaceID: UUID(),
            targetTerminalView: nil,
            targetRendererPresented: true, targetRenderedFrameSequence: 1
        )

        #expect(ownerIsAlive?() == true)
        coordinator = nil

        #expect(ownerIsAlive?() == false)
    }

    @Test
    func presentationProtectedRendererConsumesWarmSlotAndIsNeverSelected() {
        let now: TimeInterval = 1_000
        let warmSurfaceID = UUID()
        let reclaimableSurfaceID = UUID()
        let switchTargetID = UUID()
        let settings = RendererRealizationSettings.Values(
            enabled: true,
            idleSeconds: 5,
            maxWarmRenderers: 1
        )
        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: [
                RendererRealizationPlannerInput(
                    surfaceId: warmSurfaceID,
                    isVisible: false,
                    isRealized: true,
                    lastVisibleAt: now - 10
                ),
                RendererRealizationPlannerInput(
                    surfaceId: reclaimableSurfaceID,
                    isVisible: false,
                    isRealized: true,
                    lastVisibleAt: now - 10
                ),
                RendererRealizationPlannerInput(
                    surfaceId: switchTargetID,
                    isVisible: false,
                    isRealized: true,
                    lastVisibleAt: now - 100,
                    isProtectedForPresentation: true
                ),
            ],
            settings: settings,
            now: now
        )

        #expect(selected == [warmSurfaceID, reclaimableSurfaceID])
    }

    @Test
    func systemMemoryPressureAlsoPreservesPresentationProtectedRenderer() {
        let now: TimeInterval = 1_000
        let switchTargetID = UUID()
        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: [
                RendererRealizationPlannerInput(
                    surfaceId: switchTargetID,
                    isVisible: false,
                    isRealized: true,
                    lastVisibleAt: now - 100,
                    isProtectedForPresentation: true
                ),
            ],
            settings: RendererRealizationSettings.Values(
                enabled: true,
                idleSeconds: 5,
                maxWarmRenderers: 1
            ),
            now: now,
            trigger: .systemMemoryPressure
        )

        #expect(!selected.contains(switchTargetID))
    }
}
