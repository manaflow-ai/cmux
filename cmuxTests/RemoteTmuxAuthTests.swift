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

        #expect(connection.pendingCommandKindsForTesting == [.listWindows])
    }

    @Test @MainActor func layoutChangePrunesRemovedPaneDiagnosticState() {
        let connection = RemoteTmuxControlConnection(host: RemoteTmuxHost(destination: "user@host"), sessionName: "work")
        connection.handleMessageForTesting(.layoutChange(
            windowId: 1,
            layout: "abcd,120x40,0,0{60x40,0,0,4,59x40,61,0,5}"
        ))
        connection.handleMessageForTesting(.output(paneId: 4, data: Data("left".utf8)))
        connection.handleMessageForTesting(.output(paneId: 5, data: Data("right".utf8)))
        connection.handleMessageForTesting(.subscriptionChanged(name: "cmux_reflow_4", value: "0|zsh"))
        connection.handleMessageForTesting(.subscriptionChanged(name: "cmux_reflow_5", value: "1|vim"))

        connection.handleMessageForTesting(.layoutChange(windowId: 1, layout: "f92f,80x24,0,0,4"))

        #expect(connection.snapshot().paneOutputByteCounts[4] == 4)
        #expect(connection.snapshot().paneOutputByteCounts[5] == nil)
        #expect(connection.paneForegroundStates[4] != nil)
        #expect(connection.paneForegroundStates[5] == nil)
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
        // …and -f so ssh backgrounds AFTER auth: the persistent ControlMaster then
        // detaches its fds and won't freeze the terminal on window/app close.
        #expect(argv.contains("-f"))
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
}
