import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Every ssh-tmux invocation supplies its own remote command (`true` for
/// interactive auth, `tmux -CC …` for the mirror, one-shot discovery
/// commands), so a host ssh_config `RemoteCommand` would abort them all with
/// OpenSSH's "Cannot execute command-line and remote command." (exit 255,
/// https://github.com/manaflow-ai/cmux/issues/7246) — the shared control
/// args must clear it with `-o RemoteCommand=none`.
@Suite struct RemoteTmuxHostRemoteCommandOverrideTests {
    @Test(arguments: [true, false])
    func controlArgsOverrideHostConfiguredRemoteCommand(batchMode: Bool) {
        let host = RemoteTmuxHost(destination: "user@host")
        let args = host.sshControlArguments(controlPersistSeconds: 180, batchMode: batchMode)
        #expect(consecutive(args, "-o", "RemoteCommand=none"))
    }

    @Test func controlModeArgumentsOverrideHostRemoteCommandAndKeepForcedTTY() {
        let host = RemoteTmuxHost(destination: "user@host")
        let args = host.controlModeArguments(sessionName: "work", createIfMissing: false)
        #expect(consecutive(args, "-o", "RemoteCommand=none"))
        // The remote `tmux attach` still needs its forced PTY.
        #expect(args.first == "-tt")
    }

    @Test func interactiveAuthInvocationOverridesHostConfiguredRemoteCommand() {
        let host = RemoteTmuxHost(destination: "user@host")
        #expect(consecutive(host.interactiveAuthInvocation(), "-o", "RemoteCommand=none"))
    }

    /// True when `a` is immediately followed by `b` in `args` — i.e. an ssh
    /// `-o KEY=VALUE` pair is adjacent, as ssh requires.
    private func consecutive(_ args: [String], _ a: String, _ b: String) -> Bool {
        for i in args.indices.dropLast() where args[i] == a && args[i + 1] == b {
            return true
        }
        return false
    }
}
