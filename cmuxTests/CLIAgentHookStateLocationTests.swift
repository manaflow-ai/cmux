import Darwin
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func testPreUpgradeClaudeHookWritesThroughInheritedBundleScope() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("claude-inherited-scope")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-inherited-scope-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let bundleIdentifier = "com.cmuxterm.app.nightly"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return "OK"
            }
            switch method {
            case "system.resolve_terminal":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["tty_bindings": [], "pid_binding": NSNull()]
                )
            case "surface.list":
                return self.surfaceListResponse(id: id, surfaceId: surfaceId)
            case "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"]
                )
            }
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "claude", "session-start"],
            environment: [
                "HOME": root.path,
                "CFFIXED_USER_HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId,
                "CMUX_BUNDLE_ID": bundleIdentifier,
                "CMUX_CLAUDE_HOOK_STATE_PATH": "",
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
            ],
            standardInput: #"{"session_id":"pre-upgrade-session","source":"startup","cwd":"\#(root.path)","hook_event_name":"SessionStart"}"#,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let scopedStore = root
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("cmux/agent-hooks", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("claude-hook-sessions.json", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scopedStore.path), scopedStore.path)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".cmuxterm/claude-hook-sessions.json").path
        ))
    }
}
