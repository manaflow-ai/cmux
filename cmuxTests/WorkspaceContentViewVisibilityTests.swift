import Testing
import AppKit
import CmuxUpdater
import CoreGraphics
import SwiftUI
import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
final class WorkspaceContentViewVisibilityTests {
    private final class MinimalModeBodyProbeCounts {
        var contentViewBody = 0
        var workspaceContentBody = 0
        var verticalTabsSidebarBody = 0

        func reset() {
            contentViewBody = 0
            workspaceContentBody = 0
            verticalTabsSidebarBody = 0
        }
    }

    @Test
    @MainActor
    func testMinimalModeToggleDoesNotReevaluateChromeHeavyBodies() async throws {
        _ = NSApplication.shared

        let suiteName = "WorkspaceContentViewVisibilityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(
            WorkspacePresentationModeSettings.Mode.standard.rawValue,
            forKey: WorkspacePresentationModeSettings.modeKey
        )

        let tabManager = TabManager()
        for _ in 0..<6 {
            tabManager.addWorkspace(autoWelcomeIfNeeded: false)
        }
        let notificationStore = TerminalNotificationStore.shared
        let counts = MinimalModeBodyProbeCounts()
        let root = ContentView(updateViewModel: UpdateStateModel(), windowId: UUID())
            .environmentObject(tabManager)
            .environmentObject(notificationStore)
            .environmentObject(notificationStore.sidebarUnread)
            .environmentObject(SidebarState())
            .environmentObject(SidebarSelectionState())
            .environmentObject(FileExplorerState())
            .environmentObject(CmuxConfigStore())
            .environment(
                \.minimalModeInvalidationProbe,
                MinimalModeInvalidationProbe(
                    contentViewBody: { counts.contentViewBody += 1 },
                    workspaceContentBody: { counts.workspaceContentBody += 1 },
                    verticalTabsSidebarBody: { counts.verticalTabsSidebarBody += 1 }
                )
            )
            .defaultAppStorage(defaults)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = MainWindowHostingView(rootView: root)
        defer {
            window.contentView = nil
            window.close()
        }

        await Self.drainMainRunLoop(for: window)
        #expect(counts.contentViewBody > 0)
        #expect(counts.workspaceContentBody > 0)
        #expect(counts.verticalTabsSidebarBody > 0)

        counts.reset()
        defaults.set(
            WorkspacePresentationModeSettings.Mode.minimal.rawValue,
            forKey: WorkspacePresentationModeSettings.modeKey
        )
        await Self.drainMainRunLoop(for: window)

