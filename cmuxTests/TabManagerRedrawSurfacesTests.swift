import AppKit
import Foundation
import Testing
@preconcurrency import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Regression coverage for the "Redraw Window" escape hatch (issue #6031): the
// command-palette / View-menu action must re-run the geometry reconcile + repaint
// pass on the selected workspace only, never on background workspaces.
@MainActor
@Suite(.serialized)
struct TabManagerRedrawSurfacesTests {
    @Test func redrawVisibleSurfacesRoutesToSelectedWorkspaceOnly() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()

        guard let selected = manager.selectedWorkspace else {
            Issue.record("Expected a selected workspace")
            return
        }
        let other = selected.id == first.id ? second : first

        #expect(selected.redrawVisibleSurfacesRequestCount == 0)
        #expect(other.redrawVisibleSurfacesRequestCount == 0)

        manager.redrawVisibleSurfaces()

        // Redraw Window must run on the selected workspace, not background ones.
        #expect(selected.redrawVisibleSurfacesRequestCount == 1)
        #expect(other.redrawVisibleSurfacesRequestCount == 0)

        // Switching selection must re-target the shared action.
        manager.selectWorkspace(other)
        manager.redrawVisibleSurfaces()

        #expect(other.redrawVisibleSurfacesRequestCount == 1)
        #expect(selected.redrawVisibleSurfacesRequestCount == 1)
    }

    @Test func redrawVisibleSurfacesSchedulesGeometryRefreshForSelectedWorkspace() throws {
#if DEBUG
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelId))
        let window = Self.makeWindow()
        defer {
            panel.hostedView.removeFromSuperview()
            window.orderOut(nil)
        }
        let contentView = try #require(window.contentView)

        panel.hostedView.frame = contentView.bounds
        panel.hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(panel.hostedView)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        panel.hostedView.layoutSubtreeIfNeeded()
        panel.hostedView.setVisibleInUI(true)
        panel.hostedView.setActive(true)

        let didCreateSurface = Self.waitUntil(timeout: 1.0) { panel.surface.surface != nil }
        #expect(didCreateSurface)
        guard didCreateSurface else { return }

        panel.surface.resetDebugForceRefreshCount()
        manager.redrawVisibleSurfaces()
        workspace.debugAttemptEventDrivenLayoutFollowUpForTesting()

        #expect(panel.surface.debugForceRefreshCount() == 1)
#else
        throw XCTSkip("DEBUG-only terminal surface refresh instrumentation is required")
#endif
    }

    private static func makeWindow() -> NSWindow {
        let contentRect = NSRect(x: 0, y: 0, width: 480, height: 320)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: contentRect)
        return window
    }

    private static func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}
