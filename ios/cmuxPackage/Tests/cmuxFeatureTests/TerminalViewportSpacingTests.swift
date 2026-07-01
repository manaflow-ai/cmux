#if canImport(UIKit)
import CMUXMobileCore
import Foundation
import Testing
import UIKit

@testable import CmuxMobileTerminal

/// In-simulator behavior coverage for the terminal's vertical spacing: the
/// rendered grid must stretch to the full viewport (bounds minus keyboard /
/// toolbar / safe-area reservation) whenever the daemon grid allows it, across
/// keyboard open/close orderings and Mac-side window resizes.
///
/// These tests mount a REAL `GhosttySurfaceView` (real libghostty surface, real
/// display link) in a window and play the exact message sequences the
/// `GhosttySurfaceRepresentable.Coordinator` plays in production:
///
/// - The view reports its natural grid via `didResize` (debounced on the
///   display link).
/// - The "Mac" (the test) echoes an effective grid back through
///   `applyConfirmedViewSize` — in production this echo is the async
///   `store.updateTerminalViewport` RPC reply, so echoes can arrive LATE and
///   OUT OF ORDER relative to newer reports.
/// - Mac window resizes arrive as daemon pushes through `applyViewSize`.
///
/// The user-visible invariant under test: empty space above the terminal
/// content (`renderRect.minY`, the render is bottom-pinned) never exceeds one
/// cell once the negotiated grid covers the phone's natural capacity. The
/// opencode "ton of extra space at top" screenshot is exactly this invariant
/// breaking: a stale keyboard-up viewport echo landing after the keyboard
/// closed pins the phone to the old, smaller grid forever.
@MainActor
private final class ViewportSpacingDelegate: NSObject, GhosttySurfaceViewDelegate {
    /// Every natural-grid report the view has emitted, in order.
    private(set) var reports: [TerminalGridSize] = []

    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {}

    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize) {
        reports.append(size)
    }
}

@MainActor
private final class ViewportSpacingHarness {
    let window: UIWindow
    let view: GhosttySurfaceView
    let delegate: ViewportSpacingDelegate

    /// A keyboard overlap tall enough to change the natural row count by many
    /// rows at the 10pt test font, mirroring a real iPhone keyboard.
    static let keyboardHeight: CGFloat = 336

