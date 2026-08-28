import Foundation
import Testing
@testable import cmux

@Suite("Harbor probe output parsing")
struct HarborProbeOutputParserTests {
    @Test func parsesMixedToolLines() {
        let output = """
        tmux\tcxtest\tdetached\t1w
        tmux\tdeploy\tattached\t3w
        zellij\tjudicious-magpie\texited\t
        screen\t12345.build\tdetached\t
        zmx\tdev\tattached\t
        herdr\tpr-demo\trunning\t/Users/x/.config/herdr
        cmux-tui\tcxdog\trunning\t/tmp/cmux-tui-501/cxdog.sock
        """
        let sessions = HarborProbeOutputParser.sessions(fromProbeOutput: output, source: .local)
        #expect(sessions.count == 7)
        #expect(sessions[0] == HarborSession(source: .local, tool: .tmux, name: "cxtest", state: .detached, detail: "1w"))
        #expect(sessions[1].state == .attached)
        #expect(sessions[2].tool == .zellij)
        #expect(sessions[2].state == .exited)
        #expect(sessions[6].tool == .cmuxTui)
        #expect(sessions[6].detail == "/tmp/cmux-tui-501/cxdog.sock")
    }

    @Test func skipsMalformedAndUnknownLines() {
        let output = """
        nonsense line without tabs
        futuretool\tx\tattached\t
        tmux\t\tdetached\t
        tmux\tok\tdetached\t
        """
        let sessions = HarborProbeOutputParser.sessions(fromProbeOutput: output, source: .local)
        #expect(sessions.map(\.name) == ["ok"])
    }

    @Test func dedupesRepeatedSessions() {
        // The cmux-tui stanza can report one session from two socket dirs.
        let output = "cmux-tui\tdev\trunning\t/a.sock\ncmux-tui\tdev\trunning\t/b.sock\n"
        let sessions = HarborProbeOutputParser.sessions(fromProbeOutput: output, source: .local)
        #expect(sessions.count == 1)
        #expect(sessions[0].detail == "/a.sock")
    }

    @Test func dropsCmuxInfrastructureSessions() {
        let output = """
        cmux-tui\tcmux-mytag\trunning\t/a.sock
        cmux-tui\tcmux-browser-abc123\trunning\t/b.sock
        cmux-tui\tuser-session\trunning\t/c.sock
        tmux\tcmux-mytag\tdetached\t
        """
        let sessions = HarborProbeOutputParser.sessions(
            fromProbeOutput: output,
            source: .local,
            ownSessionName: "cmux-mytag"
        )
        // Only cmux-tui rows are infrastructure-filtered; a tmux session that
        // happens to share the name stays listed.
        #expect(sessions.map(\.name) == ["user-session", "cmux-mytag"])
        #expect(sessions[1].tool == .tmux)
    }

    @Test func unknownStateFallsBackToUnknown() {
        let sessions = HarborProbeOutputParser.sessions(
            fromProbeOutput: "tmux\tx\tsomething-new\t",
            source: .local
        )
        #expect(sessions[0].state == .unknown)
    }

    @Test func rejectsUnboundedOrControlCharacterSessionNames() {
        let oversized = String(repeating: "x", count: HarborProbeOutputParser.maxSessionNameBytes + 1)
        let output = "tmux\t\(oversized)\tdetached\t\n"
            + "tmux\tgood\u{0}name\tdetached\t\n"
            + "tmux\tok\tdetached\t\(String(repeating: "d", count: HarborProbeOutputParser.maxDetailCharacters + 40))\n"
        let sessions = HarborProbeOutputParser.sessions(fromProbeOutput: output, source: .local)
        #expect(sessions.map(\.name) == ["ok"])
        #expect(sessions[0].detail.count == HarborProbeOutputParser.maxDetailCharacters)
    }

    @Test func capsSessionCountAndSanitizesDetails() {
        let rows = (0..<HarborProbeOutputParser.maxSessions + 20)
            .map { "tmux\tname\($0)\tdetached\tdetail\u{1b}[31m" }
            .joined(separator: "\n")
        let sessions = HarborProbeOutputParser.sessions(fromProbeOutput: rows, source: .local)
        #expect(sessions.count == HarborProbeOutputParser.maxSessions)
        #expect(sessions[0].detail == "detail[31m")
    }
}

@Suite("Harbor attach command construction")
struct HarborAttachCommandTests {
    private func session(
        _ tool: HarborTool,
        name: String = "dev",
        state: HarborSessionState = .detached,
        source: HarborSource = .local
    ) -> HarborSession {
        HarborSession(source: source, tool: tool, name: name, state: state, detail: "")
    }

