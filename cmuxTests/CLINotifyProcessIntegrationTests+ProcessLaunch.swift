import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Process capture and hook launch environment
extension CLINotifyProcessIntegrationTests {
    @MainActor
    func testARunProcessCaptureSurvivesPipeReadHandleTeardown() throws {
        let controller = WorkspaceRemoteSessionController(
            workspace: Workspace(),
            configuration: WorkspaceRemoteConfiguration(
                destination: "test@example.invalid",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: nil,
                relayID: nil,
                relayToken: nil,
                localSocketPath: nil,
                terminalStartupCommand: nil
            ),
            controllerID: UUID()
        )

        let didCloseReadHandles = DispatchSemaphore(value: 0)
        WorkspaceRemoteSessionController.runProcessReadHandlesDidInstallForTesting = { stdoutHandle, stderrHandle in
            try? stdoutHandle.close()
            try? stderrHandle.close()
            didCloseReadHandles.signal()
        }
        defer {
            WorkspaceRemoteSessionController.runProcessReadHandlesDidInstallForTesting = nil
        }

        let result = try controller.runProcessForTesting(
            executable: "/usr/bin/true",
            arguments: [],
            timeout: 2
        )

        XCTAssertEqual(didCloseReadHandles.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
    }

    func testAgentHookLaunchEnvironmentDoesNotPersistPathOrShell() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("hook")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            return self.v2Response(
                id: line,
                ok: false,
                error: ["code": "unexpected", "message": "Unexpected command \(line)"]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        for key in [
            "ANTHROPIC_MODEL",
            "CLAUDE_CONFIG_DIR",
            "CMUX_CUSTOM_CLAUDE_PATH",
            "NODE_OPTIONS",
            "OPENCODE_CONFIG_DIR"
        ] {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_AGENT_LAUNCH_KIND"] = "codex"
        environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] = "/usr/local/bin/codex"
        environment["CMUX_AGENT_LAUNCH_ARGV_B64"] = base64NULSeparated([
            "/usr/local/bin/codex",
            "--model",
            "gpt-5.4",
            "old prompt"
        ])
        environment["CMUX_AGENT_LAUNCH_CWD"] = "/tmp/repo"
        environment["CODEX_HOME"] = "/tmp/codex home"
        environment["PATH"] = "/tmp/custom-bin:/usr/bin"
        environment["SHELL"] = "/bin/zsh"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "session-start"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")

        let storeURL = root.appendingPathComponent("codex-hook-sessions.json", isDirectory: false)
        let data = try Data(contentsOf: storeURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
        let sessions = try XCTUnwrap(json["sessions"] as? [String: Any])
        let session = try XCTUnwrap(sessions[surfaceId] as? [String: Any])
        let launchCommand = try XCTUnwrap(session["launchCommand"] as? [String: Any])
        let persistedEnvironment = try XCTUnwrap(launchCommand["environment"] as? [String: String])
        XCTAssertEqual(persistedEnvironment, ["CODEX_HOME": "/tmp/codex home"])
    }

    private func base64NULSeparated(_ values: [String]) -> String {
        var data = Data()
        for value in values {
            data.append(contentsOf: value.utf8)
            data.append(0)
        }
        return data.base64EncodedString()
    }

}
