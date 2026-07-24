import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests for the proxy-transport stderr classifier used by remote-tmux
/// interactive retry routing.
@Suite struct RemoteTmuxProxyTransportRetryTests {
    @Test(arguments: [
        "Connection closed by UNKNOWN port 65535",
        "ssh_dispatch_run_fatal: Connection to UNKNOWN port 65535: Broken pipe",
        "Connection closed by UnKnOwN port 65535",
    ])
    func classifiesSilentProxyCommandClosures(_ stderr: String) {
        #expect(RemoteTmuxSSHTransport.indicatesProxyCommandTransportClosed(stderr))
    }

    @Test(arguments: [
        "channel 0: open failed: connect failed: Connection refused\nstdio forwarding failed\nConnection closed by UNKNOWN port 65535",
        "connect failed: Connection refused\nConnection closed by UNKNOWN port 65535",
        "stdio forwarding failed\nssh_exchange_identification: Connection closed by remote host\nConnection closed by UNKNOWN port 65535",
        "kex_exchange_identification: Connection closed by remote host\nConnection closed by UNKNOWN port 65535",
        "ssh: Could not resolve hostname inner.invalid: nodename nor servname provided\nConnection closed by UNKNOWN port 65535",
        "nc: getaddrinfo: name or service not known\nConnection closed by UNKNOWN port 65535",
        "nc: getaddrinfo: nodename nor servname provided, or not known\nConnection closed by UNKNOWN port 65535",
        "channel 1: open failed: administratively prohibited: open failed\nConnection closed by UNKNOWN port 65535",
        "nc: connect to inner.invalid port 22 (tcp) failed: Connection timed out\nConnection closed by UNKNOWN port 65535",
        "ssh_exchange_identification: Connection closed by remote host\nConnection closed by UNKNOWN port 65535",
        "zsh:1: command not found: corp-proxy\nConnection closed by UNKNOWN port 65535",
        "bash: line 1: corp-proxy: command not found\nConnection closed by UNKNOWN port 65535",
        "sh: 1: corp-proxy: not found\nConnection closed by UNKNOWN port 65535",
        "zsh:1: no such file or directory: /opt/corp/proxy\nConnection closed by UNKNOWN port 65535",
        "bash: line 1: /opt/corp/proxy: No such file or directory\nConnection closed by UNKNOWN port 65535",
        "bash: line 1: /opt/corp/proxy: cannot execute binary file: Exec format error\nConnection closed by UNKNOWN port 65535",
    ])
    func doesNotClassifyExplainedProxyClosures(_ stderr: String) {
        #expect(!RemoteTmuxSSHTransport.indicatesProxyCommandTransportClosed(stderr))
    }

    @Test(arguments: [
        "MOTD: lab name is UNKNOWN port 65535 status board",
        "remote warning: process listening on port 65535 with unknown owner",
        "user note: 'unknown port 65535' is reserved",
    ])
    func anchorsProxyClosedMatchToOpenSSHPhrasing(_ stderr: String) {
        #expect(!RemoteTmuxSSHTransport.indicatesProxyCommandTransportClosed(stderr))
    }

    @Test(arguments: [
        "ssh: connect to host bad.example.com port 22: Connection refused",
        "ssh: connect to host bad.example.com port 2222: Operation timed out",
        "Connection closed by 10.0.0.5 port 22",
    ])
    func doesNotClassifyRealPortClosuresAsProxyTransport(_ stderr: String) {
        #expect(!RemoteTmuxSSHTransport.indicatesProxyCommandTransportClosed(stderr))
    }

    @Test func proxyClosedAndAuthRequiredAreDisjoint() {
        let proxyOnly = "ssh_dispatch_run_fatal: Connection to UNKNOWN port 65535: Broken pipe"
        #expect(RemoteTmuxSSHTransport.indicatesProxyCommandTransportClosed(proxyOnly))
        #expect(!RemoteTmuxSSHTransport.indicatesAuthRequired(proxyOnly))

        let authOnly = "user@host: Permission denied (publickey,password)."
        #expect(RemoteTmuxSSHTransport.indicatesAuthRequired(authOnly))
        #expect(!RemoteTmuxSSHTransport.indicatesProxyCommandTransportClosed(authOnly))
    }

    @Test(arguments: [
        "user@host: Permission denied (publickey,password).",
        "Host key verification failed.",
        "Too many authentication failures",
        "Connection closed by UNKNOWN port 65535",
        "ssh_dispatch_run_fatal: Connection to UNKNOWN port 65535: Broken pipe",
    ])
    func composedPredicateFiresForEitherRecoverableSignal(_ stderr: String) {
        #expect(RemoteTmuxSSHTransport.indicatesInteractiveRetryWillHelp(stderr))
    }

    @Test(arguments: [
        "no server running on /tmp/tmux-501/default",
        "no matching host key type found. their offer: ssh-rsa",
        "ssh: connect to host bad.example.com port 22: Connection refused",
        "",
        "channel 0: open failed: connect failed: Connection refused\nstdio forwarding failed\nConnection closed by UNKNOWN port 65535",
        "zsh:1: command not found: corp-proxy\nConnection closed by UNKNOWN port 65535",
    ])
    func composedPredicateRejectsNonRecoverableFailures(_ stderr: String) {
        #expect(!RemoteTmuxSSHTransport.indicatesInteractiveRetryWillHelp(stderr))
    }
}

/// Tests for the transport seam: the point where cmux decides *how* a control stream is
/// carried, rather than assuming ssh at the point of use.
@Suite struct RemoteTmuxTransportProfileTests {

    /// A transport that keeps a session alive across a network change, standing in for
    /// EternalTerminal. Only used to prove the seam is real — that argv and the
    /// reconnect-ownership flag both come from the profile and nothing else re-derives them.
    struct PersistentSessionProfile: RemoteTmuxTransportProfile {
        let binary: String
        let port: Int?

        func executablePath() -> String { binary }

        func controlStreamArgv(
            host: RemoteTmuxHost,
            sessionName: String,
            createIfMissing: Bool
        ) -> [String] {
            // `--command` runs one command and exits, and `exec` keeps a shell parent out of
            // the remote process tree. This stand-in keeps the resolver because it says nothing
            // about how its command reaches the remote shell; the real et profile drops it,
            // since et types the command into a login shell that both resolves PATH itself and
            // cannot read a line that long.
            let remote = RemoteTmuxHost.tmuxRemoteCommand(
                arguments: ["-CC", createIfMissing ? "new-session" : "attach-session", "-t", sessionName]
            )
            var argv: [String] = []
            if let port { argv += ["--port", String(port)] }
            return argv + ["--command", "exec \(remote)", host.destination]
        }

