import CMUXAgentLaunch
import Combine
import CmuxSidebar
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private final class PiFeedDockPanel: Panel, ObservableObject {
    let id: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .terminal
    let displayTitle = "Pi Feed Dock Test"
    let displayIcon: String? = "terminal.fill"
    var isDirty = false

    init(id: UUID = UUID()) {
        self.id = id
    }

    func close() {}
    func focus() {}
    func unfocus() {}
    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }
}

@MainActor
private final class PiFeedDockAttentionRecorder {
    var acceptedEvent: WorkstreamEvent?
    var targetWasNeedsInput = false
    var focusedWasNeedsInput = false
    var targetStatusValue: String?
    var moveSucceeded = false
    var transferredWasNeedsInput = false
    var transferredStatusValue: String?
}

@MainActor
private extension DockSplitStore {
    @discardableResult
    func seedPiFeedPanel(id: UUID = UUID()) throws -> PiFeedDockPanel {
        let panel = PiFeedDockPanel(id: id)
        let pane = try #require(bonsplitController.allPaneIds.first)
        panels[panel.id] = panel
        let tabID = try #require(
            bonsplitController.createTab(
                title: panel.displayTitle,
                icon: panel.displayIcon,
                kind: panel.panelType.rawValue,
                isDirty: panel.isDirty,
                inPane: pane
            )
        )
        bindSurface(tabID, toPanelId: panel.id)
        return panel
    }
}

@MainActor
private extension Workspace {
    @discardableResult
    func seedPiFeedPanel(id: UUID = UUID()) throws -> PiFeedDockPanel {
        let panel = PiFeedDockPanel(id: id)
        let pane = try #require(bonsplitController.allPaneIds.first)
        panels[panel.id] = panel
        let tabID = try #require(
            bonsplitController.createTab(
                title: panel.displayTitle,
                icon: panel.displayIcon,
                kind: panel.panelType.rawValue,
                isDirty: panel.isDirty,
                inPane: pane
            )
        )
        bindSurface(tabID, toPanelId: panel.id)
        return panel
    }
}

@Suite("Pi Feed Dock ownership", .serialized)
struct PiFeedDockOwnershipTests {
    private static var attentionStatusKey: String {
        FeedCoordinator.attentionStatusKey(forSource: "pi")
    }

    @MainActor
    @Test("Acknowledged Feed prefers its live claimed workspace over a stale Dock copy")
    func acknowledgedFeedPrefersLiveClaimedWorkspaceOverStaleDockCopy() async throws {
        try await withAppContext { appDelegate, _, workspace, windowID in
            let panel = try workspace.seedPiFeedPanel()
            let dock = appDelegate.windowDock(forWindowId: windowID)
            _ = try dock.seedPiFeedPanel(id: panel.id)
            var insertedEvent: WorkstreamEvent?
            let store = WorkstreamStore(ringCapacity: 10) {
                insertedEvent = $0
                return nil
            }
            FeedCoordinator.shared.install(store: store)
            let event = WorkstreamEvent(
                sessionId: "pi-live-workspace-feed",
                hookEventName: .postToolUse,
                source: "pi",
                workspaceId: workspace.id.uuidString,
                surfaceId: panel.id.uuidString,
                requestId: "pi-live-workspace-feed-request"
            )

            let result = await Self.ingestAcknowledgedOffMainActor([event])
            let payload = try Self.acknowledgmentPayload(result)

            #expect(payload["workspace_id"] as? String == workspace.id.uuidString)
            #expect(payload["surface_id"] as? String == panel.id.uuidString)
            #expect(insertedEvent?.workspaceId == workspace.id.uuidString)
            #expect(insertedEvent?.surfaceId == panel.id.uuidString)
            #expect(store.items.count == 1)
        }
    }

