import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Remote relay metadata and stale listener cleanup scripts
extension WorkspaceRemoteConnectionTests {
    func testRemoteRelayMetadataCleanupScriptRemovesMatchingSocketAddr() {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("cmux-relay-cleanup-\(UUID().uuidString)")
        let relayDir = home.appendingPathComponent(".cmux/relay")
        let socketAddrURL = home.appendingPathComponent(".cmux/socket_addr")
        let authURL = relayDir.appendingPathComponent("64008.auth")
        let daemonPathURL = relayDir.appendingPathComponent("64008.daemon_path")
        let slotURL = relayDir.appendingPathComponent("64008.slot")
        let ttyURL = relayDir.appendingPathComponent("64008.tty")

        XCTAssertNoThrow(try fileManager.createDirectory(at: relayDir, withIntermediateDirectories: true))
        XCTAssertNoThrow(try "127.0.0.1:64008".write(to: socketAddrURL, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "auth".write(to: authURL, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "daemon".write(to: daemonPathURL, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "slot".write(to: slotURL, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "ttys001".write(to: ttyURL, atomically: true, encoding: .utf8))
        defer { try? fileManager.removeItem(at: home) }

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "HOME=\(home.path)",
                "/bin/sh",
                "-c",
                WorkspaceRemoteSessionController.remoteRelayMetadataCleanupScript(relayPort: 64008),
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(fileManager.fileExists(atPath: socketAddrURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: authURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: daemonPathURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: slotURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: ttyURL.path))
    }

    func testRemoteRelayMetadataCleanupScriptPreservesDifferentSocketAddr() {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("cmux-relay-cleanup-preserve-\(UUID().uuidString)")
        let relayDir = home.appendingPathComponent(".cmux/relay")
        let socketAddrURL = home.appendingPathComponent(".cmux/socket_addr")
        let authURL = relayDir.appendingPathComponent("64009.auth")
        let daemonPathURL = relayDir.appendingPathComponent("64009.daemon_path")
        let slotURL = relayDir.appendingPathComponent("64009.slot")
        let ttyURL = relayDir.appendingPathComponent("64009.tty")

        XCTAssertNoThrow(try fileManager.createDirectory(at: relayDir, withIntermediateDirectories: true))
        XCTAssertNoThrow(try "127.0.0.1:64010".write(to: socketAddrURL, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "auth".write(to: authURL, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "daemon".write(to: daemonPathURL, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "slot".write(to: slotURL, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try "ttys002".write(to: ttyURL, atomically: true, encoding: .utf8))
        defer { try? fileManager.removeItem(at: home) }

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "HOME=\(home.path)",
                "/bin/sh",
                "-c",
                WorkspaceRemoteSessionController.remoteRelayMetadataCleanupScript(relayPort: 64009),
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(fileManager.fileExists(atPath: socketAddrURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: authURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: daemonPathURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: slotURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: ttyURL.path))
    }

    func testRemoteStaleRelayListenerCleanupScriptKillsMatchingPersistentRelayListener() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("cmux-stale-relay-cleanup-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        let killLog = root.appendingPathComponent("kill.log")
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try "".write(to: killLog, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableShellFile(
            at: bin.appendingPathComponent("lsof"),
            body: """
            #!/bin/sh
            cat <<'EOF'
            p33681
            f12
            n127.0.0.1:50446
            EOF
            """
        )
        try writeExecutableShellFile(
            at: bin.appendingPathComponent("ps"),
            body: """
            #!/bin/sh
            cat <<'EOF'
            33681 1 /usr/sbin/sshd-session
            34057 33681 /Users/cmux/.cmux/bin/cmuxd-remote/current/darwin-arm64/cmuxd-remote serve --stdio --persistent --slot ssh-c4ba8ab1
            34058 33681 /bin/zsh
            EOF
            """
        )

        let script = try XCTUnwrap(
            WorkspaceRemoteSessionController.remoteStaleRelayListenerCleanupScript(
                relayPort: 50446,
                persistentDaemonSlot: "ssh-c4ba8ab1"
            )
        )
        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "PATH=\(bin.path):/usr/bin:/bin",
                "CMUX_KILL_LOG=\(killLog.path)",
                "/bin/sh",
                "-c",
                """
                kill() { printf '%s\\n' "$*" >> "$CMUX_KILL_LOG"; return 0; }
                \(script)
                """,
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("cmux_stale_relay_killed pid=33681 children=34057 port=50446"), result.stdout)

        let killOutput = try String(contentsOf: killLog, encoding: .utf8)
        XCTAssertTrue(killOutput.contains("-TERM 33681 34057"), killOutput)
        XCTAssertTrue(killOutput.contains("-KILL 33681"), killOutput)
        XCTAssertTrue(killOutput.contains("-KILL 34057"), killOutput)
    }

    func testRemoteStaleRelayListenerCleanupScriptPreservesDifferentPersistentSlot() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("cmux-stale-relay-preserve-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        let killLog = root.appendingPathComponent("kill.log")
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try "".write(to: killLog, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableShellFile(
            at: bin.appendingPathComponent("lsof"),
            body: """
            #!/bin/sh
            cat <<'EOF'
            p33681
            f12
            n127.0.0.1:50446
            EOF
            """
        )
        try writeExecutableShellFile(
            at: bin.appendingPathComponent("ps"),
            body: """
            #!/bin/sh
            cat <<'EOF'
            33681 1 /usr/sbin/sshd-session
            34057 33681 /Users/cmux/.cmux/bin/cmuxd-remote/current/darwin-arm64/cmuxd-remote serve --stdio --persistent --slot ssh-other
            EOF
            """
        )

        let script = try XCTUnwrap(
            WorkspaceRemoteSessionController.remoteStaleRelayListenerCleanupScript(
                relayPort: 50446,
                persistentDaemonSlot: "ssh-c4ba8ab1"
            )
        )
        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "PATH=\(bin.path):/usr/bin:/bin",
                "CMUX_KILL_LOG=\(killLog.path)",
                "/bin/sh",
                "-c",
                """
                kill() { printf '%s\\n' "$*" >> "$CMUX_KILL_LOG"; return 0; }
                \(script)
                """,
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(try String(contentsOf: killLog, encoding: .utf8), "")
    }

    func testRemoteStaleRelayListenerCleanupScriptMatchesPersistentSlotExactly() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("cmux-stale-relay-slot-prefix-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        let killLog = root.appendingPathComponent("kill.log")
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try "".write(to: killLog, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableShellFile(
            at: bin.appendingPathComponent("lsof"),
            body: """
            #!/bin/sh
            cat <<'EOF'
            p33681
            f12
            n127.0.0.1:50446
            EOF
            """
        )
        try writeExecutableShellFile(
            at: bin.appendingPathComponent("ps"),
            body: """
            #!/bin/sh
            cat <<'EOF'
            33681 1 /usr/sbin/sshd-session
            34057 33681 /Users/cmux/.cmux/bin/cmuxd-remote/current/darwin-arm64/cmuxd-remote serve --stdio --persistent --slot ssh-ab
            EOF
            """
        )

        let script = try XCTUnwrap(
            WorkspaceRemoteSessionController.remoteStaleRelayListenerCleanupScript(
                relayPort: 50446,
                persistentDaemonSlot: "ssh-a"
            )
        )
        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "PATH=\(bin.path):/usr/bin:/bin",
                "CMUX_KILL_LOG=\(killLog.path)",
                "/bin/sh",
                "-c",
                """
                kill() { printf '%s\\n' "$*" >> "$CMUX_KILL_LOG"; return 0; }
                \(script)
                """,
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(try String(contentsOf: killLog, encoding: .utf8), "")
    }

    func testRemoteStaleRelayListenerCleanupScriptKillsMetadataMatchedListenerWithoutChild() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("cmux-stale-relay-metadata-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        let relayDir = root.appendingPathComponent(".cmux/relay")
        let killLog = root.appendingPathComponent("kill.log")
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: relayDir, withIntermediateDirectories: true)
        try "/Users/cmux/.cmux/bin/cmuxd-remote/current/darwin-arm64/cmuxd-remote".write(
            to: relayDir.appendingPathComponent("50446.daemon_path"),
            atomically: true,
            encoding: .utf8
        )
        try "ssh-c4ba8ab1".write(
            to: relayDir.appendingPathComponent("50446.slot"),
            atomically: true,
            encoding: .utf8
        )
        try "".write(to: killLog, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableShellFile(
            at: bin.appendingPathComponent("lsof"),
            body: """
            #!/bin/sh
            cat <<'EOF'
            p33681
            f12
            n127.0.0.1:50446
            EOF
            """
        )
        try writeExecutableShellFile(
            at: bin.appendingPathComponent("ps"),
            body: """
            #!/bin/sh
            cat <<'EOF'
            33681 1 /usr/sbin/sshd-session
            EOF
            """
        )

        let script = try XCTUnwrap(
            WorkspaceRemoteSessionController.remoteStaleRelayListenerCleanupScript(
                relayPort: 50446,
                persistentDaemonSlot: "ssh-c4ba8ab1"
            )
        )
        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "HOME=\(root.path)",
                "PATH=\(bin.path):/usr/bin:/bin",
                "CMUX_KILL_LOG=\(killLog.path)",
                "/bin/sh",
                "-c",
                """
                kill() { printf '%s\\n' "$*" >> "$CMUX_KILL_LOG"; return 0; }
                \(script)
                """,
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(
            result.stdout.contains("cmux_stale_relay_killed pid=33681 children= port=50446 reason=metadata"),
            result.stdout
        )

        let killOutput = try String(contentsOf: killLog, encoding: .utf8)
        XCTAssertTrue(killOutput.contains("-TERM 33681"), killOutput)
        XCTAssertTrue(killOutput.contains("-KILL 33681"), killOutput)
    }

    func testRemoteStaleRelayListenerCleanupScriptPreservesMetadataMatchedDifferentPersistentSlot() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("cmux-stale-relay-metadata-preserve-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        let relayDir = root.appendingPathComponent(".cmux/relay")
        let killLog = root.appendingPathComponent("kill.log")
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: relayDir, withIntermediateDirectories: true)
        try "/Users/cmux/.cmux/bin/cmuxd-remote/current/darwin-arm64/cmuxd-remote".write(
            to: relayDir.appendingPathComponent("50446.daemon_path"),
            atomically: true,
            encoding: .utf8
        )
        try "ssh-other-slot".write(
            to: relayDir.appendingPathComponent("50446.slot"),
            atomically: true,
            encoding: .utf8
        )
        try "".write(to: killLog, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableShellFile(
            at: bin.appendingPathComponent("lsof"),
            body: """
            #!/bin/sh
            cat <<'EOF'
            p33681
            f12
            n127.0.0.1:50446
            EOF
            """
        )
        try writeExecutableShellFile(
            at: bin.appendingPathComponent("ps"),
            body: """
            #!/bin/sh
            cat <<'EOF'
            33681 1 /usr/sbin/sshd-session
            EOF
            """
        )

        let script = try XCTUnwrap(
            WorkspaceRemoteSessionController.remoteStaleRelayListenerCleanupScript(
                relayPort: 50446,
                persistentDaemonSlot: "ssh-c4ba8ab1"
            )
        )
        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "HOME=\(root.path)",
                "PATH=\(bin.path):/usr/bin:/bin",
                "CMUX_KILL_LOG=\(killLog.path)",
                "/bin/sh",
                "-c",
                """
                kill() { printf '%s\\n' "$*" >> "$CMUX_KILL_LOG"; return 0; }
                \(script)
                """,
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(try String(contentsOf: killLog, encoding: .utf8), "")
    }

}
