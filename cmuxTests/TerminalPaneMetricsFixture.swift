import AppKit
import CmuxTerminal
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A process-backed terminal in an actual vertical AppKit split.
@MainActor
final class TerminalPaneMetricsFixture {
    let workspace = TerminalPortalTestWorkspace()
    let window: NSWindow
    let split = NSSplitView()
    let anchor = NSView()
    let sibling = NSView()
    let surface: TerminalSurface
    var hosted: GhosttySurfaceScrollView { surface.hostedView }

    init() throws {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        surface = TerminalSurface(
            tabId: workspace.id, context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil, initialCommand: "/bin/cat"
        )
        try waitUntil { self.surface.surface != nil }
        let content = try #require(window.contentView)
        split.frame = content.bounds
        split.isVertical = true
        split.dividerStyle = .thin
        content.addSubview(split)
        split.addArrangedSubview(anchor)
        split.addArrangedSubview(sibling)
        split.adjustSubviews()
        window.orderFront(nil)
        window.displayIfNeeded()
    }

    func bind() throws {
        TerminalWindowPortalRegistry.bind(
            hostedView: hosted, to: anchor, visibleInUI: true,
            expectedSurfaceId: surface.id,
            expectedGeneration: surface.portalBindingGeneration()
        )
        hosted.setVisibleInUI(true)
        try settle()
    }

    func settle() throws {
        try waitUntil {
            self.window.contentView?.layoutSubtreeIfNeeded()
            guard let sample = self.surface.rawSizingSample() else { return false }
            let view = self.hosted.surfaceView
            var grid = ghostty_surface_grid_metrics_s()
            guard let runtime = self.surface.surface,
                  ghostty_surface_grid_metrics(runtime, &grid) else { return false }
            return abs(self.hosted.frame.width - self.anchor.frame.width) < 1 &&
                abs(CGFloat(sample.surfaceWidthPx) - view.bounds.width * self.window.backingScaleFactor) < 2 &&
                sample.columns == Int(grid.columns) && sample.rows == Int(grid.rows)
        }
    }

    func moveDivider(to x: CGFloat) throws {
        split.setPosition(x, ofDividerAt: 0)
        TerminalWindowPortalRegistry.synchronizeForAnchor(anchor, syncLayout: false)
        try settle()
    }

    func closeSibling() throws {
        sibling.removeFromSuperview()
        split.adjustSubviews()
        TerminalWindowPortalRegistry.synchronizeForAnchor(anchor, syncLayout: false)
        try settle()
    }

    func writeRows() throws {
        let runtime = try #require(surface.surface)
        let fill = String(repeating: "=", count: 74)
        let output = "\u{1B}[2J\u{1B}[H" + (1...4).map { "R\($0)\(fill)END\($0)\r\n" }.joined()
        output.withCString { ghostty_surface_process_output(runtime, $0, UInt(output.utf8.count)) }
    }

    func physicalRows() throws -> [String] {
        let runtime = try #require(surface.surface)
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SURFACE, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SURFACE, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: true
        )
        try #require(ghostty_surface_read_text(runtime, selection, &text))
        defer { ghostty_surface_free_text(runtime, &text) }
        let pointer = try #require(text.text)
        return String(decoding: UnsafeBufferPointer(start: pointer, count: Int(text.text_len)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            .components(separatedBy: "\n")
    }

    func waitUntil(_ predicate: () -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        try #require(predicate(), "Terminal geometry did not converge")
    }

    func tearDown() {
        TerminalWindowPortalRegistry.detach(hostedView: hosted)
        surface.releaseSurfaceForTesting()
        surface.teardownSurface()
        window.close()
        workspace.tearDown()
    }
}
