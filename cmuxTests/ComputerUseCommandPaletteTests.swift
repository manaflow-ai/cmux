import CmuxCommandPalette
import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Computer Use command palette")
struct ComputerUseCommandPaletteTests {
    @Test func computerUseCommandPaletteActionsHideWhenFeatureIsDisabled() {
        var context = CommandPaletteContextSnapshot()
        context.setBool(CommandPaletteContextKeys.computerUseUXEnabled, false)

        let contributions = ContentView.commandPaletteComputerUseContributions()
        #expect(!contributions.isEmpty)
        #expect(contributions.allSatisfy { !$0.when(context) })
    }

    @Test func computerUseCommandPaletteActionsExposeAllOnboardingEntryPoints() {
        var context = CommandPaletteContextSnapshot()
        context.setBool(CommandPaletteContextKeys.computerUseUXEnabled, true)

        let contributions = ContentView.commandPaletteComputerUseContributions()
        #expect(contributions.map(\.commandId) == [
            ContentView.commandPaletteComputerUseOpenSetupCommandId,
            ContentView.commandPaletteComputerUseAccessibilityCommandId,
            ContentView.commandPaletteComputerUseScreenRecordingCommandId,
        ])
        #expect(contributions.allSatisfy { $0.when(context) && $0.enablement(context) })
        #expect(contributions.allSatisfy { !$0.keywords.isEmpty && !$0.subtitle(context).isEmpty })
        #expect(contributions.allSatisfy {
            ContentView.commandPaletteShouldDismissBeforeRun(forCommandId: $0.commandId)
        })
    }
}
