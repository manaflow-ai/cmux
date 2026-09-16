import AppKit
import CmuxTerminal
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct TerminalPaneMetricInvalidationTests {
    @Test(arguments: [CGFloat(1), CGFloat(2)])
    func fontCallbacksUseCurrentLogicalCellSize(backingScale: CGFloat) throws {
        let fixture = try TerminalPaneMetricsFixture(backingScale: backingScale)
        defer { fixture.tearDown() }
        try fixture.bind()
        #expect(fixture.surface.performInternalBindingAction("set_font_size:24"))
        #expect(fixture.surface.performInternalBindingAction("set_font_size:13"))
        try fixture.waitUntil {
            fixture.hosted.surfaceView.cellSize == fixture.surface.cellSizePoints()
        }
        let sample = try #require(fixture.surface.rawSizingSample())
        #expect(fixture.hosted.surfaceView.cellSize.width == CGFloat(sample.cellWidthPx) / backingScale)
        #expect(fixture.hosted.surfaceView.cellSize.height == CGFloat(sample.cellHeightPx) / backingScale)
    }

    @Test func hiddenOutputReflowsThroughDividerDragAndSplitClose() throws {
        let fixture = try TerminalPaneMetricsFixture()
        defer { fixture.tearDown() }
        // The original #12381 path: output arrives before the split is shown.
        try fixture.writeRows()
        try fixture.bind()
        let originalCell = try #require(fixture.surface.cellSizePoints())
        let originalFont = ghostty_surface_font_size(try #require(fixture.surface.surface))
        for width: CGFloat in [280, 620, 360] {
            try fixture.moveDivider(to: width)
            try assertGridAndText(fixture, cell: originalCell, font: originalFont)
        }
        try fixture.closeSibling()
        try assertGridAndText(fixture, cell: originalCell, font: originalFont)
    }

    @Test func paneGeometryInvalidatesStaleLargerCellMetrics() throws {
        let fixture = try TerminalPaneMetricsFixture()
        defer { fixture.tearDown() }
        try fixture.bind()
        let expected = try #require(fixture.surface.cellSizePoints())
        // Simulate a delayed metric notification from the previous layout.
        // Repair must come from each pane geometry boundary, with no window
        // resize, config reload, or font-size mutation.
        for closeSibling in [false, true] {
            fixture.hosted.surfaceView.cellSize = CGSize(width: expected.width * 2, height: expected.height * 2)
            if closeSibling { try fixture.closeSibling() }
            else { try fixture.moveDivider(to: 340) }
            #expect(fixture.hosted.surfaceView.cellSize == expected)
        }
    }

    @Test func sameFrameReconciliationRepairsMetricCache() throws {
        let fixture = try TerminalPaneMetricsFixture()
        defer { fixture.tearDown() }
        try fixture.bind()
        let expected = try #require(fixture.surface.cellSizePoints())
        let frame = fixture.hosted.frame
        fixture.hosted.surfaceView.cellSize = CGSize(width: expected.width * 2, height: expected.height * 2)
        _ = fixture.hosted.reconcileGeometryNow()
        #expect(fixture.hosted.frame == frame)
        #expect(fixture.hosted.surfaceView.cellSize == expected)
    }

    @Test func splitCloseRecoversAfterNativeResizeEndCallbackWasLost() throws {
        let fixture = try TerminalPaneMetricsFixture()
        defer { fixture.tearDown() }
        try fixture.bind()
        let portal = try #require(TerminalWindowPortalRegistry.portalsByWindowId[ObjectIdentifier(fixture.window)])
        portal.isWindowLiveResizeActiveOverrideForTesting = true
        TerminalWindowPortalRegistry.synchronizeForAnchor(fixture.anchor, syncLayout: false)
        #expect(portal.isRendererResizeDeferred)
        portal.isWindowLiveResizeActiveOverrideForTesting = false
        // No window notification: only the surviving pane's layout changes.
        try fixture.closeSibling()
        #expect(!portal.isRendererResizeDeferred)
    }

    private func assertGridAndText(_ fixture: TerminalPaneMetricsFixture, cell: CGSize, font: Float) throws {
        let sample = try #require(fixture.surface.rawSizingSample())
        let runtime = try #require(fixture.surface.surface)
        var grid = ghostty_surface_grid_metrics_s()
        #expect(ghostty_surface_grid_metrics(runtime, &grid))
        #expect(Int(grid.columns) == sample.columns)
        #expect(Int(grid.rows) == sample.rows)
        #expect(fixture.surface.cellSizePoints() == cell)
        #expect(ghostty_surface_font_size(runtime) == font)
        let rows = try fixture.physicalRows()
        #expect(rows.allSatisfy { $0.count <= sample.columns })
        let compact = rows.joined().filter { !$0.isWhitespace }
        for index in 1...4 {
            #expect(compact.components(separatedBy: "R\(index)").count == 2)
            #expect(compact.components(separatedBy: "END\(index)").count == 2)
        }
    }
}
