import CMUXAgentLaunch
import CmuxControlSocket
import CmuxCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension SessionSnapshotImportTrustTests {
    @Test("a layout over the node cap with distinct leaves is cut, and its panels still restore")
    func nodeCapWithDistinctLeavesKeepsPanels() throws {
        let panels = (0..<SessionPersistencePolicy.maxPanelsPerWorkspace).map { _ in
            Self.panel(terminal: SessionTerminalPanelSnapshot())
        }
        // Leaves that name no panel still cost nodes. The real panels sit
        // after the cap, so only the fallback can keep them.
        let unknownLeaves = (0..<SessionPersistencePolicy.maxLayoutNodes).map { _ in UUID() }
        var workspace = Self.workspace(
            panels: panels,
            layout: Self.balancedLayout(unknownLeaves + panels.map(\.id))
        )
        let original = Self.finish(workspace: &workspace, workspaceHasRemote: false)

        let (restored, report) = SessionSnapshotImportTrust.snapshotForRestore(
            original,
            source: Self.channelImport
        )

        let layout = try #require(restored.windows.first?.tabManager.workspaces.first?.layout)
        #expect(Self.layoutNodeCount(layout) == 1)
        #expect(Set(Self.layoutPanelIDs(layout)) == Set(panels.map(\.id)))
        #expect(Self.layoutPanelIDs(layout).count == panels.count)
        #expect(report.droppedPanelCount == 0)
    }

    @Test("the layout node budget is shared across workspaces")
    func layoutNodeBudgetIsGlobal() throws {
        // Each workspace's layout is 5,999 nodes, well under the cap alone;
        // three of them are not. The third must fall back.
        func workspace() -> SessionWorkspaceSnapshot {
            let panels = (0..<400).map { _ in Self.panel(terminal: SessionTerminalPanelSnapshot()) }
            let unknownLeaves = (0..<2_600).map { _ in UUID() }
            return Self.workspace(panels: panels, layout: Self.balancedLayout(unknownLeaves + panels.map(\.id)))
        }
        var first = workspace()
        var original = Self.finish(workspace: &first, workspaceHasRemote: false)
        original.windows[0].tabManager.workspaces = [first, workspace(), workspace()]

        let (restored, _) = SessionSnapshotImportTrust.snapshotForRestore(
            original,
            source: Self.channelImport
        )

        let workspaces = try #require(restored.windows.first?.tabManager.workspaces)
        #expect(workspaces.count == 3)
        #expect(Self.layoutNodeCount(workspaces[0].layout) > 1)
        #expect(Self.layoutPanelIDs(workspaces[0].layout).count == 400)
        #expect(Self.layoutNodeCount(workspaces[2].layout) == 1)
        #expect(Self.layoutPanelIDs(workspaces[2].layout).count == 400)
    }

    @Test("trusted restore deduplicates repeated panel IDs in a wide split layout")
    func trustedRestoreDeduplicatesWideLayout() throws {
        let panel = Self.panel(terminal: SessionTerminalPanelSnapshot())
        var workspace = SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            customTitle: "Deep",
            customColor: nil,
            isPinned: false,
            currentDirectory: "/tmp/project",
            focusedPanelId: panel.id,
            // N leaves need 2N - 1 nodes, so this crosses the node cap.
            layout: Self.repeatedLayout(SessionPersistencePolicy.maxLayoutNodes, panelID: panel.id),
            panels: [panel],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )
        let original = Self.finish(workspace: &workspace, workspaceHasRemote: false)

        let (restored, _) = SessionSnapshotImportTrust.snapshotForRestore(
            original,
            source: Self.channelImport
        )
        let layout = try #require(restored.windows.first?.tabManager.workspaces.first?.layout)
        #expect(Self.layoutNodeCount(layout) <= SessionPersistencePolicy.maxLayoutNodes)
        #expect(Self.layoutPanelIDs(layout) == [panel.id])
    }

    @Test("trusted restore deduplicates fallback panel IDs before layout construction")
    func trustedRestoreDeduplicatesFallbackPanelIDs() throws {
        let panel = Self.panel(terminal: SessionTerminalPanelSnapshot())
        var workspace = SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            customTitle: "Fallback duplicates",
            customColor: nil,
            isPinned: false,
            currentDirectory: "/tmp/project",
            focusedPanelId: panel.id,
            layout: .split(SessionSplitLayoutSnapshot(
                orientation: .horizontal,
                dividerPosition: 0.5,
                first: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
                second: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil))
            )),
            panels: Array(repeating: panel, count: 64),
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )
        let original = Self.finish(workspace: &workspace, workspaceHasRemote: false)

        let (restored, _) = SessionSnapshotImportTrust.snapshotForRestore(
            original,
            source: Self.channelImport
        )
        let layout = try #require(restored.windows.first?.tabManager.workspaces.first?.layout)
        #expect(Self.layoutPanelIDs(layout) == [panel.id])
    }

    @Test("trusted restore drops duplicate panel records before runtime admission")
    func trustedRestoreDropsDuplicatePanelRecords() throws {
        let panel = Self.panel(terminal: SessionTerminalPanelSnapshot())
        var duplicate = panel
        duplicate.title = "duplicate record"
        var workspace = Self.workspace(
            panels: [panel, duplicate],
            layout: .pane(SessionPaneLayoutSnapshot(
                panelIds: [panel.id, duplicate.id],
                selectedPanelId: duplicate.id
            ))
        )
        let original = Self.finish(workspace: &workspace, workspaceHasRemote: false)

        let (restored, report) = SessionSnapshotImportTrust.snapshotForRestore(
            original,
            source: Self.channelImport
        )

        let panels = try #require(restored.windows.first?.tabManager.workspaces.first?.panels)
        #expect(panels.map(\.id) == [panel.id])
        #expect(panels.first?.title == panel.title)
        #expect(report.droppedPanelCount == 1)
    }

    @Test("trusted restore bounds a skewed deep layout without overflowing the stack")
    func trustedRestoreBoundsSkewedDeepLayout() throws {
        let panel = Self.panel(terminal: SessionTerminalPanelSnapshot())
        let empty = SessionWorkspaceLayoutSnapshot.pane(
            SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)
        )
        var layout = SessionWorkspaceLayoutSnapshot.pane(
            SessionPaneLayoutSnapshot(panelIds: [panel.id], selectedPanelId: panel.id)
        )
        // A skewed tree is the shape that defeats a depth guard implemented
        // with recursive descent: it reaches the guard only after consuming
        // one native stack frame per level. Keep this above the restore depth
        // cap while below Swift's recursive enum-destruction limit; production
        // file imports also reject deeper JSON before Codable materialization.
        for _ in 0..<600 {
            layout = .split(SessionSplitLayoutSnapshot(
                orientation: .horizontal,
                dividerPosition: 0.5,
                first: layout,
                second: empty
            ))
        }
        var workspace = SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            customTitle: "Deep skew",
            customColor: nil,
            isPinned: false,
            currentDirectory: "/tmp/project",
            focusedPanelId: panel.id,
            layout: layout,
            panels: [panel],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )
        let original = Self.finish(workspace: &workspace, workspaceHasRemote: false)

        let (restored, _) = SessionSnapshotImportTrust.snapshotForRestore(
            original,
            source: Self.channelImport
        )
        let restoredLayout = try #require(
            restored.windows.first?.tabManager.workspaces.first?.layout
        )
        #expect(Self.layoutNodeCount(restoredLayout) <= SessionPersistencePolicy.maxLayoutNodes)
        #expect(Self.layoutPanelIDs(restoredLayout) == [panel.id])
    }

    @Test("a panel cut off below the depth cap is reported as dropped")
    func depthCapReportsCutPanels() throws {
        let kept = Self.panel(terminal: SessionTerminalPanelSnapshot())
        let cut = Self.panel(terminal: SessionTerminalPanelSnapshot())
        var layout = SessionWorkspaceLayoutSnapshot.pane(
            SessionPaneLayoutSnapshot(panelIds: [cut.id], selectedPanelId: cut.id)
        )
        for _ in 0..<(SessionPersistencePolicy.maxLayoutDepth + 8) {
            layout = .split(SessionSplitLayoutSnapshot(
                orientation: .horizontal,
                dividerPosition: 0.5,
                first: layout,
                second: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil))
            ))
        }
        layout = .split(SessionSplitLayoutSnapshot(
            orientation: .vertical,
            dividerPosition: 0.5,
            first: .pane(SessionPaneLayoutSnapshot(panelIds: [kept.id], selectedPanelId: kept.id)),
            second: layout
        ))
        var workspace = SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            customTitle: "Cut subtree",
            customColor: nil,
            isPinned: false,
            currentDirectory: "/tmp/project",
            focusedPanelId: kept.id,
            layout: layout,
            panels: [kept, cut],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )
        let original = Self.finish(workspace: &workspace, workspaceHasRemote: false)

        let (restored, report) = SessionSnapshotImportTrust.snapshotForRestore(
            original,
            source: Self.channelImport
        )
        let restoredLayout = try #require(restored.windows.first?.tabManager.workspaces.first?.layout)
        #expect(Self.layoutPanelIDs(restoredLayout) == [kept.id])
        #expect(report.droppedPanelCount == 1)
    }

    @Test("trusted restore returns an ordinary split layout and dock unchanged")
    func trustedRestoreKeepsOrdinaryLayoutUnchanged() throws {
        let panels = (0..<6).map { _ in Self.panel(terminal: SessionTerminalPanelSnapshot()) }
        let dockPanels = (0..<2).map { _ in Self.panel(terminal: SessionTerminalPanelSnapshot()) }
        func pane(_ indices: [Int], selected: Int) -> SessionWorkspaceLayoutSnapshot {
            .pane(SessionPaneLayoutSnapshot(
                panelIds: indices.map { panels[$0].id },
                selectedPanelId: panels[selected].id
            ))
        }
        // Mixed orientations, uneven ratios, multi-tab panes with a
        // non-first selection: the shapes a real session saves.
        let layout = SessionWorkspaceLayoutSnapshot.split(SessionSplitLayoutSnapshot(
            orientation: .horizontal,
            dividerPosition: 0.3,
            first: pane([0, 1], selected: 1),
            second: .split(SessionSplitLayoutSnapshot(
                orientation: .vertical,
                dividerPosition: 0.65,
                first: pane([2], selected: 2),
                second: .split(SessionSplitLayoutSnapshot(
                    orientation: .horizontal,
                    dividerPosition: 0.5,
                    first: pane([3, 4], selected: 4),
                    second: pane([5], selected: 5)
                ))
            ))
        ))
        var workspace = SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            customTitle: "Ordinary",
            customColor: nil,
            isPinned: false,
            currentDirectory: "/tmp/project",
            focusedPanelId: panels[4].id,
            layout: layout,
            panels: panels,
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )
        workspace.dock = SessionSplitContainerSnapshot(
            focusedPanelId: dockPanels[1].id,
            layout: .split(SessionSplitLayoutSnapshot(
                orientation: .vertical,
                dividerPosition: 0.4,
                first: .pane(SessionPaneLayoutSnapshot(panelIds: [dockPanels[0].id], selectedPanelId: dockPanels[0].id)),
                second: .pane(SessionPaneLayoutSnapshot(panelIds: [dockPanels[1].id], selectedPanelId: dockPanels[1].id))
            )),
            panels: dockPanels
        )
        let original = Self.finish(workspace: &workspace, workspaceHasRemote: false)

        let (restored, report) = SessionSnapshotImportTrust.snapshotForRestore(
            original,
            source: Self.channelImport
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(restored) == encoder.encode(original))
        #expect(report.droppedPanelCount == 0)
        #expect(report.droppedWorkspaceCount == 0)
        #expect(report.droppedWindowCount == 0)
    }

    @Test("trusted restore keeps a valid sibling after a capped empty subtree")
    func trustedRestoreKeepsSiblingAfterCappedEmptySubtree() throws {
        let panel = Self.panel(terminal: SessionTerminalPanelSnapshot())
        var empty = SessionWorkspaceLayoutSnapshot.pane(
            SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)
        )
        for _ in 0..<600 {
            empty = .split(SessionSplitLayoutSnapshot(
                orientation: .horizontal,
                dividerPosition: 0.5,
                first: empty,
                second: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil))
            ))
        }
        var workspace = SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            customTitle: "Capped empty subtree",
            customColor: nil,
            isPinned: false,
            currentDirectory: "/tmp/project",
            focusedPanelId: panel.id,
            layout: .split(SessionSplitLayoutSnapshot(
                orientation: .horizontal,
                dividerPosition: 0.5,
                first: empty,
                second: .pane(SessionPaneLayoutSnapshot(panelIds: [panel.id], selectedPanelId: panel.id))
            )),
            panels: [panel],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )
        let original = Self.finish(workspace: &workspace, workspaceHasRemote: false)

        let (restored, _) = SessionSnapshotImportTrust.snapshotForRestore(
            original,
            source: Self.channelImport
        )
        let restoredLayout = try #require(
            restored.windows.first?.tabManager.workspaces.first?.layout
        )
        #expect(Self.layoutPanelIDs(restoredLayout) == [panel.id])
        guard case .pane(let pane) = restoredLayout else {
            Issue.record("capped empty subtree should collapse to the valid sibling pane")
            return
        }
        #expect(pane.panelIds == [panel.id])
    }
}
