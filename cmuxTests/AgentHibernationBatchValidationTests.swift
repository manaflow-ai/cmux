import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension AgentHibernationPlannerSwiftTests {
    @MainActor
    @Test
    func multipleRestoreMonitorsShareOnePostQuiescenceIndex() async throws {
        let controller = AgentHibernationController.shared
        let wasEnabled = AgentHibernationTrackingGate.isEnabled()
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = previousAppDelegate ?? AppDelegate()
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-batch-teardown-boundary-\(UUID().uuidString)", isDirectory: true)
        let configRoot = testDirectory.appendingPathComponent("claude-config", isDirectory: true)
        defer {
            if previousAppDelegate == nil, AppDelegate.shared === appDelegate {
                AppDelegate.shared = nil
            }
            AgentHibernationTrackingGate.setEnabled(wasEnabled)
            resetSharedHibernationState(controller)
            try? FileManager.default.removeItem(at: testDirectory)
        }

        AgentHibernationTrackingGate.setEnabled(true)
        let confirmationFingerprint = "headless-runtime-fingerprint"
        let first = try Self.batchFixture(
            name: "first",
            configRoot: configRoot,
            controller: controller,
            confirmationFingerprint: confirmationFingerprint
        )
        let second = try Self.batchFixture(
            name: "second",
            configRoot: configRoot,
            controller: controller,
            confirmationFingerprint: confirmationFingerprint
        )
        let fixtures = [first, second]
        let monitorReady = fixtures.map { _ in DispatchSemaphore(value: 0) }
        let cancellationObserved = fixtures.map { _ in DispatchSemaphore(value: 0) }
        let releaseMonitor = fixtures.map { _ in DispatchSemaphore(value: 0) }
        let olderMonitorRequestIDs = fixtures.map { _ in UUID() }
        let olderMonitorTasks = fixtures.indices.map { index in
            Task.detached {
                await withTaskCancellationHandler {
                    monitorReady[index].signal()
                    releaseMonitor[index].wait()
                } onCancel: {
                    cancellationObserved[index].signal()
                }
            }
        }
        defer {
            for index in fixtures.indices {
                releaseMonitor[index].signal()
                olderMonitorTasks[index].cancel()
                controller.clearPostTeardownRestoreTask(
                    transcriptPath: fixtures[index].transcriptPath,
                    requestID: olderMonitorRequestIDs[index]
                )
            }
        }
        for index in fixtures.indices {
            #expect(await Self.wait(for: monitorReady[index]))
            #expect(controller.storePostTeardownRestoreTask(
                olderMonitorTasks[index],
                transcriptPath: fixtures[index].transcriptPath,
                requestID: olderMonitorRequestIDs[index],
                cancellationState: AgentHibernationController.PostTeardownRestoreCancellationState()
            ))
        }

        controller.postSnapshotValidationIndexSequence = 0
        // Synchronous loader callbacks can overlap; the lock protects only this test counter.
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let teardownTask = controller.beginConfirmedTeardowns(
            [first.request, second.request],
            postSnapshotIndexLoader: {
                loadCount.withLock { count in
                    count += 1
                }
                return .empty
            },
            runtimeObservationProvider: { _ in
                AgentHibernationController.ConfirmedTeardownRuntimeObservation(
                    hasLiveSurface: true,
                    fingerprint: confirmationFingerprint
                )
            }
        )
        for index in fixtures.indices {
            #expect(await Self.wait(for: cancellationObserved[index]))
            releaseMonitor[index].signal()
        }
        await teardownTask.value

        #expect(loadCount.withLock { $0 } == 2)
        #expect(first.panel.isAgentHibernated)
        #expect(second.panel.isAgentHibernated)

        _ = await controller.cancelPostTeardownRestoreTaskForReplacement(
            transcriptPath: first.transcriptPath
        )
        _ = await controller.cancelPostTeardownRestoreTaskForReplacement(
            transcriptPath: second.transcriptPath
        )
    }

    @MainActor
    @Test
    func finalValidationCannotAdmitRequestWhoseMonitorWasNotQuiesced() async throws {
        let controller = AgentHibernationController.shared
        let wasEnabled = AgentHibernationTrackingGate.isEnabled()
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-batch-newly-eligible-\(UUID().uuidString)", isDirectory: true)
        let configRoot = testDirectory.appendingPathComponent("claude-config", isDirectory: true)
        defer {
            AgentHibernationTrackingGate.setEnabled(wasEnabled)
            resetSharedHibernationState(controller)
            try? FileManager.default.removeItem(at: testDirectory)
        }

        AgentHibernationTrackingGate.setEnabled(true)
        let confirmationFingerprint = "newly-eligible-fingerprint"
        let first = try Self.batchFixture(
            name: "initially-qualified",
            configRoot: configRoot,
            controller: controller,
            confirmationFingerprint: confirmationFingerprint
        )
        let second = try Self.batchFixture(
            name: "newly-eligible",
            configRoot: configRoot,
            controller: controller,
            confirmationFingerprint: confirmationFingerprint
        )
        let fixtures = [first, second]
        let monitorReady = fixtures.map { _ in DispatchSemaphore(value: 0) }
        let cancellationObserved = fixtures.map { _ in DispatchSemaphore(value: 0) }
        let releaseMonitor = fixtures.map { _ in DispatchSemaphore(value: 0) }
        let monitorRequestIDs = fixtures.map { _ in UUID() }
        let monitorTasks = fixtures.indices.map { index in
            Task.detached {
                await withTaskCancellationHandler {
                    monitorReady[index].signal()
                    releaseMonitor[index].wait()
                } onCancel: {
                    cancellationObserved[index].signal()
                }
            }
        }
        defer {
            for index in fixtures.indices {
                releaseMonitor[index].signal()
                monitorTasks[index].cancel()
                controller.clearPostTeardownRestoreTask(
                    transcriptPath: fixtures[index].transcriptPath,
                    requestID: monitorRequestIDs[index]
                )
            }
        }
        for index in fixtures.indices {
            #expect(await Self.wait(for: monitorReady[index]))
            #expect(controller.storePostTeardownRestoreTask(
                monitorTasks[index],
                transcriptPath: fixtures[index].transcriptPath,
                requestID: monitorRequestIDs[index],
                cancellationState: AgentHibernationController.PostTeardownRestoreCancellationState()
            ))
        }

        controller.postSnapshotValidationIndexSequence = 0
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let firstIndex = Self.indexWithLiveProcess(
            workspaceId: second.record.key.workspaceId,
            panelId: second.record.key.panelId,
            agent: second.record.agent,
            processID: 44_201
        )
        let teardownTask = controller.beginConfirmedTeardowns(
            [first.request, second.request],
            postSnapshotIndexLoader: {
                let invocation = loadCount.withLock { count in
                    count += 1
                    return count
                }
                return invocation == 1 ? firstIndex : .empty
            },
            runtimeObservationProvider: { _ in
                AgentHibernationController.ConfirmedTeardownRuntimeObservation(
                    hasLiveSurface: true,
                    fingerprint: confirmationFingerprint
                )
            }
        )
        #expect(await Self.wait(for: cancellationObserved[0]))
        releaseMonitor[0].signal()
        await teardownTask.value

        #expect(loadCount.withLock { $0 } == 2)
        #expect(first.panel.isAgentHibernated)
        #expect(!second.panel.isAgentHibernated)
        #expect(controller.postTeardownRestoreTaskIsCurrent(
            transcriptPath: second.transcriptPath,
            requestID: monitorRequestIDs[1]
        ))
    }

    @MainActor
    private static func batchFixture(
        name: String,
        configRoot: URL,
        controller: AgentHibernationController,
        confirmationFingerprint: String
    ) throws -> (
        record: AgentHibernationRecord,
        request: AgentHibernationController.ConfirmedTeardownRequest,
        panel: TerminalPanel,
        transcriptPath: String
    ) {
        let workingDirectory = "/tmp/cmux-batch-teardown-\(name)-\(UUID().uuidString)"
        let sessionId = "batch-teardown-\(name)-\(UUID().uuidString)"
        let transcriptURL = configRoot
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(
                RestorableAgentSessionIndex.encodeClaudeProjectDir(workingDirectory),
                isDirectory: true
            )
            .appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try #"{"type":"user","message":{"role":"user","content":"keep this turn"}}"#.write(
            to: transcriptURL,
            atomically: true,
            encoding: .utf8
        )

        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)
        let key = AgentHibernationPanelKey(workspaceId: workspace.id, panelId: panelId)
        let agent = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionId,
            workingDirectory: workingDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/usr/local/bin/claude",
                arguments: ["/usr/local/bin/claude"],
                workingDirectory: workingDirectory,
                environment: ["CLAUDE_CONFIG_DIR": configRoot.path],
                capturedAt: nil,
                source: nil
            )
        )
        workspace.setRestoredAgentSnapshotForTesting(agent, panelId: panelId)
        workspace.setAgentLifecycle(key: "claude.batch-\(name)", panelId: panelId, lifecycle: .idle)
        let record = AgentHibernationRecord(
            key: key,
            workspace: workspace,
            terminalPanel: panel,
            agent: agent,
            lifecycle: .idle,
            hasUnconfirmedTerminalInput: false,
            lastActivityAt: 0,
            isProtected: false,
            hasLiveProcess: false,
            processIDs: []
        )
        return (
            record: record,
            request: AgentHibernationController.ConfirmedTeardownRequest(
                record: record,
                confirmationFingerprint: confirmationFingerprint,
                effectiveLastActivityAt: Date().timeIntervalSince1970 + 60,
                requestID: UUID(),
                epoch: controller.teardownValidationEpochByPanel[key] ?? 0,
                generation: controller.teardownValidationGeneration
            ),
            panel: panel,
            transcriptPath: transcriptURL.path
        )
    }

    @MainActor
    @Test
    func unavailablePostQuiescenceIndexRetainsRecoveryWithoutStalePIDMonitor() async throws {
        let controller = AgentHibernationController.shared
        let wasEnabled = AgentHibernationTrackingGate.isEnabled()
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = previousAppDelegate ?? AppDelegate()
        let sessionId = "post-quiescence-unavailable-\(UUID().uuidString)"
        let snapshotDirectory = try #require(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("agent-transcript-teardown-snapshots", isDirectory: true)
        let retainedSnapshot = snapshotDirectory
            .appendingPathComponent("\(sessionId)-retained.jsonl", isDirectory: false)
        try? FileManager.default.removeItem(at: retainedSnapshot)
        defer {
            try? FileManager.default.removeItem(at: retainedSnapshot)
            if previousAppDelegate == nil, AppDelegate.shared === appDelegate {
                AppDelegate.shared = nil
            }
            AgentHibernationTrackingGate.setEnabled(wasEnabled)
            resetSharedHibernationState(controller)
        }

        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-post-quiescence-unavailable-\(UUID().uuidString)", isDirectory: true)
        let configRoot = testDirectory.appendingPathComponent("claude-config", isDirectory: true)
        let workingDirectory = "/tmp/cmux-post-quiescence-unavailable-\(UUID().uuidString)"
        let transcriptURL = configRoot
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(
                RestorableAgentSessionIndex.encodeClaudeProjectDir(workingDirectory),
                isDirectory: true
            )
            .appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try #"{"type":"user","message":{"role":"user","content":"retain this turn"}}"#.write(
            to: transcriptURL,
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: testDirectory) }

        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)
        let panelKey = AgentHibernationPanelKey(workspaceId: workspace.id, panelId: panelId)
        let agent = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionId,
            workingDirectory: workingDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/usr/local/bin/claude",
                arguments: ["/usr/local/bin/claude"],
                workingDirectory: workingDirectory,
                environment: ["CLAUDE_CONFIG_DIR": configRoot.path],
                capturedAt: nil,
                source: nil
            )
        )
        workspace.setRestoredAgentSnapshotForTesting(agent, panelId: panelId)
        workspace.setAgentLifecycle(key: "claude.post-quiescence-unavailable", panelId: panelId, lifecycle: .idle)

        let priorMonitorRequestID = UUID()
        let priorMonitor = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
            }
        }
        #expect(controller.storePostTeardownRestoreTask(
            priorMonitor,
            transcriptPath: transcriptURL.path,
            requestID: priorMonitorRequestID,
            cancellationState: AgentHibernationController.PostTeardownRestoreCancellationState()
        ))

        AgentHibernationTrackingGate.setEnabled(true)
        let confirmationFingerprint = "headless-runtime-fingerprint"
        let record = AgentHibernationRecord(
            key: panelKey,
            workspace: workspace,
            terminalPanel: panel,
            agent: agent,
            lifecycle: .idle,
            hasUnconfirmedTerminalInput: false,
            lastActivityAt: 0,
            isProtected: false,
            hasLiveProcess: false,
            processIDs: [Int(ProcessInfo.processInfo.processIdentifier)]
        )
        let request = AgentHibernationController.ConfirmedTeardownRequest(
            record: record,
            confirmationFingerprint: confirmationFingerprint,
            effectiveLastActivityAt: Date().timeIntervalSince1970 + 60,
            requestID: UUID(),
            epoch: controller.teardownValidationEpochByPanel[panelKey] ?? 0,
            generation: controller.teardownValidationGeneration
        )
        let loadCount = OSAllocatedUnfairLock(initialState: 0)

        let teardownTask = controller.beginConfirmedTeardowns(
            [request],
            postSnapshotIndexLoader: {
                let invocation = loadCount.withLock { count in
                    count += 1
                    return count
                }
                return invocation == 1 ? .empty : nil
            },
            runtimeObservationProvider: { _ in
                AgentHibernationController.ConfirmedTeardownRuntimeObservation(
                    hasLiveSurface: true,
                    fingerprint: confirmationFingerprint
                )
            }
        )
        await teardownTask.value

        let monitorKey = AgentHibernationController.postTeardownRestoreTaskKey(
            transcriptPath: transcriptURL.path
        )
        #expect(loadCount.withLock { $0 } == 2)
        #expect(!panel.isAgentHibernated)
        #expect(controller.postTeardownRestoreTasksByTranscriptPath[monitorKey] == nil)
        #expect(FileManager.default.fileExists(atPath: retainedSnapshot.path))
        #expect(
            try String(contentsOf: retainedSnapshot, encoding: .utf8).contains("retain this turn")
        )

        if let monitor = controller.postTeardownRestoreTasksByTranscriptPath.removeValue(forKey: monitorKey) {
            monitor.cancellationState.restoresSnapshotOnCancellation = false
            monitor.task.cancel()
            await monitor.task.value
        }
    }

    nonisolated private static func indexWithLiveProcess(
        workspaceId: UUID,
        panelId: UUID,
        agent: SessionRestorableAgentSnapshot,
        processID: Int
    ) -> RestorableAgentSessionIndex {
        let key = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        let detected: RestorableAgentSessionIndex.ProcessDetectedSnapshotEntry = (
            snapshot: agent,
            updatedAt: 42,
            processIDs: [processID],
            agentProcessIDs: [processID],
            sessionIDSource: .explicit
        )
        return RestorableAgentSessionIndex.load(
            homeDirectory: "/tmp/cmux-batch-validation-missing-home",
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [key: detected],
            processArgumentsProvider: { _ in nil },
            processIdentityProvider: { _ in nil }
        )
    }

}
