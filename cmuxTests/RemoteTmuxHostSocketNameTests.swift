import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A host with a tmux socket name (`tmux -L <name>`) is a distinct endpoint: it gets its own
/// connection hash, its own ControlMaster socket, and `-L <name>` on every tmux command it
/// runs, while a host without one keeps the identity it has today (#15022).
@Suite struct RemoteTmuxHostSocketNameTests {
    @Test func hostWithoutSocketNameKeepsItsExistingHash() {
        let host = RemoteTmuxHost(destination: "dev@host")
        // The fingerprint format that shipped before socket names existed: destination, port,
        // identity file, unit-separated. Changing it would orphan every live master socket.
        #expect(host.connectionHash == RemoteTmuxHost.fnv1a64Hex("dev@host\u{1f}\u{1f}"))
        #expect(host.socketName == nil)
    }

    @Test func socketNamesOnOneHostHashDifferently() {
        let plain = RemoteTmuxHost(destination: "dev@host")
        let alpha = RemoteTmuxHost(destination: "dev@host", socketName: "alpha")
        let beta = RemoteTmuxHost(destination: "dev@host", socketName: "beta")

        #expect(alpha.connectionHash != plain.connectionHash)
        #expect(beta.connectionHash != plain.connectionHash)
        #expect(alpha.connectionHash != beta.connectionHash)
        // Identity and the ControlMaster socket follow the hash, so the two servers never share
        // a master that multiplexes destructive commands.
        #expect(alpha.id != beta.id)
        #expect(alpha.controlSocketPath != beta.controlSocketPath)
        #expect(alpha.controlSocketPath != plain.controlSocketPath)
    }

