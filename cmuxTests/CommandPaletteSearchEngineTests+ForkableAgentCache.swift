import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Fork command ranking and forkable agent cache visibility
extension CommandPaletteSearchEngineTests {
    func testExactForkQueryPinsForkRightBeforeOtherForkCommands() {
        let entries = [
            FixtureEntry(
                id: "palette.forkAgentConversationLeft",
                rank: 0,
                title: "Fork Conversation to the Left",
                searchableTexts: ["Fork Conversation to the Left", "Terminal", "fork", "left"]
            ),
            FixtureEntry(
                id: "palette.forkAgentConversationRight",
                rank: 4,
                title: "Fork Conversation to the Right",
                searchableTexts: ["Fork Conversation to the Right", "Terminal", "fork", "right"]
            ),
            FixtureEntry(
                id: "palette.forkAgentConversationNewTab",
                rank: 2,
                title: "Fork Conversation to New Tab",
                searchableTexts: ["Fork Conversation to New Tab", "Terminal", "fork", "new", "tab"]
            ),
            FixtureEntry(
                id: "palette.forkAgentConversationNewWorkspace",
                rank: 1,
                title: "Fork Conversation to New Workspace",
                searchableTexts: ["Fork Conversation to New Workspace", "Workspace", "fork", "new", "workspace"]
            ),
        ]
        let corpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }

        let results = CommandPaletteSearchEngine.search(
            entries: corpus,
            query: "fork"
        ) { commandId, _ in
            ContentView.commandPaletteForkPriorityBoost(commandId: commandId, query: "fork")
        }

        XCTAssertEqual(results.map(\.payload).first, "palette.forkAgentConversationRight")
    }

    func testForkableAgentCacheKeepsPanelVisibleWithoutFallbackSnapshot() {
        let workspaceId = UUID()
        let panelId = UUID()
        let supportedKey = ContentView.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )

        XCTAssertFalse(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [],
                fallbackSnapshot: nil
            )
        )
        XCTAssertTrue(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [supportedKey],
                fallbackSnapshot: nil
            )
        )
        XCTAssertFalse(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: UUID(),
                supportedPanelKeys: [supportedKey],
                fallbackSnapshot: nil
            )
        )
        XCTAssertFalse(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: UUID(),
                panelId: panelId,
                supportedPanelKeys: [supportedKey],
                fallbackSnapshot: nil
            )
        )
    }

    func testForkableAgentCacheRequiresMatchingRemoteContextWithoutFallbackSnapshot() {
        let workspaceId = UUID()
        let panelId = UUID()
        let supportedKey = ContentView.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )

        XCTAssertTrue(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [supportedKey],
                supportedRemoteContextsByPanelKey: [supportedKey: false],
                fallbackSnapshot: nil,
                isRemoteTerminal: false
            )
        )
        XCTAssertFalse(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [supportedKey],
                supportedRemoteContextsByPanelKey: [supportedKey: false],
                fallbackSnapshot: nil,
                isRemoteTerminal: true
            )
        )
        XCTAssertTrue(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [supportedKey],
                supportedRemoteContextsByPanelKey: [supportedKey: true],
                fallbackSnapshot: nil,
                isRemoteTerminal: true
            )
        )
        XCTAssertFalse(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [supportedKey],
                supportedRemoteContextsByPanelKey: [supportedKey: true],
                fallbackSnapshot: nil,
                isRemoteTerminal: false
            )
        )
    }

    func testForkableAgentFallbackSnapshotRequiresVerifiedProbeForVisibility() {
        let workspaceId = UUID()
        let panelId = UUID()
        let supportedKey = ContentView.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        let codex = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-session",
            workingDirectory: nil,
            launchCommand: nil
        )
        let directOpenCode = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-session",
            workingDirectory: "/tmp/opencode repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "/opt/homebrew/bin/opencode",
                arguments: ["/opt/homebrew/bin/opencode"],
                workingDirectory: "/tmp/opencode repo",
                environment: nil,
                capturedAt: 123,
                source: "environment"
            )
        )
        let omoOpenCode = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "omo-session",
            workingDirectory: "/tmp/opencode repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "omo",
                executablePath: "/usr/local/bin/cmux",
                arguments: ["/usr/local/bin/cmux", "omo"],
                workingDirectory: "/tmp/opencode repo",
                environment: nil,
                capturedAt: 123,
                source: "environment"
            )
        )

        XCTAssertFalse(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [],
                fallbackSnapshot: codex
            )
        )
        XCTAssertTrue(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [supportedKey],
                supportedRemoteContextsByPanelKey: [supportedKey: false],
                fallbackSnapshot: codex
            )
        )
        XCTAssertFalse(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [],
                fallbackSnapshot: directOpenCode
            )
        )
        XCTAssertFalse(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [],
                fallbackSnapshot: directOpenCode,
                isRemoteTerminal: true
            )
        )
        XCTAssertTrue(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [supportedKey],
                supportedRemoteContextsByPanelKey: [supportedKey: true],
                fallbackSnapshot: directOpenCode,
                isRemoteTerminal: true
            )
        )
        XCTAssertFalse(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [],
                fallbackSnapshot: omoOpenCode
            )
        )
        XCTAssertTrue(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [supportedKey],
                supportedRemoteContextsByPanelKey: [supportedKey: false],
                fallbackSnapshot: omoOpenCode
            )
        )
    }

    func testForkableAgentRemoteFallbackRejectsCommandsThatRequireLocalLauncherScript() {
        let workspaceId = UUID()
        let panelId = UUID()
        let supportedKey = ContentView.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        let longPath = "/Users/cmux/" + String(repeating: "nested-project-", count: 120)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: "/Users/cmux/project",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: [
                    "/Users/example/.bun/bin/codex",
                    "--model",
                    "gpt-5.4",
                    "--add-dir",
                    longPath
                ],
                workingDirectory: "/Users/cmux/project",
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        XCTAssertNotNil(snapshot.forkStartupInput(allowLauncherScript: true))
        XCTAssertNil(snapshot.forkStartupInput(allowLauncherScript: false))
        XCTAssertFalse(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [],
                fallbackSnapshot: snapshot
            )
        )
        XCTAssertTrue(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [supportedKey],
                supportedRemoteContextsByPanelKey: [supportedKey: false],
                fallbackSnapshot: snapshot
            )
        )
        XCTAssertFalse(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [],
                fallbackSnapshot: snapshot,
                isRemoteTerminal: true
            )
        )
        XCTAssertFalse(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [supportedKey],
                fallbackSnapshot: snapshot,
                isRemoteTerminal: true
            )
        )
    }

    func testForkableAgentCacheDoesNotOverrideUnsupportedCurrentSnapshot() {
        let workspaceId = UUID()
        let panelId = UUID()
        let supportedKey = ContentView.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        let unsupported = SessionRestorableAgentSnapshot(
            kind: .custom("unsupported-agent"),
            sessionId: "unsupported-session",
            workingDirectory: nil,
            launchCommand: nil
        )

        XCTAssertFalse(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [supportedKey],
                fallbackSnapshot: unsupported
            )
        )
    }

}
