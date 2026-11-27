@preconcurrency import XCTest
import AppKit
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// An anchor that can run portal work from inside its own layout pass —
/// the stack shape of the production anchor-container callbacks, where
/// portal syncs run while the layout engine is mid-walk.
private final class LayoutSyncingAnchorView: NSView {
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        onLayout?()
    }
}

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
        // Only autoresizing-translated constraints may involve the host,
        // and they are tolerated rather than trusted: a flexible mask
        // translates into edge pins whose frozen margins re-derive size on
        // every superview resize — the exact mechanism that stomped
        // portal-hosted views until adoption started clearing their masks.
        // The host keeps its [.width, .height] mask deliberately (it must
        // track the theme frame) and the portal stays its only frame
        // writer. What this test bans is the dangerous kind: an explicit
        // constraint tying the host to another view, which reads the
        // engine's solution for the OTHER view.
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

    /// The unit-test window carries no NSHostingView, so nothing activates
    /// the window's layout engine on its own and translated-autoresizing
    /// views never acquire an engine solution. The live windows are the
    /// opposite (hosting views everywhere), and the engine's solution for
    /// hosted views is the writer in the 5pt ping-pong. One constraint-based
    /// view is enough to switch the whole window over.
    @MainActor
    private func activateWindowLayoutEngine(in contentView: NSView) {
        let engineDriver = NSView()
        engineDriver.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(engineDriver)
        NSLayoutConstraint.activate([
            engineDriver.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            engineDriver.topAnchor.constraint(equalTo: contentView.topAnchor),
            engineDriver.widthAnchor.constraint(equalToConstant: 4),
            engineDriver.heightAnchor.constraint(equalToConstant: 4),
        ])
    }

    /// Live-fuzz regression (seed 4, iter 13): the window's layout engine
    /// holds an autoresizing-translated frame solution for each hosted view,
    /// frozen at a previous layout generation. The portal restored plan truth
    /// every pass; the very next layout flush re-applied the stale solution
    /// (exactly +5pt wide); full_hierarchy_sync hit 14,258 per settle window
    /// versus a healthy ~17. The re-apply wins because the portal's writes
    /// land mid-turn, so constraint re-translation only ever samples the
    /// frame AFTER the engine has stomped it — the engine perpetually
    /// re-learns its own stale value. The contract: once the portal owns a
    /// view, no layout flush of any scope may move the frame off the
    /// portal's last write.
    @MainActor
    func testHostedFrameRestoreSurvivesLayoutFlush() throws {
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
        activateWindowLayoutEngine(in: contentView)
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

        let settled = hosted.frame
        XCTAssertGreaterThan(settled.width, 1, "fixture: the hosted view must be placed")

        // The stale generation: an external writer moves the view +5pt (the
        // live delta), and a full window pass lets the engine learn whatever
        // the actual frame now is.
        hosted.frame = NSRect(
            x: settled.origin.x, y: settled.origin.y,
            width: settled.width + 5, height: settled.height
        )
        contentView.superview?.needsLayout = true
        contentView.superview?.layoutSubtreeIfNeeded()

        // The portal's restore, exactly as the live pump makes it: from an
        // anchor callback stack, no ancestor flush allowed.
        portal.synchronizeHostedViewForAnchor(anchor, syncLayout: false)
        XCTAssertEqual(
            hosted.frame.width, settled.width, accuracy: 0.5,
            "the portal restore itself must land"
        )

        // The pump's flush: refreshSurfaceNow runs layoutSubtreeIfNeeded on
        // the hosted view alone. In the live capture this is where the
        // engine stomped the restore back to +5pt within 11ms.
        hosted.needsLayout = true
        hosted.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            hosted.frame.width, settled.width, accuracy: 0.5,
            "a hosted-subtree layout flush must not re-apply the engine's stale solution — "
                + "that re-apply is the 5pt frame ping-pong from the live fuzz"
        )

        // And a full window pass must converge on portal truth, not restore
        // the stale generation.
        contentView.superview?.needsLayout = true
        contentView.superview?.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            hosted.frame.width, settled.width, accuracy: 0.5,
            "a full window layout pass must converge on the portal's frame"
        )
        withExtendedLifetime(hosted) {}
    }

    /// The live pump, reproduced: the layout engine's autoresizing
    /// constants for a hosted view only re-translate when the view holding
    /// those constraints runs an update-constraints pass. A portal restore
    /// that is immediately chased by a hosted-subtree layout flush (the
    /// surface-refresh shape) never reaches that stable point: the flush
    /// re-applies the engine's stale solution, the next restore is chased
    /// by the next flush, and the constants only ever sample the engine's
    /// own stomp. The portal must therefore re-translate the constants as
    /// part of every frame write, so a flush of any scope can only apply
    /// portal truth.
    @MainActor
    func testRestoreChasedByHostedSubtreeFlushConverges() throws {
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
        activateWindowLayoutEngine(in: contentView)
        let portal = makeTrackedPortal(window: window)
        let anchor = LayoutSyncingAnchorView(frame: NSRect(x: 8, y: 8, width: 240, height: 160))
        contentView.addSubview(anchor)
        let hosted = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        )
        portal.bind(hostedView: hosted, to: anchor, visibleInUI: true)
        realizeWindowLayout(window)
        portal.synchronizeHostedViewForAnchor(anchor)
        drainMainQueue()
        drainMainQueue()

        let settled = hosted.frame
        XCTAssertGreaterThan(settled.width, 1, "fixture: the hosted view must be placed")

        // Freeze a stale generation: an external writer moves the view +5pt
        // (the live delta) and a full window pass lets the engine learn it.
        hosted.frame = NSRect(
            x: settled.origin.x, y: settled.origin.y,
            width: settled.width + 5, height: settled.height
        )
        contentView.superview?.needsLayout = true
        contentView.superview?.layoutSubtreeIfNeeded()

        // The pump: a mid-layout restore (the anchor-callback stack, no
        // ancestor flush allowed) chased by a hosted-subtree flush, over and
        // over — the exact per-display-cycle shape from the live capture.
        for _ in 0..<3 {
            anchor.onLayout = { [weak portal, weak anchor] in
                guard let portal, let anchor else { return }
                portal.synchronizeHostedViewForAnchor(anchor, syncLayout: false)
            }
            anchor.needsLayout = true
            contentView.superview?.needsLayout = true
            contentView.superview?.layoutSubtreeIfNeeded()
            anchor.onLayout = nil
            hosted.needsLayout = true
            hosted.layoutSubtreeIfNeeded()
        }
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(
            hosted.frame.width, settled.width, accuracy: 0.5,
            "restores chased by hosted-subtree flushes must converge on portal truth — "
                + "a re-applied stale engine solution here is the 5pt frame ping-pong"
        )

        // And it must hold across one more full pass: convergence, not a
        // lucky sample of an ongoing oscillation.
        contentView.superview?.needsLayout = true
        contentView.superview?.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            hosted.frame.width, settled.width, accuracy: 0.5,
            "the converged frame must survive a full window layout pass"
        )
        withExtendedLifetime(hosted) {}
    }

    /// The width constant the layout engine holds for a view, read from the
    /// autoresizing-translated constraint on its superview. This IS the
    /// engine's solution: whatever value sits here is what the next layout
    /// flush applies to the view's frame.
    @MainActor
    private func engineWidthConstant(for view: NSView) -> CGFloat? {
        guard let holder = view.superview else { return nil }
        return holder.constraints.first {
            String(describing: type(of: $0)) == "NSAutoresizingMaskLayoutConstraint"
                && $0.firstItem === view
                && $0.firstAttribute == .width
        }?.constant
    }

    /// The load-bearing invariant behind the 5pt frame ping-pong. The
    /// engine's autoresizing constants for a hosted view only re-translate
    /// when an update-constraints pass runs over the holder; a portal write
    /// whose constants are still stale loses to the very next layout flush,
    /// and because the stomp lands before the constants ever sample the
    /// write, the engine re-learns its own stale value forever — restores
    /// and stomps alternate per display cycle and hierarchy syncs run into
    /// the thousands per settle window. The contract that kills the loop at
    /// its root: a completed clean-turn portal write leaves the engine's
    /// constants already equal to the written frame, BEFORE any flush gets
    /// a chance to run.
    @MainActor
    func testCleanTurnPortalWritePinsEngineConstantsBeforeAnyFlush() throws {
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
        activateWindowLayoutEngine(in: contentView)
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

        let settled = hosted.frame
        XCTAssertGreaterThan(settled.width, 1, "fixture: the hosted view must be placed")

        // Freeze a stale engine generation: an external stomp plus a full
        // window pass re-translates the engine's constants to the stomp.
        hosted.frame = NSRect(
            x: settled.origin.x, y: settled.origin.y,
            width: settled.width + 5, height: settled.height
        )
        contentView.superview?.needsLayout = true
        contentView.superview?.layoutSubtreeIfNeeded()
        guard let staleConstant = engineWidthConstant(for: hosted) else {
            XCTFail("fixture: the engine holds no autoresizing width constant for the hosted view")
            return
        }
        XCTAssertEqual(
            staleConstant, settled.width + 5, accuracy: 0.5,
            "fixture: the full pass must have taught the engine the stomped width"
        )

        // The portal restore, on the one sync path that writes with flushes
        // permitted (the interactive fan-out — outside a drag, anchor syncs
        // coalesce into the scheduled pass instead). This is the pump's
        // shape: pre-fix, the reconcile flush inside this very call is what
        // re-applied the engine's stale solution over the fresh write. No
        // drains after — the constants must be correct when this returns.
        TerminalWindowPortalRegistry.isPointerDragActiveForTesting = true
        portal.synchronizeHostedViewForAnchor(anchor)
        TerminalWindowPortalRegistry.isPointerDragActiveForTesting = false

        XCTAssertEqual(
            hosted.frame.width, settled.width, accuracy: 0.5,
            "the portal restore must land"
        )
        XCTAssertEqual(
            engineWidthConstant(for: hosted) ?? -1, settled.width, accuracy: 0.5,
            "a completed portal write must leave the engine's autoresizing constants equal to "
                + "the written frame — stale constants here are what every later layout flush "
                + "re-applies, which is the 5pt frame ping-pong"
        )
        withExtendedLifetime(hosted) {}
    }

    /// The root of the frame ping-pong, pinned by live forensics: hosted
    /// views arrive from SwiftUI hosting with a flexible autoresizing mask
    /// ([.width, .height]), which the layout engine translates into EDGE
    /// pins — a minX constant plus a trailing margin to the host, no width
    /// at all. Those margins freeze at translation time, so whenever the
    /// host resizes, the engine re-derives the pane's size from stale
    /// margins against the new host bounds and stomps the portal's write
    /// (live: panes re-inflated to a previous generation's geometry,
    /// hierarchy syncs in the thousands per settle window). The portal is
    /// the sole writer of hosted geometry, so adoption must clear the mask:
    /// an empty mask translates to rigid position+size constants that
    /// always equal the last portal write, leaving the engine nothing to
    /// re-derive. Detach restores the original mask for the view's normal
    /// AppKit life.
    @MainActor
    func testPortalAdoptionDecouplesHostedViewFromHostResizing() throws {
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
        activateWindowLayoutEngine(in: contentView)
        let portal = makeTrackedPortal(window: window)
        let anchor = NSView(frame: NSRect(x: 8, y: 8, width: 240, height: 160))
        contentView.addSubview(anchor)
        let hosted = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        )
        // How production views reach the portal: SwiftUI hosting has already
        // given them the flexible mask.
        hosted.autoresizingMask = [.width, .height]
        portal.bind(hostedView: hosted, to: anchor, visibleInUI: true)
        realizeWindowLayout(window)
        portal.synchronizeHostedViewForAnchor(anchor)
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(
            hosted.autoresizingMask, [],
            "adoption must clear the hosted view's autoresizing mask — a flexible mask "
                + "translates to edge pins whose frozen margins re-derive the pane's size on "
                + "every host resize, fighting the portal's writes"
        )

        let settled = hosted.frame
        XCTAssertGreaterThan(settled.width, 1, "fixture: the hosted view must be placed")

        // A host resize. The anchor keeps its frame (empty mask), so portal
        // truth for the pane is unchanged — nothing may resize it.
        let base = window.frame
        window.setFrame(
            NSRect(x: base.origin.x, y: base.origin.y,
                   width: base.width + 120, height: base.height + 90),
            display: true
        )
        XCTAssertEqual(
            hosted.frame.width, settled.width, accuracy: 0.5,
            "a host resize must not move a portal-hosted view: the engine re-deriving the "
                + "pane from frozen edge margins against the new host bounds is the live stomp"
        )
        XCTAssertEqual(
            hosted.frame.height, settled.height, accuracy: 0.5,
            "a host resize must not resize a portal-hosted view vertically either"
        )

        // Detach returns the view to its normal AppKit life, mask restored.
        portal.detachHostedView(withId: ObjectIdentifier(hosted))
        XCTAssertEqual(
            hosted.autoresizingMask, [.width, .height],
            "detach must restore the pre-adoption autoresizing mask"
        )
        withExtendedLifetime(hosted) {}
    }

    /// The crash guard for this bug's tempting-but-fatal fix shape. Any
    /// frame setter that swallows or rewrites the engine's apply leaves the
    /// engine's bookkeeping divergent from the actual frame; the window
    /// then re-posts update-constraints passes until NSWindow's per-cycle
    /// budget raises an uncaught NSException from whatever view posts next
    /// (in the live crash, an unrelated titlebar view). That is why the
    /// portal never vetoes engine writes and instead keeps the engine's
    /// solution equal to portal truth. A rapid resize burst in an
    /// engine-active window is the trigger; surviving it with converged
    /// geometry is the contract. This test crashing the host IS the finding.
    @MainActor
    func testRapidResizeBurstKeepsPortalFramesConvergedWithoutException() throws {
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
        activateWindowLayoutEngine(in: contentView)
        let portal = makeTrackedPortal(window: window)
        let anchor = NSView(frame: NSRect(x: 8, y: 8, width: 240, height: 160))
        anchor.autoresizingMask = [.width, .height]
        contentView.addSubview(anchor)
        let hosted = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        )
        portal.bind(hostedView: hosted, to: anchor, visibleInUI: true)
        realizeWindowLayout(window)
        portal.synchronizeHostedViewForAnchor(anchor)
        drainMainQueue()

        let base = window.frame
        for step in 0..<40 {
            let delta = CGFloat((step % 7) * 16)
            window.setFrame(
                NSRect(x: base.origin.x, y: base.origin.y,
                       width: base.width + delta, height: base.height + delta),
                display: true
            )
            // The live pump's mid-turn ingredients: an anchor-callback sync
            // (no ancestor flush) followed by a hosted-subtree layout flush.
            portal.synchronizeHostedViewForAnchor(anchor, syncLayout: false)
            hosted.needsLayout = true
            hosted.layoutSubtreeIfNeeded()
            contentView.superview?.needsLayout = true
            contentView.superview?.layoutSubtreeIfNeeded()
        }
        window.setFrame(base, display: true)
        portal.synchronizeHostedViewForAnchor(anchor)
        drainMainQueue()
        drainMainQueue()

        let anchorInHost = portal.hostView.convert(anchor.bounds, from: anchor)
        XCTAssertEqual(
            hosted.frame.width, anchorInHost.width, accuracy: 1.0,
            "after the burst the hosted frame must converge on the anchor's geometry"
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
