import Darwin
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func testLocalTmuxOldUUIDCannotCloseReplacementSession() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-local-tmux-replacement-\(UUID().uuidString)", isDirectory: true)
        let fakeTmuxURL = root.appendingPathComponent("fake-tmux", isDirectory: false)
        let mutationLogURL = root.appendingPathComponent("mutations.log", isDirectory: false)
        let registryURL = root.appendingPathComponent("sessions.json", isDirectory: false)
        let logicalID = UUID()
        let sessionName = "replacement"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeTmux = """
        #!/bin/sh
        command_name=
        target=
        previous=
        for argument in "$@"; do
          if [ "$previous" = "-t" ]; then target=$argument; fi
          case "$argument" in
            has-session|display-message|kill-session) command_name=$argument ;;
          esac
          previous=$argument
        done
        case "$command_name:$target" in
          'has-session:$1') exit 1 ;;
          'has-session:=replacement') exit 0 ;;
          'display-message:=replacement') printf '%s\n' '$2'; exit 0 ;;
          kill-session:*) printf '%s\n' "$*" >> "$MUTATION_LOG"; exit 0 ;;
          *) exit 0 ;;
        esac
        """
        try Data(fakeTmux.utf8).write(to: fakeTmuxURL)
        XCTAssertEqual(chmod(fakeTmuxURL.path, 0o755), 0)

        let session: [String: Any] = [
            "id": logicalID.uuidString,
            "name": sessionName,
            "tmuxSessionID": "$1",
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
        environment["MUTATION_LOG"] = mutationLogURL.path
        environment.removeValue(forKey: "CMUX_SOCKET")
        environment.removeValue(forKey: "CMUX_SOCKET_PATH")

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["local-tmux", "close", "--id", logicalID.uuidString],
            environment: environment,
            timeout: 10
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0, result.stdout)
        XCTAssertTrue(result.stderr.contains("identity changed"), result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mutationLogURL.path))
        let persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: registryURL)) as? [String: Any]
        )
        XCTAssertEqual((persisted["sessions"] as? [[String: Any]])?.count, 1)
    }

    func testLocalTmuxDuplicateRegistryNamesFailWithoutTrap() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-local-tmux-duplicate-state-\(UUID().uuidString)", isDirectory: true)
        let fakeTmuxURL = root.appendingPathComponent("fake-tmux", isDirectory: false)
        let registryURL = root.appendingPathComponent("sessions.json", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakeTmuxURL)
        XCTAssertEqual(chmod(fakeTmuxURL.path, 0o755), 0)

        let sessions = [1, 2].map { index -> [String: Any] in
            [
                "id": UUID().uuidString,
                "name": "duplicate",
                "tmuxSessionID": "$\(index)",
                "socketPath": root.appendingPathComponent("server.sock").path,
                "cwd": root.path,
                "createdAt": Double(index),
                "updatedAt": Double(index),
            ]
        }
        try JSONSerialization.data(withJSONObject: ["version": 1, "sessions": sessions], options: [.sortedKeys])
            .write(to: registryURL)
        XCTAssertEqual(chmod(registryURL.path, 0o600), 0)

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_LOCAL_TMUX_BIN"] = fakeTmuxURL.path
        environment["CMUX_LOCAL_TMUX_STATE_DIR"] = root.path
        environment.removeValue(forKey: "CMUX_SOCKET")
        environment.removeValue(forKey: "CMUX_SOCKET_PATH")

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["local-tmux", "list", "--json"],
            environment: environment,
            timeout: 10
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertTrue(result.stderr.contains("state could not be accessed safely"), result.stderr)
        XCTAssertFalse(result.stderr.localizedCaseInsensitiveContains("fatal error"), result.stderr)
    }
}
