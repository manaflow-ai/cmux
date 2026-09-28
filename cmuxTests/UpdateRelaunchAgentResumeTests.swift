import CMUXAgentLaunch
import CmuxControlSocket
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A Sparkle update relaunch persists the session through
/// `AppDelegate.persistSessionForUpdateRelaunch()`, which cannot scan processes
/// from the synchronous updater callback and so saves with
/// `ProcessDetectedResumeIndexes.cached(...)`. Every agent that was open before
/// the update must come back through the launcher that started it.
///
/// Each session here is known only through its agent-hook resume binding: the
/// cached live-agent index has not seen it yet, which is the state of any agent
/// started after the last index refresh.
@MainActor
@Suite("Update relaunch keeps every agent resumable through its own launcher")
struct UpdateRelaunchAgentResumeTests {
    private struct Case {
        let label: String
        let kind: String
        let sessionID: String
        let command: String
        let launchCommand: AgentLaunchCommandSnapshot
        let expectedArguments: [String]
    }

    private static let workingDirectory = "/tmp/cmux-update-relaunch-project"
    private static let subrouterMarker = "sr claude proxy --resume"

    private static let cases: [Case] = [
        Case(
            label: "sr-routed claude",
            kind: "claude",
            sessionID: "0198f073-0a5b-7000-8000-00000000a001",
            command: "claude --resume 0198f073-0a5b-7000-8000-00000000a001",
            launchCommand: AgentLaunchCommandSnapshot(
                executablePath: "/opt/homebrew/bin/claude",
                arguments: ["/opt/homebrew/bin/claude", "--model", "opus"],
                workingDirectory: workingDirectory,
                environment: [
                    "ANTHROPIC_BASE_URL": "http://127.0.0.1:31415/v1",
                    SubrouterClaudeResumeRouting.environmentKey: subrouterMarker,
                    SubrouterClaudeResumeRouting.launchBoundEnvironmentKey: subrouterMarker,
                ],
                capturedAt: 1,
                source: "hook"
            ),
            expectedArguments: [
                "sr", "claude", "proxy", "--resume",
                "0198f073-0a5b-7000-8000-00000000a001", "--model", "opus",
            ]
        ),
        Case(
            label: "external launcher claude",
            kind: "claude",
            sessionID: "0198f073-0a5b-7000-8000-00000000a002",
            command: "claude --resume 0198f073-0a5b-7000-8000-00000000a002",
            launchCommand: AgentLaunchCommandSnapshot(
                externalLauncher: "teamclaude",
                executablePath: "/opt/homebrew/bin/claude",
                arguments: ["/opt/homebrew/bin/claude"],
                workingDirectory: workingDirectory,
                capturedAt: 1,
                source: "hook"
            ),
            expectedArguments: [
                "teamclaude", "run", "--", "--resume", "0198f073-0a5b-7000-8000-00000000a002",
            ]
        ),
        Case(
            label: "plain claude",
            kind: "claude",
            sessionID: "0198f073-0a5b-7000-8000-00000000a003",
            command: "claude --resume 0198f073-0a5b-7000-8000-00000000a003",
            launchCommand: AgentLaunchCommandSnapshot(
                executablePath: "/opt/homebrew/bin/claude",
                arguments: ["claude"],
                workingDirectory: workingDirectory,
                capturedAt: 1,
                source: "hook"
            ),
            expectedArguments: ["claude", "--resume", "0198f073-0a5b-7000-8000-00000000a003"]
        ),
        Case(
            label: "plain codex",
            kind: "codex",
            sessionID: "0198f073-0a5b-7000-8000-00000000a004",
            command: "codex resume 0198f073-0a5b-7000-8000-00000000a004",
            launchCommand: AgentLaunchCommandSnapshot(
                executablePath: "/opt/homebrew/bin/codex",
                arguments: ["codex"],
                workingDirectory: workingDirectory,
                capturedAt: 1,
                source: "hook"
            ),
            expectedArguments: [
                "/opt/homebrew/bin/codex", "resume", "0198f073-0a5b-7000-8000-00000000a004",
                "-c", "check_for_update_on_startup=false",
            ]
        ),
    ]

    private static let planner = AgentRestorePlanner(
        isExecutableFile: { path in
            ["/opt/homebrew/bin/sr", "/opt/homebrew/bin/teamclaude", "/opt/homebrew/bin/codex"].contains(path)
        },
        isReadableFile: { _ in true },
        externalLaunchers: AgentExternalLauncherRegistry(launchers: [
            AgentExternalLauncher(
                id: "teamclaude",
                kinds: ["claude"],
                argvExecutables: ["teamclaude"],
                resumeArgvPrefix: ["teamclaude", "run", "--"]
            ),
        ])
    )

