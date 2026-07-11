import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for the remote-tmux SSH auth path that backs `cmux ssh-tmux`:
/// the stderr → "needs interactive auth" classifier, the ControlMaster host-key
/// policy baked into the standard control args, and the interactive auth `ssh`
/// argv the CLI runs in the user's terminal to open the shared master. These
/// assert produced values and decisions, never source text.
@Suite struct RemoteTmuxAuthTests {

    // MARK: - Auth-required classification

    @Test(arguments: [
        "Permission denied (publickey,password).",
        "user@host: Permission denied (publickey,keyboard-interactive).",
        "Host key verification failed.",
        "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@",
        "Authentication failed.",
        "Too many authentication failures",
    ])
    func classifiesInteractiveAuthFailures(_ stderr: String) {
        #expect(RemoteTmuxSSHTransport.indicatesAuthRequired(stderr))
    }

    @Test(arguments: [
        "no server running on /tmp/tmux-501/default",
        "no sessions",
        "error connecting to /tmp/tmux-501/default (No such file or directory)",
        // Algorithm-negotiation failure: an interactive retry can't fix it, so it
        // must NOT route to auth (surfaces as a normal error instead).
        "no matching host key type found. their offer: ssh-rsa",
        // A success-time banner that merely mentions keyboard-interactive must not
        // be mistaken for an auth failure (the bare substring was dropped).
        "this server offers password and keyboard-interactive methods",
        "",
        "some unrelated failure",
    ])
    func doesNotClassifyNonAuthFailures(_ stderr: String) {
        #expect(!RemoteTmuxSSHTransport.indicatesAuthRequired(stderr))
    }

    @Test func noServerIsNotTreatedAsAuthRequired() {
        // A reachable host whose tmux server just isn't running must be treated as
        // zero sessions, never as an auth prompt — otherwise attaching would pop an
        // interactive ssh instead of offering to create a session.
        let stderr = "no server running on /tmp/tmux-501/default"
        #expect(RemoteTmuxSSHTransport.indicatesNoServer(stderr))
        #expect(!RemoteTmuxSSHTransport.indicatesAuthRequired(stderr))

        let socketMissing = "error connecting to /tmp/tmux-501/default (No such file or directory)"
        #expect(RemoteTmuxSSHTransport.indicatesNoServer(socketMissing))
        #expect(!RemoteTmuxSSHTransport.indicatesAuthRequired(socketMissing))
    }

    @Test func staleSSHAgentErrorDoesNotMaskPermissionDeniedAuthRequirement() {
        let stderr = """
        Error connecting to agent: No such file or directory
        user@host: Permission denied (publickey,password).
        """
        #expect(!RemoteTmuxSSHTransport.indicatesNoServer(stderr))
        #expect(RemoteTmuxSSHTransport.indicatesAuthRequired(stderr))
    }

    @Test(arguments: [
        "command refresh-client: unknown flag -B",
        "refresh-client: unknown option -- B",
        "refresh-client: invalid option -- B",
        "refresh-client: illegal option -- B",
    ])
    func classifiesUnsupportedRefreshClientSubscriptionProbe(_ stderr: String) {
        #expect(RemoteTmuxSSHTransport.indicatesRefreshClientSubscriptionUnsupported(stderr))
        #expect(!RemoteTmuxSSHTransport.indicatesRefreshClientNeedsCurrentClient(stderr))
    }

    @Test(arguments: [
        "refresh-client: unknown option while building command",
        "refresh-client: unknown option btree",
        "refresh-client: invalid option because backend returned an error",
    ])
    func doesNotClassifyUnrelatedBWordsAsUnsupportedRefreshClientSubscriptionProbe(_ stderr: String) {
        #expect(!RemoteTmuxSSHTransport.indicatesRefreshClientSubscriptionUnsupported(stderr))
        #expect(!RemoteTmuxSSHTransport.indicatesRefreshClientNeedsCurrentClient(stderr))
    }

    @Test(arguments: [
        "no current client",
        "not a control client",
        "refresh-client: not a client",
    ])
    func classifiesRecognizedRefreshClientSubscriptionProbeWithoutClient(_ stderr: String) {
        #expect(!RemoteTmuxSSHTransport.indicatesRefreshClientSubscriptionUnsupported(stderr))
        #expect(RemoteTmuxSSHTransport.indicatesRefreshClientNeedsCurrentClient(stderr))
    }

