import Darwin
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func testLocalTmuxAttachCreatesSurfaceAfterPersistedSurfaceDisappears() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-local-tmux-surface-recovery-\(UUID().uuidString)", isDirectory: true)
        let fakeTmuxURL = root.appendingPathComponent("fake-tmux", isDirectory: false)
        let registryURL = root.appendingPathComponent("sessions.json", isDirectory: false)
        let socketPath = makeSocketPath("local-tmux-surface-recovery")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let workspaceID = UUID().uuidString
        let staleSurfaceID = UUID().uuidString
        let createdSurfaceID = UUID().uuidString
        let logicalID = UUID()
        let sessionName = "surface-recovery"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let fakeTmux = """
        #!/bin/sh
        case "$*" in
          *display-message*'#{session_name}'*) printf 'surface-recovery\t$31\teeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee\t31\n'; exit 0 ;;
          *has-session*|*set-option*) exit 0 ;;
          *) exit 0 ;;
        esac
        """
        try Data(fakeTmux.utf8).write(to: fakeTmuxURL)
        XCTAssertEqual(chmod(fakeTmuxURL.path, 0o755), 0)

        let session: [String: Any] = [
            "id": logicalID.uuidString,
            "name": sessionName,
            "tmuxBinding": [
                "sessionID": "$31",
                "serverID": "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee",
                "sessionCreated": 31,
            ],
            "socketPath": root.appendingPathComponent("server.sock").path,
            "cwd": root.path,
            "workspaceID": workspaceID,
            "workspaceTitle": "durable-workspace",
            "surfaceID": staleSurfaceID,
            "createdAt": 1.0,
            "updatedAt": 1.0,
        ]
        try JSONSerialization.data(withJSONObject: ["version": 1, "sessions": [session]], options: [.sortedKeys])
            .write(to: registryURL)
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
            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "window.list":
                return self.v2Response(id: id, ok: true, result: [
                    "windows": [["id": UUID().uuidString]],
                ])
            case "workspace.list":
                return self.v2Response(id: id, ok: true, result: [
                    "workspaces": [[
                        "id": workspaceID,
                        "title": "durable-workspace",
                        "current_directory": root.path,
                    ]],
                ])
            case "surface.list":
                XCTAssertEqual(params["workspace_id"] as? String, workspaceID)
                return self.v2Response(id: id, ok: true, result: ["surfaces": []])
            case "surface.create":
                XCTAssertEqual(params["workspace_id"] as? String, workspaceID)
                XCTAssertTrue((params["initial_command"] as? String)?.contains("$31") == true)
                XCTAssertTrue((params["initial_command"] as? String)?.contains("@cmux_local_server_id") == true)
                return self.v2Response(id: id, ok: true, result: [
                    "workspace_id": workspaceID,
                    "surface_id": createdSurfaceID,
                ])
            default:
                XCTFail("Unexpected method: \(method)")
                return self.v2Response(id: id, ok: false, result: [:])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_LOCAL_TMUX_BIN"] = fakeTmuxURL.path
        environment["CMUX_LOCAL_TMUX_STATE_DIR"] = root.path
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment.removeValue(forKey: "CMUX_SOCKET")
        environment.removeValue(forKey: "CMUX_WORKSPACE_ID")
        environment.removeValue(forKey: "CMUX_SURFACE_ID")

        let attach = runProcess(
            executablePath: cliPath,
            arguments: ["local-tmux", "attach", "--id", logicalID.uuidString],
            environment: environment,
            timeout: 10
        )

        wait(for: [serverHandled], timeout: 10)
        XCTAssertFalse(attach.timedOut, attach.stderr)
        XCTAssertEqual(attach.status, 0, attach.stderr)
        XCTAssertTrue(attach.stdout.contains(createdSurfaceID), attach.stdout)
        let persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: registryURL)) as? [String: Any]
        )
        let persistedSessions = try XCTUnwrap(persisted["sessions"] as? [[String: Any]])
        XCTAssertEqual(persistedSessions.first?["surfaceID"] as? String, createdSurfaceID)
    }
}
