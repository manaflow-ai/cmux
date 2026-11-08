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

    @Test func socketNameHashIsStableAcrossTransports() {
        let ssh = RemoteTmuxHost(destination: "dev@host", socketName: "alpha")
        let et = RemoteTmuxHost(destination: "dev@host", transport: .et, socketName: "alpha")
        #expect(ssh.connectionHash != et.connectionHash)
        #expect(
            RemoteTmuxHost(destination: "dev@host", socketName: "alpha").connectionHash
                == ssh.connectionHash)
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

    @Test func eternalTerminalLengthBudgetCountsTheSocketFlag() {
        let longest = String(repeating: "n", count: RemoteTmuxETTransportProfile.maxSessionNameBytes())
        let plain = RemoteTmuxETTransportProfile()
        #expect(plain.commandLengthOverrun(sessionName: longest, mode: .attach) == nil)
        let withSocket = RemoteTmuxETTransportProfile(socketName: "alpha")
        #expect(withSocket.commandLengthOverrun(sessionName: longest, mode: .attach) != nil)
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
