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
    @Test("untrusted imports clamp structural fan-out before restore")
    func fileImportClampsStructuralFanOut() throws {
        var snapshot = Self.snapshot(terminal: SessionTerminalPanelSnapshot())
        var workspace = try #require(snapshot.windows[0].tabManager.workspaces.first)
        let panelCount = SessionPersistencePolicy.maxPanelsPerWorkspace + 17
        workspace.panels = (0..<panelCount).map { _ in
            Self.panel(terminal: SessionTerminalPanelSnapshot())
        }
        workspace.focusedPanelId = workspace.panels[0].id
        snapshot.windows[0].tabManager.workspaces[0] = workspace

        let (restored, _) = SessionSnapshotImportTrust.snapshotForRestore(
            snapshot,
            source: Self.fileImport
        )
        let restoredWorkspace = try #require(
            restored.windows.first?.tabManager.workspaces.first
        )
        #expect(restoredWorkspace.panels.count == SessionPersistencePolicy.maxPanelsPerWorkspace)
    }

    @Test("imported panel fan-out has a global budget")
    func importedPanelFanOutIsBoundedGlobally() throws {
        var original = Self.snapshot(terminal: SessionTerminalPanelSnapshot())
        original.windows[0].tabManager.workspaces = (0..<9).map { _ in
            let panels = (0..<(SessionPersistencePolicy.maxPanelsPerWorkspace + 1)).map { panelIndex in
                Self.panel(terminal: SessionTerminalPanelSnapshot())
            }
            return Self.workspace(panels: panels, layout: Self.balancedLayout(panels.map(\.id)))
        }

        let (restored, report) = SessionSnapshotImportTrust.snapshotForRestore(
            original,
            source: Self.fileImport
        )

        #expect(
            restored.windows.first?.tabManager.workspaces.reduce(0) { $0 + $1.panels.count }
                == SessionPersistencePolicy.maxPanelsPerSnapshot
        )
        #expect(restored.windows.first?.tabManager.workspaces.count == 8)
        // Every panel that won't restore is counted, including the ones the
        // per-workspace cap cut: 9 x 4,097 offered, 4,096 kept.
        #expect(report.droppedPanelCount == 9 * (SessionPersistencePolicy.maxPanelsPerSnapshot + 1)
            - SessionPersistencePolicy.maxPanelsPerSnapshot)
    }

    @Test("panels the per-workspace cap cuts are reported as dropped")
    func perWorkspaceCapCountsDroppedPanels() throws {
        let panels = (0..<(SessionPersistencePolicy.maxPanelsPerWorkspace + 88)).map { _ in
            Self.panel(terminal: SessionTerminalPanelSnapshot())
        }
        var workspace = Self.workspace(panels: panels, layout: Self.balancedLayout(panels.map(\.id)))
        let original = Self.finish(workspace: &workspace, workspaceHasRemote: false)

        let (restored, report) = SessionSnapshotImportTrust.snapshotForRestore(
            original,
            source: Self.channelImport
        )

        #expect(restored.windows.first?.tabManager.workspaces.first?.panels.count
            == SessionPersistencePolicy.maxPanelsPerWorkspace)
        // Without this count no session.restore.bounded breadcrumb is written.
        #expect(report.droppedPanelCount == 88)
    }

    @Test("workspaces emptied by the global panel budget are dropped")
    func globalPanelBudgetDropsEmptyWorkspaces() throws {
        var original = Self.snapshot(terminal: SessionTerminalPanelSnapshot())
        original.windows[0].tabManager.workspaces = (0..<SessionPersistencePolicy.maxWorkspacesPerWindow).map { _ in
            let panels = (0..<SessionPersistencePolicy.maxPanelsPerWorkspace).map { _ in
                Self.panel(terminal: SessionTerminalPanelSnapshot())
            }
            return Self.workspace(panels: panels, layout: Self.balancedLayout(panels.map(\.id)))
        }

        let (restored, report) = SessionSnapshotImportTrust.snapshotForRestore(
            original,
            source: Self.channelImport
        )

        let workspaces = try #require(restored.windows.first?.tabManager.workspaces)
        #expect(workspaces.count == SessionPersistencePolicy.maxPanelsPerSnapshot
            / SessionPersistencePolicy.maxPanelsPerWorkspace)
        #expect(report.droppedWorkspaceCount ==
            SessionPersistencePolicy.maxWorkspacesPerWindow - workspaces.count)
    }

    @Test("trusted restore preserves a window containing only an empty pinned group")
    func emptyPinnedGroupWindowSurvivesBounding() throws {
        let group = SessionWorkspaceGroupSnapshot(
            id: UUID(), name: "Pinned", isCollapsed: false,
            anchorIsEmpty: true, isPinned: true
        )
        let window = SessionWindowSnapshot(
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(
                selectedWorkspaceIndex: nil,
                workspaces: [],
                workspaceGroups: [group]
            ),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 240)
        )
        let original = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 0,
            windows: [window]
        )

        let (restored, _) = SessionSnapshotImportTrust.snapshotForRestore(
            original,
            source: Self.channelImport
        )

        #expect(restored.windows.count == 1)
        #expect(restored.windows.first?.tabManager.workspaceGroups == [group])
    }

    @Test("ordinary empty workspaces preserve group anchors and selection", arguments: [false, true])
    func ordinaryEmptyWorkspaceKeepsGroupAnchor(hasWorkspaceIDs: Bool) throws {
        let groupID = UUID()
        let anchorID: UUID? = hasWorkspaceIDs ? UUID() : nil
        var empty = Self.workspace(panels: [], layout: .pane(
            SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)
        ))
        empty.workspaceId = hasWorkspaceIDs ? UUID() : nil
        empty.groupId = groupID
        var anchor = Self.workspace(
            panels: [Self.panel(terminal: SessionTerminalPanelSnapshot())],
            layout: nil
        )
        anchor.workspaceId = anchorID
        anchor.groupId = groupID
        var trailing = Self.workspace(
            panels: [Self.panel(terminal: SessionTerminalPanelSnapshot())],
            layout: nil
        )
        trailing.workspaceId = hasWorkspaceIDs ? UUID() : nil
        trailing.groupId = groupID
        let group = SessionWorkspaceGroupSnapshot(
            id: groupID, name: "Group", isCollapsed: false,
            anchorWorkspaceId: anchorID, anchorMemberIndex: 1, isPinned: true
        )
        let window = SessionWindowSnapshot(
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(
                selectedWorkspaceIndex: 1,
                workspaces: [empty, anchor, trailing],
                workspaceGroups: [group]
            ),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 240)
        )
        let original = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 0,
            windows: [window]
        )

        let (restored, _) = SessionSnapshotImportTrust.snapshotForRestore(
            original,
            source: Self.channelImport
        )
        let restoredGroup = try #require(restored.windows.first?.tabManager.workspaceGroups?.first)
        #expect(restoredGroup.anchorMemberIndex == 1)
        #expect(restored.windows.first?.tabManager.workspaces.count == 3)
        #expect(restored.windows.first?.tabManager.selectedWorkspaceIndex == 1)
        #expect(restoredGroup.anchorWorkspaceId == anchorID)
    }

    @Test("crash and phantom windows are pruned before the window cap is spent")
    func importPrunesPhantomWindowsBeforeBounding() throws {
        var workspace = Self.workspace(
            panels: [Self.panel(terminal: SessionTerminalPanelSnapshot())],
            layout: nil
        )
        var original = Self.finish(workspace: &workspace, workspaceHasRemote: false)
        let realWindow = try #require(original.windows.first)
        let phantom = SessionWindowSnapshot(
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: nil, workspaces: []),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 240)
        )
        original.windows = Array(repeating: phantom, count: SessionPersistencePolicy.maxWindowsPerSnapshot)
            + [realWindow]

        let (restored, report) = SessionSnapshotImportTrust.snapshotForRestore(
            original,
            source: Self.fileImport
        )

        #expect(restored.windows.count == 1)
        #expect(restored.windows.first?.tabManager.workspaces.count == 1)
        #expect(report.droppedWindowCount == 0)
    }

    @Test("trusted restore applies the global panel budget without stripping commands")
    func trustedRestoreBoundsTopology() throws {
        var original = Self.snapshot(terminal: Self.untrustedTerminal())
        original.windows[0].tabManager.workspaces = (0..<9).map { _ in
            let panels = (0..<(SessionPersistencePolicy.maxPanelsPerWorkspace + 1)).map { _ in
                Self.panel(terminal: Self.untrustedTerminal())
            }
            return Self.workspace(panels: panels, layout: Self.balancedLayout(panels.map(\.id)))
        }

        let (restored, report) = SessionSnapshotImportTrust.snapshotForRestore(
            original,
            source: Self.channelImport
        )

        let restoredWorkspaces = try #require(restored.windows.first?.tabManager.workspaces)
        #expect(restoredWorkspaces.count == 8)
        #expect(restoredWorkspaces.reduce(0) { $0 + $1.panels.count } ==
            SessionPersistencePolicy.maxPanelsPerSnapshot)
        #expect(report.droppedPanelCount == 9 * (SessionPersistencePolicy.maxPanelsPerSnapshot + 1)
            - SessionPersistencePolicy.maxPanelsPerSnapshot)
        #expect(restoredWorkspaces.first?.panels.first?.terminal?.resumeBinding?.command != nil)
    }

    @Test("dock-only workspaces charge their fallback main terminal to the panel budget")
    func dockOnlyWorkspaceBudgetIncludesFallbacks() throws {
        let panels = (0..<SessionPersistencePolicy.maxPanelsPerWorkspace).map { _ in
            Self.panel(terminal: SessionTerminalPanelSnapshot())
        }
        var workspace = Self.workspace(panels: [], layout: nil)
        workspace.dock = SessionSplitContainerSnapshot(
            focusedPanelId: panels.first?.id,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: panels.map(\.id), selectedPanelId: panels.first?.id)),
            panels: panels
        )
        var original = Self.finish(workspace: &workspace, workspaceHasRemote: false)
        original.windows[0].tabManager.workspaces = (0..<9).map { _ in
            var copy = workspace
            let panels = (0..<SessionPersistencePolicy.maxPanelsPerWorkspace).map { _ in
                Self.panel(terminal: SessionTerminalPanelSnapshot())
            }
            copy.dock?.panels = panels
            copy.dock?.focusedPanelId = panels.first?.id
            copy.dock?.layout = .pane(SessionPaneLayoutSnapshot(panelIds: panels.map(\.id), selectedPanelId: panels.first?.id))
            return copy
        }
        let (restored, _) = SessionSnapshotImportTrust.snapshotForRestore(original, source: Self.channelImport)
        let workspaces = try #require(restored.windows.first?.tabManager.workspaces)
        let runtimePanelCount = workspaces.reduce(0) {
            $0 + max(1, $1.panels.count) + ($1.dock?.panels.count ?? 0)
        }
        #expect(runtimePanelCount == SessionPersistencePolicy.maxPanelsPerSnapshot)
    }

    @Test("an exhausted Dock remains explicitly empty rather than returning to configuration seeding")
    func exhaustedDockKeepsExplicitEmptySnapshot() throws {
        let panels = (0..<SessionPersistencePolicy.maxPanelsPerWorkspace).map { _ in
            Self.panel(terminal: SessionTerminalPanelSnapshot())
        }
        var workspace = Self.workspace(panels: panels, layout: nil)
        var original = Self.finish(workspace: &workspace, workspaceHasRemote: false)
        original.windows[0].tabManager.workspaces = Array(repeating: workspace, count: 8)
        original.windows[0].dock = SessionSplitContainerSnapshot(
            focusedPanelId: panels[0].id,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [panels[0].id], selectedPanelId: panels[0].id)),
            panels: [panels[0]]
        )
        let (restored, _) = SessionSnapshotImportTrust.snapshotForRestore(original, source: Self.channelImport)
        let dock = try #require(restored.windows.first?.dock)
        #expect(dock.panels.isEmpty)
        #expect(Self.layoutPanelIDs(dock.layout).isEmpty)
    }

}
