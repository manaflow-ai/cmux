import XCTest
import CoreGraphics
import SwiftUI
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class WorkspaceContentViewVisibilityTests: XCTestCase {
    private func terminalLifecycleFacts(
        isVisibleInUI: Bool,
        isWindowed: Bool,
        hasUsableGeometry: Bool,
        hasRuntime: Bool,
        hasPresentedFrame: Bool,
        isActive: Bool
    ) -> WorkspaceSurfaceLifecycleFacts {
        WorkspaceSurfaceLifecycleFacts(
            TerminalViewportLifecycleFacts(
                isVisibleInUI: isVisibleInUI,
                isWindowed: isWindowed,
                hasUsableGeometry: hasUsableGeometry,
                hasRuntime: hasRuntime,
                hasPresentedFrame: hasPresentedFrame,
                isActive: isActive
            )
        )
    }

    @MainActor
    private func terminalViewport(
        paneId: PaneID,
        surfaceId: UUID
    ) -> WorkspaceLayoutViewportSnapshot {
        let content = WorkspacePaneContent.terminal(
            WorkspaceTerminalPaneContent(
                surfaceId: surfaceId,
                isFocused: true,
                isVisibleInUI: true,
                isSplit: false,
                appearance: WorkspaceTerminalPaneAppearance(PanelAppearance(
                    dividerColor: .clear,
                    unfocusedOverlayNSColor: .clear,
                    unfocusedOverlayOpacity: 0
                )),
                hasUnreadNotification: false,
                onFocus: {},
                onTriggerFlash: {}
            )
        )
        return WorkspaceLayoutViewportSnapshot(
            paneId: paneId,
            contentId: surfaceId,
            mountIdentity: content.mountIdentity(contentId: surfaceId),
            content: content,
            frame: CGRect(x: 0, y: 0, width: 320, height: 240)
        )
    }

    @MainActor
    private func browserViewport(
        paneId: PaneID,
        surfaceId: UUID
    ) -> WorkspaceLayoutViewportSnapshot {
        let content = WorkspacePaneContent.browser(
            WorkspaceBrowserPaneContent(
                surfaceId: surfaceId,
                paneId: paneId,
                isFocused: true,
                isVisibleInUI: true,
                prefersLocalInlineHosting: true,
                portalPriority: 0,
                onRequestPanelFocus: {}
            )
        )
        return WorkspaceLayoutViewportSnapshot(
            paneId: paneId,
            contentId: surfaceId,
            mountIdentity: content.mountIdentity(contentId: surfaceId),
            content: content,
            frame: CGRect(x: 0, y: 0, width: 320, height: 240)
        )
    }

    @MainActor
    func testDismantlingWorkspaceLayoutRootHostHidesBrowserPortal() throws {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let paneId = workspace.focusedPaneId,
              let browserPanel = workspace.createBrowserPanel(inPane: paneId, focus: true) else {
            XCTFail("Expected focused workspace and browser panel")
            return
        }

        let renderContext = WorkspaceLayoutRenderContext(
            notificationStore: nil,
            isWorkspaceVisible: true,
            isWorkspaceInputActive: true,
            isMinimalMode: false,
            appearance: PanelAppearance(
                dividerColor: .clear,
                unfocusedOverlayNSColor: .clear,
                unfocusedOverlayOpacity: 0
            ),
            workspacePortalPriority: 1,
            usesWorkspacePaneOverlay: false,
            showSplitButtons: workspace.showsSplitButtons
        )
        let renderSnapshot = workspace.makeLayoutRenderSnapshot(context: renderContext)
        let rootHost = WorkspaceLayoutRootHostView(
            hostBridge: workspace.layoutInteractionHandlers,
            renderSnapshot: renderSnapshot,
            surfaceRegistry: workspace.surfaceRegistry
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let anchor = NSView(frame: NSRect(x: 40, y: 36, width: 220, height: 150))
        window.contentView?.addSubview(anchor)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()

        BrowserWindowPortalRegistry.bind(
            webView: browserPanel.webView,
            to: anchor,
            visibleInUI: true,
            zPriority: 1
        )
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        XCTAssertEqual(BrowserWindowPortalRegistry.debugSnapshot(for: browserPanel.webView)?.visibleInUI, true)

        WorkspaceLayoutNativeHost.dismantleNSView(rootHost, coordinator: ())

        XCTAssertEqual(BrowserWindowPortalRegistry.debugSnapshot(for: browserPanel.webView)?.visibleInUI, false)
        let staleHostId = ObjectIdentifier(NSView())
        XCTAssertFalse(
            browserPanel.claimPortalHost(
                hostId: staleHostId,
                paneId: paneId,
                inWindow: true,
                bounds: CGRect(x: 0, y: 0, width: 220, height: 150),
                reason: "unitTest.staleAfterWorkspaceRemoval"
            ),
            "Workspace host removal should suspend stale portal-host claims"
        )
        browserPanel.resumePortalHosting(reason: "unitTest.visibleReattach")
        XCTAssertTrue(
            browserPanel.claimPortalHost(
                hostId: staleHostId,
                paneId: paneId,
                inWindow: true,
                bounds: CGRect(x: 0, y: 0, width: 220, height: 150),
                reason: "unitTest.visibleReattach"
            ),
            "Visible reattach should resume portal-host claims"
        )

        BrowserWindowPortalRegistry.detach(webView: browserPanel.webView)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        window.orderOut(nil)
    }

    func testPanelVisibleInUIReturnsFalseWhenWorkspaceHidden() {
        XCTAssertFalse(
            WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: false,
                isSelectedInPane: true,
                isFocused: true
            )
        )
    }

    func testPanelVisibleInUIReturnsTrueForSelectedPanel() {
        XCTAssertTrue(
            WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: true,
                isSelectedInPane: true,
                isFocused: false
            )
        )
    }

    func testPanelVisibleInUIReturnsTrueForFocusedPanelDuringTransientSelectionGap() {
        XCTAssertTrue(
            WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: true,
                isSelectedInPane: false,
                isFocused: true
            )
        )
    }

    func testPanelVisibleInUIReturnsFalseWhenNeitherSelectedNorFocused() {
        XCTAssertFalse(
            WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: true,
                isSelectedInPane: false,
                isFocused: false
            )
        )
    }

    func testPanelPresentationFactsDeriveVisibilityAndResponderIntent() {
        let paneId = PaneID(id: UUID())
        let panelId = UUID()

        let visibleFocused = WorkspacePanelPresentationFacts(
            paneId: paneId,
            panelId: panelId,
            isWorkspaceVisible: true,
            isWorkspaceInputActive: true,
            isSelectedInPane: true,
            isFocused: true
        )
        XCTAssertTrue(visibleFocused.isVisibleInUI)
        XCTAssertTrue(visibleFocused.wantsFirstResponder)

        let hidden = WorkspacePanelPresentationFacts(
            paneId: paneId,
            panelId: panelId,
            isWorkspaceVisible: false,
            isWorkspaceInputActive: true,
            isSelectedInPane: true,
            isFocused: true
        )
        XCTAssertFalse(hidden.isVisibleInUI)
        XCTAssertFalse(hidden.wantsFirstResponder)
    }

    func testSelectedIndicatorUsesAccentOnlyForFocusedPane() {
        let appearance = WorkspaceLayoutConfiguration.Appearance(
            chromeColors: .init(backgroundHex: "#272822")
        )

        let focused = TabBarColors.nsColorSelectedIndicator(for: appearance, focused: true).usingColorSpace(.sRGB)!
        let unfocused = TabBarColors.nsColorSelectedIndicator(for: appearance, focused: false).usingColorSpace(.sRGB)!
        let inactive = TabBarColors.nsColorInactiveText(for: appearance).usingColorSpace(.sRGB)!
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)!
        let expectedInactiveIndicator = NSColor.white.withAlphaComponent(0.35).usingColorSpace(.sRGB)!

        XCTAssertEqual(focused.redComponent, accent.redComponent, accuracy: 0.01)
        XCTAssertEqual(focused.greenComponent, accent.greenComponent, accuracy: 0.01)
        XCTAssertEqual(focused.blueComponent, accent.blueComponent, accuracy: 0.01)

        XCTAssertEqual(unfocused.redComponent, expectedInactiveIndicator.redComponent, accuracy: 0.01)
        XCTAssertEqual(unfocused.greenComponent, expectedInactiveIndicator.greenComponent, accuracy: 0.01)
        XCTAssertEqual(unfocused.blueComponent, expectedInactiveIndicator.blueComponent, accuracy: 0.01)
        XCTAssertEqual(unfocused.alphaComponent, expectedInactiveIndicator.alphaComponent, accuracy: 0.01)
        XCTAssertNotEqual(unfocused.redComponent, accent.redComponent, accuracy: 0.05)
        XCTAssertNotEqual(unfocused.alphaComponent, inactive.alphaComponent, accuracy: 0.05)
    }

    func testTerminalPresentationTransitionResolverEmitsOnlyEdgeOperations() {
        let hidden = WorkspaceTerminalPresentationState(isVisibleInUI: false, isActive: false)
        let visibleFocused = WorkspaceTerminalPresentationState(isVisibleInUI: true, isActive: true)

        XCTAssertEqual(
            WorkspaceTerminalPresentationTransitionResolver.operations(
                previous: hidden,
                next: visibleFocused
            ),
            [.setVisibleInUI(true), .setActive(true), .requestFirstResponderReconcile]
        )

        XCTAssertEqual(
            WorkspaceTerminalPresentationTransitionResolver.operations(
                previous: visibleFocused,
                next: visibleFocused
            ),
            []
        )

        XCTAssertEqual(
            WorkspaceTerminalPresentationTransitionResolver.operations(
                previous: visibleFocused,
                next: hidden
            ),
            [.setVisibleInUI(false), .setActive(false)]
        )
    }

    func testTmuxWorkspacePaneOverlayRectReturnsMatchingPaneFrame() {
        let paneID = PaneID(id: UUID())
        let snapshot = LayoutSnapshot(
            containerFrame: PixelRect(x: 200, y: 32, width: 1200, height: 800),
            panes: [
                PaneGeometry(
                    paneId: paneID.id.uuidString,
                    frame: PixelRect(x: 877.5, y: 32, width: 500, height: 320),
                    selectedTabId: nil,
                    tabIds: []
                )
            ],
            focusedPaneId: paneID.id.uuidString,
            timestamp: 0
        )

        XCTAssertEqual(
            WorkspaceContentView.tmuxWorkspacePaneOverlayRect(
                layoutSnapshot: snapshot,
                paneId: paneID
            ),
            CGRect(x: 677.5, y: 30, width: 500, height: 290)
        )
    }

    @MainActor
    func testTmuxWorkspacePaneUnreadRectsIncludeFocusedReadIndicator() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
        }

        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let surfaceId = workspace.surfaceIdFromPanelId(panelId),
              let paneId = workspace.paneId(forPanelId: panelId) else {
            XCTFail("Expected selected workspace geometry")
            return
        }

        store.setFocusedReadIndicator(forTabId: workspace.id, surfaceId: panelId)

        let snapshot = LayoutSnapshot(
            containerFrame: PixelRect(x: 200, y: 32, width: 1200, height: 800),
            panes: [
                PaneGeometry(
                    paneId: paneId.id.uuidString,
                    frame: PixelRect(x: 877.5, y: 32, width: 500, height: 320),
                    selectedTabId: surfaceId.uuid.uuidString,
                    tabIds: [surfaceId.uuid.uuidString]
                )
            ],
            focusedPaneId: paneId.id.uuidString,
            timestamp: 0
        )

        XCTAssertEqual(
            WorkspaceContentView.tmuxWorkspacePaneUnreadRects(
                workspace: workspace,
                notificationStore: store,
                layoutSnapshot: snapshot
            ),
            [CGRect(x: 677.5, y: 30, width: 500, height: 290)]
        )
    }

    func testTerminalRevealPhaseWaitsForFirstPresentedFrame() {
        XCTAssertEqual(
            WorkspaceSurfaceRevealPhase(
                lifecycleFacts: terminalLifecycleFacts(
                    isVisibleInUI: true,
                    isWindowed: false,
                    hasUsableGeometry: false,
                    hasRuntime: false,
                    hasPresentedFrame: false,
                    isActive: false
                )
            ),
            .waitingForWindow
        )

        XCTAssertEqual(
            WorkspaceSurfaceRevealPhase(
                lifecycleFacts: terminalLifecycleFacts(
                    isVisibleInUI: true,
                    isWindowed: true,
                    hasUsableGeometry: false,
                    hasRuntime: false,
                    hasPresentedFrame: false,
                    isActive: false
                )
            ),
            .waitingForGeometry
        )

        XCTAssertEqual(
            WorkspaceSurfaceRevealPhase(
                lifecycleFacts: terminalLifecycleFacts(
                    isVisibleInUI: true,
                    isWindowed: true,
                    hasUsableGeometry: true,
                    hasRuntime: false,
                    hasPresentedFrame: false,
                    isActive: false
                )
            ),
            .waitingForRuntime
        )

        XCTAssertEqual(
            WorkspaceSurfaceRevealPhase(
                lifecycleFacts: terminalLifecycleFacts(
                    isVisibleInUI: true,
                    isWindowed: true,
                    hasUsableGeometry: true,
                    hasRuntime: true,
                    hasPresentedFrame: false,
                    isActive: false
                )
            ),
            .waitingForFirstFrame
        )

        XCTAssertEqual(
            WorkspaceSurfaceRevealPhase(
                lifecycleFacts: terminalLifecycleFacts(
                    isVisibleInUI: true,
                    isWindowed: true,
                    hasUsableGeometry: true,
                    hasRuntime: true,
                    hasPresentedFrame: true,
                    isActive: true
                )
            ),
            .visible
        )
    }

    @MainActor
    func testPaneContentSlotMoveKeepsViewMountedWhenNewSlotInstallsFirst() {
        let firstSlot = WorkspaceLayoutPaneContentSlotView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let secondSlot = WorkspaceLayoutPaneContentSlotView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let hostedView = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))

        firstSlot.installContentView(hostedView)
        XCTAssertTrue(hostedView.superview === firstSlot)

        secondSlot.installContentView(hostedView)
        XCTAssertTrue(hostedView.superview === secondSlot)

        firstSlot.clearContentView()
        XCTAssertTrue(hostedView.superview === secondSlot)
    }

    @MainActor
    func testViewportHostApplySynchronizesSlotGeometryBeforeMount() {
        _ = NSApplication.shared

        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId,
              let panel = workspace.terminalPanel(for: panelId),
              let paneId = workspace.paneId(forPanelId: panelId) else {
            XCTFail("Expected focused terminal panel")
            return
        }

        let viewport = terminalViewport(paneId: paneId, surfaceId: panel.id)
        let host = WorkspaceLayoutSurfaceViewportHostView(
            mountIdentity: viewport.mountIdentity,
            surfaceRegistry: workspace.surfaceRegistry,
            debugCanvasName: "test"
        )

        host.apply(
            snapshot: viewport,
            surfaceRegistry: workspace.surfaceRegistry,
            activeDropZone: nil
        )

        XCTAssertEqual(host.debugSlotBounds.size.width, viewport.frame.width, accuracy: 0.001)
        XCTAssertEqual(host.debugSlotBounds.size.height, viewport.frame.height, accuracy: 0.001)
        XCTAssertEqual(panel.hostedView.frame.width, viewport.frame.width, accuracy: 0.001)
        XCTAssertEqual(panel.hostedView.frame.height, viewport.frame.height, accuracy: 0.001)
        XCTAssertTrue(host.debugShowsRevealCover)
        XCTAssertEqual(host.debugRevealPhase, .waitingForWindow)
    }

}