    @MainActor
    @Test("Blocking Feed conclusion prefers its live workspace over a stale Dock copy")
    func blockingFeedConclusionPrefersLiveWorkspaceOverStaleDockCopy() async throws {
        try await withAppContext { appDelegate, manager, workspace, windowID in
            let panel = try workspace.seedPiFeedPanel()
            let staleDock = appDelegate.windowDock(forWindowId: windowID)
            _ = try staleDock.seedPiFeedPanel(id: panel.id)
            let target = try #require(
                FeedCoordinator.shared.surfaceBlockingDecisionAttention(
                    event: WorkstreamEvent(
                        sessionId: "pi-live-workspace-blocking-feed",
                        hookEventName: .permissionRequest,
                        source: "pi",
                        workspaceId: workspace.id.uuidString,
                        surfaceId: panel.id.uuidString,
                        requestId: "pi-live-workspace-blocking-request"
                    ),
                    resolved: (workspace.id, panel.id),
                    tabManager: manager
                )
            )

            #expect(
                workspace.agentLifecycleStatesByPanelId[panel.id]?[Self.attentionStatusKey]
                    == .needsInput
            )
            #expect(
                workspace.statusEntries[Self.attentionStatusKey]?.value
                    == FeedCoordinator.needsInputStatusValue
            )

            FeedCoordinator.shared.concludeBlockingDecisionAttention(target)

            #expect(
                workspace.agentLifecycleStatesByPanelId[panel.id]?[Self.attentionStatusKey] == nil
            )
            #expect(workspace.statusEntries[Self.attentionStatusKey] == nil)
            #expect(staleDock.agentRuntimeByPanelId[panel.id] == nil)
        }
    }

    @MainActor
    @Test("Muted workspaces do not surface or reorder blocking Feed attention")
    func mutedWorkspaceSuppressesBlockingFeedAttention() async throws {
        try await withAppContext { _, manager, workspace, _ in
            let panel = try workspace.seedPiFeedPanel()
            workspace.isMuted = true
            let originalOrder = manager.tabs.map(\.id)

            let target = FeedCoordinator.shared.surfaceBlockingDecisionAttention(
                event: WorkstreamEvent(
                    sessionId: "pi-muted-blocking-feed",
                    hookEventName: .permissionRequest,
                    source: "pi",
                    workspaceId: workspace.id.uuidString,
                    surfaceId: panel.id.uuidString,
                    requestId: "pi-muted-blocking-request"
                ),
                resolved: (workspace.id, panel.id),
                tabManager: manager
            )

            #expect(target == nil)
            #expect(manager.tabs.map(\.id) == originalOrder)
            #expect(workspace.agentLifecycleStatesByPanelId[panel.id] == nil)
            #expect(workspace.statusEntries[Self.attentionStatusKey] == nil)
        }
    }

    @MainActor
    @Test("Blocking Feed leaves the agent lifecycle state untouched")
    func blockingFeedLeavesAgentLifecycleStateUntouched() async throws {
        try await withAppContext { _, manager, workspace, _ in
            let panel = try workspace.seedPiFeedPanel()
            workspace.setAgentLifecycle(key: "pi", panelId: panel.id, lifecycle: .idle)
            let target = try #require(
                FeedCoordinator.shared.surfaceBlockingDecisionAttention(
                    event: WorkstreamEvent(
                        sessionId: "pi-restore-previous-lifecycle-feed",
                        hookEventName: .permissionRequest,
                        source: "pi",
                        workspaceId: workspace.id.uuidString,
                        surfaceId: panel.id.uuidString,
                        requestId: "pi-restore-previous-lifecycle-request"
                    ),
                    resolved: (workspace.id, panel.id),
                    tabManager: manager
                )
            )

            #expect(
                workspace.agentLifecycleStatesByPanelId[panel.id]?["pi"] == .idle
            )
            #expect(
                workspace.agentLifecycleStatesByPanelId[panel.id]?[Self.attentionStatusKey]
                    == .needsInput
            )

            FeedCoordinator.shared.concludeBlockingDecisionAttention(target)

            #expect(
                workspace.agentLifecycleStatesByPanelId[panel.id]?["pi"] == .idle
            )
            #expect(
                workspace.agentLifecycleStatesByPanelId[panel.id]?[Self.attentionStatusKey] == nil
            )
            #expect(workspace.statusEntries[Self.attentionStatusKey] == nil)
        }
    }

    @MainActor
    @Test("Overlapping Feed attention preserves a newer agent lifecycle update")
    func overlappingFeedAttentionPreservesNewerAgentLifecycleUpdate() async throws {
        try await withAppContext { _, manager, workspace, _ in
            let panel = try workspace.seedPiFeedPanel()
            let idleStatus = SidebarStatusEntry(
                key: "pi",
                value: "Idle",
                timestamp: Date(timeIntervalSince1970: 1)
            )
            workspace.setAgentLifecycle(key: "pi", panelId: panel.id, lifecycle: .idle)
            workspace.statusEntries["pi"] = idleStatus
            let firstTarget = try #require(
                FeedCoordinator.shared.surfaceBlockingDecisionAttention(
                    event: WorkstreamEvent(
                        sessionId: "pi-overlap-agent-update-first-feed",
                        hookEventName: .permissionRequest,
                        source: "pi",
                        workspaceId: workspace.id.uuidString,
                        surfaceId: panel.id.uuidString,
                        requestId: "pi-overlap-agent-update-first-request"
                    ),
                    resolved: (workspace.id, panel.id),
                    tabManager: manager
                )
            )

            let runningStatus = SidebarStatusEntry(
                key: "pi",
                value: "Running",
                timestamp: Date(timeIntervalSince1970: 2)
            )
            workspace.setAgentLifecycle(key: "pi", panelId: panel.id, lifecycle: .running)
            workspace.statusEntries["pi"] = runningStatus
            let secondTarget = try #require(
                FeedCoordinator.shared.surfaceBlockingDecisionAttention(
                    event: WorkstreamEvent(
                        sessionId: "pi-overlap-agent-update-second-feed",
                        hookEventName: .permissionRequest,
                        source: "pi",
                        workspaceId: workspace.id.uuidString,
                        surfaceId: panel.id.uuidString,
                        requestId: "pi-overlap-agent-update-second-request"
                    ),
                    resolved: (workspace.id, panel.id),
                    tabManager: manager
                )
            )

            FeedCoordinator.shared.concludeBlockingDecisionAttention(firstTarget)

            #expect(
                workspace.agentLifecycleStatesByPanelId[panel.id]?["pi"] == .running
            )
            #expect(workspace.statusEntries["pi"] == runningStatus)
            #expect(
                workspace.agentLifecycleStatesByPanelId[panel.id]?[Self.attentionStatusKey]
                    == .needsInput
            )
            #expect(
                workspace.statusEntries[Self.attentionStatusKey]?.value
                    == FeedCoordinator.needsInputStatusValue
            )

            FeedCoordinator.shared.concludeBlockingDecisionAttention(secondTarget)

            #expect(
                workspace.agentLifecycleStatesByPanelId[panel.id]?["pi"] == .running
            )
            #expect(workspace.statusEntries["pi"] == runningStatus)
            #expect(
                workspace.agentLifecycleStatesByPanelId[panel.id]?[Self.attentionStatusKey] == nil
            )
            #expect(workspace.statusEntries[Self.attentionStatusKey] == nil)
        }
    }

    @MainActor
    @Test("Feed attention preserves a preexisting Needs input lifecycle and status")
    func feedAttentionPreservesPreexistingNeedsInputLifecycleAndStatus() async throws {
        try await withAppContext { _, manager, workspace, _ in
            let panel = try workspace.seedPiFeedPanel()
            let agentStatus = SidebarStatusEntry(
                key: "pi",
                value: "Agent needs input",
                timestamp: Date(timeIntervalSince1970: 1)
            )
            workspace.setAgentLifecycle(key: "pi", panelId: panel.id, lifecycle: .needsInput)
            workspace.statusEntries["pi"] = agentStatus
            let target = try #require(
                FeedCoordinator.shared.surfaceBlockingDecisionAttention(
                    event: WorkstreamEvent(
                        sessionId: "pi-preexisting-needs-input-feed",
                        hookEventName: .permissionRequest,
                        source: "pi",
                        workspaceId: workspace.id.uuidString,
                        surfaceId: panel.id.uuidString,
                        requestId: "pi-preexisting-needs-input-request"
                    ),
                    resolved: (workspace.id, panel.id),
                    tabManager: manager
                )
            )

            #expect(
                workspace.agentLifecycleStatesByPanelId[panel.id]?["pi"] == .needsInput
            )
            #expect(workspace.statusEntries["pi"] == agentStatus)
            #expect(
                workspace.agentLifecycleStatesByPanelId[panel.id]?[Self.attentionStatusKey]
                    == .needsInput
            )
            #expect(
                workspace.statusEntries[Self.attentionStatusKey]?.value
                    == FeedCoordinator.needsInputStatusValue
            )

            FeedCoordinator.shared.concludeBlockingDecisionAttention(target)

            #expect(
                workspace.agentLifecycleStatesByPanelId[panel.id]?["pi"] == .needsInput
            )
            #expect(workspace.statusEntries["pi"] == agentStatus)
            #expect(
                workspace.agentLifecycleStatesByPanelId[panel.id]?[Self.attentionStatusKey] == nil
            )
            #expect(workspace.statusEntries[Self.attentionStatusKey] == nil)
        }
    }

    @MainActor
    @Test("Resolved Feed cannot transfer another panel's Needs input status")
    func resolvedFeedCannotTransferAnotherPanelsNeedsInputStatus() async throws {
        try await withAppContext { appDelegate, manager, workspace, windowID in
            let resolvedPanel = try workspace.seedPiFeedPanel()
            let pendingPanel = try workspace.seedPiFeedPanel()
            let resolvedTarget = try #require(
                FeedCoordinator.shared.surfaceBlockingDecisionAttention(
                    event: WorkstreamEvent(
                        sessionId: "pi-resolved-panel-feed",
                        hookEventName: .permissionRequest,
                        source: "pi",
                        workspaceId: workspace.id.uuidString,
                        surfaceId: resolvedPanel.id.uuidString,
                        requestId: "pi-resolved-panel-request"
                    ),
                    resolved: (workspace.id, resolvedPanel.id),
                    tabManager: manager
                )
            )
            FeedCoordinator.shared.concludeBlockingDecisionAttention(resolvedTarget)

            let pendingTarget = try #require(
                FeedCoordinator.shared.surfaceBlockingDecisionAttention(
                    event: WorkstreamEvent(
                        sessionId: "pi-pending-panel-feed",
                        hookEventName: .permissionRequest,
                        source: "pi",
                        workspaceId: workspace.id.uuidString,
                        surfaceId: pendingPanel.id.uuidString,
                        requestId: "pi-pending-panel-request"
                    ),
                    resolved: (workspace.id, pendingPanel.id),
                    tabManager: manager
                )
            )
            defer { FeedCoordinator.shared.concludeBlockingDecisionAttention(pendingTarget) }

            let resolvedTabID = try #require(workspace.surfaceIdFromPanelId(resolvedPanel.id))
            let dock = appDelegate.windowDock(forWindowId: windowID)
            let dockPane = try #require(dock.bonsplitController.allPaneIds.first)
            #expect(appDelegate.moveSurfaceIntoDock(
                sourceTabId: resolvedTabID.uuid,
                destinationDock: dock,
                destination: .insert(targetPane: dockPane, targetIndex: nil)
            ))

            #expect(dock.agentRuntimeByPanelId[resolvedPanel.id] == nil)
            #expect(
                workspace.agentLifecycleStatesByPanelId[pendingPanel.id]?[Self.attentionStatusKey]
                    == .needsInput
            )
            #expect(
                workspace.statusEntries[Self.attentionStatusKey]?.value
                    == FeedCoordinator.needsInputStatusValue
            )
        }
    }

    @MainActor
    @Test("Acknowledged Feed follows a surface into its window Dock")
    func acknowledgedFeedRehomesStaleWorkspaceClaimToWindowDockOwner() async throws {
        try await withAppContext { appDelegate, manager, workspace, windowID in
            let dock = appDelegate.windowDock(forWindowId: windowID)
            let panel = try dock.seedPiFeedPanel()
            var insertedEvent: WorkstreamEvent?
            let store = WorkstreamStore(ringCapacity: 10) {
                insertedEvent = $0
                return nil
            }
            FeedCoordinator.shared.install(store: store)
            let event = WorkstreamEvent(
                sessionId: "pi-window-dock-feed",
                hookEventName: .postToolUse,
                source: "pi",
                workspaceId: workspace.id.uuidString,
                surfaceId: panel.id.uuidString,
                requestId: "pi-window-dock-feed-request"
            )

            let result = await Self.ingestAcknowledgedOffMainActor([event])
            let payload = try Self.acknowledgmentPayload(result)

            #expect(payload["workspace_id"] as? String == windowID.uuidString)
            #expect(payload["surface_id"] as? String == panel.id.uuidString)
            #expect(insertedEvent?.workspaceId == windowID.uuidString)
            #expect(insertedEvent?.surfaceId == panel.id.uuidString)
            #expect(store.items.count == 1)
            #expect(appDelegate.tabManagerFor(windowId: windowID) === manager)
        }
    }

    @MainActor
    @Test("Blocking Feed preserves exact window Dock attention ownership")
    func blockingFeedPreservesExactWindowDockAttentionOwnership() async throws {
        try await withAppContext { appDelegate, _, workspace, windowID in
            let dock = appDelegate.windowDock(forWindowId: windowID)
            let focusedPanel = try dock.seedPiFeedPanel()
            let targetPanel = try dock.seedPiFeedPanel()
            dock.focusPanel(focusedPanel.id)
            let recorder = PiFeedDockAttentionRecorder()
            let requestID = "pi-window-dock-blocking-request"
            FeedCoordinator.shared.install(store: WorkstreamStore(ringCapacity: 10))
            let event = WorkstreamEvent(
                sessionId: "pi-window-dock-blocking-feed",
                hookEventName: .permissionRequest,
                source: "pi",
                workspaceId: workspace.id.uuidString,
                surfaceId: targetPanel.id.uuidString,
                toolName: "Bash",
                requestId: requestID
            )

            let result = await Task.detached {
                FeedCoordinator.shared.ingestBlocking(
                    event: event,
                    waitTimeout: 1,
                    onAcceptedOnMainActor: { acceptedEvent in
                        recorder.acceptedEvent = acceptedEvent
                        recorder.targetWasNeedsInput = dock.agentRuntimeByPanelId[targetPanel.id]?
                            .agentLifecycleStates[Self.attentionStatusKey] == .needsInput
                        recorder.focusedWasNeedsInput = dock.agentRuntimeByPanelId[focusedPanel.id]?
                            .agentLifecycleStates[Self.attentionStatusKey] == .needsInput
                        recorder.targetStatusValue = dock.agentRuntimeStatusEntry(
                            key: Self.attentionStatusKey,
                            panelId: targetPanel.id
                        )?.value
                        FeedCoordinator.shared.deliverReply(
                            requestId: requestID,
                            decision: .permission(.once)
                        )
                    }
                )
            }.value

            guard case .resolved(_, .permission(.once)) = result else {
                Issue.record("expected the window Dock blocking Feed event to resolve")
                return
            }
            #expect(recorder.acceptedEvent?.workspaceId == windowID.uuidString)
            #expect(recorder.acceptedEvent?.surfaceId == targetPanel.id.uuidString)
            #expect(recorder.targetWasNeedsInput)
            #expect(!recorder.focusedWasNeedsInput)
            #expect(recorder.targetStatusValue == FeedCoordinator.needsInputStatusValue)
        }
    }

    @MainActor
    @Test("Blocking Feed publishes window Dock attention to the rendered projection")
    func blockingFeedPublishesWindowDockAttentionToRenderedProjection() async throws {
        try await withAppContext { appDelegate, manager, _, windowID in
            let dock = appDelegate.windowDock(forWindowId: windowID)
            let targetPanel = try dock.seedPiFeedPanel()
            let projection = DockUnreadPanelProjection(
                source: TerminalNotificationStore.shared.sidebarUnread,
                workspaceID: windowID,
                panelIDs: [targetPanel.id],
                isActive: true,
                agentAttentionSource: dock.agentNeedsInputAttention
            )
            let target = try #require(
                FeedCoordinator.shared.surfaceBlockingDecisionAttention(
                    event: WorkstreamEvent(
                        sessionId: "pi-window-dock-rendered-attention-feed",
                        hookEventName: .permissionRequest,
                        source: "pi",
                        workspaceId: windowID.uuidString,
                        surfaceId: targetPanel.id.uuidString,
                        requestId: "pi-window-dock-rendered-attention-request"
                    ),
                    resolved: (windowID, targetPanel.id),
                    tabManager: manager
                )
            )

            #expect(projection.unreadPanelIDs == [targetPanel.id])

            FeedCoordinator.shared.concludeBlockingDecisionAttention(target)

            #expect(projection.unreadPanelIDs.isEmpty)
        }
    }

    @MainActor
    @Test("Blocking Feed attention follows a panel moved from window Dock to workspace")
    func blockingFeedAttentionFollowsPanelMovedFromWindowDockToWorkspace() async throws {
        try await withAppContext { appDelegate, _, workspace, windowID in
            let dock = appDelegate.windowDock(forWindowId: windowID)
            let targetPanel = try dock.seedPiFeedPanel()
            let recorder = PiFeedDockAttentionRecorder()
            let requestID = "pi-window-dock-transfer-blocking-request"
            FeedCoordinator.shared.install(store: WorkstreamStore(ringCapacity: 10))
            let event = WorkstreamEvent(
                sessionId: "pi-window-dock-transfer-blocking-feed",
                hookEventName: .permissionRequest,
                source: "pi",
                workspaceId: windowID.uuidString,
                surfaceId: targetPanel.id.uuidString,
                toolName: "Bash",
                requestId: requestID
            )

            let result = await Task.detached {
                FeedCoordinator.shared.ingestBlocking(
                    event: event,
                    waitTimeout: 1,
                    onAcceptedOnMainActor: { _ in
                        recorder.moveSucceeded = appDelegate.moveDockSurfaceToWorkspace(
                            sourceDock: dock,
                            panelId: targetPanel.id,
                            toWorkspace: workspace.id,
                            targetPane: nil,
                            targetIndex: nil,
                            splitTarget: nil,
                            focus: false,
                            focusWindow: false
                        )
                        recorder.transferredWasNeedsInput = workspace
                            .agentLifecycleStatesByPanelId[targetPanel.id]?[Self.attentionStatusKey]
                            == .needsInput
                        recorder.transferredStatusValue = workspace
                            .statusEntries[Self.attentionStatusKey]?.value
                        FeedCoordinator.shared.deliverReply(
                            requestId: requestID,
                            decision: .permission(.once)
                        )
                    }
                )
            }.value

            guard case .resolved(_, .permission(.once)) = result else {
                Issue.record("expected the transferred blocking Feed event to resolve")
                return
            }
            #expect(recorder.moveSucceeded)
            #expect(recorder.transferredWasNeedsInput)
            #expect(recorder.transferredStatusValue == FeedCoordinator.needsInputStatusValue)
            #expect(
                workspace.agentLifecycleStatesByPanelId[targetPanel.id]?[Self.attentionStatusKey]
                    == nil
            )
            #expect(workspace.statusEntries[Self.attentionStatusKey] == nil)
        }
    }

    @MainActor
    @Test("Blocking Feed attention follows a panel moved from workspace to window Dock")
    func blockingFeedAttentionFollowsPanelMovedFromWorkspaceToWindowDock() async throws {
        try await withAppContext { appDelegate, manager, workspace, windowID in
            let targetPanel = try workspace.seedPiFeedPanel()
            let sourceTabID = try #require(workspace.surfaceIdFromPanelId(targetPanel.id))
            let dock = appDelegate.windowDock(forWindowId: windowID)
            let dockPane = try #require(dock.bonsplitController.allPaneIds.first)
            let target = try #require(
                FeedCoordinator.shared.surfaceBlockingDecisionAttention(
                    event: WorkstreamEvent(
                        sessionId: "pi-workspace-transfer-blocking-feed",
                        hookEventName: .permissionRequest,
                        source: "pi",
                        workspaceId: workspace.id.uuidString,
                        surfaceId: targetPanel.id.uuidString,
                        toolName: "Bash",
                        requestId: "pi-workspace-transfer-blocking-request"
                    ),
                    resolved: (workspace.id, targetPanel.id),
                    tabManager: manager
                )
            )

            #expect(appDelegate.moveSurfaceIntoDock(
                sourceTabId: sourceTabID.uuid,
                destinationDock: dock,
                destination: .insert(targetPane: dockPane, targetIndex: nil)
            ))
            #expect(
                dock.agentRuntimeByPanelId[targetPanel.id]?
                    .agentLifecycleStates[Self.attentionStatusKey]
                    == .needsInput
            )
            #expect(
                dock.agentRuntimeStatusEntry(
                    key: Self.attentionStatusKey,
                    panelId: targetPanel.id
                )?.value
                    == FeedCoordinator.needsInputStatusValue
            )
            #expect(workspace.statusEntries[Self.attentionStatusKey] == nil)

            FeedCoordinator.shared.concludeBlockingDecisionAttention(target)

            #expect(
                dock.agentRuntimeByPanelId[targetPanel.id]?
                    .agentLifecycleStates[Self.attentionStatusKey] == nil
            )
            #expect(
                dock.agentRuntimeStatusEntry(
                    key: Self.attentionStatusKey,
                    panelId: targetPanel.id
                ) == nil
            )
            #expect(workspace.statusEntries[Self.attentionStatusKey] == nil)
        }
    }

    @MainActor
    @Test("Overlapping Feed attention stays lit across a panel owner transfer")
    func overlappingFeedAttentionStaysLitAcrossPanelOwnerTransfer() async throws {
        try await withAppContext { appDelegate, manager, workspace, windowID in
            let dock = appDelegate.windowDock(forWindowId: windowID)
            let targetPanel = try dock.seedPiFeedPanel()
            let beforeMoveEvent = WorkstreamEvent(
                sessionId: "pi-window-dock-overlap-before-move",
                hookEventName: .permissionRequest,
                source: "pi",
                workspaceId: windowID.uuidString,
                surfaceId: targetPanel.id.uuidString,
                toolName: "Bash",
                requestId: "pi-window-dock-overlap-before-move-request"
            )
            let firstTarget = try #require(
                FeedCoordinator.shared.surfaceBlockingDecisionAttention(
                    event: beforeMoveEvent,
                    resolved: (windowID, targetPanel.id),
                    tabManager: manager
                )
            )
            #expect(appDelegate.moveDockSurfaceToWorkspace(
                sourceDock: dock,
                panelId: targetPanel.id,
                toWorkspace: workspace.id,
                targetPane: nil,
                targetIndex: nil,
                splitTarget: nil,
                focus: false,
                focusWindow: false
            ))

            let afterMoveEvent = WorkstreamEvent(
                sessionId: "pi-window-dock-overlap-after-move",
                hookEventName: .permissionRequest,
                source: "pi",
                workspaceId: workspace.id.uuidString,
                surfaceId: targetPanel.id.uuidString,
                toolName: "Bash",
                requestId: "pi-window-dock-overlap-after-move-request"
            )
            let secondTarget = try #require(
                FeedCoordinator.shared.surfaceBlockingDecisionAttention(
                    event: afterMoveEvent,
                    resolved: (workspace.id, targetPanel.id),
                    tabManager: manager
                )
            )

            FeedCoordinator.shared.concludeBlockingDecisionAttention(firstTarget)

            #expect(
                workspace.agentLifecycleStatesByPanelId[targetPanel.id]?[Self.attentionStatusKey]
                    == .needsInput
            )
            #expect(
                workspace.statusEntries[Self.attentionStatusKey]?.value
                    == FeedCoordinator.needsInputStatusValue
            )

            FeedCoordinator.shared.concludeBlockingDecisionAttention(secondTarget)

            #expect(
                workspace.agentLifecycleStatesByPanelId[targetPanel.id]?[Self.attentionStatusKey]
                    == nil
            )
            #expect(workspace.statusEntries[Self.attentionStatusKey] == nil)
        }
    }

    @MainActor
    @Test("Surface-less blocking Feed marks the focused window Dock panel as needing input")
    func surfaceLessBlockingFeedMarksFocusedWindowDockPanelAsNeedingInput() async throws {
        try await withAppContext { appDelegate, _, _, windowID in
            let dock = appDelegate.windowDock(forWindowId: windowID)
            let focusedPanel = try dock.seedPiFeedPanel()
            dock.focusPanel(focusedPanel.id)
            let recorder = PiFeedDockAttentionRecorder()
            let requestID = "pi-window-dock-surface-less-blocking-request"
            FeedCoordinator.shared.install(store: WorkstreamStore(ringCapacity: 10))
            let event = WorkstreamEvent(
                sessionId: "pi-window-dock-surface-less-blocking-feed",
                hookEventName: .permissionRequest,
                source: "pi",
                workspaceId: windowID.uuidString,
                toolName: "Bash",
                requestId: requestID
            )

            let result = await Task.detached {
                FeedCoordinator.shared.ingestBlocking(
                    event: event,
                    waitTimeout: 1,
                    onAcceptedOnMainActor: { acceptedEvent in
                        recorder.acceptedEvent = acceptedEvent
                        recorder.focusedWasNeedsInput = dock.agentRuntimeByPanelId[focusedPanel.id]?
                            .agentLifecycleStates[Self.attentionStatusKey] == .needsInput
                        recorder.targetStatusValue = dock.agentRuntimeStatusEntry(
                            key: Self.attentionStatusKey,
                            panelId: focusedPanel.id
                        )?.value
                        FeedCoordinator.shared.deliverReply(
                            requestId: requestID,
                            decision: .permission(.once)
                        )
                    }
                )
            }.value

            guard case .resolved(_, .permission(.once)) = result else {
                Issue.record("expected the surface-less window Dock blocking Feed event to resolve")
                return
            }
            #expect(recorder.acceptedEvent?.workspaceId == windowID.uuidString)
            #expect(recorder.acceptedEvent?.surfaceId == nil)
            #expect(recorder.focusedWasNeedsInput)
            #expect(recorder.targetStatusValue == FeedCoordinator.needsInputStatusValue)
        }
    }

    @MainActor
    @Test("Acknowledged Feed follows a surface into its workspace Dock")
    func acknowledgedFeedRehomesStaleWorkspaceClaimToWorkspaceDockOwner() async throws {
        try await withAppContext { _, manager, workspace, _ in
            let staleWorkspace = manager.addWorkspace(select: false)
            let panel = try workspace.requiredDockSplitForTesting.seedPiFeedPanel()
            var insertedEvent: WorkstreamEvent?
            let store = WorkstreamStore(ringCapacity: 10) {
                insertedEvent = $0
                return nil
            }
            FeedCoordinator.shared.install(store: store)
            let event = WorkstreamEvent(
                sessionId: "pi-workspace-dock-feed",
                hookEventName: .postToolUse,
                source: "pi",
                workspaceId: staleWorkspace.id.uuidString,
                surfaceId: panel.id.uuidString,
                requestId: "pi-workspace-dock-feed-request"
            )

            let result = await Self.ingestAcknowledgedOffMainActor([event])
            let payload = try Self.acknowledgmentPayload(result)

            #expect(payload["workspace_id"] as? String == workspace.id.uuidString)
            #expect(payload["surface_id"] as? String == panel.id.uuidString)
            #expect(insertedEvent?.workspaceId == workspace.id.uuidString)
            #expect(insertedEvent?.surfaceId == panel.id.uuidString)
            #expect(store.items.count == 1)
        }
    }

    @MainActor
    @Test("Blocking Feed clears attention from its exact workspace Dock owner")
    func blockingFeedClearsAttentionFromExactWorkspaceDockOwner() async throws {
        try await withAppContext { _, manager, workspace, _ in
            let dock = try #require(workspace.dockSplit)
            let panel = try dock.seedPiFeedPanel()
            let target = try #require(
                FeedCoordinator.shared.surfaceBlockingDecisionAttention(
                    event: WorkstreamEvent(
                        sessionId: "pi-workspace-dock-blocking-feed",
                        hookEventName: .permissionRequest,
                        source: "pi",
                        workspaceId: workspace.id.uuidString,
                        surfaceId: panel.id.uuidString,
                        requestId: "pi-workspace-dock-blocking-request"
                    ),
                    resolved: (workspace.id, panel.id),
                    tabManager: manager
                )
            )

            #expect(workspace.statusEntries[Self.attentionStatusKey] == nil)
            #expect(
                dock.agentRuntimeByPanelId[panel.id]?
                    .agentLifecycleStates[Self.attentionStatusKey] == .needsInput
            )
            #expect(
                dock.agentRuntimeStatusEntry(
                    key: Self.attentionStatusKey,
                    panelId: panel.id
                )?.value == FeedCoordinator.needsInputStatusValue
            )

            FeedCoordinator.shared.concludeBlockingDecisionAttention(target)

            #expect(
                dock.agentRuntimeByPanelId[panel.id]?
                    .agentLifecycleStates[Self.attentionStatusKey] == nil
            )
            #expect(
                dock.agentRuntimeStatusEntry(
                    key: Self.attentionStatusKey,
                    panelId: panel.id
                ) == nil
            )
            #expect(workspace.statusEntries[Self.attentionStatusKey] == nil)
        }
    }

    @MainActor
    @Test("Surface-less Feed accepts a live window Dock owner")
    func surfaceLessFeedAcceptsWindowDockOwner() async throws {
        try await withAppContext { appDelegate, _, _, windowID in
            _ = appDelegate.windowDock(forWindowId: windowID)
            var insertedEvent: WorkstreamEvent?
            let store = WorkstreamStore(ringCapacity: 10) {
                insertedEvent = $0
                return nil
            }
            FeedCoordinator.shared.install(store: store)
            let event = WorkstreamEvent(
                sessionId: "pi-window-dock-owner-feed",
                hookEventName: .postToolUse,
                source: "pi",
                workspaceId: "  \(windowID.uuidString) \n",
                requestId: "pi-window-dock-owner-feed-request"
            )

            let result = await Self.ingestAcknowledgedOffMainActor([event])
            let payload = try Self.acknowledgmentPayload(result)

            #expect(payload["workspace_id"] as? String == windowID.uuidString)
            #expect(payload["surface_id"] == nil)
            #expect(insertedEvent?.workspaceId == windowID.uuidString)
            #expect(insertedEvent?.surfaceId == nil)
            #expect(store.items.count == 1)
        }
    }

    @MainActor
    private func withAppContext(
        _ body: @MainActor (AppDelegate, TabManager, Workspace, UUID) async throws -> Void
    ) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let appDelegate = AppDelegate()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            AppDelegate.shared = appDelegate
            appDelegate.tabManager = manager
            appDelegate.didAttemptStartupSessionRestore = true
            let windowID = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            let workspace = manager.addWorkspace(select: true)
            defer {
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
                appDelegate.forgetRecoverableMainWindowRoute(windowId: windowID)
                manager.tabs.forEach { $0.teardownAllPanels() }
                appDelegate.tabManager = nil
                AppDelegate.shared = previousAppDelegate
            }

            try await body(appDelegate, manager, workspace, windowID)
        }
    }

    private static func acknowledgmentPayload(
        _ result: TerminalController.V2CallResult
    ) throws -> [String: Any] {
        guard case .ok(let rawPayload) = result,
              let payload = rawPayload as? [String: Any] else {
            Issue.record("expected authoritative Pi Feed insertion, got \(result)")
            return [:]
        }
        return payload
    }

    private static func ingestAcknowledgedOffMainActor(
        _ events: [WorkstreamEvent]
    ) async -> TerminalController.V2CallResult {
        let resultBox = PiFeedV2CallResultBox()
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                resultBox.value = TerminalController.shared.v2IngestAcknowledgedFeedEvents(events)
                continuation.resume()
            }
        }
        return resultBox.value!
    }
}
