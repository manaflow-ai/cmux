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

    init(backingScale: CGFloat = 1) async throws {
        _ = NSApplication.shared
        let metricsWindow = TerminalPaneMetricsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        metricsWindow.testBackingScale = backingScale
        window = metricsWindow
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        surface = TerminalSurface(
            tabId: workspace.id, context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil, initialCommand: "/bin/cat"
        )
        do {
            try await waitUntil("runtime creation") { self.surface.surface != nil }
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
        } catch {
            tearDown()
            throw error
        }
    }

    func bind() async throws {
        TerminalWindowPortalRegistry.bind(
            hostedView: hosted, to: anchor, visibleInUI: true,
            expectedSurfaceId: surface.id,
            expectedGeneration: surface.portalBindingGeneration()
        )
        hosted.setVisibleInUI(true)
        try await settle()
    }

    func settle() async throws {
        try await waitUntil("native grid convergence") {
            self.window.contentView?.layoutSubtreeIfNeeded()
            guard let sample = self.surface.rawSizingSample() else { return false }
            let view = self.hosted.surfaceView
            guard let scroll = self.hosted.subviews.compactMap({ $0 as? NSScrollView }).first else { return false }
            var grid = ghostty_surface_grid_metrics_s()
            guard let runtime = self.surface.surface,
                  ghostty_surface_grid_metrics(runtime, &grid) else { return false }
            return abs(self.hosted.frame.width - self.anchor.frame.width) < 1 &&
                abs(view.frame.width - scroll.contentView.bounds.width) < 1 &&
                abs(view.frame.height - scroll.contentView.bounds.height) < 1 &&
                abs(CGFloat(sample.surfaceWidthPx) - view.bounds.width * self.window.backingScaleFactor) < 2 &&
                sample.columns == Int(grid.columns) && sample.rows == Int(grid.rows)
        }
    }

    func moveDivider(to x: CGFloat) async throws {
        split.setPosition(x, ofDividerAt: 0)
        TerminalWindowPortalRegistry.synchronizeForAnchor(anchor, syncLayout: false)
        try await settle()
    }

    func closeSibling() async throws {
        sibling.removeFromSuperview()
        split.adjustSubviews()
        TerminalWindowPortalRegistry.synchronizeForAnchor(anchor, syncLayout: false)
        try await settle()
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
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: true
        )
        try #require(ghostty_surface_read_text(runtime, selection, &text))
        defer { ghostty_surface_free_text(runtime, &text) }
        let pointer = try #require(text.text)
        return String(decoding: UnsafeBufferPointer(start: pointer, count: Int(text.text_len)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            .components(separatedBy: "\n")
    }

    func waitUntil(_ stage: String = "condition", _ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
            await withCheckedContinuation { continuation in
                RunLoop.main.perform(inModes: [.common]) { continuation.resume() }
            }
        }
        try #require(predicate(), "Timed out during \(stage): runtime=\(surface.surface != nil), anchor=\(anchor.frame), hosted=\(hosted.frame), native=\(String(describing: surface.rawSizingSample()))")
    }

    func tearDown() {
        TerminalWindowPortalRegistry.detach(hostedView: hosted)
        surface.releaseSurfaceForTesting()
        surface.teardownSurface()
        window.close()
        workspace.tearDown()
    }
}
