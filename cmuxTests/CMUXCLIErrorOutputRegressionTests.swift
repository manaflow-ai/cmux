import CmuxSettings
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized) struct CMUXCLIErrorOutputRegressionTests {
    struct ProcessRunResult {
        let status: Int32
        let stdout: String
        /// Captured on its own pipe, not merged into `stdout`.
        ///
        /// Roughly thirty tests here parse stdout as JSON or compare it to an exact
        /// reply. While both streams shared one pipe, a single unrelated diagnostic line
        /// from the runtime landed in the middle of that payload and failed the content
        /// check instead of naming itself.
        let stderr: String
        let timedOut: Bool
        /// Defaulted so existing call sites are unaffected. A process killed by a signal reports
        /// `.uncaughtSignal`, and its `terminationStatus` is the signal number — indistinguishable
        /// from an ordinary non-zero exit if you only look at the status.
        var terminationReason: Process.TerminationReason = .exit

        var diedFromSignal: Bool { terminationReason == .uncaughtSignal }

        /// Both streams together, for a check that cares whether the CLI said something
        /// at all rather than which stream carried it.
        var combinedOutput: String { stdout + stderr }

        var diagnostics: String {
            "status=\(status) reason=\(diedFromSignal ? "uncaughtSignal" : "exit") "
                + "timedOut=\(timedOut) stdout=\(stdout.isEmpty ? "<empty>" : stdout) "
                + "stderr=\(stderr.isEmpty ? "<empty>" : stderr)"
        }
    }

    @Test func testCLIErrorPathDoesNotCrashWhenStderrIsClosed() throws {
        let cliPath = try bundledCLIPath()
        // Pin the socket and the home directory. Without CMUX_SOCKET_PATH the CLI's resolution can
        // fall back to a machine-global marker file and reach whatever app happens to be running,
        // which would make this test's exit code depend on the machine rather than on the CLI.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-stderr-closed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let socketPath = home.appendingPathComponent("cmux.sock").path

        // `exec` so the process we wait on is the CLI itself. Without it the shell is the child, and
        // a shell reports a signalled child as an ordinary exit with status 128+signal — which would
        // hide the very crash this test exists to catch.
        let result = runShell(
            "CMUX_CLI_SENTRY_DISABLED=1 "
                + "CMUX_SOCKET_PATH=\(shellSingleQuote(socketPath)) "
                + "CFFIXED_USER_HOME=\(shellSingleQuote(home.path)) "
                + "HOME=\(shellSingleQuote(home.path)) "
                + "exec \(shellSingleQuote(cliPath)) definitely-not-a-command 2>&-",
            // The assignments above are what the CLI sees; this is the shell's own
            // environment, kept bare so no `CMUX_*` the test host was launched with
            // leaks through to the child.
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: 5
        )

        // What is guarded here is a crash, not an exit code. cc4a6109d8 replaced
        // FileHandle.standardError.write — which raises, and aborts the process, when stderr is
        // closed — with a raw Darwin.write that returns -1 on EBADF. So the oracle is that the CLI
        // exited on its own terms rather than dying from a signal.
        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertFalse(result.diedFromSignal, result.diagnostics)
        // 2 is the unknown-command exit and it is deterministic now the socket is pinned. Asserting
        // the exact code rather than merely non-zero keeps this from passing when the CLI fails for
        // some unrelated reason. Nothing is asserted about stdout: the message goes to stderr, which
        // this test deliberately closes.
        XCTAssertEqual(result.status, 2, result.diagnostics)
    }

    @Test func testAgentTeamsHelpDoesNotLaunchExternalAgentCLI() throws {
        let cliPath = try bundledCLIPath()
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["PATH"] = "/usr/bin:/bin"
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        // The CLI resolves its socket before it dispatches the command, so even a
        // `--help` run walks the candidate list — which means reading the machine-wide
        // marker file and connecting to any `cmux-debug-*.sock` it finds in /tmp. A
        // per-run path nothing listens on is not one of the implicit defaults, so the
        // CLI takes it as given and never goes looking.
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-agent-teams-help-\(UUID().uuidString.prefix(8)).sock"

        for command in ["claude-teams", "codex-teams"] {
            let result = runProcess(
                executablePath: cliPath,
                arguments: [command, "--help"],
                environment: environment
            )

            XCTAssertFalse(result.timedOut, result.diagnostics)
            XCTAssertEqual(result.status, 0, result.diagnostics)
            XCTAssertTrue(result.stdout.contains("Usage: cmux \(command)"), result.diagnostics)
            // The CLI reports a failed exec by throwing, and the top-level handler prints
            // that on stderr, so this has to read both streams. On one shared pipe it
            // used to cover either by accident.
            XCTAssertFalse(result.combinedOutput.contains("Failed to launch"), result.diagnostics)
        }
    }

    @Test func testBundledCLIInTaggedDebugAppPrefersItsOwnSocketWithoutEnvironmentOverride() throws {
        let cliPath = try bundledCLIPath()
        let tagSlug = "cli-socket-\(UUID().uuidString.lowercased())"
        let taggedSocketPath = "/tmp/cmux-debug-\(tagSlug).sock"
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let stableSocketURL = try stableSocketURL(home: home)

        // The CLI only accepts OK / OK … / PONG / ERROR: … / JSON as a complete single-line
        // reply. A bareword sends it into the multiline drain pass, where reconfiguring the
        // receive timeout on an already-closed socket fails with EINVAL and the CLI reports
        // "Invalid argument" instead of the reply it already has.
        let stableResponder = try UnixSocketResponder(path: stableSocketURL.path, response: "OK STABLE")
        defer { stableResponder.stop() }
        let taggedResponder = try UnixSocketResponder(path: taggedSocketPath, response: "OK TAGGED")
        defer { taggedResponder.stop() }

        let fakeCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: tagSlug
        )
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        // No CMUX_SOCKET_PATH on purpose: where the CLI lands with no override is the
        // whole subject. That stays inside the test because the tag slug is unique per
        // run, so the tagged default socket and the marker file the CLI consults are both
        // named after this run. CFFIXED_USER_HOME moves the stable socket into the temp
        // home (it overrides homeDirectoryForCurrentUser).
        environment["CFFIXED_USER_HOME"] = home.path

        let result = runProcess(
            executablePath: fakeCLIPath,
            arguments: ["ping"],
            environment: environment
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK TAGGED",
            result.diagnostics
        )
        // The point of this test: the tagged socket was chosen and the stable one was not. These
        // hold whatever framing the reply uses, so a future reply change cannot make it vacuous.
        XCTAssertEqual(taggedResponder.receivedRequests, ["ping"], result.diagnostics)
        XCTAssertEqual(stableResponder.receivedRequests, [], result.diagnostics)
    }

    @Test func testBundledCLIInTaggedDebugAppTreatsCaseVariantStableEnvSocketAsImplicitDefault() throws {
        let cliPath = try bundledCLIPath()
        let tagSlug = "cli-case-\(UUID().uuidString.lowercased())"
        let taggedSocketPath = "/tmp/cmux-debug-\(tagSlug).sock"
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let stableSocketURL = try stableSocketURL(home: home)
        let stableSocketPath = stableSocketURL.path
        let caseVariantStablePath = stableSocketURL
            .deletingLastPathComponent()
            .appendingPathComponent("CMUX.sock", isDirectory: false)
            .path

        let stableResponder = try UnixSocketResponder(path: stableSocketPath, response: "OK STABLE")
        defer { stableResponder.stop() }
        let taggedResponder = try UnixSocketResponder(path: taggedSocketPath, response: "PONG")
        defer { taggedResponder.stop() }

        let fakeCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: tagSlug
        )
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "5"
        // The env socket here is deliberately one of the stable implicit defaults, since
        // looking past it is what a tagged build has to do, so it cannot be pinned to a
        // per-run path. The temp home keeps that default inside the test.
        environment["CMUX_SOCKET_PATH"] = caseVariantStablePath
        environment["CFFIXED_USER_HOME"] = home.path

        let result = runProcess(
            executablePath: fakeCLIPath,
            arguments: ["ping"],
            environment: environment
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "PONG",
            result.diagnostics
        )
        XCTAssertEqual(stableResponder.receivedRequests, [], result.diagnostics)
    }

    @Test func testBundledCLIInTaggedDebugAppDoesNotFallBackToStableEnvSocketWhenTaggedSocketIsMissing() throws {
        let cliPath = try bundledCLIPath()
        let fixedHomeURL = URL(fileURLWithPath: "/tmp/cmxh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixedHomeURL) }
        let stableSocketURL = fixedHomeURL
            .appendingPathComponent(".local/state/cmux", isDirectory: true)
            .appendingPathComponent("cmux.sock", isDirectory: false)
        try FileManager.default.createDirectory(
            at: stableSocketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tagSlug = "cli-missing-\(UUID().uuidString.lowercased())"
        let taggedSocketPath = "/tmp/cmux-debug-\(tagSlug).sock"
        try? FileManager.default.removeItem(atPath: taggedSocketPath)
        defer { try? FileManager.default.removeItem(atPath: taggedSocketPath) }

        let stableResponder = try UnixSocketResponder(path: stableSocketURL.path, response: "OK STABLE")
        defer { stableResponder.stop() }

        let fakeCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: tagSlug
        )
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "0.1"
        // Another deliberate stable-default env socket: pinning it to a per-run path would
        // remove the fallback decision this test is about.
        environment["CMUX_SOCKET_PATH"] = stableSocketURL.path
        environment["CFFIXED_USER_HOME"] = fixedHomeURL.path

        let result = runProcess(
            executablePath: fakeCLIPath,
            arguments: ["ping"],
            environment: environment
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertNotEqual(result.status, 0, result.diagnostics)
        // The connect failure is thrown, and the top-level handler prints a thrown error
        // on stderr, so that is where the socket it gave up on is named.
        XCTAssertTrue(result.stderr.contains(taggedSocketPath), result.diagnostics)
        XCTAssertFalse(result.combinedOutput.contains("OK STABLE"), result.diagnostics)
        XCTAssertEqual(stableResponder.receivedRequests, [], result.diagnostics)
    }

    @Test func testBundledCLIInTaggedDebugAppTreatsUserScopedStableEnvSocketAsImplicitDefault() throws {
        let cliPath = try bundledCLIPath()
        let fixedHomeURL = URL(fileURLWithPath: "/tmp/cmux-cli-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixedHomeURL) }
        let stableSocketURL = fixedHomeURL
            .appendingPathComponent(".local/state/cmux", isDirectory: true)
            .appendingPathComponent("cmux-\(getuid()).sock", isDirectory: false)
        let stableSocketPath = stableSocketURL.path
        try FileManager.default.createDirectory(
            at: stableSocketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let aliases = [
            stableSocketPath,
            stableSocketURL
                .deletingLastPathComponent()
                .appendingPathComponent("CMUX-\(getuid()).sock", isDirectory: false)
                .path,
        ]

        for alias in aliases {
            try autoreleasepool {
                let tagSlug = "cli-user-\(UUID().uuidString.lowercased())"
                let taggedSocketPath = "/tmp/cmux-debug-\(tagSlug).sock"
                let stableResponder = try UnixSocketResponder(path: stableSocketPath, response: "OK STABLE")
                defer { stableResponder.stop() }
                let taggedResponder = try UnixSocketResponder(path: taggedSocketPath, response: "PONG")
                defer { taggedResponder.stop() }

                let fakeCLIPath = try fakeTaggedBundledCLIPath(
                    sourceCLIPath: cliPath,
                    tagSlug: tagSlug
                )
                var environment = ProcessInfo.processInfo.environment
                for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
                    environment.removeValue(forKey: key)
                }
                environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
                environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "5"
                // Each alias is a user-scoped stable default that a tagged build has to
                // look past, so the env socket stays as spelled rather than pinned.
                environment["CMUX_SOCKET_PATH"] = alias
                environment["CFFIXED_USER_HOME"] = fixedHomeURL.path

                let result = runProcess(
                    executablePath: fakeCLIPath,
                    arguments: ["ping"],
                    environment: environment
                )

                XCTAssertFalse(result.timedOut, result.diagnostics)
                XCTAssertEqual(result.status, 0, result.diagnostics)
                XCTAssertEqual(
                    result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                    "PONG",
                    result.diagnostics
                )
                XCTAssertEqual(stableResponder.receivedRequests, [], "\(alias)\n\(result.diagnostics)")
            }
        }
    }

    @Test func testBundledStableCLIPreservesLiveUserScopedStableEnvSocket() throws {
        let cliPath = try bundledCLIPath()
        let fixedHomeURL = URL(fileURLWithPath: "/tmp/cmxh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixedHomeURL) }
        let socketDirectoryURL = fixedHomeURL
            .appendingPathComponent(".local/state/cmux", isDirectory: true)
        try FileManager.default.createDirectory(
            at: socketDirectoryURL,
            withIntermediateDirectories: true
        )
        let defaultStableSocketPath = socketDirectoryURL
            .appendingPathComponent("cmux.sock", isDirectory: false)
            .path
        let userScopedStableSocketPath = socketDirectoryURL
            .appendingPathComponent("cmux-\(getuid()).sock", isDirectory: false)
            .path
        try writeStableSocketMarker(home: fixedHomeURL)

        let fakeStableCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: "stable-\(UUID().uuidString.lowercased())",
            bundleIdentifier: "com.cmuxterm.app",
            bundleName: "cmux"
        )
        let defaultResponder = try UnixSocketResponder(path: defaultStableSocketPath, response: "OK DEFAULT")
        defer { defaultResponder.stop() }
        let userScopedResponder = try UnixSocketResponder(path: userScopedStableSocketPath, response: "OK USER")
        defer { userScopedResponder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "5"
        // A stable implicit default on purpose: keeping this one rather than resolving on
        // to another candidate is the behavior under test, so it is not pinned.
        environment["CMUX_SOCKET_PATH"] = userScopedStableSocketPath
        environment["CFFIXED_USER_HOME"] = fixedHomeURL.path

        let result = runProcess(
            executablePath: fakeStableCLIPath,
            arguments: ["ping"],
            environment: environment
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK USER",
            result.diagnostics
        )
        XCTAssertEqual(defaultResponder.receivedRequests, [], result.diagnostics)
        XCTAssertEqual(
            userScopedResponder.receivedRequests.count,
            1,
            "\(userScopedResponder.receivedRequests.joined(separator: "\n"))\n\(result.diagnostics)"
        )
        XCTAssertTrue(
            userScopedResponder.receivedRequests.contains { $0.contains("ping") },
            "\(userScopedResponder.receivedRequests.joined(separator: "\n"))\n\(result.diagnostics)"
        )
    }

    @Test func testBundledStableCLIFallsBackFromStaleUserScopedStableEnvSocket() throws {
        let cliPath = try bundledCLIPath()
        let fixedHomeURL = URL(fileURLWithPath: "/tmp/cmxh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixedHomeURL) }
        let socketDirectoryURL = fixedHomeURL
            .appendingPathComponent(".local/state/cmux", isDirectory: true)
        try FileManager.default.createDirectory(
            at: socketDirectoryURL,
            withIntermediateDirectories: true
        )
        let defaultStableSocketPath = socketDirectoryURL
            .appendingPathComponent("cmux.sock", isDirectory: false)
            .path
        let userScopedStableSocketPath = socketDirectoryURL
            .appendingPathComponent("cmux-\(getuid()).sock", isDirectory: false)
            .path
        try writeStableSocketMarker(home: fixedHomeURL)

        let fakeStableCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: "stable-\(UUID().uuidString.lowercased())",
            bundleIdentifier: "com.cmuxterm.app",
            bundleName: "cmux"
        )
        let defaultResponder = try UnixSocketResponder(path: defaultStableSocketPath, response: "OK DEFAULT")
        defer { defaultResponder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "5"
        // Nothing listens on this stable default, and finding the next candidate is the
        // behavior under test, so the env socket stays as spelled.
        environment["CMUX_SOCKET_PATH"] = userScopedStableSocketPath
        environment["CFFIXED_USER_HOME"] = fixedHomeURL.path

        let result = runProcess(
            executablePath: fakeStableCLIPath,
            arguments: ["ping"],
            environment: environment
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK DEFAULT",
            result.diagnostics
        )
        XCTAssertEqual(
            defaultResponder.receivedRequests.count,
            1,
            "\(defaultResponder.receivedRequests.joined(separator: "\n"))\n\(result.diagnostics)"
        )
        XCTAssertTrue(
            defaultResponder.receivedRequests.contains { $0.contains("ping") },
            "\(defaultResponder.receivedRequests.joined(separator: "\n"))\n\(result.diagnostics)"
        )
    }

    /// A symlink standing where a stable socket belongs is not a socket, and the CLI has
    /// to resolve past it.
    ///
    /// The env socket is the user-scoped stable default inside this test's temp home. It
    /// used to be `/tmp/cmux.sock`, the release app's own socket path, which the responder
    /// unlinks before it binds — that takes the control socket away from a release app the
    /// developer is running. The early return that was supposed to prevent it both raced
    /// the app and, because it used `lstat` where the sibling test followed symlinks,
    /// disagreed with itself about what counts as present.
    @Test func testBundledStableCLIFallsBackFromSymlinkedStableEnvSocket() throws {
        let cliPath = try bundledCLIPath()
        let fixedHomeURL = URL(fileURLWithPath: "/tmp/cmxh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixedHomeURL) }
        let socketDirectoryURL = fixedHomeURL
            .appendingPathComponent(".local/state/cmux", isDirectory: true)
        try FileManager.default.createDirectory(
            at: socketDirectoryURL,
            withIntermediateDirectories: true
        )
        let defaultStableSocketPath = socketDirectoryURL
            .appendingPathComponent("cmux.sock", isDirectory: false)
            .path
        let symlinkedStableSocketPath = socketDirectoryURL
            .appendingPathComponent("cmux-\(getuid()).sock", isDirectory: false)
            .path
        let symlinkTargetSocketPath = "/tmp/cmux-symlink-target-\(UUID().uuidString).sock"
        try writeStableSocketMarker(home: fixedHomeURL)

        let fakeStableCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: "stable-\(UUID().uuidString.lowercased())",
            bundleIdentifier: "com.cmuxterm.app",
            bundleName: "cmux"
        )
        let defaultResponder = try UnixSocketResponder(path: defaultStableSocketPath, response: "OK DEFAULT")
        defer { defaultResponder.stop() }
        let targetResponder = try UnixSocketResponder(path: symlinkTargetSocketPath, response: "OK TARGET")
        defer { targetResponder.stop() }
        XCTAssertEqual(symlink(symlinkTargetSocketPath, symlinkedStableSocketPath), 0)

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "5"
        // The symlinked stable default is the input to the fallback under test, so it is
        // not pinned to a per-run path.
        environment["CMUX_SOCKET_PATH"] = symlinkedStableSocketPath
        environment["CFFIXED_USER_HOME"] = fixedHomeURL.path

        let result = runProcess(
            executablePath: fakeStableCLIPath,
            arguments: ["ping"],
            environment: environment
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK DEFAULT",
            result.diagnostics
        )
        XCTAssertEqual(
            defaultResponder.receivedRequests.count,
            1,
            "\(defaultResponder.receivedRequests.joined(separator: "\n"))\n\(result.diagnostics)"
        )
        XCTAssertTrue(
            defaultResponder.receivedRequests.contains { $0.contains("ping") },
            "\(defaultResponder.receivedRequests.joined(separator: "\n"))\n\(result.diagnostics)"
        )
        XCTAssertEqual(targetResponder.receivedRequests, [], result.diagnostics)
    }

    /// `/tmp/cmux.sock`, the release app's socket path, counts as a stable implicit
    /// default: a tagged build handed it in the environment still talks to its own socket.
    ///
    /// Nothing here creates, binds, or removes that path — a release app may be using it
    /// right now, and the responder unlinks whatever it finds before it binds. Only the
    /// classification needs testing, and that is readable from which responder saw the
    /// ping, with or without a release app running. The other half of the old test, that a
    /// live stable env socket is kept rather than resolved away, is covered under a temp
    /// home by ``testBundledStableCLIPreservesLiveUserScopedStableEnvSocket``.
    @Test func testBundledCLIInTaggedDebugAppTreatsLegacyStableEnvSocketAsImplicitDefault() throws {
        let cliPath = try bundledCLIPath()
        let tagSlug = "cli-legacy-\(UUID().uuidString.lowercased())"
        let taggedSocketPath = "/tmp/cmux-debug-\(tagSlug).sock"
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let stableSocketURL = try stableSocketURL(home: home)

        let stableResponder = try UnixSocketResponder(path: stableSocketURL.path, response: "OK STABLE")
        defer { stableResponder.stop() }
        let taggedResponder = try UnixSocketResponder(path: taggedSocketPath, response: "PONG")
        defer { taggedResponder.stop() }

        let fakeCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: tagSlug
        )
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "5"
        environment["CMUX_SOCKET_PATH"] = SocketControlSettings.legacyStableDefaultSocketPath
        environment["CFFIXED_USER_HOME"] = home.path

        let result = runProcess(
            executablePath: fakeCLIPath,
            arguments: ["ping"],
            environment: environment
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "PONG",
            result.diagnostics
        )
        XCTAssertEqual(taggedResponder.receivedRequests, ["ping"], result.diagnostics)
        XCTAssertEqual(stableResponder.receivedRequests, [], result.diagnostics)
    }

    @Test func testBundledCLISkipsIdentifierlessNestedAppWhenResolvingTaggedSocket() throws {
        let cliPath = try bundledCLIPath()
        let tagSlug = "cli-nested-\(UUID().uuidString.lowercased())"
        let taggedSocketPath = "/tmp/cmux-debug-\(tagSlug).sock"
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let stableSocketURL = try stableSocketURL(home: home)

        // The CLI only accepts OK / OK … / PONG / ERROR: … / JSON as a complete single-line
        // reply. A bareword sends it into the multiline drain pass, where reconfiguring the
        // receive timeout on an already-closed socket fails with EINVAL and the CLI reports
        // "Invalid argument" instead of the reply it already has.
        let stableResponder = try UnixSocketResponder(path: stableSocketURL.path, response: "OK STABLE")
        defer { stableResponder.stop() }
        let taggedResponder = try UnixSocketResponder(path: taggedSocketPath, response: "OK TAGGED")
        defer { taggedResponder.stop() }

        let fakeCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: tagSlug,
            nestedIdentifierlessApp: true
        )
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        // No CMUX_SOCKET_PATH again: resolution from the bundle layout is the subject. The
        // temp home and the unique tag slug keep that resolution inside the test.
        environment["CFFIXED_USER_HOME"] = home.path

        let result = runProcess(
            executablePath: fakeCLIPath,
            arguments: ["ping"],
            environment: environment
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK TAGGED",
            result.diagnostics
        )
        // The point of this test: the tagged socket was chosen and the stable one was not. These
        // hold whatever framing the reply uses, so a future reply change cannot make it vacuous.
        XCTAssertEqual(taggedResponder.receivedRequests, ["ping"], result.diagnostics)
        XCTAssertEqual(stableResponder.receivedRequests, [], result.diagnostics)
    }

    @Test func testThemesSetReloadsRunningAppAfterEveryThemeWrite() throws {
        let cliPath = try bundledCLIPath()
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-themes-socket-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let resourcesURL = root.appendingPathComponent("resources", isDirectory: true)
        let themesURL = resourcesURL.appendingPathComponent("themes", isDirectory: true)
        try fileManager.createDirectory(at: themesURL, withIntermediateDirectories: true)
        try writeTheme(named: "Theme A", background: "#101010", to: themesURL)
        try writeTheme(named: "Theme B", background: "#f8f8f8", to: themesURL)
        try writeTheme(named: "Theme C", background: "#003b49", to: themesURL)

        let socketPath = "/tmp/cmux-theme-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(path: socketPath, response: "OK")
        defer { responder.stop() }
        // The reload notification travels over DistributedNotificationCenter, which is
        // machine-wide, and the observer below filters only on the bundle identifier. With
        // a fixed identifier a second run of this test on the same machine fulfills this
        // run's expectation and appends to its list, so the identifier carries a per-run
        // suffix. The CLI takes the identifier from CMUX_BUNDLE_ID here because this
        // socket file name has no channel prefix to derive one from.
        let bundleIdentifier = "com.cmuxterm.app.debug.issue-4355-test."
            + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let reloadExpectation = expectation(description: "cmux themes set posts final reload notifications")
        reloadExpectation.expectedFulfillmentCount = 3
        let notificationQueue = OperationQueue()
        notificationQueue.maxConcurrentOperationCount = 1
        let notificationLock = NSLock()
        var observedReloads: [(bundleIdentifier: String?, phase: String?)] = []
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.cmuxterm.themes.reload-config"),
            object: nil,
            queue: notificationQueue
        ) { notification in
            let observedBundleIdentifier = notification.userInfo?["bundleIdentifier"] as? String
            guard observedBundleIdentifier == bundleIdentifier else { return }
            let observedPhase = notification.userInfo?["phase"] as? String
            notificationLock.lock()
            observedReloads.append((bundleIdentifier: observedBundleIdentifier, phase: observedPhase))
            notificationLock.unlock()
            reloadExpectation.fulfill()
        }
        defer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CFFIXED_USER_HOME"] = root.path
        environment["HOME"] = root.path
        environment["GHOSTTY_RESOURCES_DIR"] = resourcesURL.path
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_BUNDLE_ID"] = bundleIdentifier
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let configURL = root
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("config.ghostty", isDirectory: false)

        var observedThemeValues: [String] = []
        for themeName in ["Theme A", "Theme B", "Theme C"] {
            let result = runProcess(
                executablePath: cliPath,
                arguments: ["themes", "set", themeName],
                environment: environment
            )

            XCTAssertFalse(result.timedOut, result.diagnostics)
            XCTAssertEqual(result.status, 0, result.diagnostics)
            observedThemeValues.append(try managedThemeValue(in: configURL))
        }
        wait(for: [reloadExpectation], timeout: 5)

        XCTAssertEqual(observedThemeValues, [
            "light:Theme A,dark:Theme A",
            "light:Theme B,dark:Theme B",
            "light:Theme C,dark:Theme C",
        ])
        notificationLock.lock()
        let reloads = observedReloads
        notificationLock.unlock()
        XCTAssertEqual(reloads.map { $0.bundleIdentifier }, Array(repeating: bundleIdentifier, count: 3))
        XCTAssertEqual(reloads.map { $0.phase }, Array(repeating: "final", count: 3))
        XCTAssertEqual(responder.receivedRequests, [])
    }

    @Test func testThemesSetTargetsResolvedTaggedSocketWhenBundleEnvironmentIsStale() throws {
        let cliPath = try bundledCLIPath()
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-themes-stale-bundle-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let resourcesURL = root.appendingPathComponent("resources", isDirectory: true)
        let themesURL = resourcesURL.appendingPathComponent("themes", isDirectory: true)
        try fileManager.createDirectory(at: themesURL, withIntermediateDirectories: true)
        try writeTheme(named: "Theme A", background: "#101010", to: themesURL)

        // The reload target is derived from the socket file name, not from CMUX_BUNDLE_ID:
        // `cmux-debug-<slug>.sock` becomes `com.cmuxterm.app.debug.<slug>`, where every run of
        // non-alphanumerics in the slug collapses to a dot. A raw UUID here would put its dashes
        // into the identifier as dots, so keep the unique part hex-only and the expected
        // identifier stays a plain template rather than a call into the CLI's own helper.
        let uniqueSuffix = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let socketPath = "/tmp/cmux-debug-active-theme-\(uniqueSuffix).sock"
        let staleBundleIdentifier = "com.cmuxterm.app.debug.stale.theme"
        let targetBundleIdentifier = "com.cmuxterm.app.debug.active.theme.\(uniqueSuffix)"
        let reloadExpectation = expectation(description: "cmux themes set targets the resolved socket bundle")
        let notificationQueue = OperationQueue()
        notificationQueue.maxConcurrentOperationCount = 1
        let notificationLock = NSLock()
        var observedReloads: [(bundleIdentifier: String?, phase: String?, socketPath: String?)] = []
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.cmuxterm.themes.reload-config"),
            object: nil,
            queue: notificationQueue
        ) { notification in
            let observedBundleIdentifier = notification.userInfo?["bundleIdentifier"] as? String
            guard observedBundleIdentifier == targetBundleIdentifier else { return }
            let observedPhase = notification.userInfo?["phase"] as? String
            let observedSocketPath = notification.userInfo?["socketPath"] as? String
            notificationLock.lock()
            observedReloads.append((
                bundleIdentifier: observedBundleIdentifier,
                phase: observedPhase,
                socketPath: observedSocketPath
            ))
            notificationLock.unlock()
            reloadExpectation.fulfill()
        }
        defer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CFFIXED_USER_HOME"] = root.path
        environment["HOME"] = root.path
        environment["GHOSTTY_RESOURCES_DIR"] = resourcesURL.path
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_BUNDLE_ID"] = staleBundleIdentifier
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--json", "themes", "set", "Theme A"],
            environment: environment
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        wait(for: [reloadExpectation], timeout: 5)

        notificationLock.lock()
        let reloads = observedReloads
        notificationLock.unlock()
        XCTAssertEqual(reloads.map { $0.bundleIdentifier }, [targetBundleIdentifier])
        XCTAssertEqual(reloads.map { $0.phase }, ["final"])
        XCTAssertEqual(reloads.map { $0.socketPath }, [socketPath])
        // The stale identifier must not show up anywhere the CLI writes, which is why this
        // one reads both streams: the JSON payload is on stdout, and a leak through an
        // error message would land on stderr.
        XCTAssertFalse(result.combinedOutput.contains(staleBundleIdentifier), result.diagnostics)
        XCTAssertTrue(result.stdout.contains(targetBundleIdentifier), result.diagnostics)
    }

    @Test func testThemesSetNightlyOverridePathIsReadableByNightlyAppConfigResolution() throws {
        let cliPath = try bundledCLIPath()
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-themes-nightly-path-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let resourcesURL = root.appendingPathComponent("resources", isDirectory: true)
        let themesURL = resourcesURL.appendingPathComponent("themes", isDirectory: true)
        try fileManager.createDirectory(at: themesURL, withIntermediateDirectories: true)
        try writeTheme(named: "Theme A", background: "#101010", to: themesURL)

        // The reload target comes from the socket file name before CMUX_BUNDLE_ID is even
        // consulted: `cmux-nightly-<slug>.sock` becomes `com.cmuxterm.app.nightly.<slug>`.
        // So scoping the identifier means scoping the socket name it is read from, and both
        // take the same hex-only suffix — a raw UUID's dashes would turn into dots in the
        // identifier. Scoping matters because the reload goes out machine-wide: on the
        // plain nightly socket name this test told a real nightly build to re-read its
        // config, and two runs at once shared one identifier.
        let uniqueSuffix = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let socketPath = "/tmp/cmux-nightly-\(uniqueSuffix).sock"
        let bundleIdentifier = "com.cmuxterm.app.nightly.\(uniqueSuffix)"
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CFFIXED_USER_HOME"] = root.path
        environment["HOME"] = root.path
        environment["GHOSTTY_RESOURCES_DIR"] = resourcesURL.path
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_BUNDLE_ID"] = bundleIdentifier
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--json", "themes", "set", "Theme A"],
            environment: environment
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)

        // Parsed from stdout alone. This is the check that used to break when a stray
        // diagnostic line from the runtime shared the pipe with the payload.
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
            result.diagnostics
        )
        let configPath = try XCTUnwrap(payload["config_path"] as? String, result.diagnostics)
        XCTAssertEqual(payload["reload_target_bundle_id"] as? String, bundleIdentifier)

        let appSupportDirectory = root
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        let expectedConfigURL = appSupportDirectory
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("config.ghostty", isDirectory: false)
        XCTAssertEqual(configPath, expectedConfigURL.path)

        let appReadablePaths = GhosttyApp.cmuxAppSupportConfigURLs(
            currentBundleIdentifier: bundleIdentifier,
            appSupportDirectory: appSupportDirectory
        ).map(\.path)
        XCTAssertEqual(appReadablePaths, [expectedConfigURL.path])
    }

    @Test func testBareInteractiveThemesReloadsRunningAppAfterPickerExits() throws {
        let cliPath = try bundledCLIPath()
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-themes-picker-socket-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let fakeCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: "theme-picker-\(UUID().uuidString.lowercased())"
        )
        let fakeGhosttyHelperURL = URL(fileURLWithPath: fakeCLIPath)
            .deletingLastPathComponent()
            .appendingPathComponent("ghostty", isDirectory: false)
        try """
        #!/usr/bin/env python3
        import os
        import sys
        import time

        deadline = time.time() + 2.0
        last_error = ""
        while time.time() < deadline:
            try:
                if os.isatty(0) and os.tcgetpgrp(0) == os.getpgrp():
                    sys.exit(0)
                last_error = f"pgrp={os.getpgrp()} tpgid={os.tcgetpgrp(0)}"
            except OSError as error:
                last_error = str(error)
            time.sleep(0.02)

        sys.stderr.write(f"theme picker was not foregrounded: {last_error}\\n")
        sys.exit(42)
        """.write(to: fakeGhosttyHelperURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeGhosttyHelperURL.path
        )

        let socketPath = "/tmp/cmux-theme-picker-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(path: socketPath, response: "OK")
        defer { responder.stop() }
        let bundleIdentifier = "com.cmuxterm.app.debug.theme-picker.\(UUID().uuidString.lowercased())"
        let reloadExpectation = expectation(description: "bare cmux themes posts final reload notification")
        let notificationQueue = OperationQueue()
        notificationQueue.maxConcurrentOperationCount = 1
        let notificationLock = NSLock()
        var observedReloads: [(bundleIdentifier: String?, phase: String?)] = []
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.cmuxterm.themes.reload-config"),
            object: nil,
            queue: notificationQueue
        ) { notification in
            let observedBundleIdentifier = notification.userInfo?["bundleIdentifier"] as? String
            guard observedBundleIdentifier == bundleIdentifier else { return }
            let observedPhase = notification.userInfo?["phase"] as? String
            notificationLock.lock()
            observedReloads.append((bundleIdentifier: observedBundleIdentifier, phase: observedPhase))
            notificationLock.unlock()
            reloadExpectation.fulfill()
        }
        defer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }

        let command = [
            "env",
            "-i",
            "HOME=\(shellSingleQuote(root.path))",
            "CFFIXED_USER_HOME=\(shellSingleQuote(root.path))",
            "CMUX_SOCKET_PATH=\(shellSingleQuote(socketPath))",
            "CMUX_BUNDLE_ID=\(shellSingleQuote(bundleIdentifier))",
            "CMUX_CLI_SENTRY_DISABLED=1",
            "PATH=/usr/bin:/bin",
            "/usr/bin/script",
            "-q",
            "/dev/null",
            shellSingleQuote(fakeCLIPath),
            "themes",
        ].joined(separator: " ")
        // `env -i` builds the CLI's environment from scratch, so the shell needs only a
        // PATH of its own to find `env` — and nothing the test host was launched with
        // reaches the CLI.
        let result = runShell(command, environment: ["PATH": "/usr/bin:/bin"])

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        wait(for: [reloadExpectation], timeout: 5)
        notificationLock.lock()
        let reloads = observedReloads
        notificationLock.unlock()
        XCTAssertEqual(reloads.map { $0.bundleIdentifier }, [bundleIdentifier])
        XCTAssertEqual(reloads.map { $0.phase }, ["final"])
        XCTAssertEqual(responder.receivedRequests, [], result.diagnostics)
    }

    @Test func testBareInteractiveThemesTreatsSigintAsSilentCancel() throws {
        let cliPath = try bundledCLIPath()
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-themes-picker-cancel-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let fakeCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: "theme-picker-cancel-\(UUID().uuidString.lowercased())"
        )
        let fakeGhosttyHelperURL = URL(fileURLWithPath: fakeCLIPath)
            .deletingLastPathComponent()
            .appendingPathComponent("ghostty", isDirectory: false)
        try """
        #!/usr/bin/env python3
        import os
        import signal
        import sys
        import time

        deadline = time.time() + 2.0
        while time.time() < deadline:
            if os.isatty(0) and os.tcgetpgrp(0) == os.getpgrp():
                signal.signal(signal.SIGINT, signal.SIG_DFL)
                os.kill(os.getpid(), signal.SIGINT)
            time.sleep(0.02)
        sys.exit(42)
        """.write(to: fakeGhosttyHelperURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeGhosttyHelperURL.path
        )

        let socketPath = "/tmp/cmux-theme-picker-cancel-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(path: socketPath, response: "OK")
        defer { responder.stop() }

        let command = [
            "env",
            "-i",
            "HOME=\(shellSingleQuote(root.path))",
            "CFFIXED_USER_HOME=\(shellSingleQuote(root.path))",
            "CMUX_SOCKET_PATH=\(shellSingleQuote(socketPath))",
            "CMUX_CLI_SENTRY_DISABLED=1",
            "PATH=/usr/bin:/bin",
            "/usr/bin/script",
            "-q",
            "/dev/null",
            shellSingleQuote(fakeCLIPath),
            "themes",
        ].joined(separator: " ")
        let result = runShell(command, environment: ["PATH": "/usr/bin:/bin"])

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        // `script` hands the CLI a pty for both streams, so a cancel notice arrives on
        // stdout today. Reading both keeps this from going quiet if that changes — the
        // notice is a thrown error, and thrown errors print on stderr.
        XCTAssertFalse(
            result.combinedOutput.contains("Interactive theme picker exited"),
            result.diagnostics
        )
        XCTAssertEqual(responder.receivedRequests, [], result.diagnostics)
    }

    @Test func testBrowserDownloadWaitUsesRequestedTimeoutForSocketResponse() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = "/tmp/cmux-dw-\(UUID().uuidString.prefix(8)).sock"
        let response = #"{"ok":true,"result":{"downloaded":true}}"#
        let responder = try UnixSocketResponder(path: socketPath, response: response, responseDelay: 0.4)
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "0.1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "browser",
                UUID().uuidString,
                "download",
                "wait",
                "--timeout-ms",
                "1000",
            ],
            environment: environment,
            // A deliberate cap, not a hang guard: the responder answers after 0.4s and the
            // request asks for 1000ms, so this run has to finish well inside 3s. Raising it
            // to the suite default would let a CLI that ignored --timeout-ms still pass.
            timeout: 3
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK",
            result.diagnostics
        )
    }

    @Test func testBrowserDownloadWaitDefaultTimeoutMatchesServerDefaultWindow() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = "/tmp/cmux-dw-\(UUID().uuidString.prefix(8)).sock"
        let response = #"{"ok":true,"result":{"downloaded":true}}"#
        let responder = try UnixSocketResponder(path: socketPath, response: response, responseDelay: 10.5)
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "0.1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "browser",
                UUID().uuidString,
                "download",
                "wait",
            ],
            environment: environment,
            // A deliberate cap, and the only upper bound that gives this test meaning: the
            // responder answers after 10.5s, so waiting the server's default window has to
            // land between there and 16s. Under the suite default a CLI that waited a full
            // minute would still pass, and "matches the server default window" would stop
            // being a claim about anything.
            timeout: 16
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK",
            result.diagnostics
        )
    }

    @Test func testDotPathOpenBypassesProtectedSocketForExternalCLI() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-external-open-\(UUID().uuidString)", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeOpenURL = root.appendingPathComponent("open", isDirectory: false)
        let openLogURL = root.appendingPathComponent("open-args.txt", isDirectory: false)
        let openEnvLogURL = root.appendingPathComponent("open-env.txt", isDirectory: false)
        try fakeOpenScript().write(to: fakeOpenURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpenURL.path)

        let socketPath = "/tmp/cmux-external-open-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            response: "ERROR: Access denied — only processes started inside cmux can connect"
        )
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_SOCKET"] = "/tmp/cmux-stale-\(UUID().uuidString.prefix(8)).sock"
        environment["CMUX_SOCKET_PASSWORD"] = "stale-password"
        environment["CMUX_SOCKET_ENABLE"] = "0"
        environment["CMUX_SOCKET_MODE"] = "off"
        environment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        environment["CMUX_WORKSPACE_ID"] = "workspace:stale"
        environment["CMUX_PANEL_ID"] = "panel:stale"
        environment["CMUX_SURFACE_ID"] = "surface:stale"
        environment["CMUX_TAB_ID"] = "tab:stale"
        environment["CMUX_TAG"] = "keepme"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_TEST_OPEN_TOOL_PATH"] = fakeOpenURL.path
        environment["CMUX_TEST_OPEN_LOG"] = openLogURL.path
        environment["CMUX_TEST_OPEN_ENV_LOG"] = openEnvLogURL.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["."],
            environment: environment,
            currentDirectoryURL: workingDirectory
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK",
            result.diagnostics
        )
        XCTAssertEqual(responder.receivedRequests, [], result.diagnostics)

        let openArguments = try readFakeOpenArguments(from: openLogURL)
        XCTAssertEqual(openArguments.first, "-a")
        XCTAssertEqual(openArguments.last, workingDirectory.standardizedFileURL.path)
        XCTAssertTrue(openArguments.dropFirst().first?.hasSuffix(".app") == true, openArguments.joined(separator: " "))

        let openEnvironment = try readFakeOpenEnvironment(from: openEnvLogURL)
        for strippedKey in [
            "CMUX_ALLOW_SOCKET_OVERRIDE",
            "CMUX_SOCKET",
            "CMUX_SOCKET_ENABLE",
            "CMUX_SOCKET_MODE",
            "CMUX_SOCKET_PASSWORD",
            "CMUX_SOCKET_PATH",
            "CMUX_PANEL_ID",
            "CMUX_SURFACE_ID",
            "CMUX_TAB_ID",
            "CMUX_WORKSPACE_ID",
        ] {
            XCTAssertFalse(
                openEnvironment.contains { $0.hasPrefix("\(strippedKey)=") },
                "\(strippedKey) leaked to LaunchServices open environment: \(openEnvironment)"
            )
        }
        XCTAssertTrue(openEnvironment.contains("CMUX_TAG=keepme"), openEnvironment.joined(separator: "\n"))
    }

    @Test func testBareRelativeDirectoryPathOpenBypassesProtectedSocketForExternalCLI() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-bare-open-\(UUID().uuidString)", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeOpenURL = root.appendingPathComponent("open", isDirectory: false)
        let openLogURL = root.appendingPathComponent("open-args.txt", isDirectory: false)
        try fakeOpenScript().write(to: fakeOpenURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpenURL.path)

        let socketPath = "/tmp/cmux-bare-open-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            response: "ERROR: Access denied — only processes started inside cmux can connect"
        )
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_TEST_OPEN_TOOL_PATH"] = fakeOpenURL.path
        environment["CMUX_TEST_OPEN_LOG"] = openLogURL.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["project"],
            environment: environment,
            currentDirectoryURL: root
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK",
            result.diagnostics
        )
        XCTAssertEqual(responder.receivedRequests, [], result.diagnostics)

        let openArguments = try readFakeOpenArguments(from: openLogURL)
        XCTAssertEqual(openArguments.last, workingDirectory.standardizedFileURL.path)
    }

    @Test func testKnownCommandStillUsesSocketWhenMatchingBareRelativePathExists() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-command-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("ping", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeOpenURL = root.appendingPathComponent("open", isDirectory: false)
        let openLogURL = root.appendingPathComponent("open-args.txt", isDirectory: false)
        try fakeOpenScript().write(to: fakeOpenURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpenURL.path)

        let socketPath = "/tmp/cmux-command-path-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(path: socketPath, response: "PONG")
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_TEST_OPEN_TOOL_PATH"] = fakeOpenURL.path
        environment["CMUX_TEST_OPEN_LOG"] = openLogURL.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["ping"],
            environment: environment,
            currentDirectoryURL: root
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "PONG",
            result.diagnostics
        )
        XCTAssertEqual(responder.receivedRequests, ["ping"], result.diagnostics)
        XCTAssertFalse(FileManager.default.fileExists(atPath: openLogURL.path), result.diagnostics)
    }

    @Test func testCaseVariantBareRelativeDirectoryPathOpenBypassesProtectedSocket() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-case-path-\(UUID().uuidString)", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("Docs", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeOpenURL = root.appendingPathComponent("open", isDirectory: false)
        let openLogURL = root.appendingPathComponent("open-args.txt", isDirectory: false)
        try fakeOpenScript().write(to: fakeOpenURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpenURL.path)

        let socketPath = "/tmp/cmux-case-open-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            response: "ERROR: Access denied — only processes started inside cmux can connect"
        )
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_TEST_OPEN_TOOL_PATH"] = fakeOpenURL.path
        environment["CMUX_TEST_OPEN_LOG"] = openLogURL.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["Docs"],
            environment: environment,
            currentDirectoryURL: root
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK",
            result.diagnostics
        )
        XCTAssertEqual(responder.receivedRequests, [], result.diagnostics)

        let openArguments = try readFakeOpenArguments(from: openLogURL)
        XCTAssertEqual(openArguments.last, workingDirectory.standardizedFileURL.path)
    }

    @Test func testExplicitSocketPathOpenUsesRequestedSocket() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-explicit-open-\(UUID().uuidString)", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeOpenURL = root.appendingPathComponent("open", isDirectory: false)
        let openLogURL = root.appendingPathComponent("open-args.txt", isDirectory: false)
        try fakeOpenScript().write(to: fakeOpenURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpenURL.path)

        let socketPath = "/tmp/cmux-explicit-open-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            response: #"{"ok":true,"result":{"workspace_ref":"workspace:explicit"}}"#
        )
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_TEST_OPEN_TOOL_PATH"] = fakeOpenURL.path
        environment["CMUX_TEST_OPEN_LOG"] = openLogURL.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--socket", socketPath, "."],
            environment: environment,
            currentDirectoryURL: workingDirectory
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK workspace:explicit",
            result.diagnostics
        )

        let request = try XCTUnwrap(responder.receivedRequests.first)
        let requestData = try XCTUnwrap(request.data(using: .utf8))
        let requestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requestData, options: []) as? [String: Any]
        )
        XCTAssertEqual(requestObject["method"] as? String, "workspace.create")
        let params = try XCTUnwrap(requestObject["params"] as? [String: Any])
        XCTAssertEqual(params["cwd"] as? String, workingDirectory.standardizedFileURL.path)

        let openArguments = try readFakeOpenArguments(from: openLogURL)
        XCTAssertFalse(openArguments.contains(workingDirectory.standardizedFileURL.path), openArguments.joined(separator: " "))
    }

    func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
    }

    /// A throwaway home directory for hermetic CLI socket-resolution tests.
    ///
    /// The CLI resolves its stable socket under `homeDirectoryForCurrentUser`,
    /// which honors `CFFIXED_USER_HOME`. Tests build the socket path from this home
    /// via the canonical ``CmuxStateDirectory`` and pass the same home to the
    /// spawned CLI via `CFFIXED_USER_HOME`, so they never touch (or bind over) the
    /// developer's real `~/.local/state/cmux` (issue #5146).
    private func makeTemporaryHome() throws -> URL {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        let home = URL(fileURLWithPath: "/tmp/cmxh-\(shortID)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// The stable control-socket path under an injected (temp) home, resolved via
    /// the canonical ``CmuxStateDirectory`` so the test exercises the real layout.
    private func stableSocketURL(home: URL) throws -> URL {
        let directory = CmuxStateDirectory.url(homeDirectory: home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("cmux.sock", isDirectory: false)
    }

    /// Points the stable last-socket-path marker inside `home` at a path of the test's own.
    ///
    /// `CFFIXED_USER_HOME` moves the socket directory but not socket discovery: the CLI
    /// reads the first marker file it can open, and the second candidate is the
    /// machine-wide `/tmp/cmux-last-socket-path`, which on a developer's machine names the
    /// socket of the cmux they are running. Writing the per-home marker keeps the candidate
    /// list inside the test even when the test's own default socket is missing. The path
    /// written is deliberately one that does not exist, so it can never be connected to.
    private func writeStableSocketMarker(home: URL) throws {
        let directory = CmuxStateDirectory.url(homeDirectory: home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let markerURL = directory.appendingPathComponent(
            SocketPathMarkerFiles.stableMarkerFileName,
            isDirectory: false
        )
        try "/tmp/cmux-marker-\(UUID().uuidString.prefix(8)).sock\n"
            .write(to: markerURL, atomically: true, encoding: .utf8)
    }

    private func writeTheme(named name: String, background: String, to directory: URL) throws {
        try """
        background = \(background)
        foreground = #eeeeee
        cursor-color = #ff00ff
        cursor-text = #000000
        """.write(
            to: directory.appendingPathComponent(name, isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }

    private func managedThemeValue(in configURL: URL) throws -> String {
        let contents = try String(contentsOf: configURL, encoding: .utf8)
        let values = contents.components(separatedBy: .newlines).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "theme" else {
                return nil
            }
            return parts[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return try XCTUnwrap(values.last)
    }

    private func fakeTaggedBundledCLIPath(
        sourceCLIPath: String,
        tagSlug: String,
        bundleIdentifier: String? = nil,
        bundleName: String? = nil,
        nestedIdentifierlessApp: Bool = false
    ) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-socket-\(UUID().uuidString)", isDirectory: true)
        let appURL = root.appendingPathComponent("cmux DEV \(tagSlug).app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let binURL: URL
        if nestedIdentifierlessApp {
            let nestedContentsURL = contentsURL
                .appendingPathComponent("Resources/NestedTool.app/Contents", isDirectory: true)
            binURL = nestedContentsURL.appendingPathComponent("Resources/bin", isDirectory: true)
            let nestedInfoData = try PropertyListSerialization.data(
                fromPropertyList: [
                    "CFBundleName": "NestedTool",
                    "CFBundlePackageType": "APPL"
                ],
                format: .xml,
                options: 0
            )
            try FileManager.default.createDirectory(
                at: nestedContentsURL,
                withIntermediateDirectories: true
            )
            try nestedInfoData.write(to: nestedContentsURL.appendingPathComponent("Info.plist", isDirectory: false))
        } else {
            binURL = contentsURL.appendingPathComponent("Resources/bin", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier ?? "com.cmuxterm.app.debug.\(tagSlug.replacingOccurrences(of: "-", with: "."))",
            "CFBundleName": bundleName ?? "cmux DEV \(tagSlug)",
            "CFBundlePackageType": "APPL"
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist", isDirectory: false))

        let fakeCLIURL = binURL.appendingPathComponent("cmux", isDirectory: false)
        try FileManager.default.copyItem(atPath: sourceCLIPath, toPath: fakeCLIURL.path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeCLIURL.path
        )
        return fakeCLIURL.path
    }

    private func shellSingleQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    /// Runs a shell command with its environment spelled out.
    ///
    /// The environment is a required parameter. A child that inherits the test host's
    /// environment also inherits whatever `CMUX_*` variables the host was launched with,
    /// and that is one of the ways a spawned CLI ends up talking to the cmux the
    /// developer is actually running.
    private func runShell(
        _ command: String,
        environment: [String: String],
        timeout: TimeInterval? = nil
    ) -> ProcessRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        return runToCompletion(process, timeout: timeout)
    }

    func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL? = nil,
        timeout: TimeInterval? = nil
    ) -> ProcessRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL
        return runToCompletion(process, timeout: timeout)
    }

    /// Runs `process` to completion, capturing stdout and stderr on separate pipes.
    ///
    /// Both readers start before the wait. Calling `readDataToEndOfFile()` only after
    /// `waitUntilExit()` returns deadlocks as soon as the child fills a pipe buffer, and
    /// that deadlock is indistinguishable from a hang inside the CLI.
    ///
    /// - Parameter timeout: This run's deadline. A test that asserts how long the CLI
    ///   waits passes its own; everything else takes ``CMUXCLITestHangGuard/seconds``.
    private func runToCompletion(
        _ process: Process,
        timeout: TimeInterval? = nil
    ) -> ProcessRunResult {
        let budget = timeout ?? CMUXCLITestHangGuard.seconds
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            // Five sibling suites share this runner and print only `stdout` when they
            // fail, so a launch failure has to reach stdout as well or those tests
            // report an empty message.
            let message = "test runner could not spawn "
                + "\(process.executableURL?.path ?? "<none>"): \(error)"
            return ProcessRunResult(status: -1, stdout: message, stderr: message, timedOut: false)
        }

        let stdoutDrain = PipeDrain(stdoutPipe.fileHandleForReading)
        let stderrDrain = PipeDrain(stderrPipe.fileHandleForReading)

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + budget) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut,
               process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 1)
            }
        }

        // The child is gone by now, so its ends of both pipes are closed and each reader
        // sees EOF. The ceiling covers a grandchild that inherited a write end and
        // outlived its parent: report what was read rather than block the suite on it.
        let stdoutText = stdoutDrain.text(waitingUpTo: 5)
        let stderrText = stderrDrain.text(waitingUpTo: 5)

        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: stdoutText,
            stderr: stderrText,
            timedOut: timedOut,
            terminationReason: process.terminationReason
        )
    }

    /// Reads one pipe on a background queue so a child writing more than a pipe buffer
    /// never blocks while the test is waiting for it to exit.
    private final class PipeDrain: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let finished = DispatchSemaphore(value: 0)

        init(_ handle: FileHandle) {
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                store(handle.readDataToEndOfFile())
            }
        }

        private func store(_ read: Data) {
            lock.lock()
            data = read
            lock.unlock()
            finished.signal()
        }

        func text(waitingUpTo timeout: TimeInterval) -> String {
            _ = finished.wait(timeout: .now() + timeout)
            lock.lock()
            defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    private func fakeOpenScript() -> String {
        """
        #!/bin/sh
        : "${CMUX_TEST_OPEN_LOG:?}"
        : > "$CMUX_TEST_OPEN_LOG"
        printf 'fake open stdout should be suppressed\\n'
        printf 'fake open stderr should be suppressed\\n' >&2
        if [ -n "${CMUX_TEST_OPEN_ENV_LOG:-}" ]; then
          env | LC_ALL=C sort | grep '^CMUX_' > "$CMUX_TEST_OPEN_ENV_LOG" || :
        fi
        for arg in "$@"; do
          printf '%s\\n' "$arg" >> "$CMUX_TEST_OPEN_LOG"
        done
        exit 0
        """
    }

    private func readFakeOpenArguments(from url: URL) throws -> [String] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return Array(contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .dropLast())
    }

    private func readFakeOpenEnvironment(from url: URL) throws -> [String] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return Array(contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .dropLast())
    }
}

