import CmuxCommandPalette
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Artifact right-sidebar mode", .serialized)
@MainActor
struct ArtifactRightSidebarModeTests {
    @Test("Beta availability clamps disabled mode and preserves enabled mode")
    func betaAvailabilityControlsPersistence() {
        withSavedArtifactsDefault { defaults in
            defaults.set(false, forKey: RightSidebarBetaFeatureSettings.artifactsEnabledKey)
            let state = FileExplorerState()

            state.mode = .artifacts
            #expect(state.mode == .files)

            defaults.set(true, forKey: RightSidebarBetaFeatureSettings.artifactsEnabledKey)
            state.mode = .artifacts
            #expect(state.mode == .artifacts)
        }
    }

    @Test("Remote Artifacts flag is a hard gate over the local beta opt-in")
    func remoteFlagControlsLocalOptIn() {
        withSavedArtifactsDefault { defaults in
            defaults.set(true, forKey: RightSidebarBetaFeatureSettings.artifactsEnabledKey)
            #expect(!RightSidebarBetaFeatureSettings.isArtifactsEnabled(
                defaults: defaults,
                remoteEnabled: false
            ))
            #expect(RightSidebarBetaFeatureSettings.isArtifactsEnabled(
                defaults: defaults,
                remoteEnabled: true
            ))

            defaults.set(false, forKey: RightSidebarBetaFeatureSettings.artifactsEnabledKey)
            #expect(!RightSidebarBetaFeatureSettings.isArtifactsEnabled(
                defaults: defaults,
                remoteEnabled: true
            ))
        }
    }

    @Test("CLI mode parsing recognizes artifacts")
    func parsesCLIArgument() {
        #expect(RightSidebarMode.from(cliArgument: "artifacts") == .artifacts)
    }

    @Test("Artifacts has no hidden fixed shortcut")
    func hasNoModeShortcut() {
        #expect(RightSidebarMode.artifacts.shortcutAction == nil)
    }

    @Test("Command palette contribution follows the beta gate")
    func commandPaletteContributionFollowsBetaGate() throws {
        try withSavedArtifactsDefault { defaults in
            defaults.removeObject(forKey: RightSidebarBetaFeatureSettings.artifactsEnabledKey)
            let commandID = ContentView.commandPaletteRightSidebarModeCommandID(.artifacts)
            var contributions = ContentView.commandPaletteRightSidebarModeCommandContributions()
            #expect(!contributions.contains { $0.commandId == commandID })

            defaults.set(true, forKey: RightSidebarBetaFeatureSettings.artifactsEnabledKey)
            contributions = ContentView.commandPaletteRightSidebarModeCommandContributions()
            let contribution = try #require(contributions.first { $0.commandId == commandID })
            let context = CommandPaletteContextSnapshot()
            #expect(contribution.title(context) == RightSidebarMode.artifacts.label)
            #expect(ContentView.commandPaletteShortcutAction(forCommandID: commandID) == nil)
        }
    }

    private func withSavedArtifactsDefault<T>(
        _ body: (UserDefaults) throws -> T
    ) rethrows -> T {
        let defaults = UserDefaults.standard
        let key = RightSidebarBetaFeatureSettings.artifactsEnabledKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        return try body(defaults)
    }
}
