import AppKit
import Bonsplit
import SwiftUI
import Testing

/// Reproduces the SwiftUI environment trap reported in cmux issues #20194 and
/// #20181. A split pane is hosted by its own `NSHostingController`; during a
/// drag-time nested run loop, deferred divider work can lay that host out after
/// the Bonsplit tree has been detached from its window. The pane's environment
/// must still provide both Bonsplit controllers while that teardown completes.
@Suite("Bonsplit pane host environment crash regression")
@MainActor
struct BonsplitPaneHostEnvironmentCrashRegressionTests {
    @Test("Detached pane hosts survive deferred divider layout")
    func detachedPaneHostsSurviveDeferredDividerLayout() throws {
        _ = NSApplication.shared
        let controller = BonsplitController()
        controller.createTab(title: "First")

        let hostingView = NSHostingView(
            rootView: BonsplitView(controller: controller) { _, _ in
                Color.clear
            } emptyPane: { _ in
                Color.clear
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }

        let contentView = try #require(window.contentView)
        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)
        window.makeKeyAndOrderFront(nil)
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let firstPane = try #require(controller.focusedPaneId)
        _ = try #require(controller.splitPane(firstPane, orientation: .horizontal))

        // Mount the split and let AppKit enter the same run-loop boundary that
        // a real tab drag uses before its deferred divider apply.
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        var mountedSplit = Self.firstSplitView(in: hostingView)
        for _ in 0..<200 where mountedSplit == nil {
            CFRunLoopRunInMode(.defaultMode, 0.005, true)
            contentView.layoutSubtreeIfNeeded()
            mountedSplit = Self.firstSplitView(in: hostingView)
        }
        let splitView = try #require(mountedSplit)

        // Closing a window during the drag's nested run loop detaches the
        // Bonsplit hierarchy before the queued divider callback runs.
        hostingView.removeFromSuperview()
        window.close()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        #expect(splitView.window == nil)
    }

    private static func firstSplitView(in root: NSView) -> NSSplitView? {
        if let splitView = root as? NSSplitView { return splitView }
        for subview in root.subviews {
            if let splitView = firstSplitView(in: subview) { return splitView }
        }
        return nil
    }
}
