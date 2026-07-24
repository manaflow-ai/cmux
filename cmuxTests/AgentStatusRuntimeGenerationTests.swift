import CMUXAgentLaunch
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

    @Test func partialRuntimeGenerationRejectsOrderedStatusSignal() {
        let event = WorkstreamEvent(
            sessionId: "codex-current-session",
            hookEventName: .permissionRequest,
            source: "codex",
            ppid: Int(getpid()),
            extraFieldsJSON: #"{"_cmux_agent_status_signal":"needsInput","_cmux_agent_pid_start_seconds":10}"#
        )

        #expect(AgentStatusHookEventSignal(event: event) == nil)
    }

    @Test(arguments: [
        #"{"_cmux_agent_status_signal":"needsInput","_cmux_agent_status_revision":true}"#,
        #"{"_cmux_agent_status_signal":"needsInput","_cmux_agent_status_revision":1.5}"#,
        #"{"_cmux_agent_status_signal":"needsInput","_cmux_agent_status_revision":-1}"#,
        #"{"_cmux_agent_status_signal":"needsInput","_cmux_agent_status_revision":"not-a-revision"}"#,
    ])
    func malformedLifecycleRevisionRejectsStatusSignal(extraFieldsJSON: String) {
        let event = WorkstreamEvent(
            sessionId: "codex-current-session",
            hookEventName: .permissionRequest,
            source: "codex",
            ppid: Int(getpid()),
            extraFieldsJSON: extraFieldsJSON
        )

        #expect(AgentStatusHookEventSignal(event: event) == nil)
    }

    @Test @MainActor func unversionedLifecycleCannotOverwriteOrderedRuntimeGeneration() throws {
        let panelID = UUID()
        let runtimeKey = "codex.current-session"
        let identity = AgentPIDProcessIdentity(
            pid: getpid(),
            startSeconds: 10,
            startMicroseconds: 20
        )
        let ledger = AgentStatusRuntimeLedger()

        #expect(ledger.recordLifecycle(
            .running,
            panelId: panelID,
            statusKey: "codex",
            observedAt: now,
            runtimePIDKey: runtimeKey,
            runtimeProcessIdentity: identity,
            revision: 2
        ))
        #expect(!ledger.recordLifecycle(
            .needsInput,
            panelId: panelID,
            statusKey: "codex",
            observedAt: now.addingTimeInterval(1),
            runtimePIDKey: runtimeKey,
            runtimeProcessIdentity: identity
        ))
        #expect(!ledger.recordLifecycle(
            .needsInput,
            panelId: panelID,
            statusKey: "codex",
            observedAt: now.addingTimeInterval(2)
        ))
        #expect(ledger.evidenceForPanel(panelID)["codex"]?.lifecycle == .running)
        #expect(ledger.evidenceForPanel(panelID)["codex"]?.lifecycleRevision == 2)
    }

    @Test @MainActor func equalRevisionOnlyAcceptsTheSameLifecycleIdempotently() throws {
        let panelID = UUID()
        let runtimeKey = "codex.current-session"
        let identity = AgentPIDProcessIdentity(
            pid: getpid(),
            startSeconds: 10,
            startMicroseconds: 20
        )
        let ledger = AgentStatusRuntimeLedger()

        #expect(ledger.recordLifecycle(
            .running,
            panelId: panelID,
            statusKey: "codex",
            observedAt: now,
            runtimePIDKey: runtimeKey,
            runtimeProcessIdentity: identity,
            revision: 2
        ))
        #expect(!ledger.recordLifecycle(
            .needsInput,
            panelId: panelID,
            statusKey: "codex",
            observedAt: now.addingTimeInterval(1),
            runtimePIDKey: runtimeKey,
            runtimeProcessIdentity: identity,
            revision: 2
        ))
        #expect(ledger.recordLifecycle(
            .running,
            panelId: panelID,
            statusKey: "codex",
            observedAt: now.addingTimeInterval(2),
            runtimePIDKey: runtimeKey,
            runtimeProcessIdentity: identity,
            revision: 2
        ))

        let evidence = ledger.evidenceForPanel(panelID)["codex"]
        #expect(evidence?.lifecycle == .running)
        #expect(evidence?.lifecycleRevision == 2)
        #expect(evidence?.lifecycleObservedAt == now)
    }

    @Test @MainActor func newerExactRuntimeGenerationAcceptsUnversionedLifecycle() throws {
        let panelID = UUID()
        let runtimeKey = "codex.current-session"
        let ledger = AgentStatusRuntimeLedger()

        #expect(ledger.recordLifecycle(
            .running,
            panelId: panelID,
            statusKey: "codex",
            observedAt: now,
            runtimePIDKey: runtimeKey,
            runtimeProcessIdentity: AgentPIDProcessIdentity(
                pid: getpid(),
                startSeconds: 10,
                startMicroseconds: 20
            ),
            revision: 8
        ))
        #expect(ledger.recordLifecycle(
            .needsInput,
            panelId: panelID,
            statusKey: "codex",
            observedAt: now.addingTimeInterval(1),
            runtimePIDKey: runtimeKey,
            runtimeProcessIdentity: AgentPIDProcessIdentity(
                pid: getpid(),
                startSeconds: 11,
                startMicroseconds: 30
            )
        ))
        #expect(ledger.evidenceForPanel(panelID)["codex"]?.lifecycle == .needsInput)
        #expect(ledger.evidenceForPanel(panelID)["codex"]?.lifecycleRevision == nil)
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

    @Test @MainActor func localHookRejectsForgedProcessGeneration() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let pid = getpid()
        let runtimeKey = "codex.current-session"
        defer { workspace.clearAllAgentPIDs(refreshPorts: false) }
        workspace.recordAgentPID(
            key: runtimeKey,
            pid: pid,
            panelId: panelId,
            refreshPorts: false
        )
        let registeredIdentity = try #require(workspace.agentPIDProcessIdentitiesByKey[runtimeKey])
        let forgedIdentity = AgentPIDProcessIdentity(
            pid: pid,
            startSeconds: registeredIdentity.startSeconds + 1,
            startMicroseconds: registeredIdentity.startMicroseconds
        )
        let event = WorkstreamEvent(
            sessionId: "codex-current-session",
            hookEventName: .permissionRequest,
            source: "codex",
            ppid: Int(pid),
            receivedAt: now,
            extraFieldsJSON: """
            {"_cmux_agent_status_signal":"needsInput","_cmux_agent_status_revision":1,"_cmux_agent_pid_start_seconds":\(forgedIdentity.startSeconds),"_cmux_agent_pid_start_microseconds":\(forgedIdentity.startMicroseconds)}
            """
        )
        let signal = try #require(AgentStatusHookEventSignal(event: event))

        #expect(!workspace.noteAgentStatusHookSignal(signal, panelId: panelId))
        #expect(workspace.agentLifecycleStatesByPanelId[panelId]?["codex"] == .unknown)
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

    @Test @MainActor func relayedRuntimeUsesSurfaceSessionIdentityInsteadOfLocalPIDNamespace() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let remotePID: pid_t = 987_654
        defer { workspace.clearAllAgentPIDs(refreshPorts: false) }
        workspace.trackRemoteTerminalSurface(panelId)
        workspace.recordAgentPID(
            key: "codex.remote-session",
            pid: remotePID,
            panelId: panelId,
            refreshPorts: false
        )
        let remoteObservedAt = Date.now
        let remoteEvent = WorkstreamEvent(
            sessionId: "codex-remote-session",
            hookEventName: .permissionRequest,
            source: "codex",
            ppid: Int(remotePID),
            receivedAt: remoteObservedAt,
            extraFieldsJSON: #"{"_cmux_agent_status_signal":"needsInput","_cmux_agent_pid_namespace":"remote"}"#
        )
        let localNamespaceEvent = WorkstreamEvent(
            sessionId: "codex-remote-session",
            hookEventName: .permissionRequest,
            source: "codex",
            ppid: Int(remotePID),
            receivedAt: remoteObservedAt,
            extraFieldsJSON: #"{"_cmux_agent_status_signal":"needsInput"}"#
        )
        let invalidNamespaceEvent = WorkstreamEvent(
            sessionId: "codex-remote-session",
            hookEventName: .permissionRequest,
            source: "codex",
            ppid: Int(remotePID),
            receivedAt: remoteObservedAt,
            extraFieldsJSON: #"{"_cmux_agent_status_signal":"needsInput","_cmux_agent_pid_namespace":"elsewhere"}"#
        )

        #expect(!workspace.clearStaleAgentPIDs(panelId: panelId, refreshPorts: false))
        #expect(workspace.agentStatusRuntimeIsCurrent(event: remoteEvent, panelId: panelId))
        #expect(!workspace.agentStatusRuntimeIsCurrent(event: localNamespaceEvent, panelId: panelId))
        #expect(!workspace.agentStatusRuntimeIsCurrent(event: invalidNamespaceEvent, panelId: panelId))
        #expect(AgentStatusHookEventSignal(event: invalidNamespaceEvent) == nil)

        let signal = try #require(AgentStatusHookEventSignal(event: remoteEvent))
        #expect(signal.runtimePIDNamespace == .remote)
        workspace.noteAgentStatusHookSignal(signal, panelId: panelId)
        #expect(workspace.agentLifecycleStatesByPanelId[panelId]?["codex"] == .needsInput)

        workspace.recordAgentPID(
            key: "codex.replacement-session",
            pid: remotePID,
            panelId: panelId,
            refreshPorts: false
        )
        let replacementObservedAt = Date.now
        let replacementEvent = WorkstreamEvent(
            sessionId: "codex-replacement-session",
            hookEventName: .permissionRequest,
            source: "codex",
            ppid: Int(remotePID),
            receivedAt: replacementObservedAt,
            extraFieldsJSON: #"{"_cmux_agent_status_signal":"needsInput","_cmux_agent_pid_namespace":"remote"}"#
        )

        #expect(!workspace.agentStatusRuntimeIsCurrent(event: remoteEvent, panelId: panelId))
        #expect(workspace.agentStatusRuntimeIsCurrent(event: replacementEvent, panelId: panelId))

        let detachedState = try #require(workspace.agentRuntimeState(forPanelId: panelId))
        workspace.clearAllAgentPIDs(refreshPorts: false)
        workspace.adoptDetachedAgentRuntimeState(detachedState)

        #expect(workspace.agentPIDNamespacesByKey["codex.replacement-session"] == .remote)
        #expect(!workspace.clearStaleAgentPIDs(panelId: panelId, refreshPorts: false))
        #expect(workspace.agentStatusRuntimeIsCurrent(event: replacementEvent, panelId: panelId))
    }

    @Test @MainActor func movingPanePreservesExistingRuntimeLifecycleEvidence() throws {
        let source = Workspace()
        let destination = Workspace()
        let panelID = try #require(source.focusedPanelId)
        let pid = getpid()
        defer {
            source.clearAllAgentPIDs(refreshPorts: false)
            destination.clearAllAgentPIDs(refreshPorts: false)
        }
        source.recordAgentPID(
            key: "claude_code.session",
            pid: pid,
            panelId: panelID,
            refreshPorts: false
        )
        #expect(source.setAgentLifecycle(
            key: "claude_code",
            panelId: panelID,
            lifecycle: .running
        ))
        let originalEvidence = try #require(
            source.sidebarAgentRuntimeObservation.agentStatusLedger
                .evidenceForPanel(panelID)["claude_code"]
        )

        let transfer = try #require(source.detachSurface(panelId: panelID))
        let destinationPaneID = try #require(destination.bonsplitController.allPaneIds.first)
        #expect(destination.attachDetachedSurface(
            transfer,
            inPane: destinationPaneID,
            focus: false
        ) == panelID)

        let adoptedEvidence = destination.sidebarAgentRuntimeObservation.agentStatusLedger
            .evidenceForPanel(panelID)["claude_code"]
        #expect(adoptedEvidence == originalEvidence)
        #expect(destination.agentLifecycleStatesByPanelId[panelID]?["claude_code"] == .running)
    }

    @Test @MainActor func staleRemoteNeedsInputDegradesWhenProcessLivenessIsUnverifiable() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let remotePID: pid_t = 987_654
        let observedAt = Date.now
        defer { workspace.clearAllAgentPIDs(refreshPorts: false) }
        workspace.trackRemoteTerminalSurface(panelID)
        workspace.recordAgentPID(
            key: "codex.remote-session",
            pid: remotePID,
            panelId: panelID,
            refreshPorts: false
        )
        let signal = try #require(AgentStatusHookEventSignal(event: WorkstreamEvent(
            sessionId: "codex-remote-session",
            hookEventName: .permissionRequest,
            source: "codex",
            ppid: Int(remotePID),
            receivedAt: observedAt,
            extraFieldsJSON: #"{"_cmux_agent_status_signal":"needsInput","_cmux_agent_pid_namespace":"remote"}"#
        )))
        #expect(workspace.noteAgentStatusHookSignal(signal, panelId: panelID))
        #expect(workspace.suppressesRawTerminalNotification(panelId: panelID))

        workspace.reconcileAgentStatuses(
            panelId: panelID,
            now: observedAt.addingTimeInterval(301)
        )

        #expect(workspace.agentLifecycleStatesByPanelId[panelID]?["codex"] == .unknown)
        #expect(workspace.statusEntries["codex"] == nil)
        #expect(!workspace.suppressesRawTerminalNotification(panelId: panelID))
    }

    @Test func needsInputRemainsConfidentForLiveRuntimeUntilCounterSignal() {
        let evidence = AgentStatusEvidence(
            lifecycle: .needsInput,
            lifecycleObservedAt: now.addingTimeInterval(-3_600)
        )

        let resolution = AgentStatusReconciler().resolve(
            evidence: evidence,
            statusKey: "codex",
            runtimeLiveness: .confirmed,
            now: now
        )

        #expect(resolution == AgentStatusResolution(lifecycle: .needsInput, confidence: .confident))
    }
}
