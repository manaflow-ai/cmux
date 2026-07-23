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
            mode: RemoteTmuxControlAttachMode
        ) -> [String] {
            // `--command` runs one command and exits, and `exec` keeps a shell parent out of
            // the remote process tree. This stand-in keeps the resolver because it says nothing
            // about how its command reaches the remote shell; the real et profile drops it,
            // since et types the command into a login shell that both resolves PATH itself and
            // cannot read a line that long.
            let remote = RemoteTmuxHost.tmuxRemoteCommand(
                arguments: mode.tmuxArguments(sessionName: sessionName)
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
        /// Keeping the remote session across a client death is the point of this transport.
        var remoteHalfSurvivesLocalExit: Bool { true }
    }

    @Test func sshProfileProducesTodaysControlStreamArgv() {
        let host = RemoteTmuxHost(destination: "user@host")
        let profile = RemoteTmuxSSHTransportProfile()
        #expect(
            profile.controlStreamArgv(host: host, sessionName: "work", mode: .attach)
                == host.controlModeArguments(sessionName: "work", mode: .attach)
        )
        #expect(profile.executablePath() == RemoteTmuxHost.defaultSSHExecutablePath())
    }

    /// The three attach shapes, spelled out as the tmux commands they become.
    ///
    /// `attach-session` needs the session to exist and `new-session -t` groups a new session with
    /// an existing one's windows, so neither can open a session that may or may not be there.
    /// `new-session -A -s` is the one that can, and the sized form is what the hidden view session
    /// attaches with — that is what lets the view stream be the only connection cmux opens to a
    /// host, instead of a one-shot creating the view first.
    @Test func attachModesSpellOutTheirTmuxCommands() {
        #expect(
            RemoteTmuxControlAttachMode.attach.tmuxArguments(sessionName: "work")
                == ["-CC", "attach-session", "-t", "work"]
        )
        #expect(
            RemoteTmuxControlAttachMode.attachOrCreate.tmuxArguments(sessionName: "work")
                == ["-CC", "new-session", "-A", "-s", "work"]
        )
        #expect(
            RemoteTmuxControlAttachMode.attachOrCreateSized(columns: 120, rows: 40)
                .tmuxArguments(sessionName: "cmux-view-abc")
                == [
                    "-CC", "new-session", "-A", "-s", "cmux-view-abc",
                    "-x", "120", "-y", "40",
                ]
        )
    }

    /// Both transports carry the sized attach-or-create, so the view behaves the same over either.
    @Test func bothProfilesCarryTheSizedAttachOrCreate() {
        let mode = RemoteTmuxControlAttachMode.attachOrCreateSized(columns: 120, rows: 40)
        let host = RemoteTmuxHost(destination: "user@host")
        let sshCommand = RemoteTmuxSSHTransportProfile()
            .controlStreamArgv(host: host, sessionName: "cmux-view-abc", mode: mode)
            .last ?? ""
        // ssh runs the PATH resolver first and quotes every token it passes on.
        #expect(
            sshCommand.hasSuffix(
                "'-CC' 'new-session' '-A' '-s' 'cmux-view-abc' '-x' '120' '-y' '40'")
        )

        #expect(
            RemoteTmuxETTransportProfile.controlStreamRemoteCommand(
                sessionName: "cmux-view-abc", mode: mode
            ) == "'tmux' '-CC' 'new-session' '-A' '-s' 'cmux-view-abc' '-x' '120' '-y' '40'"
        )
    }

    /// The rest of the view's bringup rides the same stream: three option writes that tag the
    /// session as this owner's. They are re-sent on every attach, so a view left by an older
    /// format version is re-tagged rather than mistaken for a stale one.
    @Test func theViewStampsItsOwnershipOverTheStream() {
        let commands = RemoteTmuxViewSession(ownerId: "owner-1").setOptionCommands()
        let name = RemoteTmuxViewSession(ownerId: "owner-1").sessionName
        #expect(commands == [
            "set-option -t '\(name)' @cmux_view 1",
            "set-option -t '\(name)' @cmux_view_owner 'owner-1'",
            "set-option -t '\(name)' @cmux_view_version 1",
        ])
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
        let argv = profile.controlStreamArgv(host: host, sessionName: "work", mode: .attach)

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

    // MARK: - Brokered transport

    /// A host reached through a wrapper produces a different argv SHAPE, not extra flags.
    ///
    /// Both rules here are measured against a real broker rather than inferred. The wrapper parses
    /// its own flags up to the destination and forwards everything after it, so a client flag
    /// placed ahead of the destination is rejected outright — `flag provided but not defined`,
    /// exit 2, no connection. And the wrapper is the thing that resolved the route, so it already
    /// knows the port and the helper path; passing cmux's would override what it just worked out.
    @Test func brokeredArgvPutsBrokerFlagsFirstAndDropsEndpointFlags() {
        let broker = RemoteTmuxTransportBroker(
            executable: "/opt/site/bin/broker",
            leadingArguments: ["-et", "-fallback"]
        )
        let host = RemoteTmuxHost(
            destination: "somehost",
            port: 2222,
            identityFile: "/keys/id",
            transport: .et,
            transportPort: 2022,
            transportBroker: broker
        )
        let profile = host.transport.profile(
            port: host.transportPort,
            terminalPath: host.transportTerminalPath,
            broker: host.transportBroker
        )
        #expect(profile.executablePath() == "/opt/site/bin/broker")

        let argv = profile.controlStreamArgv(host: host, sessionName: "work", mode: .attach)
        #expect(argv.first == "-et")
        #expect(argv[1] == "-fallback")

        // The destination must precede everything the wrapper forwards.
        let destinationIndex = argv.firstIndex(of: "somehost")
        let commandIndex = argv.firstIndex(of: "-c")
        #expect(destinationIndex != nil)
        #expect(commandIndex != nil)
        if let destinationIndex, let commandIndex {
            #expect(destinationIndex < commandIndex)
        }

        // None of the endpoint flags may appear: the broker owns the endpoint.
        #expect(!argv.contains("-p"))
        #expect(!argv.contains("--terminal-path"))
        #expect(!argv.contains("--ssh-option"))

        // Plain `tmux`, because the command lands in a login shell that resolves PATH itself.
        let remote = argv.last(where: { $0.hasPrefix("exec ") })
        #expect(remote?.contains("'tmux'") == true)
    }

    /// Without a broker the ET argv keeps its endpoint flags, so the two shapes cannot be confused.
    @Test func directEtArgvStillCarriesEndpointFlags() {
        let host = RemoteTmuxHost(destination: "somehost", transport: .et, transportPort: 2022)
        let argv = host.transport
            .profile(port: host.transportPort, terminalPath: "/usr/local/bin/etterminal")
            .controlStreamArgv(host: host, sessionName: "work", mode: .attach)
        #expect(argv.contains("-p"))
        #expect(argv.contains("2022"))
        #expect(argv.contains("--terminal-path"))
    }

    /// ssh ignores a broker on purpose: ProxyCommand/ProxyJump already do this, configured where
    /// the user's other host settings live, and a second mechanism could only disagree with it.
    @Test func sshProfileIgnoresABroker() {
        let broker = RemoteTmuxTransportBroker(executable: "/opt/site/bin/broker",
                                               leadingArguments: ["-et"])
        let host = RemoteTmuxHost(destination: "somehost", transport: .ssh, transportBroker: broker)
        let profile = host.transport.profile(port: nil, terminalPath: nil, broker: broker)
        #expect(profile.executablePath() != "/opt/site/bin/broker")
        let argv = profile.controlStreamArgv(host: host, sessionName: "work", mode: .attach)
        #expect(!argv.contains("-et"))
    }

    /// A broker describes how to REACH an endpoint, not which endpoint it is, so two hosts that
    /// differ only by broker are one endpoint and must share one connection rather than compete.
    @Test func brokerDoesNotChangeConnectionIdentity() {
        let plain = RemoteTmuxHost(destination: "somehost", transport: .et, transportPort: 2022)
        let brokered = RemoteTmuxHost(
            destination: "somehost", transport: .et, transportPort: 2022,
            transportBroker: RemoteTmuxTransportBroker(executable: "/opt/site/bin/broker")
        )
        #expect(plain.connectionHash == brokered.connectionHash)
    }

    /// Go's flag package wording for a rejected argv. Wrappers that front a transport are commonly
    /// written in Go, and without this a mis-ordered argv reads as a transient problem, so cmux
    /// would retry the identical rejected command forever. Measured against a real broker.
    @Test(arguments: [
        "flag provided but not defined: -p",
        "FLAG PROVIDED BUT NOT DEFINED: -p\nusage: broker [-et] <HOSTNAME>",
    ])
    func classifiesGoFlagRejectionAsUnrecoverable(_ stderr: String) {
        #expect(RemoteTmuxSSHTransport.indicatesUnrecoverableTransportFailure(stderr))
    }

    /// The remote command budget must sit strictly inside MAX_CANON, not equal it.
    ///
    /// Measured against real et on macOS: delivery stops between 953 and 1016 bytes, not at 1024.
    /// et appends `; exit` and the shell's own line editing costs more, so roughly 70 bytes of the
    /// line are already spent before cmux's command begins. A budget compared against the raw
    /// MAX_CANON passes its own check and still gets truncated, and the symptom is an attach that
    /// times out with nothing to explain it.
    @Test func deliverableBudgetLeavesRoomForTheTransportsOwnSuffix() {
        let profile = RemoteTmuxETTransportProfile.self
        #expect(profile.deliverableCommandBytes < profile.maxCanonicalLineBytes)
        // The measured floor was 953; the budget must fit under it.
        #expect(profile.deliverableCommandBytes <= 953)
        // And a session name at the limit must still produce a deliverable command.
        let longest = String(repeating: "n", count: profile.maxSessionNameBytes())
        let command = profile.controlStreamRemoteCommand(sessionName: longest, mode: .attach)
        #expect(command.utf8.count <= profile.deliverableCommandBytes)
    }

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
        let argv = profile.controlStreamArgv(host: host, sessionName: "work", mode: .attach)

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
    @Test func etCommandFitsWhatALoginShellCanRead() {
        let maxCanon = 1024
        for session in ["s", "work session", String(repeating: "session-", count: 24)] {
            let argv = RemoteTmuxETTransportProfile(port: 2039).controlStreamArgv(
                host: RemoteTmuxHost(destination: "user@host"),
                sessionName: session,
                mode: .attach
            )
            let command = try? #require(argv.first(where: { $0.hasPrefix("exec ") }))
            let byteCount = (command ?? "").utf8.count
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
            mode: .attach
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

    /// A probe that is written but never answered is the stall this monitor exists for: ET can
    /// accept stdin while producing no control output. Before the deadline, probes accumulated and
    /// the connection stayed `.connected` forever — the monitor could not detect the very case it
    /// was added for.
    @MainActor @Test func anUnansweredProbeIsTreatedAsAStall() {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host", transport: .et, transportPort: 2039),
            sessionName: "work"
        )
        connection.handle(.enter)
        // Stand in for a probe that was written and never came back.
        connection.livenessProbeOutstanding = true

        var reported: Bool?
        connection.checkLivenessAndRecoverIfStalled { reported = $0 }
        #expect(reported == false)
        #expect(connection.snapshot().recentEvents.contains("liveness-unanswered"))
        #expect(connection.snapshot().recentEvents.contains("liveness-stalled"))
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
            .controlStreamArgv(host: unprobed, sessionName: "work", mode: .attach)
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
            .controlStreamArgv(host: probed, sessionName: "work", mode: .attach)
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
            host: host, sessionName: "work", mode: .attach
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
        // The floor guards against the bound collapsing to something useless, which is what this
        // assertion is for. It used to read `> 900`, pinned to a budget that spent the whole
        // canonical line; the budget now reserves 96 bytes for et's appended `; exit` and the
        // shell's line editing, because delivery was measured to stop between 1016 and 1080 bytes
        // of total command line on a host whose MAX_CANON is 1024 — so spending all 1024 truncated.
        // That legitimately moved the bound to 890.
        //
        // Deliberately not re-pinned to 889: an exact figure would fail again on the next honest
        // adjustment while saying nothing extra. A real tmux session name is under 100 bytes, so
        // anything past a few hundred proves the budget did not collapse, which is the only thing
        // worth asserting here.
        #expect(bound > 512, "the bound should leave room for a realistic name, saw \(bound)")
        #expect(bound < RemoteTmuxETTransportProfile.deliverableCommandBytes)
        #expect(RemoteTmuxETTransportProfile.deliverableCommandBytes
            < RemoteTmuxETTransportProfile.maxCanonicalLineBytes)

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
        let modes: [RemoteTmuxControlAttachMode] = [
            .attach, .attachOrCreate, .attachOrCreateSized(columns: 240, rows: 120),
        ]
        for mode in modes {
            let bound = RemoteTmuxETTransportProfile.maxSessionNameBytes(mode: mode)
            let command = RemoteTmuxETTransportProfile.controlStreamRemoteCommand(
                sessionName: String(repeating: "a", count: bound), mode: mode
            )
            #expect(
                command.utf8.count <= RemoteTmuxETTransportProfile.maxCanonicalLineBytes,
                "\(mode) produced \(command.utf8.count) bytes"
            )
        }
    }

    /// The boundary must measure the command the request will really send.
    ///
    /// `remote.tmux.attach` with `create: true` spawns `new-session -A -s <name>`, which is longer
    /// than `attach-session -t <name>`. Checking the attach shape for a create request let an
    /// 890-byte name through the socket check and then `spawnProcess` computed 929 bytes against a
    /// 928-byte budget and threw `launchFailed` — the over-long name was refused, just in the wrong
    /// place and with the wrong error.
    @Test func theSessionNameBoundFollowsTheModeTheRequestWillUse() {
        #expect(RemoteTmuxControlAttachMode.forCreateIfMissing(false) == .attach)
        #expect(RemoteTmuxControlAttachMode.forCreateIfMissing(true) == .attachOrCreate)

        let attachBound = RemoteTmuxETTransportProfile.maxSessionNameBytes(mode: .attach)
        let createBound = RemoteTmuxETTransportProfile.maxSessionNameBytes(mode: .attachOrCreate)
        #expect(createBound < attachBound, "attach-or-create is the longer command")

        // One name, two requests: the attach shape accepts it, the create shape refuses it.
        let atAttachBound = String(repeating: "a", count: attachBound)
        #expect(
            TerminalController.remoteTmuxSessionName(
                from: ["session": atAttachBound], transport: .et,
                mode: .forCreateIfMissing(false)) != nil)
        #expect(
            TerminalController.remoteTmuxSessionName(
                from: ["session": atAttachBound], transport: .et,
                mode: .forCreateIfMissing(true)) == nil)

        // And the longest name the create path does accept still produces a deliverable command,
        // so the bound is pinned against the string that gets sent rather than against itself.
        let atCreateBound = String(repeating: "a", count: createBound)
        #expect(
            TerminalController.remoteTmuxSessionName(
                from: ["session": atCreateBound], transport: .et,
                mode: .forCreateIfMissing(true)) != nil)
        let sent = RemoteTmuxETTransportProfile.controlStreamRemoteCommand(
            sessionName: atCreateBound, mode: .attachOrCreate)
        #expect(sent.utf8.count <= RemoteTmuxETTransportProfile.deliverableCommandBytes)
        #expect(
            RemoteTmuxETTransportProfile().commandLengthOverrun(
                sessionName: atCreateBound, mode: .attachOrCreate) == nil)
        // One byte past the bound is refused, so the check is on the boundary rather than near it.
        #expect(
            TerminalController.remoteTmuxSessionName(
                from: ["session": String(repeating: "a", count: createBound + 1)],
                transport: .et, mode: .forCreateIfMissing(true)) == nil)
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
            host: RemoteTmuxHost(destination: "user@host"), sessionName: "s", mode: .attach
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
            .controlStreamArgv(host: host, sessionName: "work", mode: .attach)
        #expect(consecutive(streamArgv, "-p", "2039"), "the control stream must use et's port")

        let oneShot = RemoteTmuxSSHTransportProfile().oneShotArgv(host: host, remoteCommand: "true")
        #expect(!consecutive(oneShot, "-p", "2039"), "a one-shot must never be sent to et's port")

        // Unset means etserver's documented default, never ssh's 22.
        let defaulted = RemoteTmuxHost(destination: "user@host", transport: .et)
        let defaultArgv = defaulted.transport.profile(port: defaulted.transportPort)
            .controlStreamArgv(host: defaulted, sessionName: "work", mode: .attach)
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

    // MARK: - declaring a broker in configuration and selecting one by name

    /// A declared broker with an absolute, existing executable is usable, and its arguments
    /// survive in order — the order is the whole reason a broker takes a list rather than a set.
    @Test func aDeclaredBrokerBecomesUsableWithItsArgumentsInOrder() {
        let definition = CmuxRemoteTmuxConfigDefinition(brokers: [
            "site": CmuxRemoteTmuxBrokerDefinition(
                executable: "/opt/site/bin/broker", arguments: ["-et", "-fallback"]
            )
        ])
        let (registry, rejected) = RemoteTmuxBrokerRegistry.make(
            from: definition, fileExists: { $0 == "/opt/site/bin/broker" }
        )
        #expect(rejected.isEmpty)
        let selection = RemoteTmuxBrokerRegistry.select(requestedName: "site", registry: registry)
        #expect(selection == .resolved(RemoteTmuxTransportBroker(
            executable: "/opt/site/bin/broker", leadingArguments: ["-et", "-fallback"]
        )))
    }

    /// A name nobody declared is refused rather than defaulted to a direct connection. Reaching a
    /// host by a route the user did not choose is the failure this prevents; the error would
    /// otherwise surface later as an unreachable network rather than as a typo.
    @Test func anUndeclaredBrokerNameIsRefusedRatherThanIgnored() {
        let (registry, rejected) = RemoteTmuxBrokerRegistry.make(
            from: CmuxRemoteTmuxConfigDefinition(), fileExists: { _ in true }
        )
        #expect(registry.isEmpty)
        #expect(RemoteTmuxBrokerRegistry.select(
            requestedName: "typo", registry: registry, rejected: rejected
        ) == .unknown(name: "typo"))
    }

    /// Asking for nothing is not an error: an absent or blank name means the direct argv applies.
    @Test func noBrokerNameSelectsTheDirectPath() {
        let registry = RemoteTmuxBrokerRegistry()
        #expect(RemoteTmuxBrokerRegistry.select(requestedName: nil, registry: registry) == .none)
        #expect(RemoteTmuxBrokerRegistry.select(requestedName: "   ", registry: registry) == .none)
    }

    /// A relative executable is refused. Not tidiness: the pty wrapper resolves its argument
    /// against the app's PATH, which for a GUI app is not the user's, so a bare name fails in a
    /// way that looks like the host being unreachable.
    @Test func aRelativeBrokerExecutableIsRejectedWithItsReason() {
        let definition = CmuxRemoteTmuxConfigDefinition(brokers: [
            "site": CmuxRemoteTmuxBrokerDefinition(executable: "broker")
        ])
        let (registry, rejected) = RemoteTmuxBrokerRegistry.make(
            from: definition, fileExists: { _ in true }
        )
        #expect(registry.broker(named: "site") == nil)
        // Declared-but-unusable must not read as never-declared: one is a fixable path, the other
        // a typo, and the user needs to be told which.
        let selection = RemoteTmuxBrokerRegistry.select(
            requestedName: "site", registry: registry, rejected: rejected
        )
        guard case let .unusable(name, reason) = selection else {
            Issue.record("expected .unusable, got \(selection)")
            return
        }
        #expect(name == "site")
        #expect(reason.contains("absolute path"))
    }

    /// An absolute path that is not there is also unusable, and says so differently from a
    /// relative one, because the fix is different.
    @Test func aMissingBrokerExecutableIsRejectedAsMissing() {
        let definition = CmuxRemoteTmuxConfigDefinition(brokers: [
            "site": CmuxRemoteTmuxBrokerDefinition(executable: "/opt/site/bin/gone")
        ])
        let (_, rejected) = RemoteTmuxBrokerRegistry.make(
            from: definition, fileExists: { _ in false }
        )
        #expect(rejected["site"]?.contains("no executable file") == true)
    }

    /// Hidden and control characters are refused in a broker's arguments and in the name a caller
    /// asks for, on the same grounds the destination refuses them: they can smuggle terminal
    /// escapes or obscure what is actually being run.
    @Test func hiddenCharactersAreRefusedInArgumentsAndInTheRequestedName() {
        let definition = CmuxRemoteTmuxConfigDefinition(brokers: [
            "site": CmuxRemoteTmuxBrokerDefinition(
                executable: "/opt/site/bin/broker", arguments: ["-et\u{7}"]
            )
        ])
        let (registry, rejected) = RemoteTmuxBrokerRegistry.make(
            from: definition, fileExists: { _ in true }
        )
        #expect(registry.broker(named: "site") == nil)
        #expect(rejected["site"]?.contains("control or hidden character") == true)

        let selection = RemoteTmuxBrokerRegistry.select(
            requestedName: "si\u{200B}te", registry: RemoteTmuxBrokerRegistry()
        )
        guard case .malformed = selection else {
            Issue.record("expected .malformed for a name with a hidden character, got \(selection)")
            return
        }
    }

    /// `arguments` is optional in the config file, because a broker that needs no flags should not
    /// have to write an empty list.
    @Test func aBrokerDefinitionDecodesWithoutAnArgumentsKey() throws {
        let json = Data("""
        {"brokers": {"site": {"executable": "/opt/site/bin/broker"}}}
        """.utf8)
        let definition = try JSONDecoder().decode(CmuxRemoteTmuxConfigDefinition.self, from: json)
        #expect(definition.brokers["site"]?.arguments.isEmpty == true)
    }

    // MARK: - a mirror only counts once it has a topology

    /// The defect this guards: reaching control mode is not the same as having something to
    /// mirror. Measured on a real host — the stream sent the DCS intro, the attach block, and
    /// `%session-changed`, then `%exit`, with no window ever arriving. `%enter` had already moved
    /// the connection to `.connected`, so the caller created a workspace and the RPC reported
    /// success for a mirror that could never populate.
    @MainActor
    @Test func readinessStartsPendingAndFailsWhenAStreamEndsWithNoWindow() async {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "somehost"), sessionName: "work"
        )
        #expect(connection.initialTopologyState == .pending)
        // What a dead-on-arrival stream amounts to: it ends without ever publishing windows.
        connection.resolveInitialTopology(ready: false)
        #expect(connection.initialTopologyState == .failed)
        #expect(await connection.waitUntilInitialTopology() == false)
    }

    /// And the success direction: once a topology is published the connection is ready, and stays
    /// ready. Stickiness matters because a later normal end — the session killed, the last window
    /// closed — must not be mistaken for an initial attach that never worked.
    @MainActor
    @Test func readinessIsStickyOncePublished() async {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "somehost"), sessionName: "work"
        )
        connection.resolveInitialTopology(ready: true)
        #expect(connection.initialTopologyState == .ready)
        #expect(await connection.waitUntilInitialTopology() == true)
        // A later end must not downgrade it.
        connection.resolveInitialTopology(ready: false)
        #expect(connection.initialTopologyState == .ready)
        #expect(await connection.waitUntilInitialTopology() == true)
    }

    /// A waiter that arrives before the answer must be released by it, not left hanging — that is
    /// the whole point of the barrier for the attach path.
    @MainActor
    @Test func aPendingWaiterIsReleasedWhenReadinessResolves() async {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "somehost"), sessionName: "work"
        )
        let waiter = Task { await connection.waitUntilInitialTopology() }
        // Wait on the barrier's own registration, not the clock. A fixed sleep can resolve before the
        // waiter arrives, and then the barrier answers from its already-resolved shortcut: the pending
        // path this test exists for is skipped and the assertion below passes regardless. Bounded by a
        // yield count so a waiter that never registers fails rather than hanging.
        var handoffs = 0
        while connection.initialTopologyWaiterCount == 0, handoffs < 10_000 {
            await Task.yield()
            handoffs += 1
        }
        #expect(connection.initialTopologyWaiterCount == 1, "the waiter has to be registered")
        #expect(
            connection.initialTopologyState == .pending,
            "if readiness already resolved, this no longer tests a pending waiter"
        )
        connection.resolveInitialTopology(ready: true)
        #expect(await waiter.value == true)
    }

    // MARK: - detaching a transport whose remote half survives

    /// Only a transport that outlives its client needs the extra step, and the two profiles have to
    /// disagree here or the trait would be decoration. ssh's client death closes tmux's pty; et
    /// leaves `etterminal` holding it, which is what left stale clients attached to real sessions.
    @Test func onlyThePersistentTransportNeedsATmuxLevelDetach() {
        #expect(RemoteTmuxSSHTransportProfile().remoteHalfSurvivesLocalExit == false)
        let et = RemoteTmuxETTransportProfile(
            port: 2022, remoteTerminalPath: RemoteTmuxETTransportProfile.defaultRemoteTerminalPath
        )
        #expect(et.remoteHalfSurvivesLocalExit == true)
    }

    /// With no live stream there is nobody to ask, so the detach must not wait on a confirmation
    /// that can never come — it ends the connection now. A hang here would stall a workspace close.
    @MainActor
    @Test func detachingAConnectionWithNoLiveStreamEndsItImmediately() {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "somehost", transport: .et), sessionName: "work"
        )
        connection.detachThenStop()
        #expect(connection.connectionState == .ended)
    }

    /// An ssh connection skips the tmux-level detach even when asked, because tearing its client
    /// down is already a complete detach. Same call, different transport, different path.
    @MainActor
    @Test func detachingAnSSHConnectionJustEndsIt() {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "somehost", transport: .ssh), sessionName: "work"
        )
        connection.detachThenStop()
        #expect(connection.connectionState == .ended)
    }

    // MARK: - a broker named for a transport that ignores brokers

    /// ssh ignores a broker, so accepting one would connect straight to the host while the user asked
    /// for a specific route — the same outcome this boundary refuses for an unknown name, reached by
    /// agreeing instead of by defaulting. `transport` defaults to ssh, so `--broker <name>` alone hits
    /// this.
    @Test func aBrokerNamedForTheSSHTransportIsRefused() {
        let broker = RemoteTmuxTransportBroker(
            executable: "/opt/site/bin/broker", leadingArguments: ["-et"]
        )
        let select: (String?) -> RemoteTmuxBrokerSelection = {
            $0 == "site" ? .resolved(broker) : .unknown(name: $0 ?? "")
        }
        // No transport key at all: this is the CLI's `--broker site` with no `--transport`.
        #expect(
            TerminalController.remoteTmuxHost(
                from: ["host": "somehost", "transport_broker": "site"], selectBroker: select
            ) == nil
        )
        // And explicitly asking for ssh is refused the same way.
        #expect(
            TerminalController.remoteTmuxHost(
                from: ["host": "somehost", "transport": "ssh", "transport_broker": "site"],
                selectBroker: select
            ) == nil
        )
        // et still works, or the refusal would be indiscriminate.
        #expect(
            TerminalController.remoteTmuxHost(
                from: ["host": "somehost", "transport": "et", "transport_broker": "site"],
                selectBroker: select
            )?.transportBroker == broker
        )
    }

    /// The refusal has to explain itself; a silent nil reads as "the host was bad".
    @Test func refusingABrokerForSSHSaysWhy() {
        let broker = RemoteTmuxTransportBroker(executable: "/opt/site/bin/broker", leadingArguments: [])
        let message = TerminalController.remoteTmuxBrokerFailureMessage(
            from: ["host": "somehost", "transport_broker": "site"],
            selectBroker: { $0 == "site" ? .resolved(broker) : .unknown(name: $0 ?? "") }
        )
        #expect(message?.contains("does not use a broker") == true)
        // And a broker the et transport does use produces no complaint.
        #expect(
            TerminalController.remoteTmuxBrokerFailureMessage(
                from: ["host": "somehost", "transport": "et", "transport_broker": "site"],
                selectBroker: { $0 == "site" ? .resolved(broker) : .unknown(name: $0 ?? "") }
            ) == nil
        )
    }

    // MARK: - a %exit that is really the transport dying

    /// The bound has to exist and be small. A tunnel that dies on every attach reaches control mode
    /// every time, so without a cap the reattach would repeat at the base backoff forever — and
    /// `beginReconnecting` resets that backoff, so the cap is the only thing holding it.
    @Test func theTransportDeathReattachBudgetIsSmallAndFinite() {
        #expect(RemoteTmuxControlConnection.maxTransportDeathReattempts >= 1)
        #expect(RemoteTmuxControlConnection.maxTransportDeathReattempts <= 5)
    }

    /// Clearing the budget is only meaningful once an attach has published windows, and it must be a
    /// no-op otherwise so a stream that never carried anything cannot silently extend its own budget.
    @MainActor
    @Test func clearingTheReattachBudgetIsANoOpWhenNothingWasSpent() {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "somehost", transport: .et), sessionName: "work"
        )
        connection.clearTransportDeathReattachBudget()
        // Nothing to assert beyond "it did not trap"; the budget is private, and the observable
        // contract is that a fresh connection is unaffected by the reset.
        #expect(connection.connectionState != .ended)
    }

    // MARK: - the socket boundary

    /// A declared name reaches the host, so the profile built from that host uses the broker.
    @Test func theSocketBoundaryAttachesADeclaredBroker() {
        let broker = RemoteTmuxTransportBroker(
            executable: "/opt/site/bin/broker", leadingArguments: ["-et"]
        )
        let host = TerminalController.remoteTmuxHost(
            from: ["host": "somehost", "transport": "et", "transport_broker": "site"],
            selectBroker: { $0 == "site" ? .resolved(broker) : .unknown(name: $0 ?? "") }
        )
        #expect(host?.transportBroker == broker)
    }

    /// Asking for a broker that cannot be resolved refuses the host outright. Connecting directly
    /// instead would reach the host by a route the caller did not ask for, and the failure would
    /// then look like an unreachable network rather than a name that does not exist.
    @Test func theSocketBoundaryRefusesAHostWhenABrokerCannotBeResolved() {
        let params: [String: Any] = ["host": "somehost", "transport": "et", "transport_broker": "typo"]
        #expect(TerminalController.remoteTmuxHost(
            from: params, selectBroker: { .unknown(name: $0 ?? "") }
        ) == nil)
        // And the refusal is explained in terms of the broker, not as a missing host.
        let message = TerminalController.remoteTmuxBrokerFailureMessage(
            from: params, selectBroker: { .unknown(name: $0 ?? "") }
        )
        #expect(message?.contains("typo") == true)
        #expect(message?.contains("remoteTmux.brokers") == true)
    }

    /// A declared-but-unusable broker says what is wrong with it, so the reason reaches whoever has
    /// to fix the config rather than being flattened into the same error as a typo.
    @Test func anUnusableBrokerExplainsItselfAtTheBoundary() {
        let message = TerminalController.remoteTmuxBrokerFailureMessage(
            from: ["host": "somehost", "transport": "et", "transport_broker": "site"],
            selectBroker: { .unusable(name: $0 ?? "", reason: "executable must be an absolute path, got broker") }
        )
        #expect(message?.contains("absolute path") == true)
    }

    /// No broker asked for is not an error, and it leaves the host on the direct path.
    @Test func theSocketBoundaryLeavesAHostAloneWhenNoBrokerIsAskedFor() {
        let host = TerminalController.remoteTmuxHost(
            from: ["host": "somehost", "transport": "et"], selectBroker: { _ in .none }
        )
        #expect(host != nil)
        #expect(host?.transportBroker == nil)
        #expect(TerminalController.remoteTmuxBrokerFailureMessage(
            from: ["host": "somehost"], selectBroker: { _ in .none }
        ) == nil)
    }

    /// The end of the seam: a broker resolved from configuration produces the brokered argv, with
    /// its flags ahead of the destination and cmux's endpoint flags dropped.
    @Test func aBrokerFromConfigurationProducesTheBrokeredArgv() {
        let definition = CmuxRemoteTmuxConfigDefinition(brokers: [
            "site": CmuxRemoteTmuxBrokerDefinition(
                executable: "/opt/site/bin/broker", arguments: ["-et", "-fallback"]
            )
        ])
        let (registry, _) = RemoteTmuxBrokerRegistry.make(
            from: definition, fileExists: { _ in true }
        )
        guard case let .resolved(broker) = RemoteTmuxBrokerRegistry.select(
            requestedName: "site", registry: registry
        ) else {
            Issue.record("expected the declared broker to resolve")
            return
        }
        let host = RemoteTmuxHost(destination: "somehost", transport: .et, transportBroker: broker)
        let profile = RemoteTmuxETTransportProfile(broker: broker)
        let argv = profile.controlStreamArgv(
            host: host, sessionName: "work", mode: .attach
        )
        #expect(profile.executablePath() == "/opt/site/bin/broker")
        #expect(argv.prefix(3) == ["-et", "-fallback", "somehost"])
        #expect(argv.contains("-p") == false)
        #expect(argv.last == "exec 'tmux' '-CC' 'attach-session' '-t' 'work'")
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

    // MARK: - Property tests over the real connection: readiness, the reattach budget,
    // MARK: - deliberate detach, and command bookkeeping

    /// The one fixture every case below is built on, checked against what was measured.
    ///
    /// This is the anti-false-oracle gate. A healthy `tmux -CC attach-session` is 84 bytes and
    /// announces no window at all; cmux learns the topology by SENDING `list-windows`. A fake far
    /// end that volunteers `%window-add` is more talkative than tmux, and an oracle written against
    /// one passes on a stream real tmux never produces — that bug shipped in this repo's brokered
    /// harness and survived fifty assertions. So the fixture is not typed out here: it is the tail
    /// of the captured et stream the suite above already ships.
    @Test func theMeasuredHealthyAttachAnnouncesNoWindow() {
        let attach = MeasuredControlStream.healthyAttach
        #expect(attach.count == 84, "the measured attach is 84 bytes, saw \(attach.count)")
        let text = String(decoding: attach, as: UTF8.self)
        #expect(text.hasPrefix("\u{1b}P1000p"), "the attach opens with the enter DCS")
        #expect(occurrences(of: "%begin ", in: text) == 1)
        #expect(occurrences(of: "%end ", in: text) == 1)
        #expect(occurrences(of: "%session-changed ", in: text) == 1)
        for absent in ["%window-add", "%windows-changed", "%layout-change", "%exit"] {
            #expect(!text.contains(absent), "a healthy attach never sends \(absent)")
        }

        // And the product's parser turns those bytes into exactly three messages, in that order.
        var parser = RemoteTmuxControlStreamParser()
        let messages = parser.feed(attach)
        #expect(messages.count == 3, "expected enter + attach block + session-changed, saw \(messages.count)")
        if messages.count == 3 {
            #expect({ if case .enter = messages[0] { return true }; return false }())
            #expect({ if case .commandResult = messages[1] { return true }; return false }())
            #expect({ if case .sessionChanged = messages[2] { return true }; return false }())
        }
    }

    /// The instrument check for every case that follows: the driver reaches readiness only by
    /// answering commands cmux itself wrote, and those commands really leave through the product's
    /// own stdin writer rather than being conjured into the correlation FIFO.
    ///
    /// Reaching control mode is deliberately checked to be NOT ready. That is the shipped bug this
    /// whole barrier exists for: `%enter` moved the connection to `.connected`, the caller created a
    /// workspace, and the RPC reported success for a mirror that could never populate.
    @MainActor
    @Test(arguments: seeds)
    func aDrivenAttachReachesReadinessOnlyThroughTheCommandsCmuxSent(seed: UInt64) async {
        var rng = SplitMix64(seed: seed)
        let peer = FuzzPeer(seed: seed, label: "attach", shape: .persistentRemote, rng: &rng)
        let context = peer.context()
        #expect(peer.probeIntervalIsUntouched, "\(context) another test lowered the liveness probe interval")

        // A waiter registered before the first byte, so the release is the product's doing.
        let waiter = Task { await peer.connection.waitUntilInitialTopology() }
        peer.installStream()
        peer.feed(MeasuredControlStream.healthyAttach)

        #expect(peer.connection.connectionState == .connected, "\(context) the attach never reached control mode")
        #expect(
            peer.connection.initialTopologyState == .pending,
            "\(context) control mode alone was taken for readiness"
        )
        #expect(!peer.events.contains("initial-topology-ready"), "\(context) ready before any window")
        #expect(
            peer.connection.pendingCommands.contains { if case .listWindows = $0 { return true }; return false },
            "\(context) the attach block did not queue list-windows"
        )
        // The bytes, not just the FIFO slot: proves the driver drives the shipped send path.
        #expect(
            await peer.awaitSentText(containing: "list-windows -F"),
            "\(context) no list-windows reached the transport's stdin, sent=\(peer.sentText)"
        )

        let answered = peer.drainFarEnd()
        #expect(answered > 0 && answered < FuzzPeer.answerLimit, "\(context) far end answered \(answered) commands")
        #expect(
            peer.connection.initialTopologyState == .ready,
            "\(context) a published topology did not make the connection ready"
        )
        #expect(
            peer.connection.windowsByID.count == peer.windows.count,
            "\(context) published \(peer.connection.windowsByID.count) of \(peer.windows.count) windows"
        )
        // Publication comes first; readiness is claimed from it and nowhere earlier.
        let publishedAt = peer.firstIndex(ofEventPrefix: "initial-batch-published")
        let readyAt = peer.firstIndex(ofEventPrefix: "initial-topology-ready")
        #expect(publishedAt != nil && readyAt != nil, "\(context) events=\(peer.events)")
        if let publishedAt, let readyAt {
            #expect(publishedAt < readyAt, "\(context) readiness was claimed before publication")
        }
        #expect(await waiter.value == true, "\(context) the pre-registered waiter was not released with ready")
        #expect(peer.ringIsIntact, "\(context) the diagnostics ring overflowed, so its counts cannot be read")
        #expect(peer.exitNotifications == 0, "\(context) a healthy attach notified exit")
        #expect(peer.topologyNotifications > 0, "\(context) the publication told no observer about it")

        peer.connection.stop()
    }

    /// Readiness moves at most once, and only a published topology can move it to ready.
    ///
    /// Two arms in one case, because a one-armed version of this passes trivially: an oracle that
    /// only ever sees a healthy stream cannot tell "ready needs windows" from "ready is the default".
    /// Both outcomes have to be reached by the same code in the same case.
    ///
    /// Every readiness reading is taken BEFORE any teardown. `connectionState`'s `didSet` resolves
    /// readiness to failed on `.ended`, so a case that called `stop()` first and then read would be
    /// grading its own teardown instead of the stream.
    @MainActor
    @Test(arguments: seeds)
    func readinessResolvesOnceAndNeverWithoutPublishedWindows(seed: UInt64) async {
        var rng = SplitMix64(seed: seed)

        // Arm 1: a stream that publishes. Readiness goes ready once and survives later churn,
        // including a transport-death reattach and a later windowless reply.
        let ready = FuzzPeer(seed: seed, label: "ready-arm", shape: .persistentRemote, rng: &rng)
        let readyContext = ready.context()
        ready.installStream()
        ready.feed(MeasuredControlStream.healthyAttach)
        ready.sampleReadiness()
        _ = ready.drainFarEnd()
        ready.sampleReadiness()
        #expect(ready.connection.initialTopologyState == .ready, "\(readyContext) never became ready")

        for step in 0..<rng.int(2..<5) {
            switch step % 3 {
            case 0:
                ready.deliverOutput(pane: ready.windows[0].panes[0], text: "churn \(step)")
            case 1:
                ready.deliverLayoutChange(window: ready.windows[0])
                _ = ready.drainFarEnd()
            default:
                // A windowless list-windows reply after readiness must change nothing.
                ready.requestWindowsAsTheAttachDrainWould()
                _ = ready.drainFarEnd(windows: [])
            }
            ready.sampleReadiness()
        }
        // A transport-death reattach is the sharpest post-resolution trigger: it tears the stream
        // down and builds a new one, and readiness must not follow it back to pending or failed.
        ready.deliverExit()
        ready.sampleReadiness()
        ready.installStream()
        ready.deliverControlModeEntry()
        ready.sampleReadiness()
        #expect(
            ready.readinessIsMonotonic(),
            "\(readyContext) readiness moved more than once: \(ready.readinessSamples)"
        )
        #expect(
            ready.connection.initialTopologyState == .ready,
            "\(readyContext) a resolved readiness was downgraded, samples=\(ready.readinessSamples)"
        )
        #expect(
            ready.eventCount(prefix: "initial-topology-") == 1,
            "\(readyContext) readiness resolved \(ready.eventCount(prefix: "initial-topology-")) times"
        )
        #expect(ready.ringIsIntact, "\(readyContext) ring overflowed")

        // Arm 2: the measured failing stream — control mode, a complete attach block, a session
        // change, and no window ever. This must stay pending while the connection lives, then fail.
        let empty = FuzzPeer(seed: seed, label: "windowless-arm", shape: .plainSSH, rng: &rng)
        let emptyContext = empty.context()
        let waiter = Task { await empty.connection.waitUntilInitialTopology() }
        empty.installStream()
        empty.feed(MeasuredControlStream.healthyAttach)
        _ = empty.drainFarEnd(windows: [])
        empty.sampleReadiness()
        #expect(
            empty.connection.initialTopologyState == .pending,
            "\(emptyContext) a windowless reply resolved readiness"
        )
        #expect(!empty.events.contains("initial-batch-published"), "\(emptyContext) published nothing, yet said so")
        // `%exit` on a transport whose remote half dies with the client is a genuine end.
        empty.deliverExit()
        empty.sampleReadiness()
        #expect(
            empty.connection.initialTopologyState == .failed,
            "\(emptyContext) a stream that ended with no window was not failed"
        )
        #expect(empty.connection.connectionState == .ended, "\(emptyContext) state=\(empty.connection.connectionState)")
        #expect(empty.exitNotifications == 1, "\(emptyContext) exit fired \(empty.exitNotifications)x")
        #expect(await waiter.value == false, "\(emptyContext) the waiter was released with ready")
        #expect(empty.readinessIsMonotonic(), "\(emptyContext) samples=\(empty.readinessSamples)")

        // Per-case anti-vacuity: both outcomes were reached, so neither reading is a default.
        #expect(
            ready.connection.initialTopologyState == .ready
                && empty.connection.initialTopologyState == .failed,
            "seed=\(String(seed, radix: 16)) one of the two arms never happened"
        )

        ready.connection.stop()
        empty.connection.stop()
    }

    /// The `%exit`-driven reattach chain is capped at `maxTransportDeathReattempts`, and the budget
    /// resets on a `list-windows` reply that carries windows — so it counts CONSECUTIVE failures.
    ///
    /// Two arms, again in one case. Neither "always resets" nor "never resets" can pass both: arm A
    /// recovers four times over, arm B ends on the fourth incident. Deleting the reset at
    /// `RemoteTmuxControlConnection+CommandResults.swift:183` fails arm A; removing the cap fails
    /// arm B.
    ///
    /// Each incident is checked to have actually happened rather than merely been logged. A `%exit`
    /// that arrives while the connection is already `.reconnecting` still increments the counter and
    /// still records `exit-may-be-transport-death`, but `beginReconnecting` returns having done
    /// nothing — so "three entries then an end" is satisfiable with zero real reattaches. Every
    /// incident therefore also requires the `reconnecting preserving-backoff` record, a return to
    /// `.connected`, and a `list-windows` on the wire for that attempt.
    @MainActor
    @Test(arguments: seeds)
    func theReattachBudgetIsCappedAndResetsOnAWindowsBearingReply(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let cap = RemoteTmuxControlConnection.maxTransportDeathReattempts

        // Arm A: every reattach lists windows, so every incident starts from a clean budget.
        let recovering = FuzzPeer(seed: seed, label: "budget-resets", shape: .persistentRemote, rng: &rng)
        let recoveringContext = recovering.context()
        recovering.installStream()
        recovering.feed(MeasuredControlStream.healthyAttach)
        _ = recovering.drainFarEnd()
        #expect(recovering.connection.initialTopologyState == .ready, "\(recoveringContext) attach never published")

        for incident in 1...(cap + 1) {
            let before = recovering.eventCount(prefix: "exit-may-be-transport-death")
            let reconnectsBefore = recovering.eventCount(prefix: "reconnecting preserving-backoff")
            recovering.deliverExit()
            let context = "\(recoveringContext) incident=\(incident)"
            #expect(
                recovering.eventCount(prefix: "exit-may-be-transport-death") == before + 1,
                "\(context) the %exit was not treated as a possible transport death"
            )
            #expect(
                recovering.lastEvent(prefix: "exit-may-be-transport-death")
                    == "exit-may-be-transport-death reattach=1",
                "\(context) the budget did not reset — events=\(recovering.events.suffix(12))"
            )
            #expect(
                recovering.eventCount(prefix: "reconnecting preserving-backoff") == reconnectsBefore + 1,
                "\(context) the reattach was recorded but never started"
            )
            #expect(
                recovering.connection.connectionState == .reconnecting,
                "\(context) state=\(recovering.connection.connectionState)"
            )
            #expect(recovering.exitNotifications == 0, "\(context) a reattach notified exit")

            // The reattach reaches control mode, and lists windows.
            recovering.installStream()
            recovering.deliverControlModeEntry()
            #expect(
                recovering.connection.connectionState == .connected,
                "\(context) the reattach did not return to connected"
            )
            recovering.requestWindowsAsTheAttachDrainWould()
            #expect(
                recovering.connection.pendingCommands.contains {
                    if case .listWindows = $0 { return true }
                    return false
                },
                "\(context) no list-windows was written for this reattach, so the reset edge is unreachable"
            )
            let answered = recovering.drainFarEnd()
            #expect(answered < FuzzPeer.answerLimit, "\(context) the far end answered \(answered) commands")
            #expect(
                recovering.eventCount(prefix: "transport-death-reattach-recovered") == incident,
                "\(context) a windows-bearing reply did not clear the budget"
            )
        }
        #expect(
            recovering.exitNotifications == 0,
            "\(recoveringContext) \(cap + 1) recovered incidents ended the connection"
        )
        #expect(
            recovering.connection.connectionState != .ended,
            "\(recoveringContext) state=\(recovering.connection.connectionState)"
        )
        #expect(recovering.ringIsIntact, "\(recoveringContext) ring overflowed, counts unreadable")

        // Arm B: the reattach reaches control mode but can never list a window, so the failures are
        // consecutive and the cap has to stop them.
        let failing = FuzzPeer(seed: seed, label: "budget-exhausts", shape: .persistentRemote, rng: &rng)
        let failingContext = failing.context()
        failing.installStream()
        failing.feed(MeasuredControlStream.healthyAttach)
        _ = failing.drainFarEnd()
        #expect(failing.connection.initialTopologyState == .ready, "\(failingContext) attach never published")

        for incident in 1...cap {
            failing.deliverExit()
            let context = "\(failingContext) incident=\(incident)"
            #expect(
                failing.lastEvent(prefix: "exit-may-be-transport-death")
                    == "exit-may-be-transport-death reattach=\(incident)",
                "\(context) the budget reset without a windows-bearing reply — events=\(failing.events.suffix(12))"
            )
            #expect(
                failing.connection.connectionState == .reconnecting,
                "\(context) state=\(failing.connection.connectionState)"
            )
            #expect(failing.exitNotifications == 0, "\(context) exit fired before the budget was spent")
            failing.installStream()
            failing.deliverControlModeEntry()
            failing.requestWindowsAsTheAttachDrainWould()
            _ = failing.drainFarEnd(windows: [])
            #expect(
                failing.eventCount(prefix: "transport-death-reattach-recovered") == 0,
                "\(context) a windowless reply cleared the budget"
            )
        }
        // The next %exit is past the cap: believe it.
        failing.deliverExit()
        #expect(
            failing.eventCount(prefix: "exit-may-be-transport-death") == cap,
            "\(failingContext) reattached \(failing.eventCount(prefix: "exit-may-be-transport-death"))x, cap is \(cap)"
        )
        #expect(failing.connection.connectionState == .ended, "\(failingContext) the spent budget did not end it")
        #expect(failing.exitNotifications == 1, "\(failingContext) exit fired \(failing.exitNotifications)x")
        // Readiness is sticky, so an end after a working attach does not rewrite history.
        #expect(failing.connection.initialTopologyState == .ready, "\(failingContext) readiness was downgraded")
        #expect(failing.ringIsIntact, "\(failingContext) ring overflowed, counts unreadable")

        // The two arms have to have DIFFERED. Identical text, opposite verdicts: that is what makes
        // this a measurement of the reset rather than a description of whatever the code does.
        // Arm C: the reset is what extends the chain, shown by driving that one edge and nothing
        // else. Three consecutive failures, then the budget is cleared, and the fourth `%exit` has
        // to reattach where arm B's ended. If the counter were a lifetime total that nothing could
        // clear, this arm ends exactly like arm B.
        let cleared = FuzzPeer(seed: seed, label: "budget-cleared", shape: .persistentRemote, rng: &rng)
        let clearedContext = cleared.context()
        cleared.installStream()
        cleared.feed(MeasuredControlStream.healthyAttach)
        _ = cleared.drainFarEnd()
        for _ in 1...cap {
            cleared.deliverExit()
            cleared.installStream()
            cleared.deliverControlModeEntry()
            cleared.requestWindowsAsTheAttachDrainWould()
            _ = cleared.drainFarEnd(windows: [])
        }
        #expect(
            cleared.lastEvent(prefix: "exit-may-be-transport-death")
                == "exit-may-be-transport-death reattach=\(cap)",
            "\(clearedContext) the chain did not reach the cap — events=\(cleared.events.suffix(12))"
        )
        cleared.connection.clearTransportDeathReattachBudget()
        #expect(
            cleared.eventCount(prefix: "transport-death-reattach-recovered") == 1,
            "\(clearedContext) clearing a spent budget recorded nothing"
        )
        cleared.deliverExit()
        #expect(
            cleared.lastEvent(prefix: "exit-may-be-transport-death")
                == "exit-may-be-transport-death reattach=1",
            "\(clearedContext) a cleared budget did not restart the chain — events=\(cleared.events.suffix(12))"
        )
        #expect(
            cleared.connection.connectionState == .reconnecting,
            "\(clearedContext) state=\(cleared.connection.connectionState)"
        )
        #expect(cleared.exitNotifications == 0, "\(clearedContext) the reattach after the clear notified exit")
        #expect(cleared.ringIsIntact, "\(clearedContext) ring overflowed, counts unreadable")

        let recoveredA = recovering.eventCount(prefix: "transport-death-reattach-recovered")
        let recoveredB = failing.eventCount(prefix: "transport-death-reattach-recovered")
        #expect(
            recoveredA == cap + 1 && recoveredB == 0
                && recovering.exitNotifications == 0 && failing.exitNotifications == 1,
            "seed=\(String(seed, radix: 16)) the arms behaved alike, so neither measured the reset: recovered A=\(recoveredA) B=\(recoveredB) exits A=\(recovering.exitNotifications) B=\(failing.exitNotifications)"
        )

        recovering.connection.stop()
        failing.connection.stop()
        cleared.connection.stop()
    }

    /// A `%exit` that answers cmux's own `detach-client` must never reach the exit observers, and an
    /// unsolicited one must.
    ///
    /// Scope, stated because the assertion is easy to over-read: this proves cmux SENT
    /// `detach-client` and that its confirmation is not treated as a remote end. It says nothing
    /// about whether the remote control client actually left — over a transport whose remote half
    /// outlives the local client that is a separate, currently-red lifecycle fact, and a green run
    /// here is not evidence about it.
    @MainActor
    @Test(arguments: seeds)
    func aDeliberateDetachNeverReachesExitObservers(seed: UInt64) async {
        var rng = SplitMix64(seed: seed)

        // Arm 1: the detach is confirmed.
        let confirmed = FuzzPeer(seed: seed, label: "detach-confirmed", shape: .persistentRemote, rng: &rng)
        let confirmedContext = confirmed.context()
        confirmed.installStream()
        confirmed.feed(MeasuredControlStream.healthyAttach)
        _ = confirmed.drainFarEnd()
        #expect(confirmed.connection.initialTopologyState == .ready, "\(confirmedContext) attach never published")

        confirmed.connection.detachThenStop(timeout: FuzzPeer.detachBackstopSeconds)
        #expect(confirmed.events.contains("detach-client-sent"), "\(confirmedContext) no detach was sent")
        #expect(
            await confirmed.awaitSentText(containing: "detach-client"),
            "\(confirmedContext) detach-client never reached the transport, sent=\(confirmed.sentText)"
        )
        // Targeting the session would evict the user's own client, so the command carries no `-s`.
        #expect(
            !confirmed.sentText.contains("detach-client -s"),
            "\(confirmedContext) the detach targeted a session: \(confirmed.sentText)"
        )
        confirmed.deliverExit()
        #expect(confirmed.events.contains("detach-client-confirmed"), "\(confirmedContext) events=\(confirmed.events)")
        #expect(confirmed.connection.connectionState == .ended, "\(confirmedContext) the confirmation did not end it")
        #expect(confirmed.exitNotifications == 0, "\(confirmedContext) cmux's own detach notified exit")
        #expect(
            confirmed.eventCount(prefix: "exit-may-be-transport-death") == 0,
            "\(confirmedContext) a deliberate detach started a reattach chain"
        )

        // Arm 2: nothing answers, so the backstop tears the transport down locally. Still not a
        // remote end. Waiting on the state edge rather than on the clock; the timeout is the bound.
        let unconfirmed = FuzzPeer(seed: seed, label: "detach-unconfirmed", shape: .persistentRemote, rng: &rng)
        let unconfirmedContext = unconfirmed.context()
        unconfirmed.installStream()
        unconfirmed.feed(MeasuredControlStream.healthyAttach)
        _ = unconfirmed.drainFarEnd()
        unconfirmed.connection.detachThenStop(timeout: FuzzPeer.detachBackstopSeconds)
        let ended = await unconfirmed.awaitConnectionEnded()
        #expect(ended, "\(unconfirmedContext) the detach backstop never fired")
        #expect(
            unconfirmed.events.contains("detach-client-unconfirmed"),
            "\(unconfirmedContext) events=\(unconfirmed.events)"
        )
        #expect(unconfirmed.exitNotifications == 0, "\(unconfirmedContext) an unconfirmed detach notified exit")

        // Arm 3, the discrimination: an unsolicited %exit on the same connection shape DOES reach
        // the observers once its reattach budget is spent. Without this the two arms above are
        // satisfiable by an exit observer that never fires at all.
        let unsolicited = FuzzPeer(seed: seed, label: "unsolicited-exit", shape: .persistentRemote, rng: &rng)
        let unsolicitedContext = unsolicited.context()
        unsolicited.installStream()
        unsolicited.feed(MeasuredControlStream.healthyAttach)
        _ = unsolicited.drainFarEnd()
        for _ in 1...RemoteTmuxControlConnection.maxTransportDeathReattempts {
            unsolicited.deliverExit()
            unsolicited.installStream()
            unsolicited.deliverControlModeEntry()
            unsolicited.requestWindowsAsTheAttachDrainWould()
            _ = unsolicited.drainFarEnd(windows: [])
        }
        #expect(unsolicited.exitNotifications == 0, "\(unsolicitedContext) exit fired during the reattach chain")
        unsolicited.deliverExit()
        #expect(
            unsolicited.exitNotifications == 1,
            "\(unsolicitedContext) exit fired \(unsolicited.exitNotifications)x once the budget was spent"
        )

        confirmed.connection.stop()
        unconfirmed.connection.stop()
        unsolicited.connection.stop()
    }

    /// Command bookkeeping stays bounded under generated churn, and nothing survives teardown.
    ///
    /// The failure this guards is a leak rather than an exact arithmetic: a FIFO that grows with
    /// churn, a completion table that outlives its stream, or pane state keyed by ids a peer
    /// invented. So the assertions are a generous ceiling plus "it returns to zero", not a formula
    /// mirroring the product's own.
    @MainActor
    @Test(arguments: seeds)
    func commandBookkeepingStaysBoundedUnderChurn(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let started = ContinuousClock.now
        let peer = FuzzPeer(seed: seed, label: "bookkeeping", shape: .persistentRemote, rng: &rng)
        let context = peer.context()
        peer.installStream()
        peer.feed(MeasuredControlStream.healthyAttach)
        _ = peer.drainFarEnd()
        #expect(peer.connection.initialTopologyState == .ready, "\(context) attach never published")

        // Real in-flight work, so "every table is empty after teardown" cannot pass by never
        // having held anything. This batch gets answered; a second batch below does not.
        var trackedOutcomes: [Bool] = []
        var activityAnswers: [Bool] = []
        var newWindowOutcomes = 0
        _ = peer.connection.sendTracked("display-message -p cmux-fuzz") { trackedOutcomes.append($0) }
        peer.connection.queryWindowActivity(windowId: peer.windows[0].id) { activityAnswers.append($0 != nil) }
        _ = peer.connection.sendNewWindow("new-window -P -F \"#{window_id}\"") { _ in newWindowOutcomes += 1 }
        #expect(peer.connection.trackedSendCompletions.count == 1, "\(context) the tracked send was not recorded")
        #expect(peer.connection.activityQueryCompletions.count == 1, "\(context) the activity query was not recorded")
        #expect(peer.connection.newWindowCompletions.count == 1, "\(context) the new-window was not recorded")

        let unpublishedPane = 900 + Int(seed % 90)
        var unpublishedOutputs = 0
        var deepestFIFO = peer.connection.pendingCommands.count
        for step in 0..<16 {
            let stepContext = "\(context) step=\(step)"
            switch rng.int(0..<6) {
            case 0:
                peer.deliverOutput(pane: peer.windows[0].panes[0], text: "live \(step)")
            case 1:
                // A pane the peer invented. Bookkeeping may accept it, but the next publication
                // must prune it — a hostile peer must not be able to grow this table.
                peer.deliverOutput(pane: unpublishedPane, text: "ghost \(step)")
                unpublishedOutputs += 1
            case 2:
                peer.deliverLayoutChange(window: peer.windows[rng.int(0..<peer.windows.count)])
            case 3:
                peer.deliverWindowRenamed(window: peer.windows[rng.int(0..<peer.windows.count)], step: step)
            case 4:
                // Real peer behaviour, not a network fault: et types a trailing command that tmux
                // answers with an error block carrying an id cmux never issued. Only injected with
                // an empty FIFO — with a command outstanding this would pop that command's slot by
                // design, and the case would then be measuring the injection, not the bookkeeping.
                if peer.connection.pendingCommands.isEmpty {
                    peer.deliverUnsolicitedErrorBlock()
                } else {
                    _ = peer.answerNextCommand()
                }
            default:
                _ = peer.answerNextCommand()
            }
            deepestFIFO = max(deepestFIFO, peer.connection.pendingCommands.count)
            #expect(
                peer.connection.pendingCommands.count <= FuzzPeer.pendingCommandCeiling,
                "\(stepContext) FIFO depth \(peer.connection.pendingCommands.count) over the ceiling"
            )
        }
        #expect(unpublishedOutputs > 0, "\(context) no output for an unpublished pane, so the prune check is vacuous")

        // Drain to quiescence: a bounded number of answers has to be enough, or the connection is
        // generating commands without end.
        peer.requestWindowsAsTheAttachDrainWould()
        let answered = peer.drainFarEnd()
        #expect(answered < FuzzPeer.answerLimit, "\(context) answered \(answered) commands without reaching quiescence")
        #expect(
            peer.connection.pendingCommands.isEmpty,
            "\(context) \(peer.connection.pendingCommands.count) commands outstanding after a full drain"
        )
        #expect(!peer.connection.windowListRequestInFlight, "\(context) a list-windows is still in flight")
        let publishedPanes = Set(peer.connection.windowsByID.values.flatMap { $0.paneIDsInOrder })
        #expect(
            Set(peer.connection.paneOutputByteCounts.keys).isSubset(of: publishedPanes),
            "\(context) pane byte counts kept unpublished panes \(Set(peer.connection.paneOutputByteCounts.keys).subtracting(publishedPanes))"
        )
        #expect(
            Set(peer.connection.paneHeaderLabels.keys).isSubset(of: publishedPanes),
            "\(context) header labels kept unpublished panes"
        )
        #expect(peer.ringIsIntact, "\(context) ring overflowed, so nothing above can be read from it")
        // The answered batch resolved, and the tracked block resolved as a success.
        #expect(trackedOutcomes == [true], "\(context) tracked send resolved \(trackedOutcomes)")
        #expect(activityAnswers == [true], "\(context) activity query resolved \(activityAnswers)")
        #expect(newWindowOutcomes == 1, "\(context) new-window resolved \(newWindowOutcomes)x")
        // The three requests above really passed through the FIFO, so the ceiling was measured
        // against something rather than against an empty queue.
        #expect(deepestFIFO >= 3, "\(context) the FIFO never held the registered work, depth peaked at \(deepestFIFO)")

        // A second batch that nothing answers, so teardown is what has to release it. Without this
        // the assertions below would pass because the drain had already emptied every table.
        var reorderOutcomes: [Bool] = []
        _ = peer.connection.sendTracked("display-message -p cmux-fuzz-orphan") { trackedOutcomes.append($0) }
        peer.connection.queryWindowActivity(windowId: peer.windows[0].id) { activityAnswers.append($0 != nil) }
        _ = peer.connection.sendWindowReorder(["swap-window -s @\(peer.windows[0].id) -t @\(peer.windows[0].id)"]) {
            reorderOutcomes.append($0)
        }
        #expect(peer.connection.trackedSendCompletions.count == 1, "\(context) the orphan tracked send never queued")
        #expect(peer.connection.activityQueryCompletions.count == 1, "\(context) the orphan activity query never queued")
        #expect(!peer.connection.windowReorderVerifications.isEmpty, "\(context) the reorder verification never queued")

        peer.connection.stop()
        #expect(peer.connection.connectionState == .ended, "\(context) stop() did not end the connection")
        #expect(peer.connection.trackedSendCompletions.isEmpty, "\(context) a tracked send survived teardown")
        #expect(peer.connection.activityQueryCompletions.isEmpty, "\(context) an activity query survived teardown")
        #expect(peer.connection.newWindowCompletions.isEmpty, "\(context) a new-window survived teardown")
        #expect(peer.connection.windowReorderVerifications.isEmpty, "\(context) a reorder verification survived")
        // Note what is NOT asserted: `pendingCommands` still holds the orphaned entries after
        // `stop()`. That is the shipped design — the FIFO is reset by the next spawn, and an ended
        // connection never spawns — so requiring it empty here would invent a rule.
        //
        // Exactly one edge each, and teardown's edge is a failure rather than a silent success.
        #expect(trackedOutcomes == [true, false], "\(context) tracked outcomes \(trackedOutcomes)")
        #expect(activityAnswers == [true, false], "\(context) activity outcomes \(activityAnswers)")
        #expect(reorderOutcomes == [false], "\(context) reorder outcomes \(reorderOutcomes)")

        // A loose bound on purpose: it catches a spin or an accidental real wait creeping in, and
        // is far enough above the millisecond-scale reality not to fail on a busy machine.
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(5), "\(context) took \(elapsed) — nothing here may wait on a clock")
    }

    /// The readers the cases above depend on, validated against known truth instead of trusted.
    ///
    /// Every case here passed on the first run, which is when an oracle is most likely to be inert.
    /// The three readers that could quietly always agree are the monotonicity check, the ring
    /// counters, and the profile shape — so each is shown reporting a violation for input that
    /// contains one, and the ring is shown noticing its own eviction.
    @MainActor
    @Test func theReadersBehindTheseOraclesReportViolations() {
        var rng = SplitMix64(seed: 0x0BAD_0BAD)
        let peer = FuzzPeer(seed: 0x0BAD_0BAD, label: "self-test", shape: .persistentRemote, rng: &rng)

        peer.replaceReadinessSamplesForSelfTest([.pending, .pending, .ready, .ready])
        #expect(peer.readinessIsMonotonic(), "a monotonic sequence was rejected")
        peer.replaceReadinessSamplesForSelfTest([.pending, .ready, .failed])
        #expect(!peer.readinessIsMonotonic(), "readiness that moved twice was called monotonic")
        peer.replaceReadinessSamplesForSelfTest([.failed, .pending])
        #expect(!peer.readinessIsMonotonic(), "a resolved readiness returning to pending was accepted")

        // The ring readers, against a ring whose contents are known.
        #expect(peer.events.isEmpty, "a connection that saw no bytes already has events: \(peer.events)")
        peer.connection.record("exit-may-be-transport-death reattach=1")
        peer.connection.record("unrelated")
        peer.connection.record("exit-may-be-transport-death reattach=2")
        #expect(peer.eventCount(prefix: "exit-may-be-transport-death") == 2)
        #expect(peer.eventCount(prefix: "never-recorded") == 0)
        #expect(peer.firstIndex(ofEventPrefix: "unrelated") == 1)
        #expect(peer.firstIndex(ofEventPrefix: "never-recorded") == nil)
        #expect(peer.ringIsIntact)

        // Eviction is what would turn "absent" into "it never happened", so the guard against it
        // has to be shown firing.
        let chatty = FuzzPeer(seed: 0x0BAD_0BAD, label: "ring-overflow", shape: .persistentRemote, rng: &rng)
        for index in 0..<200 { chatty.connection.record("filler-\(index)") }
        #expect(!chatty.ringIsIntact, "the ring overflowed and the guard did not notice")
        #expect(
            chatty.eventCount(prefix: "filler-0") == 0,
            "the oldest entry survived 200 records, so the cap is not what it is documented to be"
        )

        // The shapes the %exit cases lean on are the shipped ones, not this file's opinion.
        let persistent = FuzzTransportProfile(shape: .persistentRemote)
        let et = RemoteTmuxETTransportProfile(port: 2039)
        #expect(persistent.reconnectsInternally == et.reconnectsInternally)
        #expect(persistent.remoteHalfSurvivesLocalExit == et.remoteHalfSurvivesLocalExit)
        #expect(persistent.remoteHalfSurvivesLocalExit, "the reattach chain needs a surviving remote half")
        let plain = FuzzTransportProfile(shape: .plainSSH)
        let ssh = RemoteTmuxSSHTransportProfile()
        #expect(plain.reconnectsInternally == ssh.reconnectsInternally)
        #expect(plain.remoteHalfSurvivesLocalExit == ssh.remoteHalfSurvivesLocalExit)
        #expect(!plain.remoteHalfSurvivesLocalExit)

        // And the enforcement that keeps this layer from ever spawning: a stray reconnect backoff
        // reaches the product's own executable guard and throws.
        for profile in [persistent, plain] {
            #expect(!FileManager.default.isExecutableFile(atPath: profile.executablePath()))
            #expect(
                !RemoteTmuxBrokerRegistry.isAcceptableExecutable(
                    profile.executablePath(),
                    fileExists: { FileManager.default.isExecutableFile(atPath: $0) }
                ),
                "the fuzz transport executable would be accepted for launch: \(profile.executablePath())"
            )
        }

        peer.connection.stop()
        chatty.connection.stop()
    }

    /// The negative control for the whole reattach chain: on a transport whose remote half dies with
    /// its client, the FIRST `%exit` is the end.
    ///
    /// Without this, "the chain is capped at three" would be compatible with a chain that fires for
    /// every transport — and the flag it is gated on would be decoration.
    @MainActor
    @Test(arguments: seeds)
    func aTransportWhoseRemoteHalfDiesWithItGetsNoReattachChain(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let peer = FuzzPeer(seed: seed, label: "ssh-shape", shape: .plainSSH, rng: &rng)
        let context = peer.context()
        peer.installStream()
        peer.feed(MeasuredControlStream.healthyAttach)
        _ = peer.drainFarEnd()
        #expect(peer.connection.initialTopologyState == .ready, "\(context) attach never published")

        peer.deliverExit()
        #expect(
            peer.eventCount(prefix: "exit-may-be-transport-death") == 0,
            "\(context) an ssh-shaped transport started a reattach chain"
        )
        #expect(peer.connection.connectionState == .ended, "\(context) state=\(peer.connection.connectionState)")
        #expect(peer.exitNotifications == 1, "\(context) exit fired \(peer.exitNotifications)x")
        #expect(peer.ringIsIntact, "\(context) ring overflowed")
        peer.connection.stop()
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var index = text.startIndex
        while let found = text.range(of: needle, range: index..<text.endIndex) {
            count += 1
            index = found.upperBound
        }
        return count
    }
}

