#if canImport(UIKit)
import CMUXMobileCore
import Foundation
import Testing
import UIKit

@testable import CmuxMobileTerminal

/// Regression coverage for #7275: row auto-fit must not turn a phone-width
/// terminal into a preview-width grid by inflating the rendered font until only
/// ~26-28 columns fit across the whole phone.
@MainActor
private final class ViewportColumnFitDelegate: NSObject, GhosttySurfaceViewDelegate {
    private(set) var reports: [TerminalGridSize] = []
    private(set) var reportIDs: [TerminalGridSize: UInt64] = [:]
    var autoEchoMacGrid: (cols: Int, rows: Int)?

    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {}

    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize, reportID: UInt64) {
        reports.append(size)
        reportIDs[size] = reportID
        if let mac = autoEchoMacGrid {
            surfaceView.markViewportReportConfirmed()
            surfaceView.applyConfirmedViewSize(
                cols: min(size.columns, mac.cols),
                rows: min(size.rows, mac.rows),
                reportID: reportID
            )
        }
    }
}

@MainActor
private final class ViewportColumnFitHarness {
    let window: UIWindow
    let view: GhosttySurfaceView
    let delegate: ViewportColumnFitDelegate

    init() throws {
        let runtime = try GhosttyRuntime.shared()
        let delegate = ViewportColumnFitDelegate()
        let view = GhosttySurfaceView(runtime: runtime, delegate: delegate, fontSize: 10)
        view.autoFocusOnWindowAttach = false
        view.isRenderDispatchSuppressed = true
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        self.window = window
        self.view = view
        self.delegate = delegate
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    func tearDown() {
        view.prepareForDismantle()
        view.removeFromSuperview()
        window.isHidden = true
    }

    var snapshot: GhosttySurfaceView.DebugGeometrySnapshot {
        view.debugGeometrySnapshotForTesting()
    }

    @discardableResult
    func pump(timeout: TimeInterval = 5, until condition: () -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    func waitForReport(after count: Int, timeout: TimeInterval = 5) async -> TerminalGridSize? {
        guard await pump(timeout: timeout, until: { self.delegate.reports.count > count }) else { return nil }
        return delegate.reports.last
    }

    func echo(_ report: TerminalGridSize, macColumns: Int = .max, macRows: Int = .max) {
        view.markViewportReportConfirmed()
        view.applyConfirmedViewSize(
            cols: min(report.columns, macColumns),
            rows: min(report.rows, macRows),
            reportID: delegate.reportIDs[report] ?? 0
        )
    }
}

@MainActor
@Suite("Terminal viewport column fit", .serialized)
struct TerminalViewportColumnFitTests {
    @Test("row auto-fit preserves phone-width columns")
    func rowAutoFitDoesNotCollapsePhoneWidthColumns() async throws {
        let harness = try ViewportColumnFitHarness()
        defer { harness.tearDown() }

        let initial = try #require(
            await harness.waitForReport(after: 0),
            "view never reported its natural grid"
        )
        #expect(initial.columns >= 40)
        #expect(initial.rows >= 20)
        harness.echo(initial)

        let minimumPhoneWidthColumns = max(1, Int((Double(initial.columns) * 0.75).rounded(.down)))
        let rowConstrainedGrid = max(6, initial.rows / 3)
        harness.delegate.autoEchoMacGrid = (cols: initial.columns, rows: rowConstrainedGrid)
        let beforeConstraintReports = harness.delegate.reports.count
        await harness.view.applyViewSizeAndWait(cols: initial.columns, rows: rowConstrainedGrid)
        let postFitReport = try #require(
            await harness.waitForReport(after: beforeConstraintReports, timeout: 8),
            "row-constrained grid never re-reported after auto-fit"
        )

        let settled = await harness.pump(timeout: 8) {
            let snapshot = harness.snapshot
            return snapshot.effectiveGrid?.rows == rowConstrainedGrid
                && snapshot.renderedSize?.columns == postFitReport.columns
                && snapshot.liveFontSize > snapshot.baseFontSize + 0.25
        }
        #expect(settled, "row-constrained grid did not settle")

        let snapshot = harness.snapshot
        let renderedColumns = try #require(snapshot.renderedSize?.columns)
        #expect(
            renderedColumns >= minimumPhoneWidthColumns,
            """
            row auto-fit collapsed the phone grid from \(initial.columns) to \(renderedColumns) columns \
            (minimum \(minimumPhoneWidthColumns), live font \(snapshot.liveFontSize), \
            base \(snapshot.baseFontSize), effective \(snapshot.effectiveGrid.map { "\($0.cols)x\($0.rows)" } ?? "nil"))
            """
        )
    }
}
#endif
