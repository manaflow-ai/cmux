import CmuxFoundation
import Foundation
import XCTest
import Darwin

extension CLINotifyProcessIntegrationRegressionTests {
    func testAgentsListIncludesLiveProcessOnlyAgentsAndJoinsDurableSessions() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-live-list-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socketPath = makeSocketPath("agent-live-list")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let runtimeID = "target-runtime"
        let durableWorkspaceID = UUID()
        let durableSurfaceID = UUID()
        let durableSessionID = "durable-codex-session"
        let durablePID = getpid()
        var processInfo = kinfo_proc()
        var processInfoSize = MemoryLayout<kinfo_proc>.stride
        var processMIB: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, durablePID]
        let processInfoResult = sysctl(
            &processMIB,
            u_int(processMIB.count),
            &processInfo,
            &processInfoSize,
            nil,
            0
        )
        XCTAssertEqual(processInfoResult, 0)
        let durableStartSeconds = Int64(processInfo.kp_proc.p_un.__p_starttime.tv_sec)
        let durableStartMicroseconds = Int64(processInfo.kp_proc.p_un.__p_starttime.tv_usec)
        let durableStartedAt = TimeInterval(durableStartSeconds)
            + TimeInterval(durableStartMicroseconds) / 1_000_000
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [durableSessionID: [
                "sessionId": durableSessionID,
                "workspaceId": durableWorkspaceID.uuidString,
                "surfaceId": durableSurfaceID.uuidString,
                "runId": "durable-codex-run",
                "activeRunId": "durable-codex-run",
                "restoreAuthority": true,
                "cmuxRuntime": ["id": runtimeID],
                "runs": [[
                    "runId": "durable-codex-run",
                    "pid": durablePID,
                    "processStartedAt": durableStartedAt,
                    "restoreAuthority": true,
                    "cmuxRuntime": ["id": runtimeID],
                    "startedAt": 100.0,
                    "updatedAt": 200.0,
                ]],
                "startedAt": 100.0,
                "updatedAt": 200.0,
            ]],
            "activeSessionsByWorkspace": [durableWorkspaceID.uuidString: [
                "sessionId": durableSessionID,
                "updatedAt": 200.0,
            ]],
            "activeSessionsBySurface": [durableSurfaceID.uuidString: [
                "sessionId": durableSessionID,
                "updatedAt": 200.0,
            ]],
        ], options: [.sortedKeys]).write(
            to: root.appendingPathComponent("codex-hook-sessions.json"),
            options: .atomic
        )

        func observation(
            workspaceID: UUID,
            surfaceID: UUID,
            familyID: String,
            provider: String,
            lifecycleAuthoritative: Bool,
            state: CmuxAgentObservedState,
            pid: Int32,
            startSeconds: Int64,
            startMicroseconds: Int64,
            cwd: String
        ) -> CmuxAgentTerminalObservation {
            CmuxAgentTerminalObservation(
                runtimeID: runtimeID,
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                surfaceGeneration: 1,
                revision: 1,
                familyID: familyID,
                sessionProviderID: provider,
                lifecycleAuthoritative: lifecycleAuthoritative,
                state: state,
                pid: pid,
                processStartSeconds: startSeconds,
                processStartMicroseconds: startMicroseconds,
                cwd: cwd,
                publishedAt: 300.0 + Double(pid)
            )
        }

        let observations = [
            observation(
                workspaceID: durableWorkspaceID,
                surfaceID: durableSurfaceID,
                familyID: "codex",
                provider: "codex",
                lifecycleAuthoritative: false,
                state: .blocked,
                pid: durablePID,
                startSeconds: durableStartSeconds,
                startMicroseconds: durableStartMicroseconds,
                cwd: "/tmp/durable"
            ),
            observation(
                workspaceID: UUID(),
                surfaceID: UUID(),
                familyID: "codex",
                provider: "codex",
                lifecycleAuthoritative: false,
                state: .working,
                pid: 202,
                startSeconds: 200,
                startMicroseconds: 2,
                cwd: "/tmp/codex-exec"
            ),
            observation(
                workspaceID: UUID(),
                surfaceID: UUID(),
                familyID: "claude-code",
                provider: "claude",
                lifecycleAuthoritative: false,
                state: .idle,
                pid: 303,
                startSeconds: 300,
                startMicroseconds: 3,
                cwd: "/tmp/claude-print"
            ),
            observation(
                workspaceID: UUID(),
                surfaceID: UUID(),
                familyID: "kimi",
                provider: "kimi",
                lifecycleAuthoritative: true,
                state: .blocked,
                pid: 404,
                startSeconds: 400,
                startMicroseconds: 4,
                cwd: "/tmp/kimi"
            ),
            observation(
                workspaceID: UUID(),
                surfaceID: UUID(),
                familyID: "devin",
                provider: "devin",
                lifecycleAuthoritative: false,
                state: .working,
                pid: 505,
                startSeconds: 500,
                startMicroseconds: 5,
                cwd: "/tmp/devin"
            ),
        ]
        let observationsData = try JSONEncoder().encode(observations)

        let state = MockSocketServerState()
        let serverHandled = startMockServer(
            listenerFD: listenerFD,
            state: state,
            connectionCount: 5
        ) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "system.capabilities":
                return self.v2Response(id: id, ok: true, result: [
                    "runtime_id": runtimeID,
                    "socket_path": socketPath,
                    "bundle_identifier": "com.cmuxterm.app.debug.target",
                    "methods": ["agents.observations"],
                ])
            case "agents.observations":
                let observationObjects = (try? JSONSerialization.jsonObject(with: observationsData)) as? [Any] ?? []
                return self.v2Response(id: id, ok: true, result: [
                    "runtime_id": runtimeID,
                    "observations": observationObjects,
                ])
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unknown_method", "message": method]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = socketPath

        let fullList = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "list", "--json", "--state-dir", root.path],
            environment: environment,
            timeout: 5
        )
        XCTAssertEqual(fullList.status, 0, fullList.stderr)
        let fullPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(fullList.stdout.utf8)) as? [String: Any]
        )
        let rows = try XCTUnwrap(fullPayload["sessions"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 5, fullList.stdout)
        let durable = try XCTUnwrap(rows.first { $0["session_id"] as? String == durableSessionID })
        XCTAssertEqual(durable["identity_source"] as? String, "hook_session")
        XCTAssertEqual(durable["effective_state"] as? String, "needs_input")
        XCTAssertEqual(durable["state_source"] as? String, "terminal")
        XCTAssertEqual(rows.filter { $0["pid"] as? Int32 == durablePID || $0["pid"] as? Int == Int(durablePID) }.count, 1)

        let processRows = rows.filter { $0["identity_source"] as? String == "terminal_process" }
        XCTAssertEqual(
            Set(processRows.compactMap { $0["agent"] as? String }),
            ["claude", "codex", "devin", "kimi"]
        )
        XCTAssertTrue(processRows.allSatisfy {
            $0.keys.contains("session_id") && $0["session_id"] is NSNull
        })
        XCTAssertTrue(processRows.allSatisfy { $0["restore_authority"] as? Bool == false })
        XCTAssertTrue(processRows.allSatisfy { $0["is_restorable"] as? Bool == false })
        XCTAssertEqual(
            processRows.first { $0["pid"] as? Int == 202 }?["effective_state"] as? String,
            "working"
        )
        XCTAssertEqual(
            processRows.first { $0["pid"] as? Int == 404 }?["effective_state"] as? String,
            "needs_input"
        )

        let sessionFiltered = runProcess(
            executablePath: cliPath,
            arguments: [
                "agents", "list", "--session", durableSessionID,
                "--json", "--state-dir", root.path,
            ],
            environment: environment,
            timeout: 5
        )
        XCTAssertEqual(sessionFiltered.status, 0, sessionFiltered.stderr)
        let sessionPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(sessionFiltered.stdout.utf8)) as? [String: Any]
        )
        let sessionRows = try XCTUnwrap(sessionPayload["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessionRows.count, 1)
        XCTAssertEqual(sessionRows.first?["session_id"] as? String, durableSessionID)

        let claudeFiltered = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "list", "--agent", "claude", "--json", "--state-dir", root.path],
            environment: environment,
            timeout: 5
        )
        XCTAssertEqual(claudeFiltered.status, 0, claudeFiltered.stderr)
        let claudePayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(claudeFiltered.stdout.utf8)) as? [String: Any]
        )
        let claudeRows = try XCTUnwrap(claudePayload["sessions"] as? [[String: Any]])
        XCTAssertEqual(claudeRows.count, 1)
        XCTAssertEqual(claudeRows.first?["pid"] as? Int, 303)

        let devinFiltered = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "list", "--agent", "devin", "--json", "--state-dir", root.path],
            environment: environment,
            timeout: 5
        )
        XCTAssertEqual(devinFiltered.status, 0, devinFiltered.stderr)
        let devinPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(devinFiltered.stdout.utf8)) as? [String: Any]
        )
        let devinRows = try XCTUnwrap(devinPayload["sessions"] as? [[String: Any]])
        XCTAssertEqual(devinRows.count, 1)
        XCTAssertEqual(devinRows.first?["pid"] as? Int, 505)

        let kimiText = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "list", "--agent", "kimi", "--state-dir", root.path],
            environment: environment,
            timeout: 5
        )
        XCTAssertEqual(kimiText.status, 0, kimiText.stderr)
        XCTAssertTrue(kimiText.stdout.contains("kimi pid 404"), kimiText.stdout)
        XCTAssertFalse(kimiText.stdout.contains("kimi unknown"), kimiText.stdout)

        wait(for: [serverHandled], timeout: 1)

        var offlineEnvironment = environment
        offlineEnvironment.removeValue(forKey: "CMUX_SOCKET_PATH")
        let offline = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "list", "--json", "--state-dir", root.path],
            environment: offlineEnvironment,
            timeout: 5
        )
        XCTAssertEqual(offline.status, 0, offline.stderr)
        let offlinePayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(offline.stdout.utf8)) as? [String: Any]
        )
        let offlineRows = try XCTUnwrap(offlinePayload["sessions"] as? [[String: Any]])
        XCTAssertEqual(offlineRows.count, 1)
        XCTAssertEqual(offlineRows.first?["session_id"] as? String, durableSessionID)
    }

    func testSessionFilterDoesNotApplyActiveSiblingObservationToInactiveSession() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-filtered-shared-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socketPath = makeSocketPath("agent-filtered-shared-process")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let runtimeID = "target-runtime"
        let workspaceID = UUID()
        let surfaceID = UUID()
        let inactiveSessionID = "inactive-session"
        let activeSessionID = "active-session"
        let filteredCWD = "/tmp/shared-process"
        let pid = getpid()
        var processInfo = kinfo_proc()
        var processInfoSize = MemoryLayout<kinfo_proc>.stride
        var processMIB: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        XCTAssertEqual(
            sysctl(
                &processMIB,
                u_int(processMIB.count),
                &processInfo,
                &processInfoSize,
                nil,
                0
            ),
            0
        )
        let startSeconds = Int64(processInfo.kp_proc.p_un.__p_starttime.tv_sec)
        let startMicroseconds = Int64(processInfo.kp_proc.p_un.__p_starttime.tv_usec)
        let processStartedAt = TimeInterval(startSeconds)
            + TimeInterval(startMicroseconds) / 1_000_000

        func record(
            sessionID: String,
            runID: String,
            cwd: String,
            updatedAt: TimeInterval
        ) -> [String: Any] {
            [
                "sessionId": sessionID,
                "workspaceId": workspaceID.uuidString,
                "surfaceId": surfaceID.uuidString,
                "cwd": cwd,
                "runId": runID,
                "activeRunId": runID,
                "restoreAuthority": true,
                "cmuxRuntime": ["id": runtimeID],
                "foregroundState": "idle",
                "attentionState": "none",
                "sessionState": "active",
                "runs": [[
                    "runId": runID,
                    "pid": pid,
                    "processStartedAt": processStartedAt,
                    "restoreAuthority": true,
                    "cmuxRuntime": ["id": runtimeID],
                    "startedAt": 100.0,
                    "updatedAt": updatedAt,
                ]],
                "startedAt": 100.0,
                "updatedAt": updatedAt,
            ]
        }
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [
                inactiveSessionID: record(
                    sessionID: inactiveSessionID,
                    runID: "inactive-run",
                    cwd: filteredCWD,
                    updatedAt: 200
                ),
                activeSessionID: record(
                    sessionID: activeSessionID,
                    runID: "active-run",
                    cwd: "/tmp/active-persisted-cwd",
                    updatedAt: 300
                ),
            ],
            "activeSessionsByWorkspace": [workspaceID.uuidString: [
                "sessionId": activeSessionID,
                "updatedAt": 300.0,
            ]],
            "activeSessionsBySurface": [surfaceID.uuidString: [
                "sessionId": activeSessionID,
                "updatedAt": 300.0,
            ]],
        ], options: [.sortedKeys]).write(
            to: root.appendingPathComponent("codex-hook-sessions.json"),
            options: .atomic
        )

        let observation = CmuxAgentTerminalObservation(
            runtimeID: runtimeID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            surfaceGeneration: 1,
            revision: 1,
            familyID: "codex",
            sessionProviderID: "codex",
            lifecycleAuthoritative: false,
            state: .blocked,
            pid: pid,
            processStartSeconds: startSeconds,
            processStartMicroseconds: startMicroseconds,
            cwd: filteredCWD,
            publishedAt: 400
        )
        let observationObjects = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode([observation])) as? [Any]
        )
        let state = MockSocketServerState()
        let serverHandled = startMockServer(
            listenerFD: listenerFD,
            state: state,
            connectionCount: 2
        ) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "system.capabilities":
                return self.v2Response(id: id, ok: true, result: [
                    "runtime_id": runtimeID,
                    "socket_path": socketPath,
                    "bundle_identifier": "com.cmuxterm.app.debug.target",
                    "methods": ["agents.observations"],
                ])
            case "agents.observations":
                return self.v2Response(id: id, ok: true, result: [
                    "runtime_id": runtimeID,
                    "observations": observationObjects,
                ])
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unknown_method", "message": method]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = socketPath

        for (subcommand, resultKey) in [("list", "sessions"), ("tree", "nodes")] {
            var arguments = [
                "agents", subcommand, "--session", inactiveSessionID,
                "--json", "--state-dir", root.path,
            ]
            if subcommand == "list" {
                arguments.append(contentsOf: ["--cwd", filteredCWD])
            }
            let result = runProcess(
                executablePath: cliPath,
                arguments: arguments,
                environment: environment,
                timeout: 5
            )
            XCTAssertFalse(result.timedOut, result.stderr)
            XCTAssertEqual(result.status, 0, result.stderr)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
            )
            let rows = try XCTUnwrap(payload[resultKey] as? [[String: Any]])
            XCTAssertEqual(rows.count, 1, result.stdout)
            let row = try XCTUnwrap(rows.first)
            XCTAssertEqual(row["session_id"] as? String, inactiveSessionID)
            XCTAssertEqual(row["effective_state"] as? String, "idle")
            XCTAssertEqual(row["state_source"] as? String, "lifecycle")
        }
        wait(for: [serverHandled], timeout: 1)
    }

    func testWorkspaceFilterUsesLiveMovedSurfaceWorkspaceInListAndTree() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-live-moved-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socketPath = makeSocketPath("agent-live-moved-workspace")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let runtimeID = "target-runtime"
        let savedWorkspaceID = UUID()
        let liveWorkspaceID = UUID()
        let surfaceID = UUID()
        let sessionID = "moved-workspace-session"
        let pid = getpid()
        var processInfo = kinfo_proc()
        var processInfoSize = MemoryLayout<kinfo_proc>.stride
        var processMIB: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        XCTAssertEqual(
            sysctl(
                &processMIB,
                u_int(processMIB.count),
                &processInfo,
                &processInfoSize,
                nil,
                0
            ),
            0
        )
        let startSeconds = Int64(processInfo.kp_proc.p_un.__p_starttime.tv_sec)
        let startMicroseconds = Int64(processInfo.kp_proc.p_un.__p_starttime.tv_usec)
        let processStartedAt = TimeInterval(startSeconds)
            + TimeInterval(startMicroseconds) / 1_000_000
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [sessionID: [
                "sessionId": sessionID,
                "workspaceId": savedWorkspaceID.uuidString,
                "surfaceId": surfaceID.uuidString,
                "runId": "moved-workspace-run",
                "activeRunId": "moved-workspace-run",
                "restoreAuthority": true,
                "cmuxRuntime": ["id": runtimeID],
                "foregroundState": "idle",
                "attentionState": "none",
                "sessionState": "active",
                "runs": [[
                    "runId": "moved-workspace-run",
                    "pid": pid,
                    "processStartedAt": processStartedAt,
                    "restoreAuthority": true,
                    "cmuxRuntime": ["id": runtimeID],
                    "startedAt": 100.0,
                    "updatedAt": 200.0,
                ]],
                "startedAt": 100.0,
                "updatedAt": 200.0,
            ]],
            "activeSessionsByWorkspace": [savedWorkspaceID.uuidString: [
                "sessionId": sessionID,
                "updatedAt": 200.0,
            ]],
            "activeSessionsBySurface": [surfaceID.uuidString: [
                "sessionId": sessionID,
                "updatedAt": 200.0,
            ]],
        ], options: [.sortedKeys]).write(
            to: root.appendingPathComponent("codex-hook-sessions.json"),
            options: .atomic
        )

        let observation = CmuxAgentTerminalObservation(
            runtimeID: runtimeID,
            workspaceID: liveWorkspaceID,
            surfaceID: surfaceID,
            surfaceGeneration: 1,
            revision: 1,
            familyID: "codex",
            sessionProviderID: "codex",
            lifecycleAuthoritative: false,
            state: .working,
            pid: pid,
            processStartSeconds: startSeconds,
            processStartMicroseconds: startMicroseconds,
            cwd: "/tmp/moved-workspace",
            publishedAt: 400
        )
        let observationObjects = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode([observation])) as? [Any]
        )
        let state = MockSocketServerState()
        let serverHandled = startMockServer(
            listenerFD: listenerFD,
            state: state,
            connectionCount: 16
        ) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "system.capabilities":
                return self.v2Response(id: id, ok: true, result: [
                    "runtime_id": runtimeID,
                    "socket_path": socketPath,
                    "bundle_identifier": "com.cmuxterm.app.debug.target",
                    "methods": ["agents.observations"],
                ])
            case "agents.observations":
                return self.v2Response(id: id, ok: true, result: [
                    "runtime_id": runtimeID,
                    "observations": observationObjects,
                ])
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unknown_method", "message": method]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = socketPath

        for subcommand in ["list", "tree"] {
            let rowsKey = subcommand == "list" ? "sessions" : "nodes"
            for includesSessionFilter in [false, true] {
                for jsonOutput in [false, true] {
                    for (workspaceID, shouldMatch) in [
                        (savedWorkspaceID, false),
                        (liveWorkspaceID, true),
                    ] {
                        var arguments = [
                            "agents", subcommand,
                            "--agent", "codex",
                            "--workspace", workspaceID.uuidString,
                            "--state-dir", root.path,
                        ]
                        if includesSessionFilter {
                            arguments.append(contentsOf: ["--session", sessionID])
                        }
                        if jsonOutput { arguments.append("--json") }
                        let result = runProcess(
                            executablePath: cliPath,
                            arguments: arguments,
                            environment: environment,
                            timeout: 5
                        )
                        XCTAssertFalse(result.timedOut, result.stderr)
                        XCTAssertEqual(result.status, 0, result.stderr)
                        if jsonOutput {
                            let payload = try XCTUnwrap(
                                JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
                                    as? [String: Any]
                            )
                            let rows = try XCTUnwrap(payload[rowsKey] as? [[String: Any]])
                            XCTAssertEqual(rows.count, shouldMatch ? 1 : 0, result.stdout)
                            if shouldMatch {
                                let row = try XCTUnwrap(rows.first)
                                XCTAssertEqual(row["session_id"] as? String, sessionID)
                                XCTAssertEqual(row["workspace_id"] as? String, liveWorkspaceID.uuidString)
                                XCTAssertEqual(row["identity_source"] as? String, "hook_session")
                                XCTAssertEqual(row["state_source"] as? String, "terminal")
                            }
                        } else if shouldMatch {
                            XCTAssertTrue(result.stdout.contains(sessionID), result.stdout)
                            let workspaceLabel = subcommand == "list" ? "workspace=" : "workspace:"
                            XCTAssertTrue(
                                result.stdout.contains("\(workspaceLabel)\(liveWorkspaceID.uuidString)"),
                                result.stdout
                            )
                        } else {
                            XCTAssertFalse(result.stdout.contains(sessionID), result.stdout)
                        }
                    }
                }
            }
        }
        wait(for: [serverHandled], timeout: 2)
    }

    func testAgentFamilyAliasesRetainDurableSessionsInListAndTree() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-family-aliases-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socketPath = makeSocketPath("agent-family-aliases")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let runtimeID = "target-runtime"
        let pid = getpid()
        var processInfo = kinfo_proc()
        var processInfoSize = MemoryLayout<kinfo_proc>.stride
        var processMIB: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let processInfoResult = sysctl(
            &processMIB,
            u_int(processMIB.count),
            &processInfo,
            &processInfoSize,
            nil,
            0
        )
        XCTAssertEqual(processInfoResult, 0)
        let startSeconds = Int64(processInfo.kp_proc.p_un.__p_starttime.tv_sec)
        let startMicroseconds = Int64(processInfo.kp_proc.p_un.__p_starttime.tv_usec)
        let processStartedAt = TimeInterval(startSeconds)
            + TimeInterval(startMicroseconds) / 1_000_000

        func writeStore(
            provider: String,
            sessionID: String,
            workspaceID: UUID,
            surfaceID: UUID
        ) throws {
            let runID = "\(provider)-run"
            try JSONSerialization.data(withJSONObject: [
                "version": 2,
                "sessions": [sessionID: [
                    "sessionId": sessionID,
                    "workspaceId": workspaceID.uuidString,
                    "surfaceId": surfaceID.uuidString,
                    "runId": runID,
                    "activeRunId": runID,
                    "restoreAuthority": true,
                    "cmuxRuntime": ["id": runtimeID],
                    "runs": [[
                        "runId": runID,
                        "pid": pid,
                        "processStartedAt": processStartedAt,
                        "restoreAuthority": true,
                        "cmuxRuntime": ["id": runtimeID],
                        "startedAt": 100.0,
                        "updatedAt": 200.0,
                    ]],
                    "startedAt": 100.0,
                    "updatedAt": 200.0,
                ]],
                "activeSessionsByWorkspace": [workspaceID.uuidString: [
                    "sessionId": sessionID,
                    "updatedAt": 200.0,
                ]],
                "activeSessionsBySurface": [surfaceID.uuidString: [
                    "sessionId": sessionID,
                    "updatedAt": 200.0,
                ]],
            ], options: [.sortedKeys]).write(
                to: root.appendingPathComponent("\(provider)-hook-sessions.json"),
                options: .atomic
            )
        }

        let cursorWorkspaceID = UUID()
        let cursorSurfaceID = UUID()
        let cursorSessionID = "durable-cursor-session"
        let factoryWorkspaceID = UUID()
        let factorySurfaceID = UUID()
        let factorySessionID = "durable-factory-session"
        try writeStore(
            provider: "cursor",
            sessionID: cursorSessionID,
            workspaceID: cursorWorkspaceID,
            surfaceID: cursorSurfaceID
        )
        try writeStore(
            provider: "factory",
            sessionID: factorySessionID,
            workspaceID: factoryWorkspaceID,
            surfaceID: factorySurfaceID
        )

        func observation(
            familyID: String,
            provider: String,
            workspaceID: UUID,
            surfaceID: UUID
        ) -> CmuxAgentTerminalObservation {
            CmuxAgentTerminalObservation(
                runtimeID: runtimeID,
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                surfaceGeneration: 1,
                revision: 1,
                familyID: familyID,
                sessionProviderID: provider,
                lifecycleAuthoritative: false,
                state: .working,
                pid: pid,
                processStartSeconds: startSeconds,
                processStartMicroseconds: startMicroseconds,
                cwd: "/tmp/\(provider)",
                publishedAt: 300.0
            )
        }
        let observations = [
            observation(
                familyID: "cursor-agent",
                provider: "cursor",
                workspaceID: cursorWorkspaceID,
                surfaceID: cursorSurfaceID
            ),
            observation(
                familyID: "droid",
                provider: "factory",
                workspaceID: factoryWorkspaceID,
                surfaceID: factorySurfaceID
            ),
        ]
        let observationsData = try JSONEncoder().encode(observations)

        let state = MockSocketServerState()
        let serverHandled = startMockServer(
            listenerFD: listenerFD,
            state: state,
            connectionCount: 4
        ) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "system.capabilities":
                return self.v2Response(id: id, ok: true, result: [
                    "runtime_id": runtimeID,
                    "socket_path": socketPath,
                    "bundle_identifier": "com.cmuxterm.app.debug.target",
                    "methods": ["agents.observations"],
                ])
            case "agents.observations":
                let objects = (try? JSONSerialization.jsonObject(with: observationsData)) as? [Any] ?? []
                return self.v2Response(id: id, ok: true, result: [
                    "runtime_id": runtimeID,
                    "observations": objects,
                ])
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unknown_method", "message": method]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = socketPath

        func rows(
            command: String,
            agent: String,
            key: String,
            processEnvironment: [String: String]
        ) throws -> [[String: Any]] {
            let result = runProcess(
                executablePath: cliPath,
                arguments: ["agents", command, "--agent", agent, "--json", "--state-dir", root.path],
                environment: processEnvironment,
                timeout: 5
            )
            XCTAssertEqual(result.status, 0, result.stderr)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
            )
            return try XCTUnwrap(payload[key] as? [[String: Any]])
        }

        let cursorListRows = try rows(
            command: "list",
            agent: "cursor-agent",
            key: "sessions",
            processEnvironment: environment
        )
        XCTAssertEqual(cursorListRows.count, 1)
        XCTAssertEqual(cursorListRows.first?["agent"] as? String, "cursor")
        XCTAssertEqual(cursorListRows.first?["session_id"] as? String, cursorSessionID)
        XCTAssertEqual(cursorListRows.first?["identity_source"] as? String, "hook_session")

        let droidListRows = try rows(
            command: "list",
            agent: "droid",
            key: "sessions",
            processEnvironment: environment
        )
        XCTAssertEqual(droidListRows.count, 1)
        XCTAssertEqual(droidListRows.first?["agent"] as? String, "factory")
        XCTAssertEqual(droidListRows.first?["session_id"] as? String, factorySessionID)
        XCTAssertEqual(droidListRows.first?["identity_source"] as? String, "hook_session")

        let cursorTreeRows = try rows(
            command: "tree",
            agent: "cursor-agent",
            key: "nodes",
            processEnvironment: environment
        )
        XCTAssertEqual(cursorTreeRows.count, 1)
        XCTAssertEqual(cursorTreeRows.first?["provider"] as? String, "cursor")
        XCTAssertEqual(cursorTreeRows.first?["session_id"] as? String, cursorSessionID)
        XCTAssertEqual(cursorTreeRows.first?["identity_source"] as? String, "hook_session")

        let droidTreeRows = try rows(
            command: "tree",
            agent: "droid",
            key: "nodes",
            processEnvironment: environment
        )
        XCTAssertEqual(droidTreeRows.count, 1)
        XCTAssertEqual(droidTreeRows.first?["provider"] as? String, "factory")
        XCTAssertEqual(droidTreeRows.first?["session_id"] as? String, factorySessionID)
        XCTAssertEqual(droidTreeRows.first?["identity_source"] as? String, "hook_session")

        wait(for: [serverHandled], timeout: 1)

        var offlineEnvironment = environment
        offlineEnvironment.removeValue(forKey: "CMUX_SOCKET_PATH")
        let offlineCursorListRows = try rows(
            command: "list",
            agent: "cursor-agent",
            key: "sessions",
            processEnvironment: offlineEnvironment
        )
        XCTAssertEqual(offlineCursorListRows.compactMap { $0["session_id"] as? String }, [cursorSessionID])

        let offlineDroidListRows = try rows(
            command: "list",
            agent: "droid",
            key: "sessions",
            processEnvironment: offlineEnvironment
        )
        XCTAssertEqual(offlineDroidListRows.compactMap { $0["session_id"] as? String }, [factorySessionID])

        let offlineCursorTreeRows = try rows(
            command: "tree",
            agent: "cursor-agent",
            key: "nodes",
            processEnvironment: offlineEnvironment
        )
        XCTAssertEqual(offlineCursorTreeRows.compactMap { $0["session_id"] as? String }, [cursorSessionID])

        let offlineDroidTreeRows = try rows(
            command: "tree",
            agent: "droid",
            key: "nodes",
            processEnvironment: offlineEnvironment
        )
        XCTAssertEqual(offlineDroidTreeRows.compactMap { $0["session_id"] as? String }, [factorySessionID])
    }

    func testAmbientSocketScopesAgentsTreeToTheConnectedRuntime() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-ambient-socket-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socketPath = makeSocketPath("agent-ambient-runtime")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }
        func record(_ sessionID: String, _ runtimeID: String) -> [String: Any] {
            [
                "sessionId": sessionID, "workspaceId": "workspace-\(runtimeID)",
                "surfaceId": "surface-\(runtimeID)", "runId": "run-\(runtimeID)",
                "activeRunId": "run-\(runtimeID)", "restoreAuthority": true,
                "cmuxRuntime": ["id": runtimeID],
                "runs": [[
                    "runId": "run-\(runtimeID)", "restoreAuthority": true,
                    "cmuxRuntime": ["id": runtimeID], "startedAt": 100.0, "updatedAt": 200.0,
                ]],
                "startedAt": 100.0, "updatedAt": 200.0,
            ]
        }
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [
                "current-session": record("current-session", "target-runtime"),
                "other-session": record("other-session", "other-runtime"),
            ],
        ], options: [.sortedKeys]).write(
            to: root.appendingPathComponent("codex-hook-sessions.json"), options: .atomic
        )
        let state = MockSocketServerState()
        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  payload["method"] as? String == "system.capabilities" else {
                return self.malformedRequestResponse(raw: line)
            }
            return self.v2Response(id: id, ok: true, result: [
                "runtime_id": "target-runtime",
                "socket_path": socketPath,
                "bundle_identifier": "com.cmuxterm.app.debug.target",
            ])
        }
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = socketPath
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "tree", "--json", "--state-dir", root.path],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 1)
        XCTAssertEqual(result.status, 0, result.stderr)
        let output = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let nodes = try XCTUnwrap(output["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes.compactMap { $0["session_id"] as? String }, ["current-session"])
    }

    func testAgentsInspectionSocketFallbackIsBoundedAndExplicitSocketStaysAuthoritative() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-socket-timeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socketPath = makeSocketPath("agent-timeout")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [
                "saved-session": [
                    "sessionId": "saved-session",
                    "workspaceId": "workspace-saved",
                    "surfaceId": "surface-saved",
                    "runId": "run-saved",
                    "restoreAuthority": true,
                    "startedAt": 100.0,
                    "updatedAt": 200.0,
                ],
            ],
        ], options: [.sortedKeys]).write(
            to: root.appendingPathComponent("opencode-hook-sessions.json"),
            options: .atomic
        )

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["HOME"] = root.path

        var deadSocketEnvironment = environment
        deadSocketEnvironment["CMUX_SOCKET_PATH"] = makeSocketPath("agent-dead")
        for subcommand in ["list", "tree"] {
            let result = runProcess(
                executablePath: cliPath,
                arguments: [
                    "agents", subcommand, "--agent", "opencode", "--all",
                    "--json", "--state-dir", root.path,
                ],
                environment: deadSocketEnvironment,
                timeout: 3
            )
            XCTAssertFalse(result.timedOut, result.stderr)
            XCTAssertEqual(result.status, 0, result.stderr)
        }

        let state = MockSocketServerState()
        let serverObservedRequest = startMockServerAllowingNoResponse(
            listenerFD: listenerFD,
            state: state,
            connectionCount: 4,
            fulfillWhen: { line in
                guard let data = line.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return false
                }
                return payload["method"] as? String == "system.capabilities"
            },
            handler: { _ in nil }
        )
        var inheritedSocketEnvironment = environment
        inheritedSocketEnvironment["CMUX_SOCKET_PATH"] = socketPath
        for subcommand in ["list", "tree"] {
            let inheritedResult = runProcess(
                executablePath: cliPath,
                arguments: [
                    "agents", subcommand, "--agent", "opencode", "--all",
                    "--json", "--state-dir", root.path,
                ],
                environment: inheritedSocketEnvironment,
                timeout: 3
            )
            XCTAssertFalse(inheritedResult.timedOut, inheritedResult.stderr)
            XCTAssertEqual(inheritedResult.status, 0, inheritedResult.stderr)
            let inheritedPayload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(inheritedResult.stdout.utf8)) as? [String: Any]
            )
            let rowKey = subcommand == "list" ? "sessions" : "nodes"
            let rows = try XCTUnwrap(inheritedPayload[rowKey] as? [[String: Any]])
            XCTAssertEqual(rows.compactMap { $0["session_id"] as? String }, ["saved-session"])

            let explicitResult = runProcess(
                executablePath: cliPath,
                arguments: [
                    "--socket", socketPath,
                    "agents", subcommand, "--agent", "opencode", "--all",
                    "--json", "--state-dir", root.path,
                ],
                environment: environment,
                timeout: 3
            )
            XCTAssertFalse(explicitResult.timedOut, explicitResult.stderr)
            XCTAssertNotEqual(explicitResult.status, 0)
        }
        wait(for: [serverObservedRequest], timeout: 1)
        let capabilityRequests = state.snapshot().filter { line in
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            return payload["method"] as? String == "system.capabilities"
        }
        XCTAssertEqual(capabilityRequests.count, 4)
    }

    func testExplicitSocketScopesAgentsTreeToTheTargetRuntime() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-explicit-socket-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socketPath = makeSocketPath("agent-runtime")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        func record(sessionId: String, runtimeId: String) -> [String: Any] {
            [
                "sessionId": sessionId,
                "workspaceId": "workspace-\(runtimeId)",
                "surfaceId": "surface-\(runtimeId)",
                "runId": "run-\(runtimeId)",
                "activeRunId": "run-\(runtimeId)",
                "restoreAuthority": true,
                "cmuxRuntime": ["id": runtimeId],
                "runs": [[
                    "runId": "run-\(runtimeId)",
                    "restoreAuthority": true,
                    "cmuxRuntime": ["id": runtimeId],
                    "startedAt": 100.0,
                    "updatedAt": 200.0,
                ]],
                "startedAt": 100.0,
                "updatedAt": 200.0,
            ]
        }
        let store: [String: Any] = [
            "version": 2,
            "sessions": [
                "current-session": record(sessionId: "current-session", runtimeId: "target-runtime"),
                "other-session": record(sessionId: "other-session", runtimeId: "other-runtime"),
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)

        let state = MockSocketServerState()
        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  payload["method"] as? String == "system.capabilities" else {
                return self.malformedRequestResponse(raw: line)
            }
            return self.v2Response(
                id: id,
                ok: true,
                result: [
                    "runtime_id": "target-runtime",
                    "socket_path": socketPath,
                    "bundle_identifier": "com.cmuxterm.app.debug.target",
                ]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "--socket", socketPath,
                "agents", "tree", "--json", "--state-dir", root.path,
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 1)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let output = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let nodes = try XCTUnwrap(output["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes.compactMap { $0["session_id"] as? String }, ["current-session"])
    }
}
