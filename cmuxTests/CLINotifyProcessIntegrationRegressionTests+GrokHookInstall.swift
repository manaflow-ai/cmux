import XCTest
import Darwin


// MARK: - Grok hook install routing, pinning, and legacy-config preservation
extension CLINotifyProcessIntegrationRegressionTests {
    func testGrokHookInstallRoutesNotificationEventToNotificationSubcommand() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-hook-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyHookURL = root
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("cmux.json", isDirectory: false)
        try FileManager.default.createDirectory(at: legacyHookURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacyHookJSON: [String: Any] = [
            "hooks": [
                "PostToolUse": [
                    [
                        "hooks": [
                            [
                                "command": "[ -n \"$CMUX_SURFACE_ID\" ] && [ \"$CMUX_GROK_HOOKS_DISABLED\" != \"1\" ] && command -v cmux >/dev/null 2>&1 && cmux hooks feed --source grok --event PostToolUse || echo '{}'",
                                "timeout": 120,
                                "type": "command",
                            ],
                        ],
                    ],
                ],
                "Stop": [
                    [
                        "hooks": [
                            [
                                "command": "[ -n \"$CMUX_SURFACE_ID\" ] && [ \"$CMUX_GROK_HOOKS_DISABLED\" != \"1\" ] && command -v cmux >/dev/null 2>&1 && cmux hooks grok stop || echo '{}'",
                                "timeout": 5,
                                "type": "command",
                            ],
                        ],
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: legacyHookJSON, options: [.prettyPrinted, .sortedKeys])
            .write(to: legacyHookURL, options: .atomic)

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "grok", "install", "--yes"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let hookURL = root
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("cmux-session.json", isDirectory: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: hookURL)) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let notificationGroups = try XCTUnwrap(hooks["Notification"] as? [[String: Any]])
        let notificationCommands = notificationGroups
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["command"] as? String }
        let notificationTimeouts = notificationGroups
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["timeout"] as? Int }
        let preToolUseGroups = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        let preToolUseTimeouts = preToolUseGroups
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["timeout"] as? Int }
        let allCommands = hooks.values
            .compactMap { $0 as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["command"] as? String }

