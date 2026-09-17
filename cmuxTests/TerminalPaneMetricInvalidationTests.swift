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
    func fontCallbacksUseCurrentLogicalCellSize(backingScale: CGFloat) async throws {
        let fixture = try await TerminalPaneMetricsFixture(backingScale: backingScale)
        defer { fixture.tearDown() }
        try await fixture.bind()
        #expect(fixture.surface.performInternalBindingAction("set_font_size:24"))
        #expect(fixture.surface.performInternalBindingAction("set_font_size:13"))
        try await fixture.waitUntil("logical cell metrics") {
            fixture.hosted.surfaceView.cellSize == fixture.surface.cellSizePoints()
        }
        let sample = try #require(fixture.surface.rawSizingSample())
        #expect(fixture.hosted.surfaceView.cellSize.width == CGFloat(sample.cellWidthPx) / backingScale)
        #expect(fixture.hosted.surfaceView.cellSize.height == CGFloat(sample.cellHeightPx) / backingScale)
    }

    @Test(arguments: [CGFloat(1), CGFloat(2)])
    func hiddenOutputReflowsThroughDividerDragAndSplitClose(backingScale: CGFloat) async throws {
        let fixture = try await TerminalPaneMetricsFixture(backingScale: backingScale)
        defer { fixture.tearDown() }
        // The original #12381 path: output arrives before the split is shown.
        try fixture.writeRows()
        try await fixture.bind()
        let originalCell = try #require(fixture.surface.cellSizePoints())
        let originalFont = ghostty_surface_font_size(try #require(fixture.surface.surface))
        for width: CGFloat in [280, 620, 360] {
            try await fixture.moveDivider(to: width)
            try assertGridAndText(fixture, cell: originalCell, font: originalFont)
        }
        try await fixture.closeSibling()
        try assertGridAndText(fixture, cell: originalCell, font: originalFont)
    }

    @Test func paneGeometryInvalidatesStaleLargerCellMetrics() async throws {
        let fixture = try await TerminalPaneMetricsFixture()
        defer { fixture.tearDown() }
        try await fixture.bind()
        let expected = try #require(fixture.surface.cellSizePoints())
        // Simulate a delayed metric notification from the previous layout.
        // Repair must come from each pane geometry boundary, with no window
        // resize, config reload, or font-size mutation.
        for closeSibling in [false, true] {
            fixture.hosted.surfaceView.cellSize = CGSize(width: expected.width * 2, height: expected.height * 2)
            if closeSibling { try await fixture.closeSibling() }
            else { try await fixture.moveDivider(to: 340) }
            #expect(fixture.hosted.surfaceView.cellSize == expected)
        }
    }

    @Test func sameFrameReconciliationRepairsMetricCache() async throws {
        let fixture = try await TerminalPaneMetricsFixture()
        defer { fixture.tearDown() }
        try await fixture.bind()
        let expected = try #require(fixture.surface.cellSizePoints())
        let frame = fixture.hosted.frame
        fixture.hosted.surfaceView.cellSize = CGSize(width: expected.width * 2, height: expected.height * 2)
        _ = fixture.hosted.reconcileGeometryNow()
        #expect(fixture.hosted.frame == frame)
        #expect(fixture.hosted.surfaceView.cellSize == expected)
    }

    @Test func splitCloseRecoversAfterNativeResizeEndCallbackWasLost() async throws {
        let fixture = try await TerminalPaneMetricsFixture()
        defer { fixture.tearDown() }
        try await fixture.bind()
        let portal = try #require(TerminalWindowPortalRegistry.portalsByWindowId[ObjectIdentifier(fixture.window)])
        portal.isWindowLiveResizeActiveOverrideForTesting = true
        TerminalWindowPortalRegistry.synchronizeForAnchor(fixture.anchor, syncLayout: false)
        #expect(portal.isRendererResizeDeferred)
        portal.isWindowLiveResizeActiveOverrideForTesting = false
        // No window notification: only the surviving pane's layout changes.
        try await fixture.closeSibling()
        #expect(!portal.isRendererResizeDeferred)
    }

    @Test func activeDividerDoesNotFinishWhenNativeWindowResizeIsInactive() async throws {
        let fixture = try await TerminalPaneMetricsFixture()
        defer { fixture.tearDown() }
        try await fixture.bind()
        let portal = try #require(TerminalWindowPortalRegistry.portalsByWindowId[ObjectIdentifier(fixture.window)])
        TerminalWindowPortalRegistry.beginInteractiveGeometryResize(in: fixture.window)
        defer { TerminalWindowPortalRegistry.endInteractiveGeometryResize(in: fixture.window) }
        fixture.split.setPosition(320, ofDividerAt: 0)
        TerminalWindowPortalRegistry.synchronizeExternalGeometryNow(for: fixture.window)
        #expect(portal.isRendererResizeDeferred)
        TerminalWindowPortalRegistry.endInteractiveGeometryResize(in: fixture.window)
        try await fixture.waitUntil("divider completion") { !portal.isRendererResizeDeferred }
        try await fixture.settle()
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
        #expect(fixture.hosted.surfaceView.cellSize == cell)
        #expect(ghostty_surface_font_size(runtime) == font)
        // Text selection unwraps soft-wrapped lines even for rectangles.
        // Inspect the native grid export, including each span's cell extent.
        let rendered = try #require(fixture.surface.mobileRenderGridFrame(stateSeq: 0, includeTheme: false))
        #expect(rendered.frame.columns == sample.columns)
        #expect(rendered.frame.rows == sample.rows)
        #expect(rendered.frame.rowSpans.allSatisfy {
            $0.row < sample.rows && $0.column + $0.gridCellWidth <= sample.columns
        })
        let rows = rendered.rows
        #expect(rows.allSatisfy { $0.count <= sample.columns })
        let compact = rows.joined().filter { !$0.isWhitespace }
        for index in 1...4 {
            let expected = "R\(index)" + String(repeating: "=", count: 74) + "END\(index)"
            #expect(compact.components(separatedBy: expected).count == 2)
            #expect(compact.components(separatedBy: "R\(index)").count == 2)
            #expect(compact.components(separatedBy: "END\(index)").count == 2)
        }
    }
}