    @Test func socketNameIsPartOfIdentityOnEveryTransport() {
        let ssh = RemoteTmuxHost(destination: "dev@host", socketName: "alpha")
        let etPlain = RemoteTmuxHost(destination: "dev@host", transport: .et)
        let etAlpha = RemoteTmuxHost(destination: "dev@host", transport: .et, socketName: "alpha")
        let etBeta = RemoteTmuxHost(destination: "dev@host", transport: .et, socketName: "beta")
        // The transport is part of identity, so ssh and et never share a key for one name.
        #expect(ssh.connectionHash != etAlpha.connectionHash)
        // And the socket name stays part of identity under et, where the command is built
        // separately: two servers, and the default, are three endpoints.
        #expect(etAlpha.connectionHash != etPlain.connectionHash)
        #expect(etBeta.connectionHash != etPlain.connectionHash)
        #expect(etAlpha.connectionHash != etBeta.connectionHash)
        // Deterministic: the same spelling hashes the same way twice.
        #expect(
            RemoteTmuxHost(destination: "dev@host", socketName: "alpha").connectionHash
                == ssh.connectionHash)
    }

    /// `tmux -L default` is the server the flag's absence names, so the two spellings are one
    /// endpoint: same hash, same master socket, and no `-L` on the wire.
    @Test func defaultSocketNameIsTheDefaultServer() {
        let plain = RemoteTmuxHost(destination: "dev@host")
        let named = RemoteTmuxHost(destination: "dev@host", socketName: "default")
        #expect(named.socketName == nil)
        #expect(named.connectionHash == plain.connectionHash)
        #expect(named.controlSocketPath == plain.controlSocketPath)
        #expect(!named.tmuxRemoteCommand(arguments: ["list-sessions"]).contains("-L"))

        let viaSocket = TerminalController.remoteTmuxHost(
            from: ["host": "dev@host", "socket_name": "default"], selectBroker: { _ in .none })
        #expect(viaSocket == plain)
    }

    @Test func controlModeArgumentsSelectTheSocket() {
        let host = RemoteTmuxHost(destination: "dev@host", socketName: "alpha")
        let remote = host.controlModeArguments(sessionName: "work", mode: .attach).last ?? ""
        #expect(remote.contains("'-L' 'alpha' '-CC' 'attach-session' '-t' 'work'"))

        let plain = RemoteTmuxHost(destination: "dev@host")
        let plainRemote = plain.controlModeArguments(sessionName: "work", mode: .attach).last ?? ""
        #expect(!plainRemote.contains("-L"))
    }

    @Test func oneShotCommandsSelectTheSocket() {
        let host = RemoteTmuxHost(destination: "dev@host", socketName: "alpha")
        let command = host.tmuxRemoteCommand(arguments: ["list-sessions", "-F", "#{session_name}"])
        #expect(command.contains("'-L' 'alpha' 'list-sessions'"))
        // The static builder takes no host, so it cannot name a server and stays socket-free.
        #expect(!RemoteTmuxHost.tmuxRemoteCommand(arguments: ["list-sessions"]).contains("-L"))
    }

    @Test func eternalTerminalControlStreamSelectsTheSocket() {
        let host = RemoteTmuxHost(destination: "dev@host", transport: .et, socketName: "alpha")
        let argv = host.transportProfile.controlStreamArgv(host: host, sessionName: "work", mode: .attach)
        let command = argv.first { $0.hasPrefix("exec ") } ?? ""
        #expect(command == "exec 'tmux' '-L' 'alpha' '-CC' 'attach-session' '-t' 'work'")
        #expect(
            RemoteTmuxETTransportProfile.controlStreamRemoteCommand(sessionName: "work", mode: .attach)
                == "'tmux' '-CC' 'attach-session' '-t' 'work'")
    }

    /// The et line budget is 1024 (MAX_CANON) minus the 96-byte transport allowance, and the
    /// named-server attach line is `'tmux' '-L' 'alpha' '-CC' 'attach-session' '-t' '<name>'`.
    /// Both figures are written out here rather than read back from the profile, so the test
    /// checks the limit cmux intends and not whatever the implementation happens to compute.
    @Test func eternalTerminalLengthBudgetCountsTheSocketFlag() {
        let budget = 1024 - 96
        let fixed = "'tmux' '-L' 'alpha' '-CC' 'attach-session' '-t' ''".utf8.count
        let fits = String(repeating: "n", count: budget - fixed)
        let oneTooLong = fits + "n"
        let named = RemoteTmuxETTransportProfile(socketName: "alpha")

        #expect(named.commandLengthOverrun(sessionName: fits, mode: .attach) == nil)
        let overrun = named.commandLengthOverrun(sessionName: oneTooLong, mode: .attach)
        #expect(overrun?.actual == budget + 1)
        #expect(overrun?.budget == budget)
        // The same name fits a default-server line, which is 12 bytes shorter.
        #expect(RemoteTmuxETTransportProfile().commandLengthOverrun(sessionName: oneTooLong, mode: .attach) == nil)
        // The boundary's limit is the same figure, so the two gates agree byte for byte.
        #expect(RemoteTmuxETTransportProfile.maxSessionNameBytes(socketName: "alpha") == budget - fixed)
    }

    /// The socket boundary's pre-check applies the same budget, so an over-long name for a named
    /// et server is refused as invalid params instead of timing out at attach.
    @Test func socketBoundaryCountsTheSocketNameInTheSessionLengthCheck() {
        let unnamedLimit = String(repeating: "n", count: RemoteTmuxETTransportProfile.maxSessionNameBytes())
        // A name at the limit fills the line exactly, and both gates accept it: the boundary
        // must not refuse a name the spawn gate would run.
        #expect(RemoteTmuxETTransportProfile.controlStreamRemoteCommand(sessionName: unnamedLimit, mode: .attach)
            .utf8.count == RemoteTmuxETTransportProfile.deliverableCommandBytes)
        #expect(RemoteTmuxETTransportProfile().commandLengthOverrun(sessionName: unnamedLimit, mode: .attach) == nil)
        #expect(TerminalController.remoteTmuxSessionName(
            from: ["session": unnamedLimit], transport: .et, mode: .attach) == unnamedLimit)
        #expect(TerminalController.remoteTmuxSessionName(
            from: ["session": unnamedLimit, "socket_name": "alpha"], transport: .et, mode: .attach) == nil)
        // `default` costs nothing, exactly as the host builds the command.
        #expect(TerminalController.remoteTmuxSessionName(
            from: ["session": unnamedLimit, "socket_name": "default"], transport: .et, mode: .attach) == unnamedLimit)
        // ssh execs its command and has no line limit.
        #expect(TerminalController.remoteTmuxSessionName(
            from: ["session": unnamedLimit, "socket_name": "alpha"], transport: .ssh, mode: .attach) == unnamedLimit)
        // A quote in the name costs three bytes once shell-quoted, so a name that fits the
        // length bound can still render past the budget; the boundary measures the rendering.
        let quoted = String(unnamedLimit.dropLast()) + "'"
        #expect(quoted.utf8.count == unnamedLimit.utf8.count)
        #expect(TerminalController.remoteTmuxSessionName(
            from: ["session": quoted], transport: .et, mode: .attach) == nil)
        #expect(TerminalController.remoteTmuxSessionName(
            from: ["session": quoted], transport: .ssh, mode: .attach) == quoted)
        // The same rendering check applies with the socket flag on the line.
        let namedLimit = String(
            repeating: "n", count: RemoteTmuxETTransportProfile.maxSessionNameBytes(socketName: "alpha"))
        let namedQuoted = String(namedLimit.dropLast()) + "'"
        #expect(TerminalController.remoteTmuxSessionName(
            from: ["session": namedLimit, "socket_name": "alpha"], transport: .et, mode: .attach) == namedLimit)
        #expect(TerminalController.remoteTmuxSessionName(
            from: ["session": namedQuoted, "socket_name": "alpha"], transport: .et, mode: .attach) == nil)
        #expect(TerminalController.remoteTmuxSessionName(
            from: ["session": namedQuoted, "socket_name": "alpha"], transport: .ssh, mode: .attach) == namedQuoted)
    }

    /// tmux reports a socket path past the AF_UNIX limit as `error connecting to … (File name
    /// too long)`. A long `-L <name>` under a long `TMUX_TMPDIR` is how a user reaches that, and
    /// the server behind it can never be contacted, so it must surface as the command failure it
    /// is rather than be read as an idle server and become an empty session list.
    @Test func anOverlongSocketPathIsNotMisreadAsNoServer() {
        let name = String(repeating: "n", count: 64)
        let directory = "/Users/dev/Library/Caches/cmux/remote-tmux-et/some-host/tmux/tmux-501"
        #expect(!RemoteTmuxSSHTransport.indicatesNoServer(
            "error connecting to \(directory)/\(name) (File name too long)"))
        // The idle-server shapes keep their meaning for a named socket.
        #expect(RemoteTmuxSSHTransport.indicatesNoServer("no server running on /tmp/tmux-501/\(name)"))
        #expect(RemoteTmuxSSHTransport.indicatesNoServer(
            "error connecting to /tmp/tmux-501/\(name) (No such file or directory)"))
    }

    /// The overlong-socket-path failure is cmux's own error. It names the host and says what to
    /// shorten, and carries neither tmux's stderr nor the remote socket path, which would put
    /// the remote account's directory layout into a socket reply or CLI output.
    @Test func anOverlongSocketPathIsReportedWithoutTmuxOutputOrTheRemotePath() {
        let directory = "/Users/dev/Library/Caches/cmux/remote-tmux-et/some-host/tmux/tmux-501"
        let name = String(repeating: "n", count: 64)
        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "dev@example", socketName: name))

        let failure = transport.commandFailure(RemoteTmuxCommandResult(
            exitCode: 1,
            stdout: "",
            stderr: "error connecting to \(directory)/\(name) (File name too long)"
        ))

        #expect(failure == .socketPathTooLong(destination: "dev@example"))
        #expect(failure.message.contains("dev@example"))
        #expect(!failure.message.contains(directory))
        #expect(!failure.message.contains(name))
        #expect(!failure.message.localizedCaseInsensitiveContains("file name too long"))
    }

    /// Any other failed command keeps the generic command failure, exit code included.
    @Test func otherCommandFailuresAreNotReportedAsAnOverlongSocketPath() {
        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "dev@example", socketName: "alpha"))

        let failure = transport.commandFailure(RemoteTmuxCommandResult(
            exitCode: 1,
            stdout: "",
            stderr: "error connecting to /tmp/tmux-501/alpha (Permission denied)"
        ))

        #expect(failure == .commandFailed(
            exitCode: 1, stderr: "error connecting to /tmp/tmux-501/alpha (Permission denied)"))
    }

    @Test func socketBoundaryBuildsAndRefusesSocketNames() {
        let host = TerminalController.remoteTmuxHost(
            from: ["host": "dev@host", "socket_name": "alpha"], selectBroker: { _ in .none })
        #expect(host?.socketName == "alpha")

        let plain = TerminalController.remoteTmuxHost(from: ["host": "dev@host"], selectBroker: { _ in .none })
        #expect(plain?.socketName == nil)

        for bad in ["", "a b", "a;b", "a/b", "-x"] {
            let refused = TerminalController.remoteTmuxHost(
                from: ["host": "dev@host", "socket_name": bad], selectBroker: { _ in .none })
            #expect(refused == nil, "accepted socket_name \(bad.debugDescription)")
            #expect(
                TerminalController.remoteTmuxBrokerFailureMessage(
                    from: ["host": "dev@host", "socket_name": bad], selectBroker: { _ in .none }) != nil)
        }
    }
}

