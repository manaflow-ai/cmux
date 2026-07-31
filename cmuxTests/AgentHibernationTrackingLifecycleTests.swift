import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct AgentHibernationTrackingLifecycleTests {
    @Test
    func permanentPanelTeardownPrunesOnlyTheClosedPanelTracking() throws {
        let controller = AgentHibernationController.shared
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let closedKey = AgentHibernationPanelKey(workspaceId: workspace.id, panelId: panelID)
        let retainedKey = AgentHibernationPanelKey(workspaceId: workspace.id, panelId: UUID())
        defer {
            for key in [closedKey, retainedKey] {
                controller.discardTrackingStateForClosedPanel(
                    workspaceId: key.workspaceId,
                    panelId: key.panelId
                )
            }
        }

        for key in [closedKey, retainedKey] {
            controller.activityByPanel[key] = 1
            controller.terminalInputByPanel[key] = 2
            controller.lifecycleChangeByPanel[key] = 3
            controller.teardownValidationEpochByPanel[key] = 4
        }

        workspace.teardownAllPanels()

        #expect(workspace.panels[panelID] == nil)
        #expect(controller.activityByPanel[closedKey] == nil)
        #expect(controller.terminalInputByPanel[closedKey] == nil)
        #expect(controller.lifecycleChangeByPanel[closedKey] == nil)
        #expect(controller.teardownValidationEpochByPanel[closedKey] == nil)
        #expect(controller.activityByPanel[retainedKey] == 1)
        #expect(controller.terminalInputByPanel[retainedKey] == 2)
        #expect(controller.lifecycleChangeByPanel[retainedKey] == 3)
        #expect(controller.teardownValidationEpochByPanel[retainedKey] == 4)
    }

    @Test
    func detachedPanelPreservesTrackingUntilItsNewOwnerAdoptsIt() throws {
        let controller = AgentHibernationController.shared
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelID])
        let key = AgentHibernationPanelKey(workspaceId: workspace.id, panelId: panelID)
        defer {
            panel.close()
            controller.discardTrackingStateForClosedPanel(
                workspaceId: key.workspaceId,
                panelId: key.panelId
            )
        }
        controller.terminalInputByPanel[key] = 2
        controller.lifecycleChangeByPanel[key] = 1

        workspace.discardClosedPanelLifecycleState(
            panelId: panelID,
            tabId: workspace.surfaceIdFromPanelId(panelID),
            paneId: workspace.paneId(forPanelId: panelID),
            panel: panel,
            origin: "test_detach",
            closePanel: false,
            publishSurfaceClosedEvent: false,
            clearSurfaceNotifications: false,
            requestTransferredRemoteCleanup: false,
            discardAgentHibernationTracking: false
        )

        #expect(controller.terminalInputByPanel[key] == 2)
        #expect(controller.lifecycleChangeByPanel[key] == 1)
    }

    @Test
    func movedPanelTransfersUnconfirmedInputSafetyToItsNewOwner() {
        let controller = AgentHibernationController.shared
        let panelID = UUID()
        let sourceKey = AgentHibernationPanelKey(workspaceId: UUID(), panelId: panelID)
        let destinationKey = AgentHibernationPanelKey(workspaceId: UUID(), panelId: panelID)
        defer {
            for key in [sourceKey, destinationKey] {
                controller.discardTrackingStateForClosedPanel(
                    workspaceId: key.workspaceId,
                    panelId: key.panelId
                )
            }
        }
        controller.activityByPanel[sourceKey] = 1
        controller.terminalInputByPanel[sourceKey] = 3
        controller.lifecycleChangeByPanel[sourceKey] = 2
        controller.teardownValidationEpochByPanel[sourceKey] = 4

        controller.transferTrackingStateForMovedPanel(
            panelId: panelID,
            from: sourceKey.workspaceId,
            to: destinationKey.workspaceId
        )

        #expect(controller.activityByPanel[sourceKey] == nil)
        #expect(controller.terminalInputByPanel[sourceKey] == nil)
        #expect(controller.lifecycleChangeByPanel[sourceKey] == nil)
        #expect(controller.teardownValidationEpochByPanel[sourceKey] == nil)
        #expect(controller.activityByPanel[destinationKey] == 1)
        #expect(controller.terminalInputByPanel[destinationKey] == 3)
        #expect(controller.lifecycleChangeByPanel[destinationKey] == 2)
        #expect(controller.teardownValidationEpochByPanel[destinationKey] == 5)
    }

    @Test
    func dockReconcilePrunesTrackingForPermanentlyClosedPanel() throws {
        let controller = AgentHibernationController.shared
        let store = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        defer { store.closeAllPanels() }
        let paneID = try #require(store.bonsplitController.allPaneIds.first)
        let panelID = try #require(
            store.newSurface(kind: .terminal, inPane: paneID, focus: false)
        )
        let tabID = try #require(store.surfaceId(forPanelId: panelID))
        let key = AgentHibernationPanelKey(workspaceId: store.workspaceId, panelId: panelID)
        controller.activityByPanel[key] = 1
        controller.terminalInputByPanel[key] = 2
        controller.lifecycleChangeByPanel[key] = 3
        controller.teardownValidationEpochByPanel[key] = 4

        store.forceCloseDockTabIds.insert(tabID)
        defer { store.forceCloseDockTabIds.remove(tabID) }
        #expect(store.bonsplitController.closeTab(tabID))
        store.reconcilePanels()

        #expect(store.panels[panelID] == nil)
        expectTrackingWasDiscarded(for: key, controller: controller)
    }

    @Test
    func dockResetPrunesTrackingForEveryPermanentlyClosedPanel() throws {
        let controller = AgentHibernationController.shared
        let store = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        let paneID = try #require(store.bonsplitController.allPaneIds.first)
        let panelID = try #require(
            store.newSurface(kind: .terminal, inPane: paneID, focus: false)
        )
        let key = AgentHibernationPanelKey(workspaceId: store.workspaceId, panelId: panelID)
        controller.activityByPanel[key] = 1
        controller.terminalInputByPanel[key] = 2
        controller.lifecycleChangeByPanel[key] = 3
        controller.teardownValidationEpochByPanel[key] = 4

        store.removeAllPanels()

        #expect(store.panels.isEmpty)
        expectTrackingWasDiscarded(for: key, controller: controller)
    }

    @Test
    func permanentPanelCloseKeepsTranscriptExitObservationUntilExit() async {
        let controller = AgentHibernationController.shared
        let panel = TerminalPanel(workspaceId: UUID())
        let identity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 10,
            startMicroseconds: 1
        )
        let exitEvents = AsyncStream<Void>.makeStream()
        var didCompleteHibernation = false
        controller.observeCommittedTermination(
            panelID: panel.id,
            terminations: [
                .init(
                    processID: 101,
                    processIdentity: identity,
                    processGroupID: 1
                ),
            ],
            waitForExit: { _ in
                for await _ in exitEvents.stream {}
                return true
            },
            onExit: {
                didCompleteHibernation = true
                return true
            },
            onRecovery: {}
        )
        let observationTask = controller
            .committedTerminationObservationsByPanelID[panel.id]?
            .task

        panel.close()
        exitEvents.continuation.finish()
        await observationTask?.value

        #expect(controller.committedTerminationObservationsByPanelID[panel.id] == nil)
        #expect(didCompleteHibernation)
    }

    @Test
    func permanentPanelCloseBoundsTranscriptExitObservation() async {
        let controller = AgentHibernationController.shared
        let panel = TerminalPanel(workspaceId: UUID())
        let identity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 10,
            startMicroseconds: 1
        )
        let exitEvents = AsyncStream<Void>.makeStream()
        let processExitCompletion = AgentHibernationProcessExitCompletion()
        var didCompleteHibernation = false
        controller.observeCommittedTermination(
            panelID: panel.id,
            terminations: [
                .init(
                    processID: 101,
                    processIdentity: identity,
                    processGroupID: 1
                ),
            ],
            processExitCompletion: processExitCompletion,
            waitForExit: { _ in
                for await _ in exitEvents.stream {}
                return true
            },
            onExit: {
                didCompleteHibernation = true
                return true
            },
            onRecovery: {}
        )

        panel.close()
        controller.limitCommittedTerminationObservationAfterPanelClose(
            panelID: panel.id,
            cleanupDelay: .zero,
            sleepUntilDeadline: { _ in true }
        )
        let didExit = await processExitCompletion.wait()

        #expect(!didExit)
        #expect(controller.committedTerminationObservationsByPanelID[panel.id] == nil)
        #expect(!didCompleteHibernation)
        exitEvents.continuation.finish()
    }

    @Test
    func panelCloseCleanupFollowsObservationIntoRecovery() async throws {
        let controller = AgentHibernationController.shared
        let panelID = UUID()
        let identity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 10,
            startMicroseconds: 1
        )
        let initialWaitStarted = AsyncStream<Void>.makeStream()
        let allowInitialFailure = AsyncStream<Void>.makeStream()
        let nativeReadiness = AsyncStream<Void>.makeStream()
        let allowCleanup = AsyncStream<Void>.makeStream()
        let processExitCompletion = AgentHibernationProcessExitCompletion()
        controller.observeCommittedTermination(
            panelID: panelID,
            terminations: [
                .init(
                    processID: 101,
                    processIdentity: identity,
                    processGroupID: 1
                ),
            ],
            processExitCompletion: processExitCompletion,
            waitForExit: { _ in
                initialWaitStarted.continuation.yield()
                for await _ in allowInitialFailure.stream { return false }
                return false
            },
            waitForRecoveryReadiness: {
                for await _ in nativeReadiness.stream { return true }
                return false
            },
            onExit: { true },
            onRecovery: {}
        )
        let initialObservation = try #require(
            controller.committedTerminationObservationsByPanelID[panelID]
        )
        let initialObservationTask = try #require(initialObservation.task)
        var initialWaitIterator = initialWaitStarted.stream.makeAsyncIterator()
        _ = await initialWaitIterator.next()

        controller.limitCommittedTerminationObservationAfterPanelClose(
            panelID: panelID,
            cleanupDelay: .zero,
            sleepUntilDeadline: { _ in
                for await _ in allowCleanup.stream { return true }
                return false
            }
        )
        let cleanupTask = try #require(
            controller.committedTerminationCleanupByPanelID[panelID]?.task
        )
        allowInitialFailure.continuation.yield()
        allowInitialFailure.continuation.finish()
        await initialObservationTask.value

        let recoveryObservation = try #require(
            controller.committedTerminationObservationsByPanelID[panelID]
        )
        #expect(recoveryObservation.requestID == initialObservation.requestID)

        allowCleanup.continuation.yield()
        allowCleanup.continuation.finish()
        await cleanupTask.value

        #expect(controller.committedTerminationObservationsByPanelID[panelID] == nil)
        #expect(await processExitCompletion.wait() == false)
        initialWaitStarted.continuation.finish()
        nativeReadiness.continuation.finish()
    }

    @Test
    func panelCloseCleanupOwnsCommitBeforeNativeRecoveryCanSuspend() async throws {
        let controller = AgentHibernationController.shared
        let workspaceID = UUID()
        let panelID = UUID()
        let requestID = UUID()
        let processExitCompletion = AgentHibernationProcessExitCompletion()
        let allowCleanup = AsyncStream<Void>.makeStream()
        let allowLateRecovery = AsyncStream<Void>.makeStream()
        var didRecover = false

        controller.registerCommittedTerminationObservation(
            panelID: panelID,
            requestID: requestID,
            processExitCompletion: processExitCompletion
        )
        #expect(
            controller.committedTerminationObservationsByPanelID[panelID]?
                .requestID == requestID
        )

        controller.discardTrackingStateForClosedPanel(
            workspaceId: workspaceID,
            panelId: panelID
        )
        #expect(controller.committedTerminationCleanupByPanelID[panelID] != nil)
        controller.limitCommittedTerminationObservationAfterPanelClose(
            panelID: panelID,
            cleanupDelay: .zero,
            sleepUntilDeadline: { _ in
                for await _ in allowCleanup.stream { return true }
                return false
            }
        )
        let cleanupTask = try #require(
            controller.committedTerminationCleanupByPanelID[panelID]?.task
        )

        let lateRecoveryTask = Task { @MainActor in
            for await _ in allowLateRecovery.stream {
                controller.observeCommittedTerminationRecovery(
                    panelID: panelID,
                    requestID: requestID,
                    terminations: [],
                    processExitCompletion: processExitCompletion,
                    onRecovery: {
                        didRecover = true
                    }
                )
                return
            }
        }

        allowCleanup.continuation.yield()
        allowCleanup.continuation.finish()
        await cleanupTask.value

        #expect(controller.committedTerminationObservationsByPanelID[panelID] == nil)
        #expect(await processExitCompletion.wait() == false)

        allowLateRecovery.continuation.yield()
        allowLateRecovery.continuation.finish()
        await lateRecoveryTask.value

        #expect(controller.committedTerminationObservationsByPanelID[panelID] == nil)
        #expect(!didRecover)
    }

    private func expectTrackingWasDiscarded(
        for key: AgentHibernationPanelKey,
        controller: AgentHibernationController
    ) {
        #expect(controller.activityByPanel[key] == nil)
        #expect(controller.terminalInputByPanel[key] == nil)
        #expect(controller.lifecycleChangeByPanel[key] == nil)
        #expect(controller.teardownValidationEpochByPanel[key] == nil)
    }
}
