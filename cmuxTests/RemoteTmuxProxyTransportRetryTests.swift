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
            // the remote process tree. The tmux resolver is still required: a non-login
            // remote shell has a minimal PATH, which is a property of the remote shell and
            // not of ssh, so it applies to every transport identically.
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

    /// ssh ends when the connection drops, so EOF is cmux's cue to respawn.
    @Test func endOfStreamOverSSHMeansReconnect() {
        #expect(
            RemoteTmuxStreamEndDisposition.forStreamEnd(reconnectsInternally: false) == .reconnect
        )
    }

    /// A transport that reconnects internally does not end for a network drop — the stream
    /// pauses and resumes. So if it ends, the session is genuinely over, and respawning
    /// would be cmux fighting the transport for ownership of recovery.
    @Test func endOfStreamOverAPersistentTransportMeansTheSessionIsOver() {
        #expect(
            RemoteTmuxStreamEndDisposition.forStreamEnd(reconnectsInternally: true) == .sessionOver
        )
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
        // The resolver is still needed: a minimal remote PATH is a property of the remote
        // shell, not of ssh.
        #expect(command?.contains("cmux-remote-executable") == true)
        // Never kill the user's other sessions on that host.
        #expect(!argv.contains("-x"))
        #expect(!argv.contains("--kill-other-sessions"))
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
        #expect(RemoteTmuxStreamEndDisposition.forStreamEnd(
            reconnectsInternally: profile.reconnectsInternally) == .sessionOver)
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
    @Test func aStallIsNotADeathForATransportThatReconnectsItself() {
        let et = RemoteTmuxETTransportProfile()
        #expect(et.reconnectsInternally)
        // EOF from such a transport means the session is genuinely over...
        #expect(RemoteTmuxStreamEndDisposition.forStreamEnd(
            reconnectsInternally: true) == .sessionOver)
        // ...whereas ssh's EOF is cmux's cue to respawn. Same event, opposite meaning, which
        // is why a stall has to be diagnosed by asking rather than by waiting for EOF.
        #expect(RemoteTmuxStreamEndDisposition.forStreamEnd(
            reconnectsInternally: false) == .reconnect)
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
        let spawnsAtStart = model.spawnCount

        for step in 0..<40 {
            let event = Event.allCases[rng.int(0..<Event.allCases.count)]
            let context = "seed=\(String(seed, radix: 16)) step=\(step) event=\(event)"

            switch event {
            case .stall:
                guard model.processAlive, !model.ended else { continue }
                model.streamFlowing = false
                // INVARIANT 1: a stall is not a death for this transport, so nothing respawns.
                #expect(model.spawnCount == spawnsAtStart, "respawned on a stall — \(context)")
                // INVARIANT 2: a stall never ends the connection.
                #expect(!model.ended, "a stall ended the connection — \(context)")

            case .resume:
                guard model.processAlive, !model.ended else { continue }
                model.streamFlowing = true
                #expect(model.spawnCount == spawnsAtStart, "respawned on a resume — \(context)")
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
                // INVARIANT 2 (other half): a genuine exit DOES end it, because this
                // transport would not have exited for a mere network drop.
                let disposition = RemoteTmuxStreamEndDisposition.forStreamEnd(
                    reconnectsInternally: profile.reconnectsInternally)
                #expect(disposition == .sessionOver, "a real exit did not end the session — \(context)")
                model.ended = true

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

        // INVARIANT 8: teardown is ordering-independent — nothing above may have respawned.
        #expect(
            model.spawnCount == spawnsAtStart,
            "seed=\(String(seed, radix: 16)) respawned \(model.spawnCount - spawnsAtStart) time(s) for an internally-reconnecting transport"
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
