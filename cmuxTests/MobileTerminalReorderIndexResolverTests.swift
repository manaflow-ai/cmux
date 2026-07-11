import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Mobile terminal reorder index resolver")
struct MobileTerminalReorderIndexResolverTests {
    @MainActor
    @Test func surfaceCleanupLeavesOtherTerminalViewportReportsIntact() {
        let controller = TerminalController.shared
        let closingSurfaceID = UUID()
        let survivingSurfaceID = UUID()
        controller.debugResetMobileViewportReportsForTesting()
        defer { controller.debugResetMobileViewportReportsForTesting() }
        controller.debugSetMobileViewportReportForTesting(
            surfaceID: closingSurfaceID,
            clientID: "phone",
            columns: 40,
            rows: 20
        )
        controller.debugSetMobileViewportReportForTesting(
            surfaceID: survivingSurfaceID,
            clientID: "tablet",
            columns: 80,
            rows: 30
        )

        controller.clearMobileViewportReports(surfaceID: closingSurfaceID, reason: "test")

        #expect(controller.debugMobileViewportReportClientIDsForTesting(surfaceID: closingSurfaceID) == nil)
        #expect(controller.debugMobileViewportReportClientIDsForTesting(surfaceID: survivingSurfaceID) == ["tablet"])
    }

    @Test func translatesTerminalOrderAcrossInterleavedNonTerminalPanels() throws {
        let firstTerminal = UUID()
        let browser = UUID()
        let secondTerminal = UUID()
        let terminals: Set<UUID> = [firstTerminal, secondTerminal]

        #expect(MobileTerminalReorderIndexResolver.destinationIndex(
            panePanelIDs: [firstTerminal, browser, secondTerminal],
            terminalPanelIDs: terminals,
            movingPanelID: firstTerminal,
            targetTerminalIndex: 1
        ) == 3)
        #expect(MobileTerminalReorderIndexResolver.destinationIndex(
            panePanelIDs: [firstTerminal, browser, secondTerminal],
            terminalPanelIDs: terminals,
            movingPanelID: secondTerminal,
            targetTerminalIndex: 0
        ) == 0)
    }

    @Test func rejectsWrongIdentityAndOutOfRangeTerminalIndex() {
        let terminal = UUID()
        #expect(MobileTerminalReorderIndexResolver.destinationIndex(
            panePanelIDs: [terminal],
            terminalPanelIDs: [terminal],
            movingPanelID: UUID(),
            targetTerminalIndex: 0
        ) == nil)
        #expect(MobileTerminalReorderIndexResolver.destinationIndex(
            panePanelIDs: [terminal],
            terminalPanelIDs: [terminal],
            movingPanelID: terminal,
            targetTerminalIndex: 1
        ) == nil)
    }
}