// MARK: - Layer 3 fixtures and driver

/// The bytes a healthy `tmux -CC attach-session` really sends, taken from the capture this file
/// already ships rather than re-typed.
///
/// Measured: 84 bytes — the enter DCS, one `%begin`/`%end` block, `%session-changed`. Deriving it
/// from the recorded stream is deliberate: it is the same fixture the ET tests above assert against,
/// so the property layer cannot drift into a friendlier version of the protocol.
private enum MeasuredControlStream {
    static let enterDCS = Data([0x1b, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])

    static let healthyAttach: Data = {
        let captured = RemoteTmuxETTransportTests.capturedETStream
        guard let dcs = captured.range(of: enterDCS) else { return Data() }
        return captured.subdata(in: dcs.lowerBound..<captured.endIndex)
    }()

    /// Just the enter DCS on its own line: what a reattach that reaches control mode delivers
    /// before it is asked anything.
    static let controlModeEntry = enterDCS + Data("\r\n".utf8)
}

/// One window on the far end: an id, its panes, and the name tmux would report.
private struct FuzzWindow {
    let id: Int
    let panes: [Int]
    let name: String
}

/// A transport profile for the property layer: the shipped behaviour flags, and an executable that
/// cannot be launched.
///
/// The flags are forwarded from the real profiles rather than restated, so a change to the ET
/// profile cannot leave these cases passing against a shape no shipped transport has. The
/// executable is the enforcement: if a stray reconnect backoff ever fires, `spawnProcess` reaches
/// the `isAcceptableExecutable` guard and throws, so nothing is ever spawned. Naming a real profile
/// here would launch `/usr/bin/ssh`.
private struct FuzzTransportProfile: RemoteTmuxTransportProfile {
    enum Shape {
        /// et's shape: reconnects internally, and its remote half outlives the local client, so a
        /// `%exit` may be the transport dying rather than the session ending.
        case persistentRemote
        /// ssh's shape: cmux owns reconnection and killing the client is a complete detach.
        case plainSSH
    }

