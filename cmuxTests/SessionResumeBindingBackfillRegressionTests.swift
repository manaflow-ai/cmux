import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Session resume binding backfill regressions")
struct SessionResumeBindingBackfillRegressionTests {
    @Test @MainActor
    func relaunchOnlyOllamaRemainsBindingFreeAcrossRepeatedSaves() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.restoredAgentSnapshotsByPanelId[panel.id] = SessionRestorableAgentSnapshot(
            kind: .ollama,
            sessionId: "",
            workingDirectory: "/tmp/ollama-project",
            launchCommand: AgentLaunchCommandSnapshot(
                processDetectedLauncher: "ollama",
                executablePath: "/opt/homebrew/bin/ollama",
                arguments: ["/opt/homebrew/bin/ollama", "run", "qwen3:8b"],
                workingDirectory: "/tmp/ollama-project",
                source: "process"
            )
        )
        workspace.restoredAgentResumeStatesByPanelId[panel.id] = .observedAgentCommandRunning
        workspace.updatePanelShellActivityState(panelId: panel.id, state: .commandRunning)

        for _ in 0..<2 {
            let snapshot = workspace.sessionSnapshot(
                includeScrollback: false,
                restorableAgentIndex: .empty,
                surfaceResumeBindingIndex: .empty
            )
            let terminal = try #require(snapshot.panels.first?.terminal)
            #expect(terminal.agent?.kind == .ollama)
            #expect(terminal.resumeBinding == nil)
            #expect(terminal.wasAgentRunning == false)
            #expect(workspace.unresolvedResumeBindingGapCount == 0)
        }
    }

    @Test
    func ignoredCustomAgentCwdDoesNotEnterBackfilledBinding() throws {
        let registration = CmuxVaultAgentRegistration(
            id: "cwdless-agent",
            name: "CWD-less Agent",
            detect: CmuxVaultAgentDetectRule(processName: "cwdless-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "{{executable}} --session {{sessionId}}",
            cwd: .ignore
        )
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .custom(registration.id),
            sessionId: "cwdless-session",
            workingDirectory: "/tmp/runtime-cwd",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: registration.id,
                executablePath: "/usr/local/bin/cwdless-agent",
                arguments: ["/usr/local/bin/cwdless-agent"],
                workingDirectory: "/tmp/launch-cwd",
                source: "process"
            ),
            registration: registration
        )

        let binding = try #require(snapshot.resumeBindingSnapshot())
        #expect(binding.cwd == nil)
        #expect(binding.launchCommand?.workingDirectory == nil)
        #expect(!binding.command.contains("/tmp/runtime-cwd"))
        #expect(!binding.command.contains("/tmp/launch-cwd"))

        var cwdTemplateSnapshot = snapshot
        cwdTemplateSnapshot.registration?.resumeCommand =
            "{{executable}} --session {{sessionId}} --cwd {{cwd}}"
        #expect(cwdTemplateSnapshot.resumeBindingSnapshot() == nil)
    }

    @Test @MainActor
    func discardingRestoredAgentClearsResumeBindingGap() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.restoredAgentSnapshotsByPanelId[panel.id] = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "discarded-session"
        )
        workspace.setResumeBindingGap(true, panelId: panel.id)
        #expect(workspace.unresolvedResumeBindingGapCount == 1)

        workspace.clearRestoredAgentSnapshot(panelId: panel.id)

        #expect(workspace.restoredAgentSnapshotsByPanelId[panel.id] == nil)
        #expect(workspace.unresolvedResumeBindingGapCount == 0)
        #expect(
            !workspace.sidebarStatusEntriesInDisplayOrder().contains {
                $0.key == Workspace.resumeBindingGapStatusKey
            }
        )
    }

    @Test @MainActor
    func conditionalRetryCannotReplaceChangedBinding() throws {
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = tabManager.addWorkspace(autoWelcomeIfNeeded: false)
        defer { tabManager.tabs.forEach { $0.teardownAllPanels() } }
        let panelID = try #require(workspace.focusedPanelId)
        let current = SurfaceResumeBindingSnapshot(
            kind: "claude",
            command: "claude --resume session-b",
            checkpointId: "session-b",
            source: "agent-hook",
            autoResume: true,
            updatedAt: 20
        )
        #expect(workspace.setSurfaceResumeBinding(current, panelId: panelID))
        let target = ControlSurfaceResumeTarget.workspace(
            tabManager: tabManager,
            workspace: workspace,
            surfaceID: panelID
        )
        let staleRetry = SurfaceResumeBindingSnapshot(
            kind: "claude",
            command: "claude --resume session-a",
            checkpointId: "session-a",
            source: "agent-hook",
            autoResume: true,
            updatedAt: 30
        )

        #expect(target.setBinding(
            staleRetry,
            expectedBindingUpdatedAt: 10
        ) == .generationMismatch)
        #expect(workspace.surfaceResumeBinding(panelId: panelID) == current)

        #expect(target.setBinding(
            staleRetry,
            expectedBindingUpdatedAt: current.updatedAt
        ) == .applied)
        #expect(workspace.surfaceResumeBinding(panelId: panelID) == staleRetry)
    }

    @Test @MainActor
    func conditionalRetryUsesAppOwnedOwnerGeneration() throws {
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = tabManager.addWorkspace(autoWelcomeIfNeeded: false)
        defer { tabManager.tabs.forEach { $0.teardownAllPanels() } }
        let panelID = try #require(workspace.focusedPanelId)
        let current = SurfaceResumeBindingSnapshot(
            kind: "claude",
            command: "claude --resume owner-session",
            checkpointId: "owner-session",
            source: "agent-hook",
            autoResume: true,
            updatedAt: 7
        )
        #expect(workspace.setSurfaceResumeBinding(current, panelId: panelID))
        let ownerGeneration = try #require(
            workspace.surfaceResumeBindingGeneration(panelId: panelID)
        )
        let target = ControlSurfaceResumeTarget.workspace(
            tabManager: tabManager,
            workspace: workspace,
            surfaceID: panelID
        )
        let replacement = SurfaceResumeBindingSnapshot(
            kind: "claude",
            command: "claude --resume replacement-session",
            checkpointId: "replacement-session",
            source: "agent-hook",
            autoResume: true,
            updatedAt: 7
        )
        let wrongGeneration = try #require(
            UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")
        )
        #expect(
            target.setBinding(
                replacement,
                expectedBindingGeneration: wrongGeneration
            ) == .generationMismatch
        )
        #expect(workspace.surfaceResumeBinding(panelId: panelID) == current)
        #expect(
            target.setBinding(
                replacement,
                expectedBindingGeneration: ownerGeneration
            ) == .applied
        )
        #expect(workspace.surfaceResumeBinding(panelId: panelID) == replacement)
        #expect(
            workspace.surfaceResumeBindingGeneration(panelId: panelID) != ownerGeneration
        )
    }

    @Test
    func fingerprintHashesPersistedResumeInputsWithoutRenderingCommand() {
        let registration = CmuxVaultAgentRegistration(
            id: "fingerprint-agent",
            name: "Fingerprint Agent",
            detect: CmuxVaultAgentDetectRule(processName: "fingerprint-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "{{executable}} --session {{sessionId}}"
        )
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .custom(registration.id),
            sessionId: "fingerprint-session",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: registration.id,
                executablePath: "/usr/local/bin/fingerprint-agent",
                arguments: ["/usr/local/bin/fingerprint-agent"],
                source: "test"
            ),
            registration: registration
        )
        let original = TabManager.restorableAgentSnapshotFingerprint(snapshot)

        var permissionChanged = snapshot
        permissionChanged.permissionMode = "never"
        #expect(
            TabManager.restorableAgentSnapshotFingerprint(permissionChanged) != original
        )

        var registrationChanged = snapshot
        registrationChanged.registration?.resumeCommand =
            "{{executable}} continue {{sessionId}}"
        #expect(
            TabManager.restorableAgentSnapshotFingerprint(registrationChanged) != original
        )
    }

    @Test
    func rejectedLaunchCaptureCannotBackfillBinding() {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "rejected-launch-session",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/usr/local/bin/claude",
                arguments: [],
                source: "rejected"
            )
        )

        #expect(snapshot.resumeBindingSnapshot() == nil)
    }

    @Test @MainActor
    func dockAutosaveFingerprintIncludesRetainedAgentAndBindingState() {
        let dock = DockSplitStore(
            workspaceId: UUID(),
            scope: .global,
            baseDirectoryProvider: { nil }
        )
        defer { dock.closeAllPanels() }
        let panelID = UUID()
        let baseline = dock.sessionAutosaveFingerprint(
            notificationStore: nil,
            restorableAgentIndex: .empty,
            surfaceResumeBindingIndex: .empty
        )

        dock.restoredAgentLifecycle.setSnapshot(
            SessionRestorableAgentSnapshot(
                kind: .claude,
                sessionId: "dock-fingerprint-session"
            ),
            panelId: panelID
        )
        let retained = dock.sessionAutosaveFingerprint(
            notificationStore: nil,
            restorableAgentIndex: .empty,
            surfaceResumeBindingIndex: .empty
        )
        #expect(retained != baseline)

        dock.surfaceResumeBindingsByPanelId[panelID] = SurfaceResumeBindingSnapshot(
            kind: "claude",
            command: "claude --resume dock-fingerprint-session",
            checkpointId: "dock-fingerprint-session",
            source: "agent-hook"
        )
        let withBinding = dock.sessionAutosaveFingerprint(
            notificationStore: nil,
            restorableAgentIndex: .empty,
            surfaceResumeBindingIndex: .empty
        )
        #expect(withBinding != retained)
    }

    @Test
    func heuristicProcessIdentityCannotBackfillAuthoritativeBinding() {
        var snapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "heuristic-session",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/usr/local/bin/claude",
                arguments: ["/usr/local/bin/claude"],
                source: "process"
            )
        )
        snapshot.processDetectedSessionIDSource = .inferredLatestSessionFile

        #expect(snapshot.resumeBindingSnapshot() == nil)
        #expect(snapshot.hasAuthoritativeResumeIdentity == false)
    }
}
