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
        let readiness = WorkspaceSwitchReadiness(
            contentKind: .terminal,
            requiresInteraction: true,
            portalPresented: false,
            firstFramePresented: false,
            interactionReady: false
        )

        #expect(!readiness.presentationIsReady)
    }

    @Test
    func terminalPresentationRequiresPortalAndFrame() {
        var readiness = WorkspaceSwitchReadiness(
            contentKind: .terminal,
            requiresInteraction: true,
            portalPresented: false,
            firstFramePresented: false,
            interactionReady: false
        )

        readiness.portalPresented = true
        #expect(!readiness.presentationIsReady)

        readiness.interactionReady = true
        #expect(!readiness.presentationIsReady)

        readiness.firstFramePresented = true
        #expect(readiness.presentationIsReady)
    }

    @Test
    func terminalPresentationDoesNotWaitForFocusTransfer() {
        let readiness = WorkspaceSwitchReadiness(
            contentKind: .terminal,
            requiresInteraction: true,
            portalPresented: true,
            firstFramePresented: true,
            interactionReady: false
        )

        #expect(readiness.presentationIsReady)
    }

    @Test
    func frameObservedBeforePortalPresentationIsPreserved() throws {
        let sourceWorkspaceID = UUID()
        let targetWorkspaceID = UUID()
        let targetSurfaceID = UUID()
        let coordinator = WorkspaceSwitchCoordinator(
            beginRendererProtection: { _, _, _ in },
            endRendererProtection: { _ in }
        )
        let pendingRequestID = coordinator.selectionWillCommit(
            from: sourceWorkspaceID,
            to: targetWorkspaceID,
            targetSurfaceID: targetSurfaceID,
            targetTerminalView: nil,
            targetRendererPresented: true,
            targetRenderedFrameSequence: 0
        )
        let requestID = try #require(pendingRequestID)
        coordinator.selectionDidCommit(
            from: sourceWorkspaceID,
            to: targetWorkspaceID
        )
        coordinator.beginPresentation(
            terminalTarget(
                workspaceID: targetWorkspaceID,
                surfaceID: targetSurfaceID,
                portalPresented: false,
                interactionReady: true
            ),
            retiringWorkspaceID: sourceWorkspaceID
        )

        coordinator.noteFirstFrame(
            surfaceID: targetSurfaceID,
            requestID: requestID,
            renderedFrameSequence: 1
        )
        #expect(!coordinator.isPresentationReady)

        coordinator.noteTerminalPortalPresented(
            surfaceID: targetSurfaceID,
            renderedFrameSequence: 0
        )
        #expect(coordinator.isPresentationReady)
        coordinator.cancel()
    }

    @Test
    func reclaimedRendererRequiresFrameSequenceAdvance() {
        let sourceWorkspaceID = UUID()
        let targetWorkspaceID = UUID()
        let targetSurfaceID = UUID()
        let coordinator = WorkspaceSwitchCoordinator(
            beginRendererProtection: { _, _, _ in },
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
            terminalTarget(
                workspaceID: targetWorkspaceID,
                surfaceID: targetSurfaceID,
                rendererPresented: false,
                renderedFrameSequence: 4,
                portalPresented: false,
                interactionReady: true
            ),
            retiringWorkspaceID: sourceWorkspaceID
        )

        coordinator.noteTerminalPortalPresented(
            surfaceID: targetSurfaceID,
            renderedFrameSequence: 4
        )
        #expect(!coordinator.isPresentationReady)

        coordinator.noteTerminalPortalPresented(
            surfaceID: targetSurfaceID,
            renderedFrameSequence: 5
        )
        #expect(coordinator.isPresentationReady)
        coordinator.cancel()
    }

    @Test
    func backgroundTerminalPresentationRequiresFrame() {
        var readiness = WorkspaceSwitchReadiness(
            contentKind: .terminal,
            requiresInteraction: false,
            portalPresented: true,
            firstFramePresented: false,
            interactionReady: false
        )

        #expect(!readiness.presentationIsReady)
        readiness.firstFramePresented = true
        #expect(readiness.presentationIsReady)
    }

    @Test
    func browserPresentationTracksInteractionSeparately() {
        var readiness = WorkspaceSwitchReadiness(
            contentKind: .browser,
            requiresInteraction: true,
            portalPresented: false,
            firstFramePresented: false,
            interactionReady: false
        )

        #expect(!readiness.presentationIsReady)
        readiness.portalPresented = true
        #expect(readiness.presentationIsReady)
        #expect(!readiness.interactionIsReady)
        readiness.interactionReady = true
        #expect(readiness.interactionIsReady)
    }

    @Test
    func rendererProtectionIsHeldUntilSourceRetires() {
        var protectedRequestIDs: [UUID] = []
        var releasedRequestIDs: [UUID] = []
        let sourceWorkspaceID = UUID()
        let targetWorkspaceID = UUID()
        let targetSurfaceID = UUID()
        let coordinator = WorkspaceSwitchCoordinator(
            beginRendererProtection: { _, requestID, _ in
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
            terminalTarget(
                workspaceID: targetWorkspaceID,
                surfaceID: targetSurfaceID,
                renderedFrameSequence: 1,
                portalPresented: false,
                interactionReady: true
            ),
            retiringWorkspaceID: sourceWorkspaceID
        )

        coordinator.noteTerminalPortalPresented(
            surfaceID: targetSurfaceID,
            renderedFrameSequence: 1
        )

        #expect(releasedRequestIDs.isEmpty)
        coordinator.sourceWillRetire(workspaceID: sourceWorkspaceID)
        coordinator.sourceDidRetire(workspaceID: sourceWorkspaceID)
        #expect(releasedRequestIDs == protectedRequestIDs)
        coordinator.cancel()
    }

    @Test
    func coalescedRoundTripCancelsIntermediateRendererProtection() {
        var protectedRequestIDs: [UUID] = []
        var releasedRequestIDs: [UUID] = []
        let coordinator = WorkspaceSwitchCoordinator(
            beginRendererProtection: { _, requestID, _ in
                protectedRequestIDs.append(requestID)
            },
            endRendererProtection: { requestID in
                releasedRequestIDs.append(requestID)
            }
        )
        let mountedWorkspaceID = UUID(), intermediateWorkspaceID = UUID()
        let firstTargetSurfaceID = UUID()
        coordinator.selectionDidReconcile(workspaceID: mountedWorkspaceID)

        coordinator.selectionWillCommit(
            from: mountedWorkspaceID,
            to: intermediateWorkspaceID,
            targetSurfaceID: firstTargetSurfaceID,
            targetTerminalView: nil,
            targetRendererPresented: true,
            targetRenderedFrameSequence: 1
        )
        coordinator.selectionWillCommit(
            from: intermediateWorkspaceID,
            to: mountedWorkspaceID,
            targetSurfaceID: UUID(),
            targetTerminalView: nil,
            targetRendererPresented: true,
            targetRenderedFrameSequence: 1
        )

        #expect(protectedRequestIDs.count == 1)
        #expect(releasedRequestIDs == protectedRequestIDs)
        coordinator.cancel()
        #expect(releasedRequestIDs == protectedRequestIDs)
    }

    @Test
    func staleFrameCallbackCannotFinishLaterTransactionForSameSurface() throws {
        let targetWorkspaceID = UUID(), targetSurfaceID = UUID()
        let coordinator = WorkspaceSwitchCoordinator(
            beginRendererProtection: { _, _, _ in },
            endRendererProtection: { _ in }
        )
        let staleRequestID = try #require(coordinator.selectionWillCommit(
            from: UUID(), to: targetWorkspaceID,
            targetSurfaceID: targetSurfaceID,
            targetTerminalView: nil,
            targetRendererPresented: true, targetRenderedFrameSequence: 0
        ))
        let currentRequestID = try #require(coordinator.selectionWillCommit(
            from: UUID(), to: targetWorkspaceID,
            targetSurfaceID: targetSurfaceID,
            targetTerminalView: nil,
            targetRendererPresented: true, targetRenderedFrameSequence: 0
        ))
        coordinator.beginPresentation(
            terminalTarget(
                workspaceID: targetWorkspaceID,
                surfaceID: targetSurfaceID,
                portalPresented: true, interactionReady: true
            ),
            retiringWorkspaceID: UUID()
        )

        coordinator.noteFirstFrame(
            surfaceID: targetSurfaceID,
            requestID: staleRequestID,
            renderedFrameSequence: 1
        )
        #expect(!coordinator.isPresentationReady)

        coordinator.noteFirstFrame(
            surfaceID: targetSurfaceID,
            requestID: currentRequestID,
            renderedFrameSequence: 0
        )
        #expect(!coordinator.isPresentationReady)

        coordinator.noteFirstFrame(
            surfaceID: targetSurfaceID,
            requestID: currentRequestID,
            renderedFrameSequence: 1
        )
        #expect(coordinator.isPresentationReady)
    }

    @Test
    func mismatchedPresentationCancelsSelectionTransaction() {
        let sourceWorkspaceID = UUID(), targetWorkspaceID = UUID()
        let targetSurfaceID = UUID()
        var protectedRequestIDs: [UUID] = [], releasedRequestIDs: [UUID] = []
        let coordinator = WorkspaceSwitchCoordinator(
            beginRendererProtection: { _, id, _ in protectedRequestIDs.append(id) },
            endRendererProtection: { releasedRequestIDs.append($0) }
        )
        coordinator.selectionWillCommit(
            from: sourceWorkspaceID,
            to: targetWorkspaceID,
            targetSurfaceID: targetSurfaceID,
            targetTerminalView: nil,
            targetRendererPresented: true,
            targetRenderedFrameSequence: 1
        )

        coordinator.beginPresentation(
            WorkspaceSwitchPresentationTarget(
                workspaceID: UUID(), contentKind: .passive,
                terminalSurfaceID: nil, terminalView: nil,
                terminalRendererPresented: false, terminalRenderedFrameSequence: 0,
                browserWebView: nil, portalPresented: true,
                interactionReady: true, requiresInteraction: false
            ),
            retiringWorkspaceID: sourceWorkspaceID
        )

        #expect(protectedRequestIDs.count == 1)
        #expect(releasedRequestIDs == protectedRequestIDs)
        #expect(coordinator.isPresentationReady)
    }

    @Test
    func coldDestinationRetiresSourceBeforePresentationReadiness() {
        var protectedRequestIDs: [UUID] = []
        var releasedRequestIDs: [UUID] = []
        let selectionSourceWorkspaceID = UUID()
        let mountedSourceWorkspaceID = UUID()
        let targetWorkspaceID = UUID()
        let targetSurfaceID = UUID()
        let coordinator = WorkspaceSwitchCoordinator(
            beginRendererProtection: { _, requestID, _ in
                protectedRequestIDs.append(requestID)
            },
            endRendererProtection: { requestID in
                releasedRequestIDs.append(requestID)
            }
        )

        coordinator.selectionWillCommit(
            from: selectionSourceWorkspaceID,
            to: targetWorkspaceID,
            targetSurfaceID: targetSurfaceID,
            targetTerminalView: nil,
            targetRendererPresented: false,
            targetRenderedFrameSequence: 0
        )
        coordinator.selectionDidCommit(
            from: selectionSourceWorkspaceID,
            to: targetWorkspaceID
        )
        coordinator.beginPresentation(
            terminalTarget(
                workspaceID: targetWorkspaceID,
                surfaceID: targetSurfaceID,
                rendererPresented: false,
                portalPresented: false,
                interactionReady: false,
                requiresInteraction: true
            ),
            retiringWorkspaceID: mountedSourceWorkspaceID
        )

        coordinator.sourceDidRetire(workspaceID: selectionSourceWorkspaceID)
        #expect(releasedRequestIDs.isEmpty)

        coordinator.sourceWillRetire(workspaceID: mountedSourceWorkspaceID)
        coordinator.sourceDidRetire(workspaceID: mountedSourceWorkspaceID)

        #expect(protectedRequestIDs.count == 1)
        #expect(releasedRequestIDs.isEmpty)

        coordinator.noteTerminalPortalPresented(
            surfaceID: targetSurfaceID,
            renderedFrameSequence: 1
        )
        #expect(releasedRequestIDs == protectedRequestIDs)
        coordinator.cancel()
        #expect(releasedRequestIDs == protectedRequestIDs)
    }

    @Test
    func interactionOnDifferentDestinationSurfaceFinishesMeasurement() {
        let sourceWorkspaceID = UUID()
        let targetWorkspaceID = UUID()
        let capturedSurfaceID = UUID()
        let coordinator = WorkspaceSwitchCoordinator(
            beginRendererProtection: { _, _, _ in },
            endRendererProtection: { _ in }
        )

        coordinator.selectionWillCommit(
            from: sourceWorkspaceID,
            to: targetWorkspaceID,
            targetSurfaceID: capturedSurfaceID,
            targetTerminalView: nil,
            targetRendererPresented: true,
            targetRenderedFrameSequence: 1
        )
        coordinator.beginPresentation(
            terminalTarget(
                workspaceID: targetWorkspaceID,
                surfaceID: capturedSurfaceID,
                renderedFrameSequence: 1,
                portalPresented: true,
                interactionReady: false,
                requiresInteraction: true
            ),
            retiringWorkspaceID: sourceWorkspaceID
        )
        coordinator.sourceWillRetire(workspaceID: sourceWorkspaceID)
        coordinator.sourceDidRetire(workspaceID: sourceWorkspaceID)

        #expect(coordinator.isMeasuringSwitch)
        coordinator.noteInteractionReady(
            workspaceID: targetWorkspaceID
        )
        #expect(!coordinator.isMeasuringSwitch)
    }

    private func terminalTarget(
        workspaceID: UUID,
        surfaceID: UUID,
        rendererPresented: Bool = true,
        renderedFrameSequence: UInt64 = 0,
        portalPresented: Bool,
        interactionReady: Bool,
        requiresInteraction: Bool = true
    ) -> WorkspaceSwitchPresentationTarget {
        WorkspaceSwitchPresentationTarget(
            workspaceID: workspaceID,
            contentKind: .terminal,
            terminalSurfaceID: surfaceID,
            terminalView: nil,
            terminalRendererPresented: rendererPresented,
            terminalRenderedFrameSequence: renderedFrameSequence,
            browserWebView: nil,
            portalPresented: portalPresented,
            interactionReady: interactionReady,
            requiresInteraction: requiresInteraction
        )
    }
}
