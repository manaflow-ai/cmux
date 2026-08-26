import Combine
import CmuxCore
import CMUXAgentLaunch
import Darwin
import Foundation
import Observation
import Testing

import CmuxSidebar

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct WorkspaceSidebarObservationTests {
    @Test func sidebarObservationPublisherEmitsForLateStatusSubscriber() {
        let workspace = Workspace()
        workspace.statusEntries["test_probe"] = SidebarStatusEntry(
            key: "test_probe",
            value: "VISIBLE?",
            icon: "star.fill",
            color: "#FF0000",
            priority: 200
        )

        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }

        #expect(
            publishCount > 0,
            "A sidebar row that subscribes after status metadata already exists must still refresh from the current workspace state."
        )
    }

    @Test func agentRuntimeObservationChangesWhenAgentPIDMakesExistingStatusVisible() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.statusEntries["codex"] = SidebarStatusEntry(
            key: "codex",
            value: "Running",
            icon: "bolt.fill",
            color: "#4C8DFF"
        )
        #expect(
            !workspace.sidebarStatusEntriesInDisplayOrder().contains { $0.key == "codex" },
            "Structured agent statuses stay hidden until a live agent runtime owns the status key."
        )

        let generationBeforeRecord = workspace.sidebarAgentRuntimeObservation.changeGeneration
        var workspaceWillChangeCount = 0
        let objectWillChangeCancellable = workspace.objectWillChange.sink {
            workspaceWillChangeCount += 1
        }
        defer { objectWillChangeCancellable.cancel() }

        workspace.recordAgentPID(
            key: "codex.session-b",
            pid: 12_345,
            panelId: panelId,
            refreshPorts: false
        )

        #expect(
            workspace.sidebarStatusEntriesInDisplayOrder().contains { $0.key == "codex" },
            "Recording the agent PID makes the existing Running status visible."
        )
        #expect(
            workspace.sidebarAgentRuntimeObservation.changeGeneration > generationBeforeRecord,
            "Agent PID ownership changes must notify the sidebar row runtime observation stream."
        )
        #expect(
            workspaceWillChangeCount == 0,
            "Agent PID ownership is sidebar presentation state and must not broadly invalidate Workspace observers."
        )
    }

    @Test func separateAmpProcessesCannotMoveOrCancelEachOthersPaneOwnership() throws {
        let workspace = Workspace()
        let firstPanelId = try #require(workspace.focusedPanelId)
        let secondPanel = try #require(
            workspace.newTerminalSplit(
                from: firstPanelId,
                orientation: .horizontal
            )
        )
        let firstGeneration = AgentPIDProcessIdentity(
            pid: 1_001,
            startSeconds: 100,
            startMicroseconds: 10
        )
        let firstKey = try #require(
            AgentLifecycleProcessOwnershipScope.sharedProcess.agentPIDKey(
                statusKey: BuiltInAgentIntegration.amp.statusKey,
                sessionId: "thread-a",
                processGeneration: firstGeneration
            )
        )
        let siblingThreadKey = try #require(
            AgentLifecycleProcessOwnershipScope.sharedProcess.agentPIDKey(
                statusKey: BuiltInAgentIntegration.amp.statusKey,
                sessionId: "thread-b",
                processGeneration: firstGeneration
            )
        )
        let secondKey = try #require(
            AgentLifecycleProcessOwnershipScope.sharedProcess.agentPIDKey(
                statusKey: BuiltInAgentIntegration.amp.statusKey,
                sessionId: "thread-c",
                processGeneration: AgentPIDProcessIdentity(
                    pid: 2_002,
                    startSeconds: 200,
                    startMicroseconds: 20
                )
            )
        )

        #expect(firstKey == siblingThreadKey)
        #expect(firstKey != secondKey)
        workspace.recordAgentPID(
            key: firstKey,
            pid: 1_001,
            panelId: firstPanelId,
            refreshPorts: false
        )
        workspace.recordAgentPID(
            key: secondKey,
            pid: 2_002,
            panelId: secondPanel.id,
            refreshPorts: false
        )

        #expect(workspace.agentPIDPanelIdsByKey[firstKey] == firstPanelId)
        #expect(workspace.agentPIDPanelIdsByKey[secondKey] == secondPanel.id)
        #expect(
            workspace.clearAgentPID(
                key: firstKey,
                panelId: firstPanelId,
                refreshPorts: false
            )
        )
        #expect(workspace.agentPIDPanelIdsByKey[secondKey] == secondPanel.id)
        #expect(workspace.agentPIDs[secondKey] == 2_002)
    }

    @Test
    func reconciledFeedAttentionMakesPreRegisteredStatusVisible() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.statusEntries["cursor"] = SidebarStatusEntry(
            key: "cursor",
            value: FeedCoordinator.needsInputStatusValue,
            icon: "bell.fill",
            color: "#4C8DFF"
        )
        #expect(
            !workspace.sidebarStatusEntriesInDisplayOrder().contains {
                $0.key == "cursor"
            }
        )

        let generation = try #require(
            AgentPIDProcessIdentity(pid: getpid())
        )
        let token = try #require(
            workspace.beginAgentFeedAttention(
                key: "cursor",
                panelId: panelId,
                processGeneration: generation
            )
        )

        #expect(workspace.agentPIDs.isEmpty)
        #expect(
            workspace.sidebarStatusEntriesInDisplayOrder().contains {
                $0.key == "cursor"
            },
            "Exact-generation attention evidence must surface Needs Input even when its detached PID registration has not arrived yet."
        )

        #expect(
            workspace.endAgentFeedAttention(
                key: "cursor",
                panelId: panelId,
                token: token
            )
        )
        #expect(
            !workspace.sidebarStatusEntriesInDisplayOrder().contains {
                $0.key == "cursor"
            }
        )
    }

    @Test
    func relayAttentionRejectsGenerationOlderThanAuthoritativeHook() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
        let workspace = tabManager.addWorkspace(select: true)
        let panelId = try #require(workspace.focusedPanelId)
        workspace.remoteConfiguration = WorkspaceRemoteConfiguration(
            destination: "test-remote",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64_001,
            relayID: "relay-generation-test",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/cmux-relay-generation-test.sock",
            ownerWorkspaceID: workspace.id,
            terminalStartupCommand: "ssh test-remote"
        )
        defer {
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }

        let older = AgentPIDProcessIdentity(
            pid: 4_242,
            startSeconds: 100,
            startMicroseconds: 10
        )
        let newer = AgentPIDProcessIdentity(
            pid: 4_141,
            startSeconds: 200,
            startMicroseconds: 20
        )
        #expect(
            workspace.setAgentLifecycle(
                key: "amp",
                panelId: panelId,
                lifecycle: .idle,
                processGeneration: newer
            )
        )

        let sessionId = "relay-generation-\(UUID().uuidString)"
        let observationId = "observation-\(UUID().uuidString)"
        let scopeId = "scope-\(UUID().uuidString)"
        let began = FeedCoordinator.shared.beginObservedAgentAttention(
            source: "amp",
            sessionId: sessionId,
            observationId: observationId,
            scopeId: scopeId,
            workspaceId: workspace.id,
            surfaceId: panelId,
            processGeneration: older
        )
        defer {
            if began {
                _ = FeedCoordinator.shared.endObservedAgentAttention(
                    source: "amp",
                    sessionId: sessionId,
                    observationId: observationId,
                    scopeId: scopeId,
                    processGeneration: older
                )
            }
        }

        #expect(
            !began,
            "A delayed relay approval from an older process generation must not override newer hook state."
        )
        #expect(
            !workspace.sidebarAgentRuntimeObservation.hasAgentFeedAttention(
                key: "amp",
                panelId: panelId
            )
        )
        #expect(workspace.agentLifecycleStatesByPanelId[panelId]?["amp"] == .idle)
    }

    @Test
    func newerRelayGenerationRetiresOlderObservedAttention() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
        let workspace = tabManager.addWorkspace(select: true)
        let panelId = try #require(workspace.focusedPanelId)
        workspace.remoteConfiguration = WorkspaceRemoteConfiguration(
            destination: "test-remote",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64_004,
            relayID: "relay-replacement-test",
            relayToken: String(repeating: "r", count: 64),
            localSocketPath: "/tmp/cmux-relay-replacement-test.sock",
            ownerWorkspaceID: workspace.id,
            terminalStartupCommand: "ssh test-remote"
        )
        defer {
            FeedCoordinator.shared.retireAgentAttention(
                workspaceId: workspace.id,
                panelId: panelId
            )
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }

        let older = AgentPIDProcessIdentity(
            pid: 4_242,
            startSeconds: 100,
            startMicroseconds: 10
        )
        let newer = AgentPIDProcessIdentity(
            pid: 4_242,
            startSeconds: 200,
            startMicroseconds: 20
        )
        let runningStatus = SidebarStatusEntry(
            key: "amp",
            value: "Running",
            icon: "bolt.fill",
            color: "#4C8DFF"
        )
        workspace.statusEntries["amp"] = runningStatus
        #expect(
            FeedCoordinator.shared.beginObservedAgentAttention(
                source: "amp",
                sessionId: "relay-replacement-old",
                observationId: "relay-replacement-observation",
                scopeId: "relay-replacement-scope",
                workspaceId: workspace.id,
                surfaceId: panelId,
                processGeneration: older
            )
        )
        #expect(
            workspace.sidebarAgentRuntimeObservation.hasAgentFeedAttention(
                key: "amp",
                panelId: panelId
            )
        )

        #expect(
            ControlSidebarPanelOwner.workspace(workspace).setAgentLifecycle(
                key: "amp",
                panelId: panelId,
                lifecycle: .running,
                processGeneration: newer
            )
        )

        #expect(
            !workspace.sidebarAgentRuntimeObservation.hasAgentFeedAttention(
                key: "amp",
                panelId: panelId
            ),
            "An accepted replacement relay generation must retire attention owned by the superseded process."
        )
        #expect(
            workspace.agentLifecycleStatesByPanelId[panelId]?["amp"] == .running
        )
        #expect(
            workspace.statusEntries["amp"] == runningStatus,
            "Concluding native attention must restore the status that was visible before the prompt."
        )
    }

    @Test
    func unresolvedExplicitSurfaceDoesNotRetargetObservedAttention() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
        let workspace = tabManager.addWorkspace(select: true)
        let focusedPanelId = try #require(workspace.focusedPanelId)
        workspace.remoteConfiguration = WorkspaceRemoteConfiguration(
            destination: "test-remote",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64_005,
            relayID: "relay-explicit-surface-test",
            relayToken: String(repeating: "s", count: 64),
            localSocketPath: "/tmp/cmux-relay-explicit-surface-test.sock",
            ownerWorkspaceID: workspace.id,
            terminalStartupCommand: "ssh test-remote"
        )
        defer {
            FeedCoordinator.shared.retireAgentAttention(
                workspaceId: workspace.id,
                panelId: focusedPanelId
            )
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }

        let generation = AgentPIDProcessIdentity(
            pid: 5_252,
            startSeconds: 300,
            startMicroseconds: 30
        )
        #expect(
            !FeedCoordinator.shared.beginObservedAgentAttention(
                source: "amp",
                sessionId: "relay-stale-explicit-surface",
                observationId: "relay-stale-explicit-observation",
                scopeId: "relay-stale-explicit-scope",
                workspaceId: workspace.id,
                surfaceId: UUID(),
                processGeneration: generation
            ),
            "A stale explicit surface identity must fail closed instead of targeting the focused panel."
        )
        #expect(
            !workspace.sidebarAgentRuntimeObservation.hasAgentFeedAttention(
                key: "amp",
                panelId: focusedPanelId
            )
        )
        #expect(workspace.statusEntries["amp"] == nil)
    }

    @Test
    func cursorBoundaryRejectsDelayedObserverButAllowsFutureObserver() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
        let workspace = tabManager.addWorkspace(select: true)
        let panelId = try #require(workspace.focusedPanelId)
        workspace.remoteConfiguration = WorkspaceRemoteConfiguration(
            destination: "test-remote",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64_002,
            relayID: "cursor-boundary-test",
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-cursor-boundary-test.sock",
            ownerWorkspaceID: workspace.id,
            terminalStartupCommand: "ssh test-remote"
        )
        defer {
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }

        let coordinator = FeedCoordinator.shared
        let sessionId = "cursor-boundary-\(UUID().uuidString)"
        let generation = AgentPIDProcessIdentity(
            pid: 5_151,
            startSeconds: 300,
            startMicroseconds: 30
        )
        #expect(
            coordinator.endObservedAgentAttention(
                source: "cursor",
                sessionId: sessionId,
                observationId: nil,
                scopeId: nil,
                processGeneration: generation,
                boundaryEpoch: 200
            ) == 0
        )

        #expect(
            !coordinator.beginObservedAgentAttention(
                source: "cursor",
                sessionId: sessionId,
                observationId: "delayed-observation",
                scopeId: "delayed-scope",
                workspaceId: workspace.id,
                surfaceId: panelId,
                processGeneration: generation,
                observationEpoch: 100
            ),
            "A native observer that predates the process boundary must not resurrect attention."
        )

        let futureBegan = coordinator.beginObservedAgentAttention(
            source: "cursor",
            sessionId: sessionId,
            observationId: "future-observation",
            scopeId: "future-scope",
            workspaceId: workspace.id,
            surfaceId: panelId,
            processGeneration: generation,
            observationEpoch: 300
        )
        #expect(
            futureBegan,
            "A later approval in the same long-lived process must remain eligible."
        )
        if futureBegan {
            _ = coordinator.endObservedAgentAttention(
                source: "cursor",
                sessionId: sessionId,
                observationId: "future-observation",
                scopeId: "future-scope",
                processGeneration: generation
            )
        }
    }

    @Test
    func relayBlockingAttentionDoesNotUseTheLocalProcessTable() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
        let workspace = tabManager.addWorkspace(select: true)
        let panelId = try #require(workspace.focusedPanelId)
        workspace.remoteConfiguration = WorkspaceRemoteConfiguration(
            destination: "test-remote",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64_002,
            relayID: "relay-blocking-attention-test",
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-relay-blocking-attention-test.sock",
            ownerWorkspaceID: workspace.id,
            terminalStartupCommand: "ssh test-remote"
        )
        defer {
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }

        let event = WorkstreamEvent(
            sessionId: "relay-blocking-attention",
            hookEventName: .permissionRequest,
            source: "codex",
            workspaceId: workspace.id.uuidString,
            surfaceId: panelId.uuidString,
            requestId: "relay-blocking-attention-request",
            ppid: Int(getpid())
        )
        let target = try #require(
            FeedCoordinator.shared.surfaceBlockingDecisionAttention(
                event: event,
                resolved: (workspace.id, panelId)
            )
        )
        defer {
            FeedCoordinator.shared.concludeBlockingDecisionAttention(target)
        }

        #expect(
            target.token.processGeneration == nil,
            "A relay PID must not be resolved against the Mac's local process namespace."
        )
    }

    @Test
    func workspaceOnlyBlockingAttentionSurvivesMissingFocusedPanel() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
        let workspace = tabManager.addWorkspace(select: true)
        let panelId = try #require(workspace.focusedPanelId)
        let dock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        let dockPaneId = try #require(dock.bonsplitController.allPaneIds.first)
        let source = "workspace-only-attention"
        var target: FeedAttentionTarget?
        defer {
            if let target {
                FeedCoordinator.shared.concludeBlockingDecisionAttention(target)
            }
            dock.closeAllPanels()
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }

        let transfer = try #require(
            workspace.detachSurface(panelId: panelId)
        )
        #expect(
            dock.attachDetachedSurface(
                transfer,
                inPane: dockPaneId,
                focus: false
            ) == panelId
        )
        #expect(workspace.panels.isEmpty)
        #expect(workspace.focusedPanelId == nil)

        target = FeedCoordinator.shared.surfaceBlockingDecisionAttention(
            event: WorkstreamEvent(
                sessionId: "workspace-only-attention-session",
                hookEventName: .permissionRequest,
                source: source,
                requestId: "workspace-only-attention-request"
            ),
            resolved: (ownerId: workspace.id, surfaceId: nil),
            tabManager: tabManager
        )
        #expect(
            target != nil,
            "A blocking Feed decision must retain workspace scope when no panel is usable."
        )
        let statusKey = FeedCoordinator.attentionStatusKey(forSource: source)
        #expect(
            workspace.statusEntries[statusKey]?.value
                == FeedCoordinator.needsInputStatusValue
        )

        if let target {
            FeedCoordinator.shared.concludeBlockingDecisionAttention(target)
            self.assertWorkspaceOnlyAttentionWasCleared(
                workspace,
                statusKey: statusKey
            )
        }
    }

    private func assertWorkspaceOnlyAttentionWasCleared(
        _ workspace: Workspace,
        statusKey: String
    ) {
        #expect(
            workspace.statusEntries[statusKey] == nil,
            "Concluding a workspace-scoped Feed decision must clear its badge."
        )
    }

    @Test
    func workspaceAttentionScopesSeparateAfterOnePanelMovesToDock() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
        let workspace = tabManager.addWorkspace(select: true)
        let workspacePanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let dockPanelId = try #require(
            workspace.newTerminalSurface(inPane: paneId, focus: false)?.id
        )
        let dock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        let coordinator = FeedCoordinator.shared

        let workspaceTarget = try #require(
            coordinator.surfaceBlockingDecisionAttention(
                event: WorkstreamEvent(
                    sessionId: "workspace-attention",
                    hookEventName: .permissionRequest,
                    source: "codex",
                    requestId: "workspace-attention-request"
                ),
                resolved: (workspace.id, workspacePanelId)
            )
        )
        let dockTarget = try #require(
            coordinator.surfaceBlockingDecisionAttention(
                event: WorkstreamEvent(
                    sessionId: "dock-bound-attention",
                    hookEventName: .permissionRequest,
                    source: "codex",
                    requestId: "dock-bound-attention-request"
                ),
                resolved: (workspace.id, dockPanelId)
            )
        )
        defer {
            coordinator.concludeBlockingDecisionAttention(workspaceTarget)
            coordinator.concludeBlockingDecisionAttention(dockTarget)
            dock.closeAllPanels()
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }

        let transfer = try #require(
            workspace.detachSurface(panelId: dockPanelId)
        )
        let dockPaneId = try #require(dock.bonsplitController.allPaneIds.first)
        #expect(
            dock.attachDetachedSurface(
                transfer,
                inPane: dockPaneId,
                focus: false
            ) == dockPanelId
        )
        #expect(
            ControlSidebarPanelOwner.workspace(workspace).statusEntry(
                key: "codex",
                panelId: workspacePanelId
            ) != nil
        )
        #expect(
            ControlSidebarPanelOwner.dock(dock).statusEntry(
                key: "codex",
                panelId: dockPanelId
            ) != nil
        )

        coordinator.concludeBlockingDecisionAttention(workspaceTarget)

        #expect(
            ControlSidebarPanelOwner.workspace(workspace).statusEntry(
                key: "codex",
                panelId: workspacePanelId
            ) == nil,
            "The workspace badge must clear once its last workspace-owned decision ends."
        )
        #expect(
            ControlSidebarPanelOwner.dock(dock).statusEntry(
                key: "codex",
                panelId: dockPanelId
            ) != nil,
            "The moved panel's Dock-scoped decision must remain visible."
        )

        coordinator.concludeBlockingDecisionAttention(dockTarget)
        #expect(
            ControlSidebarPanelOwner.dock(dock).statusEntry(
                key: "codex",
                panelId: dockPanelId
            ) == nil,
            "The Dock badge must clear when its exact moved decision ends."
        )
    }

    @Test
    func dockAttentionScopesMergeWhenPanelsMoveIntoOneWorkspace() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
        let sourceWorkspace = tabManager.addWorkspace(select: true)
        let destinationWorkspace = tabManager.addWorkspace(select: false)
        let firstPanelId = try #require(sourceWorkspace.focusedPanelId)
        let sourcePaneId = try #require(
            sourceWorkspace.bonsplitController.focusedPaneId
        )
        let secondPanelId = try #require(
            sourceWorkspace.newTerminalSurface(
                inPane: sourcePaneId,
                focus: false
            )?.id
        )
        let dock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        let dockPaneId = try #require(dock.bonsplitController.allPaneIds.first)
        for panelId in [firstPanelId, secondPanelId] {
            let transfer = try #require(
                sourceWorkspace.detachSurface(panelId: panelId)
            )
            #expect(
                dock.attachDetachedSurface(
                    transfer,
                    inPane: dockPaneId,
                    focus: false
                ) == panelId
            )
        }

        let coordinator = FeedCoordinator.shared
        let firstTarget = try #require(
            coordinator.surfaceBlockingDecisionAttention(
                event: WorkstreamEvent(
                    sessionId: "first-dock-attention",
                    hookEventName: .permissionRequest,
                    source: "codex",
                    requestId: "first-dock-attention-request"
                ),
                resolved: (sourceWorkspace.id, firstPanelId)
            )
        )
        let secondTarget = try #require(
            coordinator.surfaceBlockingDecisionAttention(
                event: WorkstreamEvent(
                    sessionId: "second-dock-attention",
                    hookEventName: .permissionRequest,
                    source: "codex",
                    requestId: "second-dock-attention-request"
                ),
                resolved: (sourceWorkspace.id, secondPanelId)
            )
        )
        defer {
            coordinator.concludeBlockingDecisionAttention(firstTarget)
            coordinator.concludeBlockingDecisionAttention(secondTarget)
            dock.closeAllPanels()
            for workspace in [sourceWorkspace, destinationWorkspace]
                where tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }

        let destinationPaneId = try #require(
            destinationWorkspace.bonsplitController.focusedPaneId
        )
        for panelId in [firstPanelId, secondPanelId] {
            let transfer = try #require(dock.detachSurface(panelId: panelId))
            #expect(
                destinationWorkspace.attachDetachedSurface(
                    transfer,
                    inPane: destinationPaneId,
                    focus: false
                ) == panelId
            )
        }

        coordinator.concludeBlockingDecisionAttention(firstTarget)
        #expect(
            ControlSidebarPanelOwner.workspace(destinationWorkspace)
                .statusEntry(key: "codex", panelId: firstPanelId) != nil,
            "Workspace-scoped status must remain while the other moved panel still needs input."
        )

        coordinator.concludeBlockingDecisionAttention(secondTarget)
        #expect(
            ControlSidebarPanelOwner.workspace(destinationWorkspace)
                .statusEntry(key: "codex", panelId: secondPanelId) == nil,
            "The shared workspace badge must clear after the last moved decision ends."
        )
    }

    @Test
    func sessionScopedBuiltInKeysRequireExactProcessGeneration() {
        #expect(
            TerminalController.shared
                .controlSidebarRequiresAgentProcessGeneration(
                    "codex.session-id",
                    target: .workspace(UUID()),
                    panelID: nil
                )
        )
    }

    @Test func terminalAgentContextDoesNotObserveAgentRuntimeMaps() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId])
        let changeFlag = ObservationChangeFlag()

        withObservationTracking {
            _ = WorkspaceContentView.terminalAgentContext(panel: panel, workspace: workspace)
        } onChange: {
            changeFlag.mark()
        }

        workspace.recordAgentPID(
            key: "codex.session-c",
            pid: 12_346,
            panelId: panelId,
            refreshPorts: false
        )

        #expect(
            changeFlag.fired == false,
            "Terminal content must not subscribe to sidebar-only agent runtime map churn."
        )
    }

    @Test func sidebarImmediateObservationPublisherEmitsForLateTitleSubscriber() {
        let workspace = Workspace()
        workspace.title = "Restored Workspace"

        var publishCount = 0
        let cancellable = workspace.sidebarImmediateObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }

        #expect(
            publishCount > 0,
            "A sidebar row that subscribes after immediate workspace fields already exist must still refresh from the current workspace state."
        )
    }

    @Test func sidebarImmediateObservationPublisherDeliversManualTitleChangeSynchronously() {
        let workspace = Workspace()

        var publishCount = 0
        let cancellable = workspace.sidebarImmediateObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        workspace.setCustomTitle("User Edit")

        #expect(
            publishCount == 1,
            "The first immediate-field change after subscribing must reach the sidebar in the same run-loop turn; coalescing may only defer the tail of a burst."
        )
    }

    @Test func sidebarImmediateObservationPublisherCoalescesDescriptionBursts() {
        let workspace = Workspace()

        var publishCount = 0
        let cancellable = workspace.sidebarImmediateObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        for turn in 0..<20 {
            workspace.customDescription = "Agent Turn \(turn)"
        }

        #expect(
            publishCount == 1,
            "A synchronous burst of immediate fields must deliver only its leading edge immediately."
        )

        // Generous pump so the 50ms trailing emission fires deterministically.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        #expect(
            publishCount == 2,
            "A coalesced burst must settle with exactly one trailing emission carrying the latest state."
        )
    }

    @Test func coalesceLatestKeepsLeadingEdgeSynchronousAndEmitsLatestTrailing() {
        let subject = PassthroughSubject<Int, Never>()
        var received: [Int] = []
        let cancellable = subject
            .coalesceLatest(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { received.append($0) }
        defer { cancellable.cancel() }

        // First value models the @Published current-state replay: forwarded
        // synchronously without opening a coalesce window.
        subject.send(1)
        #expect(received == [1])

        // First change is the synchronous leading edge and opens the window.
        subject.send(2)
        #expect(received == [1, 2])

        // Burst inside the window coalesces to the latest value.
        subject.send(3)
        subject.send(4)
        subject.send(5)
        #expect(received == [1, 2])

        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        #expect(received == [1, 2, 5])

        // After the window closes and the trailing window expires, the next
        // value is synchronous again.
        subject.send(6)
        #expect(received == [1, 2, 5, 6])
    }

    @Test func coalesceLatestDropsStalePendingValueWhenLeadingSupersedesOverdueTrailing() {
        let scheduler = VirtualCoalesceScheduler()
        let subject = PassthroughSubject<Int, Never>()
        var received: [Int] = []
        let cancellable = subject
            .coalesceLatest(for: .milliseconds(50), scheduler: scheduler)
            .sink { received.append($0) }
        defer { cancellable.cancel() }

        subject.send(1) // replay: forwarded, no window
        subject.send(2) // leading edge: opens window
        subject.send(3) // pending trailing value for the open window
        #expect(received == [1, 2])
        #expect(scheduler.scheduledActionCount == 1)

        // The deadline passes WITHOUT the scheduled callback running,
        // modeling a stalled main run loop with an overdue timer.
        scheduler.advance(by: 0.12)
        subject.send(4) // deadline passed: new leading edge must supersede 3

        #expect(
            received == [1, 2, 4],
            "A newer leading value after an overdue deadline must drop the stale pending value."
        )

        scheduler.runScheduledActions()
        #expect(
            received == [1, 2, 4],
            "The overdue trailing callback must not emit the superseded stale value out of order."
        )
    }

    @Test func coalesceLatestDrainsReentrantValueBeforeCompletionWithUnlimitedDemand() {
        let scheduler = VirtualCoalesceScheduler()
        let subject = PassthroughSubject<Int, Never>()
        let subscriber = DemandControlledSubscriber<Int>()
        subject
            .coalesceLatest(for: .milliseconds(50), scheduler: scheduler)
            .subscribe(subscriber)
        defer { subscriber.cancel() }

        subscriber.onValue = { value in
            if value == 1 {
                subject.send(2)
                subject.send(completion: .finished)
            }
        }
        subscriber.request(.unlimited)
        subject.send(1)

        #expect(
            subscriber.received == [1, 2],
            "A reentrant value that arrived before completion must drain while unlimited demand remains."
        )
        #expect(subscriber.completionCount == 1)
        #expect(subscriber.receivedValuesAtCompletion == [[1, 2]])
    }

    @Test func coalesceLatestDeliversBufferedValueBeforeCompletionWhenDemandResumes() {
        let scheduler = VirtualCoalesceScheduler()
        let subject = PassthroughSubject<Int, Never>()
        let subscriber = DemandControlledSubscriber<Int>()
        subject
            .coalesceLatest(for: .milliseconds(50), scheduler: scheduler)
            .subscribe(subscriber)
        defer { subscriber.cancel() }

        subject.send(1)
        subject.send(completion: .finished)

        #expect(subscriber.received.isEmpty)
        #expect(
            subscriber.completionCount == 0,
            "Completion must wait while the final value is buffered without demand."
        )

        subscriber.request(.max(1))

        #expect(subscriber.received == [1])
        #expect(subscriber.completionCount == 1)
        #expect(subscriber.receivedValuesAtCompletion == [[1]])
    }

    @Test func sidebarObservationPublisherIgnoresRemoteHeartbeatOnlyChanges() {
        let workspace = Workspace()

        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        workspace.remoteHeartbeatCount = 1
        workspace.remoteLastHeartbeatAt = Date()

        #expect(
            publishCount == 0,
            "Expected non-visible remote heartbeat updates to avoid invalidating sidebar rows"
        )
    }

    @Test func agentLifecycleChangeBumpsRuntimeObservationGeneration() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let before = workspace.sidebarAgentRuntimeObservation.changeGeneration

        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)

        #expect(
            workspace.sidebarAgentRuntimeObservation.changeGeneration > before,
            "Agent lifecycle changes must notify sidebar rows so the loading spinner updates."
        )
    }

    @Test func redundantAgentLifecycleWriteDoesNotNotifySidebarRows() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)
        let before = workspace.sidebarAgentRuntimeObservation.changeGeneration

        // Re-asserting the same lifecycle value must not churn row refreshes.
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)

        #expect(workspace.sidebarAgentRuntimeObservation.changeGeneration == before)
    }

    @Test(.timeLimit(.minutes(1)))
    func agentProcessExitClearsRunningLifecycleWithoutWaitingForPIDPoll() async throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        }

        let pid = process.processIdentifier
        workspace.recordAgentPID(
            key: "codex.process-exit",
            pid: pid,
            panelId: panelId,
            refreshPorts: false
        )
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)
        workspace.statusEntries["codex"] = SidebarStatusEntry(
            key: "codex",
            value: "Running",
            icon: "bolt.fill",
            color: "#4C8DFF"
        )
        let changes = workspace.sidebarAgentRuntimeObservation.changes()

        process.terminate()

        let cleared = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in changes {
                    let isCleared = await MainActor.run {
                        let lifecycle = workspace.agentLifecycleStatesByPanelId[panelId]?["codex"]
                        return workspace.agentPIDs["codex.process-exit"] == nil
                            && lifecycle == nil
                            && workspace.statusEntries["codex"] == nil
                    }
                    if isCleared {
                        return true
                    }
                }
                return false
            }
            group.addTask {
                try? await Task<Never, Never>.sleep(for: .seconds(2))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        #expect(
            cleared,
            "A generation-bound process exit watcher must clear a killed agent immediately instead of leaving Running until the 30-second sweep."
        )
        #expect(workspace.statusEntries["codex"] == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func duplicateExactProcessExitObservationPreservesOriginalWatcher() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        }

        let generation = try #require(
            AgentPIDProcessIdentity(pid: process.processIdentifier)
        )
        let monitor = AgentProcessExitMonitor()
        let (events, continuation) = AsyncStream<String>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        var iterator = events.makeAsyncIterator()
        monitor.observe(key: "codex.duplicate", generation: generation) { _, _ in
            continuation.yield("original")
            continuation.finish()
        }
        monitor.observe(key: "codex.duplicate", generation: generation) { _, _ in
            continuation.yield("replacement")
            continuation.finish()
        }

        process.terminate()

        #expect(
            await iterator.next() == "original",
            "Re-registering an identical process generation must retain its existing exit watcher."
        )
    }

    @Test func unknownProcessLivenessRetiresExitObservation() throws {
        let generation = AgentPIDProcessIdentity(
            pid: pid_t(getpid()),
            startSeconds: 0,
            startMicroseconds: 0
        )
        let monitor = AgentProcessExitMonitor(
            livenessProbe: { _ in .unknown }
        )
        var didRetire = false
        monitor.observe(key: "unknown-liveness", generation: generation) { _, _ in
            didRetire = true
        }

        #expect(
            didRetire,
            "An unverified process generation must be retired conservatively instead of retaining a stuck watcher."
        )
    }

    @Test func processExitTombstoneRejectsDelayedLifecycleHook() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        }

        workspace.recordAgentPID(
            key: "codex.delayed-hook",
            pid: process.processIdentifier,
            panelId: panelId,
            refreshPorts: false
        )
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)
        process.terminate()
        process.waitUntilExit()
        #expect(workspace.clearStaleAgentPIDs(panelId: panelId, refreshPorts: false))

        // Simulate a queued Stop that was delivered after the process death.
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .idle)

        #expect(
            workspace.agentLifecycleStatesByPanelId[panelId]?["codex"] == nil,
            "A delayed hook from a dead PID generation must not resurrect lifecycle state."
        )
    }

    @Test func controlSidebarRejectsAcceptedPIDGenerationThatExitedBeforeDelivery() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        let acceptedIdentity = try #require(
            AgentPIDProcessIdentity(pid: process.processIdentifier)
        )
        process.waitUntilExit()
        let deadPID = process.processIdentifier
        let probeResult = kill(deadPID, 0)
        let probeErrno = errno
        try #require(probeResult != 0)
        try #require(probeErrno == ESRCH)
        let owner = ControlSidebarPanelOwner.workspace(workspace)

        #expect(
            !owner.recordAgentPID(
                key: "codex.dead-before-delivery",
                pid: deadPID,
                panelId: panelId,
                acceptedProcessIdentity: acceptedIdentity
            ).accepted
        )
        owner.setAgentLifecycle(
            key: "codex",
            panelId: panelId,
            lifecycle: .running
        )

        #expect(workspace.agentPIDs["codex.dead-before-delivery"] == nil)
        #expect(
            workspace.agentLifecycleStatesByPanelId[panelId]?["codex"] == nil
        )
    }

    @Test func deadPIDCannotPublishControlSocketStatus() throws {
        let previousManager =
            TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
            TerminalMutationBus.shared.drainForTesting()
        }

        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        let deadPID = process.processIdentifier
        let probeResult = kill(deadPID, 0)
        let probeErrno = errno
        try #require(probeResult != 0)
        try #require(probeErrno == ESRCH)

        let response = TerminalController.shared.handleSocketLine(
            "set_status codex Running --icon=bolt.fill --pid=\(deadPID) --tab=\(workspace.id.uuidString) --panel=\(panelId.uuidString)"
        )
        #expect(response == "OK")
        TerminalMutationBus.shared.drainForTesting()

        #expect(workspace.statusEntries["codex"] == nil)
        #expect(workspace.agentPIDs["codex"] == nil)
    }

    @Test func clearAgentLifecycleWithNilPanelClearsKeySetOnSpecificPanel() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setAgentLifecycle(key: "manual", panelId: panelId, lifecycle: .running)
        #expect(
            SidebarAgentActivitySummary.activeCodingAgentCount(
                statesByPanelId: workspace.agentLifecycleStatesByPanelId
            ) == 1
        )

        // The workspace-scoped `cmux workspace loading off` path clears with a
        // nil panel id; it must remove the key even though `on` targeted a
        // specific panel (the cross-surface off bug).
        #expect(workspace.clearAgentLifecycle(key: "manual", panelId: nil))
        #expect(
            SidebarAgentActivitySummary.activeCodingAgentCount(
                statesByPanelId: workspace.agentLifecycleStatesByPanelId
            ) == 0
        )
    }

    @Test func runningLifecycleQueryIsScopedToOneLoaderKey() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)
        workspace.setAgentLifecycle(key: "manual", panelId: panelId, lifecycle: .running)

        #expect(workspace.hasRunningAgentLifecycle(key: "manual"))
        #expect(workspace.clearAgentLifecycle(key: "manual", panelId: nil))
        #expect(!workspace.hasRunningAgentLifecycle(key: "manual"))
        #expect(workspace.hasRunningAgentLifecycle(key: "codex"))
        #expect(
            SidebarAgentActivitySummary.activeCodingAgentCount(
                statesByPanelId: workspace.agentLifecycleStatesByPanelId
            ) == 1
        )
    }

    @Test func clearAgentLifecycleStatesPreservesManualLoadersOnLivePanel() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)
        workspace.setAgentLifecycle(key: "manual", panelId: panelId, lifecycle: .running)

        // Agent lifecycle resets clear agent keys but must not drop the
        // workspace-scoped manual loader with them.
        workspace.clearAgentLifecycleStates(panelId: panelId)

        #expect(workspace.agentLifecycleStatesByPanelId[panelId]?["codex"] == nil)
        #expect(workspace.agentLifecycleStatesByPanelId[panelId]?["manual"] == .running)
    }

    @Test func activeCodingAgentCountOnlyCountsRunningAgents() {
        let firstPanelId = UUID()
        let secondPanelId = UUID()

        let count = SidebarAgentActivitySummary.activeCodingAgentCount(
            statesByPanelId: [
                firstPanelId: [
                    "codex": .running,
                    "claude_code": .idle,
                    "gemini": .needsInput,
                ],
                secondPanelId: [
                    "opencode": .running,
                    "kiro": .unknown,
                ],
            ]
        )

        #expect(count == 2)
    }

    @Test func visibleActiveCodingAgentCountReturnsZeroWhenSettingIsDisabled() {
        let panelId = UUID()
        let statesByPanelId = [
            panelId: [
                "codex": AgentHibernationLifecycleState.running,
                "claude_code": AgentHibernationLifecycleState.running,
            ],
        ]

        #expect(
            SidebarAgentActivitySummary.visibleActiveCodingAgentCount(
                showsAgentActivity: false,
                statesByPanelId: statesByPanelId
            ) == 0
        )
        #expect(
            SidebarAgentActivitySummary.visibleActiveCodingAgentCount(
                showsAgentActivity: true,
                statesByPanelId: statesByPanelId
            ) == 2
        )
    }
}