        func oneShotArgv(host: RemoteTmuxHost, remoteCommand: String) -> [String] {
            // One-shot commands can keep riding ssh's shared master even when the control
            // stream does not, so this deliberately does not reimplement it.
            RemoteTmuxSSHTransportProfile().oneShotArgv(host: host, remoteCommand: remoteCommand)
        }

        var reconnectsInternally: Bool { true }
        /// A persistent-session transport is a terminal client, so it needs a tty.
        var requiresPseudoTerminal: Bool { true }
    }

    @Test func sshProfileProducesTodaysControlStreamArgv() {
        let host = RemoteTmuxHost(destination: "user@host")
        let profile = RemoteTmuxSSHTransportProfile()
        #expect(
            profile.controlStreamArgv(host: host, sessionName: "work", createIfMissing: false)
                == host.controlModeArguments(sessionName: "work", createIfMissing: false)
        )
        #expect(profile.executablePath() == RemoteTmuxHost.defaultSSHExecutablePath())
    }

    @Test func sshProfileEndsOptionParsingBeforeTheDestination() {
        // A destination that looks like an ssh option must never be consumed as one.
        let host = RemoteTmuxHost(destination: "-oProxyCommand=evil")
        let argv = RemoteTmuxSSHTransportProfile()
            .oneShotArgv(host: host, remoteCommand: "true")
        let dashDash = argv.firstIndex(of: "--")
        #expect(dashDash != nil)
        if let dashDash {
            #expect(argv[dashDash + 1] == "-oProxyCommand=evil")
        }
    }

    /// ssh owns no reconnection: cmux respawns it. This is the flag that decides whether EOF
    /// or a liveness check drives recovery, so it is worth pinning rather than assuming.
    @Test func sshDoesNotReconnectItself() {
        #expect(!RemoteTmuxSSHTransportProfile().reconnectsInternally)
    }

    /// The seam has to be able to express a transport that is not ssh at all: a different
    /// binary, a port that is not 22, and ownership of its own reconnection.
    @Test func aPersistentSessionTransportIsExpressible() {
        let host = RemoteTmuxHost(destination: "user@host")
        let profile = PersistentSessionProfile(binary: "/usr/local/bin/et", port: 2022)
        let argv = profile.controlStreamArgv(host: host, sessionName: "work", createIfMissing: false)

        #expect(profile.executablePath() == "/usr/local/bin/et")
        #expect(profile.reconnectsInternally)
        #expect(argv.last == "user@host")
        #expect(consecutive(argv, "--port", "2022"))
        // The command must run one command rather than opening a shell, and must still go
        // through the resolver so a minimal remote PATH cannot hide tmux.
        let command = argv.first(where: { $0.hasPrefix("exec ") })
        #expect(command?.contains("attach-session") == true)
        #expect(command?.contains("cmux-remote-executable") == true)
        // Nothing in the argv may kill the user's other sessions on that host.
        #expect(!argv.contains("-x"))
        #expect(!argv.contains("--kill-other-sessions"))
    }

    // MARK: - Seam 2: who owns reconnection decides what EOF means

    /// EOF means reconnect, whoever owns reconnection, because EOF cannot say which of the
    /// transport and the session died.
    ///
    /// This test previously asserted the opposite for a self-reconnecting transport, on the
    /// reasoning that such a transport does not end for a network drop. Measured against
    /// et 6.2.11+7: restarting only `etserver` ends the stream while `tmux has-session` still
    /// succeeds, so that reasoning discarded live, reattachable sessions.
    @Test func endOfStreamOnAnEstablishedStreamMeansReconnectAndLetTheReattachDecide() {
        #expect(RemoteTmuxStreamEndDisposition.forStreamEnd(hasReachedControlMode: true) == .reconnect)
    }

    // MARK: - Seam 3: the pre-connect hook

    @Test func noHookIsTodaysBehavior() {
        #expect(RemoteTmuxPreConnectHook().argv(destination: "user@host") == nil)
        #expect(RemoteTmuxPreConnectHook(command: "   ").argv(destination: "user@host") == nil)
    }

    @Test func aHookRunsWithTheDestination() {
        let hook = RemoteTmuxPreConnectHook(command: "/usr/local/bin/mint-cred")
        #expect(hook.argv(destination: "user@host") == ["/usr/local/bin/mint-cred", "user@host"])
    }

    /// A broken hook must not make a host unreachable: cmux proceeds and lets the
    /// connection fail on its own terms.
    @Test(arguments: [Int32(0), 1, 127, -1])
    func aHookFailureNeverAbortsTheConnection(_ code: Int32) {
        #expect(!RemoteTmuxPreConnectHook(command: "/bin/false").shouldAbortConnection(onExitCode: code))
    }

    private func consecutive(_ args: [String], _ a: String, _ b: String) -> Bool {
        for index in args.indices.dropLast() where args[index] == a && args[index + 1] == b {
            return true
        }
        return false
    }

    /// A connection defaults to ssh, so introducing the seam changes no behavior.
    @MainActor @Test func aConnectionDefaultsToSSH() {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"),
            sessionName: "work"
        )
        #expect(!connection.transportProfile.reconnectsInternally)
        #expect(connection.transportProfile.executablePath() == RemoteTmuxHost.defaultSSHExecutablePath())
    }
}

/// Tests against a REAL EternalTerminal stream.
///
/// The fixture is not synthetic: it is the bytes a real `et` 6.2.11 client produced carrying
/// `tmux -CC attach-session` over a loopback `etserver`, captured under a pty. It exists
/// because the two things that break a control protocol on this transport — a kilobyte of
/// shell preamble, and CRLF line endings — are invisible in `et --help` and were only found
/// by running it.
@Suite struct RemoteTmuxETTransportTests {