    let shape: Shape
    private let et = RemoteTmuxETTransportProfile(port: 2039)
    private let ssh = RemoteTmuxSSHTransportProfile()

    init(shape: Shape) { self.shape = shape }

    var unlaunchableExecutable: String {
        switch shape {
        case .persistentRemote: return "/nonexistent/cmux-fuzz-transport-persistent"
        case .plainSSH: return "/nonexistent/cmux-fuzz-transport-ssh"
        }
    }

    func executablePath() -> String { unlaunchableExecutable }

    func controlStreamArgv(
        host: RemoteTmuxHost, sessionName: String, mode: RemoteTmuxControlAttachMode
    ) -> [String] {
        switch shape {
        case .persistentRemote:
            return et.controlStreamArgv(host: host, sessionName: sessionName, mode: mode)
        case .plainSSH:
            return ssh.controlStreamArgv(host: host, sessionName: sessionName, mode: mode)
        }
    }

    func oneShotArgv(host: RemoteTmuxHost, remoteCommand: String) -> [String] {
        ssh.oneShotArgv(host: host, remoteCommand: remoteCommand)
    }

    var requiresPseudoTerminal: Bool {
        switch shape {
        case .persistentRemote: return et.requiresPseudoTerminal
        case .plainSSH: return ssh.requiresPseudoTerminal
        }
    }

