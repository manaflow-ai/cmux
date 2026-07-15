import CmuxCommandPalette
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Right sidebar command palette", .serialized)
struct RightSidebarCommandPaletteTests {
    @Test("Feed commands are available by default")
    func feedCommandsAreAvailableByDefault() throws {
        try withFeedFlag(true) {
            let defaults = UserDefaults.standard
            let previousDock = defaults.object(forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)
            defer { restore(previousDock, forKey: RightSidebarBetaFeatureSettings.dockEnabledKey) }
            defaults.removeObject(forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)

            let contributions = ContentView.commandPaletteRightSidebarModeCommandContributions()
            let contributionsByID = Dictionary(uniqueKeysWithValues: contributions.map { ($0.commandId, $0) })
            let context = CommandPaletteContextSnapshot()

            for mode in RightSidebarMode.availableModes() {
                let commandID = ContentView.commandPaletteRightSidebarModeCommandID(mode)
                let contribution = try #require(contributionsByID[commandID])
                #expect(contribution.title(context) == mode.shortcutAction?.label ?? mode.label)
                #expect(contribution.subtitle(context) == String(
                    localized: "command.rightSidebarMode.subtitle",
                    defaultValue: "Right Sidebar"
                ))
                #expect(contribution.keywords.contains("right"))
                #expect(contribution.keywords.contains("sidebar"))
                #expect(contribution.keywords.contains(mode.rawValue))
                #expect(contribution.when(context))
                #expect(contribution.enablement(context))
            }

            #expect(contributions.count == 4)
            #expect(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.feed)] != nil)
            #expect(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.dock)] == nil)

            let paneDescriptors = ContentView.commandPaletteRightSidebarToolPaneCommandDescriptors()
            #expect(paneDescriptors.contains { $0.mode == .feed && $0.commandId == "palette.openFeedPane" })
        }
    }

    @Test("Remote Feed flag hides sidebar and pane commands")
    func remoteFeedFlagHidesCommands() throws {
        try withFeedFlag(false) {
            let contributions = ContentView.commandPaletteRightSidebarModeCommandContributions()
            #expect(!contributions.contains {
                $0.commandId == ContentView.commandPaletteRightSidebarModeCommandID(.feed)
            })
            #expect(!ContentView.commandPaletteRightSidebarToolPaneCommandDescriptors().contains { $0.mode == .feed })
        }
    }

    @Test("Right sidebar actions use configurable shortcuts")
    func rightSidebarActionsUseModeShortcutActions() throws {
        try withFeedFlag(true) {
            for mode in RightSidebarMode.allCases {
                #expect(ContentView.commandPaletteShortcutAction(
                    forCommandID: ContentView.commandPaletteRightSidebarModeCommandID(mode)
                ) == mode.shortcutAction)
            }
        }
    }

    @Test("Unread actions use configurable shortcuts")
    func unreadActionsUseConfigurableShortcuts() {
        #expect(ContentView.commandPaletteShortcutAction(forCommandID: "palette.toggleUnread") == .toggleUnread)
        #expect(ContentView.commandPaletteShortcutAction(
            forCommandID: "palette.markOldestUnreadAndJumpNext"
        ) == .markOldestUnreadAndJumpNext)
    }

    private func withFeedFlag<T>(_ enabled: Bool, _ body: () throws -> T) throws -> T {
        let flags = CmuxFeatureFlags.shared
        let definition = try #require(CmuxFeatureFlags.allFlags.first { $0.key == "feed-ui-enabled-release" })
        let previous = flags.overrideValue(for: definition)
        flags.setOverride(enabled, for: definition)
        defer { flags.setOverride(previous, for: definition) }
        return try body()
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
