import AppKit
import CmuxCanvasUI
import CmuxUpdater
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

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

        let initialPortalBecameVisible = await Self.waitForPortalCondition(in: window) {
            tabManager.selectedWorkspace?.portalPresentationVisible == true
        }
        #expect(
            initialPortalBecameVisible,
            "The selected workspace portal must become visible before the Canvas transition"
        )
        let workspace = try #require(tabManager.selectedWorkspace)
        let hostedView = try #require(workspace.focusedTerminalPanel?.hostedView)
        let initialTerminalBecamePortalBound = await Self.waitForPortalCondition(in: window) {
            guard let portal = TerminalWindowPortalRegistry.mappedPortal(for: hostedView),
                  let entry = portal.entriesByHostedId[ObjectIdentifier(hostedView)],
                  let anchor = entry.anchorView else {
                return false
            }
            return TerminalWindowPortalRegistry.isHostedView(hostedView, boundTo: anchor)
        }
        #expect(
            initialTerminalBecamePortalBound,
            "The terminal must start in the split layout's window portal"
        )
        #expect(workspace.portalPresentationVisible)

        workspace.setLayoutMode(.canvas)
        let canvasPortalStayedVisible = await Self.waitForPortalCondition(in: window) {
            workspace.layoutMode == .canvas &&
                workspace.portalPresentationVisible &&
                Self.hasCanvasRootAncestor(hostedView)
        }

        #expect(workspace.layoutMode == .canvas)
        #expect(
            canvasPortalStayedVisible && workspace.portalPresentationVisible,
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
    private static func waitForPortalCondition(
        in window: NSWindow,
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            if condition() { return true }
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
            await Task.yield()
        }
        window.contentView?.layoutSubtreeIfNeeded()
        return condition()
    }

    @MainActor
    private static func hasCanvasRootAncestor(_ view: NSView) -> Bool {
        var ancestor = view.superview
        while let current = ancestor {
            if current is CanvasRootView { return true }
            ancestor = current.superview
        }
        return false
    }
}
