import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Immediate fork execution and palette dismissal
extension CommandPaletteSearchEngineTests {
    func testImmediateForkExecutionRejectsFallbackSnapshotBeforeProbeVerification() {
        let workspaceId = UUID()
        let panelId = UUID()
        let fallback = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "fallback-codex-session",
            workingDirectory: "/tmp/fallback repo",
            launchCommand: nil
        )

        let snapshot = ContentView.commandPaletteImmediateForkExecutionSnapshot(
            workspaceId: workspaceId,
            panelId: panelId,
            isRemoteTerminal: false,
            supportedPanelKeys: [],
            supportedRemoteContextsByPanelKey: [:],
            snapshotFingerprintsByPanelKey: [:],
            fallbackSnapshot: fallback,
            cachedSnapshot: nil
        )

        XCTAssertNil(snapshot)
    }

    func testImmediateForkExecutionPrefersVerifiedCachedSnapshotForSynchronousFallback() {
        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = ContentView.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        let fallback = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "restored-codex-session",
            workingDirectory: "/tmp/restored repo",
            launchCommand: nil
        )
        let cached = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "live-codex-session",
            workingDirectory: "/tmp/live repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/opt/homebrew/bin/codex",
                arguments: ["/opt/homebrew/bin/codex", "resume", "live-codex-session"],
                workingDirectory: "/tmp/live repo",
                environment: nil,
                capturedAt: 124,
                source: "process"
            )
        )
        let fingerprint = ContentView.commandPaletteForkSnapshotFingerprint(fallback)

        let selection = ContentView.commandPaletteImmediateForkExecutionSnapshotSelection(
            workspaceId: workspaceId,
            panelId: panelId,
            isRemoteTerminal: false,
            supportedPanelKeys: [panelKey],
            supportedRemoteContextsByPanelKey: [panelKey: false],
            snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
            fallbackSnapshot: fallback,
            cachedSnapshot: cached
        )

        XCTAssertEqual(selection?.snapshot.sessionId, cached.sessionId)
        XCTAssertEqual(selection?.usedFallbackSnapshot, false)
        XCTAssertFalse(
            ContentView.commandPaletteShouldClearForkableAgentProbeResultBeforeProbe(
                panelKey: panelKey,
                supportedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: false],
                snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
                expectedSnapshotFingerprint: fingerprint,
                isRemoteTerminal: false,
                cachedResultHadFallback: selection?.usedFallbackSnapshot ?? true,
                panelChanged: false
            )
        )
    }

    func testImmediateForkExecutionUsesProbeVerifiedFallbackSnapshot() {
        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = ContentView.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        let fallback = SessionRestorableAgentSnapshot(
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
        let fingerprint = ContentView.commandPaletteForkSnapshotFingerprint(fallback)

        let selection = ContentView.commandPaletteImmediateForkExecutionSnapshotSelection(
            workspaceId: workspaceId,
            panelId: panelId,
            isRemoteTerminal: false,
            supportedPanelKeys: [panelKey],
            supportedRemoteContextsByPanelKey: [panelKey: false],
            snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
            fallbackSnapshot: fallback,
            cachedSnapshot: nil
        )

        XCTAssertEqual(selection?.snapshot.sessionId, fallback.sessionId)
        XCTAssertEqual(selection?.usedFallbackSnapshot, true)
    }

    func testImmediateForkExecutionPrefersProbeVerifiedCachedSnapshot() {
        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = ContentView.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        let fallback = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "restored-opencode-session",
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
        let cached = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "live-opencode-session",
            workingDirectory: "/tmp/opencode repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "/opt/homebrew/bin/opencode",
                arguments: ["/opt/homebrew/bin/opencode"],
                workingDirectory: "/tmp/opencode repo",
                environment: nil,
                capturedAt: 124,
                source: "process"
            )
        )
        let fingerprint = ContentView.commandPaletteForkSnapshotFingerprint(fallback)

        let selection = ContentView.commandPaletteImmediateForkExecutionSnapshotSelection(
            workspaceId: workspaceId,
            panelId: panelId,
            isRemoteTerminal: false,
            supportedPanelKeys: [panelKey],
            supportedRemoteContextsByPanelKey: [panelKey: false],
            snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
            fallbackSnapshot: fallback,
            cachedSnapshot: cached
        )

        XCTAssertEqual(selection?.snapshot.sessionId, cached.sessionId)
        XCTAssertEqual(selection?.usedFallbackSnapshot, false)
    }

    func testImmediateForkExecutionRejectsStaleProbeFingerprint() {
        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = ContentView.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        let fallback = SessionRestorableAgentSnapshot(
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

        let snapshot = ContentView.commandPaletteImmediateForkExecutionSnapshot(
            workspaceId: workspaceId,
            panelId: panelId,
            isRemoteTerminal: false,
            supportedPanelKeys: [panelKey],
            supportedRemoteContextsByPanelKey: [panelKey: false],
            snapshotFingerprintsByPanelKey: [panelKey: "stale-fingerprint"],
            fallbackSnapshot: fallback,
            cachedSnapshot: nil
        )

        XCTAssertNil(snapshot)
    }

    func testForkCommandsDismissPaletteBeforeRunning() {
        let forkCommandIds = [
            "palette.forkAgentConversationRight",
            "palette.forkAgentConversationLeft",
            "palette.forkAgentConversationTop",
            "palette.forkAgentConversationBottom",
            "palette.forkAgentConversationNewTab",
            "palette.forkAgentConversationNewWorkspace"
        ]

        for commandId in forkCommandIds {
            XCTAssertTrue(ContentView.commandPaletteShouldDismissBeforeRun(forCommandId: commandId))
        }
        XCTAssertFalse(ContentView.commandPaletteShouldDismissBeforeRun(forCommandId: "palette.terminalSplitRight"))
        XCTAssertFalse(ContentView.commandPaletteShouldDismissBeforeRun(forCommandId: "palette.terminalFocusTextBoxInput"))
    }

}
