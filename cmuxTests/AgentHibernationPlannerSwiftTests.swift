import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct AgentHibernationPlannerSwiftTests {
    @MainActor
    @Test
    func agentPIDMutationInvalidatesPendingHibernationTeardown() throws {
        let controller = AgentHibernationController.shared
        let wasEnabled = AgentHibernationTrackingGate.isEnabled()
        defer { AgentHibernationTrackingGate.setEnabled(wasEnabled) }
        defer { resetSharedHibernationState(controller) }

        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panelKey = AgentHibernationPanelKey(workspaceId: workspace.id, panelId: panelId)
        let baselineEpoch = controller.teardownValidationEpochByPanel[panelKey] ?? 0

        AgentHibernationTrackingGate.setEnabled(true)
        workspace.recordAgentPID(
            key: "codex.live-session",
            pid: 12_345,
            panelId: panelId,
            refreshPorts: false
        )
        let recordEpoch = try #require(controller.teardownValidationEpochByPanel[panelKey])
        #expect(recordEpoch == baselineEpoch + 1)

        AgentHibernationTrackingGate.setEnabled(true)
        workspace.clearAgentPID(
            key: "codex.live-session",
            panelId: panelId,
            clearStatus: true,
            refreshPorts: false
        )
        #expect(controller.teardownValidationEpochByPanel[panelKey] == recordEpoch + 1)
    }

    @MainActor
    @Test
    func agentPIDRefreshDoesNotInvalidatePendingHibernationTeardown() throws {
        let controller = AgentHibernationController.shared
        let wasEnabled = AgentHibernationTrackingGate.isEnabled()
        defer { AgentHibernationTrackingGate.setEnabled(wasEnabled) }
        defer { resetSharedHibernationState(controller) }

        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panelKey = AgentHibernationPanelKey(workspaceId: workspace.id, panelId: panelId)

        AgentHibernationTrackingGate.setEnabled(true)
        workspace.recordAgentPID(
            key: "codex.live-session",
            pid: getpid(),
            panelId: panelId,
            refreshPorts: false
        )
        let recordEpoch = try #require(controller.teardownValidationEpochByPanel[panelKey])
        controller.activityByPanel[panelKey] = 123

        workspace.recordAgentPID(
            key: "codex.live-session",
            pid: getpid(),
            panelId: panelId,
            refreshPorts: false
        )

        #expect(controller.teardownValidationEpochByPanel[panelKey] == recordEpoch)
        #expect(controller.activityByPanel[panelKey] == 123)
    }

    @MainActor
    @Test
    func panelActivityKeepsPendingPostTeardownRestoreTaskAlive() {
        let controller = AgentHibernationController.shared
        let wasEnabled = AgentHibernationTrackingGate.isEnabled()
        defer { AgentHibernationTrackingGate.setEnabled(wasEnabled) }
        defer { resetSharedHibernationState(controller) }

        let key = AgentHibernationPanelKey(workspaceId: UUID(), panelId: UUID())
        let transcriptPath = "/tmp/cmux-hibernation-monitor-\(UUID().uuidString)/../transcript.jsonl"
        let requestID = UUID()
        let task = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
            }
        }
        defer {
            controller.clearPostTeardownRestoreTask(transcriptPath: transcriptPath, requestID: requestID)
            task.cancel()
        }
        AgentHibernationTrackingGate.setEnabled(true)
        controller.storePostTeardownRestoreTask(
            task,
            transcriptPath: transcriptPath,
            requestID: requestID,
            cancellationState: AgentHibernationController.PostTeardownRestoreCancellationState()
        )

        controller.recordTerminalFocus(workspaceId: key.workspaceId, panelId: key.panelId)

        let monitorKey = AgentHibernationController.postTeardownRestoreTaskKey(
            transcriptPath: transcriptPath
        )
        #expect(controller.postTeardownRestoreTasksByTranscriptPath[monitorKey] != nil)
        #expect(task.isCancelled == false)
    }

    @MainActor
    @Test
    func teardownRecordRejectsPanelMovedToAnotherWorkspace() throws {
        let source = Workspace()
        let panelId = try #require(source.focusedPanelId)
        let panel = try #require(source.panels[panelId] as? TerminalPanel)
        let record = AgentHibernationRecord(
            key: AgentHibernationPanelKey(workspaceId: source.id, panelId: panelId),
            workspace: source,
            terminalPanel: panel,
            agent: SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: "codex-moved-before-teardown",
                workingDirectory: "/tmp/cmux-agent-hibernation",
                launchCommand: nil
            ),
            lifecycle: .idle,
            hasUnconfirmedTerminalInput: false,
            lastActivityAt: 0,
            isProtected: false,
            hasLiveProcess: false,
            processIDs: []
        )
        #expect(record.isStillOwnedByOriginalWorkspace)

        let detached = try #require(source.detachSurface(panelId: panelId))
        let destination = Workspace()
        let destinationPaneId = try #require(destination.bonsplitController.focusedPaneId)
        #expect(destination.attachDetachedSurface(detached, inPane: destinationPaneId, focus: false) == panelId)

        #expect(record.isStillOwnedByOriginalWorkspace == false)
    }

    @Test
    func liveScopedProcessCreatesPressureButIsNotSelected() {
        let workspaceId = UUID()
        let now: TimeInterval = 1_000
        let runningAgent = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let exitedAgent = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let settings = AgentHibernationSettings.Values(
            enabled: true,
            idleSeconds: 60,
            maxLiveTerminals: 1,
            confirmationSeconds: 5
        )

        let selected = AgentHibernationPlanner.selectedPanelKeys(
            inputs: [
                .init(
                    key: runningAgent,
                    hasRestorableAgent: true,
                    isLive: true,
                    hasLiveProcess: true,
                    isProtected: false,
                    lifecycle: .idle,
                    hasUnconfirmedTerminalInput: false,
                    lastActivityAt: now - 300
                ),
                .init(
                    key: exitedAgent,
                    hasRestorableAgent: true,
                    isLive: true,
                    isProtected: false,
                    lifecycle: .idle,
                    hasUnconfirmedTerminalInput: false,
                    lastActivityAt: now - 200
                ),
            ],
            settings: settings,
            now: now
        )

        #expect(selected == Set([exitedAgent]))
    }

    @Test
    func unableToProtectPaneCreatesPressureButIsNotSelected() {
        let workspaceId = UUID()
        let now: TimeInterval = 1_000
        let unableToProtectAgent = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let safeAgent = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let settings = AgentHibernationSettings.Values(
            enabled: true,
            idleSeconds: 60,
            maxLiveTerminals: 1,
            confirmationSeconds: 5
        )

        let selected = AgentHibernationPlanner.selectedPanelKeys(
            inputs: [
                .init(
                    key: unableToProtectAgent,
                    hasRestorableAgent: true,
                    isLive: true,
                    isProtected: false,
                    lifecycle: .idle,
                    isTemporarilyUnableToProtect: true,
                    hasUnconfirmedTerminalInput: false,
                    lastActivityAt: now - 300
                ),
                .init(
                    key: safeAgent,
                    hasRestorableAgent: true,
                    isLive: true,
                    isProtected: false,
                    lifecycle: .idle,
                    hasUnconfirmedTerminalInput: false,
                    lastActivityAt: now - 200
                ),
            ],
            settings: settings,
            now: now
        )

        #expect(selected == Set([safeAgent]))
    }

    @MainActor
    @Test
    func unableToProtectMarkerExpiresSoTransientSnapshotFailuresRetry() {
        let marker = AgentHibernationController.UnableToProtectMarker(
            fingerprint: "tail:abc",
            lastActivityAt: 100,
            retryAfter: 220
        )

        #expect(AgentHibernationController.unableToProtectMarkerStillApplies(
            marker,
            fingerprint: "tail:abc",
            lastActivityAt: 100,
            now: 219
        ))
        #expect(AgentHibernationController.unableToProtectMarkerStillApplies(
            marker,
            fingerprint: "tail:abc",
            lastActivityAt: 100,
            now: 220
        ) == false)
        #expect(AgentHibernationController.unableToProtectMarkerStillApplies(
            marker,
            fingerprint: "tail:changed",
            lastActivityAt: 100,
            now: 219
        ) == false)
        #expect(AgentHibernationController.unableToProtectMarkerStillApplies(
            marker,
            fingerprint: "tail:abc",
            lastActivityAt: 101,
            now: 219
        ) == false)
    }

    @MainActor
    @Test
    func postSnapshotValidationDoesNotReuseTaskStartedBeforeSnapshotPoint() {
        let controller = AgentHibernationController.shared
        defer { resetSharedHibernationState(controller) }

        let staleRequestID = UUID()
        let staleTask = Task<RestorableAgentSessionIndex, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            return .empty
        }
        controller.postSnapshotValidationIndexSequence = 1
        controller.postSnapshotValidationIndexTask = AgentHibernationController.PostSnapshotValidationIndexTask(
            requestID: staleRequestID,
            startSequence: 1,
            task: staleTask
        )
        controller.postSnapshotValidationIndexSequence = 2

        _ = controller.sharedPostSnapshotValidationIndexTask(minimumStartSequence: 2)

        #expect(controller.postSnapshotValidationIndexTask?.requestID != staleRequestID)
        #expect(controller.postSnapshotValidationIndexTask?.startSequence == 2)
        #expect(staleTask.isCancelled)
    }

    @MainActor
    @Test
    func postSnapshotValidationReusesTaskForSameBatchBoundary() {
        let controller = AgentHibernationController.shared
        defer { resetSharedHibernationState(controller) }

        let boundary = controller.markPostSnapshotValidationPoint()
        _ = controller.sharedPostSnapshotValidationIndexTask(minimumStartSequence: boundary)
        let firstRequestID = controller.postSnapshotValidationIndexTask?.requestID

        _ = controller.sharedPostSnapshotValidationIndexTask(minimumStartSequence: boundary)

        #expect(controller.postSnapshotValidationIndexTask?.requestID == firstRequestID)
        #expect(controller.postSnapshotValidationIndexTask?.startSequence == boundary)
    }

    @MainActor
    @Test
    func postSnapshotValidationUsesFreshIndexLifecycleAndActivity() throws {
        let controller = AgentHibernationController.shared
        defer { resetSharedHibernationState(controller) }

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-post-snapshot-index-\(UUID().uuidString)", isDirectory: true)
        let storeURL = RestorableAgentKind.opencode.hookStoreFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)
        let sessionId = "opencode-post-snapshot-running"
        let hookUpdatedAt = Date().timeIntervalSince1970 + 1_000
        let jsonObject: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspace.id.uuidString,
                    "surfaceId": panelId.uuidString,
                    "cwd": "/tmp/repo",
                    "agentLifecycle": "running",
                    "updatedAt": hookUpdatedAt,
                    "launchCommand": [
                        "launcher": "opencode",
                        "executablePath": "/usr/local/bin/opencode",
                        "arguments": ["/usr/local/bin/opencode"],
                        "workingDirectory": "/tmp/repo",
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted])
        try data.write(to: storeURL, options: .atomic)
        let index = RestorableAgentSessionIndex.load(homeDirectory: home.path)
        let record = AgentHibernationRecord(
            key: AgentHibernationPanelKey(workspaceId: workspace.id, panelId: panelId),
            workspace: workspace,
            terminalPanel: panel,
            agent: SessionRestorableAgentSnapshot(
                kind: .opencode,
                sessionId: sessionId,
                workingDirectory: "/tmp/repo",
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "opencode",
                    executablePath: "/usr/local/bin/opencode",
                    arguments: ["/usr/local/bin/opencode"],
                    workingDirectory: "/tmp/repo",
                    environment: nil,
                    capturedAt: nil,
                    source: nil
                )
            ),
            lifecycle: .idle,
            hasUnconfirmedTerminalInput: false,
            lastActivityAt: 100,
            isProtected: false,
            hasLiveProcess: false,
            processIDs: []
        )

        #expect(controller.postSnapshotLifecycle(for: record, index: index) == .running)
        #expect(controller.postSnapshotEffectiveLastActivityAt(for: record, index: index) == hookUpdatedAt)
    }

    @MainActor
    private func resetSharedHibernationState(_ controller: AgentHibernationController) {
        controller.activityByPanel.removeAll(keepingCapacity: false)
        controller.terminalInputByPanel.removeAll(keepingCapacity: false)
        controller.lifecycleChangeByPanel.removeAll(keepingCapacity: false)
        controller.teardownValidationEpochByPanel.removeAll(keepingCapacity: false)
        controller.unableToProtectByPanel.removeAll(keepingCapacity: false)
        // Do NOT bulk-cancel the shared restore-monitor registry here: other
        // suites run concurrently against the shared controller, and a bulk
        // cancel would kill their in-flight monitors mid-test. Tests in this
        // suite that store a monitor clean up their own entry by request ID.
        controller.postSnapshotValidationIndexTask?.task.cancel()
        controller.postSnapshotValidationIndexSequence = 0
        controller.postSnapshotValidationIndexTask = nil
    }
}
