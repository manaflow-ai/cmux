import CmuxMobileSSH
@testable import CmuxiOSSSHCore
import Foundation
import Testing

/// E3: SSH session discovery and attach commands (e3-workspaces.md section 6).
@Suite struct SSHDiscoveryTests {
    let discovery = SSHSessionDiscovery()

    @Test func sessionNamesAreValidatedAgainstTheAllowedSet() {
        for good in ["main", "cmux-1", "a.b:c_d", "12345.pts-0.host"] {
            #expect(SSHSessionName(validating: good)?.rawValue == good)
        }
        for bad in ["", "-t", "has space", "a;rm -rf ~", "$(id)", "a'b", "a\nb", "ü", String(repeating: "a", count: 129)] {
            #expect(SSHSessionName(validating: bad) == nil, "\(bad)")
        }
    }

    @Test func binaryPathsArePlainAbsolutePaths() {
        #expect(SSHRemoteBinary(validatingPath: "/opt/homebrew/bin/tmux")?.path == "/opt/homebrew/bin/tmux")
        #expect(SSHRemoteBinary(validatingPath: "/home/u/.local/bin/cmux-tui")?.path == "/home/u/.local/bin/cmux-tui")
        for bad in ["tmux", "/usr/bin/tmux; id", "/a b/tmux", "/x/../tmux", "/$(id)", "/a:b"] {
            #expect(SSHRemoteBinary(validatingPath: bad) == nil, "\(bad)")
        }
    }

    @Test func attachCommandsQuoteEveryArgument() throws {
        let tmux = try #require(SSHRemoteBinary(validatingPath: "/usr/bin/tmux"))
        let name = try #require(SSHSessionName(validating: "work"))
        #expect(SSHSessionTarget.tmux(binary: tmux, session: name, window: nil).attachCommand
            == "exec '/usr/bin/tmux' attach-session -t '=work'")
        #expect(SSHSessionTarget.tmux(binary: tmux, session: name, window: 2).attachCommand
            == "exec '/usr/bin/tmux' attach-session -t '=work:2'")
        let screen = try #require(SSHSessionName(validating: "4242.build"))
        #expect(SSHSessionTarget.screen(binary: .screen, session: screen).attachCommand == "exec 'screen' -x '4242.build'")
        let socket = try #require(SSHCmuxTUISocket(validatingPath: "/tmp/cmux-tui-501/work.sock"))
        #expect(SSHSessionTarget.cmuxTUI(binary: .cmuxTUI, socket: socket).attachCommand
            == "exec 'cmux-tui' attach --socket '/tmp/cmux-tui-501/work.sock'")
        #expect(SSHSessionTarget.tmux(binary: tmux, session: name, window: 2).surfaceID == "ssh:tmux:work:2")
    }

    @Test func parsesTmuxScreenAndCmuxTUI() {
        let output = """
        @tmux\t/usr/bin/tmux
        S\twork\t2\t1\t1791331200
        S\tbad name\t1\t0\t1
        S\tidle\t1\t0\t1791331000
        W\twork\t1\t0\tlogs
        W\twork\t0\t1\tzsh\twith tab
        W\tidle\t0\t1\tvim
        W\tbad name\t0\t1\tx
        @screen\t/usr/bin/screen
        There are screens on:
        \t4242.build\t(Detached)
        \t77.pts-1.box\t(Attached)
        \t88.$(id)\t(Detached)
        2 Sockets in /run/screen/S-u.
        @cmux-tui\t/home/u/.local/bin/cmux-tui
        C\t/run/user/1000/cmux-tui-1000/cmux-ios.sock
        C\t/tmp/cmux-tui-1000/cmux-ios.sock
        C\t/tmp/cmux-tui-1000/-evil.sock
        """
        let sessions = discovery.parse(output)
        #expect(sessions.map(\.id) == ["ssh:tmux:work", "ssh:tmux:idle", "ssh:screen:4242.build", "ssh:screen:77.pts-1.box",
                                       "ssh:cmux-tui:cmux-ios"])
        let work = sessions[0]
        #expect(work.isAttached)
        #expect(work.activity == 1_791_331_200)
        #expect(work.windows.map(\.index) == [0, 1])
        #expect(work.windows[0].name == "zsh\twith tab")
        #expect(work.windows[0].isActive)
        #expect(work.target.attachCommand == "exec '/usr/bin/tmux' attach-session -t '=work'")
        #expect(sessions[2].isAttached == false)
        #expect(sessions[3].isAttached)
        #expect(sessions[2].target.attachCommand == "exec '/usr/bin/screen' -x '4242.build'")
        #expect(sessions[4].target.attachCommand == "exec '/home/u/.local/bin/cmux-tui' attach --socket '/run/user/1000/cmux-tui-1000/cmux-ios.sock'")
    }

    @Test func noToolsMeansNoSessionsAndBadPathsFallBackToNames() {
        #expect(discovery.parse("").isEmpty)
        let sessions = discovery.parse("@tmux\t/x/../tmux\nS\tmain\t1\t0\t0\n")
        #expect(sessions.first?.target.attachCommand == "exec 'tmux' attach-session -t '=main'")
    }

    @Test func theScriptTakesNoInputAndRunsUnderSh() {
        #expect(discovery.command == "/bin/sh -s")
        #expect(discovery.input.hasSuffix("exit 0\n"))
        #expect(SSHSessionDiscovery.script.contains("list-sessions -F 'S\t#{session_name}"))
        #expect(SSHSessionDiscovery.script.contains("list-panes -a -F 'P2\t#{window_id}"))
        #expect(SSHSessionDiscovery.script.contains("screen -ls"))
    }

    @Test func pinnedVerifierNeverTrustsUnknownKeys() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let known = SSHKnownHostsFile(url: directory.appendingPathComponent("known_hosts"))
        let verifier = PinnedHostKeyVerifier(knownHosts: known)
        let endpoint = SSHEndpoint(host: "box", port: 22, username: "u")
        let key = SSHKnownHostsTests.keyA
        #expect(await verifier.verify(key, for: endpoint) == false)
        await known.pin(key, for: endpoint.hostKeyIdentity)
        #expect(await verifier.verify(key, for: endpoint))
        #expect(await verifier.verify(SSHKnownHostsTests.keyB, for: endpoint) == false)
    }
}
