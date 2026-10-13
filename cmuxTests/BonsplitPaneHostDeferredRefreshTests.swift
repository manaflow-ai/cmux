import AppKit
import Bonsplit
import CmuxTerminal
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// cmux #20181/#20194: cmux 0.65.1 on macOS 27.0.1 trapped with
/// `SwiftUICore/Environment+Objects.swift:34: Fatal error: No Observable object
/// of type BonsplitController found.` The main thread was draining a
/// `WindowTerminalPortal.deferSurfaceRefresh` block: `refreshSurfaceNow` ->
/// `TerminalGeometryDiagnostics.refresh` -> `displayIfNeeded` ->
/// `NSWindow.layoutIfNeeded` -> `NSHostingView.layout()` of a bonsplit pane
/// host that had left `BonsplitView`. A pane host is its own `NSHostingView`
/// and, before bonsplit 093f774, read `BonsplitController` only through the
/// environment it inherits while it sits under `BonsplitView`.
///
/// The test forces that order in a real main window: queue a deferred surface
/// refresh through the window's terminal portal, move one pane host out from
/// under `BonsplitView` (next to the terminal portal, so it stays in the
/// window) before the block runs, then drain the main queue so the refresh
/// lays the window out. The 0.65.1 bonsplit pin traps; the fixed pin passes.
@Suite(.serialized)
@MainActor
final class BonsplitPaneHostDeferredRefreshTests {
    @Test
    func deferredSurfaceRefreshAfterPaneHostLeavesBonsplitViewDoesNotTrap() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await self.deferredSurfaceRefreshAfterPaneHostLeavesBonsplitViewBody()
        }
    }

    @MainActor
    private func deferredSurfaceRefreshAfterPaneHostLeavesBonsplitViewBody() async throws {
        let appDelegate = try #require(AppDelegate.shared)
        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        let window = try #require(window(withId: windowId))
        let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
        let workspace = try #require(manager.selectedWorkspace)
        let leftPanelId = try #require(workspace.focusedPanelId)
        window.setContentSize(CGSize(width: 1_000, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        workspace.bonsplitController.setContainerFrame(CGRect(x: 0, y: 0, width: 1_000, height: 700))

        // 1. A real two-pane terminal split in a real main window.
        let rightPanel = try #require(workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal))
        window.makeKeyAndOrderFront(nil)
        let hostedView = rightPanel.hostedView
        let hostedId = ObjectIdentifier(hostedView)
        var portal: WindowTerminalPortal?
        for _ in 0..<200 {
            settle(window)
            if let candidate = TerminalWindowPortalRegistry.portalsByWindowId[ObjectIdentifier(window)],
               candidate.entriesByHostedId[hostedId]?.visibleInUI == true,
               !hostedView.isHidden,
               paneHosts(in: window).count >= 2 {
                portal = candidate
                break
            }
        }
        let terminalPortal = try #require(portal, "the split terminal must be presented through the window portal")
        let portalContainer = try #require(terminalPortal.hostView.superview)
        let hosts = paneHosts(in: window)
        #expect(hosts.count == 2, "a two-pane split mounts two bonsplit pane hosts")
        let paneHost = try #require(hosts.first)
        let bonsplitSubtree = try #require(bonsplitRoot(of: hosts))
        print("BonsplitPaneHostDeferredRefreshTests: macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

        // 2. Queue the deferred refresh through the portal's own path.
        rightPanel.surface.resetDebugForceRefreshCount()
        terminalPortal.deferSurfaceRefresh(
            forHostedId: hostedId,
            reason: "test.paneHostLeftBonsplitView",
            transition: .unknown
        )

        // 3. Before that main-queue block runs, the pane host leaves
        //    BonsplitView. It stays in the window, beside the terminal portal,
        //    with layout pending, the way a drop or a pane-to-split change
        //    leaves a host between parents.
        paneHost.removeFromSuperview()
        portalContainer.addSubview(paneHost, positioned: .below, relativeTo: terminalPortal.hostView)
        paneHost.needsLayout = true
        hostedView.needsDisplay = true
        #expect(paneHost.window === window)
        #expect(!paneHost.isDescendant(of: bonsplitSubtree))

        // 4. Drain the main queue: deferSurfaceRefresh's block runs
        //    refreshSurfaceNow -> TerminalGeometryDiagnostics.refresh ->
        //    displayIfNeeded, which lays the window (and the detached host) out.
        await drainMainQueue()
        await drainMainQueue()
        #expect(
            rightPanel.surface.debugForceRefreshCount() > 0,
            "the deferred surface refresh must have run"
        )
        #expect(paneHost.window === window)
        paneHost.removeFromSuperview()
        withExtendedLifetime(rightPanel) {}
    }

    private func settle(_ window: NSWindow) {
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Bonsplit's per-pane hosting views on screen in `window`: the
    /// `NSHostingView` each split arranged container
    /// (`SplitArrangedContainerView`, internal to Bonsplit, so matched by type
    /// name) holds.
    private func paneHosts(in window: NSWindow) -> [NSView] {
        guard let root = window.contentView?.superview ?? window.contentView else { return [] }
        var found: [NSView] = []
        func visit(_ view: NSView) {
            if view is NSHostingView<AnyView>,
               let parent = view.superview,
               String(describing: type(of: parent)).contains("SplitArrangedContainerView") {
                if !view.isHiddenOrHasHiddenAncestor, view.bounds.width > 0, view.bounds.height > 0 {
                    found.append(view)
                }
                return
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return found
    }

    /// The nearest common ancestor of the pane hosts: the BonsplitView subtree.
    private func bonsplitRoot(of hosts: [NSView]) -> NSView? {
        guard let first = hosts.first else { return nil }
        var candidate = first.superview
        while let view = candidate {
            if hosts.allSatisfy({ $0.isDescendant(of: view) }) { return view }
            candidate = view.superview
        }
        return nil
    }

    private func window(withId windowId: UUID) -> NSWindow? {
        let identifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == identifier })
    }

    private func closeWindow(withId windowId: UUID) {
        guard let window = window(withId: windowId) else { return }
        window.performClose(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
}
