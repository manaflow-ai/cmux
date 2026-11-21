import CMUXAgentLaunch
import CmuxCommandPalette
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct SessionPriorityPaletteCommandsTests {
    private func ids(isEnabled: Bool) -> [String] {
        SessionPriorityPaletteCommands
            .contributions(isEnabled: isEnabled, workspaceSubtitle: { _ in "" })
            .map(\.commandId)
    }

    @Test
    func contributionsHiddenWhenDisabled() {
        #expect(ids(isEnabled: false).isEmpty)
    }

    @Test
    func difficultyCommandsCoverAllLevelsAndAuto() {
        let commandIds = ids(isEnabled: true)
        for suffix in ["auto", "easy", "normal", "hard"] {
            #expect(commandIds.contains("palette.claudeDifficulty.\(suffix)"))
        }
        #expect(commandIds.contains("palette.sessionPriorityManual.on"))
        #expect(commandIds.contains("palette.sessionPriorityManual.off"))
        #expect(Set(commandIds).count == commandIds.count)
        #expect(SessionPriorityPaletteCommands.difficultyCommandId(nil) == "palette.claudeDifficulty.auto")
        #expect(SessionPriorityPaletteCommands.difficultyCommandId(.hard) == "palette.claudeDifficulty.hard")
    }

    /// The manual commands read the palette window's own selected workspace from its context
    /// snapshot, like the other workspace commands, not the app's active window.
    @Test
    func manualCommandsFollowThePaletteSnapshot() throws {
        let contributions = SessionPriorityPaletteCommands.contributions(isEnabled: true, workspaceSubtitle: { _ in "" })
        let dontAdjust = try #require(contributions.first { $0.commandId == SessionPriorityPaletteCommands.manualOnCommandId })
        let adjust = try #require(contributions.first { $0.commandId == SessionPriorityPaletteCommands.manualOffCommandId })
        var snapshot = CommandPaletteContextSnapshot()
        snapshot.setBool(CommandPaletteContextKeys.hasWorkspace, true)
        snapshot.setBool(SessionPriorityPaletteCommands.workspaceAdjustableManualKey, true)
        #expect(adjust.when(snapshot))
        #expect(!dontAdjust.when(snapshot))
        snapshot.setBool(SessionPriorityPaletteCommands.workspaceAdjustableManualKey, false)
        #expect(dontAdjust.when(snapshot))
        #expect(!adjust.when(snapshot))
        // No workspace in the palette's window: neither.
        let empty = CommandPaletteContextSnapshot()
        #expect(!dontAdjust.when(empty) && !adjust.when(empty))
    }

    @Test
    func actionsApplyDifficultyAndManualToEveryTarget() {
        let first = Workspace()
        let second = Workspace()
        SessionPriorityActions.applyDifficulty(.hard, to: [first, second])
        #expect(first.sessionPriorityState.difficultyOverride == .hard)
        #expect(second.sessionPriorityState.difficultyOverride == .hard)
        SessionPriorityActions.applyDifficulty(nil, to: [first, second])
        #expect(first.sessionPriorityState.difficultyOverride == nil)
        SessionPriorityActions.setManual(true, for: [first, second])
        #expect(first.sessionPriorityState.isManual && second.sessionPriorityState.isManual)
        SessionPriorityActions.setManual(false, for: [first])
        #expect(!first.sessionPriorityState.isManual && second.sessionPriorityState.isManual)
    }
}
