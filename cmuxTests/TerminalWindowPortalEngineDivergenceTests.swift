@preconcurrency import XCTest
import AppKit
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension TerminalWindowPortalLifecycleTests {

    /// Live-fuzz regression (seed 1, iters 12-18). A hosted AppKit subtree
    /// carried a required width demand beyond the window; the hosting view
    /// refuses oversized frames, so the layout ENGINE's solution for it ran
    /// 175pt wider than any frame it actually held, forever. The portal host
    /// was edge-constrained to the hosting view — and constraints read the
    /// ENGINE's solution, not actual frames — so every layout pass stomped
    /// the host and every hosted terminal view to the unreachable +175pt
    /// geometry, the portal undid it, and the undo forced the next pass:
    /// full_hierarchy_sync in the thousands per settle window, panes pinned
    /// at plan+175 for minutes. The contract that closes the class: the
    /// portal owns the host's frame — no layout-engine constraint may
    /// involve the portal host, so no engine solution (divergent or not)
    /// can co-write it.
    @MainActor
    func testPortalHostCarriesNoLayoutEngineConstraints() throws {
        let window = makeTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340)
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        let portal = makeTrackedPortal(window: window)
        let anchor = NSView(frame: NSRect(x: 8, y: 8, width: 240, height: 160))
        contentView.addSubview(anchor)
        let hosted = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        )
        portal.bind(hostedView: hosted, to: anchor, visibleInUI: true)
        realizeWindowLayout(window)

        let host = portal.hostView
        // Autoresizing-translated constraints are the SAFE kind: AppKit
        // regenerates them from the view's ACTUAL frame, so they can never
        // carry an engine solution the frame doesn't already hold. The
        // dangerous kind is an explicit constraint tying the host to another
        // view — that reads the engine's solution for the OTHER view.
        let translatedClassName = "NSAutoresizingMaskLayoutConstraint"
        var offending: [NSLayoutConstraint] = []
        var current: NSView? = host
        while let view = current {
            offending.append(contentsOf: view.constraints.filter {
                ($0.firstItem === host || $0.secondItem === host)
                    && String(describing: type(of: $0)) != translatedClassName
            })
            current = view.superview
        }
        XCTAssertTrue(
            offending.isEmpty,
            "the portal host must carry no layout-engine constraints — constraints read the "
                + "engine's solution, and when a hosted subtree's required demand makes that "
                + "solution unreachable for the hosting view, they stomp the host to it on "
                + "every layout pass (the live +175pt hierarchy-sync storm): \(offending)"
        )
        withExtendedLifetime(hosted) {}
    }

    /// The behavioral half: whatever writer moves the portal host and a
    /// hosted view off portal truth (the live storm's writer was the layout
    /// engine applying a broken-constraint solution), one portal sync
    /// restores both from ACTUAL geometry, and a follow-up drain does not
    /// oscillate them back.
    @MainActor
    func testPortalRestoresHostAndHostedFramesAfterExternalStomp() throws {
        let window = makeTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340)
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        let portal = makeTrackedPortal(window: window)
        let anchor = NSView(frame: NSRect(x: 8, y: 8, width: 240, height: 160))
        contentView.addSubview(anchor)
        let hosted = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        )
        portal.bind(hostedView: hosted, to: anchor, visibleInUI: true)
        realizeWindowLayout(window)
        portal.synchronizeHostedViewForAnchor(anchor)
        drainMainQueue()
        drainMainQueue()

        let settledHost = portal.hostView.frame
        let settledHosted = hosted.frame
        XCTAssertGreaterThan(settledHost.width, 1, "fixture: the host must be installed")

        // The stomp: +175pt on both, the live storm's uniform delta.
        portal.hostView.frame = NSRect(
            x: settledHost.origin.x, y: settledHost.origin.y,
            width: settledHost.width + 175, height: settledHost.height
        )
        hosted.frame = NSRect(
            x: settledHosted.origin.x, y: settledHosted.origin.y,
            width: settledHosted.width + 175, height: settledHosted.height
        )
        portal.synchronizeHostedViewForAnchor(anchor)
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(
            portal.hostView.frame.width, settledHost.width, accuracy: 0.5,
            "one sync must restore the portal host from actual reference bounds"
        )
        XCTAssertEqual(
            hosted.frame.width, settledHosted.width, accuracy: 0.5,
            "one sync must restore a stomped hosted view to its anchor's frame"
        )

        drainMainQueue()
        drainMainQueue()
        XCTAssertEqual(
            portal.hostView.frame.width, settledHost.width, accuracy: 0.5,
            "the restore must hold — no oscillation on later turns"
        )
        withExtendedLifetime(hosted) {}
    }

    /// The deferred-hop follow-up under an interactive flag: a non-immediate
    /// request folded into a flushed pass gets one follow-up to honor its
    /// extra-hop contract. While an interactive flag holds (live resize,
    /// pointer drag), every pass flushes — the follow-up chain must still
    /// terminate on static geometry, not run one full sync per runloop turn
    /// for the whole gesture.
    @MainActor
    func testInteractiveFlagWithStaticGeometryDoesNotChainSyncPasses() throws {
        let window = makeTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340)
        )
        defer {
            TerminalWindowPortalRegistry.isPointerDragActiveForTesting = false
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        let anchor = NSView(frame: NSRect(x: 8, y: 8, width: 240, height: 160))
        contentView.addSubview(anchor)
        let hosted = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        )
        realizeWindowLayout(window)
        TerminalWindowPortalRegistry.bind(hostedView: hosted, to: anchor, visibleInUI: true)
        drainMainQueue()
        drainMainQueue()

        TerminalWindowPortalRegistry.isPointerDragActiveForTesting = true
        let baseline = RemoteTmuxSizingDiagnostics.externalGeometrySyncPassCount
        TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(
            for: window, forceImmediate: false
        )
        for _ in 0..<12 {
            drainMainQueue()
        }
        let executed = RemoteTmuxSizingDiagnostics.externalGeometrySyncPassCount - baseline
        XCTAssertLessThanOrEqual(
            executed, 4,
            "one deferred request under a held interactive flag ran \(executed) sync passes "
                + "across 12 static-geometry turns — the follow-up chain is a per-turn busy loop"
        )
        withExtendedLifetime(hosted) {}
    }

    /// The self-echo half of the hierarchy-sync storm (live seed 1, iter 21:
    /// full_hierarchy_sync 2520 in one settle window at a stationary
    /// layout). The portal's own frame writes post frame/bounds
    /// notifications synchronously, and the geometry observers re-armed the
    /// sync on them. The single-signature guard stops an echo whose
    /// geometry matches the last completed pass, but a stationary two-state
    /// disagreement alternates A,B,A,B — the guard can never latch, and the
    /// portal feeds its own loop forever. The structural rule: a write the
    /// portal itself makes schedules nothing; only genuinely external
    /// geometry re-arms. Observable: an external stomp of the host frame
    /// costs exactly ONE sync request — the pass that restores the frame
    /// must buy zero more with its own write.
    @MainActor
    func testPortalSelfFrameWritesDoNotRearmTheSync() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        let portal = WindowTerminalPortal(window: window)
        let anchor = NSView(frame: NSRect(x: 8, y: 8, width: 240, height: 160))
        contentView.addSubview(anchor)
        let hosted = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        )
        portal.bind(hostedView: hosted, to: anchor, visibleInUI: true)
        realizeWindowLayout(window)
        portal.synchronizeHostedViewForAnchor(anchor)

        // Quiesce: drain until a full drain adds no new sync requests, so
        // the stomp below is measured from a genuinely idle portal.
        var stableDrains = 0
        var lastCount = portal.externalGeometrySyncRequestCountForTesting
        for _ in 0..<40 {
            drainMainQueue()
            let now = portal.externalGeometrySyncRequestCountForTesting
            if now == lastCount {
                stableDrains += 1
                if stableDrains >= 3 { break }
            } else {
                stableDrains = 0
                lastCount = now
            }
        }
        XCTAssertGreaterThanOrEqual(
            stableDrains, 3,
            "fixture never quiesced: sync requests kept arriving with static geometry"
        )
        let settledHost = portal.hostView.frame
        XCTAssertGreaterThan(settledHost.width, 1, "fixture: the host must be installed")
        let baseline = portal.externalGeometrySyncRequestCountForTesting

        // The stomp: an external writer moves the host off portal truth.
        portal.hostView.frame = NSRect(
            x: settledHost.origin.x, y: settledHost.origin.y,
            width: settledHost.width + 175, height: settledHost.height
        )
        for _ in 0..<6 {
            drainMainQueue()
        }
        XCTAssertEqual(
            portal.hostView.frame.width, settledHost.width, accuracy: 0.5,
            "the sync pass must restore the stomped host frame from the reference"
        )
        XCTAssertEqual(
            portal.externalGeometrySyncRequestCountForTesting - baseline, 1,
            "an external stomp costs exactly one sync request; every request past it was "
                + "re-armed by the portal's own restoring write — the self-echo the "
                + "signature guard cannot stop when geometry alternates"
        )
        withExtendedLifetime(hosted) {}
    }
}
