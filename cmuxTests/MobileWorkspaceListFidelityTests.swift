import Testing
import AppKit
import Bonsplit
import CmuxCore
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Covers the mobile workspace-list fidelity fixes: bonsplit layout serialization,
/// terminal spatial order, custom titles, and observer topology invalidation.
///
/// `.serialized` because these exercise process-global surface registries via the
/// real `Workspace`/`TabManager`/bonsplit model, which must not run concurrently.
@MainActor
@Suite(.serialized)
struct MobileWorkspaceListFidelityTests {
    private func firstValue<Element: Sendable>(
        from stream: AsyncStream<Element>,
        within timeout: Duration = .seconds(2)
    ) async -> Element? {
        await withTaskGroup(of: Element?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let value = await group.next() ?? nil
            group.cancelAll()
            return value
        }
    }

    /// Builds a workspace with `count` terminals as tabs in a single pane so that
    /// a within-pane `reorderTab` genuinely changes their on-screen order. Returns
    /// the workspace and panel ids in spatial (tab) order.
    private func makeWorkspaceWithTabTerminals(count: Int) throws -> (Workspace, [UUID]) {
        precondition(count >= 1)
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        var orderedIds: [UUID] = [try #require(workspace.focusedPanelId)]
        for _ in 1..<count {
            let panel = try #require(workspace.newTerminalSurfaceInFocusedPane(focus: false))
            orderedIds.append(panel.id)
        }
        return (workspace, orderedIds)
    }

    /// Builds a workspace with `count` terminals laid out left-to-right via
    /// horizontal splits (each in its own pane), returning the workspace and panel
    /// ids in spatial order.
    private func makeWorkspaceWithSplitTerminals(count: Int) throws -> (Workspace, [UUID]) {
        precondition(count >= 1)
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        var orderedIds: [UUID] = [try #require(workspace.focusedPanelId)]
        for _ in 1..<count {
            let previous = try #require(orderedIds.last)
            let panel = try #require(
                workspace.newTerminalSplit(from: previous, orientation: .horizontal, focus: false)
            )
            orderedIds.append(panel.id)
        }
        return (workspace, orderedIds)
    }

    private func canonicalJSON(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try #require(String(data: data, encoding: .utf8))
    }

    @Test func splitTreeSerializesExactLayoutV1Shape() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let leftPanelID = try #require(workspace.focusedPanelId)
        workspace.setPanelCustomTitle(panelId: leftPanelID, title: "Left shell")
        let rightPanel = try #require(
            workspace.newTerminalSplit(
                from: leftPanelID,
                orientation: .vertical,
                focus: false,
                initialDividerPosition: 0.3
            )
        )
        workspace.setPanelCustomTitle(panelId: rightPanel.id, title: "Right shell")

        let snapshot = workspace.bonsplitController.treeSnapshot()
        guard case .split(let split) = snapshot,
              case .pane(let firstPane) = split.first,
              case .pane(let secondPane) = split.second else {
            Issue.record("expected a root split with two pane children")
            return
        }
        #expect(split.orientation == "vertical")
        #expect(abs(split.dividerPosition - 0.3) < 0.000_1)
        let firstTab = try #require(firstPane.tabs.first)
        let secondTab = try #require(secondPane.tabs.first)
        let firstSurfaceID = try #require(UUID(uuidString: firstTab.id))
        let secondSurfaceID = try #require(UUID(uuidString: secondTab.id))
        #expect(workspace.panelId(forSurfaceId: firstSurfaceID) == leftPanelID)
        #expect(workspace.panelId(forSurfaceId: secondSurfaceID) == rightPanel.id)
        let focusedPaneID = try #require(workspace.bonsplitController.focusedPaneId?.id.uuidString)
        #expect(focusedPaneID == firstPane.id)