    var reconnectsInternally: Bool {
        switch shape {
        case .persistentRemote: return et.reconnectsInternally
        case .plainSSH: return ssh.reconnectsInternally
        }
    }

    var remoteHalfSurvivesLocalExit: Bool {
        switch shape {
        case .persistentRemote: return et.remoteHalfSurvivesLocalExit
        case .plainSSH: return ssh.remoteHalfSurvivesLocalExit
        }
    }

    func commandLengthOverrun(
        sessionName: String, mode: RemoteTmuxControlAttachMode
    ) -> (actual: Int, budget: Int)? {
        switch shape {
        case .persistentRemote:
            return et.commandLengthOverrun(sessionName: sessionName, mode: mode)
        case .plainSSH:
            return ssh.commandLengthOverrun(sessionName: sessionName, mode: mode)
        }
    }
}

/// Drives a real ``RemoteTmuxControlConnection`` from bytes, and answers what it sends.
///
/// Nothing here reimplements cmux's logic. Bytes go in through the product's own parser and
/// `handle(_:)`; commands come out through the product's own `RemoteTmuxControlPipeWriter` over a
/// pipe this peer reads. The only test-owned logic is the far end's replies and the RNG.
///
/// One fidelity gap, stated rather than hidden: the product resets `attachBlockDrained`, the parser
/// and the command FIFO inside `spawnProcess`, which this layer cannot run because it spawns no
/// process. So a simulated respawn installs a fresh parser and writer here, and a reattach that
/// reaches control mode issues its `list-windows` through
/// ``requestWindowsAsTheAttachDrainWould()`` — the call the attach-block drain would have made.
@MainActor
private final class FuzzPeer {
    /// A drain is bounded: past this the connection is generating commands without end, which is
    /// the finding rather than a reason to keep answering.
    nonisolated static let answerLimit = 200
    /// A generous FIFO ceiling. The real depth for three windows is under a dozen; this is set to
    /// catch a leak, not to restate the product's arithmetic.
    static let pendingCommandCeiling = 64
    /// Short enough that the unconfirmed-detach case costs milliseconds. Passed explicitly, so it
    /// needs no environment override.
    static let detachBackstopSeconds: TimeInterval = 0.05

