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
        let coordinator = WorkspaceSwitchCoordinator(
            beginRendererProtection: { _, _ in },
            endRendererProtection: { _ in }
        )
        coordinator.selectionWillCommit(
            from: sourceWorkspaceID,
            to: targetWorkspaceID,
            targetSurfaceID: targetSurfaceID,
            targetTerminalView: nil,
            targetRendererPresented: true,
            targetRenderedFrameSequence: 0
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
                terminalRendererPresented: true,
                terminalRenderedFrameSequence: 0,
                browserWebView: nil,
                portalPresented: false,
                interactionReady: true,
                requiresInteraction: true
            )
        )

        coordinator.noteFirstFrame(surfaceID: targetSurfaceID)
        #expect(!coordinator.isReadyForSourceRetirement)

        coordinator.noteTerminalPortalPresented(
            surfaceID: targetSurfaceID,
            renderedFrameSequence: 0
        )
        #expect(coordinator.isReadyForSourceRetirement)
        coordinator.cancel()
    }

    @Test
    func reclaimedRendererRequiresFrameSequenceAdvance() {
        let sourceWorkspaceID = UUID()
        let targetWorkspaceID = UUID()
        let targetSurfaceID = UUID()
        let coordinator = WorkspaceSwitchCoordinator(
            beginRendererProtection: { _, _ in },
            endRendererProtection: { _ in }
        )
        coordinator.selectionWillCommit(
            from: sourceWorkspaceID,
            to: targetWorkspaceID,
            targetSurfaceID: targetSurfaceID,
            targetTerminalView: nil,
            targetRendererPresented: false,
            targetRenderedFrameSequence: 4
        )
        coordinator.beginPresentation(
            WorkspaceSwitchCoordinator.PresentationTarget(
                workspaceID: targetWorkspaceID,
                contentKind: .terminal,
                terminalSurfaceID: targetSurfaceID,
                terminalView: nil,
                terminalRendererPresented: false,
                terminalRenderedFrameSequence: 4,
                browserWebView: nil,
                portalPresented: false,
                interactionReady: true,
                requiresInteraction: true
            )
        )

        coordinator.noteTerminalPortalPresented(
            surfaceID: targetSurfaceID,
            renderedFrameSequence: 4
        )
        #expect(!coordinator.isReadyForSourceRetirement)

        coordinator.noteTerminalPortalPresented(
            surfaceID: targetSurfaceID,
            renderedFrameSequence: 5
        )
        #expect(coordinator.isReadyForSourceRetirement)
        coordinator.cancel()
    }

    @Test
    func backgroundTerminalDoesNotRequireFirstResponder() {
        var readiness = WorkspaceSwitchCoordinator.Readiness(
            contentKind: .terminal,
            requiresInteraction: false,
            portalPresented: true,
            firstFramePresented: false,
            interactionReady: false
        )

        #expect(!readiness.isReadyForSourceRetirement)
        readiness.firstFramePresented = true
        #expect(readiness.isReadyForSourceRetirement)
    }

    @Test
    func browserRetiresSourceAtPortalWhileTrackingInteractionSeparately() {
        var readiness = WorkspaceSwitchCoordinator.Readiness(
            contentKind: .browser,
            requiresInteraction: true,
            portalPresented: false,
            firstFramePresented: false,
            interactionReady: false
        )

        #expect(!readiness.isReadyForSourceRetirement)
        readiness.portalPresented = true
        #expect(readiness.isReadyForSourceRetirement)
        #expect(!readiness.interactionIsReady)
        readiness.interactionReady = true
        #expect(readiness.interactionIsReady)
    }

    @Test
    func rendererProtectionIsReleasedAtPortalPresentation() {
        var protectedRequestIDs: [UUID] = []
        var releasedRequestIDs: [UUID] = []
        let sourceWorkspaceID = UUID()
        let targetWorkspaceID = UUID()
        let targetSurfaceID = UUID()
        let coordinator = WorkspaceSwitchCoordinator(
            beginRendererProtection: { _, requestID in
                protectedRequestIDs.append(requestID)
            },
            endRendererProtection: { requestID in
                releasedRequestIDs.append(requestID)
            }
        )

        coordinator.selectionWillCommit(
            from: sourceWorkspaceID,
            to: targetWorkspaceID,
            targetSurfaceID: targetSurfaceID,
            targetTerminalView: nil,
            targetRendererPresented: true,
            targetRenderedFrameSequence: 1
        )
        #expect(protectedRequestIDs.count == 1)
        #expect(releasedRequestIDs.isEmpty)
        coordinator.beginPresentation(
            WorkspaceSwitchCoordinator.PresentationTarget(
                workspaceID: targetWorkspaceID,
                contentKind: .terminal,
                terminalSurfaceID: targetSurfaceID,
                terminalView: nil,
                terminalRendererPresented: true,
                terminalRenderedFrameSequence: 1,
                browserWebView: nil,
                portalPresented: false,
                interactionReady: true,
                requiresInteraction: true
            )
        )

        coordinator.noteTerminalPortalPresented(
            surfaceID: targetSurfaceID,
            renderedFrameSequence: 1
        )

        #expect(releasedRequestIDs == protectedRequestIDs)
        coordinator.cancel()
    }

    @Test
    func rapidSwitchCancelsPreviousRendererProtection() {
        var protectedRequestIDs: [UUID] = []
        var releasedRequestIDs: [UUID] = []
        let coordinator = WorkspaceSwitchCoordinator(
            beginRendererProtection: { _, requestID in
                protectedRequestIDs.append(requestID)
            },
            endRendererProtection: { requestID in
                releasedRequestIDs.append(requestID)
            }
        )
        let firstTargetSurfaceID = UUID()
        let secondTargetSurfaceID = UUID()

        coordinator.selectionWillCommit(
            from: UUID(),
            to: UUID(),
            targetSurfaceID: firstTargetSurfaceID,
            targetTerminalView: nil,
            targetRendererPresented: true,
            targetRenderedFrameSequence: 1
        )
        coordinator.selectionWillCommit(
            from: UUID(),
            to: UUID(),
            targetSurfaceID: secondTargetSurfaceID,
            targetTerminalView: nil,
            targetRendererPresented: true,
            targetRenderedFrameSequence: 1
        )

        #expect(protectedRequestIDs.count == 2)
        #expect(releasedRequestIDs == [protectedRequestIDs[0]])
        coordinator.cancel()
        #expect(releasedRequestIDs == protectedRequestIDs)
    }

    @Test
    func presentationProtectedRendererIsNeverSelectedForReclamation() {
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
                    lastVisibleAt: now - 1
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

        #expect(selected == [reclaimableSurfaceID])
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
