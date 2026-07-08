import Darwin
import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct ForkParentFallbackSessionIndexTests {
    @Test func unpromptedForkPaneUsesParentSessionFallbackWithoutStealingParentPane() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let detected = detectedSnapshots(
            fixture: fixture,
            argv: ["/usr/local/bin/claude", "--resume", fixture.parentSessionId, "--fork-session", "--model", "sonnet"]
        )
        let index = loadIndex(fixture: fixture, detectedSnapshots: detected)

        let forkSnapshot = try #require(index.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.forkPanelId))
        #expect(forkSnapshot.kind == .claude)
        #expect(forkSnapshot.sessionId == fixture.parentSessionId)
        #expect(forkSnapshot.workingDirectory == fixture.cwd.path)
        #expect(forkSnapshot.launchCommand?.arguments == ["/usr/local/bin/claude", "--model", "sonnet"])
        let forkCommand = try #require(forkSnapshot.forkCommand)
        #expect(forkCommand.contains(fixture.parentSessionId), "\(forkCommand)")
        #expect(forkCommand.contains("--fork-session"), "\(forkCommand)")

        let parentSnapshot = try #require(index.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.parentPanelId))
        #expect(parentSnapshot.sessionId == fixture.parentSessionId)
    }

    @Test func promptedForkPaneHookIdentityWinsOverParentFallback() throws {
        let fixture = try makeFixture(forkedSessionId: "bbbbbbbb-2222-2222-2222-bbbbbbbbbbbb")
        defer { fixture.cleanup() }

        let detected = detectedSnapshots(
            fixture: fixture,
            argv: ["/usr/local/bin/claude", "--resume", fixture.parentSessionId, "--fork-session"]
        )
        let index = loadIndex(fixture: fixture, detectedSnapshots: detected)

        let forkSnapshot = try #require(index.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.forkPanelId))
        let forkedSessionId = try #require(fixture.forkedSessionId)
        #expect(forkSnapshot.sessionId == forkedSessionId)
        #expect(index.processIDs(workspaceId: fixture.workspaceId, panelId: fixture.forkPanelId) == [fixture.forkProcessID])
    }

    @Test func forkParentFallbackIgnoresNonClaudeProcessWithInheritedLaunchEnvironment() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        // A tool spawned inside a claude pane inherits CMUX_AGENT_LAUNCH_* but is not
        // the launched claude executable; ambient environment alone must not mint a
        // fork fallback for the pane.
        let detected = detectedSnapshots(
            fixture: fixture,
            argv: ["/usr/local/bin/some-tool", "--resume", fixture.parentSessionId, "--fork-session"],
            extraEnvironment: ["CMUX_AGENT_LAUNCH_EXECUTABLE": "/usr/local/bin/claude"],
            processName: "some-tool",
            processPath: "/usr/local/bin/some-tool"
        )

        #expect(detected[RestorableAgentSessionIndex.PanelKey(
            workspaceId: fixture.workspaceId,
            panelId: fixture.forkPanelId
        )] == nil)
    }

    @Test func forkParentFallbackAcceptsCustomClaudeBinaryMatchingLaunchExecutable() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        // A custom claude binary (CMUX_CUSTOM_CLAUDE_PATH) has a non-"claude" basename;
        // the launch-kind token plus the recorded launch executable identify it.
        let detected = detectedSnapshots(
            fixture: fixture,
            argv: ["/opt/tools/claude-custom", "--resume", fixture.parentSessionId, "--fork-session", "--model", "sonnet"],
            extraEnvironment: ["CMUX_AGENT_LAUNCH_EXECUTABLE": "/opt/tools/claude-custom"],
            processName: "claude-custom",
            processPath: "/opt/tools/claude-custom"
        )

        let entry = try #require(detected[RestorableAgentSessionIndex.PanelKey(
            workspaceId: fixture.workspaceId,
            panelId: fixture.forkPanelId
        )])
        #expect(entry.snapshot.sessionId == fixture.parentSessionId)
        // The custom binary is an executable boundary: sanitizer-preserved flags stay,
        // and the logical executable is bare "claude" (the cmux wrapper resolves
        // CMUX_CUSTOM_CLAUDE_PATH at exec time).
        #expect(entry.snapshot.launchCommand?.arguments == ["claude", "--model", "sonnet"])
    }

    @Test func forkParentFallbackIgnoresExplicitlyDisabledForkSessionFlag() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        // Mirrors the hook CLI: --fork-session=off is an explicit false value, so a
        // resumed pane must not be treated as an unprompted fork.
        let detected = detectedSnapshots(
            fixture: fixture,
            argv: ["/usr/local/bin/claude", "--resume", fixture.parentSessionId, "--fork-session=off"]
        )

        #expect(detected[RestorableAgentSessionIndex.PanelKey(
            workspaceId: fixture.workspaceId,
            panelId: fixture.forkPanelId
        )] == nil)
    }

    @Test func staleSamePaneHookRecordDoesNotCaptureForkLaunchedAfterIt() throws {
        // The fork pane reuses a terminal whose older claude session (updatedAt 10)
        // is still in the hook store, and the fork process started later
        // (startSeconds 15): the stale record must not absorb the fork's live
        // process evidence; the pane resolves to the parent-session fallback.
        let fixture = try makeFixture(
            forkedSessionId: "dddddddd-4444-4444-4444-dddddddddddd",
            forkPaneRecordUpdatedAt: 10
        )
        defer { fixture.cleanup() }

        let detected = detectedSnapshots(
            fixture: fixture,
            argv: ["/usr/local/bin/claude", "--resume", fixture.parentSessionId, "--fork-session"]
        )
        let index = loadIndex(
            fixture: fixture,
            detectedSnapshots: detected,
            processIdentityProvider: { pid in
                pid == fixture.forkProcessID
                    ? AgentPIDProcessIdentity(pid: pid_t(pid), startSeconds: 15, startMicroseconds: 0)
                    : nil
            }
        )

        let forkSnapshot = try #require(index.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.forkPanelId))
        #expect(forkSnapshot.sessionId == fixture.parentSessionId)
    }

    @Test func forkParentFallbackYieldsToOtherAgentKindHookEntryOnSamePane() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        // The fork-shaped claude process is a nested child inside an opencode pane
        // (it inherits the pane's cmux scope); the pane's opencode hook identity
        // must survive the fallback.
        try writeHookStore(
            root: fixture.root,
            storeFilename: "opencode-hook-sessions.json",
            sessions: [
                "oc-session-1": [
                    "sessionId": "oc-session-1",
                    "workspaceId": fixture.workspaceId.uuidString,
                    "surfaceId": fixture.forkPanelId.uuidString,
                    "cwd": fixture.cwd.path,
                    "updatedAt": 30,
                    "launchCommand": [
                        "launcher": "opencode",
                        "executablePath": "/usr/local/bin/opencode",
                        "arguments": ["/usr/local/bin/opencode"],
                        "workingDirectory": fixture.cwd.path,
                        "capturedAt": 30,
                        "source": "test",
                    ],
                ],
            ]
        )

        let detected = detectedSnapshots(
            fixture: fixture,
            argv: ["/usr/local/bin/claude", "--resume", fixture.parentSessionId, "--fork-session"]
        )
        let index = loadIndex(fixture: fixture, detectedSnapshots: detected)

        let paneSnapshot = try #require(index.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.forkPanelId))
        #expect(paneSnapshot.kind == .opencode)
        #expect(paneSnapshot.sessionId == "oc-session-1")
    }

    @Test func mintedForkChildRecordUpdatedAfterProcessStartStillWins() throws {
        // Same shape as the stale-record case, but the pane record (updatedAt 20)
        // was written after the fork process started (startSeconds 15): it is the
        // fork's own minted child session and keeps the pane.
        let fixture = try makeFixture(forkedSessionId: "bbbbbbbb-2222-2222-2222-bbbbbbbbbbbb")
        defer { fixture.cleanup() }

        let detected = detectedSnapshots(
            fixture: fixture,
            argv: ["/usr/local/bin/claude", "--resume", fixture.parentSessionId, "--fork-session"]
        )
        let index = loadIndex(
            fixture: fixture,
            detectedSnapshots: detected,
            processIdentityProvider: { pid in
                pid == fixture.forkProcessID
                    ? AgentPIDProcessIdentity(pid: pid_t(pid), startSeconds: 15, startMicroseconds: 0)
                    : nil
            }
        )

        let forkSnapshot = try #require(index.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.forkPanelId))
        let forkedSessionId = try #require(fixture.forkedSessionId)
        #expect(forkSnapshot.sessionId == forkedSessionId)
    }

    @Test func forkParentFallbackIgnoresWrapperInjectedSessionID() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let detected = detectedSnapshots(
            fixture: fixture,
            argv: [
                "/usr/local/bin/claude",
                "--session-id", "cccccccc-3333-3333-3333-cccccccccccc",
                "--resume", fixture.parentSessionId,
                "--fork-session",
            ]
        )

        #expect(detected[RestorableAgentSessionIndex.PanelKey(
            workspaceId: fixture.workspaceId,
            panelId: fixture.forkPanelId
        )] == nil)
    }

    @Test func forkParentFallbackDoesNotEvictParentHookEntryForSameSession() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let detected = detectedSnapshots(
            fixture: fixture,
            argv: ["/usr/local/bin/claude", "--resume=\(fixture.parentSessionId)", "--fork-session=true"]
        )
        let index = loadIndex(fixture: fixture, detectedSnapshots: detected)

        #expect(
            index.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.parentPanelId)?.sessionId
                == fixture.parentSessionId
        )
        #expect(
            index.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.forkPanelId)?.sessionId
                == fixture.parentSessionId
        )
    }

    @Test func unpromptedForkPaneIsForkValidatedFromLiveProcessFallback() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let processSnapshot = snapshot(fixture: fixture)
        let processArguments = claudeProcessArguments(
            fixture: fixture,
            argv: ["/usr/local/bin/claude", "-r", fixture.parentSessionId, "--fork-session", "--model", "sonnet"]
        )
        let identity = AgentPIDProcessIdentity(
            pid: pid_t(fixture.forkProcessID),
            startSeconds: 1,
            startMicroseconds: 2
        )
        let result = SharedLiveAgentIndexLoader(
            homeDirectory: fixture.root.path,
            fileManager: fixture.fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            processSnapshotProvider: { processSnapshot },
            capturedAtProvider: { 42 },
            processArgumentsProvider: { $0 == fixture.forkProcessID ? processArguments : nil },
            processIdentityProvider: { $0 == fixture.forkProcessID ? identity : nil }
        ).loadResultSynchronously()

        #expect(result.forkValidatedPanels.contains(RestorableAgentSessionIndex.PanelKey(
            workspaceId: fixture.workspaceId,
            panelId: fixture.forkPanelId
        )))
    }

    private struct Fixture {
        let fileManager: FileManager
        let root: URL
        let cwd: URL
        let configDir: URL
        let workspaceId: UUID
        let parentPanelId: UUID
        let forkPanelId: UUID
        let parentSessionId: String
        let forkedSessionId: String?
        let forkProcessID: Int

        func cleanup() {
            try? fileManager.removeItem(at: root)
        }
    }

    private func makeFixture(
        forkedSessionId: String? = nil,
        forkPaneRecordUpdatedAt: TimeInterval = 20
    ) throws -> Fixture {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-claude-fork-fallback-\(UUID().uuidString)", isDirectory: true)
        let cwd = root.appendingPathComponent("repo", isDirectory: true)
        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let projectsDir = configDir.appendingPathComponent("projects", isDirectory: true)
        let projectDir = projectsDir.appendingPathComponent(
            RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd.path),
            isDirectory: true
        )
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let workspaceId = UUID()
        let parentPanelId = UUID()
        let forkPanelId = UUID()
        let parentSessionId = "aaaaaaaa-1111-1111-1111-aaaaaaaaaaaa"
        try writeTranscript(sessionId: parentSessionId, transcriptDir: projectDir, cwd: cwd)

        var sessions = [
            parentSessionId: hookRecord(
                sessionId: parentSessionId,
                workspaceId: workspaceId,
                panelId: parentPanelId,
                cwd: cwd.path,
                configDir: configDir.path,
                updatedAt: 10
            ),
        ]
        if let forkedSessionId {
            try writeTranscript(sessionId: forkedSessionId, transcriptDir: projectDir, cwd: cwd)
            sessions[forkedSessionId] = hookRecord(
                sessionId: forkedSessionId,
                workspaceId: workspaceId,
                panelId: forkPanelId,
                cwd: cwd.path,
                configDir: configDir.path,
                updatedAt: forkPaneRecordUpdatedAt
            )
        }
        try writeHookStore(root: root, sessions: sessions)

        return Fixture(
            fileManager: fm,
            root: root,
            cwd: cwd,
            configDir: configDir,
            workspaceId: workspaceId,
            parentPanelId: parentPanelId,
            forkPanelId: forkPanelId,
            parentSessionId: parentSessionId,
            forkedSessionId: forkedSessionId,
            forkProcessID: 4_242
        )
    }

    private func detectedSnapshots(
        fixture: Fixture,
        argv: [String],
        extraEnvironment: [String: String] = [:],
        processName: String = "claude",
        processPath: String? = "/usr/local/bin/claude"
    ) -> [RestorableAgentSessionIndex.PanelKey: RestorableAgentSessionIndex.ProcessDetectedSnapshotEntry] {
        let processArguments = claudeProcessArguments(
            fixture: fixture,
            argv: argv,
            extraEnvironment: extraEnvironment
        )
        return RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: fixture.fileManager,
            processSnapshot: snapshot(fixture: fixture, processName: processName, processPath: processPath),
            capturedAt: 42,
            processArgumentsProvider: { $0 == fixture.forkProcessID ? processArguments : nil }
        )
    }

    private func loadIndex(
        fixture: Fixture,
        detectedSnapshots: [RestorableAgentSessionIndex.PanelKey: RestorableAgentSessionIndex.ProcessDetectedSnapshotEntry],
        processIdentityProvider: @escaping (Int) -> AgentPIDProcessIdentity? = { _ in nil }
    ) -> RestorableAgentSessionIndex {
        RestorableAgentSessionIndex.load(
            homeDirectory: fixture.root.path,
            fileManager: fixture.fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: detectedSnapshots,
            processArgumentsProvider: { _ in nil },
            processIdentityProvider: processIdentityProvider
        )
    }

    private func snapshot(
        fixture: Fixture,
        processName: String = "claude",
        processPath: String? = "/usr/local/bin/claude"
    ) -> CmuxTopProcessSnapshot {
        CmuxTopProcessSnapshot(
            processes: [
                CmuxTopProcessInfo(
                    pid: fixture.forkProcessID,
                    parentPID: 1,
                    name: processName,
                    path: processPath,
                    ttyDevice: nil,
                    cmuxWorkspaceID: fixture.workspaceId,
                    cmuxSurfaceID: fixture.forkPanelId,
                    cmuxAttributionReason: "cmux-test",
                    processGroupID: nil,
                    terminalProcessGroupID: nil,
                    cpuPercent: 0,
                    residentBytes: 0,
                    virtualBytes: 0,
                    threadCount: 1
                ),
            ],
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: true
        )
    }

    private func claudeProcessArguments(
        fixture: Fixture,
        argv: [String],
        extraEnvironment: [String: String] = [:]
    ) -> CmuxTopProcessArguments {
        var environment = [
            "CMUX_AGENT_LAUNCH_KIND": "claude",
            "CMUX_AGENT_LAUNCH_CWD": fixture.cwd.path,
            "CMUX_WORKSPACE_ID": fixture.workspaceId.uuidString,
            "CMUX_SURFACE_ID": fixture.forkPanelId.uuidString,
            "CLAUDE_CONFIG_DIR": fixture.configDir.path,
            "PWD": fixture.cwd.path,
        ]
        for (key, value) in extraEnvironment {
            environment[key] = value
        }
        return CmuxTopProcessArguments(arguments: argv, environment: environment)
    }

    private func hookRecord(
        sessionId: String,
        workspaceId: UUID,
        panelId: UUID,
        cwd: String,
        configDir: String,
        updatedAt: TimeInterval
    ) -> [String: Any] {
        [
            "sessionId": sessionId,
            "workspaceId": workspaceId.uuidString,
            "surfaceId": panelId.uuidString,
            "cwd": cwd,
            "pid": NSNull(),
            "updatedAt": updatedAt,
            "launchCommand": [
                "launcher": "claude",
                "executablePath": "/usr/local/bin/claude",
                "arguments": ["/usr/local/bin/claude"],
                "workingDirectory": cwd,
                "environment": ["CLAUDE_CONFIG_DIR": configDir],
                "capturedAt": updatedAt,
                "source": "test",
            ],
        ]
    }

    private func writeTranscript(sessionId: String, transcriptDir: URL, cwd: URL) throws {
        try """
        {"type":"last-prompt","sessionId":"\(sessionId)"}
        {"type":"user","sessionId":"\(sessionId)","cwd":"\(cwd.path)","message":{"role":"user","content":"hello"}}

        """.write(
            to: transcriptDir.appendingPathComponent("\(sessionId).jsonl", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeHookStore(root: URL, sessions: [String: [String: Any]]) throws {
        try writeHookStore(root: root, storeFilename: "claude-hook-sessions.json", sessions: sessions)
    }

    // The index loads hook stores from `<home>/.cmuxterm/<kind>-hook-sessions.json`
    // (RestorableAgentKind.hookStoreFileURL), so the fixture must write there.
    private func writeHookStore(root: URL, storeFilename: String, sessions: [String: [String: Any]]) throws {
        let stateDir = root.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let store: [String: Any] = ["version": 1, "sessions": sessions]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
        try data.write(to: stateDir.appendingPathComponent(storeFilename), options: .atomic)
    }
}
