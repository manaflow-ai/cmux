import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspaceLayoutRootHostTests: XCTestCase {
    private func placeholderPaneSnapshot(_ paneId: PaneID) -> WorkspaceLayoutPaneRenderSnapshot {
        let content = WorkspacePaneContent.placeholder(
            WorkspacePlaceholderPaneContent(
                paneId: paneId,
                onCreateTerminal: {},
                onCreateBrowser: {}
            )
        )
        return WorkspaceLayoutPaneRenderSnapshot(
            paneId: paneId,
            chrome: WorkspaceLayoutPaneChromeSnapshot(
                paneId: paneId,
                tabs: [],
                selectedTabId: nil,
                isFocused: false,
                showSplitButtons: false,
                chromeRevision: 0
            ),
            contentId: paneId.id,
            content: content
        )
    }

    private func renderSnapshot(
        root: WorkspaceLayoutRenderNodeSnapshot,
        localTabDrag: WorkspaceLayoutLocalDragSnapshot? = nil
    ) -> WorkspaceLayoutRenderSnapshot {
        WorkspaceLayoutRenderSnapshot(
            presentation: WorkspaceLayoutPresentationSnapshot(
                appearance: .default,
                isInteractive: true,
                isMinimalMode: false,
                tabShortcutHintsEnabled: false,
                localTabDrag: localTabDrag
            ),
            root: root,
            viewports: []
        )
    }

    func testRootHostStaysVisibleWhenWorkspaceIsNotInputActive() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let visibleInactiveContext = WorkspaceLayoutRenderContext(
            notificationStore: nil,
            isWorkspaceVisible: true,
            isWorkspaceInputActive: false,
            isMinimalMode: false,
            appearance: PanelAppearance(
                dividerColor: .clear,
                unfocusedOverlayNSColor: .clear,
                unfocusedOverlayOpacity: 0
            ),
            workspacePortalPriority: 0,
            usesWorkspacePaneOverlay: false,
            showSplitButtons: workspace.showsSplitButtons
        )
        let renderSnapshot = workspace.makeLayoutRenderSnapshot(context: visibleInactiveContext)
        let rootHost = WorkspaceLayoutRootHostView(
            hostBridge: workspace.layoutInteractionHandlers,
            renderSnapshot: renderSnapshot,
            surfaceRegistry: workspace.surfaceRegistry
        )

        rootHost.isHidden = true
        rootHost.update(
            hostBridge: workspace.layoutInteractionHandlers,
            renderSnapshot: renderSnapshot,
            surfaceRegistry: workspace.surfaceRegistry
        )

        XCTAssertFalse(rootHost.isHidden)
        WorkspaceLayoutNativeHost.dismantleNSView(rootHost, coordinator: ())
    }

    func testSnapshotLocalDragClearPropagatesToPaneHosts() throws {
        let workspace = try XCTUnwrap(TabManager().selectedWorkspace)
        let paneId = PaneID()
        let activeDrag = WorkspaceLayoutLocalDragSnapshot(
            tabId: TabID(id: UUID()),
            sourcePaneId: paneId
        )
        let root = WorkspaceLayoutRenderNodeSnapshot.pane(placeholderPaneSnapshot(paneId))
        let activeSnapshot = renderSnapshot(root: root, localTabDrag: activeDrag)
        let rootHost = WorkspaceLayoutRootHostView(
            hostBridge: workspace.layoutInteractionHandlers,
            renderSnapshot: activeSnapshot,
            surfaceRegistry: workspace.surfaceRegistry
        )
        let paneHost = try XCTUnwrap(rootHost.paneHosts[paneId.id])
        XCTAssertEqual(rootHost.activeLocalTabDrag, activeDrag)
        XCTAssertEqual(paneHost.localTabDrag, activeDrag)

        rootHost.update(
            hostBridge: workspace.layoutInteractionHandlers,
            renderSnapshot: renderSnapshot(root: root),
            surfaceRegistry: workspace.surfaceRegistry
        )

        XCTAssertNil(rootHost.activeLocalTabDrag)
        XCTAssertNil(paneHost.localTabDrag)
        WorkspaceLayoutNativeHost.dismantleNSView(rootHost, coordinator: ())
    }

    func testStaleSplitHostDoesNotReparentCurrentChildren() throws {
        let workspace = try XCTUnwrap(TabManager().selectedWorkspace)
        let leftPaneId = PaneID()
        let rightPaneId = PaneID()
        let splitSnapshot = WorkspaceLayoutSplitRenderSnapshot(
            splitId: UUID(),
            orientation: .horizontal,
            dividerPosition: 0.5,
            animationOrigin: nil,
            first: .pane(placeholderPaneSnapshot(leftPaneId)),
            second: .pane(placeholderPaneSnapshot(rightPaneId))
        )
        let rootSnapshot = renderSnapshot(root: .split(splitSnapshot))
        let rootHost = WorkspaceLayoutRootHostView(
            hostBridge: workspace.layoutInteractionHandlers,
            renderSnapshot: rootSnapshot,
            surfaceRegistry: workspace.surfaceRegistry
        )
        XCTAssertNotNil(rootHost.splitHosts[splitSnapshot.splitId])

        let staleHost = WorkspaceLayoutNativeSplitView(
            snapshot: splitSnapshot,
            hostBridge: workspace.layoutInteractionHandlers,
            rootHost: rootHost,
            firstChild: NSView(),
            secondChild: NSView(),
            appearance: rootSnapshot.presentation.appearance
        )
        let currentOwner = NSView()
        let firstChild = NSView()
        let secondChild = NSView()
        currentOwner.addSubview(firstChild)
        currentOwner.addSubview(secondChild)

        staleHost.update(
            snapshot: splitSnapshot,
            hostBridge: workspace.layoutInteractionHandlers,
            rootHost: rootHost,
            firstChild: firstChild,
            secondChild: secondChild,
            appearance: rootSnapshot.presentation.appearance
        )

        XCTAssertTrue(firstChild.superview === currentOwner)
        XCTAssertTrue(secondChild.superview === currentOwner)
        staleHost.removeAllChildren()
        WorkspaceLayoutNativeHost.dismantleNSView(rootHost, coordinator: ())
    }
}
