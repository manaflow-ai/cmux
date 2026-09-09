import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for #12084: shell-activity flips must not retire a
/// hook-published resume binding whose agent process is verifiably alive.
///
/// Pi's interactive TUI emits OSC 133 prompt and command marks while the agent
/// keeps running, so cmux sees the pane go idle and busy on every turn. The
/// restored-agent lifecycle used to read the first busy flip after an idle
/// hook publish as an unrelated command replacing the agent, and the first
/// idle flip after a resumed launch as the agent exiting, and demoted the
/// binding to manual either way. The next relaunch then restored a bare shell.
@MainActor
@Suite(.serialized)
struct RestoredAgentShellActivityLivenessTests {
    private static let sessionID = "5c0f2e4a-9b3d-4f6e-8a1c-2d7b9e0f4a63"
    private static let projectDirectory = "/tmp/pi-liveness-project"

    private static func trustedPiBinding(updatedAt: TimeInterval = 10) -> SurfaceResumeBindingSnapshot {
        SurfaceResumeBindingSnapshot(
            name: "Pi",
            kind: "pi",
            command: "pi --session \(sessionID)",
            cwd: projectDirectory,
            checkpointId: sessionID,
            source: "agent-hook",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "pi",
                executablePath: "pi",
                arguments: ["pi"],
                workingDirectory: projectDirectory,
                capturedAt: updatedAt,
                source: "process"
            ),
            autoResume: true,
            approvalPolicy: .auto,
            updatedAt: updatedAt
        )
    }

    private static var pidKey: String { "pi.\(sessionID)" }

    /// The test process itself stands in for the live Pi process the hook
    /// registered through `set_agent_pid`.
    private static var livePID: pid_t { ProcessInfo.processInfo.processIdentifier }

    /// A PID with no process table entry stands in for an agent that exited.
    private static var exitedPID: pid_t { pid_t(Int32.max - 11) }

    // MARK: - Workspace

    @Test
    func workspaceKeepsFreshHookBindingAcrossTUIPromptMarks() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)

        // Pi renders its prompt (133;A/B) before its session-start hook lands.
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)
        #expect(workspace.setSurfaceResumeBinding(Self.trustedPiBinding(), panelId: panelId))
        #expect(workspace.restoredAgentSnapshotsByPanelId[panelId]?.sessionId == Self.sessionID)
        _ = workspace.recordAgentPID(key: Self.pidKey, pid: Self.livePID, panelId: panelId)

        // The first turn emits 133;C: the running command is the agent itself.
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
        #expect(workspace.surfaceResumeBinding(panelId: panelId)?.allowsAutomaticResume == true)
        #expect(workspace.restoredAgentSnapshotsByPanelId[panelId]?.sessionId == Self.sessionID)
        #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] == .observedAgentCommandRunning)

        // The turn ends with 133;A while Pi keeps running.
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)
        #expect(workspace.surfaceResumeBinding(panelId: panelId)?.allowsAutomaticResume == true)
        #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] == .observedAgentCommandRunning)
    }

    @Test
    func workspaceStillRetiresBindingAfterAgentExits() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)

        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
        #expect(workspace.setSurfaceResumeBinding(Self.trustedPiBinding(), panelId: panelId))
        workspace.restoredAgentLifecycle.setResumeState(.observedAgentCommandRunning, panelId: panelId)
        _ = workspace.recordAgentPID(key: Self.pidKey, pid: Self.exitedPID, panelId: panelId)

        // The shell prompt returns after the agent process is gone (#8446).
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)
        #expect(workspace.surfaceResumeBinding(panelId: panelId)?.allowsAutomaticResume == false)
        #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] == .completedAgentExit)
    }

    @Test
    func workspaceKeepsResumedLaunchAcrossTUIPromptMarks() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)

        #expect(workspace.setSurfaceResumeBinding(Self.trustedPiBinding(), panelId: panelId))
        workspace.restoredAgentLifecycle.setResumeState(.awaitingAutoResumeCommand, panelId: panelId)
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
        #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] == .autoResumeCommandRunning)
        _ = workspace.recordAgentPID(key: Self.pidKey, pid: Self.livePID, panelId: panelId)

        // The resumed Pi renders its prompt; the agent has not exited.
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)
        #expect(workspace.surfaceResumeBinding(panelId: panelId)?.allowsAutomaticResume == true)
        #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] == .autoResumeCommandRunning)
        #expect(workspace.restoredAgentSnapshotsByPanelId[panelId]?.sessionId == Self.sessionID)
    }

    // MARK: - Dock

    @Test
    func dockKeepsFreshHookBindingAcrossTUIPromptMarks() throws {
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { store.closeAllPanels() }
        let panel = TerminalPanel(workspaceId: store.workspaceId)
        store.panels[panel.id] = panel

        store.updatePanelShellActivityState(panelId: panel.id, state: .promptIdle)
        #expect(store.setSurfaceResumeBinding(Self.trustedPiBinding(), panelId: panel.id))
        store.restoredAgentLifecycle.setResumeState(.manualResumeAvailable, panelId: panel.id)
        _ = store.recordAgentPID(key: Self.pidKey, pid: Self.livePID, panelId: panel.id)

        store.updatePanelShellActivityState(panelId: panel.id, state: .commandRunning)
        #expect(store.surfaceResumeBinding(panelId: panel.id)?.allowsAutomaticResume == true)
        #expect(store.restoredAgentLifecycle.snapshotsByPanelId[panel.id]?.sessionId == Self.sessionID)
        #expect(store.restoredAgentLifecycle.resumeStatesByPanelId[panel.id] == .observedAgentCommandRunning)

        store.updatePanelShellActivityState(panelId: panel.id, state: .promptIdle)
        #expect(store.surfaceResumeBinding(panelId: panel.id)?.allowsAutomaticResume == true)
        #expect(store.restoredAgentLifecycle.resumeStatesByPanelId[panel.id] == .observedAgentCommandRunning)
    }

    @Test
    func dockStillRetiresBindingAfterAgentExits() throws {
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { store.closeAllPanels() }
        let panel = TerminalPanel(workspaceId: store.workspaceId)
        store.panels[panel.id] = panel

        store.updatePanelShellActivityState(panelId: panel.id, state: .commandRunning)
        #expect(store.setSurfaceResumeBinding(Self.trustedPiBinding(), panelId: panel.id))
        store.restoredAgentLifecycle.setResumeState(.observedAgentCommandRunning, panelId: panel.id)
        _ = store.recordAgentPID(key: Self.pidKey, pid: Self.exitedPID, panelId: panel.id)

        store.updatePanelShellActivityState(panelId: panel.id, state: .promptIdle)
        #expect(store.surfaceResumeBinding(panelId: panel.id)?.allowsAutomaticResume == false)
    }

    // MARK: - Deferred restore ownership

    /// After a relaunch the only process evidence for a restored binding is the
    /// hook-recorded PID that died with the previous app instance. While the
    /// restore is still deferred behind its ownership scan, nothing owns the
    /// binding yet, so the staleness reconciliation used to retire it and the
    /// scan then cancelled the launch: every deferred pane came back as a
    /// bare shell.
    @Test
    func workspaceKeepsDeferredRestoreBindingThroughStalenessReconciliation() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        let binding = Self.trustedPiBinding()

        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelId))
        let restoredAgent = try #require(workspace.restoredAgentSnapshotsByPanelId[panelId])
        workspace.deferredAgentResumeRestoresByPanelId[panelId] = DeferredAgentResumeRestore(
            stablePanelID: panelId,
            restorableAgent: restoredAgent,
            resumeBinding: binding,
            restoresRemoteWorkspaceTerminalSnapshot: false,
            workingDirectory: Self.projectDirectory,
            resumeWorkingDirectory: Self.projectDirectory
        )
        defer { workspace.deferredAgentResumeRestoresByPanelId.removeValue(forKey: panelId) }

        workspace.reconcileSurfaceResumeBindings(
            using: .empty,
            restorableAgentIndex: Self.emptyLiveIndex()
        )
        #expect(workspace.surfaceResumeBinding(panelId: panelId)?.allowsAutomaticResume == true)
        #expect(!workspace.isStaleAgentHookBinding(
            binding,
            panelId: panelId,
            restorableAgentIndex: Self.emptyLiveIndex()
        ))
    }

    @Test
    func workspaceRetiresBindingWhenCompletedIndexHasNoMatchingSession() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)

        #expect(workspace.setSurfaceResumeBinding(Self.trustedPiBinding(), panelId: panelId))
        workspace.reconcileSurfaceResumeBindings(
            using: .empty,
            restorableAgentIndex: Self.emptyLiveIndex()
        )
        // Unlike a missing index or pending restore, this completed scan has
        // no live owner for the old binding. Keep manual resume available, but
        // do not automatically replay a session whose process has exited.
        #expect(workspace.surfaceResumeBinding(panelId: panelId)?.allowsAutomaticResume == false)
    }

    /// A completed scan that found no live process for any panel.
    private static func emptyLiveIndex() -> RestorableAgentSessionIndex {
        RestorableAgentSessionIndex.load(
            homeDirectory: "/tmp/cmux-deferred-restore-empty-home",
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:],
            processIdentityProvider: { _ in nil }
        )
    }

    // MARK: - Foreground process evidence

    @Test
    func foregroundProcessRequiresSessionIdentityBeforeHookRegistersPID() {
        let agent = SessionRestorableAgentSnapshot(
            kind: .pi,
            sessionId: Self.sessionID,
            workingDirectory: Self.projectDirectory,
            launchCommand: nil
        )
        // Pi overwrites its argv with a bare title, so the foreground process
        // carries no session identity of its own.
        let piProcess = CmuxTopProcessArguments(arguments: ["pi"], environment: [:])
        let otherPiSession = CmuxTopProcessArguments(
            arguments: ["pi", "--session", "9b7e1c2d-3a4f-4e5b-8c6d-7e8f9a0b1c2d"],
            environment: [:]
        )
        let shellProcess = CmuxTopProcessArguments(arguments: ["zsh", "-l"], environment: [:])

        #expect(!RestoredAgentForegroundProcess.matches(
            agent,
            foregroundProcessID: 4242,
            processArguments: { _ in piProcess }
        ))
        #expect(!RestoredAgentForegroundProcess.matches(
            agent,
            foregroundProcessID: 4242,
            processArguments: { _ in otherPiSession }
        ))
        #expect(!RestoredAgentForegroundProcess.matches(
            agent,
            foregroundProcessID: 4242,
            processArguments: { _ in shellProcess }
        ))
        #expect(!RestoredAgentForegroundProcess.matches(
            agent,
            foregroundProcessID: nil,
            processArguments: { _ in piProcess }
        ))
        #expect(!RestoredAgentForegroundProcess.matches(
            agent,
            foregroundProcessID: 4242,
            processArguments: { _ in nil }
        ))
    }

    /// Once the session has registered its own process, a different bare Pi
    /// in the pane is another agent unless its argv names this session.
    @Test
    func foregroundVouchingIsBoundToTheSessionsRecordedProcess() {
        let agent = SessionRestorableAgentSnapshot(
            kind: .pi,
            sessionId: Self.sessionID,
            workingDirectory: Self.projectDirectory,
            launchCommand: nil
        )
        let barePi = CmuxTopProcessArguments(arguments: ["pi"], environment: [:])
        let sameSessionPi = CmuxTopProcessArguments(
            arguments: ["pi", "--session", Self.sessionID],
            environment: [:]
        )

        #expect(!RestoredAgentForegroundProcess.matches(
            agent,
            foregroundProcessID: 4242,
            processArguments: { _ in barePi }
        ))
        #expect(!RestoredAgentForegroundProcess.matches(
            agent,
            foregroundProcessID: 9999,
            processArguments: { _ in barePi }
        ))
        #expect(RestoredAgentForegroundProcess.matches(
            agent,
            foregroundProcessID: 9999,
            processArguments: { _ in sameSessionPi }
        ))
    }

    // MARK: - Shared evaluator

    @Test
    func sharedEvaluatorOrdersRecordedProcessThenIndexThenForeground() {
        let agent = SessionRestorableAgentSnapshot(
            kind: .pi,
            sessionId: Self.sessionID,
            workingDirectory: Self.projectDirectory,
            launchCommand: nil
        )
        let identity = AgentPIDProcessIdentity(pid: 4242, startSeconds: 100, startMicroseconds: 0)
        let recorded = RestoredAgentLiveness.RecordedProcess(pid: 4242, identity: identity)
        let workspaceId = UUID()
        let panelId = UUID()

        // The recorded process is alive with its recorded generation.
        #expect(RestoredAgentLiveness().hasLiveProcess(
            agent,
            workspaceId: workspaceId,
            panelId: panelId,
            recordedProcess: recorded,
            liveIndex: nil,
            foregroundProcessID: nil,
            currentProcessIdentity: { _ in identity }
        ))
        // The recorded process exited and the pane's foreground is something
        // that cannot be inspected.
        #expect(!RestoredAgentLiveness().hasLiveProcess(
            agent,
            workspaceId: workspaceId,
            panelId: panelId,
            recordedProcess: recorded,
            liveIndex: RestorableAgentSessionIndex.empty,
            foregroundProcessID: nil,
            currentProcessIdentity: { _ in nil }
        ))
        // A PID reused by another generation is not this session's process.
        #expect(!RestoredAgentLiveness().hasLiveProcess(
            agent,
            workspaceId: workspaceId,
            panelId: panelId,
            recordedProcess: recorded,
            liveIndex: nil,
            foregroundProcessID: nil,
            currentProcessIdentity: { _ in
                AgentPIDProcessIdentity(pid: 4242, startSeconds: 200, startMicroseconds: 0)
            }
        ))
        // Claude's key is panel-scoped and never vouches for a session.
        let claude = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: Self.sessionID,
            workingDirectory: Self.projectDirectory,
            launchCommand: nil
        )
        #expect(!RestoredAgentLiveness().hasLiveProcess(
            claude,
            workspaceId: workspaceId,
            panelId: panelId,
            recordedProcess: recorded,
            liveIndex: nil,
            foregroundProcessID: nil,
            currentProcessIdentity: { _ in identity }
        ))
    }

    /// A replacement Pi must identify the recorded session, even after its
    /// former process exits. A matching current hook PID remains sufficient.
    @Test
    func deadRecordedProcessRequiresIdentifiedForegroundSession() {
        let agent = SessionRestorableAgentSnapshot(
            kind: .pi,
            sessionId: Self.sessionID,
            workingDirectory: Self.projectDirectory,
            launchCommand: nil
        )
        let identity = AgentPIDProcessIdentity(pid: 4242, startSeconds: 100, startMicroseconds: 0)
        let recorded = RestoredAgentLiveness.RecordedProcess(pid: 4242, identity: identity)
        let barePi = CmuxTopProcessArguments(arguments: ["pi"], environment: [:])
        let workspaceId = UUID()
        let panelId = UUID()

        // The recorded process exited; a bare replacement Pi cannot identify its session.
        #expect(!RestoredAgentLiveness().hasLiveProcess(
            agent,
            workspaceId: workspaceId,
            panelId: panelId,
            recordedProcess: recorded,
            liveIndex: nil,
            foregroundProcessID: 9999,
            currentProcessIdentity: { _ in nil },
            foregroundProcessArguments: { _ in barePi }
        ))
        // An explicit matching session still supports resumes of resumes.
        #expect(RestoredAgentLiveness().hasLiveProcess(
            agent,
            workspaceId: workspaceId,
            panelId: panelId,
            recordedProcess: recorded,
            liveIndex: nil,
            foregroundProcessID: 9999,
            currentProcessIdentity: { _ in nil },
            foregroundProcessArguments: { _ in
                CmuxTopProcessArguments(
                    arguments: ["pi", "--session", Self.sessionID],
                    environment: [:]
                )
            }
        ))
        // PID reuse cannot bypass session validation through the foreground fallback.
        #expect(!RestoredAgentLiveness().hasLiveProcess(
            agent,
            workspaceId: workspaceId,
            panelId: panelId,
            recordedProcess: recorded,
            liveIndex: nil,
            foregroundProcessID: 4242,
            currentProcessIdentity: { _ in
                AgentPIDProcessIdentity(pid: 4242, startSeconds: 200, startMicroseconds: 0)
            },
            foregroundProcessArguments: { _ in barePi }
        ))
        // The recorded PID still exists under another generation; a different
        // bare process in the foreground does not vouch.
        #expect(!RestoredAgentLiveness().hasLiveProcess(
            agent,
            workspaceId: workspaceId,
            panelId: panelId,
            recordedProcess: recorded,
            liveIndex: nil,
            foregroundProcessID: 9999,
            currentProcessIdentity: { _ in
                AgentPIDProcessIdentity(pid: 4242, startSeconds: 200, startMicroseconds: 0)
            },
            foregroundProcessArguments: { _ in barePi }
        ))
        // A shell in the foreground never vouches, dead recorded process or not.
        #expect(!RestoredAgentLiveness().hasLiveProcess(
            agent,
            workspaceId: workspaceId,
            panelId: panelId,
            recordedProcess: recorded,
            liveIndex: nil,
            foregroundProcessID: 9999,
            currentProcessIdentity: { _ in nil },
            foregroundProcessArguments: { _ in CmuxTopProcessArguments(arguments: ["zsh", "-l"], environment: [:]) }
        ))
    }
}