@MainActor
final class TerminalViewportLifecycleControllerTests: XCTestCase {
    private func facts(
        visible: Bool,
        windowed: Bool,
        geometry: Bool,
        runtime: Bool,
        presentedFrame: Bool,
        active: Bool
    ) -> TerminalViewportLifecycleFacts {
        TerminalViewportLifecycleFacts(
            isVisibleInUI: visible,
            isWindowed: windowed,
            hasUsableGeometry: geometry,
            hasRuntime: runtime,
            hasPresentedFrame: presentedFrame,
            isActive: active
        )
    }

    func testVisibleLifecycleWaitsForWindowAndGeometryBeforeRuntimeCreation() {
        let controller = TerminalViewportLifecycleController()

        XCTAssertEqual(
            controller.reconcile(
                facts: facts(
                    visible: true,
                    windowed: false,
                    geometry: false,
                    runtime: false,
                    presentedFrame: false,
                    active: false
                ),
                force: false
            ),
            TerminalViewportLifecycleUpdate(
                phase: .mountedAwaitingWindow,
                demand: .visible,
                commands: []
            )
        )

        XCTAssertEqual(
            controller.reconcile(
                facts: facts(
                    visible: true,
                    windowed: true,
                    geometry: false,
                    runtime: false,
                    presentedFrame: false,
                    active: false
                ),
                force: false
            ),
            TerminalViewportLifecycleUpdate(
                phase: .mountedAwaitingGeometry,
                demand: .visible,
                commands: []
            )
        )

        XCTAssertEqual(
            controller.reconcile(
                facts: facts(
                    visible: true,
                    windowed: true,
                    geometry: true,
                    runtime: false,
                    presentedFrame: false,
                    active: false
                ),
                force: false
            ),
            TerminalViewportLifecycleUpdate(
                phase: .runtimeRealized,
                demand: .visible,
                commands: [.realizeRuntime, .synchronizeVisibleGeometry]
            )
        )
    }

