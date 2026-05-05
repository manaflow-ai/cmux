import XCTest
import Darwin

extension CLINotifyProcessIntegrationRegressionTests {
    func testRovoDevPromptSubmitInfersSessionIdFromWorkspaceMetadataAndPersistsLaunchCommand() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("rovo-infer")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-rovo-hook-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("repo", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let workspaceId = "55555555-5555-5555-5555-555555555555"
        let surfaceId = "66666666-6666-6666-6666-666666666666"
        let sessionId = "rovo-session"

        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try writeRovoDevSessionMetadata(
            sessionsRoot: sessionsRoot,
            sessionId: sessionId,
            workspacePath: workspace.path,
            modified: Date(timeIntervalSince1970: 200)
        )
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else {
                return "OK"
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            if method == "surface.list" {
                return self.surfaceListResponse(id: id, surfaceId: surfaceId)
            }
            return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_ROVODEV_SESSIONS_DIR"] = sessionsRoot.path
        environment["CMUX_AGENT_LAUNCH_KIND"] = "rovodev"
        environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] = "/usr/local/bin/acli"
        environment["CMUX_AGENT_LAUNCH_ARGV_B64"] = base64NULSeparated([
            "/usr/local/bin/acli",
            "rovodev",
            "run",
            "--restore",
            sessionId,
            "--yolo",
            "prompt that should not persist",
        ])
        environment["CMUX_AGENT_LAUNCH_CWD"] = workspace.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "rovodev", "prompt-submit"],
            environment: environment,
            standardInput: #"{"cwd":"\#(workspace.path)","hook_event_name":"on_tool_permission"}"#,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")

        let storeURL = root.appendingPathComponent("rovodev-hook-sessions.json", isDirectory: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
        let sessions = try XCTUnwrap(json["sessions"] as? [String: Any])
        let session = try XCTUnwrap(sessions[sessionId] as? [String: Any])
        XCTAssertEqual(session["workspaceId"] as? String, workspaceId)
        XCTAssertEqual(session["surfaceId"] as? String, surfaceId)
        XCTAssertEqual(session["cwd"] as? String, workspace.path)

        let launchCommand = try XCTUnwrap(session["launchCommand"] as? [String: Any])
        XCTAssertEqual(launchCommand["launcher"] as? String, "rovodev")
        XCTAssertEqual(launchCommand["executablePath"] as? String, "/usr/local/bin/acli")
        XCTAssertEqual(
            launchCommand["arguments"] as? [String],
            ["/usr/local/bin/acli", "rovodev", "run", "--yolo"]
        )
        XCTAssertTrue(
            state.commands.contains { $0.contains("set_status rovodev Running") && $0.contains("--tab=\(workspaceId)") },
            "Expected Rovo Dev prompt status to target current workspace, saw \(state.commands)"
        )
    }

