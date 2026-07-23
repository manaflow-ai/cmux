import CmuxCommandPalette
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Right sidebar command palette actions", .serialized)
struct RightSidebarCommandPaletteActionTests {
    @Test
    func includesDefaultModesWithExactTargetRequirements() throws {
        try withSavedBetaFeatureDefaults {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
            defaults.removeObject(forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)
            let contributions = ContentView.commandPaletteRightSidebarModeCommandContributions()
            let contributionsByID = Dictionary(
                uniqueKeysWithValues: contributions.map { ($0.commandId, $0) }
            )
            let unavailableContext = CommandPaletteContextSnapshot()
            var panelWithoutPaneContext = CommandPaletteContextSnapshot()
            panelWithoutPaneContext.setBool(CommandPaletteContextKeys.hasFocusedPanel, true)
            var availableContext = CommandPaletteContextSnapshot()
            availableContext.setBool(CommandPaletteContextKeys.hasFocusedPanel, true)
            availableContext.setBool(CommandPaletteContextKeys.panelHasPane, true)

            for mode in RightSidebarMode.availableModes() {
                let commandID = ContentView.commandPaletteRightSidebarModeCommandID(mode)
                let contribution = try #require(contributionsByID[commandID])

                #expect(
                    contribution.title(availableContext)
                        == (mode.shortcutAction?.label ?? mode.label)
                )
                #expect(
                    contribution.subtitle(availableContext)
                        == String(
                            localized: "command.rightSidebarMode.subtitle",
                            defaultValue: "Right Sidebar"
                        )
                )
                #expect(contribution.keywords.contains("right"))
                #expect(contribution.keywords.contains("sidebar"))
                #expect(contribution.keywords.contains(mode.rawValue))
                #expect(!contribution.when(unavailableContext))
                #expect(!contribution.when(panelWithoutPaneContext))
                #expect(contribution.when(availableContext))
                #expect(contribution.enablement(availableContext))
            }

            #expect(contributions.count == 3)
            #expect(
                contributionsByID[
                    ContentView.commandPaletteRightSidebarModeCommandID(.feed)
                ] == nil
            )
            #expect(
                contributionsByID[
                    ContentView.commandPaletteRightSidebarModeCommandID(.dock)
                ] == nil
            )
        }
    }

    @Test
    func toolPaneActionsRequireCapturedPanelAndPane() {
        let contributions = ContentView.commandPaletteRightSidebarToolPaneCommandContributions()
        let unavailableContext = CommandPaletteContextSnapshot()
        var panelWithoutPaneContext = CommandPaletteContextSnapshot()
        panelWithoutPaneContext.setBool(CommandPaletteContextKeys.hasFocusedPanel, true)
        var availableContext = CommandPaletteContextSnapshot()
        availableContext.setBool(CommandPaletteContextKeys.hasFocusedPanel, true)
        availableContext.setBool(CommandPaletteContextKeys.panelHasPane, true)

        #expect(!contributions.isEmpty)
        for contribution in contributions {
            #expect(!contribution.when(unavailableContext))
            #expect(!contribution.when(panelWithoutPaneContext))
            #expect(contribution.when(availableContext))
        }
    }

    @Test
    @MainActor
    func rejectionsBeepOnlyForCommandPaletteInvocations() {
        var beeps = 0
        let automationResult = ContentView.commandPaletteRightSidebarRejected(
            .targetUnavailable,
            invocation: CmuxActionInvocation(source: .automation),
            beep: { beeps += 1 }
        )

        #expect(automationResult == .targetUnavailable)
        #expect(beeps == 0)

        let paletteResult = ContentView.commandPaletteRightSidebarRejected(
            .targetUnavailable,
            invocation: CmuxActionInvocation(source: .commandPalette),
            beep: { beeps += 1 }
        )

        #expect(paletteResult == .targetUnavailable)
        #expect(beeps == 1)
    }

    @Test
    func modeActionsUseModeShortcutActions() {
        withSavedBetaFeatureDefaults {
            let defaults = UserDefaults.standard
            defaults.set(true, forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
            defaults.set(true, forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)

            for mode in RightSidebarMode.allCases {
                #expect(
                    ContentView.commandPaletteShortcutAction(
                        forCommandID: ContentView.commandPaletteRightSidebarModeCommandID(mode)
                    ) == mode.shortcutAction
                )
            }
        }
    }

    @Test
    func unreadActionsUseConfigurableShortcutActions() {
        #expect(
            ContentView.commandPaletteShortcutAction(forCommandID: "palette.toggleUnread")
                == .toggleUnread
        )
        #expect(
            ContentView.commandPaletteShortcutAction(
                forCommandID: "palette.markOldestUnreadAndJumpNext"
            ) == .markOldestUnreadAndJumpNext
        )
    }

    private func withSavedBetaFeatureDefaults(
        _ body: () throws -> Void
    ) rethrows {
        let defaults = UserDefaults.standard
        let previousFeed = defaults.object(
            forKey: RightSidebarBetaFeatureSettings.feedEnabledKey
        )
        let previousDock = defaults.object(
            forKey: RightSidebarBetaFeatureSettings.dockEnabledKey
        )
        defer {
            restore(previousFeed, forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
            restore(previousDock, forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)
        }
        try body()
    }

    private func restore(_ value: Any?, forKey key: String) {
        let defaults = UserDefaults.standard
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