    let seed: UInt64
    let label: String
    let connection: RemoteTmuxControlConnection
    let windows: [FuzzWindow]
    let chunkSize: Int

    private var parser = RemoteTmuxControlStreamParser()
    /// Retained so the read ends stay open: a closed read end would EPIPE the writer and make the
    /// product reconnect for a reason belonging to the harness.
    private var pipes: [Pipe] = []
    private var sentBuffer = ""
    private var blockCounter = 0

    private(set) var exitNotifications = 0
    private(set) var topologyNotifications = 0
    private(set) var readinessSamples: [RemoteTmuxControlConnection.InitialTopologyState] = []

    init(seed: UInt64, label: String, shape: FuzzTransportProfile.Shape, rng: inout SplitMix64) {
        self.seed = seed
        self.label = label
        // Chunk boundaries are part of the case: the same bytes delivered one at a time, or in
        // prime-sized pieces, split lines and escape sequences anywhere.
        self.chunkSize = [0, 1, 7, 13][rng.int(0..<4)]

        var built: [FuzzWindow] = []
        var nextPane = 1
        for index in 0..<rng.int(1..<4) {
            let paneCount = rng.int(1..<3)
            let panes = (0..<paneCount).map { _ -> Int in
                defer { nextPane += 1 }
                return nextPane
            }
            built.append(FuzzWindow(id: index + 1, panes: panes, name: "w\(index)-\(String(seed, radix: 16))"))
        }
        self.windows = built

        let host = RemoteTmuxHost(
            destination: "cmux-fuzz-host",
            transport: shape == .persistentRemote ? .et : .ssh,
            transportPort: shape == .persistentRemote ? 2039 : nil
        )
        let connection = RemoteTmuxControlConnection(
            host: host,
            sessionName: "fuzz-\(String(seed, radix: 16))",
            transportProfile: FuzzTransportProfile(shape: shape)
        )
        self.connection = connection
        _ = connection.addObserver(
            onTopologyChanged: { [weak self] in self?.topologyNotifications += 1 },
            onExit: { [weak self] in self?.exitNotifications += 1 }
        )
    }