    private static let ambientEnvironment = [
        "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
        "HOME": "/Users/me",
    ]

    @Test("Each agent is saved auto-resumable and restores through its launcher")
    func updateRelaunchRestoresEveryAgentThroughItsLauncher() throws {
        let approvalStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-update-relaunch-approvals-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: approvalStoreURL) }

        var restoredLabels: [String] = []
        for testCase in Self.cases {
            let workspace = Workspace()
            defer { workspace.teardownAllPanels() }
            let panelId = try #require(workspace.focusedPanelId)
            let liveBinding = SurfaceResumeBindingSnapshot(
                kind: testCase.kind,
                command: testCase.command,
                cwd: Self.workingDirectory,
                checkpointId: testCase.sessionID,
                source: "agent-hook",
                launchCommand: testCase.launchCommand,
                autoResume: true
            )
            try #require(workspace.setSurfaceResumeBinding(liveBinding, panelId: panelId))

            // The same indexes `persistSessionForUpdateRelaunch()` passes when the
            // shared live-agent index has not seen this session (or has not
            // loaded yet, where it falls back to `.empty`).
            let updateRelaunchIndexes = ProcessDetectedResumeIndexes.cached(
                restorableAgentIndex: .empty
            )
            // Scrollback capture does not affect resume planning and needs a
            // started surface, so it is left out.
            let saved = workspace.sessionSnapshot(
                includeScrollback: false,
                restorableAgentIndex: updateRelaunchIndexes.restorableAgentIndex,
                surfaceResumeBindingIndex: updateRelaunchIndexes.surfaceResumeBindingIndex
            )

            // Saving is not evidence that the agent exited: the live binding the
            // later terminate-path save reads must keep its automatic resume.
            #expect(
                workspace.surfaceResumeBinding(panelId: panelId)?.allowsAutomaticResume == true,
                "\(testCase.label): the update relaunch save retired the live binding"
            )

            // Round-trip through the persisted form that the relaunched app reads.
            let persisted = try JSONDecoder().decode(
                SessionWorkspaceSnapshot.self,
                from: JSONEncoder().encode(saved)
            )
            let restoredBinding = try #require(
                persisted.panels.first(where: { $0.id == panelId })?.terminal?.resumeBinding,
                "\(testCase.label): the agent was dropped from the update relaunch snapshot"
            )

            // The binding still authorizes the short restore verb. Whether restore
            // types it also depends on `wasAgentRunning`, which needs process
            // evidence this cached save does not have; the fresh save on the
            // terminate path that follows supplies it.
            #expect(
                Workspace.surfaceResumeStartupInput(
                    restoredBinding,
                    autoResumeAgentSessions: true,
                    promptForApproval: false,
                    approvalStoreURL: approvalStoreURL
                ) == " cmux restore \(testCase.kind) \(testCase.sessionID)\n",
                "\(testCase.label): restore did not plan an automatic resume"
            )

            // `cmux restore` then plans the argv from the app's restore record.
            let record = TerminalController.shared.controlSurfaceBindingContinuationRecord(
                binding: restoredBinding,
                compatibilityBinding: nil,
                restoredAgentExists: false
            )
            let request = try Self.restoreRequest(from: record)
            let invocation = try #require(
                Self.planner.invocation(
                    for: request,
                    ambientEnvironment: Self.ambientEnvironment
                ),
                "\(testCase.label): the restore record could not be planned"
            )
            #expect(
                invocation.arguments == testCase.expectedArguments,
                "\(testCase.label): \(invocation.arguments)"
            )
            #expect(invocation.workingDirectory == Self.workingDirectory, "\(testCase.label)")
            restoredLabels.append(testCase.label)
        }
        #expect(restoredLabels == Self.cases.map(\.label))
    }

    /// The update relaunch save (and the quit watchdog fallback after a timed-out
    /// fresh scan) cannot scan processes, so its binding index is unavailable.
    /// That is missing evidence, not proof that tmux exited: the pane attached
    /// to tmux at the last autosave must still reattach after the relaunch.
    @Test("A tmux pane stays reattachable through the cached update relaunch save")
    func updateRelaunchKeepsProcessDetectedTmuxBinding() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        let tmuxBinding = SurfaceResumeBindingSnapshot(
            name: "tmux",
            kind: "tmux",
            command: "tmux attach-session -t work",
            cwd: Self.workingDirectory,
            checkpointId: "work",
            source: "process-detected",
            autoResume: true,
            updatedAt: 1_999_999_999
        )

        // The last autosave's fresh process scan saw tmux in this pane.
        _ = workspace.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: SurfaceResumeBindingIndex(bindingsByPanel: [
                .init(workspaceId: workspace.id, panelId: panelId): tmuxBinding,
            ])
        )
        #expect(workspace.surfaceResumeBinding(panelId: panelId)?.command == tmuxBinding.command)

        let updateRelaunchIndexes = ProcessDetectedResumeIndexes.cached(
            restorableAgentIndex: .empty
        )
        let saved = workspace.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: updateRelaunchIndexes.restorableAgentIndex,
            surfaceResumeBindingIndex: updateRelaunchIndexes.surfaceResumeBindingIndex
        )
        let persisted = try JSONDecoder().decode(
            SessionWorkspaceSnapshot.self,
            from: JSONEncoder().encode(saved)
        )
        let restoredBinding = try #require(
            persisted.panels.first(where: { $0.id == panelId })?.terminal?.resumeBinding,
            "the tmux reattach binding was dropped from the update relaunch snapshot"
        )
        #expect(restoredBinding.command == tmuxBinding.command)
        #expect(restoredBinding.allowsAutomaticResume)
        #expect(workspace.surfaceResumeBinding(panelId: panelId)?.command == tmuxBinding.command)
    }

    /// The relaunch save uses the indexes captured just before the relaunch, so an agent the
    /// cached index has not seen yet is still saved as running. A capture from a relaunch that
    /// did not happen is never reused.
    @Test("The update relaunch save uses only a recent pre-relaunch capture, once")
    func updateRelaunchIndexCaptureIsRecentAndSingleUse() throws {
        let fresh = ProcessDetectedResumeIndexes(
            restorableAgentIndex: .empty,
            surfaceResumeBindingIndex: SurfaceResumeBindingIndex(bindingsByPanel: [:])
        )
        var capture = UpdateRelaunchIndexCapture()
        #expect(capture.take(now: 100) == nil)

        capture.store(fresh, capturedAt: 100)
        let taken = try #require(capture.take(now: 100 + UpdateRelaunchIndexCapture.lifetime))
        #expect(taken.surfaceResumeBindingIndex.isAvailable)
        #expect(capture.take(now: 101) == nil)

        capture.store(fresh, capturedAt: 100)
        #expect(capture.take(now: 101 + UpdateRelaunchIndexCapture.lifetime) == nil)
        #expect(capture.take(now: 101) == nil)
    }

    /// An agent the update relaunch cut off mid-task is saved marked, and only that save marks it.
    @Test("The update relaunch save marks only mid-task agents to continue")
    func updateRelaunchSaveMarksMidTaskAgents() throws {
        let nudges = UpdateRelaunchContinuationNudges.shared
        let previousMidTask = nudges.midTaskPanelIds
        defer { nudges.midTaskPanelIds = previousMidTask }
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        try #require(workspace.setSurfaceResumeBinding(Self.continuationBinding, panelId: panelId))

        func savedTerminal() throws -> (terminal: SessionTerminalPanelSnapshot?, json: String) {
            let data = try JSONEncoder().encode(workspace.sessionSnapshot(includeScrollback: false))
            let persisted = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: data)
            return (
                persisted.panels.first(where: { $0.id == panelId })?.terminal,
                String(decoding: data, as: UTF8.self)
            )
        }

        nudges.midTaskPanelIds = [panelId]
        #expect(try savedTerminal().terminal?.resumeWithContinuation == true)

        // An idle agent at the relaunch, and every ordinary save, leave the field out, so
        // snapshots from builds without it decode the same way.
        nudges.midTaskPanelIds = [UUID()]
        let idle = try savedTerminal()
        #expect(idle.terminal?.resumeWithContinuation == nil)
        #expect(!idle.json.contains("resumeWithContinuation"))
        nudges.midTaskPanelIds = []
        #expect(try savedTerminal().terminal?.resumeWithContinuation == nil)
    }

    /// The relaunched app resumes a marked agent with the continuation prompt, once; an unmarked
    /// agent resumes plainly.
    @Test("A marked agent resumes with the continuation prompt once")
    func markedAgentResumesWithContinuationPromptOnce() throws {
        let suiteName = "cmux-update-relaunch-continuation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let nudges = UpdateRelaunchContinuationNudges.shared

        func restoredRecord(marked: Bool) throws -> (record: ControlSurfaceRestoreRecord, panelId: UUID) {
            let source = Workspace()
            let sourcePanelId = try #require(source.focusedPanelId)
            try #require(source.setSurfaceResumeBinding(Self.continuationBinding, panelId: sourcePanelId))
            var saved = try JSONDecoder().decode(
                SessionWorkspaceSnapshot.self,
                from: JSONEncoder().encode(source.sessionSnapshot(includeScrollback: false))
            )
            source.teardownAllPanels()
            let index = try #require(saved.panels.firstIndex(where: { $0.id == sourcePanelId }))
            saved.panels[index].terminal?.wasAgentRunning = true
            saved.panels[index].terminal?.resumeWithContinuation = marked ? true : nil

            let restored = Workspace(agentSessionAutoResumeDefaults: defaults)
            defer { restored.teardownAllPanels() }
            let panelId = try #require(restored.restoreSessionSnapshot(saved)[sourcePanelId])
            let record = try #require(TerminalController.shared.controlSurfaceRestoreRecord(
                target: .workspace(tabManager: tabManager, workspace: restored, surfaceID: panelId),
                binding: restored.surfaceResumeBinding(panelId: panelId)
            ))
            return (record, panelId)
        }

        let marked = try restoredRecord(marked: true)
        defer { nudges.consume(panelId: marked.panelId) }
        #expect(marked.record.continuationPrompt == UpdateRelaunchContinuationNudges.prompt)
        let request = try Self.restoreRequest(from: marked.record)
        let invocation = try #require(Self.planner.invocation(
            for: request,
            ambientEnvironment: Self.ambientEnvironment
        ))
        #expect(invocation.arguments == [
            "claude", "--resume", Self.continuationBinding.checkpointId ?? "",
            UpdateRelaunchContinuationNudges.prompt,
        ])

        // The admitted resume consumes the nudge, so a later restore resumes plainly.
        nudges.consume(panelId: marked.panelId)
        #expect(nudges.prompt(forPanel: marked.panelId) == nil)

        #expect(try restoredRecord(marked: false).record.continuationPrompt == nil)
    }

    /// A nudge the restore never used expires, so a manual resume much later resumes plainly.
    @Test("An unused continuation nudge expires")
    func unusedContinuationNudgeExpires() {
        let nudges = UpdateRelaunchContinuationNudges.shared
        let panelId = UUID()
        defer { nudges.consume(panelId: panelId) }
        let marked = SessionTerminalPanelSnapshot(resumeWithContinuation: true)

        nudges.registerRestoredPanel(panelId, snapshot: marked, resumesAgent: false, now: 100)
        #expect(nudges.prompt(forPanel: panelId, now: 100) == nil)

        nudges.registerRestoredPanel(panelId, snapshot: marked, resumesAgent: true, now: 100)
        #expect(nudges.prompt(forPanel: panelId, now: 100 + UpdateRelaunchContinuationNudges.lifetime)
            == UpdateRelaunchContinuationNudges.prompt)
        #expect(nudges.prompt(forPanel: panelId, now: 101 + UpdateRelaunchContinuationNudges.lifetime) == nil)
        #expect(nudges.prompt(forPanel: panelId, now: 100) == nil)
    }

    private static let continuationBinding = SurfaceResumeBindingSnapshot(
        kind: "claude",
        command: "claude --resume 0198f073-0a5b-7000-8000-00000000a0c1",
        cwd: workingDirectory,
        checkpointId: "0198f073-0a5b-7000-8000-00000000a0c1",
        source: "agent-hook",
        launchCommand: AgentLaunchCommandSnapshot(
            executablePath: "/opt/homebrew/bin/claude",
            arguments: ["claude"],
            workingDirectory: workingDirectory,
            capturedAt: 1,
            source: "hook"
        ),
        autoResume: true
    )

    /// Mirrors the `cmux restore` CLI mapping from a socket restore record to
    /// the planner request.
    private static func restoreRequest(from record: ControlSurfaceRestoreRecord) throws -> AgentRestoreRequest {
        AgentRestoreRequest(
            mode: try #require(AgentRestoreRequestMode(rawValue: record.modeRawValue)),
            kind: record.kind,
            checkpointID: record.checkpointID,
            source: record.source,
            workingDirectory: record.workingDirectory,
            environment: record.environment,
            launchCommand: record.launchCommand.map {
                AgentLaunchCommand(
                    launcher: $0.launcher,
                    externalLauncher: $0.externalLauncher,
                    executablePath: $0.executablePath,
                    arguments: $0.arguments,
                    workingDirectory: $0.workingDirectory,
                    environment: $0.environment,
                    verificationHome: $0.verificationHome,
                    capturedAt: $0.capturedAt,
                    source: $0.source
                )
            },
            preparedArguments: record.preparedArguments,
            preparedArgumentsWorkingDirectory: record.preparedArgumentsWorkingDirectory,
            observedPermissionMode: record.permissionMode,
            continuationPrompt: record.continuationPrompt
        )
    }
}