/// The RPC handlers hand the boundary the request's transport and socket name, so a session
/// too long for a named et server is refused by the handler itself as `invalid_params`, before
/// any process is spawned. The boundary tests above prove the arithmetic; this proves the
/// handlers reach it with the right inputs.
@Suite(.serialized, .exclusiveAppContext) struct RemoteTmuxSocketNameHandlerTests {
    @Test(arguments: ["remote.tmux.mirror", "remote.tmux.window", "remote.tmux.attach"])
    func overBudgetSessionOnANamedETServerIsInvalidParams(method: String) async throws {
        let remoteTmuxKey = SettingCatalog().betaFeatures.remoteTmux.userDefaultsKey
        let previousRemoteTmux = UserDefaults.standard.object(forKey: remoteTmuxKey)
        UserDefaults.standard.set(true, forKey: remoteTmuxKey)
        defer {
            if let previousRemoteTmux {
                UserDefaults.standard.set(previousRemoteTmux, forKey: remoteTmuxKey)
            } else {
                UserDefaults.standard.removeObject(forKey: remoteTmuxKey)
            }
        }
        // Exactly fills the default server's line, so only `-L alpha` pushes it over budget.
        let session = String(repeating: "n", count: RemoteTmuxETTransportProfile.maxSessionNameBytes())
        let requestData = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": method,
            "params": ["host": "dev@host", "transport": "et", "socket_name": "alpha", "session": session],
        ])
        let request = try #require(String(data: requestData, encoding: .utf8))
        let responseText = TerminalController.shared.handleSocketLine(request)
        let responseData = try #require(responseText.data(using: .utf8))
        let response = try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])

        #expect(response["ok"] as? Bool == false)
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? String == "invalid_params")
        // The session check is what refused it: the host, transport and socket name were fine.
        let message = try #require(error["message"] as? String)
        #expect(
            message == String(localized: "socket.remoteTmux.sessionRequired", defaultValue: "session is required"),
            "\(method) refused for another reason: \(message)")
        // Nothing was started for the refused endpoint. Every ssh one-shot goes through a
        // transport the registry creates on first use, and every et control stream through a
        // connection the controller records, so an absent entry for this host is an absent process.
        let host = RemoteTmuxHost(destination: "dev@host", transport: .et, socketName: "alpha")
        let controller = try await MainActor.run { try #require(AppDelegate.shared).remoteTmuxController }
        let started = await MainActor.run {
            (transport: controller.transportRegistry.transports[host.connectionHash] != nil,
             connection: controller.connection(host: host, sessionName: session) != nil)
        }
        #expect(!started.transport, "\(method) created an ssh transport for the refused host")
        #expect(!started.connection, "\(method) recorded a control connection for the refused session")
    }
}
