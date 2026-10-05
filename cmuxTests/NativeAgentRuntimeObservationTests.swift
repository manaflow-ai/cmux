import Darwin
import Foundation
import Testing
import CmuxAgentJournal
import CmuxRemoteWorkspace
@_spi(CmuxHostTransport) import CmuxExtensionKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct NativeAgentRuntimeObservationTests {
    private func configure(_ workspace: Workspace, panelID: UUID, processes: [String: AgentPIDProcessIdentity]) {
        let model = workspace.sidebarAgentRuntimeObservation
        model.setAgentPIDs(processes.mapValues(\.pid))
        model.setAgentPIDProcessIdentitiesByKey(processes)
        model.setAgentPIDPanelIdsByKey(processes.mapValues { _ in panelID })
        model.setAgentPIDKeysByPanelId([panelID: Set(processes.keys)])
    }

    private func state(_ activity: AgentSessionActivity, mode: AgentExecutionMode = .unknown, reason: AgentRuntimeReason? = nil, at: Int64 = 125_000, generation: UInt64? = nil) -> AgentSessionLifecycleState {
        AgentSessionLifecycleState(phase: activity == .working ? .running : .needsInput, ended: false, lastSequence: 1, lastOccurredAtMs: at, activity: activity, reason: reason, mode: mode, activityObservedAtMs: at, transitionedAtMs: at, modeObservedAtMs: mode == .unknown ? nil : at - 1_000, processGeneration: generation, modeProcessGeneration: generation)
    }

    @Test
    func nativeSamePaneSessionsKeepTheirOwnActivityReasonAndMode() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        let first = AgentPIDProcessIdentity(pid: 12_345, startSeconds: 100, startMicroseconds: 7)
        let second = AgentPIDProcessIdentity(pid: 12_346, startSeconds: 101, startMicroseconds: 8)
        configure(workspace, panelID: panel, processes: ["codex.first": first, "codex.second": second])
        let model = workspace.sidebarAgentRuntimeObservation
        model.recordJournalEvidence(panelID: panel, statusKey: "codex", sessionID: "first", state: state(.working, mode: .execution, generation: 100_000_007))
        model.recordJournalEvidence(panelID: panel, statusKey: "codex", sessionID: "second", state: state(.needsInput, mode: .plan, reason: .planReview, generation: 101_000_008))
        let projector = SidebarExtensionRuntimeProjector(processIdentity: { $0 == first.pid ? first : second })
        let observations = try #require(projector.observations(workspace: workspace, panelID: panel))
        #expect(observations.map(\.sessionID) == ["first", "second"])
        #expect(observations.map(\.activity) == [.working, .needsInput])
        #expect(observations.map(\.mode) == [.execution, .plan])
        #expect(observations.last?.reason == .planReview)
        #expect(projector.observation(workspace: workspace, panelID: panel)?.lifecycle == .running)
        #expect(projector.observations(workspace: workspace, panelID: panel) == observations)
    }

    @Test
    func currentBirthProofKeepsOldHealthyWorkingButRejectsReplacedProcess() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        let old = AgentPIDProcessIdentity(pid: 12_345, startSeconds: 100, startMicroseconds: 7)
        configure(workspace, panelID: panel, processes: ["codex.exact": old])
        workspace.sidebarAgentRuntimeObservation.recordJournalEvidence(panelID: panel, statusKey: "codex", sessionID: "exact", state: state(.working, mode: .plan, generation: 100_000_007))
        let healthy = SidebarExtensionRuntimeProjector(processIdentity: { _ in old }).observation(workspace: workspace, panelID: panel)
        #expect(healthy?.activity == .working)
        #expect(healthy?.mode == .plan)
        #expect(healthy?.observedAt == Date(timeIntervalSince1970: 125))
        let replacement = AgentPIDProcessIdentity(pid: old.pid, startSeconds: 200, startMicroseconds: 1)
        #expect(SidebarExtensionRuntimeProjector(processIdentity: { _ in replacement }).observation(workspace: workspace, panelID: panel) == nil)
        workspace.sidebarAgentRuntimeObservation.setAgentPIDProcessIdentitiesByKey(["codex.exact": replacement])
        let restored = SidebarExtensionRuntimeProjector(processIdentity: { _ in replacement }).observation(workspace: workspace, panelID: panel)
        #expect(restored?.activity == .unknown)
        #expect(restored?.mode == .unknown)
    }

    @Test(arguments: [true, false])
    func oldOrWrongGenerationEvidenceCannotClaimActivityOrMode(oldTimestamp: Bool) throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        let identity = AgentPIDProcessIdentity(pid: 12_345, startSeconds: 100, startMicroseconds: 7)
        configure(workspace, panelID: panel, processes: ["codex.exact": identity])
        workspace.sidebarAgentRuntimeObservation.recordJournalEvidence(panelID: panel, statusKey: "codex", sessionID: "exact", state: state(.working, mode: .plan, at: oldTimestamp ? 50_000 : 125_000, generation: oldTimestamp ? 100_000_007 : 999))
        let observation = SidebarExtensionRuntimeProjector(processIdentity: { _ in identity }).observation(workspace: workspace, panelID: panel)
        #expect(observation?.sessionID == "exact")
        #expect(observation?.activity == .unknown)
        #expect(observation?.mode == .unknown)
        #expect(observation?.observedAt == nil)
    }

    @Test
    func modeOnlyPlanRemainsUnknownAndCoarseAggregateCannotOverwriteExactFeedback() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        let identity = AgentPIDProcessIdentity(pid: 12_345, startSeconds: 100, startMicroseconds: 7)
        configure(workspace, panelID: panel, processes: ["codex.exact": identity])
        let model = workspace.sidebarAgentRuntimeObservation
        model.recordJournalEvidence(panelID: panel, statusKey: "codex", sessionID: "exact", state: .init(phase: .unknown, ended: false, lastSequence: 0, lastOccurredAtMs: 0, mode: .plan, modeObservedAtMs: 125_000, modeProcessGeneration: 100_000_007))
        let projector = SidebarExtensionRuntimeProjector(processIdentity: { _ in identity })
        #expect(projector.observation(workspace: workspace, panelID: panel)?.activity == .unknown)
        #expect(projector.observation(workspace: workspace, panelID: panel)?.mode == .plan)
        model.recordJournalEvidence(panelID: panel, statusKey: "codex", sessionID: "exact", state: state(.needsInput, mode: .plan, reason: .question, generation: 100_000_007))
        model.setAgentLifecycleStatesByPanelId([panel: ["codex": .running]])
        model.recordLifecycleEvidence(panelID: panel, statusKey: "codex", evidence: .init(agentPIDKey: "codex.exact", processIdentity: identity, lifecycle: .running, observedAt: Date(timeIntervalSince1970: 200), isError: false))
        #expect(projector.observation(workspace: workspace, panelID: panel)?.activity == .needsInput)
        #expect(projector.observation(workspace: workspace, panelID: panel)?.reason == .question)
    }

    @Test
    func readOnlyCarrierIsBoundedRetainsUnknownIdentityAndContainsNoTranscript() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        let identity = AgentPIDProcessIdentity(pid: 12_345, startSeconds: 100, startMicroseconds: 7)
        let second = AgentPIDProcessIdentity(pid: 12_346, startSeconds: 101, startMicroseconds: 8)
        configure(workspace, panelID: panel, processes: ["codex": identity, "opencode.exact": second])
        let reader = AgentRuntimeObservationReader(projector: .init(processIdentity: { $0 == identity.pid ? identity : second }))
        let result = reader.read(workspaces: [workspace], surfaceID: panel, limit: 1)
        let rows = try #require(result["observations"] as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(result["truncated"] as? Bool == true)
        #expect(rows.first?["session_id"] is NSNull)
        #expect(rows.first?["process_generation"] as? UInt64 == 100_000_007)
        #expect(rows.first?["activity"] as? String == "unknown")
        #expect(rows.first?["transcript"] == nil)
        #expect(rows.first?["environment"] == nil)
        #expect(try JSONSerialization.data(withJSONObject: result).isEmpty == false)
    }

    @Test
    func explicitBindingIsBirthGuardedAndNeverInventsActivity() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false)
        let workspace = Workspace()
        manager.tabs = [workspace]
        let panel = try #require(workspace.focusedPanelId)
        let identity = try #require(AgentPIDProcessIdentity(pid: getpid()))
        let generation = UInt64(identity.startSeconds) * 1_000_000 + UInt64(identity.startMicroseconds)
        configure(workspace, panelID: panel, processes: ["codex": identity])
        let coordinator = SidebarExtensionAgentSessionBindingCoordinator(tabManager: manager, processIdentity: { _ in identity }, ownsSurface: { _, _, _ in true }, now: { Date(timeIntervalSince1970: 200) })
        let stale = coordinator.perform(.bindAgentSession(workspaceID: workspace.id, surfaceID: panel, toolID: "codex", sessionID: "known-session", expectedProcessGeneration: generation + 1))
        #expect(stale?.accepted == false)
        #expect(workspace.surfaceResumeBinding(panelId: panel) == nil)
        let accepted = coordinator.perform(.bindAgentSession(workspaceID: workspace.id, surfaceID: panel, toolID: "codex", sessionID: "known-session", expectedProcessGeneration: generation))
        #expect(accepted?.accepted == true)
        #expect(workspace.surfaceResumeBinding(panelId: panel)?.checkpointId == "known-session")
        #expect(workspace.surfaceResumeBinding(panelId: panel)?.autoResume == false)
        #expect(workspace.agentPIDPanelIdsByKey["codex.known-session"] == panel)
        let observation = SidebarExtensionRuntimeProjector(processIdentity: { _ in identity }).observations(workspace: workspace, panelID: panel)?.first(where: { $0.sessionID == "known-session" })
        #expect(observation?.activity == .unknown)
    }

    @Test
    func registeringDistinctProcessSessionsInOnePanelDoesNotEvictEachOther() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        _ = try #require(AgentPIDProcessIdentity(pid: getpid()))
        _ = try #require(AgentPIDProcessIdentity(pid: getppid()))
        _ = workspace.recordAgentPID(key: "codex.first", pid: getpid(), panelId: panel, refreshPorts: false)
        _ = workspace.recordAgentPID(key: "codex.second", pid: getppid(), panelId: panel, refreshPorts: false)
        #expect(workspace.agentPIDKeysByPanelId[panel]?.contains("codex.first") == true)
        #expect(workspace.agentPIDKeysByPanelId[panel]?.contains("codex.second") == true)
        _ = workspace.recordAgentPID(key: "codex.replacement", pid: getpid(), panelId: panel, refreshPorts: false)
        #expect(workspace.agentPIDKeysByPanelId[panel]?.contains("codex.first") == false)
        #expect(workspace.agentPIDKeysByPanelId[panel]?.contains("codex.second") == true)
    }

    @Test
    func runtimeReadIsDeniedByRemoteRelayByDefault() throws {
        let line = try JSONSerialization.data(withJSONObject: ["id": "runtime", "method": "agent.runtime.list", "params": [:]])
        let result = RemoteRelayCommandPolicy().evaluate(commandLine: line, workspaceAliases: [:], surfaceAliases: [:])
        guard case .deny = result else { Issue.record("Native runtime metadata leaked to a remote relay"); return }
    }
}
