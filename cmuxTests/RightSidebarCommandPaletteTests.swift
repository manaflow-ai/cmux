import Darwin
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class RightSidebarCommandPaletteTests: XCTestCase {
    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let timedOut: Bool
    }

    func testCommandPaletteIncludesGuiModeCommand() throws {
        let contributions = ContentView.commandPaletteViewCommandContributions()
        let contribution = try XCTUnwrap(
            contributions.first { $0.commandId == GuiModeWorkspaceCoordinator.commandPaletteCommandId }
        )

        XCTAssertTrue(contribution.keywords.contains("gui"))
        XCTAssertTrue(contribution.keywords.contains("worktree"))
    }

    func testGuiModeTaskPromptShellQuotingKeepsMetacharactersLiteral() {
        let cases = [
            ("", "''"),
            ("   ", "'   '"),
            ("build Lawrence's thing", "'build Lawrence'\\''s thing'"),
            ("`uname`", "'`uname`'"),
            ("$HOME", "'$HOME'"),
            ("line one\nline two", "'line one\nline two'"),
            (#"back\slash"#, #"'back\slash'"#),
            (#""quoted""#, "'\"quoted\"'"),
        ]

        for (input, expected) in cases {
            XCTAssertEqual(GuiModeWorkspaceCoordinator.shellQuoted(input), expected)
        }
    }

    func testGuiModeTaskWorkspaceTitleCollapsesWhitespace() {
        XCTAssertEqual(
            GuiModeWorkspaceCoordinator.taskWorkspaceTitle(prompt: "  build\n\tthe   provider  UI  "),
            "GUI: build the provider UI"
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
            XCTAssertTrue(provider.accentColor.hasPrefix("#"))
            XCTAssertEqual(provider.accentColor.count, 7)
            XCTAssertFalse(provider.setupCommand.isEmpty)
            XCTAssertFalse(provider.taskCommandPreview.isEmpty)
            XCTAssertFalse(provider.capabilityLabels.isEmpty)
        }
    }

    func testGuiModeHookBackedProvidersMatchBundledCLIHookAgents() throws {
        let cliPath = try bundledCLIPath()
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "agents", "--json"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        let data = try XCTUnwrap(result.stdout.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let agents = try XCTUnwrap(object["agents"] as? [[String: Any]])
        let hookBackedProviderIDs = agents.compactMap { $0["name"] as? String }
        let guiHookBackedProviderIDs = GuiModeProviderID.allCases
            .filter { $0 != .claude }
            .map(\.rawValue)

        XCTAssertEqual(Set(hookBackedProviderIDs), Set(guiHookBackedProviderIDs))
        for agent in agents {
            let name = try XCTUnwrap(agent["name"] as? String)
            XCTAssertEqual(agent["installCommand"] as? String, "cmux hooks \(name) install")
            XCTAssertFalse((agent["displayName"] as? String ?? "").isEmpty)
            XCTAssertFalse((agent["statusKey"] as? String ?? "").isEmpty)
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
    func testGuiModeTaskWorkspaceInitialStateBootsTaskPanel() throws {
        let manager = TabManager()
        let prompt = "Build a provider catalog smoke test"

        let workspace = manager.addWorkspace(
            title: "GUI task",
            initialSurface: .guiMode,
            initialGuiModeState: .taskWorktreePR(prompt: prompt, providerID: .qoder),
            autoRefreshMetadata: false
        )

        XCTAssertEqual(manager.selectedTabId, workspace.id)
        XCTAssertEqual(workspace.panels.count, 1)
        let guiPanel = try XCTUnwrap(workspace.panels.values.first as? AgentSessionPanel)
        XCTAssertEqual(guiPanel.rendererKind, .guiMode)
        XCTAssertEqual(guiPanel.guiModePage, .taskWorktreePR)
        XCTAssertEqual(guiPanel.guiModePrompt, prompt)
        XCTAssertEqual(guiPanel.guiModeProviderID, .qoder)
        XCTAssertFalse(guiPanel.workingDirectory?.isEmpty ?? true)
        XCTAssertEqual(
            guiPanel.displayTitle,
            String(localized: "guiMode.task.panel.title", defaultValue: "/task-worktree-pr")
        )

        XCTAssertEqual(workspace.bonsplitController.allTabIds.count, 1)
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
            XCTAssertNotNil(provider["accentColor"] as? String)
            XCTAssertNotNil(provider["detail"] as? String)
            XCTAssertNotNil(provider["runtimeMode"] as? String)
            XCTAssertNotNil(provider["supportLabel"] as? String)
            XCTAssertNotNil(provider["setupCommand"] as? String)
            XCTAssertNotNil(provider["taskCommandPreview"] as? String)
            XCTAssertFalse((provider["capabilities"] as? [String] ?? []).isEmpty)
        }
        let copy = try XCTUnwrap(payload["copy"] as? [String: String])
        for key in [
            "errorMessage",
            "homeTitle",
            "noProvidersFound",
            "promptPlaceholder",
            "providerLabel",
            "providerSearchPlaceholder",
            "runtimeLabel",
            "setupCommandLabel",
            "submit",
            "submitting",
            "taskCommandLabel",
            "taskPromptLabel",
            "taskTitle",
        ] {
            XCTAssertFalse(copy[key]?.isEmpty ?? true, key)
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

    private func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: Self.self)
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: String(describing: error), timedOut: false)
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut,
               process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 1)
            }
        }

        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }
}