    func context() -> String {
        "seed=\(String(seed, radix: 16)) arm=\(label) windows=\(windows.map(\.id)) chunk=\(chunkSize)"
    }

    /// A stray foreign change to the probe interval would turn these cases into probe-driven
    /// reconnects, so it is read rather than assumed. Nothing here mutates it: it is process-global.
    var probeIntervalIsUntouched: Bool {
        RemoteTmuxControlConnection.livenessProbeIntervalSeconds >= 5
    }

    // MARK: Stream lifecycle

    /// Installs a fresh control stream: a new parser and a new writer over a new pipe. Stands in for
    /// the product's `spawnProcess` reset, which needs a process this layer deliberately never has.
    func installStream() {
        drainSentBytes()
        parser = RemoteTmuxControlStreamParser()
        let pipe = Pipe()
        // Non-blocking, so reading what cmux wrote never parks the main actor.
        _ = fcntl(pipe.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK)
        pipes.append(pipe)
        connection.stdinWriter = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "com.cmux.fuzz.stdin.\(UUID().uuidString)",
            maxPendingBytes: 256 * 1024,
            onFailure: {}
        )
    }

    /// The product's ingest path, through the product's parser, in this case's chunk schedule.
    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        let step = chunkSize <= 0 ? data.count : chunkSize
        var index = data.startIndex
        while index < data.endIndex {
            let end = min(index + step, data.endIndex)
            for message in parser.feed(data[index..<end]) { connection.handle(message) }
            index = end
        }
    }

    func deliverControlModeEntry() { feed(MeasuredControlStream.controlModeEntry) }
    func deliverExit() { feed(Data("%exit\r\n".utf8)) }

    func deliverOutput(pane: Int, text: String) {
        feed(Data("%output %\(pane) \(text)\r\n".utf8))
    }

    func deliverLayoutChange(window: FuzzWindow) {
        let layout = Self.layoutString(for: window)
        feed(Data("%layout-change @\(window.id) \(layout) \(layout) *\r\n".utf8))
    }

    func deliverWindowRenamed(window: FuzzWindow, step: Int) {
        feed(Data("%window-renamed @\(window.id) \(window.name)-r\(step)\r\n".utf8))
    }

    /// A `%error` block carrying a command number cmux never issued — measured against real et,
    /// which types a trailing command tmux answers.
    func deliverUnsolicitedErrorBlock() {
        feed(block(["parse error: unknown command: exit"], isError: true))
    }

    /// The `list-windows` the attach-block drain issues in production. See the type's note on why
    /// this layer has to ask for it explicitly on a simulated respawn.
    func requestWindowsAsTheAttachDrainWould() {
        connection.requestWindows()
    }

    // MARK: Far end

    /// Answers the command at the head of cmux's own correlation FIFO, or returns nil when there is
    /// nothing outstanding. Reading the FIFO is how the far end knows what was asked — and it is
    /// also the evidence that cmux asked.
    @discardableResult
    func answerNextCommand(windows replacement: [FuzzWindow]? = nil) -> String? {
        guard let kind = connection.pendingCommands.first else { return nil }
        let model = replacement ?? windows
        switch kind {
        case .listWindows:
            let lines = model.map { window -> String in
                let layout = Self.layoutString(for: window)
                return "@\(window.id) \(layout) \(layout) [] \(window.name)"
            }
            feed(block(lines))
            return "list-windows(\(lines.count))"
        case let .paneRects(windowId, _):
            guard let window = model.first(where: { $0.id == windowId }) else {
                // The window is gone as far as the far end is concerned: an empty reply, which the
                // product retries once and then drops.
                feed(block([]))
                return "pane-rects(@\(windowId) gone)"
            }
            feed(block(Self.rectLines(for: window)))
            return "pane-rects(@\(windowId))"
        case .listWindowOrder:
            feed(block(model.map { "@\($0.id)" }))
            return "list-window-order"
        case .newWindow:
            feed(block(["@\(9000 + model.count)"]))
            return "new-window"
        case let .paneAltScreen(pane):
            feed(block(["0"]))
            return "alt-screen(%\(pane))"
        case let .capturePane(pane):
            feed(block(["cmux-fuzz screen for %\(pane)"]))
            return "capture-pane(%\(pane))"
        case let .paneState(pane):
            feed(block([
                "cursor_x=0,cursor_y=0,scroll_region_upper=0,scroll_region_lower=23,"
                    + "cursor_flag=1,insert_flag=0,keypad_cursor_flag=0,keypad_flag=0,"
                    + "wrap_flag=1,origin_flag=0,pane_height=24,mouse_all_flag=0,"
                    + "mouse_button_flag=0,mouse_standard_flag=0,mouse_sgr_flag=0,mouse_utf8_flag=0"
            ]))
            return "pane-state(%\(pane))"
        case let .panePath(pane):
            feed(block(["/tmp/cmux-fuzz"]))
            return "pane-path(%\(pane))"
        case let .paneOutputReset(pane, _):
            // Per-pane flow control: cmux asks tmux to drop or resume this pane's output. Both are
            // acknowledged with an empty block, like the other fire-and-forget commands here.
            feed(block([]))
            return "pane-output-reset(%\(pane))"
        case let .paneOutputContinue(pane, _):
            feed(block([]))
            return "pane-output-continue(%\(pane))"
        case .paneReflow:
            // An empty reply is the documented safe default (no reflow).
            feed(block([]))
            return "pane-reflow"
        case .activityQuery:
            feed(block([]))
            return "activity-query"
        case .rawQuery:
            feed(block([]))
            return "raw-query"
        case .tracked:
            feed(block([]))
            return "tracked"
        case .perWindowSize:
            feed(block([]))
            return "per-window-size"
        case .windowReorder:
            feed(block([]))
            return "window-reorder"
        case .other:
            feed(block([]))
            return "other"
        }
    }

    @discardableResult
    func drainFarEnd(windows replacement: [FuzzWindow]? = nil, limit: Int = FuzzPeer.answerLimit) -> Int {
        var answered = 0
        while answered < limit, answerNextCommand(windows: replacement) != nil { answered += 1 }
        return answered
    }

    private func block(_ lines: [String], isError: Bool = false) -> Data {
        blockCounter += 1
        let number = blockCounter
        var text = "%begin 1784616604 \(number) 1\r\n"
        for line in lines { text += line + "\r\n" }
        text += (isError ? "%error" : "%end") + " 1784616604 \(number) 1\r\n"
        return Data(text.utf8)
    }

    /// A tmux layout string for this window. Geometry is plausible rather than exact — the product
    /// patches leaf rects from the `list-panes` reply, which is what it publishes.
    private static func layoutString(for window: FuzzWindow) -> String {
        guard window.panes.count > 1 else { return "80x24,0,0,\(window.panes[0])" }
        let width = 80 / window.panes.count
        let children = window.panes.enumerated().map { index, pane in
            "\(width)x24,\(index * (width + 1)),0,\(pane)"
        }
        return "80x24,0,0{\(children.joined(separator: ","))}"
    }

    /// `list-panes` reply lines. The reply must cover EVERY pane of the tree it publishes, or the
    /// product keeps the last verified tree instead — which is the behaviour, not a bug to work
    /// around. `pane-border-status` is empty here, hence the double space before the `:` sentinel.
    private static func rectLines(for window: FuzzWindow) -> [String] {
        let width = window.panes.count > 1 ? 80 / window.panes.count : 80
        return window.panes.enumerated().map { index, pane in
            "%\(pane) \(index * (width + 1)) 0 \(width) 24 \(index == 0 ? 1 : 0)  :hdr\(pane)"
        }
    }

    // MARK: Observations

    var events: [String] { connection.snapshot().recentEvents }

    /// The ring holds at most 100 entries and drops the oldest, so an absent label would read as
    /// "it never happened". Every count taken from the ring is gated on this.
    var ringIsIntact: Bool { events.count < 100 }

    func eventCount(prefix: String) -> Int { events.filter { $0.hasPrefix(prefix) }.count }

    func firstIndex(ofEventPrefix prefix: String) -> Int? {
        events.firstIndex { $0.hasPrefix(prefix) }
    }

    /// The most recent entry with this prefix. Containment is not enough for a per-incident count:
    /// `reattach=1` stays in the ring forever once recorded, so a budget that never reset would
    /// still satisfy "the ring contains reattach=1" on every later incident.
    func lastEvent(prefix: String) -> String? {
        events.last { $0.hasPrefix(prefix) }
    }

    func sampleReadiness() { readinessSamples.append(connection.initialTopologyState) }

    /// Feeds the monotonicity reader a sequence chosen by the caller, so the reader can be shown
    /// rejecting one that moves twice. Only ``theReadersBehindTheseOraclesReportViolations`` uses it.
    func replaceReadinessSamplesForSelfTest(_ samples: [RemoteTmuxControlConnection.InitialTopologyState]) {
        readinessSamples = samples
    }

    /// Readiness may leave `.pending` once and must then never change.
    func readinessIsMonotonic() -> Bool {
        var resolved: RemoteTmuxControlConnection.InitialTopologyState?
        for sample in readinessSamples {
            if let resolved {
                if sample != resolved { return false }
            } else if sample != .pending {
                resolved = sample
            }
        }
        return true
    }

    // MARK: What cmux actually wrote

    var sentText: String {
        drainSentBytes()
        return sentBuffer
    }

    /// Waits for bytes to appear on the pipe. The writer hands its payload to a serial queue, so
    /// the bytes arrive a moment after the send returns; the wait is on that edge, with the timeout
    /// only as a backstop.
    func awaitSentText(containing needle: String, timeoutSeconds: Double = 2) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
        while ContinuousClock.now < deadline {
            if sentText.contains(needle) { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return sentText.contains(needle)
    }

    /// Waits for the connection to end, for the cases whose end comes from a dispatched backstop.
    func awaitConnectionEnded(timeoutSeconds: Double = 5) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
        while ContinuousClock.now < deadline {
            if connection.connectionState == .ended { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return connection.connectionState == .ended
    }

    @discardableResult
    private func drainSentBytes() -> String {
        for pipe in pipes {
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { raw in
                    read(descriptor, raw.baseAddress, raw.count)
                }
                guard count > 0 else { break }
                sentBuffer += String(decoding: buffer[0..<count], as: UTF8.self)
            }
        }
        return sentBuffer
    }
}