    @Test func localCommandsPerTool() {
        #expect(HarborAttachCommand.shellCommand(for: session(.tmux)) == "exec tmux attach-session -t 'dev'")
        #expect(HarborAttachCommand.shellCommand(for: session(.zellij)) == "exec zellij attach 'dev'")
        #expect(HarborAttachCommand.shellCommand(for: session(.zmx)) == "exec zmx attach 'dev'")
        #expect(HarborAttachCommand.shellCommand(for: session(.herdr)) == "exec herdr session attach 'dev'")
        #expect(HarborAttachCommand.shellCommand(for: session(.cmuxTui)) == "exec cmux-tui attach --session 'dev'")
    }

    @Test func screenUsesJoinWhenAttachedElsewhere() {
        #expect(HarborAttachCommand.shellCommand(for: session(.screen, state: .detached)) == "exec screen -r 'dev'")
        #expect(HarborAttachCommand.shellCommand(for: session(.screen, state: .attached)) == "exec screen -x 'dev'")
    }

    @Test func sshWrapsLocalCommandWithTTY() {
        let command = HarborAttachCommand.shellCommand(
            for: session(.tmux, source: .ssh(destination: "lawrence@devbox"))
        )
        #expect(command == "exec ssh -t 'lawrence@devbox' -- 'TERM=xterm-256color exec tmux attach-session -t '\\''dev'\\'''")
    }

    @Test func quotesHostileSessionNames() {
        let command = HarborAttachCommand.shellCommand(for: session(.tmux, name: "a'b; rm -rf /"))
        #expect(command == "exec tmux attach-session -t 'a'\\''b; rm -rf /'")
    }
}

@Suite("Harbor host store validation")
struct HarborHostStoreTests {
    @Test func acceptsPlausibleDestinations() {
        #expect(HarborHostStore.isPlausibleDestination("devbox"))
        #expect(HarborHostStore.isPlausibleDestination("lawrence@devbox.local"))
        #expect(HarborHostStore.isPlausibleDestination("ec2-user@10.0.0.5"))
    }

    @Test func rejectsOptionInjectionAndShellMetacharacters() {
        #expect(!HarborHostStore.isPlausibleDestination(""))
        #expect(!HarborHostStore.isPlausibleDestination("-oProxyCommand=evil"))
        #expect(!HarborHostStore.isPlausibleDestination("host extra"))
        #expect(!HarborHostStore.isPlausibleDestination("host;rm"))
        #expect(!HarborHostStore.isPlausibleDestination("host`x`"))
        #expect(!HarborHostStore.isPlausibleDestination("host\u{0}"))
        #expect(!HarborHostStore.isPlausibleDestination(
            String(repeating: "h", count: HarborHostStore.maxDestinationBytes + 1)
        ))
    }

    @Test func addAndRemoveRoundTrip() {
        let suiteName = "HarborHostStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(HarborHostStore.add("devbox", defaults: defaults))
        #expect(!HarborHostStore.add("devbox", defaults: defaults))
        #expect(HarborHostStore.hosts(defaults: defaults) == ["devbox"])
        HarborHostStore.remove("devbox", defaults: defaults)
        #expect(HarborHostStore.hosts(defaults: defaults).isEmpty)
    }

    @Test func hostStoreCapsPersistedDestinationsAndRefreshFanout() {
        let suiteName = "HarborHostStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set((0..<HarborHostStore.maxHosts + 4).map { "host\($0)" }, forKey: HarborHostStore.defaultsKey)
        #expect(HarborHostStore.hosts(defaults: defaults).count == HarborHostStore.maxHosts)
        #expect(!HarborHostStore.add("new-host", defaults: defaults))
    }
}

@Suite("Harbor sidebar availability")
struct HarborAvailabilityTests {
    @Test func hiddenUnlessBetaFlagEnabled() {
        #expect(!RightSidebarMode.harbor.isAvailable(
            feedEnabled: true, dockEnabled: true, machinesEnabled: true, harborEnabled: false
        ))
        #expect(RightSidebarMode.harbor.isAvailable(
            feedEnabled: false, dockEnabled: false, machinesEnabled: false, harborEnabled: true
        ))
        #expect(!RightSidebarMode.availableModes(
            feedEnabled: false, dockEnabled: false, machinesEnabled: false, harborEnabled: false
        ).contains(.harbor))
    }

    @Test func cliTokenResolves() {
        #expect(RightSidebarMode.from(cliArgument: "harbor") == .harbor)
        #expect(RightSidebarMode.from(cliArgument: " Harbor ") == .harbor)
    }
}