// Mutable flag captured by Observation's Sendable onChange closure in this test.
private final class ObservationChangeFlag: @unchecked Sendable {
    private(set) var fired = false

    func mark() {
        fired = true
    }
}

private final class DemandControlledSubscriber<Input>: Subscriber {
    typealias Failure = Never

    private var subscription: Subscription?
    private(set) var received: [Input] = []
    private(set) var completionCount = 0
    private(set) var receivedValuesAtCompletion: [[Input]] = []
    var onValue: ((Input) -> Void)?

    func receive(subscription: Subscription) {
        self.subscription = subscription
    }

    func receive(_ input: Input) -> Subscribers.Demand {
        received.append(input)
        onValue?(input)
        return .none
    }

    func receive(completion: Subscribers.Completion<Never>) {
        completionCount += 1
        receivedValuesAtCompletion.append(received)
    }

    func request(_ demand: Subscribers.Demand) {
        subscription?.request(demand)
    }

    func cancel() {
        subscription?.cancel()
        subscription = nil
    }
}
// Deterministic Combine scheduler for coalesceLatest tests: `now` only moves
// via advance(by:), and scheduled actions run only when runScheduledActions()
// is called, so overdue-timer interleavings are exact instead of wall-clock.
private final class VirtualCoalesceScheduler: Scheduler {
    typealias SchedulerTimeType = RunLoop.SchedulerTimeType
    typealias SchedulerOptions = Never

    private(set) var now = SchedulerTimeType(Date(timeIntervalSinceReferenceDate: 0))
    var minimumTolerance: SchedulerTimeType.Stride { .seconds(0) }
    private var scheduledActions: [() -> Void] = []

    var scheduledActionCount: Int { scheduledActions.count }

    func advance(by seconds: TimeInterval) {
        now = SchedulerTimeType(now.date.addingTimeInterval(seconds))
    }

    func runScheduledActions() {
        let actions = scheduledActions
        scheduledActions = []
        actions.forEach { $0() }
    }

    func schedule(options: Never?, _ action: @escaping () -> Void) {
        action()
    }

    func schedule(
        after date: SchedulerTimeType,
        tolerance: SchedulerTimeType.Stride,
        options: Never?,
        _ action: @escaping () -> Void
    ) {
        scheduledActions.append(action)
    }

    func schedule(
        after date: SchedulerTimeType,
        interval: SchedulerTimeType.Stride,
        tolerance: SchedulerTimeType.Stride,
        options: Never?,
        _ action: @escaping () -> Void
    ) -> Cancellable {
        scheduledActions.append(action)
        return AnyCancellable {}
    }
}
