import CMUXAgentLaunch
import Foundation
import SQLite3
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Hermes first-class support")
struct HermesFirstClassSupportTests {
    private struct StateRow {
        let id: String
        let cwd: String?
        let source: String
        let startedAt: Double
        let endedAt: Double?

        init(
            _ id: String,
            cwd: String?,
            source: String = "cli",
            startedAt: Double = 10,
            endedAt: Double? = nil
        ) {
            self.id = id
            self.cwd = cwd
            self.source = source
            self.startedAt = startedAt
            self.endedAt = endedAt
        }
    }

    @Test("A bare Hermes process binds the unique active state.db session")
    func bareProcessBindsUniqueActiveSession() throws {
        let fixture = try makeFixture { repo in
            [
                StateRow("ended-newer", cwd: repo.path, startedAt: 30, endedAt: 40),
                StateRow("live-session", cwd: repo.path, source: "tui", startedAt: 20),
            ]
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let detected = try detectedHermesSnapshots(
            fixture: fixture,
            processes: [hermesProcess(pid: 9_520, workspaceID: fixture.workspaceID, panelID: fixture.panelID)],
            argumentsByPID: [
                9_520: CmuxTopProcessArguments(
                    arguments: [fixture.hermesExecutable, "--tui"],
                    environment: hermesEnvironment(fixture)
                ),
            ]
        )

        let snapshot = try #require(detected.values.first?.snapshot)
        #expect(snapshot.kind == .hermesAgent)
        #expect(snapshot.sessionId == "live-session")
        #expect(snapshot.workingDirectory == fixture.repo.path)
        let command = try #require(snapshot.resumeCommand)
        #expect(command.contains("'--resume' 'live-session'"))
        #expect(command.contains("'--tui'"))
        #expect(command.contains("'HERMES_HOME=\(fixture.hermesHome.path)'"))
    }

    @Test(
        "Explicit Hermes resume flags win over ambiguous cwd lookup",
        arguments: [
            ["--resume", "explicit-session"],
            ["--resume=explicit-session"],
            ["-r", "explicit-session"],
            ["-r=explicit-session"],
        ]
    )
    func explicitResumeFlagsWin(arguments: [String]) throws {
        let fixture = try makeFixture { repo in
            [
                StateRow("explicit-session", cwd: repo.path, startedAt: 10),
                StateRow("other-active-session", cwd: repo.path, startedAt: 20),
            ]
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let processArguments = [fixture.hermesExecutable] + arguments + ["--tui"]
        let detected = try detectedHermesSnapshots(
            fixture: fixture,
            processes: [hermesProcess(pid: 9_521, workspaceID: fixture.workspaceID, panelID: fixture.panelID)],
            argumentsByPID: [
                9_521: CmuxTopProcessArguments(
                    arguments: processArguments,
                    environment: hermesEnvironment(fixture)
                ),
            ]
        )

        #expect(detected.values.first?.snapshot.kind == .hermesAgent)
        #expect(detected.values.first?.snapshot.sessionId == "explicit-session")
    }

    @Test("A bare Hermes process fails closed when active state.db rows are ambiguous")
    func bareProcessRejectsAmbiguousActiveSessions() throws {
        let fixture = try makeFixture { repo in
            [
                StateRow("active-a", cwd: repo.path, startedAt: 10),
                StateRow("active-b", cwd: repo.path, startedAt: 20),
            ]
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let detected = try detectedHermesSnapshots(
            fixture: fixture,
            processes: [hermesProcess(pid: 9_522, workspaceID: fixture.workspaceID, panelID: fixture.panelID)],
            argumentsByPID: [
                9_522: CmuxTopProcessArguments(
                    arguments: [fixture.hermesExecutable],
                    environment: hermesEnvironment(fixture)
                ),
            ]
        )

        #expect(detected.isEmpty)
    }

    @Test("Two bare Hermes panes in one cwd do not claim the same state.db session")
    func coLocatedBareProcessesDoNotShareOneSession() throws {
        let secondPanelID = UUID()
        let fixture = try makeFixture { [StateRow("only-active", cwd: $0.path)] }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let processes = [
            hermesProcess(pid: 9_523, workspaceID: fixture.workspaceID, panelID: fixture.panelID),
            hermesProcess(pid: 9_524, workspaceID: fixture.workspaceID, panelID: secondPanelID),
        ]
        let launch = CmuxTopProcessArguments(
            arguments: [fixture.hermesExecutable],
            environment: hermesEnvironment(fixture)
        )

        let detected = try detectedHermesSnapshots(
            fixture: fixture,
            processes: processes,
            argumentsByPID: [9_523: launch, 9_524: launch]
        )

        #expect(detected.isEmpty)
    }

    @Test("Session index entries preserve Hermes cwd for filtering and resume")
    func sessionIndexPreservesCwd() throws {
        let fixture = try makeFixture { [StateRow("indexed-session", cwd: $0.path)] }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let outcome = SessionIndexStore.loadHermesAgentEntriesForTesting(
            stateDBPath: fixture.stateDB.path,
            cwdFilter: fixture.repo.path
        )
        let entry = try #require(outcome.entries.first)

        #expect(outcome.errors.isEmpty)
        #expect(entry.sessionId == "indexed-session")
        #expect(entry.cwd == fixture.repo.path)
    }

    @Test("User-configured detectors take precedence over the built-in Hermes detector")
    func userDetectorTakesPrecedence() throws {
        let fixture = try makeFixture { [StateRow("built-in-session", cwd: $0.path)] }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let builtInRegistry = CmuxVaultAgentRegistry.load(
            homeDirectory: fixture.root.path,
            environment: ["HOME": fixture.root.path],
            fileManager: .default
        )
        let builtInHermes = try #require(builtInRegistry.registration(id: "hermes-agent"))
        let custom = CmuxVaultAgentRegistration(
            id: "team-hermes",
            name: "Team Hermes",
            detect: CmuxVaultAgentDetectRule(processNames: ["hermes"]),
            sessionIdSource: .argvOption("--team-session"),
            resumeCommand: "{{executable}} --team-session {{sessionId}}"
        )
        let registry = CmuxVaultAgentRegistry(registrations: [builtInHermes, custom])
        let process = hermesProcess(pid: 9_525, workspaceID: fixture.workspaceID, panelID: fixture.panelID)

        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: registry,
            fileManager: .default,
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [process],
                sampledAt: Date(timeIntervalSince1970: 0),
                includesProcessDetails: true
            ),
            capturedAt: 42,
            processArgumentsProvider: { pid in
                guard pid == process.pid else { return nil }
                return CmuxTopProcessArguments(
                    arguments: [fixture.hermesExecutable, "--team-session", "team-session-1"],
                    environment: self.hermesEnvironment(fixture)
                )
            }
        )

        #expect(detected.values.first?.snapshot.kind == .custom("team-hermes"))
        #expect(detected.values.first?.snapshot.sessionId == "team-session-1")
    }

    @Test("Hermes hook install migrates consent to ambient per-launch dispatch")
    func hookInstallUsesAmbientDispatchAndConsent() throws {
        let root = try temporaryDirectory(prefix: "cmux-hermes-hooks")
        defer { try? FileManager.default.removeItem(at: root) }
        let hermesHome = root.appendingPathComponent("hermes-home", isDirectory: true)
        try FileManager.default.createDirectory(at: hermesHome, withIntermediateDirectories: true)
        let pinnedCLI = root.appendingPathComponent("cmux pinned cli", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: pinnedCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pinnedCLI.path)
        let socketPath = root.appendingPathComponent("cmux-debug-hermes-first-class.sock").path
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: HermesFirstClassBundleToken.self)
        let allowlistURL = hermesHome.appendingPathComponent("shell-hooks-allowlist.json")
        let legacyCommand = #"sh -c 'cmux_cli=cmux; "$cmux_cli" hooks hermes-agent prompt-submit'"#
        let userCommand = "echo user-owned Hermes hook"
        let existingAllowlist = try JSONSerialization.data(
            withJSONObject: [
                "approvals": [
                    [
                        "event": "pre_llm_call",
                        "command": legacyCommand,
                        "approved_at": "2026-01-01T00:00:00Z",
                    ],
                    [
                        "event": "pre_tool_call",
                        "command": userCommand,
                        "scope": "user",
                    ],
                ],
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        try existingAllowlist.write(to: allowlistURL, options: .atomic)

        let result = try runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "hermes-agent", "install", "--yes"],
            environment: [
                "HOME": root.path,
                "HERMES_HOME": hermesHome.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_BUNDLED_CLI_PATH": pinnedCLI.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )

        #expect(result.status == 0, Comment(rawValue: result.output))
        let config = try String(
            contentsOf: hermesHome.appendingPathComponent("config.yaml"),
            encoding: .utf8
        )
        let allowlistData = try Data(
            contentsOf: allowlistURL
        )
        let allowlist = try #require(
            JSONSerialization.jsonObject(with: allowlistData) as? [String: Any]
        )
        let approvals = try #require(allowlist["approvals"] as? [[String: Any]])
        let commands = approvals.compactMap { $0["command"] as? String }
        let cmuxCommands = commands.filter {
            $0.contains("cmux-hermes-agent-hook-v2") || $0.contains("hooks hermes-agent ")
        }

        #expect(commands.count == approvals.count)
        #expect(commands.contains(userCommand))
        #expect(!commands.contains(legacyCommand))
        #expect(!cmuxCommands.isEmpty)
        #expect(cmuxCommands.allSatisfy { !$0.contains("cmux-hermes-agent-hook-v2") })
        #expect(cmuxCommands.allSatisfy { !$0.contains(pinnedCLI.path) })
        #expect(cmuxCommands.allSatisfy { !$0.contains(socketPath) })
        #expect(cmuxCommands.allSatisfy { $0.contains("CMUX_BUNDLED_CLI_PATH") })
        #expect(cmuxCommands.allSatisfy { $0.contains("CMUX_SOCKET_PATH") })
        #expect(!config.contains("cmux-hermes-agent-hook-v2"))
        #expect(!config.contains(pinnedCLI.path))
        #expect(!config.contains(socketPath))
        #expect(config.contains("CMUX_BUNDLED_CLI_PATH"))
        #expect(config.contains("CMUX_SOCKET_PATH"))
    }

    @Test("Hermes hook install creates a fresh home without a pinned cmux target")
    func hookInstallCreatesMissingHomeWithAmbientDispatch() throws {
        let root = try temporaryDirectory(prefix: "cmux-hermes-hooks-no-target")
        defer { try? FileManager.default.removeItem(at: root) }
        let hermesHome = root.appendingPathComponent("hermes-home", isDirectory: true)
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: HermesFirstClassBundleToken.self)
        let configURL = hermesHome.appendingPathComponent("config.yaml")
        let allowlistURL = hermesHome.appendingPathComponent("shell-hooks-allowlist.json")

        let result = try runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "hermes-agent", "install", "--yes"],
            environment: [
                "HOME": root.path,
                "HERMES_HOME": hermesHome.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )

        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(FileManager.default.fileExists(atPath: configURL.path))
        #expect(FileManager.default.fileExists(atPath: allowlistURL.path))
        let config = try String(contentsOf: configURL, encoding: .utf8)
        #expect(config.contains("CMUX_BUNDLED_CLI_PATH"))
        #expect(config.contains("CMUX_SOCKET_PATH"))
    }

    private struct Fixture {
        let root: URL
        let hermesHome: URL
        let stateDB: URL
        let repo: URL
        let workspaceID: UUID
        let panelID: UUID
        let hermesExecutable: String
    }

    private func makeFixture(rows: (URL) -> [StateRow]) throws -> Fixture {
        let root = try temporaryDirectory(prefix: "cmux-hermes-first-class")
        let hermesHome = root.appendingPathComponent("hermes-home", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: hermesHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let stateDB = hermesHome.appendingPathComponent("state.db", isDirectory: false)
        try writeStateDB(at: stateDB, rows: rows(repo))
        return Fixture(
            root: root,
            hermesHome: hermesHome,
            stateDB: stateDB,
            repo: repo,
            workspaceID: UUID(),
            panelID: UUID(),
            hermesExecutable: "/usr/local/bin/hermes"
        )
    }

    private func detectedHermesSnapshots(
        fixture: Fixture,
        processes: [CmuxTopProcessInfo],
        argumentsByPID: [Int: CmuxTopProcessArguments]
    ) throws -> [RestorableAgentSessionIndex.PanelKey: RestorableAgentSessionIndex.ProcessDetectedSnapshotEntry] {
        let registry = CmuxVaultAgentRegistry.load(
            homeDirectory: fixture.root.path,
            environment: ["HOME": fixture.root.path],
            fileManager: .default
        )
        _ = try #require(registry.registration(id: "hermes-agent"))
        return RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: registry,
            fileManager: .default,
            processSnapshot: CmuxTopProcessSnapshot(
                processes: processes,
                sampledAt: Date(timeIntervalSince1970: 0),
                includesProcessDetails: true
            ),
            capturedAt: 42,
            processArgumentsProvider: { argumentsByPID[$0] }
        )
    }

    private func hermesProcess(pid: Int, workspaceID: UUID, panelID: UUID) -> CmuxTopProcessInfo {
        CmuxTopProcessInfo(
            pid: pid,
            parentPID: 1,
            name: "hermes",
            path: "/usr/local/bin/hermes",
            ttyDevice: nil,
            cmuxWorkspaceID: workspaceID,
            cmuxSurfaceID: panelID,
            cmuxAttributionReason: "cmux-test",
            processGroupID: nil,
            terminalProcessGroupID: nil,
            cpuPercent: 0,
            residentBytes: 0,
            virtualBytes: 0,
            threadCount: 1
        )
    }

    private func hermesEnvironment(_ fixture: Fixture) -> [String: String] {
        [
            "HERMES_HOME": fixture.hermesHome.path,
            "CMUX_AGENT_LAUNCH_CWD": fixture.repo.path,
            "PWD": fixture.repo.path,
        ]
    }

    private func temporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeStateDB(at url: URL, rows: [StateRow]) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw HermesFirstClassTestError.sqlite("open failed")
        }
        defer { sqlite3_close(database) }
        try execute(database, sql: """
        CREATE TABLE sessions (
          id TEXT PRIMARY KEY,
          source TEXT NOT NULL,
          model TEXT,
          started_at REAL NOT NULL,
          ended_at REAL,
          title TEXT,
          cwd TEXT
        );
        CREATE TABLE messages (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id TEXT NOT NULL,
          role TEXT NOT NULL,
          content TEXT,
          tool_name TEXT,
          tool_calls TEXT,
          timestamp REAL NOT NULL
        );
        """)
        for row in rows {
            try execute(
                database,
                sql: """
                INSERT INTO sessions (id, source, model, started_at, ended_at, title, cwd)
                VALUES (
                  \(sqlLiteral(row.id)),
                  \(sqlLiteral(row.source)),
                  'test-model',
                  \(row.startedAt),
                  \(row.endedAt.map { String($0) } ?? "NULL"),
                  \(sqlLiteral(row.id)),
                  \(row.cwd.map(sqlLiteral) ?? "NULL")
                );
                """
            )
        }
    }

    private func execute(_ database: OpaquePointer, sql: String) throws {
        var error: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(database, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "sqlite error \(result)"
            sqlite3_free(error)
            throw HermesFirstClassTestError.sqlite(message)
        }
    }

    private func sqlLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            status: process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? ""
        )
    }
}

private final class HermesFirstClassBundleToken {}

private enum HermesFirstClassTestError: Error {
    case sqlite(String)
}
