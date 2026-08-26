import Darwin
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func testLocalTmuxDetachedTakesPrecedenceOverHeadless() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-local-tmux-detached-headless-\(UUID().uuidString)", isDirectory: true)
        let fakeTmuxURL = root.appendingPathComponent("fake-tmux", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeTmux = """
        #!/bin/sh
        case "$*" in
          *has-session*) exit 1 ;;
          *) exit 0 ;;
        esac
        """
        try Data(fakeTmux.utf8).write(to: fakeTmuxURL)
        XCTAssertEqual(chmod(fakeTmuxURL.path, 0o755), 0)

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_LOCAL_TMUX_BIN"] = fakeTmuxURL.path
        environment["CMUX_LOCAL_TMUX_STATE_DIR"] = root.path
        environment.removeValue(forKey: "CMUX_SOCKET")
        environment.removeValue(forKey: "CMUX_SOCKET_PATH")

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "local-tmux", "start", "detached-headless",
                "--cwd", root.path, "--detached", "--headless",
            ],
            environment: environment,
            timeout: 10
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("state=detached"), result.stdout)
    }

    func testLocalTmuxStaleWorkspaceIdentityDoesNotMatchMutableHints() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-local-tmux-stale-workspace-\(UUID().uuidString)", isDirectory: true)
        let fakeTmuxURL = root.appendingPathComponent("fake-tmux", isDirectory: false)
        let socketPath = makeSocketPath("local-tmux-stale")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let staleWorkspaceID = UUID().uuidString
        let lookalikeWorkspaceID = UUID().uuidString
        let sessionName = "stale-workspace"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let fakeTmux = """
        #!/bin/sh
        case "$FAKE_TMUX_MODE:$*" in
          create:*has-session*) exit 1 ;;
          live:*has-session*) exit 0 ;;
          *) exit 0 ;;
        esac
        """
        try Data(fakeTmux.utf8).write(to: fakeTmuxURL)
        XCTAssertEqual(chmod(fakeTmuxURL.path, 0o755), 0)

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_LOCAL_TMUX_BIN"] = fakeTmuxURL.path
        environment["CMUX_LOCAL_TMUX_STATE_DIR"] = root.path
        environment["FAKE_TMUX_MODE"] = "create"
        environment.removeValue(forKey: "CMUX_WORKSPACE_ID")
        environment.removeValue(forKey: "CMUX_SURFACE_ID")
        environment.removeValue(forKey: "CMUX_SOCKET")
        environment.removeValue(forKey: "CMUX_SOCKET_PATH")

        let start = runProcess(
            executablePath: cliPath,
            arguments: ["local-tmux", "start", sessionName, "--cwd", root.path, "--detached"],
            environment: environment,
            timeout: 10
        )
        XCTAssertEqual(start.status, 0, start.stderr)

        let registryURL = root.appendingPathComponent("sessions.json", isDirectory: false)
        var registry = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: registryURL)) as? [String: Any]
        )
        var sessions = try XCTUnwrap(registry["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.count, 1)
        sessions[0]["workspaceID"] = staleWorkspaceID
        sessions[0]["workspaceTitle"] = "mutable-title"
        sessions[0]["cwd"] = root.path
        registry["sessions"] = sessions
        try JSONSerialization.data(withJSONObject: registry, options: [.sortedKeys])
            .write(to: registryURL, options: .atomic)
        XCTAssertEqual(chmod(registryURL.path, 0o600), 0)

        let serverHandled = startMockServer(
            listenerFD: listenerFD,
            state: MockSocketServerState()
        ) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            XCTAssertEqual(method, "workspace.list")
            return self.v2Response(
                id: id,
                ok: true,
                result: [
                    "workspaces": [[
                        "id": lookalikeWorkspaceID,
                        "title": "mutable-title",
                        "current_directory": root.path,
                    ]],
                ]
            )
        }

        environment["FAKE_TMUX_MODE"] = "live"
        environment["CMUX_SOCKET_PATH"] = socketPath
        let attach = runProcess(
            executablePath: cliPath,
            arguments: ["local-tmux", "attach", sessionName],
            environment: environment,
            timeout: 10
        )

        wait(for: [serverHandled], timeout: 10)
        XCTAssertFalse(attach.timedOut, attach.stderr)
        XCTAssertNotEqual(attach.status, 0, attach.stdout)
        XCTAssertTrue(attach.stderr.contains("workspace target was not found"), attach.stderr)
        XCTAssertFalse(attach.stdout.contains(lookalikeWorkspaceID), attach.stdout)
    }
}
