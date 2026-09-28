import AppKit
import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Replays the UI fuzzer's repro for #15346 in-process: a fresh window showing both
/// side panels, resized to 320x360, used to leave the terminal area 0 pt wide.
@Suite(.serialized)
@MainActor
struct NarrowWindowSidePanelFitTests {
    /// `repro.json` from the issue, verbatim.
    private static let repro = """
    {"kind": "cmux-fuzz-repro", "version": 1, "signature": {"kind": "invariant", "key": "container-degenerate", \
    "title": "Layout invariant broken: container-degenerate", "digest": "085e7a6e329b"}, \
    "steps": [{"do": "window_resize", "w": 320, "h": 360}]}
    """

    private struct Repro: Decodable {
        struct Step: Decodable {
            let `do`: String
            let w: Double?
            let h: Double?
        }
        let steps: [Step]
    }

    @Test func narrowWindowCollapsesSidePanelsAndKeepsTheTerminal() async throws {
        _ = NSApplication.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let defaults = UserDefaults.standard
        let savedRightSidebarVisible = defaults.object(forKey: "fileExplorer.isVisible")
        let windowId = appDelegate.createMainWindow(shouldActivate: false)
        let window = try #require(appDelegate.mainWindow(for: windowId) as? CmuxMainWindow)
#if DEBUG
        let previousConfirmationHandler = appDelegate.debugCloseMainWindowConfirmationHandler
        appDelegate.debugCloseMainWindowConfirmationHandler = { _ in true }
#endif
        defer {
            window.animationBehavior = .none
            window.orderOut(nil)
            window.close()
#if DEBUG
            appDelegate.debugCloseMainWindowConfirmationHandler = previousConfirmationHandler
#endif
            if let savedRightSidebarVisible {
                defaults.set(savedRightSidebarVisible, forKey: "fileExplorer.isVisible")
            } else {
                defaults.removeObject(forKey: "fileExplorer.isVisible")
            }
        }
        let context = try #require(appDelegate.contextForMainWindow(window))
        let rightSidebar = try #require(context.fileExplorerState)
        let pump = AppKitTestEventPump()

        // The fuzzer's fresh app: a 1440x900 window with both side panels showing.
        _ = appDelegate.resizeMainWindow(windowId: windowId, width: 1440, height: 900)
        context.sidebarState.setVisible(true)
        rightSidebar.isVisible = true
        window.orderFront(nil)
        let laidOut = await pump.waitUntil(timeout: .seconds(10)) {
            layOut(window)
            return containerWidth(context) > 1
        }
        #expect(laidOut, "the 1440 pt window lays out a terminal area")

        let repro = try JSONDecoder().decode(Repro.self, from: Data(Self.repro.utf8))
        for step in repro.steps where step.do == "window_resize" {
            _ = appDelegate.resizeMainWindow(
                windowId: windowId,
                width: step.w.map { CGFloat($0) },
                height: step.h.map { CGFloat($0) }
            )
        }

        let collapsed = await pump.waitUntil(timeout: .seconds(10)) {
            layOut(window)
            return !context.sidebarState.isVisible && !rightSidebar.isVisible
        }
        #expect(collapsed, "both side panels collapse in a 320 pt window")
        let keepsTerminal = await pump.waitUntil(timeout: .seconds(10)) {
            layOut(window)
            return containerWidth(context) >= 1
        }
        #expect(keepsTerminal, "the terminal area keeps its width (was 0 pt)")

        // Widening the window brings back the panels it collapsed.
        _ = appDelegate.resizeMainWindow(windowId: windowId, width: 1440, height: 900)
        let restored = await pump.waitUntil(timeout: .seconds(10)) {
            layOut(window)
            return context.sidebarState.isVisible && rightSidebar.isVisible
        }
        #expect(restored, "auto-collapsed side panels return when the window widens")
    }

    private func layOut(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private func containerWidth(_ context: AppDelegate.MainWindowContext) -> Double {
        guard let workspace = context.tabManager.selectedWorkspace else { return 0 }
        return Double(workspace.bonsplitController.layoutSnapshot().containerFrame.width)
    }
}
