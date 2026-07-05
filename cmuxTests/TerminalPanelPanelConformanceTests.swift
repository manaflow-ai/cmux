import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct TerminalPanelPanelConformanceTests {
    @MainActor
    @Test func protocolTypedRestoreFocusIntentUsesTerminalPanelWitness() {
        let terminalPanel = TerminalPanel(workspaceId: UUID())
        var autoResumeRequestCount = 0
        terminalPanel.onRequestRestoredAgentAutoResume = {
            autoResumeRequestCount += 1
            return true
        }

        let panel: any Panel = terminalPanel
        _ = panel.restoreFocusIntent(.terminal(.surface))

        #expect(autoResumeRequestCount == 1)
    }

    @MainActor
    @Test func protocolTypedFocusUsesTerminalPanelWitness() {
        let terminalPanel = TerminalPanel(workspaceId: UUID())
        var autoResumeRequestCount = 0
        terminalPanel.onRequestRestoredAgentAutoResume = {
            autoResumeRequestCount += 1
            return true
        }

        let panel: any Panel = terminalPanel
        panel.focus()

        #expect(autoResumeRequestCount == 1)
    }
}
