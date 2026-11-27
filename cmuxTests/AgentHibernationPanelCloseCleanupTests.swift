import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct AgentHibernationPanelCloseCleanupTests {
    @Test
    func rejectedCleanupDeadlineReleasesCleanupOwnership() async throws {
        let controller = AgentHibernationController.shared
        let panelID = UUID()
        let requestID = UUID()
        let processExitCompletion = AgentHibernationProcessExitCompletion()
        controller.registerCommittedTerminationObservation(
            panelID: panelID,
            requestID: requestID,
            processExitCompletion: processExitCompletion
        )
        defer {
            controller.removeCommittedTerminationObservation(
                panelID: panelID,
                requestID: requestID
            )
        }

        controller.limitCommittedTerminationObservationAfterPanelClose(
            panelID: panelID,
            cleanupDelay: .zero,
            sleepUntilDeadline: { _ in false }
        )
        let cleanupTask = try #require(
            controller.committedTerminationCleanupByPanelID[panelID]?.task
        )
        await cleanupTask.value

        #expect(controller.committedTerminationCleanupByPanelID[panelID] == nil)
        #expect(
            controller.committedTerminationObservationsByPanelID[panelID]?
                .requestID == requestID
        )
    }
}