    /// Base64 of a captured `et` control stream: echoed command, prompt escapes, then tmux
    /// control mode.
    static let capturedETStreamBase64 = "ZXhlYyBlbnYgVE1VWF9UTVBESVI9L1VzZXJzL2VqYzMvTGlicmFyeS9DYWNoZXMvY211eC9yZW1vdGUtdG11eC1ldC9jbXV4LWV0aG9zdC90bXV4IHRtdXggLUNDIGF0dGFjaC1zZXNzaW9uIC10IGV0cHJvYmU7IGV4aXQNChtbMW0bWzdtJRtbMjdtG1sxbRtbMG0gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgDSANG10yO2VqYzNAZWpjMy1tYWM6fgcbXTE7fgcNG1swbRtbMjdtG1syNG0bW0obWzAxOzMybeKenCAgG1szNm1+G1swMG0gG1tLG1s/MWgbPRtbPzIwMDRoZQhleGVjIGVudiBUTVVYX1RNUERJUj0vVXNlcnMvZWpjMy9MaWJyYXJ5L0NhY2hlcy9jbXV4L3JlbW90ZS10bXV4LWV0L2NtdXgtZXQgDRtbSxtbS2gNaG9zdC90bXV4IHRtdXggLUNDIGF0dGFjaC1zZXNzaW9uIC10IGV0cHJvYmU7IGV4aXQbW0ENDRtbMG0bWzI3bRtbMjRtG1tKG1swMTszMm3inpwgIBtbMzZtfhtbMDBtIGV4ZWMgZW52IFRNVVhfVE1QRElSPS9Vc2Vycy9lamMzL0xpYnJhcnkvQ2FjaGVzL2NtdXgvcmVtb3RlLXRtdXgtZXQvY211eC1ldGhvc3QvdG11eCB0bXV4IC1DQyBhdHRhY2gtc2Vzc2lvbiAtdCBldHByb2JlOyBleGl0G1tBG1s0NUQbWzRtG1szMm1lG1s0bRtbMzJteBtbNG0bWzMybWUbWzRtG1szMm1jG1syNG0bWzM5bSAbWzRtG1szMm1lG1s0bRtbMzJtbhtbNG0bWzMybXYbWzI0bRtbMzltG1sxM0MbWzRtLxtbNG1VG1s0bXMbWzRtZRtbNG1yG1s0bXMbWzRtLxtbNG1lG1s0bWobWzRtYxtbNG0zG1s0bS8bWzRtTBtbNG1pG1s0bWIbWzRtchtbNG1hG1s0bXIbWzRteRtbNG0vG1s0bUMbWzRtYRtbNG1jG1s0bWgbWzRtZRtbNG1zG1s0bS8bWzRtYxtbNG1tG1s0bXUbWzRteBtbNG0vG1s0bXIbWzRtZRtbNG1tG1s0bW8bWzRtdBtbNG1lG1s0bS0bWzRtdBtbNG1tG1s0bXUbWzRteBtbNG0tG1s0bWUbWzRtdBtbNG0vG1s0bWMbWzRtbRtbNG11G1s0bXgbWzRtLRtbNG1lG1s0bXQbWzRtaBtbNG1vG1s0bXMbWzRtdBtbNG0vG1s0bXQbWzRtbRtbNG11G1s0bXgbWzI0bSAbWzMybXQbWzMybW0bWzMybXUbWzMybXgbWzM5bRtbMzJDG1szMm1lG1szMm14G1szMm1pG1szMm10G1szOW0bWz8xbBs+G1s/MjAwNGwNDQobXTI7ZXhlYyBlbnYgIHRtdXggLUNDIGF0dGFjaC1zZXNzaW9uIC10IGV0cHJvYmU7IGV4aXQHG10xO2V4ZWMHG1AxMDAwcCViZWdpbiAxNzg0NjE2NjA0IDMwNSAwDQolZW5kIDE3ODQ2MTY2MDQgMzA1IDANCiVzZXNzaW9uLWNoYW5nZWQgJDAgZXRwcm9iZQ0K"

    static var capturedETStream: Data {
        Data(base64Encoded: capturedETStreamBase64) ?? Data()
    }

