import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct WorkspaceHandoffRetirementGateTests {
    @Test
    func retirementWaitsForTheMatchingFocusPass() {
        var gate = WorkspaceHandoffRetirementGate()
        let sourceWorkspaceID = UUID()
        gate.reset(forSelectionGeneration: 7)

        #expect(
            gate.request(
                workspaceID: sourceWorkspaceID,
                reason: "mount_reconciled",
                selectionGeneration: 7
            ) == nil
        )
        #expect(gate.markFocusPassCompleted(generation: 6) == nil)
        #expect(gate.pendingRequest?.workspaceID == sourceWorkspaceID)

        let completed = gate.markFocusPassCompleted(generation: 7)
        #expect(completed?.workspaceID == sourceWorkspaceID)
        #expect(completed?.reason == "mount_reconciled")
        #expect(gate.pendingRequest == nil)
    }

    @Test
    func requestAfterFocusPassCompletesWithTheAuthoritativeSource() {
        var gate = WorkspaceHandoffRetirementGate()
        let sourceWorkspaceID = UUID()
        gate.reset(forSelectionGeneration: 11)
        #expect(gate.markFocusPassCompleted(generation: 11) == nil)

        let completed = gate.request(
            workspaceID: sourceWorkspaceID,
            reason: "focus",
            selectionGeneration: 11
        )

        #expect(completed?.workspaceID == sourceWorkspaceID)
        #expect(completed?.reason == "focus")
    }

    @Test
    func aNewSelectionDropsAnOlderRetirementRequest() {
        var gate = WorkspaceHandoffRetirementGate()
        gate.reset(forSelectionGeneration: 3)
        _ = gate.request(
            workspaceID: UUID(),
            reason: "stale",
            selectionGeneration: 3
        )

        gate.reset(forSelectionGeneration: 4)
        #expect(gate.pendingRequest == nil)
        #expect(gate.markFocusPassCompleted(generation: 3) == nil)
        #expect(gate.markFocusPassCompleted(generation: 4) == nil)
    }
}