    func testAwaitingFirstFrameRequestsRedrawOnlyOnEntry() {
        let controller = TerminalViewportLifecycleController()
        let awaitingFirstFrameFacts = facts(
            visible: true,
            windowed: true,
            geometry: true,
            runtime: true,
            presentedFrame: false,
            active: false
        )

        XCTAssertEqual(
            controller.reconcile(facts: awaitingFirstFrameFacts, force: false),
            TerminalViewportLifecycleUpdate(
                phase: .awaitingFirstFrame,
                demand: .visible,
                commands: [.synchronizeVisibleGeometry, .requestFirstFrame]
            )
        )

        XCTAssertEqual(
            controller.reconcile(facts: awaitingFirstFrameFacts, force: false),
            TerminalViewportLifecycleUpdate(
                phase: .awaitingFirstFrame,
                demand: .visible,
                commands: [.synchronizeVisibleGeometry]
            )
        )
    }

    func testVisibleFocusedPhaseResumesFocusOnlyAfterFramePresentation() {
        let controller = TerminalViewportLifecycleController()

        XCTAssertEqual(
            controller.reconcile(
                facts: facts(
                    visible: true,
                    windowed: true,
                    geometry: true,
                    runtime: true,
                    presentedFrame: true,
                    active: false
                ),
                force: false
            ),
            TerminalViewportLifecycleUpdate(
                phase: .visible,
                demand: .visible,
                commands: [.synchronizeVisibleGeometry]
            )
        )

        XCTAssertEqual(
            controller.reconcile(
                facts: facts(
                    visible: true,
                    windowed: true,
                    geometry: true,
                    runtime: true,
                    presentedFrame: true,
                    active: true
                ),
                force: false
            ),
            TerminalViewportLifecycleUpdate(
                phase: .visibleFocused,
                demand: .visible,
                commands: [.synchronizeVisibleGeometry, .resumeFocus]
            )
        )
    }