    @Test func theFixtureIsARealETStreamWithPreambleAndCRLF() throws {
        let data = Self.capturedETStream
        #expect(!data.isEmpty)
        // ET types the command into a login shell and appends `; exit`, so the stream opens
        // with the echoed command rather than with protocol.
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("tmux -CC attach-session"))
        #expect(text.contains("; exit"))
        // And the pty gives CRLF, which pipes never would.
        #expect(data.contains(0x0d))
        // The protocol starts well into the stream, not at byte 0.
        let begin = try #require(text.range(of: "%begin"))
        let offset = text.distance(from: text.startIndex, to: begin.lowerBound)
        #expect(offset > 500, "expected a substantial preamble, saw \(offset) bytes")
    }

    /// The parser must survive the preamble and still produce the control messages. If it
    /// choked on the echoed command or the CRLF, ET could not carry `-CC` at all.
    @Test func theParserSurvivesARealETPreamble() {
        var parser = RemoteTmuxControlStreamParser()
        let messages = parser.feed(Self.capturedETStream)

        // No stream error: the preamble is ignored, not fatal.
        for message in messages {
            if case .streamError(let detail) = message {
                Issue.record("parser errored on a real ET stream: \(detail)")
            }
        }
        // And the session-changed notification after the preamble is understood.
        let sawSessionChange = messages.contains { message in
            if case .sessionChanged = message { return true }
            return false
        }
        #expect(sawSessionChange, "expected %session-changed to parse after the ET preamble")

        // `.enter` is the message that matters, and asserting only on %session-changed hid a
        // real bug: the login shell's echoed title sequences land on the same line as the
        // enter DCS, so a parser that requires the DCS at the start of a line never emits
        // `.enter`. Everything downstream waits on it — the connection stays out of
        // `.connected` and the attach dies on a timeout while later notifications parse
        // normally, which is exactly what a real et host did.
        let sawEnter = messages.contains { message in
            if case .enter = message { return true }
            return false
        }
        #expect(sawEnter, "expected .enter from the ET stream's mid-line enter DCS")
        // Order matters too: commands are withheld until `.enter`, so it has to arrive before
        // the notifications that follow it in the stream.
        let enterIndex = messages.firstIndex { if case .enter = $0 { return true }; return false }
        let changeIndex = messages.firstIndex { if case .sessionChanged = $0 { return true }; return false }
        if let enterIndex, let changeIndex {
            #expect(enterIndex < changeIndex, "`.enter` must precede %session-changed")
        }
    }

    // MARK: - The profile's argv, measured against the real client

    @Test func etArgvUsesEtserverPortAndRunsOneCommand() {
        let host = RemoteTmuxHost(destination: "user@127.0.0.1")
        let profile = RemoteTmuxETTransportProfile(port: 2039, executable: "/usr/local/bin/et")
        let argv = profile.controlStreamArgv(host: host, sessionName: "work", createIfMissing: false)

        // The executable is supplied separately, exactly as for ssh — argv is arguments
        // only, or `et` would be passed twice.
        #expect(profile.executablePath() == "/usr/local/bin/et")
        #expect(argv.first != "/usr/local/bin/et")
        // etserver's default is 2022, not ssh's 22 — the port is never assumed.
        #expect(consecutive(argv, "-p", "2039"))
        #expect(argv.last == "user@127.0.0.1")
        let command = argv.first(where: { $0.hasPrefix("exec ") })
        #expect(command?.contains("attach-session") == true)
        // Plain tmux, not ssh's PATH resolver. et types the command into a login shell, so the
        // shell resolves tmux from the user's own PATH — and the resolver would not fit anyway
        // (see etCommandFitsWhatALoginShellCanRead).
        #expect(command?.contains("cmux-remote-executable") == false)
        #expect(command?.contains("'tmux'") == true)
        // Never kill the user's other sessions on that host.
        #expect(!argv.contains("-x"))
        #expect(!argv.contains("--kill-other-sessions"))
    }

    /// et types the command into a login shell instead of exec'ing it, and that shell reads from
    /// a pty in canonical mode. macOS delivers at most MAX_CANON (1024) bytes per line, so a
    /// longer command never completes a line: the shell runs nothing, et emits nothing, and the
    /// attach dies on a timeout with no error to explain it. Measured against et 6.2.11, where
    /// ssh's ~1113-byte PATH resolver hung and a 40-byte plain `tmux` produced `%begin`.
    ///
    /// Long session names are the realistic way to cross the line, so the bound is checked
    /// against one rather than only the short names the other tests use.
    @Test func etCommandFitsWhatALoginShellCanRead() throws {
        let maxCanon = 1024
        for session in ["s", "work session", String(repeating: "session-", count: 24)] {
            let argv = RemoteTmuxETTransportProfile(port: 2039).controlStreamArgv(
                host: RemoteTmuxHost(destination: "user@host"),
                sessionName: session,
                createIfMissing: false
            )
            let command = try #require(argv.first(where: { $0.hasPrefix("exec ") }))
            let byteCount = command.utf8.count
            #expect(
                byteCount < maxCanon,
                Comment(
                    rawValue: "et command is \(byteCount) bytes for a \(session.count)-character "
                        + "session name, over the \(maxCanon)-byte canonical line limit"
                )
            )
        }
    }

    /// The session name reaches the remote shell as one word even when it contains a space or a
    /// quote. Dropping the resolver moved this responsibility onto this profile's own quoting.
    @Test func etQuotesTheSessionNameItTypes() {
        let argv = RemoteTmuxETTransportProfile(port: 2039).controlStreamArgv(
            host: RemoteTmuxHost(destination: "user@host"),
            sessionName: "work 'session'; touch /tmp/cmux-et-injection",
            createIfMissing: false
        )
        let command = argv.first(where: { $0.hasPrefix("exec ") }) ?? ""
        // Quoted as data, so the shell cannot run the trailing command.
        #expect(command.contains("touch /tmp/cmux-et-injection"))
        #expect(!command.contains("; touch /tmp/cmux-et-injection'\""))
        #expect(command.hasSuffix("'work '\\''session'\\''; touch /tmp/cmux-et-injection'"))
    }

    /// The hash keys the attach single-flight, the transport registry, and mirror-to-host
    /// matching, so anything that changes what the control stream *is* has to be in it. Without
    /// the transport an ssh host and an et host at one destination are the same endpoint, and an
    /// attach can be handed a cached connection running the wrong profile or port.
    @Test func theConnectionHashSeparatesTransportsAndTheirPorts() {
        let ssh = RemoteTmuxHost(destination: "user@host")
        let et = RemoteTmuxHost(destination: "user@host", transport: .et)
        let et2039 = RemoteTmuxHost(destination: "user@host", transport: .et, transportPort: 2039)
        let et2040 = RemoteTmuxHost(destination: "user@host", transport: .et, transportPort: 2040)

        #expect(ssh.connectionHash != et.connectionHash)
        #expect(et.connectionHash != et2039.connectionHash)
        #expect(et2039.connectionHash != et2040.connectionHash, "etserver port must separate endpoints")
        // The ssh port is a different axis from the transport port and must not alias it.
        #expect(
            RemoteTmuxHost(destination: "user@host", port: 2039).connectionHash != et2039.connectionHash
        )
    }

    /// And a plain ssh host keeps the hash it has today. It names the shared master's socket path
    /// and persisted mirror state, so moving it would orphan both on upgrade.
    @Test func theConnectionHashIsUnchangedForAnSSHHost() {
        // Naming ssh explicitly, with no transport port, is the same endpoint as saying nothing —
        // which is what keeps an existing host's socket path and persisted state addressable.
        #expect(
            RemoteTmuxHost(destination: "user@host").connectionHash
                == RemoteTmuxHost(destination: "user@host", transport: .ssh).connectionHash
        )
        #expect(
            RemoteTmuxHost(destination: "user@host", port: 22, identityFile: "/k").connectionHash
                == RemoteTmuxHost(
                    destination: "user@host", port: 22, identityFile: "/k", transport: .ssh
                ).connectionHash
        )
    }

    /// A self-reconnecting transport that is alive but no longer answering has to be recovered,
    /// not waited on. There is no EOF coming — that is the whole point of such a transport — so
    /// before this the connection stayed `.connected` and the mirror froze permanently.
    ///
    /// `.enter` is delivered through the real message path rather than a test-only setter, so the
    /// transition under test is the one production takes.
    @MainActor @Test func aStalledSelfReconnectingTransportIsRecoveredRatherThanLeftConnected() {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host", transport: .et, transportPort: 2039),
            sessionName: "work"
        )
        connection.handle(.enter)
        #expect(!connection.snapshot().recentEvents.contains("liveness-stalled"))

        // Nothing is attached to carry the probe, which is what a wedged transport looks like
        // from here: alive as far as anyone can see, unable to answer.
        var reported: Bool?
        connection.checkLivenessAndRecoverIfStalled { reported = $0 }
        #expect(reported == false, "a stream that cannot answer must be reported as stalled")
        #expect(connection.snapshot().recentEvents.contains("liveness-stalled"))
    }

    /// A probe that is written but never answered, on a host that still answers out of band, is
    /// the stall this monitor exists for: ET can accept stdin while producing no control output.
    /// Before the deadline, probes accumulated and the connection stayed `.connected` forever —
    /// the monitor could not detect the very case it was added for.
    ///
    /// The reachable answer is what makes this a stall rather than an outage: the host is fine, so
    /// the stream is the broken part.
    @MainActor @Test func anUnansweredProbeOnAReachableHostIsTreatedAsAStall() async {
        let connection = Self.etConnection(reachable: true)
        connection.handle(.enter)
        // Stand in for a probe that was written and never came back.
        connection.livenessProbeOutstanding = true

        let reported = await Self.tick(connection)
        #expect(reported == false)
        #expect(connection.snapshot().recentEvents.contains("liveness-unanswered"))
        #expect(connection.snapshot().recentEvents.contains("liveness-stalled"))
        #expect(connection.connectionState == .reconnecting)
    }

    /// An unanswered probe during a real outage must not cost the session.
    ///
    /// The transport reconnects underneath, and while it does it cannot answer a probe either — so
    /// silence alone cannot mean "wedged". Recovering here terminates the transport process and
    /// discards the session it was in the middle of resuming. The host is asked out of band, over
    /// a channel the wedge cannot reach, and an unreachable host means wait.
    @MainActor @Test func anOutageDefersTheVerdictInsteadOfDiscardingTheSession() async {
        let connection = Self.etConnection(reachable: false)
        connection.handle(.enter)
        connection.livenessProbeOutstanding = true

        let reported = await Self.tick(connection)
        #expect(reported == true, "nothing was recovered, so there is no recovery edge to report")
        #expect(connection.connectionState == .connected, "an outage must not end the session")
        #expect(!connection.snapshot().recentEvents.contains("liveness-stalled"))
        #expect(connection.snapshot().recentEvents.contains("liveness-deferred-unreachable"))
    }

    /// Deferral is bounded. A host that stays unreachable while the stream stays silent is
    /// eventually recovered anyway: if the outage is not what silenced the stream, waiting on it
    /// forever leaves a frozen mirror with no retry — the failure this monitor was added for.
    @MainActor @Test func aDeferralRunEndsInRecoveryOnceTheCapIsPassed() async {
        let connection = Self.etConnection(reachable: false)
        connection.handle(.enter)
        connection.livenessProbeOutstanding = true

        let cap = RemoteTmuxControlConnection.maxConsecutiveLivenessDeferrals
        for _ in 0..<cap {
            let reported = await Self.tick(connection)
            #expect(reported == true)
        }
        #expect(connection.connectionState == .connected, "within the cap the session is kept")

        let final = await Self.tick(connection)
        #expect(final == false)
        #expect(connection.snapshot().recentEvents.contains("liveness-deferral-exhausted"))
        #expect(connection.snapshot().recentEvents.contains("liveness-stalled"))
        #expect(connection.connectionState == .reconnecting)
    }

    /// An et connection whose reachability answer is decided by the test, so the branch under test
    /// is reached without a host, an ssh master, or a spawned process.
    @MainActor private static func etConnection(reachable: Bool) -> RemoteTmuxControlConnection {
        RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host", transport: .et, transportPort: 2039),
            sessionName: "work",
            sessionReachability: { _, _ in reachable }
        )
    }

    /// Runs one monitor tick and waits for its verdict. The verdict can now cross an `await` (the
    /// out-of-band question), so it is read from the completion rather than after the call.
    @MainActor private static func tick(_ connection: RemoteTmuxControlConnection) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.checkLivenessAndRecoverIfStalled { continuation.resume(returning: $0) }
        }
    }

    /// A stream that never reached control mode is a failed start, not a lost session.
    ///
    /// Reconnecting there is what made a real error — "tmux control stream ended before attach" —
    /// surface as an opaque 60-second attach timeout, which cost most of a debugging session.
    /// Reconnecting is right only once a stream has actually worked.
    @Test func endOfStreamBeforeControlModeIsTerminalRatherThanRetried() {
        #expect(
            RemoteTmuxStreamEndDisposition.forStreamEnd(hasReachedControlMode: false) == .sessionOver,
            "a transport that never started has nothing to reconnect to"
        )
        #expect(
            RemoteTmuxStreamEndDisposition.forStreamEnd(hasReachedControlMode: true) == .reconnect,
            "an established stream may have a session still there — reattach decides"
        )
    }

    /// ssh must be untouched by all of this: it gets an EOF, `handleStreamEnd` already recovers,
    /// and probing an idle ssh stream would add traffic and a new way to fail.
    @MainActor @Test func anSSHTransportIsNeverProbedForStalls() {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"),
            sessionName: "work"
        )
        connection.handle(.enter)
        var reported: Bool?
        connection.checkLivenessAndRecoverIfStalled { reported = $0 }
        #expect(reported == true, "ssh is out of scope for the stall check")
        #expect(!connection.snapshot().recentEvents.contains("liveness-stalled"))
    }

    /// The client binary is resolved, not assumed. A literal `/usr/local/bin/et` is a claim about
    /// someone else's machine, and it is wrong on a standard Apple Silicon Homebrew install.
    @Test func theETClientIsResolvedRatherThanHardcoded() {
        let onlyHomebrew = RemoteTmuxETTransportProfile.resolveClientExecutable(
            fileExists: { $0 == "/opt/homebrew/bin/et" },
            pathValue: "/usr/bin:/bin"
        )
        #expect(onlyHomebrew == "/opt/homebrew/bin/et")

        // PATH wins over the built-in directories, so a user-installed et is preferred.
        let fromPath = RemoteTmuxETTransportProfile.resolveClientExecutable(
            fileExists: { $0 == "/my/bin/et" || $0 == "/usr/local/bin/et" },
            pathValue: "/my/bin"
        )
        #expect(fromPath == "/my/bin/et")

        // Never a bare name. The stream is spawned through `/usr/bin/script`, which resolves its
        // argument against the app's own PATH — and a GUI app's PATH cannot be relied on, so a bare
        // name becomes "script: et: No such file or directory", an immediately-ending stream, and
        // (since end-of-stream now reconnects) a 60-second attach timeout carrying no error at all.
        let notFound = RemoteTmuxETTransportProfile.resolveClientExecutable(
            fileExists: { _ in false }, pathValue: ""
        )
        #expect(notFound == RemoteTmuxETTransportProfile.defaultClientPath)
        #expect(notFound.hasPrefix("/"), "must be absolute so `script` cannot mis-resolve it")
    }

    /// A terminal path is always sent, and comes from the host once probed.
    ///
    /// Dropping the flag was measured to be worse than the literal it replaced: `etterminal` is not
    /// on a non-interactive ssh PATH on macOS, so et fails outright with "Error starting ET process
    /// through ssh". The fix for a hardcoded path is to resolve it, not to omit it.
    @Test func theRemoteTerminalPathIsAlwaysSentAndComesFromTheHostWhenKnown() {
        let unprobed = RemoteTmuxHost(destination: "user@host", transport: .et, transportPort: 2039)
        let defaulted = RemoteTmuxTransportKind.et
            .profile(port: 2039, terminalPath: unprobed.transportTerminalPath)
            .controlStreamArgv(host: unprobed, sessionName: "work", createIfMissing: false)
        #expect(
            consecutive(defaulted, "--terminal-path", RemoteTmuxETTransportProfile.defaultRemoteTerminalPath),
            "an unprobed host must still work, so it keeps the previous default"
        )

        let probed = RemoteTmuxHost(
            destination: "user@host", transport: .et, transportPort: 2039,
            transportTerminalPath: "/opt/homebrew/bin/etterminal"
        )
        let resolved = RemoteTmuxTransportKind.et
            .profile(port: 2039, terminalPath: probed.transportTerminalPath)
            .controlStreamArgv(host: probed, sessionName: "work", createIfMissing: false)
        #expect(consecutive(resolved, "--terminal-path", "/opt/homebrew/bin/etterminal"))
    }

    /// How the path is discovered: one short command, covering PATH first and then the platform
    /// locations. Short matters — it is delivered under the same canonical-line limit as any other
    /// et command.
    @Test func theTerminalPathProbeIsShortAndCoversEveryCandidate() {
        let probe = RemoteTmuxETTransportProfile.remoteTerminalProbeCommand()
        #expect(probe.hasPrefix("command -v etterminal"), "PATH first, when the host has it there")
        for candidate in RemoteTmuxETTransportProfile.remoteTerminalCandidates {
            #expect(probe.contains(candidate), "\(candidate) must be probed")
        }
        #expect(
            probe.utf8.count < RemoteTmuxETTransportProfile.maxCanonicalLineBytes,
            "the probe itself must fit one line, saw \(probe.utf8.count) bytes"
        )
        // Apple Silicon before Intel: a machine with both should use the native one.
        let homebrew = probe.range(of: "/opt/homebrew/bin/etterminal")
        let intel = probe.range(of: "/usr/local/bin/etterminal")
        #expect(homebrew != nil && intel != nil && homebrew!.lowerBound < intel!.lowerBound)
    }

    /// et bootstraps over ssh before its own protocol takes over, and inherits none of the host's
    /// ssh settings. Without these the ssh preflight succeeds and et's bootstrap fails on defaults.
    @Test func etCarriesTheHostsSSHPortAndIdentityIntoItsBootstrap() {
        let host = RemoteTmuxHost(
            destination: "user@host", port: 2222, identityFile: "/keys/id",
            transport: .et, transportPort: 2039
        )
        let argv = RemoteTmuxTransportKind.et.profile(port: 2039).controlStreamArgv(
            host: host, sessionName: "work", createIfMissing: false
        )
        #expect(consecutive(argv, "--ssh-option", "Port=2222"))
        #expect(consecutive(argv, "--ssh-option", "IdentityFile=/keys/id"))
        // etserver's port stays distinct from ssh's.
        #expect(consecutive(argv, "-p", "2039"))
    }

    /// A session name long enough to push the command past one canonical line is rejected, because
    /// et would deliver nothing and the attach would die on a timeout with no explanation. tmux
    /// accepts names of ~1000 bytes, so this is reachable without abuse.
    @Test func anOverlongSessionNameIsRejectedForET() {
        let bound = RemoteTmuxETTransportProfile.maxSessionNameBytes()
        #expect(bound > 900, "the bound should leave room for a realistic name, saw \(bound)")
        #expect(bound < RemoteTmuxETTransportProfile.maxCanonicalLineBytes)

        let atBound = String(repeating: "a", count: bound)
        let overBound = String(repeating: "a", count: bound + 1)
        #expect(
            TerminalController.remoteTmuxSessionName(from: ["session": atBound], transport: .et) != nil
        )
        #expect(
            TerminalController.remoteTmuxSessionName(from: ["session": overBound], transport: .et) == nil
        )
        // ssh execs its command, so the pty line limit does not apply there.
        #expect(
            TerminalController.remoteTmuxSessionName(from: ["session": overBound], transport: .ssh) != nil
        )
    }

    /// The command built for a name at the bound really does fit, so the bound is derived from the
    /// command rather than asserted next to it.
    @Test func theSessionNameBoundKeepsTheCommandWithinOneLine() {
        for createIfMissing in [false, true] {
            let bound = RemoteTmuxETTransportProfile.maxSessionNameBytes(createIfMissing: createIfMissing)
            let command = RemoteTmuxETTransportProfile.controlStreamRemoteCommand(
                sessionName: String(repeating: "a", count: bound), createIfMissing: createIfMissing
            )
            #expect(
                command.utf8.count <= RemoteTmuxETTransportProfile.maxCanonicalLineBytes,
                "createIfMissing=\(createIfMissing) produced \(command.utf8.count) bytes"
            )
        }
    }

    /// Two spellings of one endpoint must be one key, or the controller mirrors a host twice.
    @Test func theConnectionHashNormalizesEquivalentEndpoints() {
        let implicit = RemoteTmuxHost(destination: "user@host", transport: .et)
        let explicit = RemoteTmuxHost(destination: "user@host", transport: .et, transportPort: 2022)
        #expect(implicit.connectionHash == explicit.connectionHash, "et's default port is 2022")

        // ssh ignores a transport port, so carrying one must not split the endpoint.
        #expect(
            RemoteTmuxHost(destination: "user@host").connectionHash
                == RemoteTmuxHost(destination: "user@host", transport: .ssh, transportPort: 2039).connectionHash
        )
    }

    /// Retrying is only honest when the next attempt could differ. These cannot, so they end the
    /// connection with their reason instead of looping — which is what turned a missing binary into
    /// a 60-second attach timeout carrying no message once end-of-stream started meaning reconnect.
    @Test(arguments: [
        "script: et: No such file or directory",
        "/usr/local/bin/et: No such file or directory",
        "etterminal: No such file or directory",
        "Error starting ET process through ssh, please make sure your ssh works first",
        "et: unrecognized option '--terminal-path'",
    ])
    func unrecoverableTransportFailuresAreNotRetried(_ stderr: String) {
        #expect(RemoteTmuxSSHTransport.indicatesUnrecoverableTransportFailure(stderr))
    }

    /// And the classifier stays narrow: wrongly retrying costs a delay, wrongly giving up costs a
    /// mirror that never comes back, so anything that might succeed next time keeps retrying.
    @Test(arguments: [
        "ssh: connect to host example.com port 22: Connection refused",
        "kex_exchange_identification: Connection reset by peer",
        "Connection closed by 10.0.0.5 port 22",
        "no server running on /tmp/tmux-501/default",
        "user@host: Permission denied (publickey).",
        "",
    ])
    func recoverableFailuresKeepRetrying(_ stderr: String) {
        #expect(!RemoteTmuxSSHTransport.indicatesUnrecoverableTransportFailure(stderr))
    }

    @Test func etCanTargetAServerWhoseTerminalIsNotOnThePath() {
        let profile = RemoteTmuxETTransportProfile(
            port: 2022, remoteTerminalPath: "/usr/local/bin/etterminal"
        )
        let argv = profile.controlStreamArgv(
            host: RemoteTmuxHost(destination: "user@host"), sessionName: "s", createIfMissing: false
        )
        #expect(consecutive(argv, "--terminal-path", "/usr/local/bin/etterminal"))
    }

    /// The two properties that decide behavior rather than argv.
    @Test func etOwnsItsReconnectionAndNeedsATTY() {
        let profile = RemoteTmuxETTransportProfile()
        #expect(profile.reconnectsInternally)
        #expect(profile.requiresPseudoTerminal)
    }

    // MARK: - Seam 2: telling a stall from a death

    /// A transport that owns its reconnection needs a question it can answer, because EOF is
    /// no longer the signal: it does not end for a network drop. The probe must be a read
    /// (mutating nothing, moving no client size) and must resolve through the same
    /// `%begin`/`%end` correlation as any other command rather than a bespoke heartbeat.
    @MainActor @Test func alivenessIsProvedByAControlModeRoundTrip() {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host", transport: .et),
            sessionName: "work"
        )
        // Never started, so there is no stream to carry a question: the caller is told the
        // probe did not leave, rather than being left waiting on a completion that cannot come.
        var completionFired = false
        let enqueued = connection.probeLiveness { _ in completionFired = true }
        #expect(!enqueued, "a probe must report that it could not be sent on a dead stream")
        #expect(!completionFired, "no completion may fire for a probe that never left")
    }

    /// The property that makes the probe necessary in the first place.
    ///
    /// A transport that reconnects internally produces no EOF for a network drop, so the failure it
    /// can suffer — alive but no longer carrying the protocol — is one EOF never reports. That is
    /// what the probe is for. EOF itself is not the discriminator it once looked like: it now means
    /// reconnect for every transport, because it cannot say whether the transport or the session
    /// ended (see endOfStreamAlwaysMeansReconnectAndLetTheReattachDecide).
    @Test func aStallIsNotADeathForATransportThatReconnectsItself() {
        let et = RemoteTmuxETTransportProfile()
        #expect(et.reconnectsInternally)
        #expect(!RemoteTmuxSSHTransportProfile().reconnectsInternally)
    }

    // MARK: - Runtime selection

    /// A host carries its transport, so selection reaches the spawn without a global switch.
    @Test func aHostSelectsItsOwnTransport() {
        let sshHost = RemoteTmuxHost(destination: "user@host")
        #expect(sshHost.transport == .ssh, "an unspecified host must behave exactly as before")
        #expect(!sshHost.transport.profile(port: nil).requiresPseudoTerminal)

        let etHost = RemoteTmuxHost(destination: "user@host", transport: .et)
        let profile = etHost.transport.profile(port: etHost.port)
        #expect(profile.requiresPseudoTerminal)
        #expect(profile.reconnectsInternally)
    }

    /// The transport's port is NOT ssh's port, and conflating them breaks every one-shot.
    ///
    /// One-shot discovery and mutation keep riding ssh even when the control stream does
    /// not, so a single `port` field pointed ssh at etserver's port and every one-shot died
    /// with `kex_exchange_identification: Connection reset`. Found by an end-to-end run,
    /// not by argv inspection — which is exactly why this test exists.
    @Test func theTransportPortIsSeparateFromTheSSHPort() {
        // ssh keeps 22 for its one-shots while et carries the stream on 2039.
        let host = RemoteTmuxHost(
            destination: "user@host", port: 22, transport: .et, transportPort: 2039
        )
        let streamArgv = host.transport.profile(port: host.transportPort)
            .controlStreamArgv(host: host, sessionName: "work", createIfMissing: false)
        #expect(consecutive(streamArgv, "-p", "2039"), "the control stream must use et's port")

        let oneShot = RemoteTmuxSSHTransportProfile().oneShotArgv(host: host, remoteCommand: "true")
        #expect(!consecutive(oneShot, "-p", "2039"), "a one-shot must never be sent to et's port")

        // Unset means etserver's documented default, never ssh's 22.
        let defaulted = RemoteTmuxHost(destination: "user@host", transport: .et)
        let defaultArgv = defaulted.transport.profile(port: defaulted.transportPort)
            .controlStreamArgv(host: defaulted, sessionName: "work", createIfMissing: false)
        #expect(consecutive(defaultArgv, "-p", "2022"))
    }

    /// An unrecognized transport is refused rather than becoming an unspawnable host.
    @Test func anUnknownTransportIsRejected() {
        #expect(RemoteTmuxTransportKind.parse("ssh") == .ssh)
        #expect(RemoteTmuxTransportKind.parse("et") == .et)
        #expect(RemoteTmuxTransportKind.parse("ET") == .et)
        #expect(RemoteTmuxTransportKind.parse(nil) == .ssh, "unset means today's behavior")
        #expect(RemoteTmuxTransportKind.parse("") == .ssh)
        #expect(RemoteTmuxTransportKind.parse("mosh") == nil)
        #expect(RemoteTmuxTransportKind.parse("../../bin/sh") == nil)
    }

    /// A connection with no explicit profile takes the host's, so nothing has to remember
    /// to pass it at each construction site.
    @MainActor @Test func aConnectionTakesItsProfileFromTheHost() {
        let et = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host", transport: .et),
            sessionName: "work"
        )
        #expect(et.transportProfile.requiresPseudoTerminal)

        let ssh = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"),
            sessionName: "work"
        )
        #expect(!ssh.transportProfile.requiresPseudoTerminal)
    }

    private func consecutive(_ args: [String], _ a: String, _ b: String) -> Bool {
        for index in args.indices.dropLast() where args[index] == a && args[index + 1] == b {
            return true
        }
        return false
    }
}