        XCTAssertTrue(
            notificationCommands.contains { $0.contains("cmux hooks grok notification") },
            "Expected Grok Notification to dispatch to the notification handler, saw \(notificationCommands)"
        )
        XCTAssertFalse(
            notificationCommands.contains { $0.contains("cmux hooks grok stop") },
            "Grok Notification should not use the generic stop handler, saw \(notificationCommands)"
        )
        XCTAssertEqual(notificationTimeouts, [5])
        XCTAssertEqual(preToolUseTimeouts, [120])
        XCTAssertFalse(
            allCommands.contains { $0.contains("[ -n \"$CMUX_SURFACE_ID\" ]") },
            "Grok strips CMUX_* from hook subprocesses, so installed commands must not gate on CMUX_SURFACE_ID. Saw \(allCommands)"
        )
        XCTAssertFalse(
            allCommands.contains { $0.contains("$CMUX_") },
            "Grok treats $VAR references as required hook environment, so installed commands must avoid CMUX variable interpolation. Saw \(allCommands)"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacyHookURL.path),
            "Expected setup to remove legacy cmux-owned Grok hook file"
        )
    }

    func testGrokHookInstallPinsInstallingCLIAndSocketWithoutCMUXInterpolation() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-hook-pin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pinnedCLI = root.appendingPathComponent("cmux pinned dev cli", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: pinnedCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pinnedCLI.path)

        let socketPath = "/tmp/cmux-debug-grok-pin.sock"
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "grok", "install", "--yes"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_BUNDLED_CLI_PATH": pinnedCLI.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let hookURL = root
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("cmux-session.json", isDirectory: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: hookURL)) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let allCommands = hooks.values
            .compactMap { $0 as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["command"] as? String }

        XCTAssertFalse(allCommands.isEmpty)
        XCTAssertTrue(
            allCommands.allSatisfy { $0.contains("cmux-grok-hook-v2") },
            "Expected installed Grok hooks to carry the owned-hook marker, saw \(allCommands)"
        )
        XCTAssertTrue(
            allCommands.allSatisfy { $0.contains("'\(pinnedCLI.path)'") },
            "Expected installed Grok hooks to pin the installing CLI path, saw \(allCommands)"
        )
        XCTAssertTrue(
            allCommands.allSatisfy { $0.contains("--socket '\(socketPath)'") },
            "Expected installed Grok hooks to pin the installing socket path, saw \(allCommands)"
        )
        XCTAssertFalse(
            allCommands.contains { $0.contains("$CMUX_") },
            "Grok hook commands must not depend on CMUX environment interpolation, saw \(allCommands)"
        )
    }

    func testGrokHookInstallPreservesUserWrappedLegacyCommands() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-hook-preserve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyHookURL = root
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("cmux.json", isDirectory: false)
        try FileManager.default.createDirectory(at: legacyHookURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let preservedCommand = "bash -lc 'cmux hooks grok notification && ~/bin/after-grok'"
        let legacyHookJSON: [String: Any] = [
            "hooks": [
                "Notification": [
                    [
                        "hooks": [
                            [
                                "command": preservedCommand,
                                "timeout": 10,
                                "type": "command",
                            ],
                            [
                                "command": "[ \"$CMUX_GROK_HOOKS_DISABLED\" != \"1\" ] && command -v cmux >/dev/null 2>&1 && cmux hooks grok notification || echo '{}'",
                                "timeout": 10,
                                "type": "command",
                            ],
                        ],
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: legacyHookJSON, options: [.prettyPrinted, .sortedKeys])
            .write(to: legacyHookURL, options: .atomic)

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "grok", "install", "--yes"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: legacyHookURL)) as? [String: Any])
        let hooks = try XCTUnwrap(legacyJSON["hooks"] as? [String: Any])
        let notificationGroups = try XCTUnwrap(hooks["Notification"] as? [[String: Any]])
        let commands = notificationGroups
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["command"] as? String }

        XCTAssertEqual(commands, [preservedCommand])
        XCTAssertFalse(
            commands.contains { $0.hasPrefix("[ \"$CMUX_GROK_HOOKS_DISABLED\"") },
            "Expected setup to remove only exact cmux-owned legacy commands, saw \(commands)"
        )
    }

    func testGrokHookInstallPreservesLegacyFileMetadataWhenPruningOwnedHooks() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-hook-metadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyHookURL = root
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("cmux.json", isDirectory: false)
        try FileManager.default.createDirectory(at: legacyHookURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let legacyHookJSON: [String: Any] = [
            "version": 1,
            "hooks": [
                "Notification": [
                    [
                        "hooks": [
                            [
                                "command": "[ \"$CMUX_GROK_HOOKS_DISABLED\" != \"1\" ] && command -v cmux >/dev/null 2>&1 && cmux hooks grok notification || echo '{}'",
                                "timeout": 10,
                                "type": "command",
                            ],
                        ],
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: legacyHookJSON, options: [.prettyPrinted, .sortedKeys])
            .write(to: legacyHookURL, options: .atomic)

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "grok", "install", "--yes"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: legacyHookURL)) as? [String: Any])
        XCTAssertEqual(legacyJSON["version"] as? Int, 1)
        XCTAssertNil(legacyJSON["hooks"])
    }

    func testGrokHookInstallRejectsFileAtHooksDirectory() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-hook-file-dir-\(UUID().uuidString)", isDirectory: true)
        let grokRoot = root.appendingPathComponent("custom-grok-home", isDirectory: true)
        let hooksPath = grokRoot.appendingPathComponent("hooks", isDirectory: false)
        try FileManager.default.createDirectory(at: grokRoot, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: hooksPath)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "grok", "install", "--yes"],
            environment: [
                "HOME": root.path,
                "GROK_HOME": grokRoot.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0, result.stdout)
        XCTAssertTrue(
            result.stderr.contains("cmux could not create the hooks directory: a file exists at \(hooksPath.path); remove or rename the conflicting file and re-run `cmux hooks setup`"),
            result.stderr
        )
        XCTAssertFalse(
            result.stdout.contains("Required agent configuration is missing."),
            result.stdout
        )
        var isDirectory: ObjCBool = true
        XCTAssertTrue(FileManager.default.fileExists(atPath: hooksPath.path, isDirectory: &isDirectory))
        XCTAssertFalse(isDirectory.boolValue)
    }

}
