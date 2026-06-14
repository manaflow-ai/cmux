import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class RightSidebarCommandPaletteTests: XCTestCase {
    func testCommandPaletteIncludesGuiModeCommand() throws {
        let contributions = ContentView.commandPaletteViewCommandContributions()
        let contribution = try XCTUnwrap(
            contributions.first { $0.commandId == GuiModeWorkspaceCoordinator.commandPaletteCommandId }
        )

        XCTAssertTrue(contribution.keywords.contains("gui"))
        XCTAssertTrue(contribution.keywords.contains("worktree"))
    }

    func testGuiModeTaskPromptShellQuotingKeepsPromptAsOneArgument() {
        XCTAssertEqual(
            GuiModeWorkspaceCoordinator.shellQuoted("build Lawrence's thing"),
            "'build Lawrence'\\''s thing'"
        )
    }

    func testGuiModeProviderCatalogMatchesHookedAgents() {
        XCTAssertEqual(
            GuiModeProviderID.allCases.map(\.rawValue),
            [
                "codex",
                "claude",
                "opencode",
                "grok",
                "pi",
                "omp",
                "amp",
                "cursor",
                "gemini",
                "kiro",
                "antigravity",
                "rovodev",
                "hermes-agent",
                "copilot",
                "codebuddy",
                "factory",
                "qoder",
            ]
        )

        for provider in GuiModeProviderID.allCases {
            XCTAssertFalse(provider.displayName.isEmpty)
            XCTAssertFalse(provider.detail.isEmpty)
            XCTAssertFalse(provider.supportLabel.isEmpty)
            XCTAssertFalse(provider.setupCommand.isEmpty)
            XCTAssertFalse(provider.taskCommandPreview.isEmpty)
            XCTAssertFalse(provider.capabilityLabels.isEmpty)
        }
    }

    func testGuiModeTaskCommandIncludesProviderForEveryAgent() {
        for provider in GuiModeProviderID.allCases {
            XCTAssertEqual(
                GuiModeWorkspaceCoordinator.taskWorktreePRCommand(
                    prompt: "build Lawrence's thing",
                    providerID: provider
                ),
                "/task-worktree-pr --provider \(provider.rawValue) 'build Lawrence'\\''s thing'"
            )
        }
    }

    @MainActor
    func testGuiModeContextPayloadIncludesEveryProviderSnapshotField() throws {
        let payload = AgentSessionWebRendererCoordinator.guiModeContextPayload(
            page: .home,
            prompt: nil,
            selectedProviderID: .qoder
        )

        XCTAssertEqual(payload["selectedProviderId"] as? String, "qoder")
        let providers = try XCTUnwrap(payload["providers"] as? [[String: Any]])
        XCTAssertEqual(providers.map { $0["id"] as? String }, GuiModeProviderID.allCases.map(\.rawValue))

        for provider in providers {
            XCTAssertNotNil(provider["displayName"] as? String)
            XCTAssertNotNil(provider["detail"] as? String)
            XCTAssertNotNil(provider["runtimeMode"] as? String)
            XCTAssertNotNil(provider["supportLabel"] as? String)
            XCTAssertNotNil(provider["setupCommand"] as? String)
            XCTAssertNotNil(provider["taskCommandPreview"] as? String)
            XCTAssertFalse((provider["capabilities"] as? [String] ?? []).isEmpty)
        }
    }

    func testCommandPaletteIncludesDefaultRightSidebarModes() throws {
        try withSavedBetaFeatureDefaults {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
            defaults.removeObject(forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)
            let contributions = ContentView.commandPaletteRightSidebarModeCommandContributions()
            let contributionsByID = Dictionary(uniqueKeysWithValues: contributions.map { ($0.commandId, $0) })
            let context = ContentView.CommandPaletteContextSnapshot()

            for mode in RightSidebarMode.availableModes() {
                let commandID = ContentView.commandPaletteRightSidebarModeCommandID(mode)
                let contribution = try XCTUnwrap(
                    contributionsByID[commandID],
                    "Expected command palette contribution for \(mode.rawValue)"
                )

                XCTAssertEqual(contribution.title(context), mode.shortcutAction?.label ?? mode.label)
                XCTAssertEqual(
                    contribution.subtitle(context),
                    String(localized: "command.rightSidebarMode.subtitle", defaultValue: "Right Sidebar")
                )
                XCTAssertTrue(contribution.keywords.contains("right"))
                XCTAssertTrue(contribution.keywords.contains("sidebar"))
                XCTAssertTrue(contribution.keywords.contains(mode.rawValue))
                XCTAssertTrue(contribution.when(context))
                XCTAssertTrue(contribution.enablement(context))
            }

            XCTAssertEqual(contributions.count, 3)
            XCTAssertNil(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.feed)])
            XCTAssertNil(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.dock)])
        }
    }

    func testCommandPaletteRightSidebarActionsUseModeShortcutActions() {
        withSavedBetaFeatureDefaults {
            let defaults = UserDefaults.standard
            defaults.set(true, forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
            defaults.set(true, forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)

            for mode in RightSidebarMode.allCases {
                XCTAssertEqual(
                    ContentView.commandPaletteShortcutAction(
                        forCommandID: ContentView.commandPaletteRightSidebarModeCommandID(mode)
                    ),
                    mode.shortcutAction
                )
            }
        }
    }

    func testCommandPaletteUnreadActionsUseConfigurableShortcutActions() {
        XCTAssertEqual(
            ContentView.commandPaletteShortcutAction(forCommandID: "palette.toggleUnread"),
            .toggleUnread
        )
        XCTAssertEqual(
            ContentView.commandPaletteShortcutAction(forCommandID: "palette.markOldestUnreadAndJumpNext"),
            .markOldestUnreadAndJumpNext
        )
    }

    private func withSavedBetaFeatureDefaults(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previousFeed = defaults.object(forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
        let previousDock = defaults.object(forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)
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
