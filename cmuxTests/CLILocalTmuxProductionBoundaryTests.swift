import Darwin
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func testLocalTmuxAttachCommandRunsThroughGhosttyLoginShellWrapper() throws {
        let cliPath = try bundledCLIPath()
        let root = makeLocalTmuxTestRoot("ghostty-attach-wrapper")
        let fakeTmuxURL = root.appendingPathComponent("fake-tmux", isDirectory: false)
        let registryURL = root.appendingPathComponent("sessions.json", isDirectory: false)
        let socketPath = makeSocketPath("local-tmux-attach-wrapper")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let sessionID = "$7"
        let serverID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
        let outputURL = root.appendingPathComponent("invocation", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let fakeTmux = """
        #!/bin/sh
        command_name=
        for argument in "$@"; do
          case "$argument" in
            set-option|has-session|display-message) command_name=$argument ;;
          esac
        done
        case "$command_name" in
          set-option|has-session) exit 0 ;;
          display-message) printf 'work\\t$7\\tcccccccc-cccc-cccc-cccc-cccccccccccc\\t42\\n'; exit 0 ;;
        esac
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
          "$TMUX" "$CMUX_LOCAL_TMUX" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" \
          > "$CMUX_TEST_OUTPUT"
        """
        try Data(fakeTmux.utf8).write(to: fakeTmuxURL)
        XCTAssertEqual(chmod(fakeTmuxURL.path, 0o755), 0)

        let session: [String: Any] = [
            "id": UUID().uuidString,
            "name": "work",
            "tmuxBinding": ["sessionID": sessionID, "serverID": serverID, "sessionCreated": 42],
            "socketPath": root.appendingPathComponent("server.sock").path,
            "cwd": root.path,
            "workspaceID": workspaceID,
            "workspaceTitle": "work",
            "createdAt": 1.0,
            "updatedAt": 1.0,
        ]
        try JSONSerialization.data(withJSONObject: ["version": 1, "sessions": [session]], options: [.sortedKeys])
            .write(to: registryURL)
        XCTAssertEqual(chmod(registryURL.path, 0o600), 0)

        let state = MockSocketServerState()
        let serverHandled = startMockServer(
            listenerFD: listenerFD,
            state: state,
            fulfillWhen: { line in
                self.jsonObject(line)?["method"] as? String == "surface.create"
            }
        ) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "window.list":
                return self.v2Response(id: id, ok: true, result: ["windows": [["id": "window:1"]]])
            case "workspace.list":
                return self.v2Response(id: id, ok: true, result: [
                    "workspaces": [["id": workspaceID, "title": "work", "current_directory": root.path]],
                ])
            case "surface.list":
                return self.v2Response(id: id, ok: true, result: ["surfaces": []])
            case "surface.create":
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceID, "surface_id": surfaceID])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": method])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_LOCAL_TMUX_BIN"] = fakeTmuxURL.path
        environment["CMUX_LOCAL_TMUX_STATE_DIR"] = root.path
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_TEST_OUTPUT"] = outputURL.path
        environment.removeValue(forKey: "CMUX_SOCKET")
        environment.removeValue(forKey: "CMUX_WORKSPACE_ID")
        environment.removeValue(forKey: "CMUX_SURFACE_ID")
        let attach = runProcess(
            executablePath: cliPath,
            arguments: ["local-tmux", "attach", "work", "--workspace", workspaceID, "--json"],
            environment: environment,
            timeout: 10
        )

        wait(for: [serverHandled], timeout: 10)
        XCTAssertFalse(attach.timedOut, attach.stderr)
        XCTAssertEqual(attach.status, 0, attach.stderr)
        let createRequest = try XCTUnwrap(
            state.snapshot().compactMap { self.jsonObject($0) }.first { $0["method"] as? String == "surface.create" }
        )
        let command = try XCTUnwrap((createRequest["params"] as? [String: Any])?["initial_command"] as? String)
        let result = runProcess(
            executablePath: "/bin/bash",
            arguments: ["--noprofile", "--norc", "-c", "exec -l \(command)"],
            environment: environment,
            timeout: 10
        )
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let invocation = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(invocation.hasPrefix("|1|-S|"), invocation)
        XCTAssertTrue(invocation.contains("'attach-session' '-t' '$7'"), invocation)
    }

    func testLocalTmuxClientListingUsesPopulatedTTYTarget() throws {
        let cliPath = try bundledCLIPath()
        let root = makeLocalTmuxTestRoot("client-tty-target")
        let fakeTmuxURL = root.appendingPathComponent("fake-tmux", isDirectory: false)
        let mutationLogURL = root.appendingPathComponent("mutations.log", isDirectory: false)
        let registryURL = root.appendingPathComponent("sessions.json", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeTmux = """
        #!/bin/sh
        command_name=
        for argument in "$@"; do
          case "$argument" in
            set-option|has-session|display-message|list-clients|detach-client) command_name=$argument ;;
          esac
        done
        case "$command_name" in
          set-option|has-session) exit 0 ;;
          display-message) printf 'work\\t$7\\tdddddddd-dddd-dddd-dddd-dddddddddddd\\t42\\n'; exit 0 ;;
          detach-client) printf '%s\\n' "$*" >> "$CMUX_TEST_MUTATIONS"; exit 0 ;;
        esac
        case "$*" in
          *list-clients*)
            case "$*" in
              *'#{client_tty}'*) printf '/dev/ttys999\\twork\\t123\\t/dev/ttys999\\n'; exit 0 ;;
              *) printf '\\twork\\t123\\t/dev/ttys999\\n'; exit 0 ;;
            esac
            ;;
          *) exit 0 ;;
        esac
        """
        try Data(fakeTmux.utf8).write(to: fakeTmuxURL)
        XCTAssertEqual(chmod(fakeTmuxURL.path, 0o755), 0)

        let session: [String: Any] = [
            "id": UUID().uuidString,
            "name": "work",
            "tmuxBinding": [
                "sessionID": "$7",
                "serverID": "dddddddd-dddd-dddd-dddd-dddddddddddd",
                "sessionCreated": 42,
            ],
            "socketPath": root.appendingPathComponent("server.sock").path,
            "cwd": root.path,
            "createdAt": 1.0,
            "updatedAt": 1.0,
        ]
        try JSONSerialization.data(withJSONObject: ["version": 1, "sessions": [session]], options: [.sortedKeys])
            .write(to: registryURL)
        XCTAssertEqual(chmod(registryURL.path, 0o600), 0)

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_LOCAL_TMUX_BIN"] = fakeTmuxURL.path
        environment["CMUX_LOCAL_TMUX_STATE_DIR"] = root.path
        environment["CMUX_TEST_MUTATIONS"] = mutationLogURL.path
        environment.removeValue(forKey: "CMUX_SOCKET")
        environment.removeValue(forKey: "CMUX_SOCKET_PATH")
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["local-tmux", "detach", "work", "--json"],
            environment: environment,
            timeout: 10
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let mutations = try String(contentsOf: mutationLogURL, encoding: .utf8)
        XCTAssertTrue(mutations.contains("detach-client"), mutations)
        XCTAssertTrue(mutations.contains("/dev/ttys999"), mutations)
    }
}