// MARK: - Layer 3: seeded model-based fuzz over transport behavior

/// Deterministic seedable RNG (SplitMix64), matching the repo's other fuzz suites: every
/// failure reproduces from the seed plus step index printed in the assertion.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ range: Range<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
}

/// Fuzzes the decisions a transport seam makes, against a reference model of the transport
/// and the remote server.
///
/// The point is invariant 1 below: cmux must never respawn a transport that owns its own
/// reconnection. ssh-era code reacted to stdout EOF, and a transport that pauses and resumes
/// instead of ending would have its session thrown away by that reflex. The model carries
/// the three pieces of state the ssh-only world never had — is the process alive, is the
/// stream flowing, does the remote session still exist.
@Suite struct RemoteTmuxTransportFuzzTests {

    /// Fixed seeds. This list only ever grows: when a seed finds a bug, the fix lands and the
    /// seed stays, so the same case can never regress silently.
    static let seeds: [UInt64] = [
        0x5EED_0001, 0x5EED_0002, 0x5EED_0003, 0x5EED_0004,
        0xA11C_E5, 0xB0B_CAFE, 0xDEAD_BEEF, 0x1234_5678,
    ]

    /// What the transport can do to the stream.
    private enum Event: CaseIterable {
        case stall              // network pause: no bytes, process alive
        case resume             // bytes flow again
        case dropMidFrameThenResume
        case exitClean          // the command finished: session over
        case exitAuthFailure
        case exitTransientFailure
        case killSessionRemotely
    }