final class UnixSocketResponder {
    let path: String
    private let response: String
    private let responseDelay: TimeInterval
    private let queue = DispatchQueue(label: "com.cmux.tests.unix-socket-responder")
    private let lock = NSLock()
    private var stopped = false
    private var requests: [String] = []
    private var listenerFD: Int32 = -1

    init(path: String, response: String, responseDelay: TimeInterval = 0) throws {
        self.path = path
        self.response = response
        self.responseDelay = responseDelay

        unlink(path)
        listenerFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerFD >= 0 else {
            throw Self.posixError("socket")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxLength else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENAMETOOLONG),
                userInfo: [NSLocalizedDescriptionKey: "Unix socket path is too long: \(path)"]
            )
        }
        path.withCString { pointer in
            withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
                let buffer = UnsafeMutableRawPointer(tuplePointer).assumingMemoryBound(to: CChar.self)
                strncpy(buffer, pointer, maxLength - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.bind(listenerFD, socketPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let error = Self.posixError("bind")
            close(listenerFD)
            listenerFD = -1
            throw error
        }
        guard listen(listenerFD, 8) == 0 else {
            let error = Self.posixError("listen")
            close(listenerFD)
            listenerFD = -1
            throw error
        }

        let fd = listenerFD
        queue.async { [weak self] in
            self?.acceptLoop(listenerFD: fd)
        }
    }

    deinit {
        stop()
    }

    var receivedRequests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let fd = listenerFD
        listenerFD = -1
        lock.unlock()

        if fd >= 0 {
            close(fd)
        }
        unlink(path)
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func acceptLoop(listenerFD: Int32) {
        while !isStopped {
            let clientFD = accept(listenerFD, nil, nil)
            if clientFD < 0 {
                if isStopped {
                    return
                }
                continue
            }
            handle(clientFD: clientFD)
        }
    }

    private func handle(clientFD: Int32) {
        defer { close(clientFD) }
        var request = Data()
        while true {
            var byte: UInt8 = 0
            let count = read(clientFD, &byte, 1)
            if count <= 0 {
                return
            }
            request.append(byte)
            if byte == 0x0A {
                break
            }
        }
        guard !request.isEmpty else {
            return
        }
        if let line = String(data: request, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) {
            lock.lock()
            requests.append(line)
            lock.unlock()
        }
        if responseDelay > 0 {
            Thread.sleep(forTimeInterval: responseDelay)
        }
        let payload = response + "\n"
        payload.withCString { pointer in
            _ = write(clientFD, pointer, strlen(pointer))
        }
    }

    private static func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))"]
        )
    }
}
