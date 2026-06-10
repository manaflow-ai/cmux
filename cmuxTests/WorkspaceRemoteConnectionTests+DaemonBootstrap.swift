import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Daemon bootstrap uploads and persistent reverse relay
extension WorkspaceRemoteConnectionTests {
    func testRemoteDropPathUsesLowercasedExtensionAndProvidedUUID() throws {
        let fileURL = URL(fileURLWithPath: "/Users/test/Screen Shot.PNG")
        let uuid = try XCTUnwrap(UUID(uuidString: "12345678-1234-1234-1234-1234567890AB"))

        let remotePath = WorkspaceRemoteSessionController.remoteDropPath(for: fileURL, uuid: uuid)

        XCTAssertEqual(remotePath, "/tmp/cmux-drop-12345678-1234-1234-1234-1234567890ab.png")
    }

    @MainActor
    func testDaemonBootstrapUploadUsesAbsoluteHomePathForScpDestination() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-remote-daemon-upload-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let fakeDaemonURL = directoryURL.appendingPathComponent("cmuxd-remote", isDirectory: false)
        try Data("fake daemon".utf8).write(to: fakeDaemonURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeDaemonURL.path)

        let previousAllowLocalBuild = getenv("CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD").map { String(cString: $0) }
        let previousDaemonBinary = getenv("CMUX_REMOTE_DAEMON_BINARY").map { String(cString: $0) }
        setenv("CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD", "1", 1)
        setenv("CMUX_REMOTE_DAEMON_BINARY", fakeDaemonURL.path, 1)
        defer {
            if let previousAllowLocalBuild {
                setenv("CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD", previousAllowLocalBuild, 1)
            } else {
                unsetenv("CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD")
            }
            if let previousDaemonBinary {
                setenv("CMUX_REMOTE_DAEMON_BINARY", previousDaemonBinary, 1)
            } else {
                unsetenv("CMUX_REMOTE_DAEMON_BINARY")
            }
        }

