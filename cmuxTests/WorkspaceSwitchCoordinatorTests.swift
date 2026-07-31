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
    func sourceRetirementDoesNotWaitForTerminalFocusTransfer() {
        let readiness = WorkspaceSwitchCoordinator.Readiness(
            contentKind: .terminal,
            requiresInteraction: true,
            nativeSurfaceLoaded: true,
            portalPresented: true,
            firstFramePresented: true,
            interactionReady: false
        )

        #expect(readiness.isReadyForSourceRetirement)
    }

    @Test
    func frameObservedBeforePortalPresentationIsPreserved() {
        let sourceWorkspaceID = UUID()
        let targetWorkspaceID = UUID()
        let targetSurfaceID = UUID()
        let coordinator = WorkspaceSwitchCoordinator()
        coordinator.selectionWillCommit(
            from: sourceWorkspaceID,
            to: targetWorkspaceID,
            targetSurfaceID: targetSurfaceID
        )
        coordinator.selectionDidCommit(
            from: sourceWorkspaceID,
            to: targetWorkspaceID
        )
        coordinator.beginPresentation(
            WorkspaceSwitchCoordinator.PresentationTarget(
                workspaceID: targetWorkspaceID,
                contentKind: .terminal,
                terminalSurfaceID: targetSurfaceID,
                terminalView: nil,
                browserWebView: nil,
                nativeSurfaceLoaded: true,
                rendererPresented: true,
                portalPresented: false,
                firstFramePresented: false,
                interactionReady: true,
                requiresInteraction: true
            )
        )

        coordinator.noteFirstFrame(surfaceID: targetSurfaceID)
        #expect(!coordinator.isReadyForSourceRetirement)

        coordinator.noteTerminalPortalPresented(surfaceID: targetSurfaceID)
        #expect(coordinator.isReadyForSourceRetirement)
        coordinator.cancel()
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
