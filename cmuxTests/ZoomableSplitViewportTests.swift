import AppKit
import Bonsplit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Zoomable split viewport")
struct ZoomableSplitViewportTests {
    @Test func zoomableSplitsUseDirectTerminalHosting() {
        #expect(WorkspaceLayoutMode.zoomableSplits.usesDirectTerminalHosting)
        #expect(WorkspaceLayoutMode.canvas.usesDirectTerminalHosting)
        #expect(!WorkspaceLayoutMode.splits.usesDirectTerminalHosting)
    }

    @Test func zoomOutClampsAtExactFit() {
        let root = makeRoot()
        defer { root.teardown() }

        root.setViewport(center: CGPoint(x: 400, y: 250), magnification: 0.25)

        #expect(abs(root.currentMagnification - 1.0) < 0.0001)
        root.zoom(by: 0.5)
        #expect(abs(root.currentMagnification - 1.0) < 0.0001)
    }

    @Test func zoomInRemainsAvailableBeyondFit() {
        let root = makeRoot()
        defer { root.teardown() }

        root.zoom(by: 1.25)

        #expect(abs(root.currentMagnification - 1.25) < 0.0001)
    }

    @Test func pointerFocusResolvesPanelFromSplitSnapshot() {
        let leftTab = UUID()
        let rightTab = UUID()
        let leftPanel = UUID()
        let rightPanel = UUID()
        let snapshot = LayoutSnapshot(
            containerFrame: PixelRect(x: 20, y: 40, width: 300, height: 120),
            panes: [
                PaneGeometry(
                    paneId: UUID().uuidString,
                    frame: PixelRect(x: 20, y: 40, width: 100, height: 120),
                    selectedTabId: leftTab.uuidString,
                    tabIds: [leftTab.uuidString]
                ),
                PaneGeometry(
                    paneId: UUID().uuidString,
                    frame: PixelRect(x: 120, y: 40, width: 200, height: 120),
                    selectedTabId: rightTab.uuidString,
                    tabIds: [rightTab.uuidString]
                ),
            ],
            focusedPaneId: nil,
            timestamp: 0
        )
        let panelsByTab = [
            TabID(uuid: leftTab): leftPanel,
            TabID(uuid: rightTab): rightPanel,
        ]

        let resolved = ZoomableSplitRootView.selectedPanelId(
            atDocumentPoint: CGPoint(x: 140, y: 60),
            in: snapshot,
            panelIdFromSurfaceId: { panelsByTab[$0] }
        )

        #expect(resolved == rightPanel)
        #expect(ZoomableSplitRootView.selectedPanelId(
            atDocumentPoint: CGPoint(x: 310, y: 60),
            in: snapshot,
            panelIdFromSurfaceId: { panelsByTab[$0] }
        ) == nil)
    }

    private func makeRoot() -> ZoomableSplitRootView {
        let root = ZoomableSplitRootView(
            workspace: Workspace(title: "Zoomable split tests"),
            isWorkspaceInputActive: false,
            content: AnyView(Color.clear)
        )
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        root.frame = host.bounds
        host.addSubview(root)
        host.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        return root
    }
}