    func testRovoDevPromptSubmitDoesNotInferAmbiguousWorkspaceMetadata() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("rovo-ambiguous")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-rovo-ambiguous-hook-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("repo", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let workspaceId = "55555555-5555-5555-5555-555555555555"
        let surfaceId = "66666666-6666-6666-6666-666666666666"

        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try writeRovoDevSessionMetadata(
            sessionsRoot: sessionsRoot,
            sessionId: "rovo-older-session",
            workspacePath: workspace.path,
            modified: Date(timeIntervalSince1970: 100)
        )
        try writeRovoDevSessionMetadata(
            sessionsRoot: sessionsRoot,
            sessionId: "rovo-newer-session",
            workspacePath: workspace.path,
            modified: Date(timeIntervalSince1970: 200)
        )
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let state = MockSocketServerState()
        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else {
                return "OK"
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            if method == "surface.list" {
                return self.surfaceListResponse(id: id, surfaceId: surfaceId)
            }
            if method == "feed.push" {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "rovodev", "prompt-submit"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId,
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_ROVODEV_SESSIONS_DIR": sessionsRoot.path,
                "CMUX_AGENT_LAUNCH_CWD": workspace.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            standardInput: #"{"cwd":"\#(workspace.path)","hook_event_name":"on_tool_permission"}"#,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")

        let storeURL = root.appendingPathComponent("rovodev-hook-sessions.json", isDirectory: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
    }

    func testRovoDevPromptSubmitReadsConfiguredPersistenceDirWithCommentsHashAndApostrophePath() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("rovo-config")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-rovo-config-hook-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("repo", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions#john's", isDirectory: true)
        let configDir = root.appendingPathComponent(".rovodev", isDirectory: true)
        let workspaceId = "55555555-5555-5555-5555-555555555555"
        let surfaceId = "66666666-6666-6666-6666-666666666666"
        let sessionId = "rovo-config-session"

        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try writeRovoDevSessionMetadata(
            sessionsRoot: sessionsRoot,
            sessionId: sessionId,
            workspacePath: workspace.path,
            modified: Date(timeIntervalSince1970: 300)
        )
        let config = [
            "sessions:",
            "  # top-level comments inside sessions should not end the block",
            "  nested:",
            "    persistenceDir: /tmp/wrong",
            "  persistenceDir: '~/sessions#john''s'",
            "other: true",
        ].joined(separator: "\r\n")
        try config.write(
            to: configDir.appendingPathComponent("config.yml", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else {
                return "OK"
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            if method == "surface.list" {
                return self.surfaceListResponse(id: id, surfaceId: surfaceId)
            }
            if method == "feed.push" {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
        }

        let environment: [String: String] = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_WORKSPACE_ID": workspaceId,
            "CMUX_SURFACE_ID": surfaceId,
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_LAUNCH_KIND": "rovodev",
            "CMUX_AGENT_LAUNCH_EXECUTABLE": "/usr/local/bin/acli",
            "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated([
                "/usr/local/bin/acli",
                "rovodev",
                "run",
                "--restore",
                sessionId,
                "--yolo",
            ]),
            "CMUX_AGENT_LAUNCH_CWD": workspace.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
        ]

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "rovodev", "prompt-submit"],
            environment: environment,
            standardInput: #"{"cwd":"\#(workspace.path)","hook_event_name":"on_tool_permission"}"#,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")

        let storeURL = root.appendingPathComponent("rovodev-hook-sessions.json", isDirectory: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
        let sessions = try XCTUnwrap(json["sessions"] as? [String: Any])
        XCTAssertNotNil(sessions[sessionId] as? [String: Any])
    }

    func testRovoDevPromptSubmitWithoutCwdDoesNotInferUnrelatedSession() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("rovo-nocwd")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-rovo-nocwd-hook-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let workspaceId = "55555555-5555-5555-5555-555555555555"
        let surfaceId = "66666666-6666-6666-6666-666666666666"
        let unrelatedSessionId = "rovo-unrelated-session"

        try writeRovoDevSessionMetadata(
            sessionsRoot: sessionsRoot,
            sessionId: unrelatedSessionId,
            workspacePath: "/tmp/unrelated",
            modified: Date(timeIntervalSince1970: 300)
        )
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let state = MockSocketServerState()
        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else {
                return "OK"
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            if method == "surface.list" {
                return self.surfaceListResponse(id: id, surfaceId: surfaceId)
            }
            if method == "feed.push" {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
        }

        let environment: [String: String] = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_WORKSPACE_ID": workspaceId,
            "CMUX_SURFACE_ID": surfaceId,
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_ROVODEV_SESSIONS_DIR": sessionsRoot.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
        ]

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "rovodev", "prompt-submit"],
            environment: environment,
            standardInput: #"{"hook_event_name":"on_tool_permission"}"#,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")

        let storeURL = root.appendingPathComponent("rovodev-hook-sessions.json", isDirectory: false)
        if let data = try? Data(contentsOf: storeURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sessions = json["sessions"] as? [String: Any] {
            XCTAssertNil(sessions[unrelatedSessionId] as? [String: Any])
        }
    }

    func testRovoDevInstallDoesNotReplaceUnreadableConfigPath() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-rovo-install-\(UUID().uuidString)", isDirectory: true)
        let configDir = root.appendingPathComponent(".rovodev", isDirectory: true)
        let configURL = configDir.appendingPathComponent("config.yml", isDirectory: true)
        let sentinelURL = configURL.appendingPathComponent("sentinel", isDirectory: false)

        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configURL, withIntermediateDirectories: true)
        try "keep".write(to: sentinelURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "rovodev", "install", "--yes"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("could not be read"), result.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinelURL.path))
    }

    func writeRovoDevSessionMetadata(
        sessionsRoot: URL,
        sessionId: String,
        workspacePath: String,
        modified: Date
    ) throws {
        let sessionURL = sessionsRoot.appendingPathComponent(sessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionURL, withIntermediateDirectories: true)
        let metadataURL = sessionURL.appendingPathComponent("metadata.json", isDirectory: false)
        let metadata = [
            "title": "Rovo Dev session",
            "workspace_path": workspacePath,
        ]
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted])
        try data.write(to: metadataURL, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: metadataURL.path)
    }
}
