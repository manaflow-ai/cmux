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
        // The static builder, used by callers that have no host, stays socket-free.
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
        // The boundary's pre-check derives its own limit; it may be conservative but never
        // admits a name the spawn gate would refuse.
        #expect(RemoteTmuxETTransportProfile.maxSessionNameBytes(socketName: "alpha") <= budget - fixed)
    }

    /// The socket boundary's pre-check applies the same budget, so an over-long name for a named
    /// et server is refused as invalid params instead of timing out at attach.
    @Test func socketBoundaryCountsTheSocketNameInTheSessionLengthCheck() {
        let unnamedLimit = String(repeating: "n", count: RemoteTmuxETTransportProfile.maxSessionNameBytes())
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