    // MARK: - Host-key policy in the standard control args

    @Test func nonInteractiveControlArgsDoNotPinHostKeyPolicy() {
        // The mirror's batch path must NOT force StrictHostKeyChecking — it honors
        // the user's ~/.ssh/config, and an unknown host key fails BatchMode (which
        // routes to interactive auth) rather than being silently trusted.
        let host = RemoteTmuxHost(destination: "user@host")
        let args = host.sshControlArguments(controlPersistSeconds: 180, batchMode: true)
        #expect(!args.contains(where: { $0.hasPrefix("StrictHostKeyChecking=") }))
        #expect(consecutive(args, "-o", "BatchMode=yes"))
        #expect(consecutive(args, "-o", "ControlPath=\(host.controlSocketPath)"))
    }

    @Test func nonBatchControlArgsOmitBatchMode() {
        let host = RemoteTmuxHost(destination: "user@host")
        let args = host.sshControlArguments(controlPersistSeconds: 180, batchMode: false)
        #expect(!args.contains("BatchMode=yes"))
    }

    @Test func controlModeArgumentsAreNonInteractive() {
        let host = RemoteTmuxHost(destination: "user@host")
        let args = host.controlModeArguments(sessionName: "work", createIfMissing: false)
        #expect(consecutive(args, "-o", "BatchMode=yes"))
        #expect(!args.contains("BatchMode=no"))
    }

