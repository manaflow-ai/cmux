import Darwin
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func testLocalTmuxOldUUIDCannotControlReplacementSession() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-local-tmux-replacement-\(UUID().uuidString)", isDirectory: true)
        let fakeTmuxURL = root.appendingPathComponent("fake-tmux", isDirectory: false)
        let mutationLogURL = root.appendingPathComponent("mutations.log", isDirectory: false)
        let registryURL = root.appendingPathComponent("sessions.json", isDirectory: false)
        let logicalID = UUID()
        let sessionName = "replacement"
        let staleServerID = "77777777-7777-7777-7777-777777777777"
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
            has-session|display-message|list-sessions|list-clients|attach-session|detach-client|kill-session|if-shell) command_name=$argument ;;
          esac
          previous=$argument
        done
        case "$command_name:$target" in
          'has-session:$1') exit 0 ;;
          'has-session:=replacement') exit 0 ;;
          display-message:*) printf 'replacement\t$1\t88888888-8888-8888-8888-888888888888\t123\n'; exit 0 ;;
          list-sessions:*) printf 'replacement\t$1\t88888888-8888-8888-8888-888888888888\t123\t1\n'; exit 0 ;;
          list-clients:*) exit 0 ;;
          attach-session:*|detach-client:*|kill-session:*|if-shell:*) printf '%s\n' "$*" >> "$MUTATION_LOG"; exit 0 ;;
          *) exit 0 ;;
        esac
        """
        try Data(fakeTmux.utf8).write(to: fakeTmuxURL)
        XCTAssertEqual(chmod(fakeTmuxURL.path, 0o755), 0)

        let session: [String: Any] = [
            "id": logicalID.uuidString,
            "name": sessionName,
            "tmuxBinding": [
                "sessionID": "$1",
                "serverID": staleServerID,
                "sessionCreated": 123,
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
        environment["MUTATION_LOG"] = mutationLogURL.path
        environment.removeValue(forKey: "CMUX_SOCKET")
        environment.removeValue(forKey: "CMUX_SOCKET_PATH")

        let list = runProcess(
            executablePath: cliPath,
            arguments: ["local-tmux", "list", "--json"],
            environment: environment,
            timeout: 10
        )
        XCTAssertEqual(list.status, 0, list.stderr)
        let listPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(list.stdout.utf8)) as? [String: Any]
        )
        let listedSessions = try XCTUnwrap(listPayload["sessions"] as? [[String: Any]])
        XCTAssertEqual(listedSessions.count, 2)
        XCTAssertTrue(listedSessions.contains {
            ($0["session_id"] as? String) == "$1"
                && ($0["managed"] as? Bool) == false
                && ($0["live"] as? Bool) == true
        })
        XCTAssertTrue(listedSessions.contains {
            ($0["id"] as? String) == logicalID.uuidString
                && ($0["stale"] as? Bool) == true
        })

        let cleanup = runProcess(
            executablePath: cliPath,
            arguments: ["local-tmux", "cleanup", "--json"],
            environment: environment,
            timeout: 10
        )
        XCTAssertEqual(cleanup.status, 0, cleanup.stderr)
        let cleanupPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(cleanup.stdout.utf8)) as? [String: Any]
        )
        XCTAssertEqual(cleanupPayload["stale_names"] as? [String], [sessionName])

        let operations = [
            ["local-tmux", "status", "--id", logicalID.uuidString],
            ["local-tmux", "detach", "--id", logicalID.uuidString, "--all"],
            ["local-tmux", "attach", "--id", logicalID.uuidString, "--headless"],
            ["local-tmux", "close", "--id", logicalID.uuidString],
        ]
        for arguments in operations {
            let result = runProcess(
                executablePath: cliPath,
                arguments: arguments,
                environment: environment,
                timeout: 10
            )
            XCTAssertFalse(result.timedOut, result.stderr)
            XCTAssertNotEqual(result.status, 0, result.stdout)
            XCTAssertTrue(result.stderr.contains("identity changed"), result.stderr)
        }
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
                "tmuxBinding": [
                    "sessionID": "$\(index)",
                    "serverID": "99999999-9999-9999-9999-999999999999",
                    "sessionCreated": index,
                ],
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

    func testLocalTmuxListBindsLegacyRecordToLiveIdentity() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-local-tmux-legacy-identity-\(UUID().uuidString)", isDirectory: true)
        let fakeTmuxURL = root.appendingPathComponent("fake-tmux", isDirectory: false)
        let registryURL = root.appendingPathComponent("sessions.json", isDirectory: false)
        let logicalID = UUID()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeTmux = """
        #!/bin/sh
        case "$*" in
          *list-sessions*) printf 'legacy\t$9\taaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\t456\t1\n'; exit 0 ;;
          *list-clients*) exit 0 ;;
          *set-option*) exit 0 ;;
          *) exit 1 ;;
        esac
        """
        try Data(fakeTmux.utf8).write(to: fakeTmuxURL)
        XCTAssertEqual(chmod(fakeTmuxURL.path, 0o755), 0)

        let legacySession: [String: Any] = [
            "id": logicalID.uuidString,
            "name": "legacy",
            "socketPath": root.appendingPathComponent("server.sock").path,
            "cwd": root.path,
            "createdAt": 1.0,
            "updatedAt": 1.0,
        ]
        try JSONSerialization.data(withJSONObject: ["version": 1, "sessions": [legacySession]], options: [.sortedKeys])
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

        XCTAssertEqual(result.status, 0, result.stderr)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let sessions = try XCTUnwrap(payload["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?["managed"] as? Bool, true)
        let persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: registryURL)) as? [String: Any]
        )
        let persistedSessions = try XCTUnwrap(persisted["sessions"] as? [[String: Any]])
        let binding = try XCTUnwrap(persistedSessions.first?["tmuxBinding"] as? [String: Any])
        XCTAssertEqual(binding["sessionID"] as? String, "$9")
    }

    func testLocalTmuxAttachReconcilesRenamedSessionByBinding() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-local-tmux-renamed-\(UUID().uuidString)", isDirectory: true)
        let fakeTmuxURL = root.appendingPathComponent("fake-tmux", isDirectory: false)
        let registryURL = root.appendingPathComponent("sessions.json", isDirectory: false)
        let logicalID = UUID()
        let serverID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeTmux = """
        #!/bin/sh
        case "$*" in
          *display-message*'#{session_name}'*) printf 'renamed\t$21\tbbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb\t21\n'; exit 0 ;;
          *list-sessions*) printf 'renamed\t$21\tbbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb\t21\t1\n'; exit 0 ;;
          *list-clients*) exit 0 ;;
          *has-session*|*set-option*|*if-shell*) exit 0 ;;
          *) exit 0 ;;
        esac
        """
        try Data(fakeTmux.utf8).write(to: fakeTmuxURL)
        XCTAssertEqual(chmod(fakeTmuxURL.path, 0o755), 0)

        let session: [String: Any] = [
            "id": logicalID.uuidString,
            "name": "original",
            "tmuxBinding": [
                "sessionID": "$21",
                "serverID": serverID,
                "sessionCreated": 21,
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
        environment.removeValue(forKey: "CMUX_SOCKET")
        environment.removeValue(forKey: "CMUX_SOCKET_PATH")

        let attach = runProcess(
            executablePath: cliPath,
            arguments: ["local-tmux", "attach", "renamed", "--headless"],
            environment: environment,
            timeout: 10
        )
        XCTAssertEqual(attach.status, 0, attach.stderr)

        let list = runProcess(
            executablePath: cliPath,
            arguments: ["local-tmux", "list", "--json"],
            environment: environment,
            timeout: 10
        )
        XCTAssertEqual(list.status, 0, list.stderr)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(list.stdout.utf8)) as? [String: Any]
        )
        let sessions = try XCTUnwrap(payload["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?["id"] as? String, logicalID.uuidString)
        XCTAssertEqual(sessions.first?["session_name"] as? String, "renamed")
        XCTAssertEqual(sessions.first?["managed"] as? Bool, true)

        let persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: registryURL)) as? [String: Any]
        )
        let persistedSessions = try XCTUnwrap(persisted["sessions"] as? [[String: Any]])
        XCTAssertEqual(persistedSessions.count, 1)
        XCTAssertEqual(persistedSessions.first?["name"] as? String, "renamed")
    }
}