    func testBackgroundDemandPersistsUntilRuntimeCreationBecomesPossible() {
        let controller = TerminalViewportLifecycleController()
        controller.requestBackgroundRuntime()

        XCTAssertEqual(
            controller.reconcile(
                facts: facts(
                    visible: false,
                    windowed: false,
                    geometry: false,
                    runtime: false,
                    presentedFrame: false,
                    active: false
                ),
                force: false
            ),
            TerminalViewportLifecycleUpdate(
                phase: .mountedAwaitingWindow,
                demand: .background,
                commands: []
            )
        )

        XCTAssertEqual(
            controller.reconcile(
                facts: facts(
                    visible: false,
                    windowed: true,
                    geometry: false,
                    runtime: false,
                    presentedFrame: false,
                    active: false
                ),
                force: false
            ),
            TerminalViewportLifecycleUpdate(
                phase: .mountedHidden,
                demand: .background,
                commands: []
            )
        )

        XCTAssertEqual(
            controller.reconcile(
                facts: facts(
                    visible: false,
                    windowed: true,
                    geometry: true,
                    runtime: false,
                    presentedFrame: false,
                    active: false
                ),
                force: false
            ),
            TerminalViewportLifecycleUpdate(
                phase: .runtimeRealized,
                demand: .background,
                commands: [.realizeRuntime]
            )
        )
    }
}
