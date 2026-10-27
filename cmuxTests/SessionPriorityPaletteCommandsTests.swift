import CMUXAgentLaunch
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