        #expect(
            counts.contentViewBody == 0,
            "Minimal-mode toggles must not re-evaluate the whole ContentView body."
        )
        #expect(
            counts.workspaceContentBody == 0,
            "Minimal-mode toggles must not re-evaluate WorkspaceContentView/Bonsplit content."
        )
        #expect(
            counts.verticalTabsSidebarBody == 0,
            "Minimal-mode toggles must not rebuild the vertical sidebar render context."
        )
    }

    @MainActor
    private static func drainMainRunLoop(for window: NSWindow, iterations: Int = 20) async {
        for _ in 0..<iterations {
            window.contentView?.layoutSubtreeIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
            await Task.yield()
        }
    }

    @Test
    @MainActor
    func testSidebarSelectionUpdatesHostedTerminalPortalVisibility() async throws {
        _ = NSApplication.shared
        let tabManager = TabManager()
        defer { tabManager.tabs.forEach { $0.teardownAllPanels() } }
        let notificationStore = TerminalNotificationStore.shared
        let sidebarSelectionState = SidebarSelectionState(selection: .tabs)
        let root = ContentView(updateViewModel: UpdateStateModel(), windowId: UUID())
            .environmentObject(tabManager)
            .environmentObject(notificationStore)
            .environmentObject(notificationStore.sidebarUnread)
            .environmentObject(SidebarState())
            .environmentObject(sidebarSelectionState)
            .environmentObject(FileExplorerState())
            .environmentObject(CmuxConfigStore())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = MainWindowHostingView(rootView: root)
        defer {
            window.contentView = nil
            window.close()
        }

        await Self.drainMainRunLoop(for: window)
        let workspace = try #require(tabManager.selectedWorkspace)
        let initialPanel = try #require(workspace.focusedTerminalPanel)
        let pane = try #require(workspace.paneId(forPanelId: initialPanel.id))
        let panel = try #require(workspace.newTerminalSurface(inPane: pane, focus: true))
        await Self.drainMainRunLoop(for: window)

        #expect(workspace.focusedTerminalPanel?.id == panel.id)
        #expect(!initialPanel.hostedView.debugPortalVisibleInUI)
        #expect(panel.hostedView.debugPortalVisibleInUI)
        let portal = try #require(TerminalWindowPortalRegistry.mappedPortal(for: panel.hostedView))
        let entry = try #require(portal.entriesByHostedId[ObjectIdentifier(panel.hostedView)])
        let anchor = try #require(entry.anchorView)
        #expect(entry.visibleInUI)
        #expect(TerminalWindowPortalRegistry.isHostedView(panel.hostedView, boundTo: anchor))

        sidebarSelectionState.selection = .notifications
        await Self.drainMainRunLoop(for: window)
        #expect(!panel.hostedView.debugPortalVisibleInUI)
        _ = tabManager.selectedWorkspace?.debugReconcileTerminalPortalVisibilityForTesting()
        #expect(
            !panel.hostedView.debugPortalVisibleInUI,
            "A layout follow-up must not override sidebar-owned portal hiding"
        )

        sidebarSelectionState.selection = .tabs
        await Self.drainMainRunLoop(for: window)
        #expect(panel.hostedView.debugPortalVisibleInUI)
    }

    @Test
    func testNonSelectedNonRetiringWorkspaceIsFullyHidden() {
        #expect(
            MountedWorkspacePresentation.resolve(
                isSelectedWorkspace: false,
                isRetiringWorkspace: false
            ) ==
            MountedWorkspacePresentation(
                isRenderedVisible: false,
                isPanelVisible: false,
                renderOpacity: 0
            )
        )
    }

    @Test
    func testRetiringWorkspaceStaysPanelVisibleDuringHandoff() {
        #expect(
            MountedWorkspacePresentation.resolve(
                isSelectedWorkspace: false,
                isRetiringWorkspace: true
            ) ==
            MountedWorkspacePresentation(
                isRenderedVisible: true,
                isPanelVisible: true,
                renderOpacity: 1
            )
        )
    }

    @Test
    func testPanelVisibleInUIReturnsFalseWhenWorkspaceHidden() {
        #expect(
            !WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: false,
                isSelectedInPane: true,
                isFocused: true
            )
        )
    }

    @Test
    func testPanelVisibleInUIReturnsTrueForSelectedPanel() {
        #expect(
            WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: true,
                isSelectedInPane: true,
                isFocused: false
            )
        )
    }

    @Test
    func testPanelVisibleInUIReturnsTrueForFocusedPanelDuringTransientSelectionGap() {
        #expect(
            WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: true,
                isSelectedInPane: false,
                isFocused: true
            )
        )
    }

    @Test
    func testPanelVisibleInUIReturnsFalseWhenNeitherSelectedNorFocused() {
        #expect(
            !WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: true,
                isSelectedInPane: false,
                isFocused: false
            )
        )
    }

    @Test
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

        #expect(
            WorkspaceContentView.tmuxWorkspacePaneOverlayRect(
                layoutSnapshot: snapshot,
                paneId: paneID
            ) ==
            CGRect(x: 677.5, y: 28, width: 500, height: 292)
        )
    }

    @Test
    @MainActor
    func testTmuxWorkspacePaneUnreadRectsIncludeFocusedReadIndicator() throws {
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

        let workspace = try #require(manager.selectedWorkspace, "Expected selected workspace geometry")
        let panelId = try #require(workspace.focusedPanelId, "Expected selected workspace geometry")
        let surfaceId = try #require(workspace.surfaceIdFromPanelId(panelId), "Expected selected workspace geometry")
        let paneId = try #require(workspace.paneId(forPanelId: panelId), "Expected selected workspace geometry")

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

        #expect(
            WorkspaceContentView.tmuxWorkspacePaneUnreadRects(
                workspace: workspace,
                notificationStore: store,
                layoutSnapshot: snapshot
            ) ==
            [CGRect(x: 677.5, y: 28, width: 500, height: 292)]
        )
    }
}

