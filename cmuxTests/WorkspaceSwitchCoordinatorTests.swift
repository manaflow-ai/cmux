import Foundation
import Testing
import CmuxSettings

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct WorkspaceSwitchCoordinatorTests {
    @Test
    func loadedTerminalPointerDoesNotMakeDestinationReady() {
        let readiness = WorkspaceSwitchCoordinator.Readiness(
            contentKind: .terminal,
            requiresInteraction: true,
            nativeSurfaceLoaded: true,
            portalPresented: false,
            firstFramePresented: false,
            interactionReady: false
        )

        #expect(!readiness.isReadyForSourceRetirement)
    }

    @Test
    func terminalRequiresPortalFrameAndInteractionBeforeSourceRetirement() {
        var readiness = WorkspaceSwitchCoordinator.Readiness(
            contentKind: .terminal,
            requiresInteraction: true,
            nativeSurfaceLoaded: true,
            portalPresented: false,
            firstFramePresented: false,
            interactionReady: false
        )

        readiness.portalPresented = true
        #expect(!readiness.isReadyForSourceRetirement)

        readiness.interactionReady = true
        #expect(!readiness.isReadyForSourceRetirement)

        readiness.firstFramePresented = true
        #expect(readiness.isReadyForSourceRetirement)
    }

    @Test
    func backgroundTerminalDoesNotRequireFirstResponder() {
        var readiness = WorkspaceSwitchCoordinator.Readiness(
            contentKind: .terminal,
            requiresInteraction: false,
            nativeSurfaceLoaded: true,
            portalPresented: true,
            firstFramePresented: false,
            interactionReady: false
        )

        #expect(!readiness.isReadyForSourceRetirement)
        readiness.firstFramePresented = true
        #expect(readiness.isReadyForSourceRetirement)
    }

    @Test
    func browserRequiresPortalAndInteraction() {
        var readiness = WorkspaceSwitchCoordinator.Readiness(
            contentKind: .browser,
            requiresInteraction: true,
            nativeSurfaceLoaded: true,
            portalPresented: false,
            firstFramePresented: false,
            interactionReady: false
        )

        #expect(!readiness.isReadyForSourceRetirement)
        readiness.portalPresented = true
        #expect(!readiness.isReadyForSourceRetirement)
        readiness.interactionReady = true
        #expect(readiness.isReadyForSourceRetirement)
    }

    @Test
    func presentationProtectedRendererIsNeverSelectedForReclamation() {
        let now: TimeInterval = 1_000
        let warmSurfaceID = UUID()
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

        #expect(!selected.contains(switchTargetID))
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
