import AppKit
import CmuxTerminalCore
import Foundation
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Cmd-hover and Cmd-click on a bare filename map the pointer to the clicked
/// cell. `GHOSTTY_ACTION_CELL_SIZE` reports backing pixels, so on a 2x display
/// the stored `cellSize` is twice the cell in view points (issue #26381).
@MainActor
@Suite(.serialized)
struct TerminalCommandClickCellMappingTests {
    @Test("Cmd-hover on a 2x display reads the row under the pointer", .timeLimit(.minutes(1)))
    func commandHoverReadsThePointedRowWhenCellSizeIsInBackingPixels() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cmd-click-cells-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let names = (1...60).map { String(format: "row%02d.txt", $0) }
        for name in names {
            try Data().write(to: directory.appendingPathComponent(name))
        }

        let fixture = TerminalPortalTestWorkspace()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        fixture.bind(to: window)
        window.makeKeyAndOrderFront(nil)
        let anchor = NSView(frame: NSRect(x: 8, y: 8, width: 520, height: 280))
        window.contentView?.addSubview(anchor)
        let portal = WindowTerminalPortal(window: window)
        let panel = try #require(fixture.workspace.focusedTerminalPanel)
        defer {
            panel.surface.releaseHostedSurfaceForTesting()
            portal.tearDown()
            window.close()
            fixture.tearDown()
        }
        panel.hostedView.setVisibleInUI(true)
        portal.bind(hostedView: panel.hostedView, to: anchor, visibleInUI: true)
        panel.surface.requestInputDemandSurfaceStartIfNeeded()
        fixture.workspace.panelDirectories[panel.id] = directory.path

        let rows = try await waitForGrid(panel)
        try #require(rows > 6)
        try #require(panel.surface.sendInput("cd '\(directory.path)' && clear && ls -1 row*.txt; cat\r"))
        let lines = try await waitForVisibleLines(panel, rows: rows, containing: names[names.count - 1])

        // `cat` holds the screen still: no prompt redraws under the hover.
        // The last listed row. Read with pixel cell sizes, the pointer lands
        // at half its offset from the top, on another filename that exists.
        let rowOffset = max(0, rows - lines.count)
        let targetRow = try #require(lines.indices.last(where: { lines[$0].hasPrefix("row") }))
        let halvedRow = (targetRow + rowOffset) / 2 - rowOffset
        try #require(halvedRow >= 0 && lines[halvedRow].hasPrefix("row") && halvedRow != targetRow)
        let expected = lines[targetRow].trimmingCharacters(in: .whitespaces)

        var metrics = ghostty_surface_grid_metrics_s()
        let runtime = try #require(panel.surface.surface)
        try #require(ghostty_surface_grid_metrics(runtime, &metrics))
        let surfaceView = panel.hostedView.surfaceView
        // The pointer below comes from the same grid metrics the lookup uses,
        // so pin their unit to sources outside them: a cell is the backing
        // pixel cell divided by the window's scale, and the grid fits the view
        // in points. A metrics scale error fails here on a 2x host.
        let pixelSize = ghostty_surface_size(runtime)
        let scale = Double(window.backingScaleFactor)
        #expect(abs(metrics.cell_width * scale - Double(pixelSize.cell_width_px)) < 0.01, "scale=\(scale)")
        #expect(abs(metrics.cell_height * scale - Double(pixelSize.cell_height_px)) < 0.01, "scale=\(scale)")
        #expect(metrics.padding_top + Double(metrics.rows) * metrics.cell_height <= surfaceView.bounds.height + 0.5)
        #expect(metrics.padding_left + Double(metrics.columns) * metrics.cell_width <= surfaceView.bounds.width + 0.5)
        // What Ghostty reports on a 2x display, whatever the test host's scale.
        surfaceView.cellSize = CGSize(width: metrics.cell_width * 2, height: metrics.cell_height * 2)
        let point = NSPoint(
            x: metrics.padding_left + 4.5 * metrics.cell_width,
            y: surfaceView.bounds.height
                - (metrics.padding_top + (Double(targetRow + rowOffset) + 0.5) * metrics.cell_height)
        )

        let details = surfaceView.debugSimulateCommandHoverDetails(at: point)
        #expect(details["rawToken"] as? String == expected, "\(details)")
        #expect((details["resolvedPath"] as? String)?.hasSuffix("/\(expected)") == true, "\(details)")
    }

    private func waitForGrid(_ panel: TerminalPanel) async throws -> Int {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        repeat {
            var metrics = ghostty_surface_grid_metrics_s()
            if let runtime = panel.surface.surface,
               panel.surface.committedPaneGeometry?.phase == .settled,
               ghostty_surface_grid_metrics(runtime, &metrics),
               metrics.rows > 1, metrics.columns > 1, metrics.cell_height > 0 {
                return Int(metrics.rows)
            }
            await yieldToMainQueue()
        } while ContinuousClock.now < deadline && !Task.isCancelled
        Issue.record("terminal runtime never reported a grid")
        throw CancellationError()
    }

    private func waitForVisibleLines(
        _ panel: TerminalPanel,
        rows: Int,
        containing needle: String
    ) async throws -> [String] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var lines: [String] = []
        repeat {
            let text = TerminalController.shared.readTerminalTextForSnapshot(
                terminalPanel: panel,
                lineLimit: max(200, rows * 4)
            ) ?? ""
            lines = text.visibleLines(rows: rows)
            if lines.contains(where: { $0.hasPrefix(needle) }) { return lines }
            await yieldToMainQueue()
        } while ContinuousClock.now < deadline && !Task.isCancelled
        Issue.record("listing never reached the screen: \(lines)")
        throw CancellationError()
    }

    private func yieldToMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