@Suite("Canvas portal lifecycle", .serialized)
struct CanvasPortalLifecycleTests {
    @Test
    @MainActor
    func switchingVisibleWorkspaceToCanvasKeepsPortalPresentationVisible() async throws {
        _ = NSApplication.shared
        let tabManager = TabManager()
        defer { tabManager.tabs.forEach { $0.teardownAllPanels() } }
        let notificationStore = TerminalNotificationStore.shared
        let root = ContentView(updateViewModel: UpdateStateModel(), windowId: UUID())
            .environmentObject(tabManager)
            .environmentObject(notificationStore)
            .environmentObject(notificationStore.sidebarUnread)
            .environmentObject(SidebarState())
            .environmentObject(SidebarSelectionState())
            .environmentObject(FileExplorerState())
            .environmentObject(CmuxConfigStore())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = MainWindowHostingView(rootView: root)
        defer {
            window.contentView = nil
            window.close()
        }

        await Self.drainMainRunLoop(for: window)
        let workspace = try #require(tabManager.selectedWorkspace)
        #expect(workspace.portalPresentationVisible)

        workspace.setLayoutMode(.canvas)
        await Self.drainMainRunLoop(for: window)

        #expect(workspace.layoutMode == .canvas)
        #expect(
            workspace.portalPresentationVisible,
            "Replacing the Bonsplit subtree with Canvas must not report that the visible workspace disappeared"
        )
    }

    @Test
    @MainActor
    func canvasDirectHostReplacesEveryPortalOwnedCallback() {
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.surface.teardownSurface() }
        let hostedView = panel.hostedView
        let portalHost = NSView()
        var portalFocusCount = 0
        var portalFlashCount = 0
        var canvasFocusCount = 0
        hostedView.setPortalHostHandlers(
            ownerHostId: ObjectIdentifier(portalHost),
            focusHandler: { portalFocusCount += 1 },
            triggerFlashHandler: { portalFlashCount += 1 }
        )

        let container = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let mount = CanvasPaneContentMount(
            content: .terminal(panel),
            panelId: panel.id,
            container: container,
            onFocusPanel: { _ in canvasFocusCount += 1 }
        )
        defer { mount.unmount() }

        hostedView.surfaceView.onFocus?()
        hostedView.surfaceView.onTriggerFlash?()

        #expect(portalFocusCount == 0)
        #expect(canvasFocusCount == 1)
        #expect(
            portalFlashCount == 0,
            "Canvas direct hosting must not retain the replaced portal host's flash callback"
        )
        withExtendedLifetime(portalHost) {}
    }

    @Test
    @MainActor
    func canvasDirectHostRestoresVisibilityWhenRenderingResumes() {
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.surface.teardownSurface() }
        let hostedView = panel.hostedView
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let mount = CanvasPaneContentMount(
            content: .terminal(panel),
            panelId: panel.id,
            container: container,
            onFocusPanel: { _ in }
        )
        defer { mount.unmount() }
        #expect(hostedView.debugPortalVisibleInUI)
        #expect(!hostedView.isHidden)

        hostedView.setVisibleInUI(false, refreshPolicy: .deferredToPortal)
        #expect(!hostedView.debugPortalVisibleInUI)
        #expect(hostedView.isHidden)

        mount.setRendering(true)

        #expect(
            hostedView.debugPortalVisibleInUI,
            "Canvas must restore a direct-hosted terminal after workspace or sidebar visibility returns"
        )
        #expect(!hostedView.isHidden)
    }

    @MainActor
    private static func drainMainRunLoop(for window: NSWindow, iterations: Int = 20) async {
        for _ in 0..<iterations {
            window.contentView?.layoutSubtreeIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
            await Task.yield()
        }
    }
}
