import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Forkable agent fingerprints and probe results
extension CommandPaletteSearchEngineTests {
    func testForkableAgentCacheKeepsVerifiedOpenCodeVisible() {
        let workspaceId = UUID()
        let panelId = UUID()
        let supportedKey = ContentView.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
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

        XCTAssertTrue(
            ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspaceId,
                panelId: panelId,
                supportedPanelKeys: [supportedKey],
                fallbackSnapshot: directOpenCode
            )
        )
    }

    func testForkableAgentSnapshotFingerprintChangesWithSession() {
        let first = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "first-session",
            workingDirectory: "/tmp/repo",
            launchCommand: nil
        )
        let second = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "second-session",
            workingDirectory: "/tmp/repo",
            launchCommand: nil
        )

        XCTAssertNotEqual(
            ContentView.commandPaletteForkSnapshotFingerprint(first),
            ContentView.commandPaletteForkSnapshotFingerprint(second)
        )
    }

    func testForkableAgentSnapshotFingerprintChangesWithForkCommand() {
        let launchCommand = AgentLaunchCommandSnapshot(
            launcher: "codex",
            executablePath: "/usr/local/bin/codex",
            arguments: ["/usr/local/bin/codex"],
            workingDirectory: "/tmp/repo",
            environment: nil,
            capturedAt: 123,
            source: "process"
        )
        let first = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-session",
            workingDirectory: "/tmp/repo",
            launchCommand: launchCommand
        )
        var second = first
        second.registration = CmuxVaultAgentRegistration(
            id: "fork-fingerprint",
            name: "Fork Fingerprint",
            detect: CmuxVaultAgentDetectRule(processName: "fork-fingerprint"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "{{executable}} resume {{sessionId}}",
            cwd: .ignore
        )

        XCTAssertNotEqual(first.forkCommand, second.forkCommand)
        XCTAssertNotEqual(
            ContentView.commandPaletteForkSnapshotFingerprint(first),
            ContentView.commandPaletteForkSnapshotFingerprint(second)
        )
    }

    func testForkableAgentCacheFingerprintUsesFallbackFingerprintAfterProbe() {
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
        let processDetected = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-session",
            workingDirectory: "/tmp/opencode repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "/opt/homebrew/bin/opencode",
                arguments: ["/opt/homebrew/bin/opencode"],
                workingDirectory: "/tmp/opencode repo",
                environment: nil,
                capturedAt: nil,
                source: "process"
            )
        )
        let fallbackFingerprint = ContentView.commandPaletteForkSnapshotFingerprint(fallback)
        let processFingerprint = ContentView.commandPaletteForkSnapshotFingerprint(processDetected)

        XCTAssertNotEqual(fallbackFingerprint, processFingerprint)
        XCTAssertEqual(
            ContentView.commandPaletteForkCacheFingerprint(
                snapshot: processDetected,
                fallbackFingerprint: fallbackFingerprint
            ),
            fallbackFingerprint
        )
        XCTAssertEqual(
            ContentView.commandPaletteForkCacheFingerprint(
                snapshot: processDetected,
                fallbackFingerprint: nil
            ),
            processFingerprint
        )
    }

    func testForkableAgentProbeResultReuseRequiresCurrentPanelSession() {
        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = ContentView.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        let fingerprint = "verified-fingerprint"

        XCTAssertTrue(
            ContentView.commandPaletteShouldReuseForkableAgentProbeResult(
                panelKey: panelKey,
                supportedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: false],
                snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
                expectedSnapshotFingerprint: fingerprint,
                isRemoteTerminal: false,
                cachedResultHadFallback: false,
                panelChanged: false
            )
        )
        XCTAssertFalse(
            ContentView.commandPaletteShouldReuseForkableAgentProbeResult(
                panelKey: panelKey,
                supportedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: false],
                snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
                expectedSnapshotFingerprint: fingerprint,
                isRemoteTerminal: false,
                cachedResultHadFallback: false,
                panelChanged: true
            )
        )
        XCTAssertFalse(
            ContentView.commandPaletteShouldReuseForkableAgentProbeResult(
                panelKey: panelKey,
                supportedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: false],
                snapshotFingerprintsByPanelKey: [panelKey: "stale-fingerprint"],
                expectedSnapshotFingerprint: fingerprint,
                isRemoteTerminal: false,
                cachedResultHadFallback: false,
                panelChanged: false
            )
        )
        XCTAssertFalse(
            ContentView.commandPaletteShouldReuseForkableAgentProbeResult(
                panelKey: panelKey,
                supportedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: true],
                snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
                expectedSnapshotFingerprint: fingerprint,
                isRemoteTerminal: false,
                cachedResultHadFallback: false,
                panelChanged: false
            )
        )
        XCTAssertFalse(
            ContentView.commandPaletteShouldReuseForkableAgentProbeResult(
                panelKey: panelKey,
                supportedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: false],
                snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
                expectedSnapshotFingerprint: nil,
                isRemoteTerminal: false,
                cachedResultHadFallback: true,
                panelChanged: false
            )
        )
    }

    func testForkableAgentProbeResultClearBeforeProbeClearsFallbackBackedCache() {
        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = ContentView.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        let fingerprint = "verified-fingerprint"

        XCTAssertFalse(
            ContentView.commandPaletteShouldClearForkableAgentProbeResultBeforeProbe(
                panelKey: panelKey,
                supportedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: false],
                snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
                expectedSnapshotFingerprint: fingerprint,
                isRemoteTerminal: false,
                cachedResultHadFallback: false,
                panelChanged: false
            )
        )
        XCTAssertTrue(
            ContentView.commandPaletteShouldClearForkableAgentProbeResultBeforeProbe(
                panelKey: panelKey,
                supportedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: false],
                snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
                expectedSnapshotFingerprint: fingerprint,
                isRemoteTerminal: false,
                cachedResultHadFallback: true,
                panelChanged: false
            )
        )
        XCTAssertTrue(
            ContentView.commandPaletteShouldClearForkableAgentProbeResultBeforeProbe(
                panelKey: panelKey,
                supportedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: false],
                snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
                expectedSnapshotFingerprint: fingerprint,
                isRemoteTerminal: false,
                cachedResultHadFallback: false,
                panelChanged: true
            )
        )
        XCTAssertTrue(
            ContentView.commandPaletteShouldClearForkableAgentProbeResultBeforeProbe(
                panelKey: panelKey,
                supportedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: false],
                snapshotFingerprintsByPanelKey: [panelKey: "stale-fingerprint"],
                expectedSnapshotFingerprint: fingerprint,
                isRemoteTerminal: false,
                cachedResultHadFallback: false,
                panelChanged: false
            )
        )
    }

    func testForkableAgentMatchedFallbackProbePreservesVerifiedCacheUsage() {
        XCTAssertFalse(
            ContentView.commandPaletteForkMatchedFallbackProbeResultHadFallback(
                cachedResultHadFallback: false
            )
        )
        XCTAssertTrue(
            ContentView.commandPaletteForkMatchedFallbackProbeResultHadFallback(
                cachedResultHadFallback: true
            )
        )
        XCTAssertTrue(
            ContentView.commandPaletteForkMatchedFallbackProbeResultHadFallback(
                cachedResultHadFallback: nil
            )
        )
    }

    func testForkableAgentProbeResultMatchIgnoresPaletteSession() {
        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = ContentView.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        let fingerprint = "verified-fingerprint"

        XCTAssertTrue(
            ContentView.commandPaletteForkableAgentProbeResultMatches(
                panelKey: panelKey,
                supportedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: false],
                snapshotFingerprintsByPanelKey: [panelKey: fingerprint],
                expectedSnapshotFingerprint: fingerprint,
                isRemoteTerminal: false
            )
        )
        XCTAssertFalse(
            ContentView.commandPaletteForkableAgentProbeResultMatches(
                panelKey: panelKey,
                supportedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: false],
                snapshotFingerprintsByPanelKey: [panelKey: "stale-fingerprint"],
                expectedSnapshotFingerprint: fingerprint,
                isRemoteTerminal: false
            )
        )
    }

}