    init() throws {
        let runtime = try GhosttyRuntime.shared()
        let delegate = ViewportSpacingDelegate()
        let view = GhosttySurfaceView(runtime: runtime, delegate: delegate, fontSize: 10)
        // No first-responder churn: a real software keyboard would post frame
        // notifications that race the scripted keyboard heights below.
        view.autoFocusOnWindowAttach = false
        // The xctest host has no window scene, so a Metal present can never
        // complete here; skip render dispatch so the render-stall recovery
        // never pauses the geometry pipeline under test.
        view.debugSkipRenderDispatchForTesting = true
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

    /// Measured cell height in points; the tolerance unit for "fills".
    var cellHeightPoints: CGFloat {
        let snap = snapshot
        guard snap.cellPixelSize.height > 0 else { return 24 }
        return snap.cellPixelSize.height / max(snap.screenScale, 1)
    }

    /// Empty space above the terminal content, the exact artifact in the
    /// opencode screenshot. The render rect is bottom-pinned to the viewport,
    /// so all letterbox slack shows at the top.
    var topGap: CGFloat {
        let snap = snapshot
        return snap.renderRect.minY - snap.viewportRect.minY
    }

    /// Gap between the render bottom and the viewport bottom; must stay ~0 in
    /// every state (content rides the keyboard/toolbar edge).
    var bottomGap: CGFloat {
        let snap = snapshot
        return snap.viewportRect.maxY - snap.renderRect.maxY
    }

    /// Wait (yielding the main actor so the display link and the surface
    /// queue's main-queue completions can run — a synchronous run-loop pump
    /// cannot drain the main dispatch queue from inside a main-queue job)
    /// until `condition` holds. Returns false on timeout.
    @discardableResult
    func pump(timeout: TimeInterval = 5, until condition: () -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// Wait a fixed interval so state that is EXPECTED to stay put has a
    /// chance to wrongly change (used before asserting an invariant held).
    func settle(_ interval: TimeInterval = 0.6) async {
        let deadline = Date(timeIntervalSinceNow: interval)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Wait for the next natural-grid report after `count` prior reports.
    func waitForReport(after count: Int, timeout: TimeInterval = 5) async -> TerminalGridSize? {
        guard await pump(timeout: timeout, until: { self.delegate.reports.count > count }) else { return nil }
        return delegate.reports.last
    }

    /// Play the Mac's role for one report: confirm it and echo the effective
    /// grid (`min` against the Mac's own grid, the daemon policy).
    func echo(_ report: TerminalGridSize, macColumns: Int = .max, macRows: Int = .max) {
        view.markViewportReportConfirmed()
        view.applyConfirmedViewSize(
            cols: min(report.columns, macColumns),
            rows: min(report.rows, macRows)
        )
    }

    /// Wait until the rendered content fills the viewport within one cell.
    func waitForFill(timeout: TimeInterval = 5) async -> Bool {
        await pump(timeout: timeout) {
            let snap = self.snapshot
            guard snap.renderRect.height > 1 else { return false }
            let cell = self.cellHeightPoints
            return self.topGap <= cell + 1 && self.bottomGap <= 1
        }
    }
}

@MainActor
@Suite("Terminal viewport vertical spacing", .serialized)
struct TerminalViewportSpacingTests {
    /// Baseline: after attach and the natural-grid handshake, the terminal
    /// fills the whole viewport (no letterbox, no top gap).
    @Test("natural grid fills the viewport after attach")
    func attachFillsViewport() async throws {
        let harness = try ViewportSpacingHarness()
        defer { harness.tearDown() }

        let report = await harness.waitForReport(after: 0)
        let initial = try #require(report, "view never reported its natural grid")
        #expect(initial.columns > 10)
        #expect(initial.rows > 10)

        harness.echo(initial)
        #expect(await harness.waitForFill(), "top gap \(harness.topGap)pt, bottom gap \(harness.bottomGap)pt, cell \(harness.cellHeightPoints)pt")
    }

    /// Keyboard open then close, echoes arriving in order after each report.
    /// Both settled states must fill their viewport.
    @Test("keyboard open/close with in-order echoes fills at every settle")
    func keyboardOpenCloseInOrder() async throws {
        let harness = try ViewportSpacingHarness()
        defer { harness.tearDown() }

        let initial = try #require(await harness.waitForReport(after: 0))
        harness.echo(initial)
        #expect(await harness.waitForFill())

        // Keyboard opens: viewport shrinks, view reports a smaller grid.
        let beforeOpen = harness.delegate.reports.count
        harness.view.setKeyboardHeightForTesting(ViewportSpacingHarness.keyboardHeight)
        let openReport = try #require(
            await harness.waitForReport(after: beforeOpen),
            "no report after keyboard open"
        )
        #expect(openReport.rows < initial.rows)
        harness.echo(openReport)
        #expect(await harness.waitForFill(), "keyboard-up: top gap \(harness.topGap)pt")

        // Keyboard closes: viewport grows back, view re-reports, echo restores.
        let beforeClose = harness.delegate.reports.count
        harness.view.setKeyboardHeightForTesting(0)
        let closeReport = try #require(
            await harness.waitForReport(after: beforeClose),
            "no report after keyboard close"
        )
        #expect(closeReport.rows > openReport.rows)
        harness.echo(closeReport)
        #expect(await harness.waitForFill(), "keyboard-down: top gap \(harness.topGap)pt")
    }

    /// THE OPENCODE BUG: the echo for the keyboard-UP report arrives AFTER the
    /// echo for the newer keyboard-DOWN report (out-of-order async RPC replies,
    /// exactly what `Coordinator.didResize`'s detached per-report Tasks allow).
    /// The stale echo must NOT re-pin the phone to the old smaller grid: the
    /// natural grid never changed afterwards, so nothing would ever re-report
    /// and the top gap would be permanent.
    @Test("stale keyboard-up echo after keyboard-down echo must not shrink the grid")
    func staleEchoAfterNewerEchoKeepsFill() async throws {
        let harness = try ViewportSpacingHarness()
        defer { harness.tearDown() }

        let initial = try #require(await harness.waitForReport(after: 0))
        harness.echo(initial)
        #expect(await harness.waitForFill())

        // Keyboard opens; the report goes out but its echo is DELAYED.
        let beforeOpen = harness.delegate.reports.count
        harness.view.setKeyboardHeightForTesting(ViewportSpacingHarness.keyboardHeight)
        let openReport = try #require(await harness.waitForReport(after: beforeOpen))
        #expect(openReport.rows < initial.rows)

        // Keyboard closes before the open echo lands; the close report's echo
        // arrives FIRST.
        let beforeClose = harness.delegate.reports.count
        harness.view.setKeyboardHeightForTesting(0)
        let closeReport = try #require(await harness.waitForReport(after: beforeClose))
        #expect(closeReport.rows > openReport.rows)
        harness.echo(closeReport)
        #expect(await harness.waitForFill())

        // NOW the stale keyboard-up echo lands (out-of-order RPC reply).
        harness.echo(openReport)
        await harness.settle()

        let staleRows = openReport.rows
        let snap = harness.snapshot
        #expect(
            harness.topGap <= harness.cellHeightPoints + 1,
            """
            stale echo re-pinned the grid: top gap \(harness.topGap)pt \
            (viewport \(snap.viewportRect.height)pt, render \(snap.renderRect.height)pt, \
            eff \(snap.effectiveGrid.map { "\($0.cols)x\($0.rows)" } ?? "nil"), \
            stale rows \(staleRows), natural rows \(closeReport.rows))
            """
        )
        #expect(harness.bottomGap <= 1)
    }

