import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Mobile terminal reorder index resolver")
struct MobileTerminalReorderIndexResolverTests {
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
