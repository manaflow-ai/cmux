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

    @Test func parsesTmuxWindowsAndPaneLeaves() {
        let output = """
        S\ttmux\tdev\tdetached\t2w
        TW\tdev\t@4\t0\twork
        TP\tdev\t@4\t%9\t1\tclaude
        """
        let sessions = HarborProbeOutputParser.sessions(fromProbeOutput: output, host: .local)
        #expect(sessions.count == 1)
        #expect(sessions[0].windows.count == 1)
        #expect(sessions[0].windows[0].terminals[0].shortID == "%9")
        #expect(sessions[0].windows[0].terminals[0].isActive)
        #expect(sessions[0].windows[0].terminals[0].leaf == .tmuxPane(
            host: .local, sessionName: "dev", windowID: 4, paneID: 9
        ))
    }

    @Test func parsesHerdrAgentMetadataAndWorkspace() {
        let paneJSON = #"{"result":{"panes":[{"pane_id":"w1:p2","workspace_id":"w1","terminal_title":"codex","cwd":"/tmp/demo","agent":"codex","agent_status":"blocked","message":"needs input","priority":1}]}}"#
        let workspaceJSON = #"{"result":{"workspaces":[{"workspace_id":"w1","label":"Review","number":2}]}}"#
        let output = """
        S\therdr\tdefault\trunning\t
        J\therdr\tdefault\tpane-list\t\(paneJSON)
        J\therdr\tdefault\tworkspace-list\t\(workspaceJSON)
        """
        let sessions = HarborProbeOutputParser.sessions(fromProbeOutput: output, host: .local)
        let terminal = sessions[0].windows[0].terminals[0]
        #expect(sessions[0].windows[0].label == "2: Review")
        #expect(terminal.leaf == .herdrPane(host: .local, sessionName: "default", paneID: "w1:p2"))
        #expect(terminal.agent?.kind == "codex")
        #expect(terminal.agent?.state == .blocked)
        #expect(terminal.agent?.message == "needs input")
        #expect(terminal.cwd == "/tmp/demo")
    }

    @Test func parsesHerdrAgentNameFromAgentList() {
        let paneJSON = #"{"result":{"panes":[{"pane_id":"w1:p2","workspace_id":"w1","terminal_title":"codex","agent_status":"working"}]}}"#
        let agentJSON = #"{"result":{"agents":[{"pane_id":"w1:p2","agent":"codex","name":"reviewer","agent_status":"working"}]}}"#
        let output = """
        S\therdr\tdefault\trunning\t
        J\therdr\tdefault\tpane-list\t\(paneJSON)
        J\therdr\tdefault\tagent-list\t\(agentJSON)
        """
        let sessions = HarborProbeOutputParser.sessions(fromProbeOutput: output, host: .local)
        let agent = sessions[0].looseTerminals[0].agent
        #expect(agent?.kind == "codex")
        #expect(agent?.name == "reviewer")
        #expect(agent?.displayName == "codex: reviewer")
    }

    @Test func parsesHerdrTerminalIDForDirectAttach() {
        let paneJSON = #"{"result":{"panes":[{"pane_id":"w1:p2","workspace_id":"w1","terminal_id":"term_abc","terminal_title":"codex"}]}}"#
        let workspaceJSON = #"{"result":{"workspaces":[{"workspace_id":"w1","label":"Review","number":1}]}}"#
        let output = """
        S\therdr\tdefault\trunning\t
        J\therdr\tdefault\tpane-list\t\(paneJSON)
        J\therdr\tdefault\tworkspace-list\t\(workspaceJSON)
        """
        let sessions = HarborProbeOutputParser.sessions(fromProbeOutput: output, host: .local)
        let terminal = sessions[0].windows[0].terminals[0]
        #expect(terminal.leaf == .herdrTerminal(
            host: .local,
            sessionName: "default",
            paneID: "w1:p2",
            terminalID: "term_abc"
        ))
    }

    @Test func keepsHerdrPaneWhenWorkspaceWasNotListed() {
        let paneJSON = #"{"result":{"panes":[{"pane_id":"w9:p1","workspace_id":"w9","terminal_id":"term_orphan"}]}}"#
        let output = """
        S\therdr\tdefault\trunning\t
        J\therdr\tdefault\tpane-list\t\(paneJSON)
        """
        let sessions = HarborProbeOutputParser.sessions(fromProbeOutput: output, host: .local)
        #expect(sessions[0].windows.isEmpty)
        #expect(sessions[0].looseTerminals.count == 1)
        #expect(sessions[0].looseTerminals[0].leaf == .herdrTerminal(
            host: .local,
            sessionName: "default",
            paneID: "w9:p1",
            terminalID: "term_orphan"
        ))
    }

    @Test func hidesExitedCmuxTuiHistory() {
        let terminalJSON = #"[{"id":"term_live","title":"live","tab_id":"tab_1","cwd":"/tmp","lifecycle":"running","running":true},{"id":"term_dead","title":"dead","tab_id":null,"cwd":"/tmp","lifecycle":"exited","running":false}]"#
        let workspaceJSON = #"[{"id":"ws_1","name":"Work","index":0}]"#
        let tabJSON = #"[{"id":"tab_1","tab_id":"tab_1","workspace_id":"ws_1","focused":true}]"#
        let output = """
        S\tcmux-tui\tdev\trunning\t/tmp/dev.sock
        J\tcmux-tui\tdev\tworkspace-list\t\(workspaceJSON)
        J\tcmux-tui\tdev\ttab-list\t\(tabJSON)
        J\tcmux-tui\tdev\tterminal-list\t\(terminalJSON)
        """
        let sessions = HarborProbeOutputParser.sessions(fromProbeOutput: output, host: .local)
        #expect(sessions[0].windows.count == 1)
        #expect(sessions[0].windows[0].terminals.map(\.shortID) == ["term_live"])
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

    @Test func leafCommandKeepsPaneIdentity() {
        let item = HarborDragItem.leaf(
            .tmuxPane(host: .local, sessionName: "dev", windowID: 4, paneID: 9),
            title: "claude"
        )
        #expect(HarborAttachCommand.shellCommand(for: item) == "exec tmux attach-session -t 'dev:@4.%9'")
    }
}