    /// Mac window shrink (daemon push): the phone letterboxes with the content
    /// bottom-pinned — ALL slack at the top, none at the bottom — and shows the
    /// separator border. Mac window grows back: the phone reclaims the full
    /// viewport.
    @Test("mac window shrink letterboxes bottom-pinned, grow restores full height")
    func macResizeShrinkGrowRestoresFill() async throws {
        let harness = try ViewportSpacingHarness()
        defer { harness.tearDown() }

        let initial = try #require(await harness.waitForReport(after: 0))
        harness.echo(initial)
        #expect(await harness.waitForFill())

        // Mac window shrinks by 10 rows: daemon pushes the smaller grid.
        let shrunkenRows = initial.rows - 10
        await harness.view.applyViewSizeAndWait(cols: initial.columns, rows: shrunkenRows)
        let pinned = await harness.pump {
            let snap = harness.snapshot
            return snap.effectiveGrid?.rows == shrunkenRows && self.renderMatchesPin(harness)
        }
        #expect(pinned, "never letterboxed to \(shrunkenRows) rows: eff \(harness.snapshot.effectiveGrid.map { "\($0.cols)x\($0.rows)" } ?? "nil")")

        // The genuine letterbox: ~10 rows of slack, all of it at the top,
        // content still attached to the keyboard/toolbar edge at the bottom.
        let cell = harness.cellHeightPoints
        #expect(harness.topGap >= cell * 8, "expected ~10 rows of top letterbox, got \(harness.topGap)pt")
        #expect(harness.topGap <= cell * 12, "letterbox larger than the missing rows: \(harness.topGap)pt")
        #expect(harness.bottomGap <= 1, "content must stay bottom-pinned, bottom gap \(harness.bottomGap)pt")
        #expect(harness.snapshot.isLetterboxBorderVisible)

        // Mac window grows back: daemon pushes the full grid again.
        await harness.view.applyViewSizeAndWait(cols: initial.columns, rows: initial.rows)
        #expect(await harness.waitForFill(), "grow-back left top gap \(harness.topGap)pt")
    }

    /// A dropped echo (RPC timeout) must self-heal: the coordinator calls
    /// `retryViewportReport`, the view re-reports, and a successful echo of the
    /// retry restores the full-height render.
    @Test("dropped echo self-heals through the viewport report retry")
    func droppedEchoRetriesAndFills() async throws {
        let harness = try ViewportSpacingHarness()
        defer { harness.tearDown() }

        let initial = try #require(await harness.waitForReport(after: 0))
        harness.echo(initial)
        #expect(await harness.waitForFill())

        // Open + echo so a real pin exists, then close with the echo DROPPED.
        let beforeOpen = harness.delegate.reports.count
        harness.view.setKeyboardHeightForTesting(ViewportSpacingHarness.keyboardHeight)
        let openReport = try #require(await harness.waitForReport(after: beforeOpen))
        harness.echo(openReport)

        let beforeClose = harness.delegate.reports.count
        harness.view.setKeyboardHeightForTesting(0)
        let closeReport = try #require(await harness.waitForReport(after: beforeClose))
        #expect(closeReport.rows > openReport.rows)

        // The Mac never answers the close report; the coordinator's nil-result
        // path re-arms the report.
        let beforeRetry = harness.delegate.reports.count
        harness.view.retryViewportReport()
        let retried = try #require(
            await harness.waitForReport(after: beforeRetry),
            "retryViewportReport never re-emitted the natural grid"
        )
        #expect(retried.rows == closeReport.rows)

        // The retry's echo lands; the render must reclaim the full viewport.
        harness.echo(retried)
        #expect(await harness.waitForFill(), "after retry echo: top gap \(harness.topGap)pt")
    }

    /// Whether the render rect currently reflects the effective pin (used to
    /// wait out the async geometry pass after a daemon push).
    private func renderMatchesPin(_ harness: ViewportSpacingHarness) -> Bool {
        let snap = harness.snapshot
        guard let eff = snap.effectiveGrid, snap.cellPixelSize.height > 0 else { return false }
        let expected = CGFloat(eff.rows) * snap.cellPixelSize.height / max(snap.screenScale, 1)
        return abs(snap.renderRect.height - expected) <= snap.cellPixelSize.height / max(snap.screenScale, 1) + 1
    }
}
#endif
