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
        defer { portal.isWindowLiveResizeActiveOverrideForTesting = false }
        fixture.split.setPosition(320, ofDividerAt: 0)
        TerminalWindowPortalRegistry.synchronizeForAnchor(fixture.anchor, syncLayout: false)
        #expect(fixture.surface.committedPaneGeometry?.phase == .interactive)
        portal.isWindowLiveResizeActiveOverrideForTesting = false
        // No window notification: only the surviving pane's layout changes.
        try await fixture.closeSibling()
        #expect(fixture.surface.committedPaneGeometry?.phase == .settled)
    }

    @Test func activeDividerDoesNotFinishWhenNativeWindowResizeIsInactive() async throws {
        let fixture = try await TerminalPaneMetricsFixture()
        defer { fixture.tearDown() }
        try await fixture.bind()
        TerminalWindowPortalRegistry.beginInteractiveGeometryResize(in: fixture.window)
        var dividerActive = true
        defer {
            if dividerActive { TerminalWindowPortalRegistry.endInteractiveGeometryResize(in: fixture.window) }
        }
        fixture.split.setPosition(320, ofDividerAt: 0)
        TerminalWindowPortalRegistry.synchronizeExternalGeometryNow(for: fixture.window)
        #expect(fixture.surface.committedPaneGeometry?.phase == .interactive)
        TerminalWindowPortalRegistry.endInteractiveGeometryResize(in: fixture.window)
        dividerActive = false
        try await fixture.settle()
        #expect(fixture.surface.committedPaneGeometry?.phase == .settled)
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
        for span in rendered.frame.rowSpans {
            let cellWidth = try #require(span.cellWidth)
            #expect(span.row < sample.rows)
            #expect(span.column + cellWidth <= sample.columns)
        }
        #expect(rendered.rows.allSatisfy { $0.count <= sample.columns })
        // The native render-grid export is the physical reflow oracle above,
        // but it can omit soft-wrapped text while a hidden pane is settling.
        // Ghostty's direct reader preserves those logical lines and their
        // markers, which is the behavior this regression path needs to prove.
        let text = try readSurfaceText(fixture)
        let compact = text.filter { !$0.isWhitespace }
        for index in 1...4 {
            let expected = "R\(index)" + String(repeating: "=", count: 74) + "END\(index)"
            #expect(compact.components(separatedBy: expected).count == 2)
            #expect(compact.components(separatedBy: "R\(index)").count == 2)
            #expect(compact.components(separatedBy: "END\(index)").count == 2)
        }
    }

    private func readSurfaceText(_ fixture: TerminalPaneMetricsFixture) throws -> String {
        let runtime = try #require(fixture.surface.surface)
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_SURFACE,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_SURFACE,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0
            ),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(runtime, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(runtime, &text) }
        guard let pointer = text.text, text.text_len > 0 else { return "" }
        return String(
            decoding: Data(bytes: pointer, count: Int(text.text_len)),
            as: UTF8.self
        )
    }
}
