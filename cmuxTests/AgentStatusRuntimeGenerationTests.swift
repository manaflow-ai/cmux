import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent status runtime generations")
struct AgentStatusRuntimeGenerationTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    @Test func claudeHookSignalBindsToItsSessionRuntime() throws {
        let event = WorkstreamEvent(
            sessionId: "claude-current-session",
            hookEventName: .permissionRequest,
            source: "claude",
            ppid: Int(getpid()),
            receivedAt: now,
            extraFieldsJSON: #"{"_cmux_agent_status_signal":"needsInput"}"#
        )

        let signal = try #require(AgentStatusHookEventSignal(event: event))

        #expect(signal.statusKey == "claude_code")
        #expect(signal.runtimePIDKey == "claude_code.current-session")
        #expect(signal.runtimeSessionID == "current-session")
    }

    @Test @MainActor func samePIDClaudeReplacementRejectsOldSessionWithoutResumeBinding() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        defer { workspace.clearAllAgentPIDs(refreshPorts: false) }
        let pid = getpid()
        workspace.recordAgentPID(
            key: "claude_code.previous-session",
            pid: pid,
            panelId: panelId,
            refreshPorts: false
        )
        let previousEvent = WorkstreamEvent(
            sessionId: "claude-previous-session",
            hookEventName: .permissionRequest,
            source: "claude",
            ppid: Int(pid),
            receivedAt: now
        )

        #expect(workspace.surfaceResumeBindingsByPanelId[panelId] == nil)
        #expect(workspace.agentStatusRuntimeIsCurrent(event: previousEvent, panelId: panelId))

        workspace.recordAgentPID(
            key: "claude_code.current-session",
            pid: pid,
            panelId: panelId,
            refreshPorts: false
        )
        let currentEvent = WorkstreamEvent(
            sessionId: "claude-current-session",
            hookEventName: .permissionRequest,
            source: "claude",
            ppid: Int(pid),
            receivedAt: now
        )

        #expect(workspace.agentPIDs["claude_code.previous-session"] == nil)
        #expect(!workspace.agentStatusRuntimeIsCurrent(event: previousEvent, panelId: panelId))
        #expect(workspace.agentStatusRuntimeIsCurrent(event: currentEvent, panelId: panelId))
    }

    @Test @MainActor func claudeRuntimeConfirmsExactRestorableSessionGeneration() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        defer { workspace.clearAllAgentPIDs(refreshPorts: false) }
        let pid = getpid()
        let identity = try #require(Workspace.agentPIDProcessIdentity(pid: pid))
        workspace.recordAgentPID(
            key: "claude_code.current-session",
            pid: pid,
            panelId: panelId,
            refreshPorts: false
        )
        let currentIdentity: (Int) -> AgentPIDProcessIdentity? = {
            $0 == Int(pid) ? identity : nil
        }

        let confirmed = workspace.confirmedRuntimeAgentProcessIdentities(
            kind: .claude,
            sessionId: "current-session",
            panelId: panelId,
            currentProcessIdentity: currentIdentity
        )
        let stale = workspace.confirmedRuntimeAgentProcessIdentities(
            kind: .claude,
            sessionId: "previous-session",
            panelId: panelId,
            currentProcessIdentity: currentIdentity
        )

        #expect(confirmed == [identity])
        #expect(stale.isEmpty)
    }

    @Test @MainActor func staleClaudeCleanupCannotClearReplacementLifecycle() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        defer { workspace.clearAllAgentPIDs(refreshPorts: false) }
        workspace.recordAgentPID(
            key: "claude_code.current-session",
            pid: getpid(),
            panelId: panelId,
            refreshPorts: false
        )
        workspace.setAgentLifecycle(
            key: "claude_code",
            panelId: panelId,
            lifecycle: .running
        )

        #expect(!workspace.clearAgentPID(
            key: "claude_code.previous-session",
            panelId: panelId,
            clearStatus: true,
            refreshPorts: false
        ))
        #expect(workspace.agentPIDs["claude_code.current-session"] == getpid())
        #expect(workspace.agentLifecycleStatesByPanelId[panelId]?["claude_code"] == .running)
    }
}
