import CmuxCommandPalette
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Auth command visibility and the Cloud team's existing customizable command.
@MainActor
struct CommandPaletteAuthCommandTests {
    @Test func upgradeTitleTracksBillingContextAndInvalidatesCachedCommands() throws {
        let command = try #require(ContentView.commandPaletteProCommandContributions().first {
            $0.commandId == ContentView.commandPaletteProUpgradeCommandId
        })
        var context = CommandPaletteContextSnapshot()
        let freeTitle = command.title(context)
        let freeFingerprint = context.fingerprint()
        #expect(freeTitle.contains("cmux Pro"))

        context.setBool(ContentView.commandPalettePersonalProActiveKey, true)
        let proTitle = command.title(context)
        let proFingerprint = context.fingerprint()
        #expect(proTitle.contains("cmux Max"))
        #expect(proFingerprint != freeFingerprint)

        context.setBool(ContentView.commandPalettePersonalProActiveKey, false)
        context.setBool(ContentView.commandPaletteMaxActiveKey, true)
        let maxTitle = command.title(context)
        #expect(maxTitle.contains("cmux Max"))
        #expect(maxTitle != proTitle)
        #expect(context.fingerprint() != proFingerprint)
    }

    @Test func signedOutContextShowsSignInCommandOnly() {
        var context = CommandPaletteContextSnapshot()
        context.setBool(CommandPaletteContextKeys.authSignedIn, false)
        context.setBool(CommandPaletteContextKeys.authWorking, false)
        #expect(visibleAuthCommandIDs(context) == [ContentView.commandPaletteAuthSignInCommandId])
    }

    @Test func signedInContextShowsSignOutAndTeamPicker() {
        var context = CommandPaletteContextSnapshot()
        context.setBool(CommandPaletteContextKeys.authSignedIn, true)
        context.setBool(CommandPaletteContextKeys.authWorking, false)
        #expect(visibleAuthCommandIDs(context) == [
            ContentView.commandPaletteAuthSignOutCommandId,
            ContentView.commandPaletteAuthTeamPickerCommandId,
            ContentView.commandPaletteAuthTeamMembersCommandId
        ])
    }

    @Test(arguments: [false, true])
    func workingAuthContextHidesAccountCommands(signedIn: Bool) {
        var context = CommandPaletteContextSnapshot()
        context.setBool(CommandPaletteContextKeys.authSignedIn, signedIn)
        context.setBool(CommandPaletteContextKeys.authWorking, true)
        #expect(visibleAuthCommandIDs(context).isEmpty)
    }

    @Test func teamPickerIsACloudCommandUsingTheCustomizableShortcut() throws {
        let command = try #require(ContentView.commandPaletteAuthCommandContributions().first {
            $0.commandId == ContentView.commandPaletteAuthTeamPickerCommandId
        })
        #expect(command.subtitle(CommandPaletteContextSnapshot()) == String(
            localized: "command.cloudVM.subtitle", defaultValue: "Cloud"
        ))
        #expect(ContentView.commandPaletteShortcutAction(forCommandID: command.commandId) == .openTeamPicker)
    }

    private func visibleAuthCommandIDs(_ context: CommandPaletteContextSnapshot) -> [String] {
        ContentView.commandPaletteAuthCommandContributions()
            .filter { $0.when(context) }
            .map(\.commandId)
    }
}
