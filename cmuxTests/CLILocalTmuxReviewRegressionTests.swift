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
          *display-message*'#{session_id}'*) printf '%s\n' '$101'; exit 0 ;;
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
          *display-message*'#{session_id}'*) printf '%s\n' '$102'; exit 0 ;;
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
            switch method {
            case "window.list":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["windows": [["id": UUID().uuidString]]]
                )
            case "workspace.list":
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
            default:
                XCTFail("Unexpected method: \(method)")
                return self.v2Response(id: id, ok: false, result: [:])
            }
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

    func testLocalTmuxListFailsClosedOnUnexpectedServerError() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-local-tmux-list-error-\(UUID().uuidString)", isDirectory: true)
        let fakeTmuxURL = root.appendingPathComponent("fake-tmux", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("#!/bin/sh\necho unavailable >&2\nexit 1\n".utf8).write(to: fakeTmuxURL)
        XCTAssertEqual(chmod(fakeTmuxURL.path, 0o755), 0)
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_LOCAL_TMUX_BIN"] = fakeTmuxURL.path
        environment["CMUX_LOCAL_TMUX_STATE_DIR"] = root.path
        environment.removeValue(forKey: "CMUX_SOCKET")
        environment.removeValue(forKey: "CMUX_SOCKET_PATH")

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["local-tmux", "list"],
            environment: environment,
            timeout: 10
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0, result.stdout)
        XCTAssertTrue(result.stderr.contains("liveness is unknown"), result.stderr)
        XCTAssertFalse(result.stderr.contains("unavailable"), result.stderr)
    }

    func testLocalTmuxExistingSessionDoesNotRequireCallerWorkingDirectory() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-local-tmux-existing-cwd-\(UUID().uuidString)", isDirectory: true)
        let doomedCwd = root.appendingPathComponent("deleted-cwd", isDirectory: true)
        let fakeTmuxURL = root.appendingPathComponent("fake-tmux", isDirectory: false)
        let wrapperURL = root.appendingPathComponent("delete-cwd-and-exec", isDirectory: false)
        try FileManager.default.createDirectory(at: doomedCwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeTmux = """
        #!/bin/sh
        case "$*" in
          *display-message*'#{session_id}'*) printf '%s\n' '$103'; exit 0 ;;
          *has-session*) exit 0 ;;
          *display-message*'#{session_path}'*) printf '%s\n' "$EXISTING_TMUX_CWD"; exit 0 ;;
          *) exit 0 ;;
        esac
        """
        let wrapper = """
        #!/bin/sh
        doomed=$1
        shift
        cd "$doomed" || exit 1
        rmdir "$doomed" || exit 1
        exec "$@"
        """
        try Data(fakeTmux.utf8).write(to: fakeTmuxURL)
        try Data(wrapper.utf8).write(to: wrapperURL)
        XCTAssertEqual(chmod(fakeTmuxURL.path, 0o755), 0)
        XCTAssertEqual(chmod(wrapperURL.path, 0o755), 0)

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_LOCAL_TMUX_BIN"] = fakeTmuxURL.path
        environment["CMUX_LOCAL_TMUX_STATE_DIR"] = root.path
        environment["EXISTING_TMUX_CWD"] = root.path
        environment.removeValue(forKey: "CMUX_SOCKET")
        environment.removeValue(forKey: "CMUX_SOCKET_PATH")

        let result = runProcess(
            executablePath: wrapperURL.path,
            arguments: [
                doomedCwd.path, cliPath,
                "local-tmux", "start", "already-live", "--detached",
            ],
            environment: environment,
            timeout: 10
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("state=detached"), result.stdout)
    }

    func testLocalTmuxWorkspaceRefResolvesAcrossWindows() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-local-tmux-cross-window-\(UUID().uuidString)", isDirectory: true)
        let fakeTmuxURL = root.appendingPathComponent("fake-tmux", isDirectory: false)
        let socketPath = makeSocketPath("local-tmux-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let firstWindowID = UUID().uuidString
        let secondWindowID = UUID().uuidString
        let firstWorkspaceID = UUID().uuidString
        let targetWorkspaceID = UUID().uuidString
        let createdSurfaceID = UUID().uuidString
        let sessionName = "cross-window"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let fakeTmux = """
        #!/bin/sh
        case "$FAKE_TMUX_MODE:$*" in
          *display-message*'#{session_id}'*) printf '%s\n' '$104'; exit 0 ;;
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

        let state = MockSocketServerState()
        let expectedCommand = "TMUX= CMUX_LOCAL_TMUX=1 exec '\(fakeTmuxURL.path)' -S '\(root.appendingPathComponent("server.sock").path)' attach-session -t '$104'"
        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "window.list":
                return self.v2Response(id: id, ok: true, result: [
                    "windows": [["id": firstWindowID], ["id": secondWindowID]],
                ])
            case "workspace.list":
                let windowID = params["window_id"] as? String
                let workspaces: [[String: Any]] = windowID == firstWindowID
                    ? [["id": firstWorkspaceID, "ref": "workspace:1"]]
                    : [["id": targetWorkspaceID, "ref": "workspace:2", "title": "target"]]
                return self.v2Response(id: id, ok: true, result: ["workspaces": workspaces])
            case "surface.create":
                XCTAssertEqual(params["workspace_id"] as? String, targetWorkspaceID)
                XCTAssertEqual(params["initial_command"] as? String, expectedCommand)
                XCTAssertEqual(params["tmux_start_command"] as? String, expectedCommand)
                return self.v2Response(id: id, ok: true, result: [
                    "workspace_id": targetWorkspaceID,
                    "surface_id": createdSurfaceID,
                ])
            default:
                XCTFail("Unexpected method: \(method)")
                return self.v2Response(id: id, ok: false, result: [:])
            }
        }

        environment["FAKE_TMUX_MODE"] = "live"
        environment["CMUX_SOCKET_PATH"] = socketPath
        let attach = runProcess(
            executablePath: cliPath,
            arguments: ["local-tmux", "attach", sessionName, "--workspace", "workspace:2"],
            environment: environment,
            timeout: 10
        )

        wait(for: [serverHandled], timeout: 10)
        XCTAssertFalse(attach.timedOut, attach.stderr)
        XCTAssertEqual(attach.status, 0, attach.stderr)
        XCTAssertTrue(attach.stdout.contains(createdSurfaceID), attach.stdout)
        XCTAssertTrue(state.snapshot().contains { $0.contains("surface.create") })
    }

    func testLocalTmuxInvalidSessionNamesFailThroughCLI() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-local-tmux-invalid-name-\(UUID().uuidString)", isDirectory: true)
        let fakeTmuxURL = root.appendingPathComponent("fake-tmux", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakeTmuxURL)
        XCTAssertEqual(chmod(fakeTmuxURL.path, 0o755), 0)

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_LOCAL_TMUX_BIN"] = fakeTmuxURL.path
        environment["CMUX_LOCAL_TMUX_STATE_DIR"] = root.path
        environment.removeValue(forKey: "CMUX_SOCKET")
        environment.removeValue(forKey: "CMUX_SOCKET_PATH")

        for invalidName in ["work.name", "work:name"] {
            let result = runProcess(
                executablePath: cliPath,
                arguments: ["local-tmux", "start", invalidName, "--detached"],
                environment: environment,
                timeout: 10
            )
            XCTAssertNotEqual(result.status, 0, invalidName)
            XCTAssertTrue(result.stderr.contains("letters, numbers, underscore, or dash"), result.stderr)
        }
    }
}
