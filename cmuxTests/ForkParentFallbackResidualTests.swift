import Darwin
import Foundation
import SQLite3
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct ForkParentFallbackResidualTests {
    @Test func customClaudeBinaryForkFallbackPassesCachedForkValidation() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }

        let sessionId = "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
        let processArguments = fixture.processArguments(
            argv: ["/opt/cmux-tools/claude-custom", "--resume", sessionId, "--fork-session"],
            launchKind: "claude",
            extraEnvironment: ["CMUX_AGENT_LAUNCH_EXECUTABLE": "/opt/cmux-tools/claude-custom"]
        )
        let identity = AgentPIDProcessIdentity(
            pid: pid_t(fixture.processID),
            startSeconds: 100,
            startMicroseconds: 0
        )
        let loader = SharedLiveAgentIndexLoader(
            homeDirectory: fixture.root.path,
            fileManager: fixture.fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            processSnapshotProvider: {
                fixture.processSnapshot(processName: "claude-custom", processPath: "/opt/cmux-tools/claude-custom")
            },
            capturedAtProvider: { 42 },
            processArgumentsProvider: { $0 == fixture.processID ? processArguments : nil },
            processIdentityProvider: { $0 == fixture.processID ? identity : nil }
        )

        let result = loader.loadResultSynchronously()
        #expect(result.forkValidatedPanels.contains(fixture.panelKey))
    }

    @Test func customClaudeValidatorRejectsDifferentLiveExecutableThanLaunchExecutable() {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "claude",
                arguments: ["claude"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: "process"
            ),
            registration: nil
        )
        let process = CmuxTopProcessArguments(
            arguments: ["/opt/cmux-tools/not-claude", "--resume", snapshot.sessionId, "--fork-session"],
            environment: [
                "CMUX_AGENT_LAUNCH_KIND": "claude",
                "CMUX_AGENT_LAUNCH_EXECUTABLE": "/opt/cmux-tools/claude-custom",
            ]
        )

        #expect(CachedAgentProcessIdentityValidator().currentProcess(process, matches: snapshot) == false)
    }

    @Test func validatorAcceptsTeamsLaunchKindOnlyForMatchingBaseKind() {
        let claudeTeamsSnapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claudeTeams",
                executablePath: "/usr/local/bin/cmux",
                arguments: ["/usr/local/bin/cmux", "claude-teams"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: "process"
            ),
            registration: nil
        )
        let claudeTeamsProcess = CmuxTopProcessArguments(
            arguments: ["/usr/local/bin/claude", "--resume", claudeTeamsSnapshot.sessionId, "--fork-session"],
            environment: [
                "CMUX_AGENT_LAUNCH_KIND": "claudeTeams",
                "CMUX_AGENT_LAUNCH_EXECUTABLE": "/usr/local/bin/cmux",
            ]
        )
        #expect(CachedAgentProcessIdentityValidator().currentProcess(claudeTeamsProcess, matches: claudeTeamsSnapshot))

        let codexTeamsSnapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019f436f-1111-4222-8333-aaaaaaaaaaaa",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codexTeams",
                executablePath: "/usr/local/bin/cmux",
                arguments: ["/usr/local/bin/cmux", "codex-teams"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: "process"
            ),
            registration: nil
        )
        #expect(CachedAgentProcessIdentityValidator().currentProcess(
            CmuxTopProcessArguments(
                arguments: ["/usr/local/bin/cmux", "codex-teams", "fork", codexTeamsSnapshot.sessionId],
                environment: ["CMUX_AGENT_LAUNCH_KIND": "codexTeams"]
            ),
            matches: codexTeamsSnapshot
        ))
        #expect(CachedAgentProcessIdentityValidator().currentProcess(
            CmuxTopProcessArguments(
                arguments: ["/usr/local/bin/cmux", "codex-teams", "fork", claudeTeamsSnapshot.sessionId],
                environment: ["CMUX_AGENT_LAUNCH_KIND": "codexTeams"]
            ),
            matches: claudeTeamsSnapshot
        ) == false)
    }

    @Test func codexRecordWithoutHookCwdUsesCodexThreadCwdForResumeAndFork() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }

        let sessionId = "019f436f-1111-4222-8333-aaaaaaaaaaaa"
        let codexHome = fixture.root.appendingPathComponent("codex-home", isDirectory: true)
        try fixture.fileManager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try writeCodexStateDB(codexHome: codexHome, sessionId: sessionId, cwd: fixture.cwd.path)
        try writeStore(root: fixture.root, filename: "codex-hook-sessions.json", sessions: [
            sessionId: [
                "sessionId": sessionId,
                "workspaceId": fixture.workspaceId.uuidString,
                "surfaceId": fixture.panelId.uuidString,
                "pid": NSNull(),
                "updatedAt": 10,
                "isRestorable": true,
                "launchCommand": [
                    "launcher": "codex",
                    "executablePath": "/usr/local/bin/codex",
                    "arguments": ["/usr/local/bin/codex"],
                    "environment": ["CODEX_HOME": codexHome.path],
                    "capturedAt": 10,
                    "source": "environment",
                ],
            ],
        ])

        let snapshot = try #require(
            RestorableAgentSessionIndex.load(homeDirectory: fixture.root.path, fileManager: fixture.fileManager)
                .snapshot(workspaceId: fixture.workspaceId, panelId: fixture.panelId)
        )
        #expect(snapshot.workingDirectory == fixture.cwd.path)
        #expect(snapshot.resumeStartupInput()?.contains("cd -- '\(fixture.cwd.path)'") == true)
        #expect(snapshot.forkStartupInput()?.contains("cd -- '\(fixture.cwd.path)'") == true)

        let cwdless = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionId,
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/usr/local/bin/codex",
                arguments: ["/usr/local/bin/codex"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: "process"
            ),
            registration: nil
        )
        #expect(cwdless.forkStartupInput() != nil)
        #expect(cwdless.forkStartupInput()?.contains("cd --") == false)
    }

    @Test func codexTeamsWrapperForkFallbackRoundTripsAndParentHookSurvives() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }

        let parentSessionId = "019f436f-1111-4222-8333-aaaaaaaaaaaa"
        try writeStore(root: fixture.root, filename: "codex-hook-sessions.json", sessions: [
            parentSessionId: fixture.hookRecord(kind: "codex", sessionId: parentSessionId, panelId: fixture.parentPanelId),
        ])
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: fixture.fileManager,
            processSnapshot: fixture.processSnapshot(processName: "cmux", processPath: "/usr/local/bin/cmux"),
            capturedAt: 42,
            processArgumentsProvider: { pid in
                pid == fixture.processID
                    ? fixture.processArguments(
                        argv: ["/usr/local/bin/cmux", "codex-teams", "fork", parentSessionId, "--model", "gpt-5"],
                        launchKind: nil
                    )
                    : nil
            }
        )
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: fixture.root.path,
            fileManager: fixture.fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: detected,
            processArgumentsProvider: { _ in nil },
            processIdentityProvider: { _ in nil }
        )

        let forkSnapshot = try #require(index.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.panelId))
        #expect(forkSnapshot.kind == .codex)
        #expect(forkSnapshot.sessionId == parentSessionId)
        #expect(forkSnapshot.forkCommand?.contains("'codex-teams' 'fork' '\(parentSessionId)' '--model' 'gpt-5'") == true)
        #expect(index.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.parentPanelId)?.sessionId == parentSessionId)
    }

    @Test func codexTeamsWrapperSameKindHookRecordWinsAfterForkMintsSession() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }

        let parentSessionId = "019f436f-1111-4222-8333-aaaaaaaaaaaa"
        let childSessionId = "019f436f-2222-4222-8333-bbbbbbbbbbbb"
        try writeStore(root: fixture.root, filename: "codex-hook-sessions.json", sessions: [
            parentSessionId: fixture.hookRecord(kind: "codex", sessionId: parentSessionId, panelId: fixture.parentPanelId, updatedAt: 10),
            childSessionId: fixture.hookRecord(kind: "codex", sessionId: childSessionId, panelId: fixture.panelId, updatedAt: 20),
        ])
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: fixture.fileManager,
            processSnapshot: fixture.processSnapshot(processName: "cmux", processPath: "/usr/local/bin/cmux"),
            capturedAt: 42,
            processArgumentsProvider: { pid in
                pid == fixture.processID
                    ? fixture.processArguments(
                        argv: ["/usr/local/bin/cmux", "codex-teams", "fork", parentSessionId],
                        launchKind: nil
                    )
                    : nil
            }
        )
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: fixture.root.path,
            fileManager: fixture.fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: detected,
            processArgumentsProvider: { _ in nil },
            processIdentityProvider: { _ in nil }
        )

        #expect(index.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.panelId)?.sessionId == childSessionId)
    }

    @Test func claudeTeamsPersistentClaudeProcessForkFallbackRoundTripsAndValidates() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }

        let parentSessionId = "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
        let liveArguments = [
            "/usr/local/bin/claude",
            "--teammate-mode",
            "auto",
            "--resume",
            parentSessionId,
            "--fork-session",
            "--model",
            "sonnet",
        ]
        let launchArguments = [
            "/usr/local/bin/cmux",
            "claude-teams",
            "--resume",
            parentSessionId,
            "--fork-session",
            "--model",
            "sonnet",
        ]
        let processArguments = fixture.processArguments(
            argv: liveArguments,
            launchKind: "claudeTeams",
            extraEnvironment: [
                "CMUX_AGENT_LAUNCH_EXECUTABLE": "/usr/local/bin/cmux",
                "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated(launchArguments),
            ]
        )
        let identity = AgentPIDProcessIdentity(
            pid: pid_t(fixture.processID),
            startSeconds: 100,
            startMicroseconds: 0
        )
        let loader = SharedLiveAgentIndexLoader(
            homeDirectory: fixture.root.path,
            fileManager: fixture.fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            processSnapshotProvider: {
                fixture.processSnapshot(processName: "claude", processPath: "/usr/local/bin/claude")
            },
            capturedAtProvider: { 42 },
            processArgumentsProvider: { pid in
                pid == fixture.processID ? processArguments : nil
            },
            processIdentityProvider: { pid in
                pid == fixture.processID ? identity : nil
            }
        )
        let result = loader.loadResultSynchronously()
        let snapshot = try #require(result.index.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.panelId))
        #expect(snapshot.kind == .claude)
        #expect(result.forkValidatedPanels.contains(fixture.panelKey))
        #expect(snapshot.forkCommand?.contains("'claude-teams' '--resume' '\(parentSessionId)' '--fork-session' '--model' 'sonnet'") == true)
    }

    private struct Fixture {
        let fileManager: FileManager
        let root: URL
        let cwd: URL
        let workspaceId: UUID
        let panelId: UUID
        let parentPanelId: UUID
        let processID = 7_655

        var panelKey: RestorableAgentSessionIndex.PanelKey {
            RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        }

        static func make() throws -> Fixture {
            let fileManager = FileManager.default
            let root = fileManager.temporaryDirectory.appendingPathComponent("cmux-fork-residual-\(UUID().uuidString)", isDirectory: true)
            let cwd = root.appendingPathComponent("repo", isDirectory: true)
            try fileManager.createDirectory(at: cwd, withIntermediateDirectories: true)
            return Fixture(
                fileManager: fileManager,
                root: root,
                cwd: cwd,
                workspaceId: UUID(),
                panelId: UUID(),
                parentPanelId: UUID()
            )
        }

        func cleanup() {
            try? fileManager.removeItem(at: root)
        }

        func processSnapshot(processName: String, processPath: String?) -> CmuxTopProcessSnapshot {
            CmuxTopProcessSnapshot(
                processes: [
                    CmuxTopProcessInfo(
                        pid: processID,
                        parentPID: 1,
                        name: processName,
                        path: processPath,
                        ttyDevice: nil,
                        cmuxWorkspaceID: workspaceId,
                        cmuxSurfaceID: panelId,
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

        func processArguments(
            argv: [String],
            launchKind: String?,
            extraEnvironment: [String: String] = [:]
        ) -> CmuxTopProcessArguments {
            var environment = [
                "CMUX_AGENT_LAUNCH_CWD": cwd.path,
                "CMUX_BUNDLED_CLI_PATH": "/usr/local/bin/cmux",
                "CMUX_WORKSPACE_ID": workspaceId.uuidString,
                "CMUX_SURFACE_ID": panelId.uuidString,
                "PWD": cwd.path,
            ]
            if let launchKind {
                environment["CMUX_AGENT_LAUNCH_KIND"] = launchKind
            }
            environment.merge(extraEnvironment) { _, new in new }
            return CmuxTopProcessArguments(arguments: argv, environment: environment)
        }

        func hookRecord(
            kind: String,
            sessionId: String,
            panelId: UUID,
            updatedAt: TimeInterval = 10
        ) -> [String: Any] {
            [
                "sessionId": sessionId,
                "workspaceId": workspaceId.uuidString,
                "surfaceId": panelId.uuidString,
                "cwd": cwd.path,
                "pid": NSNull(),
                "updatedAt": updatedAt,
                "isRestorable": true,
                "launchCommand": [
                    "launcher": kind,
                    "executablePath": "/usr/local/bin/\(kind)",
                    "arguments": ["/usr/local/bin/\(kind)"],
                    "workingDirectory": cwd.path,
                    "capturedAt": updatedAt,
                    "source": "test",
                ],
            ]
        }
    }

    private func writeStore(root: URL, filename: String, sessions: [String: [String: Any]]) throws {
        let stateDir = root.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "sessions": sessions], options: [.prettyPrinted])
        try data.write(to: stateDir.appendingPathComponent(filename), options: .atomic)
    }

    private func writeCodexStateDB(codexHome: URL, sessionId: String, cwd: String) throws {
        let dbPath = codexHome.appendingPathComponent("state_5.sqlite", isDirectory: false).path
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db else {
            throw testFailure()
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, archived INTEGER)", nil, nil, nil) == SQLITE_OK else {
            throw testFailure()
        }
        let sql = "INSERT INTO threads (id, cwd, archived) VALUES (?, ?, 0)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw testFailure()
        }
        defer { sqlite3_finalize(stmt) }
        let SQLITE_TRANSIENT_FN = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT_FN)
        sqlite3_bind_text(stmt, 2, cwd, -1, SQLITE_TRANSIENT_FN)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw testFailure()
        }
    }

    private func base64NULSeparated(_ values: [String]) -> String {
        var data = Data()
        for value in values {
            data.append(contentsOf: value.utf8)
            data.append(0)
        }
        return data.base64EncodedString()
    }

    private func testFailure() -> NSError {
        NSError(domain: "ForkParentFallbackResidualTests", code: 1)
    }
}
