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
    func unavailablePostSnapshotIndexAbortsConfirmedTeardown() async throws {
        let controller = AgentHibernationController.shared
        let wasEnabled = AgentHibernationTrackingGate.isEnabled()
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = previousAppDelegate ?? AppDelegate()
        let releaseLoad = DispatchSemaphore(value: 0)
        defer {
            releaseLoad.signal()
            if previousAppDelegate == nil, AppDelegate.shared === appDelegate {
                AppDelegate.shared = nil
            }
            AgentHibernationTrackingGate.setEnabled(wasEnabled)
            resetSharedHibernationState(controller)
        }
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)
        let panelKey = AgentHibernationPanelKey(workspaceId: workspace.id, panelId: panelId)
        let agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-timeout-before-teardown",
            workingDirectory: "/tmp/cmux-agent-hibernation-timeout",
            launchCommand: nil
        )
        workspace.setRestoredAgentSnapshotForTesting(agent, panelId: panelId)
        workspace.setAgentLifecycle(key: "codex.timeout-before-teardown", panelId: panelId, lifecycle: .idle)
        let timeoutWaiter = HibernationGenerationTimeoutWaiter()
        let loadStarted = DispatchSemaphore(value: 0)
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                loadStarted.signal()
                releaseLoad.wait()
                return (
                    index: .empty,
                    surfaceResumeBindingIndex: .empty,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: []
                )
            },
            generationTimeoutWaiter: { await timeoutWaiter.wait() },
            hookStoreDirectoryProvider: { FileManager.default.temporaryDirectory.path }
        )
        AgentHibernationTrackingGate.setEnabled(true)
        let confirmationFingerprint = "headless-runtime-fingerprint"
        let request = AgentHibernationController.ConfirmedTeardownRequest(
            record: AgentHibernationRecord(
                key: panelKey,
                workspace: workspace,
                terminalPanel: panel,
                agent: agent,
                lifecycle: .idle,
                hasUnconfirmedTerminalInput: false,
                lastActivityAt: 0,
                isProtected: false,
                hasLiveProcess: false,
                processIDs: []
            ),
            confirmationFingerprint: confirmationFingerprint,
            effectiveLastActivityAt: Date().timeIntervalSince1970 + 60,
            requestID: UUID(),
            epoch: controller.teardownValidationEpochByPanel[panelKey] ?? 0,
            generation: controller.teardownValidationGeneration
        )
        let teardownTask = controller.beginConfirmedTeardowns(
            [request],
            postSnapshotIndexLoader: {
                await sharedIndex.scopedIndexCapturedAfterRequest()
            },
            runtimeObservationProvider: { _ in
                AgentHibernationController.ConfirmedTeardownRuntimeObservation(
                    hasLiveSurface: true,
                    fingerprint: confirmationFingerprint
                )
            }
        )
        #expect(await Self.wait(for: loadStarted))
        await timeoutWaiter.waitUntilPending()
        await timeoutWaiter.fire()
        await teardownTask.value
        #expect(
            !panel.isAgentHibernated,
            "An unavailable post-snapshot process scan must fail closed instead of hibernating the pane."
        )
    }
    @MainActor
    @Test
    func pendingEvaluationDiscardsLaterTimerTicks() async throws {
        let controller = AgentHibernationController.shared
        defer { controller.cancelEvaluationTask() }
        let evaluationStarted = DispatchSemaphore(value: 0)
        let releaseEvaluation = DispatchSemaphore(value: 0)
        let evaluationCount = OSAllocatedUnfairLock(initialState: 0)
        defer { releaseEvaluation.signal() }

        #expect(controller.startEvaluationIfIdle {
            evaluationCount.withLock { $0 += 1 }
            evaluationStarted.signal()
            _ = await Self.wait(for: releaseEvaluation)
        })
        #expect(await Self.wait(for: evaluationStarted))

        #expect(!controller.startEvaluationIfIdle {
            evaluationCount.withLock { $0 += 1 }
        })
        let inFlight = try #require(controller.evaluationTask)
        releaseEvaluation.signal()
        await inFlight.value

        #expect(evaluationCount.withLock { $0 } == 1)
        #expect(controller.evaluationTask == nil)
    }

    @MainActor
    @Test
    func firstSnapshotTeardownPerformsSinglePostSnapshotLoad() async throws {
        let controller = AgentHibernationController.shared
        let wasEnabled = AgentHibernationTrackingGate.isEnabled()
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = previousAppDelegate ?? AppDelegate()
        defer {
            if previousAppDelegate == nil, AppDelegate.shared === appDelegate {
                AppDelegate.shared = nil
            }
            AgentHibernationTrackingGate.setEnabled(wasEnabled)
            resetSharedHibernationState(controller)
        }

        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-first-snapshot-teardown-\(UUID().uuidString)", isDirectory: true)
        let configRoot = testDirectory.appendingPathComponent("claude-config", isDirectory: true)
        let workingDirectory = "/tmp/cmux-first-snapshot-teardown-\(UUID().uuidString)"
        let sessionId = "first-snapshot-teardown-\(UUID().uuidString)"
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
        workspace.setAgentLifecycle(key: "claude.first-snapshot", panelId: panelId, lifecycle: .idle)
        #expect(
            AgentHibernationTranscriptGuard.resolveTranscriptPath(agent: agent, panelKey: panelKey) ==
                transcriptURL.path
        )

        AgentHibernationTrackingGate.setEnabled(true)
        let confirmationFingerprint = "headless-runtime-fingerprint"
        let request = AgentHibernationController.ConfirmedTeardownRequest(
            record: AgentHibernationRecord(
                key: panelKey,
                workspace: workspace,
                terminalPanel: panel,
                agent: agent,
                lifecycle: .idle,
                hasUnconfirmedTerminalInput: false,
                lastActivityAt: 0,
                isProtected: false,
                hasLiveProcess: false,
                processIDs: []
            ),
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
                loadCount.withLock { $0 += 1 }
                return .empty
            },
            runtimeObservationProvider: { _ in
                AgentHibernationController.ConfirmedTeardownRuntimeObservation(
                    hasLiveSurface: true,
                    fingerprint: confirmationFingerprint
                )
            }
        )
        await teardownTask.value

        #expect(loadCount.withLock { $0 } == 1)
        #expect(panel.isAgentHibernated)

        controller.cancelPostTeardownRestoreTasks()
        await controller.drainCancelledPostTeardownRestoreTasks()
    }

    @MainActor
    @Test
    func processDetectedWhileRestoreMonitorStopsAbortsConfirmedTeardown() async throws {
        let controller = AgentHibernationController.shared
        let wasEnabled = AgentHibernationTrackingGate.isEnabled()
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = previousAppDelegate ?? AppDelegate()
        defer {
            if previousAppDelegate == nil, AppDelegate.shared === appDelegate {
                AppDelegate.shared = nil
            }
            AgentHibernationTrackingGate.setEnabled(wasEnabled)
            resetSharedHibernationState(controller)
        }

        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-teardown-cancellation-barrier-\(UUID().uuidString)", isDirectory: true)
        let configRoot = testDirectory.appendingPathComponent("claude-config", isDirectory: true)
        let workingDirectory = "/tmp/cmux-teardown-cancellation-barrier-\(UUID().uuidString)"
        let sessionId = "teardown-cancellation-barrier-\(UUID().uuidString)"
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
        defer { try? FileManager.default.removeItem(at: testDirectory) }

        let workspace = Workspace()
        let workspaceId = workspace.id
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)
        let panelKey = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: panelId)
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
        workspace.setAgentLifecycle(key: "claude.cancellation-barrier", panelId: panelId, lifecycle: .idle)
        #expect(
            AgentHibernationTranscriptGuard.resolveTranscriptPath(agent: agent, panelKey: panelKey) ==
                transcriptURL.path
        )

        let scopedChild = Process()
        scopedChild.executableURL = URL(fileURLWithPath: "/bin/sleep")
        scopedChild.arguments = ["60"]
        var childEnvironment = ProcessInfo.processInfo.environment
        childEnvironment["CMUX_WORKSPACE_ID"] = workspaceId.uuidString
        childEnvironment["CMUX_SURFACE_ID"] = panelId.uuidString
        scopedChild.environment = childEnvironment
        let childExited = DispatchSemaphore(value: 0)
        scopedChild.terminationHandler = { _ in childExited.signal() }
        try scopedChild.run()
        let childProcessID = Int(scopedChild.processIdentifier)
        defer {
            if scopedChild.isRunning {
                scopedChild.terminate()
                scopedChild.waitUntilExit()
            }
        }

        let processDetectedIndex = Self.indexWithLiveProcess(
            workspaceId: workspaceId,
            panelId: panelId,
            agent: agent,
            processID: childProcessID
        )
        #expect(processDetectedIndex.hasLiveProcess(workspaceId: workspaceId, panelId: panelId))
        #expect(processDetectedIndex.processIDs(workspaceId: workspaceId, panelId: panelId) == [childProcessID])

        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let monitorReady = DispatchSemaphore(value: 0)
        let cancellationObserved = DispatchSemaphore(value: 0)
        let releaseMonitor = DispatchSemaphore(value: 0)
        let olderMonitorRequestID = UUID()
        let olderMonitorTask = Task.detached {
            await withTaskCancellationHandler {
                monitorReady.signal()
                releaseMonitor.wait()
            } onCancel: {
                cancellationObserved.signal()
            }
        }
        defer {
            releaseMonitor.signal()
            olderMonitorTask.cancel()
            controller.clearPostTeardownRestoreTask(
                transcriptPath: transcriptURL.path,
                requestID: olderMonitorRequestID
            )
        }
        #expect(await Self.wait(for: monitorReady))
        #expect(controller.storePostTeardownRestoreTask(
            olderMonitorTask,
            transcriptPath: transcriptURL.path,
            requestID: olderMonitorRequestID,
            cancellationState: AgentHibernationController.PostTeardownRestoreCancellationState()
        ))

        controller.postSnapshotValidationIndexSequence = 0
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
            processIDs: []
        )
        let request = AgentHibernationController.ConfirmedTeardownRequest(
            record: record,
            confirmationFingerprint: confirmationFingerprint,
            effectiveLastActivityAt: Date().timeIntervalSince1970 + 60,
            requestID: UUID(),
            epoch: controller.teardownValidationEpochByPanel[panelKey] ?? 0,
            generation: controller.teardownValidationGeneration
        )

        let teardownTask = controller.beginConfirmedTeardowns(
            [request],
            postSnapshotIndexLoader: {
                let invocation = loadCount.withLock { count in
                    count += 1
                    return count
                }
                return invocation == 1 ? .empty : processDetectedIndex
            },
            runtimeObservationProvider: { _ in
                AgentHibernationController.ConfirmedTeardownRuntimeObservation(
                    hasLiveSurface: true,
                    fingerprint: confirmationFingerprint
                )
            }
        )
        #expect(await Self.wait(for: cancellationObserved))
        #expect(loadCount.withLock { $0 } == 1)
        releaseMonitor.signal()
        await teardownTask.value

        #expect(loadCount.withLock { $0 } == 2)
        #expect(
            !panel.isAgentHibernated,
            "A process detected after monitor quiescence must abort destructive teardown."
        )
        #expect(
            !(await Self.wait(for: childExited, timeout: 0.25)),
            "The scoped process detected after monitor quiescence must not receive SIGTERM."
        )

        let metadataStub = #"{"type":"last-prompt","prompt":"interrupted rewrite"}"# + "\n"
        try metadataStub.write(to: transcriptURL, atomically: true, encoding: .utf8)
        #expect(
            !(await Self.waitForTranscriptRestore(
                at: transcriptURL,
                containing: "keep this turn",
                timeout: .seconds(5)
            )),
            "The re-armed monitor must wait for the newly detected process before restoring."
        )
        #expect(try String(contentsOf: transcriptURL, encoding: .utf8) == metadataStub)

        scopedChild.terminate()
        #expect(await Self.wait(for: childExited))
        #expect(
            await Self.waitForTranscriptRestore(at: transcriptURL, containing: "keep this turn"),
            "The re-armed monitor must restore the protected transcript after the process exits."
        )

        controller.cancelPostTeardownRestoreTasks()
        await controller.drainCancelledPostTeardownRestoreTasks()
    }
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated private static func waitForTranscriptRestore(
        at url: URL,
        containing expectedText: String,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if (try? String(contentsOf: url, encoding: .utf8).contains(expectedText)) == true {
                return true
            }
            try? await clock.sleep(for: .milliseconds(50))
        }
        return (try? String(contentsOf: url, encoding: .utf8).contains(expectedText)) == true
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
            homeDirectory: "/tmp/cmux-post-snapshot-missing-home",
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [key: detected],
            processArgumentsProvider: { _ in nil },
            processIdentityProvider: { _ in nil }
        )
    }
}

private actor HibernationGenerationTimeoutWaiter {
    private var pending: CheckedContinuation<Bool, Never>?
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            pending = continuation
            let waiters = readyWaiters
            readyWaiters.removeAll(keepingCapacity: false)
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilPending() async {
        guard pending == nil else { return }
        await withCheckedContinuation { continuation in
            readyWaiters.append(continuation)
        }
    }

    func fire() {
        pending?.resume(returning: true)
        pending = nil
    }
}
