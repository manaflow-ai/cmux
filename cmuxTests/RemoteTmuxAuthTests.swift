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

    /// The close path knows only which workspace closed, so an offer has to be findable by its
    /// workspace. Without this the dismissal edge cannot resolve a host and a closed login tab
    /// goes unnoticed — which is what the removed poll had been quietly covering.
    @Test func anOpenLoginIsFindableByItsWorkspace() {
        var offers = RemoteTmuxLoginOffers()
        let workspace = UUID()
        guard case .present(let generation) = offers.claim(host: "h1", isOpen: { _ in false }) else {
            Issue.record("expected a fresh claim to be presentable")
            return
        }
        offers.recordOpened(host: "h1", workspace: workspace, generation: generation)

        #expect(offers.host(forOpenedWorkspace: workspace) == "h1")
        #expect(offers.host(forOpenedWorkspace: UUID()) == nil, "an unrelated workspace matches nothing")
    }

    /// A claimed-but-not-yet-opened offer has no workspace, so it must not be matched by one. The
    /// lookup runs on every workspace close, and a false match would decline the wrong host's login.
    @Test func aClaimedOfferWithNoWorkspaceMatchesNothing() {
        var offers = RemoteTmuxLoginOffers()
        _ = offers.claim(host: "h1", isOpen: { _ in false })
        #expect(offers.host(forOpenedWorkspace: UUID()) == nil)
    }

    /// Declining is per host and per generation: a closed tab must not silence a *newer* offer that
    /// replaced it, or one flap would stop the host ever offering a login again.
    @Test func decliningAnOldGenerationDoesNotSilenceANewerOffer() {
        var offers = RemoteTmuxLoginOffers()
        let first = UUID()
        guard case .present(let g1) = offers.claim(host: "h1", isOpen: { _ in false }) else { return }
        offers.recordOpened(host: "h1", workspace: first, generation: g1)
        offers.noteConnected(host: "h1")

        guard case .present(let g2) = offers.claim(host: "h1", isOpen: { _ in false }) else {
            Issue.record("a reconnected host must be able to offer again")
            return
        }
        let second = UUID()
        offers.recordOpened(host: "h1", workspace: second, generation: g2)
        // The stale close arrives late, naming the first generation.
        offers.noteDeclined(host: "h1", generation: g1)
        #expect(offers.host(forOpenedWorkspace: second) == "h1", "the newer offer must survive a stale decline")
        #expect(!offers.isDeclined(host: "h1"))
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

    // MARK: - Reconnect disposition (the wedge fix)

    /// A reconnect that fails BECAUSE the host wants interactive authentication must be
    /// classified `.authRequired`, not `.transient`. This is the whole bug: the reconnect
    /// runs `BatchMode=yes` on pipes with no tty, so retrying can never satisfy a
    /// password / MFA / security-key touch. Classified as transient it retries forever
    /// and the mirror freezes with nothing on screen to explain why.
    @Test(arguments: [
        "user@host: Permission denied (publickey,keyboard-interactive).",
        "Permission denied (publickey,password).",
        "Host key verification failed.",
        "Authentication failed.",
        "Too many authentication failures",
    ])
    func reconnectNeedingAuthIsNotTransient(_ stderr: String) {
        #expect(
            RemoteTmuxReconnectDisposition.classify(stderr: stderr, preControlOutput: "")
                == .authRequired
        )
    }

    /// A gone session still ends the connection, and wins over an auth failure when a
    /// host reports both — ending is correct and not recoverable, so it must not be
    /// downgraded to "ask the user to log in".
    @Test func goneSessionOutranksAuthFailure() {
        #expect(
            RemoteTmuxReconnectDisposition.classify(
                stderr: "no server running on /tmp/tmux-501/default", preControlOutput: "")
                == .sessionGone
        )
        #expect(
            RemoteTmuxReconnectDisposition.classify(
                stderr: "no server running on /tmp/tmux-501/default\nPermission denied (publickey).",
                preControlOutput: "") == .sessionGone
        )
    }

    /// Everything else keeps retrying with backoff — an unreachable or refused host is
    /// exactly what the retry loop is for, and must NOT pop a login the user cannot use.
    @Test(arguments: [
        "ssh: connect to host h port 22: Connection refused",
        "ssh: connect to host h port 22: Operation timed out",
        "kex_exchange_identification: read: Connection reset by peer",
        "",
    ])
    func unreachableStaysTransient(_ stderr: String) {
        #expect(
            RemoteTmuxReconnectDisposition.classify(stderr: stderr, preControlOutput: "")
                == .transient
        )
    }

    /// A `ProxyCommand` that closes the transport silently under BatchMode is the same
    /// situation as an explicit auth failure without the error string, so it must also
    /// stop retrying and offer a login. The reconnect classifier therefore has to use the
    /// composed predicate the initial-connect sites use; matching only "permission
    /// denied" leaves a corporate-broker host retrying forever — the original bug,
    /// surviving for exactly the hosts this feature exists to serve.
    @Test(arguments: [
        "ssh_dispatch_run_fatal: Connection to UNKNOWN port 65535: Broken pipe",
        "Connection closed by UNKNOWN port 65535",
    ])
    func silentProxyCloseOnReconnectOffersLogin(_ stderr: String) {
        #expect(!RemoteTmuxSSHTransport.indicatesAuthRequired(stderr))
        #expect(
            RemoteTmuxReconnectDisposition.classify(stderr: stderr, preControlOutput: "")
                == .authRequired
        )
    }

    /// A non-recoverable proxy failure keeps retrying rather than asking for a login the
    /// user cannot act on: no amount of authenticating fixes a missing proxy binary.
    @Test func nonRecoverableProxyFailureStaysTransient() {
        #expect(
            RemoteTmuxReconnectDisposition.classify(
                stderr: "zsh:1: command not found: corp-proxy\nConnection closed by UNKNOWN port 65535",
                preControlOutput: "") == .transient
        )
    }

    // MARK: - One login per host

    /// Several sessions on one host drop together, and each reports auth-required in the
    /// same turn. Reserving the slot only *after* the workspace exists lets every one of
    /// them pass the "already offered?" check, and the user gets a tab per session.
    ///
    /// Observed for real: six login tabs for one host inside 76ms after a session restore
    /// re-attached six mirrors to a host that needs 2FA.
    @Test func simultaneousDropsOnOneHostOfferOneLogin() {
        var offers = RemoteTmuxLoginOffers()
        let host = "hash-a"
        let neverOpen: (UUID) -> Bool = { _ in false }

        // First mirror wins the slot; the create has not finished yet.
        guard case .present(let generation) = offers.claim(host: host, isOpen: neverOpen) else {
            Issue.record("the first claim must win the slot"); return
        }
        // Every other mirror in the same turn must be refused, workspace or no workspace.
        #expect(offers.claim(host: host, isOpen: neverOpen) == .alreadyOffered)
        #expect(offers.claim(host: host, isOpen: neverOpen) == .alreadyOffered)

        offers.recordOpened(host: host, workspace: UUID(), generation: generation)
        #expect(offers.claim(host: host, isOpen: { _ in true }) == .alreadyOffered)
    }

    /// A resume attempt is not proof of success: the reconnect can fail authentication
    /// again. Releasing the slot on the attempt turned every repeat failure into another
    /// tab — observed as one new tab every ~3.8s, matching the reconnect backoff.
    @Test func repeatedAuthFailuresReuseTheOpenLogin() {
        var offers = RemoteTmuxLoginOffers()
        let host = "hash-a"
        let workspace = UUID()
        guard case .present(let generation) = offers.claim(host: host, isOpen: { _ in false }) else {
            Issue.record("expected to win the slot"); return
        }
        offers.recordOpened(host: host, workspace: workspace, generation: generation)

        // Whatever happens between failures, while that workspace is on screen the answer
        // stays "already offered". There is deliberately no API to release it on a resume.
        for _ in 0..<5 {
            #expect(offers.claim(host: host, isOpen: { $0 == workspace }) == .alreadyOffered)
        }
        #expect(offers.openedWorkspace(host: host)?.workspace == workspace)
    }

    /// Connecting is what ends the offer, so the next outage starts clean.
    @Test func connectingReleasesTheOffer() {
        var offers = RemoteTmuxLoginOffers()
        let host = "hash-a"
        guard case .present(let generation) = offers.claim(host: host, isOpen: { _ in false }) else {
            Issue.record("expected to win the slot"); return
        }
        offers.recordOpened(host: host, workspace: UUID(), generation: generation)
        offers.noteConnected(host: host)
        #expect(!offers.hasOffer(host: host))
        if case .alreadyOffered = offers.claim(host: host, isOpen: { _ in true }) {
            Issue.record("connecting must let the next outage offer a login")
        }
    }

    /// Closing the login means "no", and it has to stick for this outage.
    ///
    /// The retry that follows fails the same way, so re-offering immediately reopened the tab
    /// and the close button appeared to do nothing. A reconnect clears the refusal, so the
    /// next real outage offers again.
    @Test func dismissingTheLoginStopsTheOfferingUntilTheHostReconnects() {
        var offers = RemoteTmuxLoginOffers()
        let host = "hash-a"
        guard case .present(let generation) = offers.claim(host: host, isOpen: { _ in false }) else {
            Issue.record("expected to win the slot"); return
        }
        offers.recordOpened(host: host, workspace: UUID(), generation: generation)

        offers.noteDeclined(host: host, generation: generation)
        #expect(offers.isDeclined(host: host))
        // Every later failure in this outage must be silent, however many arrive.
        for _ in 0..<5 {
            #expect(offers.claim(host: host, isOpen: { _ in false }) == .declined)
        }

        // A reconnect ends the outage, so the next one may ask again.
        offers.noteConnected(host: host)
        #expect(!offers.isDeclined(host: host))
        if case .present = offers.claim(host: host, isOpen: { _ in false }) {} else {
            Issue.record("after reconnecting, a new outage must be allowed to offer a login")
        }
    }

    /// A stale owner cannot mark a newer offer as dismissed.
    @Test func aStaleOwnerCannotDeclineANewerOffer() {
        var offers = RemoteTmuxLoginOffers()
        let host = "hash-a"
        guard case .present(let first) = offers.claim(host: host, isOpen: { _ in false }) else {
            Issue.record("expected to win the slot"); return
        }
        offers.recordOpened(host: host, workspace: UUID(), generation: first)
        guard case .present(let second) = offers.claim(host: host, isOpen: { _ in false }) else {
            Issue.record("a dismissed-workspace claim should win"); return
        }
        offers.noteDeclined(host: host, generation: first)
        #expect(!offers.isDeclined(host: host))
        offers.noteDeclined(host: host, generation: second)
        #expect(offers.isDeclined(host: host))
    }

    /// A failed create does not wedge the host behind a login that never appeared.
    @Test func aFailedOfferDoesNotSuppressTheNextOne() {
        var offers = RemoteTmuxLoginOffers()
        let host = "hash-a"
        guard case .present(let generation) = offers.claim(host: host, isOpen: { _ in false }) else {
            Issue.record("expected to win the slot"); return
        }
        offers.abandon(host: host, generation: generation)
        #expect(!offers.hasOffer(host: host))
        if case .alreadyOffered = offers.claim(host: host, isOpen: { _ in false }) {
            Issue.record("a failed create must not suppress the next offer")
        }
    }

    /// Hosts are independent: one host's outstanding login must not mute another's.
    @Test func offersAreScopedPerHost() {
        var offers = RemoteTmuxLoginOffers()
        if case .alreadyOffered = offers.claim(host: "hash-a", isOpen: { _ in false }) {
            Issue.record("first host should win")
        }
        if case .alreadyOffered = offers.claim(host: "hash-b", isOpen: { _ in false }) {
            Issue.record("a second host must not be muted by the first")
        }
        #expect(offers.claim(host: "hash-a", isOpen: { _ in false }) == .alreadyOffered)
    }

    /// A login workspace must not come back on relaunch.
    ///
    /// A restored terminal is a fresh shell, so a restored login cannot authenticate
    /// anything, and it is invisible to the per-host rule (which tracks the workspace it
    /// created) — so each relaunch would let the next outage add another. This is the
    /// mechanism behind login tabs accumulating across restarts.
    @MainActor @Test func aLoginWorkspaceIsNotRestored() {
        let manager = TabManager()
        let workspace = manager.addWorkspace(title: "Sign in to example-host", select: false)
        #expect(workspace.isRestorableInSessionSnapshot)
        #expect(manager.sessionSnapshotWorkspaceIds().contains(workspace.id))

        workspace.isRemoteTmuxAuthLogin = true
        #expect(!workspace.isRestorableInSessionSnapshot)
        #expect(!manager.sessionSnapshotWorkspaceIds().contains(workspace.id))
    }

    // MARK: - Cause A: a live connection must not be asked to authenticate

    /// The straggler case, reduced to its rule. Several sessions park, the user signs in, the
    /// first to reconnect releases the offer, and a sibling still finishing its pre-login
    /// attempt reports auth-required into an empty slot — a second login moments after a
    /// successful sign-in. A host with any live connection has proven authentication is not
    /// the blocker.
    @MainActor @Test func aHostWithALiveConnectionIsNotAskedToAuthenticate() {
        #expect(RemoteTmuxController.hasLiveConnection(states: [.connected]))
        #expect(RemoteTmuxController.hasLiveConnection(states: [.reconnecting, .connected]))
        // Parked is exactly what a login exists for, and connecting has proven nothing yet;
        // counting either as live would suppress the offer the user needs.
        #expect(!RemoteTmuxController.hasLiveConnection(states: [.reconnecting]))
        #expect(!RemoteTmuxController.hasLiveConnection(states: [.connecting]))
        #expect(!RemoteTmuxController.hasLiveConnection(states: [.reconnecting, .connecting, .ended]))
        #expect(!RemoteTmuxController.hasLiveConnection(states: []))
    }

    // MARK: - Cause B: "handled" must mean a login was presented

    /// `notifyAuthRequired` reporting handled merely because an observer is *subscribed* is
    /// what stranded a host after a dismissal: the connection's retry fallback was skipped, so
    /// it sat parked with no retry and no waiter until cmux restarted.
    @MainActor @Test func authRequiredIsHandledOnlyWhenAConsumerPresentsALogin() {
        let observers = RemoteTmuxConnectionObservers()

        // Subscribed but declining (the dismissed-host case) is NOT handled.
        _ = observers.add(
            onPaneOutput: nil, onPaneCwd: nil, onPaneReflow: nil, onActivePaneChanged: nil,
            onSessionChanged: nil, onTopologyChanged: nil, onReconnectReady: nil, onExit: nil,
            onConnectionStateChanged: nil,
            onAuthRequired: { _ in false }
        )
        #expect(!observers.notifyAuthRequired(sshArgv: ["/usr/bin/ssh", "host"]))

        // A consumer that actually presents one flips it, and every observer still runs —
        // an `||` would short-circuit and skip the rest.
        var secondRan = false
        _ = observers.add(
            onPaneOutput: nil, onPaneCwd: nil, onPaneReflow: nil, onActivePaneChanged: nil,
            onSessionChanged: nil, onTopologyChanged: nil, onReconnectReady: nil, onExit: nil,
            onConnectionStateChanged: nil,
            onAuthRequired: { _ in secondRan = true; return true }
        )
        #expect(observers.notifyAuthRequired(sshArgv: ["/usr/bin/ssh", "host"]))
        #expect(secondRan)
    }

    /// With no consumer at all there is nothing to present, so the caller must retry.
    @MainActor @Test func noConsumerMeansNotHandled() {
        let observers = RemoteTmuxConnectionObservers()
        #expect(!observers.notifyAuthRequired(sshArgv: ["/usr/bin/ssh", "host"]))
    }

    // MARK: - Cause D: the pane shows the command it ran

    /// The failure message tells the user to run the command again, which is unfollowable if
    /// the command was never shown — `ssh` prints its prompts, not its argv.
    @MainActor @Test func theLoginPaneEchoesTheCommandItRuns() {
        let command = RemoteTmuxController.interactiveAuthShellCommand(
            sshArgv: ["/usr/bin/ssh", "example-host", "true"]
        )
        #expect(command.contains("+ "))
        // The echo must precede the ssh invocation, or "the command above" is below.
        if let bannerAt = command.range(of: "printf")?.lowerBound,
           let sshAt = command.range(of: "/usr/bin/ssh")?.lowerBound {
            #expect(bannerAt < sshAt)
        } else {
            Issue.record("expected both an echo and the ssh invocation in the command")
        }
    }

    // MARK: - Login workspace focus

    /// The login workspace must actually surface, which means earning a focus allowance.
    ///
    /// `focus` is honored only for methods in `explicitFocusParamV2Methods` and only while
    /// a matching allowance is on the calling thread's stack. Both halves are load-bearing
    /// and neither is visible at the call site, so this pins them: dropping the `focus`
    /// param, renaming it, or removing `workspace.create` from the eligible set all yield
    /// a login terminal created somewhere the user never sees.
    @MainActor @Test func loginWorkspaceParamsEarnFocus() {
        let host = RemoteTmuxHost(destination: "example-host")
        let params = RemoteTmuxController.reconnectAuthWorkspaceParams(
            host: host, sshArgv: ["/usr/bin/ssh", "example-host", "true"]
        )
        #expect(params["focus"] as? Bool == true)
        #expect(
            TerminalController.explicitFocusParamAllowsFocus(
                commandKey: "workspace.create", params: params
            )
        )

        // Inside a `workspace.create` policy these params focus; outside one they do not,
        // because the allowance lives on the calling thread's stack. That is exactly why
        // the caller wraps the create instead of calling straight through.
        let snapshot = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "workspace.create", isV2: true, params: params
        )
        #expect(snapshot.insideAllowsFocus)
        #expect(!snapshot.outsideAllowsFocus)
    }

    /// The login pane must outlive the `ssh` it runs.
    ///
    /// A terminal command is executed as `bash --noprofile --norc -c "exec -l <command>"`.
    /// That `exec -l` replaces the shell with the command's FIRST program, so anything
    /// written after it at the top level never runs. With the ssh invocation leading, the
    /// result message and the interactive shell that holds the pane open are both
    /// unreachable, and cmux closes a workspace whose child exited — the login tab appears
    /// and vanishes in well under a second. Wrapping the payload in an explicit shell is
    /// what makes the tail reachable, so that is what this pins.
    @MainActor @Test func loginCommandSurvivesTheSshItRuns() {
        let command = RemoteTmuxController.interactiveAuthShellCommand(
            sshArgv: ["/usr/bin/ssh", "-o", "BatchMode=no", "example-host", "true"]
        )
        // The first program must be a shell, not ssh: `exec -l` applies to whatever leads.
        #expect(command.hasPrefix("/bin/sh -c "))
        #expect(!command.hasPrefix("'/usr/bin/ssh'"))
        // The ssh invocation and the keep-alive tail both live inside the shell's argument.
        #expect(command.contains("/usr/bin/ssh"))
        #expect(command.contains("exec "))
        #expect(command.contains(" -i"))
    }

    /// Runs the login command the way a terminal command is actually run, and checks both
    /// properties that matter: the tail is reachable, and a hostile destination cannot
    /// inject anything.
    ///
    /// This is executed rather than pattern-matched on purpose. Asserting that the hostile
    /// text is absent from the command string is not a safety check — the text is *supposed*
    /// to appear there, quoted, as data. Only running it distinguishes quoted data from
    /// executable code. Running it is also the only way to see that the tail executes at
    /// all, which is exactly what the `exec -l` wrapper broke.
    @MainActor @Test func loginCommandRunsItsTailAndResistsInjection() throws {
        let tmp = FileManager.default.temporaryDirectory
        let injected = tmp.appendingPathComponent("cmux-auth-injected-\(UUID().uuidString)")
        let tailRan = tmp.appendingPathComponent("cmux-auth-tail-\(UUID().uuidString)")

        // Stand in for the user's shell with a script that records that it ran and exits,
        // so the command terminates instead of waiting at an interactive prompt.
        let fakeShell = tmp.appendingPathComponent("cmux-auth-shell-\(UUID().uuidString).sh")
        try "#!/bin/sh\ntouch \(tailRan.path)\n".write(to: fakeShell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeShell.path)
        setenv("SHELL", fakeShell.path, 1)
        defer {
            unsetenv("SHELL")
            for url in [injected, tailRan, fakeShell] { try? FileManager.default.removeItem(at: url) }
        }

        // `/bin/echo` stands in for ssh so the success branch runs without touching a network.
        let command = RemoteTmuxController.interactiveAuthShellCommand(
            sshArgv: ["/bin/echo", "host'; touch \(injected.path); '"]
        )
        // The command is now echoed as a banner too, so the hostile text appears twice —
        // both occurrences must be inert.

        // The exact shape a terminal command is executed with.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["--noprofile", "--norc", "-c", "exec -l \(command)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(
            FileManager.default.fileExists(atPath: tailRan.path),
            "the command's tail never ran, so the login pane would exit as soon as ssh does"
        )
        #expect(
            !FileManager.default.fileExists(atPath: injected.path),
            "a hostile destination executed as a command"
        )
    }

    /// The login workspace title names the host, so a user with several mirrored hosts
    /// knows which one is asking.
    @MainActor @Test func loginWorkspaceTitleNamesTheHost() {
        let params = RemoteTmuxController.reconnectAuthWorkspaceParams(
            host: RemoteTmuxHost(destination: "build-box"), sshArgv: ["/usr/bin/ssh", "build-box", "true"]
        )
        #expect((params["title"] as? String)?.contains("build-box") == true)
    }
}