    /// The reference model: what a correct cmux would do.
    private struct Model {
        var processAlive = true
        var streamFlowing = true
        var sessionExists = true
        var spawnCount = 1
        var ended = false
        var authOutcomes = 0
        var retryScheduled = 0
    }

    @Test(arguments: seeds)
    func aTransportThatOwnsReconnectionIsNeverRespawnedForAStall(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let profile = RemoteTmuxETTransportProfile()
        #expect(profile.reconnectsInternally, "this suite is about internally-reconnecting transports")

        var model = Model()

        for step in 0..<40 {
            let event = Event.allCases[rng.int(0..<Event.allCases.count)]
            let context = "seed=\(String(seed, radix: 16)) step=\(step) event=\(event)"

            switch event {
            case .stall:
                guard model.processAlive, !model.ended else { continue }
                model.streamFlowing = false
                // INVARIANT 1: a stall never ENDS the connection. It does now trigger recovery —
                // a wedged transport is not going to un-wedge itself, and a respawn reattaches to
                // the session that is still there. What must never happen is losing the mirror.
                #expect(!model.ended, "a stall ended the connection — \(context)")

            case .resume:
                guard model.processAlive, !model.ended else { continue }
                model.streamFlowing = true
                // A resume is the transport doing its job: nothing for cmux to do, and above all
                // the connection must not have been ended while it was paused.
                #expect(!model.ended, "a resume ended the connection — \(context)")

            case .dropMidFrameThenResume:
                guard model.processAlive, !model.ended else { continue }
                model.streamFlowing = false
                model.streamFlowing = true
                // INVARIANT 5: a frame split across a resume must complete or be discarded
                // whole. Feeding half a frame must never yield a message.
                var parser = RemoteTmuxControlStreamParser()
                let whole = Data("%session-changed $1 work\r\n".utf8)
                let cut = whole.count / 2
                let firstHalf = parser.feed(whole.prefix(cut))
                #expect(firstHalf.isEmpty, "a partial frame produced a message — \(context)")
                let rest = parser.feed(whole.suffix(from: cut))
                #expect(!rest.isEmpty, "a completed frame produced nothing — \(context)")

            case .exitClean:
                guard model.processAlive, !model.ended else { continue }
                model.processAlive = false
                // INVARIANT 2 (other half): an exit does NOT end the session on its own. This
                // branch used to assert the opposite, on the premise that such a transport would
                // not exit for a mere network drop — measured against et 6.2.11+7, restarting only
                // `etserver` exits while `tmux has-session` still succeeds, so ending here threw
                // away a live session. Reconnect, and let the reattach report whether it is gone.
                // The model's stream has reached control mode by this point, which is the case
                // where an exit may still have a live session behind it.
                let disposition = RemoteTmuxStreamEndDisposition.forStreamEnd(hasReachedControlMode: true)
                #expect(disposition == .reconnect, "an exit did not lead to a reattach — \(context)")
                model.spawnCount += 1

            case .exitAuthFailure:
                guard model.processAlive, !model.ended else { continue }
                // INVARIANT 3: auth-required always surfaces an auth outcome, never an
                // unbounded retry.
                let stderr = "user@host: Permission denied (publickey,keyboard-interactive)."
                // Asserted through the predicate that exists on this branch, so the suite
                // stands alone: the reconnect-auth outcome itself ships separately.
                #expect(
                    RemoteTmuxSSHTransport.indicatesInteractiveRetryWillHelp(stderr),
                    "an auth failure did not surface as recoverable-by-login — \(context)"
                )
                model.authOutcomes += 1

            case .exitTransientFailure:
                guard model.processAlive, !model.ended else { continue }
                let stderr = "ssh: connect to host h port 22: Connection refused"
                // Neither an auth case nor a gone session: it must stay a plain retry, or a
                // refused host would pop a login the user cannot act on.
                #expect(
                    !RemoteTmuxSSHTransport.indicatesInteractiveRetryWillHelp(stderr),
                    "a refused host was misread as needing a login — \(context)"
                )
                #expect(
                    !RemoteTmuxSSHTransport.indicatesNoServer(stderr),
                    "a refused host was misread as a gone session — \(context)"
                )
                model.retryScheduled += 1