        let payload = TerminalController.shared.mobileWorkspacePayload(
            workspace: workspace,
            isSelected: true,
            requestedTerminalID: nil
        )
        let layout = try #require(payload["layout"] as? [String: Any])
        let expected: [String: Any] = [
            "version": workspace.paneLayoutVersion,
            "focused_pane_id": firstPane.id,
            "root": [
                "kind": "split",
                "id": split.id,
                "orientation": "vertical",
                "ratio": 0.3,
                "first": [
                    "kind": "pane",
                    "id": firstPane.id,
                    "selected_surface_id": leftPanelID.uuidString,
                    "surfaces": [
                        ["id": leftPanelID.uuidString, "type": "terminal", "title": "Left shell"],
                    ],
                ],
                "second": [
                    "kind": "pane",
                    "id": secondPane.id,
                    "selected_surface_id": rightPanel.id.uuidString,
                    "surfaces": [
                        ["id": rightPanel.id.uuidString, "type": "terminal", "title": "Right shell"],
                    ],
                ],
            ],
        ]
        #expect(try canonicalJSON(layout) == canonicalJSON(expected))
    }

    @Test func nonTerminalPanelAppearsOnlyInLayoutSurfaces() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let terminalID = try #require(workspace.focusedPanelId)
        workspace.setPanelCustomTitle(panelId: terminalID, title: "Shell")
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let todoPanel = try #require(workspace.newWorkspaceTodoSurface(inPane: paneID, focus: false))
        workspace.setPanelCustomTitle(panelId: todoPanel.id, title: "Plan")

        let payload = TerminalController.shared.mobileWorkspacePayload(
            workspace: workspace,
            isSelected: true,
            requestedTerminalID: nil
        )
        let terminals = try #require(payload["terminals"] as? [[String: Any]])
        #expect(terminals.count == 1)
        #expect(terminals.first?["id"] as? String == terminalID.uuidString)
        #expect(!terminals.contains { $0["id"] as? String == todoPanel.id.uuidString })

        let layout = try #require(payload["layout"] as? [String: Any])
        let root = try #require(layout["root"] as? [String: Any])
        #expect(root["kind"] as? String == "pane")
        let surfaces = try #require(root["surfaces"] as? [[String: Any]])
        let todoSurface = try #require(surfaces.first { $0["id"] as? String == todoPanel.id.uuidString })
        #expect(todoSurface["type"] as? String == PanelType.workspaceTodo.rawValue)
        #expect(todoSurface["title"] as? String == "Plan")
    }

    @Test func mobileHostAdvertisesWorkspaceLayoutV1() {
        #expect(MobileHostService.mobileHostCapabilities.contains("workspace.layout.v1"))
        #expect(MobileHostService.mobileHostCapabilities.contains("workspace.pane_reorder.v1"))
    }

    @Test func observerPipelinesFollowSubscriberPresence() throws {
        let previousOverride = MobileWorkspaceListObserver.subscriberPresenceOverrideForTesting
        defer { MobileWorkspaceListObserver.subscriberPresenceOverrideForTesting = previousOverride }

        // With no mobile client subscribed to workspace.updated, the observer
        // must not build its publisher graph: every agent-driven workspace
        // mutation would otherwise run throttled deliveries plus a full-list
        // summary hash on the main thread for nobody.
        MobileWorkspaceListObserver.subscriberPresenceOverrideForTesting = false
        let manager = TabManager()
        let observer = MobileWorkspaceListObserver(tabManager: manager)
        #expect(!observer.pipelinesAttachedForTesting)

        // First subscriber arrives: the graph attaches (with its forced
        // initial emit) off the subscription-change notification.
        MobileWorkspaceListObserver.subscriberPresenceOverrideForTesting = true
        NotificationCenter.default.post(
            name: .mobileHostEventSubscriptionsDidChange,
            object: nil,
            userInfo: ["topics": ["workspace.updated"]]
        )
        #expect(observer.pipelinesAttachedForTesting)

        // Last subscriber leaves: the graph detaches again.
        MobileWorkspaceListObserver.subscriberPresenceOverrideForTesting = false
        NotificationCenter.default.post(
            name: .mobileHostEventSubscriptionsDidChange,
            object: nil,
            userInfo: ["topics": ["workspace.updated"]]
        )
        #expect(!observer.pipelinesAttachedForTesting)
    }

    @Test func observerPipelineEmitsForPaneSelectionAndSuppressesNoOp() async throws {
        let previousOverride = MobileWorkspaceListObserver.subscriberPresenceOverrideForTesting
        defer { MobileWorkspaceListObserver.subscriberPresenceOverrideForTesting = previousOverride }
        MobileWorkspaceListObserver.subscriberPresenceOverrideForTesting = true

        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let firstPanelID = try #require(workspace.focusedPanelId)
        let secondPanel = try #require(workspace.newTerminalSurfaceInFocusedPane(focus: false))
        let firstTabID = try #require(workspace.surfaceIdFromPanelId(firstPanelID))
        let secondTabID = try #require(workspace.surfaceIdFromPanelId(secondPanel.id))
        workspace.bonsplitController.selectTab(firstTabID)
        let (updates, updateContinuation) = AsyncStream<UUID>.makeStream(
            bufferingPolicy: .unbounded
        )
        defer { updateContinuation.finish() }
        let observer = MobileWorkspaceListObserver(
            tabManager: manager,
            workspaceUpdateEmitter: {
                if let focusedPanelID = workspace.focusedPanelId {
                    updateContinuation.yield(focusedPanelID)
                }
            }
        )
        let initialSelection = try #require(
            await firstValue(from: updates),
            "the observer should publish its initial snapshot"
        )
        #expect(initialSelection == firstPanelID)

        workspace.bonsplitController.selectTab(secondTabID)
        let selectionUpdate = try #require(
            await firstValue(from: updates),
            "pane selection should publish without a fixed delay"
        )
        #expect(selectionUpdate == secondPanel.id, "selection publishes through the observer")

        // Follow the no-op with a real selection. A redundant no-op emission
        // would deliver `secondPanel.id` before the real selection and fail.
        workspace.bonsplitController.selectTab(secondTabID)
        workspace.bonsplitController.selectTab(firstTabID)
        let selectionAfterNoOp = try #require(
            await firstValue(from: updates),
            "the real selection should publish after the no-op"
        )
        #expect(selectionAfterNoOp == firstPanelID, "a no-op selection stays suppressed")
        _ = observer
    }

    @Test func orderedPanelIdsMatchesBonsplitSpatialOrder() throws {
        let (workspace, createdOrder) = try makeWorkspaceWithSplitTerminals(count: 3)

        // orderedPanelIds is derived from bonsplit's left-to-right tab ordering.
        let ordered = workspace.orderedPanelIds
        #expect(Set(ordered) == Set(createdOrder), "should contain exactly the created panels")

        // It must equal bonsplit's own allTabIds mapping (the spatial source of
        // truth), not dictionary/UUID order.
        let expected = workspace.bonsplitController.allTabIds.compactMap {
            workspace.panelIdFromSurfaceId($0)
        }
        #expect(ordered == expected)
    }

    @Test func mobilePaneReorderMovesCompleteContentsThroughStableLayoutSlots() throws {
        let (workspace, _) = try makeWorkspaceWithSplitTerminals(count: 3)
        _ = try #require(workspace.newTerminalSurfaceInFocusedPane(focus: false))
        let spatialPaneIDs = workspace.spatiallyOrderedPaneIds
        #expect(spatialPaneIDs.count == 3)
        let panesByID = Dictionary(
            uniqueKeysWithValues: workspace.bonsplitController.allPaneIds.map { ($0.id, $0) }
        )
        let originalContents = try spatialPaneIDs.map { paneID in
            let pane = try #require(panesByID[paneID])
            return workspace.bonsplitController.tabs(inPane: pane).compactMap {
                workspace.panelIdFromSurfaceId($0.id)
            }
        }
        #expect(originalContents[0].count == 2)
        let originalFocusedPanelID = try #require(workspace.focusedPanelId)
        let originalFocusedPaneID = try #require(
            workspace.paneId(forPanelId: originalFocusedPanelID)?.id
        )
        let requestedContentOrder = [
            spatialPaneIDs[2],
            spatialPaneIDs[0],
            spatialPaneIDs[1],
        ]
        let expectedPanelOrder =
            originalContents[2] + originalContents[0] + originalContents[1]
        let versionBefore = workspace.paneLayoutVersion

        #expect(workspace.applyMobilePaneOrder(requestedContentOrder))

        #expect(
            workspace.spatiallyOrderedPaneIds == spatialPaneIDs,
            "Pane identities and split geometry must remain stable"
        )
        #expect(
            workspace.orderedPanelIds == expectedPanelOrder,
            "Every pane's complete content must move into the requested spatial slot"
        )
        let focusedPanelDestinationPaneID = try #require(
            workspace.paneId(forPanelId: originalFocusedPanelID)?.id
        )
        #expect(focusedPanelDestinationPaneID == spatialPaneIDs[1])
        #expect(workspace.bonsplitController.focusedPaneId?.id == focusedPanelDestinationPaneID)
        #expect(originalFocusedPaneID != focusedPanelDestinationPaneID)
        #expect(
            workspace.paneLayoutVersion == versionBefore + 1,
            "The multi-step Bonsplit mutation must publish one authoritative revision"
        )
    }

    @Test func mobilePaneReorderRejectsStaleTopologyWithoutMutation() throws {
        let (workspace, originalPanelOrder) = try makeWorkspaceWithSplitTerminals(count: 3)
        let spatialPaneIDs = workspace.spatiallyOrderedPaneIds
        let versionBefore = workspace.paneLayoutVersion

        #expect(!workspace.applyMobilePaneOrder(Array(spatialPaneIDs.dropLast())))
        #expect(workspace.spatiallyOrderedPaneIds == spatialPaneIDs)
        #expect(workspace.orderedPanelIds == originalPanelOrder)
        #expect(workspace.paneLayoutVersion == versionBefore)
    }

    @Test func mobilePaneReorderRPCMutatesOwnerAndReturnsAuthoritativeList() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let firstPanelID = try #require(workspace.focusedPanelId)
        let secondPanel = try #require(
            workspace.newTerminalSplit(
                from: firstPanelID,
                orientation: .horizontal,
                focus: false
            )
        )
        let paneIDs = workspace.spatiallyOrderedPaneIds
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previousManager) }

        let result = TerminalController.shared.v2MobileWorkspacePaneReorder(params: [
            "workspace_id": workspace.id.uuidString,
            "ordered_pane_ids": paneIDs.reversed().map(\.uuidString),
        ])

        guard case .ok(let payload) = result,
              let object = payload as? [String: Any],
              let returnedWorkspaces = object["workspaces"] as? [[String: Any]] else {
            return #expect(Bool(false), "pane reorder should return an authoritative workspace list")
        }
        #expect(workspace.orderedPanelIds == [secondPanel.id, firstPanelID])
        #expect(
            returnedWorkspaces.contains {
                $0["id"] as? String == workspace.id.uuidString
            }
        )
    }

    @Test func reorderingTerminalsChangesObserverHashAndBumpsLayoutVersion() throws {
        // Tabs in one pane so a within-pane reorder genuinely changes their order.
        let (workspace, ordered) = try makeWorkspaceWithTabTerminals(count: 3)
        #expect(ordered.count == 3)

        let selectedTabID = try #require(workspace.surfaceIdFromPanelId(ordered[0]))
        workspace.bonsplitController.selectTab(selectedTabID)
        let versionBefore = workspace.paneLayoutVersion
        let before = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )

        // Move the first terminal to the end. Same panel set, different spatial order.
        let firstTabId = try #require(workspace.surfaceIdFromPanelId(ordered[0]))
        #expect(workspace.bonsplitController.reorderTab(firstTabId, toIndex: 2))
        workspace.bonsplitController.selectTab(selectedTabID)

        // Sanity: the id set is unchanged, but the order changed.
        let afterOrder = workspace.orderedPanelIds
        #expect(Set(afterOrder) == Set(ordered))
        #expect(afterOrder != ordered, "reorder should change the ordered sequence")

        // The reorder must wake the observer (bonsplit selection state is not
        // @Published, so paneLayoutVersion is the only signal).
        #expect(
            workspace.paneLayoutVersion > versionBefore,
            "a pure reorder must bump paneLayoutVersion so the observer re-evaluates"
        )

        let after = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )
        #expect(before != after, "a pure reorder must change the mobile summary hash")
    }

    @Test func changingPaneSelectedTabChangesObserverHash() throws {
        let (workspace, ordered) = try makeWorkspaceWithTabTerminals(count: 2)
        let firstTabID = try #require(workspace.surfaceIdFromPanelId(ordered[0]))
        let secondTabID = try #require(workspace.surfaceIdFromPanelId(ordered[1]))
        workspace.bonsplitController.selectTab(firstTabID)
        let before = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )

        workspace.bonsplitController.selectTab(secondTabID)
        let snapshot = workspace.bonsplitController.treeSnapshot()
        guard case .pane(let pane) = snapshot else {
            Issue.record("expected a single pane")
            return
        }
        #expect(pane.selectedTabId == secondTabID.uuid.uuidString)

        let after = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )
        #expect(before != after, "changing only a pane's selected tab must change the mobile summary hash")
    }

    @Test func changingPaneSelectedTabPublishesLayoutRevision() throws {
        let (workspace, ordered) = try makeWorkspaceWithTabTerminals(count: 2)
        let firstTabID = try #require(workspace.surfaceIdFromPanelId(ordered[0]))
        let secondTabID = try #require(workspace.surfaceIdFromPanelId(ordered[1]))
        workspace.bonsplitController.selectTab(firstTabID)
        let versionBefore = workspace.paneLayoutVersion

        workspace.bonsplitController.selectTab(secondTabID)

        #expect(
            workspace.paneLayoutVersion == versionBefore + 1,
            "a pane-local selection must publish one layout revision"
        )
        let versionAfterChange = workspace.paneLayoutVersion
        workspace.bonsplitController.selectTab(secondTabID)
        #expect(
            workspace.paneLayoutVersion == versionAfterChange,
            "reselecting the current surface must not publish a no-op revision"
        )
    }

    @Test func focusingPaneChangesObserverHashAndPublishesLayoutRevision() throws {
        let (workspace, _) = try makeWorkspaceWithSplitTerminals(count: 2)
        let focusedPane = try #require(workspace.bonsplitController.focusedPaneId)
        let destinationPane = try #require(
            workspace.bonsplitController.allPaneIds.first(where: { $0 != focusedPane })
        )
        let hashBefore = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )
        let versionBefore = workspace.paneLayoutVersion

        workspace.bonsplitController.focusPane(destinationPane)

        let hashAfter = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )
        #expect(hashAfter != hashBefore, "focused pane is part of the mobile layout snapshot")
        #expect(
            workspace.paneLayoutVersion == versionBefore + 1,
            "a focus-only pane change must publish one layout revision"
        )
    }

    @Test func crossPaneMoveWithStableFlatOrderPublishesLayoutRevision() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let firstPanelID = try #require(workspace.focusedPanelId)
        let secondPanel = try #require(workspace.newTerminalSurfaceInFocusedPane(focus: false))
        let thirdPanel = try #require(
            workspace.newTerminalSplit(from: secondPanel.id, orientation: .horizontal, focus: false)
        )
        let secondTabID = try #require(workspace.surfaceIdFromPanelId(secondPanel.id))
        let destinationPane = try #require(workspace.paneId(forPanelId: thirdPanel.id))
        let orderBefore = workspace.orderedPanelIds
        #expect(orderBefore == [firstPanelID, secondPanel.id, thirdPanel.id])
        let versionBefore = workspace.paneLayoutVersion

        #expect(workspace.bonsplitController.moveTab(secondTabID, toPane: destinationPane, atIndex: 0))

        #expect(
            workspace.orderedPanelIds == orderBefore,
            "the regression needs pane membership to change without changing the flat surface order"
        )
        #expect(
            workspace.paneLayoutVersion == versionBefore + 1,
            "pane membership changes must publish even when the flat surface order stays stable"
        )
    }

    @Test func changingOnlyDividerRatioDoesNotChangeObserverHash() throws {
        let (workspace, _) = try makeWorkspaceWithSplitTerminals(count: 2)
        guard case .split(let splitBefore) = workspace.bonsplitController.treeSnapshot() else {
            Issue.record("expected a root split")
            return
        }
        let before = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )
        let changedRatio = splitBefore.dividerPosition < 0.5 ? 0.75 : 0.25
        let splitID = try #require(UUID(uuidString: splitBefore.id))
        #expect(workspace.bonsplitController.setDividerPosition(CGFloat(changedRatio), forSplit: splitID))

        guard case .split(let splitAfter) = workspace.bonsplitController.treeSnapshot() else {
            Issue.record("expected a root split after resizing")
            return
        }
        #expect(abs(splitAfter.dividerPosition - changedRatio) < 0.000_1)
        let after = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )
        #expect(before == after, "divider-only changes must not change the mobile summary hash")
    }

    @Test func renamingTerminalChangesObserverHashAndDisplayedTitle() throws {
        let (workspace, ordered) = try makeWorkspaceWithTabTerminals(count: 2)
        let panelId = try #require(ordered.first)

        let before = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )

        // A terminal rename sets panelCustomTitles (not panelTitles); the observer
        // must still detect it, and panelTitle must resolve to the custom title that
        // the mobile workspace.list response serializes.
        workspace.setPanelCustomTitle(panelId: panelId, title: "Renamed Terminal")
        #expect(workspace.panelTitle(panelId: panelId) == "Renamed Terminal")

        let after = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )
        #expect(before != after, "a terminal rename must change the mobile summary hash")
    }

    @Test func renamingWorkspaceChangesObserverHashAndDisplayedTitle() throws {
        let (workspace, _) = try makeWorkspaceWithTabTerminals(count: 1)

        let before = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )

        workspace.setCustomTitle("Renamed Workspace")
        // The mobile workspace.list response sends workspace.title.
        #expect(workspace.title == "Renamed Workspace")

        let after = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )
        #expect(before != after, "a workspace rename must change the mobile summary hash")
    }

    /// A pure group-membership move (a workspace's `groupId` changes while the tab
    /// set, group list, panels, title, and pin state stay put) must change the
    /// mobile summary hash so the observer re-emits `workspace.updated`. The phone
    /// nests members under their group header keyed by `group_id`, so a stale hash
    /// here would leave the mobile sidebar showing the workspace in the wrong
    /// section. Guards the per-workspace `$groupId` subscription that drives it.
    @Test func movingWorkspaceBetweenGroupsChangesObserverHash() throws {
        let manager = TabManager()
        let member = try #require(manager.selectedWorkspace)
        // A real group with its own anchor; the member starts ungrouped.
        let groupId = try #require(manager.createWorkspaceGroup(name: "Group A"))
        #expect(member.groupId == nil)

        let before = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: manager.tabs,
            groups: manager.workspaceGroups,
            selectedTabID: manager.selectedTabId
        )

        // Move the workspace into the group: only `groupId` changes.
        member.groupId = groupId

        let after = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: manager.tabs,
            groups: manager.workspaceGroups,
            selectedTabID: manager.selectedTabId
        )
        #expect(before != after, "a pure group-membership move must change the mobile summary hash")
    }

    /// A new notification (or clearing the latest one) changes only a workspace's
    /// preview signature, not the tab set, groups, panels, title, or pin state.
    /// The signature must be folded into the summary hash so the observer
    /// re-emits and the phone refreshes the row's preview line + relative time.
    @Test func previewSignatureChangeChangesObserverHash() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)

        let before = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: manager.tabs,
            groups: manager.workspaceGroups,
            selectedTabID: manager.selectedTabId,
            previewSignatures: [:]
        )
        let after = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: manager.tabs,
            groups: manager.workspaceGroups,
            selectedTabID: manager.selectedTabId,
            previewSignatures: [workspace.id: 42]
        )
        #expect(before != after, "a preview-signature change must change the mobile summary hash")

        let changed = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: manager.tabs,
            groups: manager.workspaceGroups,
            selectedTabID: manager.selectedTabId,
            previewSignatures: [workspace.id: 43]
        )
        #expect(after != changed, "a newer notification must change the mobile summary hash")
    }

    @Test func remoteDirectoryTrustChangesObserverHashAndPayload() throws {
        let localDirectory = "/Users/alice/development"
        let remoteDirectory = "/home/seepine/workspace"
        let manager = TabManager(
            initialWorkspaceTitle: "Remote",
            initialWorkingDirectory: localDirectory,
            autoWelcomeIfNeeded: false
        )
        let workspace = try #require(manager.selectedWorkspace)
        let remotePanelId = try #require(workspace.focusedPanelId)
        #expect(workspace.updatePanelDirectory(panelId: remotePanelId, directory: localDirectory))
        let configuration = sshRemoteConfiguration()
        workspace.configureRemoteConnection(configuration, autoConnect: false)

        let untrustedHash = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: manager.tabs,
            selectedTabID: manager.selectedTabId
        )
        let untrustedPayload = TerminalController.shared.mobileWorkspacePayload(
            workspace: workspace,
            isSelected: true,
            requestedTerminalID: nil
        )
        let untrustedTerminals = try #require(untrustedPayload["terminals"] as? [[String: Any]])
        let untrustedTerminal = try #require(untrustedTerminals.first)
        #expect(untrustedPayload["current_directory"] is NSNull)
        #expect(untrustedTerminal["current_directory"] is NSNull)

        workspace.updateRemotePanelDirectory(panelId: remotePanelId, directory: remoteDirectory)
        let trustedHash = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: manager.tabs,
            selectedTabID: manager.selectedTabId
        )
        #expect(untrustedHash != trustedHash, "trusting a remote cwd must refresh the mobile list")
        let trustedPayload = TerminalController.shared.mobileWorkspacePayload(
            workspace: workspace,
            isSelected: true,
            requestedTerminalID: nil
        )
        let trustedTerminals = try #require(trustedPayload["terminals"] as? [[String: Any]])
        let trustedTerminal = try #require(trustedTerminals.first)
        #expect(trustedPayload["current_directory"] as? String == remoteDirectory)
        #expect(trustedTerminal["current_directory"] as? String == remoteDirectory)

        workspace.disconnectRemoteConnection()
        let disconnectedPayload = TerminalController.shared.mobileWorkspacePayload(
            workspace: workspace,
            isSelected: true,
            requestedTerminalID: nil
        )
        let disconnectedTerminals = try #require(disconnectedPayload["terminals"] as? [[String: Any]])
        #expect(disconnectedPayload["current_directory"] is NSNull)
        #expect(try #require(disconnectedTerminals.first)["current_directory"] is NSNull)

        workspace.configureRemoteConnection(configuration, autoConnect: false)
        let clearedHash = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: manager.tabs,
            selectedTabID: manager.selectedTabId
        )
        #expect(clearedHash != trustedHash, "clearing remote cwd trust must refresh the mobile list")
        let clearedPayload = TerminalController.shared.mobileWorkspacePayload(
            workspace: workspace,
            isSelected: true,
            requestedTerminalID: nil
        )
        let clearedTerminals = try #require(clearedPayload["terminals"] as? [[String: Any]])
        let clearedTerminal = try #require(clearedTerminals.first)
        #expect(clearedPayload["current_directory"] is NSNull)
        #expect(clearedTerminal["current_directory"] is NSNull)
    }

    @Test func focusingUntrustedRemoteTerminalChangesObserverHash() throws {
        let localDirectory = "/Users/alice/development"
        let remoteDirectory = "/home/seepine/workspace"
        let manager = TabManager(
            initialWorkspaceTitle: "Remote",
            initialWorkingDirectory: localDirectory,
            autoWelcomeIfNeeded: false
        )
        let workspace = try #require(manager.selectedWorkspace)
        let trustedPanelId = try #require(workspace.focusedPanelId)
        workspace.configureRemoteConnection(sshRemoteConfiguration(), autoConnect: false)
        workspace.updateRemotePanelDirectory(panelId: trustedPanelId, directory: remoteDirectory)
        let untrustedPanel = try #require(workspace.newTerminalSurfaceInFocusedPane(focus: false))
        #expect(workspace.isRemoteTerminalSurface(untrustedPanel.id))
        #expect(workspace.reportedPanelDirectory(panelId: trustedPanelId) == remoteDirectory)
        #expect(workspace.reportedPanelDirectory(panelId: untrustedPanel.id) == nil)

        let trustedFocusHash = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: manager.tabs,
            selectedTabID: manager.selectedTabId
        )
        workspace.focusPanel(untrustedPanel.id)
        #expect(workspace.focusedPanelId == untrustedPanel.id)
        #expect(workspace.presentedCurrentDirectory == nil)

        let untrustedFocusHash = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: manager.tabs,
            selectedTabID: manager.selectedTabId
        )
        #expect(
            trustedFocusHash != untrustedFocusHash,
            "a focus-only presented cwd change must refresh the mobile list"
        )

        workspace.configureRemoteConnection(
            try #require(workspace.remoteConfiguration),
            autoConnect: false
        )
        let clearedTrustHash = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: manager.tabs,
            selectedTabID: manager.selectedTabId
        )
        #expect(
            untrustedFocusHash != clearedTrustHash,
            "clearing background remote cwd trust must refresh the mobile list"
        )
    }

    @Test func localTerminalInRemoteWorkspaceKeepsDirectoryInMobilePayload() throws {
        let localDirectory = "/Users/alice/development"
        let manager = TabManager(
            initialWorkspaceTitle: "Remote",
            initialWorkingDirectory: localDirectory,
            autoWelcomeIfNeeded: false
        )
        let workspace = try #require(manager.selectedWorkspace)
        workspace.configureRemoteConnection(sshRemoteConfiguration(), autoConnect: false)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let localPanel = try #require(workspace.newTerminalSurface(
            inPane: paneId,
            focus: false,
            workingDirectory: localDirectory,
            suppressWorkspaceRemoteStartupCommand: true
        ))
        #expect(!workspace.isRemoteTerminalSurface(localPanel.id))
        #expect(workspace.reportedPanelDirectory(panelId: localPanel.id) == nil)

        let payload = TerminalController.shared.mobileWorkspacePayload(
            workspace: workspace,
            isSelected: true,
            requestedTerminalID: localPanel.id
        )
        let terminals = try #require(payload["terminals"] as? [[String: Any]])
        let terminal = try #require(terminals.first)
        #expect(terminal["current_directory"] as? String == localDirectory)
    }

    /// Why some rows showed no relative time: the payload's only timestamp was
    /// `preview_at`, sourced from the latest notification, so a workspace that
    /// never fired a notification carried no timestamp at all and its trailing
    /// slot stayed empty on the phone. Every workspace payload must carry
    /// `last_activity_at` (the latest notification when there is one, the
    /// workspace's creation time otherwise) so every row can render a time.
    @Test func everyWorkspacePayloadCarriesLastActivity() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)

        // A freshly created workspace has no notification, so it has no preview
        // and previously no timestamp of any kind.
        let payload = TerminalController.shared.mobileWorkspacePayload(
            workspace: workspace,
            isSelected: false,
            requestedTerminalID: nil
        )
        #expect(payload["preview_at"] is NSNull, "no notification means no preview timestamp")

        let lastActivity = try #require(
            payload["last_activity_at"] as? Double,
            "a quiet workspace must still carry a last-activity stamp"
        )
        // The fallback is the workspace's creation time: a real, recent instant,
        // never the epoch (which the phone treats as "no activity").
        let now = Date().timeIntervalSince1970
        #expect(lastActivity > now - 3600)
        #expect(lastActivity <= now + 60)
    }

    /// The payload's `has_unread` mirrors the Mac sidebar's workspace unread
    /// badge, and flipping it must also change the observer's per-workspace
    /// signature so the phone is told to refresh (an unread toggle changes
    /// nothing else this observer watches).
    @Test func workspaceUnreadFlagFlowsIntoPayloadAndSignature() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let store = TerminalNotificationStore.shared
        #expect(!store.workspaceIsUnread(forTabId: workspace.id))

        let readPayload = TerminalController.shared.mobileWorkspacePayload(
            workspace: workspace,
            isSelected: false,
            requestedTerminalID: nil,
            notificationStore: store
        )
        #expect(readPayload["has_unread"] as? Bool == false)
        let readSignatures = MobileWorkspaceListObserver.previewSignatures(
            for: [workspace],
            notificationStore: store
        )

        #expect(store.setPanelDerivedUnread(true, forTabId: workspace.id))
        defer { store.setPanelDerivedUnread(false, forTabId: workspace.id) }

        let unreadPayload = TerminalController.shared.mobileWorkspacePayload(
            workspace: workspace,
            isSelected: false,
            requestedTerminalID: nil,
            notificationStore: store
        )
        #expect(unreadPayload["has_unread"] as? Bool == true)

        let unreadSignatures = MobileWorkspaceListObserver.previewSignatures(
            for: [workspace],
            notificationStore: store
        )
        #expect(
            readSignatures[workspace.id] != unreadSignatures[workspace.id],
            "an unread flip must change the per-workspace signature so the observer re-emits"
        )
    }

    /// The mobile preview line must flatten arbitrary notification text into one
    /// short plain-text line: ANSI escapes stripped, control characters and
    /// newlines collapsed, whitespace runs joined, length capped with an ellipsis,
    /// and whitespace-only input dropped entirely.
    @Test func mobilePreviewSanitizeFlattensAndCaps() throws {
        // ANSI SGR + OSC sequences are stripped without leaking payload bytes.
        #expect(
            TerminalController.mobilePreviewSanitize("\u{001B}[31mbuild\u{001B}[0m \u{001B}]0;title\u{0007}done") ==
                "build done"
        )
        // Newlines, tabs, and runs of spaces collapse to single spaces.
        #expect(TerminalController.mobilePreviewSanitize("line one\n\n  line\ttwo   ") == "line one line two")
        // Whitespace-only input yields nil so the row shows no preview.
        #expect(TerminalController.mobilePreviewSanitize(" \n\t ") == nil)
        // Long input is capped with a trailing ellipsis at the documented limit.
        let long = String(repeating: "a", count: 500)
        let capped = try #require(TerminalController.mobilePreviewSanitize(long))
        #expect(capped.count == TerminalController.mobilePreviewMaxLength)
        #expect(capped.hasSuffix("\u{2026}"))
        // Input past the processing cap is never scanned (bounded main-actor
        // work); a huge body still yields the documented capped preview.
        let huge = String(repeating: "b", count: TerminalController.mobilePreviewInputCap * 64)
        let boundedHuge = try #require(TerminalController.mobilePreviewSanitize(huge))
        #expect(boundedHuge.count == TerminalController.mobilePreviewMaxLength)
        #expect(boundedHuge.hasSuffix("\u{2026}"))
        // A short visible head followed by over-cap filler keeps the head and
        // signals the truncation with an ellipsis instead of dropping it.
        let headThenFiller = "ok" + String(repeating: " ", count: TerminalController.mobilePreviewInputCap) + "tail"
        #expect(TerminalController.mobilePreviewSanitize(headThenFiller) == "ok\u{2026}")
        // An OSC sequence left unterminated (e.g. cut by the input cap) is
        // stripped wholly rather than leaking its payload bytes.
        #expect(TerminalController.mobilePreviewSanitize("\u{001B}]0;unterminated title") == nil)
        // CSI parameter bytes are the full ECMA-48 0x30-0x3F range, not just
        // digits/;/?. Modern 24-bit color uses colon-separated SGR parameters
        // (ESC[38:2::255:0:0m); stripping must consume the whole sequence
        // instead of leaving ":2::255:0:0m" visible in the preview.
        #expect(
            TerminalController.mobilePreviewSanitize("\u{001B}[38:2::255:0:0mred\u{001B}[0m text") ==
                "red text"
        )
        // Same range covers the private-use <=> parameter bytes.
        #expect(TerminalController.mobilePreviewSanitize("\u{001B}[>4;2mok") == "ok")
        // The input bound must hold in unicode scalars, not Characters: a single
        // crafted grapheme cluster carrying a huge run of combining marks is one
        // Character, so a Character-counted cap never truncates it and the whole
        // cluster leaks into the preview (and gets fully scanned on the
        // main-actor list path). The sanitized output must stay scalar-bounded.
        let combiningBomb = "a" + String(
            repeating: "\u{0301}",
            count: TerminalController.mobilePreviewInputCap * 8
        )
        let boundedCluster = try #require(TerminalController.mobilePreviewSanitize(combiningBomb))
        #expect(boundedCluster.unicodeScalars.count <= TerminalController.mobilePreviewInputCap + 1)
        #expect(boundedCluster.hasSuffix("\u{2026}"))
    }

    private func sshRemoteConfiguration() -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "seepine@192.168.5.20",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64007,
            relayID: "relay-\(UUID().uuidString)",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/cmux-issue-7268-\(UUID().uuidString).sock",
            terminalStartupCommand: "ssh seepine@192.168.5.20"
        )
    }
}