    @Test func controlModeArgumentsFindUserLocalTmuxWithMinimalSSHPath() throws {
        let root = try temporaryDirectory(prefix: "remote-tmux-path")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
        let emptyPath = root.appendingPathComponent("empty-path", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: emptyPath, withIntermediateDirectories: true)
        let fakeTmux = bin.appendingPathComponent("tmux")
        try writeExecutable(
            at: fakeTmux,
            contents: """
            #!/bin/sh
            printf 'fake-tmux'
            for arg in "$@"; do printf ' <%s>' "$arg"; done
            printf '\\n'
            """
        )

        let host = RemoteTmuxHost(destination: "user@example.test")
        let args = host.controlModeArguments(sessionName: "work session", createIfMissing: false)
        let dashDash = try #require(args.firstIndex(of: "--"))
        let command = args[dashDash + 2]
        let result = try runShell(
            command,
            environment: [
                "HOME": home.path,
                "PATH": emptyPath.path,
            ]
        )

        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "fake-tmux <-CC> <attach-session> <-t> <work session>\n")
    }

    @Test func controlModeArgumentsUseRemoteTmuxResolverAfterDestinationGuard() throws {
        let host = RemoteTmuxHost(destination: "-oProxyCommand=evil")
        let args = host.controlModeArguments(sessionName: "work session", createIfMissing: false)
        let dashDash = try #require(args.firstIndex(of: "--"))
        #expect(args[dashDash + 1] == "-oProxyCommand=evil")
        let remoteCommand = args[dashDash + 2]
        #expect(!remoteCommand.contains("\n"))
        #expect(remoteCommand.contains("/opt/homebrew/bin"))
        #expect(remoteCommand.hasSuffix("'cmux-remote-tmux' '-CC' 'attach-session' '-t' 'work session'"))
    }

    @Test func controlArgsAppendPortAndIdentity() {
        let host = RemoteTmuxHost(destination: "user@host", port: 2222, identityFile: "/keys/id")
        let args = host.sshControlArguments(controlPersistSeconds: 180, batchMode: true)
        #expect(consecutive(args, "-p", "2222"))
        #expect(consecutive(args, "-i", "/keys/id"))
    }

    @Test func connectionHashVariesByPortAndIdentity() {
        // The controller keys transports / connections / windows / persistence by
        // connectionHash, so distinct endpoints must produce distinct hashes (and
        // the same endpoint a stable one) — otherwise a command could be routed to
        // the wrong server through a shared transport/master.
        let base = RemoteTmuxHost(destination: "user@host")
        #expect(base.connectionHash == RemoteTmuxHost(destination: "user@host").connectionHash)
        #expect(base.connectionHash != RemoteTmuxHost(destination: "user@host", port: 2222).connectionHash)
        #expect(base.connectionHash != RemoteTmuxHost(destination: "user@host", identityFile: "/keys/id").connectionHash)
        #expect(
            RemoteTmuxHost(destination: "user@host", port: 2222).connectionHash
                != RemoteTmuxHost(destination: "user@host", identityFile: "/keys/id").connectionHash
        )
    }

    @Test func controlSocketPathVariesByPortAndIdentity() {
        // Distinct endpoints (same destination, different port/identity) must NOT
        // share a ControlMaster socket — otherwise a destructive command could
        // route to the wrong server through the shared master.
        let base = RemoteTmuxHost(destination: "user@host")
        let otherPort = RemoteTmuxHost(destination: "user@host", port: 2222)
        let otherIdentity = RemoteTmuxHost(destination: "user@host", identityFile: "/keys/id")
        #expect(base.controlSocketPath != otherPort.controlSocketPath)
        #expect(base.controlSocketPath != otherIdentity.controlSocketPath)
        #expect(otherPort.controlSocketPath != otherIdentity.controlSocketPath)
        // Deterministic: same identity → same socket path.
        #expect(base.controlSocketPath == RemoteTmuxHost(destination: "user@host").controlSocketPath)
    }

    @Test func controlSocketPathFitsUnixLimitForLongDestination() {
        // Regression: a long SSH destination produced a ControlPath that, once
        // OpenSSH appended its transient `.XXXXXXXXXXXXXXXX` bind suffix,
        // overflowed the AF_UNIX sun_path limit — `ssh` died with
        // `unix_listener: path "…" too long for Unix domain socket`. The path
        // OpenSSH actually binds (ControlPath + transient suffix), not the renamed
        // ControlPath, is what must fit.
        let host = RemoteTmuxHost(destination: "dev-host-2a-7059f1dc.us-west-2.example.internal")
        #expect(RemoteTmuxHost.controlSocketPathFitsUnixLimit(host.controlSocketPath))
    }

    @Test func controlSocketPathFitsUnixLimitForExtremeDestination() {
        // Even a pathological destination must stay within budget; the hash
        // (uniqueness) is preserved, only the slug is trimmed.
        let host = RemoteTmuxHost(destination: String(repeating: "very-long-host.example.com.", count: 20))
        #expect(RemoteTmuxHost.controlSocketPathFitsUnixLimit(host.controlSocketPath))
        // The collision-resistant hash is never trimmed away.
        #expect(host.controlSocketPath.hasSuffix("-\(host.connectionHash).sock"))
    }

    @Test func controlSocketPathTrimmingPreservesEndpointUniqueness() {
        // Two long destinations that share a slug prefix (so the slug alone would
        // collapse after trimming) must still get distinct socket paths via the
        // untrimmed connectionHash — otherwise destructive commands could route to
        // the wrong host through a shared master.
        let a = RemoteTmuxHost(destination: "dev-host-2a-7059f1dc.us-west-2.example.internal")
        let b = RemoteTmuxHost(destination: "dev-host-2a-7059f1dc.us-east-1.example.internal")
        #expect(a.controlSocketPath != b.controlSocketPath)
        // …and both still fit the limit after trimming.
        #expect(RemoteTmuxHost.controlSocketPathFitsUnixLimit(a.controlSocketPath))
        #expect(RemoteTmuxHost.controlSocketPathFitsUnixLimit(b.controlSocketPath))
    }

    @Test func controlSocketPathFitnessPredicateMatchesAFUnixLimit() {
        // The predicate that `ensureControlSocketDirectory()` gates on: a path
        // leaving room for OpenSSH's 17-byte transient suffix fits; one that does
        // not, does not. macOS sun_path is 104 bytes incl. NUL (103 usable), so
        // the longest fitting ControlPath is 103 - 17 = 86 bytes.
        let fitting = String(repeating: "a", count: 86)
        let overflowing = String(repeating: "a", count: 87)
        #expect(RemoteTmuxHost.controlSocketPathFitsUnixLimit(fitting))
        #expect(!RemoteTmuxHost.controlSocketPathFitsUnixLimit(overflowing))
    }

    @Test func controlModeCommandNameRejectsLineDelimitersAndControlScalars() {
        #expect(RemoteTmuxHost.controlModeCommandName("work session") == "work session")
        #expect(RemoteTmuxHost.controlModeCommandName("  work session  ") == "work session")
        #expect(RemoteTmuxHost.controlModeCommandName("") == nil)
        #expect(RemoteTmuxHost.controlModeCommandName("safe\nrename-window injected") == nil)
        #expect(RemoteTmuxHost.controlModeCommandName("safe\rrename-window injected") == nil)
        #expect(RemoteTmuxHost.controlModeCommandName("safe\u{7f}") == nil)
    }

    @Test func confirmedControlModeNamesPreserveSafeSpacing() {
        #expect(RemoteTmuxHost.controlModeLineSafeName(" work session ") == " work session ")
        #expect(RemoteTmuxHost.controlModeLineSafeName("work\tbad") == nil)
        #expect(RemoteTmuxHost.controlModeLineSafeName("work\nbad") == nil)
    }

    @Test func sendKeysHexArgumentsAreLowercaseSpaceSeparatedBytes() {
        #expect(RemoteTmuxControlConnection.hexByteArguments(Data([0x00, 0x0f, 0x10, 0xff])) == "00 0f 10 ff")
        #expect(RemoteTmuxControlConnection.hexByteArguments(Data()) == "")
    }

    @Test @MainActor func pastePaneRejectsDisconnectedControlStream() {
        let connection = RemoteTmuxControlConnection(host: RemoteTmuxHost(destination: "user@host"), sessionName: "work")
        #expect(connection.pastePane(paneId: 1, text: "/tmp/image.png") == false)
        #expect(connection.pastePane(paneId: 1, text: "") == false)
    }

    @Test @MainActor func sessionRenamedUpdatesTrackedNameAndEmitsObserverWithoutSessionId() {
        // A documented `%session-renamed <name>` must still track the new name
        // (reused for reconnect) and fire the observer the mirror listens on.
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"), sessionName: "old"
        )
        var observed: (old: String, new: String)?
        let token = connection.addObserver(onSessionChanged: { old, new in
            observed = (old, new)
        })
        defer { connection.removeObserver(token) }

        connection.handleMessageForTesting(.sessionRenamed(sessionId: nil, name: "dev", idBearingName: nil))

        #expect(connection.sessionName == "dev")
        #expect(connection.sessionId == nil)
        #expect(observed?.old == "old")
        #expect(observed?.new == "dev")
    }

    @Test @MainActor func sessionRenamedUpdatesTrackedIdWhenTmuxSuppliesOne() {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"), sessionName: "old"
        )
        connection.handleMessageForTesting(.sessionChanged(sessionId: 7, name: "old"))

        connection.handleMessageForTesting(.sessionRenamed(sessionId: 7, name: "$7 dev", idBearingName: "dev"))

        #expect(connection.sessionName == "dev")
        #expect(connection.sessionId == 7)
    }

    @Test @MainActor func sessionRenamedIgnoresDifferentSessionId() {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"), sessionName: "old"
        )
        connection.handleMessageForTesting(.sessionChanged(sessionId: 7, name: "old"))
        var observed: (old: String, new: String)?
        let token = connection.addObserver(onSessionChanged: { old, new in
            observed = (old, new)
        })
        defer { connection.removeObserver(token) }

        connection.handleMessageForTesting(.sessionRenamed(sessionId: 8, name: "$8 other", idBearingName: "other"))

        #expect(connection.sessionName == "old")
        #expect(connection.sessionId == 7)
        #expect(observed == nil)
    }

    @Test @MainActor func sessionRenamedIgnoresIdBearingRenameUntilSessionIdIsKnown() {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"), sessionName: "old"
        )

        connection.handleMessageForTesting(.sessionRenamed(sessionId: 7, name: "$7 dev", idBearingName: "dev"))

        #expect(connection.sessionName == "old")
        #expect(connection.sessionId == nil)
    }

    @Test @MainActor func controllerRekeysCachedConnectionWhenSessionIsRenamed() {
        let controller = RemoteTmuxController()
        let host = RemoteTmuxHost(destination: "user@host")
        let connection = RemoteTmuxControlConnection(host: host, sessionName: "old")
        controller.cacheConnection(connection)

        #expect(controller.connection(host: host, sessionName: "old") === connection)

        connection.handleMessageForTesting(.sessionRenamed(sessionId: nil, name: "dev", idBearingName: nil))

        #expect(controller.connection(host: host, sessionName: "old") == nil)
        #expect(controller.connection(host: host, sessionName: "dev") === connection)
    }

    @Test @MainActor func attachBlockDrainQueuesInitialWindowRequest() {
        let connection = RemoteTmuxControlConnection(host: RemoteTmuxHost(destination: "user@host"), sessionName: "work")
        let pipe = Pipe()
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-initial-window-request-test",
            maxPendingBytes: 4096,
            onFailure: {}
        )
        connection.installStdinWriterForTesting(writer)
        defer {
            writer.close()
            try? pipe.fileHandleForReading.close()
        }

        connection.handleMessageForTesting(.enter)
        #expect(connection.pendingCommandKindsForTesting.isEmpty)

        connection.handleMessageForTesting(.commandResult(commandNumber: 1, lines: [], isError: false))

        #expect(connection.pendingCommandKindsForTesting == [
            .listWindows(reorderGeneration: 0, retainedPaneIDs: [])
        ])
    }

    @Test func pastePaneCommandsProtectOptionLookingText() throws {
        let commands = try #require(RemoteTmuxControlConnection.pastePaneCommands(paneId: 7, text: "-n not-an-option"))
        #expect(commands.setBuffer == "set-buffer -b cmux-paste-7 -- '-n not-an-option'")
        #expect(commands.pasteBuffer == "paste-buffer -p -d -b cmux-paste-7 -t %7")
    }

    @Test func pastePaneCommandsRejectEmptyText() {
        #expect(RemoteTmuxControlConnection.pastePaneCommands(paneId: 7, text: "") == nil)
    }

    // MARK: - Interactive auth invocation (what `cmux ssh-tmux` runs in the tty)

    @Test func interactiveAuthInvocationShape() {
        let host = RemoteTmuxHost(destination: "user@host")
        let argv = host.interactiveAuthInvocation(sshExecutablePath: "/usr/bin/ssh")
        // Executable first, so the CLI can exec argv[0] directly.
        #expect(argv.first == "/usr/bin/ssh")
        // Force interactive mode so the prompt works even under ssh_config BatchMode yes…
        #expect(consecutive(argv, "-o", "BatchMode=no"))
        #expect(!argv.contains("BatchMode=yes"))
        // No -f: foreground auth keeps the post-auth ControlMaster retry deterministic.
        #expect(!argv.contains("-f"))
        // Keep -n explicitly; -f used to imply stdin from /dev/null.
        #expect(argv.contains("-n"))
        // The master must persist after the foreground client exits so discovery / the
        // -CC client can multiplex over it.
        #expect(argv.contains(where: { $0.hasPrefix("ControlPersist=") }))
        // …but do NOT pin StrictHostKeyChecking — honor the user's host-key policy.
        #expect(!argv.contains(where: { $0.hasPrefix("StrictHostKeyChecking=") }))
        // Opens the SAME shared master that discovery / the -CC client multiplex over.
        #expect(consecutive(argv, "-o", "ControlPath=\(host.controlSocketPath)"))
        // `--` guards the destination; the remote command is the trivial `true`.
        #expect(Array(argv.suffix(3)) == ["--", "user@host", "true"])
    }

    @Test func interactiveAuthInvocationGuardsDashPrefixedDestination() {
        // A dash-prefixed destination must sit AFTER `--`, never be parsed as an
        // ssh option (defense in depth; the dialog/socket also reject it upstream).
        let host = RemoteTmuxHost(destination: "-oProxyCommand=evil")
        let argv = host.interactiveAuthInvocation()
        guard let dashDash = argv.firstIndex(of: "--"),
              let dest = argv.firstIndex(of: "-oProxyCommand=evil") else {
            Issue.record("expected both `--` and the destination in the argv")
            return
        }
        #expect(dashDash < dest)
    }

    @Test func interactiveAuthInvocationIncludesPortAndIdentity() {
        let host = RemoteTmuxHost(destination: "user@host", port: 2222, identityFile: "/keys/id")
        let argv = host.interactiveAuthInvocation()
        #expect(consecutive(argv, "-p", "2222"))
        #expect(consecutive(argv, "-i", "/keys/id"))
    }

    /// True when `a` is immediately followed by `b` in `args` — i.e. an ssh
    /// `-o KEY=VALUE` / `-p N` / `-i path` pair is adjacent, as ssh requires.
    private func consecutive(_ args: [String], _ a: String, _ b: String) -> Bool {
        for i in args.indices.dropLast() where args[i] == a && args[i + 1] == b {
            return true
        }
        return false
    }

    private func temporaryDirectory(prefix: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeExecutable(at url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func runShell(
        _ command: String,
        environment: [String: String]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(decoding: stdoutData, as: UTF8.self),
            String(decoding: stderrData, as: UTF8.self)
        )
    }
}