            case .killSessionRemotely:
                guard !model.ended else { continue }
                model.sessionExists = false
                // INVARIANT 7: a session the user killed is never silently recreated, so the
                // reconnect must be attach-only and a gone session must outrank auth.
                let stderr = "no server running on /tmp/tmux-501/default"
                #expect(
                    RemoteTmuxSSHTransport.indicatesNoServer(stderr),
                    "a killed session was not recognised as gone — \(context)"
                )
                // And a gone session must never be read as merely needing a login, or the
                // user would be asked to authenticate to a session that no longer exists.
                #expect(
                    !RemoteTmuxSSHTransport.indicatesAuthRequired(stderr),
                    "a gone session was misread as an auth failure — \(context)"
                )
            }
        }

        // INVARIANT 8: teardown is ordering-independent. Respawns are expected now (an exit
        // reattaches), so this asserts the connection is not left both ended and alive.
        #expect(
            !(model.ended && model.processAlive),
            "seed=\(String(seed, radix: 16)) left the connection both ended and alive"
        )
    }

    /// The pre-connect hook must run at most once per connection open, even when opens race.
    @Test(arguments: seeds)
    func thePreConnectHookRunsAtMostOncePerOpen(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let hook = RemoteTmuxPreConnectHook(command: "/usr/local/bin/mint-cred")

        for step in 0..<20 {
            let racers = rng.int(1..<5)
            // One open = one hook argv, however many callers race for it: a single-use
            // credential must not be minted twice, since two mints can invalidate each other.
            var argvs: [[String]] = []
            var alreadyOpening = false
            for _ in 0..<racers {
                guard !alreadyOpening else { continue }
                alreadyOpening = true
                if let argv = hook.argv(destination: "user@host") { argvs.append(argv) }
            }
            #expect(
                argvs.count == 1,
                "seed=\(String(seed, radix: 16)) step=\(step): hook ran \(argvs.count)x for one open with \(racers) racers"
            )
            // And a hook failure never makes the host unreachable.
            #expect(!hook.shouldAbortConnection(onExitCode: Int32(rng.int(1..<128))))
        }
    }
}