        let scpInvoked = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var scpDestination: String?
        WorkspaceRemoteSessionController.runProcessOverrideForTesting = { executable, arguments, _, _ in
            if executable == "/usr/bin/ssh" {
                let command = arguments.last ?? ""
                if command.contains("uname -s") {
                    return (
                        status: 0,
                        stdout: """
                        __CMUX_REMOTE_HOME__=/home/test
                        __CMUX_REMOTE_OS__=Linux
                        __CMUX_REMOTE_ARCH__=x86_64
                        __CMUX_REMOTE_EXISTS__=no
                        """,
                        stderr: ""
                    )
                }
                if command.contains("mkdir -p") {
                    return (status: 0, stdout: "", stderr: "")
                }
                return (status: 0, stdout: "", stderr: "")
            }
            if executable == "/usr/bin/scp" {
                lock.lock()
                scpDestination = arguments.last
                lock.unlock()
                scpInvoked.signal()
                return (status: 1, stdout: "", stderr: "intentional stop after upload destination capture")
            }
            XCTFail("unexpected executable \(executable)")
            return (status: 1, stdout: "", stderr: "unexpected executable")
        }
        defer { WorkspaceRemoteSessionController.runProcessOverrideForTesting = nil }

        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "test@hpc.example",
            port: 2222,
            identityFile: "/Users/test/.ssh/id_ed25519",
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "ssh test@hpc.example"
        )
        defer { workspace.disconnectRemoteConnection(clearConfiguration: true) }

        workspace.configureRemoteConnection(config, autoConnect: true)

        XCTAssertEqual(scpInvoked.wait(timeout: .now() + 2), .success)
        lock.lock()
        let capturedDestination = scpDestination
        lock.unlock()
        let destination = try XCTUnwrap(capturedDestination)
        XCTAssertTrue(
            destination.hasPrefix("test@hpc.example:/home/test/.cmux/bin/cmuxd-remote/"),
            "expected scp to target an absolute path under remote HOME, got \(destination)"
        )
        XCTAssertTrue(
            destination.contains("/linux-amd64/cmuxd-remote.tmp-"),
            "expected daemon platform temp path in \(destination)"
        )
    }

    @MainActor
    func testPersistentPTYBootstrapReinstallsOldDaemonMissingPTYCapability() throws {
        let previousAllowLocalBuild = getenv("CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD").map { String(cString: $0) }
        let previousDaemonBinary = getenv("CMUX_REMOTE_DAEMON_BINARY").map { String(cString: $0) }
        setenv("CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD", "1", 1)
        unsetenv("CMUX_REMOTE_DAEMON_BINARY")
        defer {
            if let previousAllowLocalBuild {
                setenv("CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD", previousAllowLocalBuild, 1)
            } else {
                unsetenv("CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD")
            }
            if let previousDaemonBinary {
                setenv("CMUX_REMOTE_DAEMON_BINARY", previousDaemonBinary, 1)
            } else {
                unsetenv("CMUX_REMOTE_DAEMON_BINARY")
            }
        }

        let scpInvoked = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var scpDestination: String?
        WorkspaceRemoteSessionController.runProcessOverrideForTesting = { executable, arguments, _, _ in
            let executableName = URL(fileURLWithPath: executable).lastPathComponent
            if executable == "/usr/bin/ssh" {
                let command = arguments.last ?? ""
                if command.contains("uname -s") {
                    return (
                        status: 0,
                        stdout: """
                        __CMUX_REMOTE_HOME__=/home/test
                        __CMUX_REMOTE_OS__=Linux
                        __CMUX_REMOTE_ARCH__=x86_64
                        __CMUX_REMOTE_EXISTS__=yes
                        """,
                        stderr: ""
                    )
                }
                if command.contains("serve --stdio") {
                    return (
                        status: 0,
                        stdout: #"{"id":1,"ok":true,"result":{"name":"cmuxd-remote","version":"old","capabilities":["proxy.stream.push"]}}"# + "\n",
                        stderr: ""
                    )
                }
                if command.contains("mkdir -p") {
                    return (status: 0, stdout: "", stderr: "")
                }
                return (status: 0, stdout: "", stderr: "")
            }
            if executable == "/usr/bin/scp" {
                lock.lock()
                scpDestination = arguments.last
                lock.unlock()
                scpInvoked.signal()
                return (status: 1, stdout: "", stderr: "intentional stop after capability reinstall")
            }
            if executableName == "go" {
                if let outputFlagIndex = arguments.firstIndex(of: "-o"),
                   outputFlagIndex + 1 < arguments.count {
                    let outputURL = URL(fileURLWithPath: arguments[outputFlagIndex + 1], isDirectory: false)
                    try? FileManager.default.createDirectory(
                        at: outputURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try Data("fake daemon".utf8).write(to: outputURL)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outputURL.path)
                }
                return (status: 0, stdout: "", stderr: "")
            }
            XCTFail("unexpected executable \(executable)")
            return (status: 1, stdout: "", stderr: "unexpected executable")
        }
        defer { WorkspaceRemoteSessionController.runProcessOverrideForTesting = nil }

        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "test@hpc.example",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "ssh-pty-attach",
            preserveAfterTerminalExit: true
        )
        defer { workspace.disconnectRemoteConnection(clearConfiguration: true) }

        workspace.configureRemoteConnection(config, autoConnect: true)

        XCTAssertEqual(scpInvoked.wait(timeout: .now() + 2), .success)
        lock.lock()
        let capturedDestination = scpDestination
        lock.unlock()
        let destination = try XCTUnwrap(capturedDestination)
        XCTAssertTrue(
            destination.hasPrefix("test@hpc.example:/home/test/.cmux/bin/cmuxd-remote/"),
            "expected missing pty.session to reinstall the old daemon, got \(destination)"
        )
    }

    @MainActor
    func testPersistentReverseRelayCancelsStaleControlMasterForwardBeforeReusingRelayPort() throws {
        let forwardInvoked = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var controlOperations: [(command: String, spec: String)] = []

        WorkspaceRemoteSessionController.runProcessOverrideForTesting = { executable, arguments, _, _ in
            guard executable == "/usr/bin/ssh" else {
                XCTFail("unexpected executable \(executable)")
                return (status: 1, stdout: "", stderr: "unexpected executable")
            }

            if let operationIndex = arguments.firstIndex(of: "-O"),
               operationIndex + 3 < arguments.count,
               arguments[operationIndex + 2] == "-R" {
                let operation = arguments[operationIndex + 1]
                let spec = arguments[operationIndex + 3]
                lock.lock()
                controlOperations.append((command: operation, spec: spec))
                lock.unlock()
                if operation == "forward" {
                    forwardInvoked.signal()
                }
                return (status: 0, stdout: "", stderr: "")
            }

            let command = arguments.last ?? ""
            if command.contains("uname -s") {
                return (
                    status: 0,
                    stdout: """
                    __CMUX_REMOTE_HOME__=/home/test
                    __CMUX_REMOTE_OS__=Linux
                    __CMUX_REMOTE_ARCH__=x86_64
                    __CMUX_REMOTE_EXISTS__=yes
                    """,
                    stderr: ""
                )
            }
            if command.contains("serve --stdio") {
                return (
                    status: 0,
                    stdout: #"{"id":1,"ok":true,"result":{"name":"cmuxd-remote","version":"dev","capabilities":["proxy.stream.push","pty.session","pty.session.token","pty.session.persistent_daemon"]}}"# + "\n",
                    stderr: ""
                )
            }
            return (status: 0, stdout: "", stderr: "")
        }
        defer { WorkspaceRemoteSessionController.runProcessOverrideForTesting = nil }

        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "test@hpc.example",
            port: 2222,
            identityFile: nil,
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-\(getuid())-64044-%C",
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64044,
            relayID: "relay-stale-forward",
            relayToken: String(repeating: "c", count: 64),
            localSocketPath: "/tmp/cmux-stale-forward-test.sock",
            terminalStartupCommand: "ssh-pty-attach",
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "ssh-stale-forward-test"
        )
        defer { workspace.disconnectRemoteConnection(clearConfiguration: true) }

        workspace.configureRemoteConnection(config, autoConnect: true)

        XCTAssertEqual(forwardInvoked.wait(timeout: .now() + 2), .success)
        lock.lock()
        let operations = controlOperations
        lock.unlock()

        XCTAssertGreaterThanOrEqual(operations.count, 2)
        XCTAssertEqual(operations[0].command, "cancel")
        XCTAssertEqual(operations[0].spec, "127.0.0.1:64044")
        XCTAssertEqual(operations[1].command, "forward")
        XCTAssertTrue(
            operations[1].spec.hasPrefix("127.0.0.1:64044:127.0.0.1:"),
            "expected forward to reuse relay port after stale cancel, got \(operations[1].spec)"
        )
    }

    @MainActor
    func testPersistentReverseRelayCleansStaleRemoteListenerAndRetriesControlMasterForward() throws {
        let retryForwardInvoked = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var controlOperations: [(command: String, spec: String)] = []
        var forwardAttempts = 0
        var cleanupInvoked = false
        var cleanupArguments: [String] = []

        WorkspaceRemoteSessionController.runProcessOverrideForTesting = { executable, arguments, _, _ in
            guard executable == "/usr/bin/ssh" else {
                XCTFail("unexpected executable \(executable)")
                return (status: 1, stdout: "", stderr: "unexpected executable")
            }

            if let operationIndex = arguments.firstIndex(of: "-O"),
               operationIndex + 3 < arguments.count,
               arguments[operationIndex + 2] == "-R" {
                let operation = arguments[operationIndex + 1]
                let spec = arguments[operationIndex + 3]
                lock.lock()
                controlOperations.append((command: operation, spec: spec))
                if operation == "forward" {
                    forwardAttempts += 1
                    let attempt = forwardAttempts
                    lock.unlock()
                    if attempt == 1 {
                        return (
                            status: 255,
                            stdout: "",
                            stderr: "remote port forwarding failed for listen port 64045"
                        )
                    }
                    retryForwardInvoked.signal()
                    return (status: 0, stdout: "", stderr: "")
                }
                lock.unlock()
                return (status: 0, stdout: "", stderr: "")
            }

            let command = arguments.last ?? ""
            if command.contains("cmux_stale_relay_listener_cleanup=1") {
                lock.lock()
                cleanupInvoked = true
                cleanupArguments = arguments
                lock.unlock()
                return (
                    status: 0,
                    stdout: "cmux_stale_relay_killed pid=33681 children=34057 port=64045\n",
                    stderr: ""
                )
            }
            if command.contains("uname -s") {
                return (
                    status: 0,
                    stdout: """
                    __CMUX_REMOTE_HOME__=/home/test
                    __CMUX_REMOTE_OS__=Linux
                    __CMUX_REMOTE_ARCH__=x86_64
                    __CMUX_REMOTE_EXISTS__=yes
                    """,
                    stderr: ""
                )
            }
            if command.contains("serve --stdio") {
                return (
                    status: 0,
                    stdout: #"{"id":1,"ok":true,"result":{"name":"cmuxd-remote","version":"dev","capabilities":["proxy.stream.push","pty.session","pty.session.token","pty.session.persistent_daemon"]}}"# + "\n",
                    stderr: ""
                )
            }
            return (status: 0, stdout: "", stderr: "")
        }
        defer { WorkspaceRemoteSessionController.runProcessOverrideForTesting = nil }

        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "test@hpc.example",
            port: 2222,
            identityFile: nil,
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-\(getuid())-64045-%C",
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64045,
            relayID: "relay-stale-forward-retry",
            relayToken: String(repeating: "d", count: 64),
            localSocketPath: "/tmp/cmux-stale-forward-retry.sock",
            terminalStartupCommand: "ssh-pty-attach",
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "ssh-stale-forward-retry"
        )
        defer { workspace.disconnectRemoteConnection(clearConfiguration: true) }

        workspace.configureRemoteConnection(config, autoConnect: true)

        XCTAssertEqual(retryForwardInvoked.wait(timeout: .now() + 2), .success)
        lock.lock()
        let operations = controlOperations
        let cleanupWasInvoked = cleanupInvoked
        let capturedCleanupArguments = cleanupArguments
        let attempts = forwardAttempts
        lock.unlock()

        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(cleanupWasInvoked)
        XCTAssertTrue(capturedCleanupArguments.contains("-S"))
        XCTAssertTrue(capturedCleanupArguments.contains("none"))
        XCTAssertFalse(capturedCleanupArguments.contains(where: { $0.hasPrefix("ControlPath=") }))
        XCTAssertGreaterThanOrEqual(operations.count, 3)
        XCTAssertEqual(operations[0].command, "cancel")
        XCTAssertEqual(operations[0].spec, "127.0.0.1:64045")
        XCTAssertEqual(operations[1].command, "forward")
        XCTAssertEqual(operations[2].command, "forward")
        XCTAssertEqual(operations[1].spec, operations[2].spec)
        XCTAssertTrue(operations[2].spec.hasPrefix("127.0.0.1:64045:127.0.0.1:"))
    }

    func testDetectedSSHUploadFailureCleansUpEarlierRemoteUploads() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-detected-ssh-upload-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let firstFileURL = directoryURL.appendingPathComponent("first.png")
        let secondFileURL = directoryURL.appendingPathComponent("second.png")
        try Data("first".utf8).write(to: firstFileURL)
        try Data("second".utf8).write(to: secondFileURL)

        let session = DetectedSSHSession(
            destination: "lawrence@example.com",
            port: 2200,
            identityFile: "/Users/test/.ssh/id_ed25519",
            configFile: nil,
            jumpHost: nil,
            controlPath: nil,
            useIPv4: false,
            useIPv6: false,
            forwardAgent: false,
            compressionEnabled: false,
            sshOptions: []
        )

        var invocations: [(executable: String, arguments: [String])] = []
        var scpInvocationCount = 0
        DetectedSSHSession.runProcessOverrideForTesting = { executable, arguments, _, _ in
            invocations.append((executable, arguments))
            if executable == "/usr/bin/scp" {
                scpInvocationCount += 1
                if scpInvocationCount == 1 {
                    return (status: 0, stdout: "", stderr: "")
                }
                return (status: 1, stdout: "", stderr: "copy failed")
            }
            if executable == "/usr/bin/ssh" {
                return (status: 0, stdout: "", stderr: "")
            }
            XCTFail("unexpected executable \(executable)")
            return (status: 1, stdout: "", stderr: "unexpected executable")
        }
        defer { DetectedSSHSession.runProcessOverrideForTesting = nil }

        XCTAssertThrowsError(
            try session.uploadDroppedFilesSyncForTesting([firstFileURL, secondFileURL])
        )

        let firstSCPDestination = try XCTUnwrap(
            invocations
                .first(where: { $0.executable == "/usr/bin/scp" })?
                .arguments
                .last
        )
        let uploadedRemotePath = try XCTUnwrap(firstSCPDestination.split(separator: ":", maxSplits: 1).last)
        let cleanupInvocation = try XCTUnwrap(
            invocations.first(where: { $0.executable == "/usr/bin/ssh" })
        )
        let cleanupCommand = cleanupInvocation.arguments.joined(separator: " ")

        XCTAssertTrue(cleanupCommand.contains(String(uploadedRemotePath)))
    }

}