@Suite("Harbor tree ordering")
struct HarborTreeNodeTests {
    @Test func blockedTerminalSortsBeforeIdleTerminal() {
        let blocked = HarborTerminalInfo(
            leaf: nil,
            shortID: "b",
            title: "blocked",
            isActive: false,
            agent: HarborAgentInfo(kind: "codex", state: .blocked)
        )
        let idle = HarborTerminalInfo(
            leaf: nil,
            shortID: "i",
            title: "idle",
            isActive: true,
            agent: HarborAgentInfo(kind: "claude", state: .idle)
        )
        let session = HarborSessionInfo(
            tool: .herdr,
            name: "agents",
            state: .running,
            detail: "",
            windows: [HarborWindowInfo(id: "w", label: "Workspace", terminals: [idle, blocked])],
            looseTerminals: []
        )
        let snapshot = HarborHostSnapshot(host: .local, status: .loaded, sessions: [session])
        let terminalNodes = HarborTreeNodeBuilder.nodes(from: [snapshot])[0].children[0].children[0].children
        #expect(terminalNodes.map(\.searchableTitle) == ["codex blocked", "claude idle"])
    }

    @Test func terminalNodeIDUsesStableIdentity() {
        let info = HarborTerminalInfo(leaf: nil, shortID: "term_1234567890", title: "x", isActive: false, stableID: "term_full_identity")
        #expect(HarborTreeNodeBuilder.nodeID(parent: "p", terminal: info) == "p/t/term_full_identity")
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
