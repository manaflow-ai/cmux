import CnxModel
import Testing
@testable import CnxWorkspaces

/// Codex QA F9: closing a tab that runs a program asks first.
@Suite struct TabCloseGuardTests {
    @Test func aWorkingAgentAsks() {
        let tab = WorkspaceTab(id: "t", kind: .terminal, title: "codex", agentStatus: .working)
        #expect(TabCloseGuard().runningProgram(tab) != nil)
    }

    @Test func aKnownProgramAsks() {
        #expect(TabCloseGuard().runningProgram(WorkspaceTab(id: "t", kind: .terminal, title: "vim notes.md")) == "vim")
        #expect(TabCloseGuard().runningProgram(WorkspaceTab(id: "t", kind: .terminal, title: "/usr/bin/top")) == "top")
    }

    @Test func aShellOrAnythingElseClosesAtOnce() {
        #expect(TabCloseGuard().runningProgram(WorkspaceTab(id: "t", kind: .terminal, title: "~/src")) == nil)
        #expect(TabCloseGuard().runningProgram(WorkspaceTab(id: "t", kind: .terminal, title: "zsh")) == nil)
        #expect(TabCloseGuard().runningProgram(WorkspaceTab(id: "t", kind: .terminal, title: "e2e-t1")) == nil)
        #expect(TabCloseGuard().runningProgram(WorkspaceTab(id: "t", kind: .browser, title: "codex")) == nil)
    }
}
