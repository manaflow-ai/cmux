import AppKit
import CmuxRemoteSession
import CmuxTerminal
import SwiftUI
import Testing
@testable import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Pins the bonsplit assumptions the sizing design depends on, against the REAL
/// renderer — not a model. The pure layout tests prove the plan computes the
/// right per-pane point extents; these prove the thing that turns those extents
/// into pixels actually honors them:
///
///  1. `setImposedFirstExtent(X)` drives the first pane's real NSView frame to
///     X — placement is our computed extent, applied by bonsplit.
///  2. The remote-tmux embedded config's `minimumPaneWidth/Height = 1` means
///     even a tiny (one-cell-ish) extent is NOT clamped up — the design allows
///     1-cell tmux panes, so bonsplit must not impose a larger floor.
///  3. Panes tile their container (first + divider + second == available), so
///     the imposed split is space-filling with no gap or overrun.
///
/// If bonsplit ever regressed to clamp impositions or ignore them, the pure
/// tests would stay green while the app wrapped; this catches that.
@MainActor
@Suite struct RemoteTmuxBonsplitImpositionRenderTests {
    private func firstDescendant<T: NSView>(ofType type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for sub in root.subviews {
            if let match = firstDescendant(ofType: type, in: sub) { return match }
        }
        return nil
    }

    private static func ancestorChain(_ view: NSView) -> String {
        var names: [String] = []
        var current: NSView? = view.superview
        while let v = current {
            names.append(String(describing: type(of: v)))
            current = v.superview
        }
        return names.joined(separator: "<")
    }

    /// Split views that are visible at the APPKIT level: not hidden
    /// themselves and under no hidden ancestor. SwiftUI opacity does not
    /// register here — that is the point of the census.
    private func effectivelyVisibleSplitViews(
        in root: NSView, ancestorHidden: Bool = false
    ) -> [NSSplitView] {
        let hidden = ancestorHidden || root.isHidden
        var found: [NSSplitView] = []
        if let split = root as? NSSplitView, !hidden { found.append(split) }
        for sub in root.subviews {
            found.append(contentsOf: effectivelyVisibleSplitViews(in: sub, ancestorHidden: hidden))
        }
        return found
    }

    /// Builds a horizontal two-pane controller with the real embedded config,
    /// hosts it in a fixed-size window, and returns the live NSSplitView plus
    /// the split's UUID and the available (post-divider) width.
    private func makeHostedHorizontalSplit(
        windowWidth: CGFloat = 400,
        windowHeight: CGFloat = 300
    ) throws -> (controller: BonsplitController, window: NSWindow, splitView: NSSplitView, splitId: UUID, available: CGFloat) {
        let controller = BonsplitController(configuration: BonsplitConfiguration().remoteTmuxEmbedded)
        let rootPane = try #require(controller.allPaneIds.first)
        _ = controller.createTab(title: "left", icon: "terminal", kind: "terminal", inPane: rootPane)
        let rightPane = try #require(
            controller.splitPane(rootPane, orientation: .horizontal, withTab: nil, initialDividerPosition: 0.5)
        )
        _ = controller.createTab(title: "right", icon: "terminal", kind: "terminal", inPane: rightPane)

        guard case .split(let split) = controller.treeSnapshot() else {
            throw TestError.notASplit
        }
        let splitId = try #require(UUID(uuidString: split.id))

        let hostingView = NSHostingView(
            rootView: BonsplitView(controller: controller) { _, _ in Color.clear }
                emptyPane: { _ in Color.clear }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        let contentView = try #require(window.contentView)
        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)
        window.makeKeyAndOrderFront(nil)
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        contentView.layoutSubtreeIfNeeded()

        let splitView = try #require(firstDescendant(ofType: NSSplitView.self, in: hostingView))
        #expect(splitView.arrangedSubviews.count == 2)
        let available = max(splitView.frame.width - splitView.dividerThickness, 1)
        return (controller, window, splitView, splitId, available)
    }

    private enum TestError: Error { case notASplit }

    /// The stale-bank fixture both wedge tests share: a two-pane mirror
    /// whose container was banked while the hosting window was 800pt wide,
    /// with the plan already computed at that stale width — far wider than
    /// the 400-500pt windows the tests then host it in. Returns the
    /// connection too: the mirror only holds it weakly.
    private func makeWideBankedMirror(
        hostingSource: @escaping () -> CGSize?
    ) throws -> (mirror: RemoteTmuxWindowMirror, connection: RemoteTmuxControlConnection) {
        let layout = node(.horizontal([
            node(.pane(1), w: 61, h: 35, x: 0, y: 0),
            node(.pane(2), w: 61, h: 35, x: 62, y: 0),
        ]), w: 123, h: 35, x: 0, y: 0)
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"), sessionName: "work"
        )
        let mirror = RemoteTmuxWindowMirror(
            windowId: 0,
            panelId: UUID(),
            connection: connection,
            layout: layout,
            geometrySource: {
                RemoteTmuxMirrorGeometry(
                    cellWidthPx: 16, cellHeightPx: 34,
                    surfacePadWidthPx: 8, surfacePadHeightPx: 0,
                    scale: 2
                )
            },
            hostingContentSizeSource: hostingSource,
            makePanel: { _ in nil }
        )
        mirror.isVisibleForSizing = true
        // The stale bank: taken while the hosting window was 800pt wide,
        // never re-read before the window shrank.
        mirror.containerSizePt = CGSize(width: 800, height: 620)
        mirror.containerScale = 2
        mirror.reconcile(layout: layout)
        mirror.performSizingPassNow()
        let planned = try #require(mirror.renderFrameSize)
        #expect(
            planned.width >= 700,
            "the stale plan must be far wider than the hosting window for this test to bite"
        )
        return (mirror, connection)
    }

    /// Impose the extent, then pump the runloop until the first pane's real
    /// frame converges (the imposed apply defers a runloop turn and has a
    /// bounded AppKit retry). Returns the settled first/second widths.
    private func settleImposed(
        _ extent: CGFloat,
        controller: BonsplitController,
        splitId: UUID,
        splitView: NSSplitView,
        contentView: NSView
    ) -> (first: CGFloat, second: CGFloat) {
        _ = controller.setImposedFirstExtent(extent, forSplit: splitId)
        for _ in 0..<12 {
            splitView.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            contentView.layoutSubtreeIfNeeded()
            if abs(splitView.arrangedSubviews[0].frame.width - extent) <= 1 { break }
        }
        return (
            splitView.arrangedSubviews[0].frame.width,
            splitView.arrangedSubviews[1].frame.width
        )
    }

    /// The live fuzz found panes rendering at a fraction of their planned
    /// extents, and the ancestor tripwire traced it to SwiftUI content laid
    /// out thousands of points wider than its correctly-pinned hosting view
    /// in the workspace pane chain — growing as the fuzz opened more tabs.
    /// This pins the suspected mechanism at the desk: a pane with MANY tabs
    /// must keep its whole hosted view tree within the window's width. If
    /// any subview (the tab strip is the suspect) overflows the proposal,
    /// every space-filling sibling below inherits the inflated width.
    @Test func manyTabsDoNotInflateThePaneBeyondItsWindow() throws {
        let controller = BonsplitController(configuration: BonsplitConfiguration().remoteTmuxEmbedded)
        let rootPane = try #require(controller.allPaneIds.first)
        for i in 0..<30 {
            _ = controller.createTab(
                title: "tab-with-a-longish-title-\(i)", icon: "terminal",
                kind: "terminal", inPane: rootPane
            )
        }
        let hostingView = NSHostingView(
            rootView: BonsplitView(controller: controller) { _, _ in Color.clear }
                emptyPane: { _ in Color.clear }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        let contentView = try #require(window.contentView)
        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<10 {
            contentView.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        defer { window.orderOut(nil) }

        // Scroll documents are legitimately wider than the window — the tab
        // row lives in a horizontal ScrollView and its content is clipped by
        // the viewport. The leak the fuzz caught is width OUTSIDE any clip:
        // the hosting view's root graphics view inflating, which no viewport
        // contains and which every space-filling sibling then fills.
        var widest: (CGFloat, String) = (0, "none")
        func walk(_ view: NSView) {
            if view is NSClipView { return }
            if view.frame.width > widest.0 {
                widest = (view.frame.width, NSStringFromClass(type(of: view)))
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(hostingView)
        #expect(
            widest.0 <= 401,
            "an unclipped hosted view inflated past the 400pt window: \(widest.1) at \(widest.0)pt — space-filling siblings inherit this width"
        )
    }

    /// The live growth spiral, reproduced through the FULL wrapper chain the
    /// app runs — main-window hosting view, workspace bonsplit pane (tab bar,
    /// drop container, single-pane wrapper), and the real mirror view with
    /// its geometry feedback. The wedge needed exactly this loop: the mirror
    /// banks a container wider than the live window (a stale bank from before
    /// a shrink), the imposed render frame holds the tree at that stale
    /// width, the mirror view reports the tree's width instead of the
    /// region's proposal, the pane chain inherits it, and the mirror's own
    /// geometry callback reads the inflated width back — which the oversized
    /// guard can only drop, never cure, so the bank never heals and the
    /// window's content marches or sticks wide forever. With the region
    /// answering proposals with the proposal, the callback reads the TRUE
    /// region, the bank heals to it on the next pass, and every frame in the
    /// chain returns to the window's width.
    @Test func staleWideBankHealsThroughTheFullPaneChain() async throws {
        // Seed an injected bound for the pre-mount pass (the transaction only
        // completes against a visible hosting context), then hand the mirror
        // to the real window: a source answering nil falls through to the
        // live probe, so the mounted window's bound takes over.
        final class SeedBound { var value: CGSize? = CGSize(width: 800, height: 620) }
        let seed = SeedBound()
        let (mirror, connection) = try makeWideBankedMirror(hostingSource: { seed.value })
        seed.value = nil

        let appearance = PanelAppearance(
            backgroundColor: .black, foregroundColor: .white,
            dividerColor: .gray, unfocusedOverlayNSColor: .black,
            unfocusedOverlayOpacity: 0, usesClearContentBackground: false
        )
        // The real outer chain: a workspace-style bonsplit pane (tab bar and
        // all) whose tab content is the mirror view, beside a fixed sidebar,
        // hosted by the main window's hosting view class.
        let workspaceBonsplit = BonsplitController(configuration: BonsplitConfiguration())
        let rootPane = try #require(workspaceBonsplit.allPaneIds.first)
        _ = workspaceBonsplit.createTab(
            title: "mirror", icon: "terminal", kind: "terminal", inPane: rootPane
        )
        let root = HStack(spacing: 0) {
            Color.clear.frame(width: 240)
            BonsplitView(controller: workspaceBonsplit) { _, _ in
                RemoteTmuxWindowMirrorSplitView(
                    mirror: mirror,
                    appearance: appearance,
                    isOuterFocused: false,
                    isVisibleInUI: true,
                    portalPriority: 0,
                    onOuterFocus: {}
                )
            } emptyPane: { _ in
                Color.clear
            }
        }
        let hostingView = MainWindowHostingView(rootView: AnyView(root))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.contentView = hostingView
        window.setFrame(NSRect(x: 0, y: 0, width: 500, height: 400), display: true)
        window.makeKeyAndOrderFront(nil)
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }

        // Enough passes for the loop to either heal (the geometry callback
        // reads the true region, the sizing pass re-banks it after the 60ms
        // quiesce) or demonstrate the march/stick. The waits are async
        // suspensions, not RunLoop.run: sizing passes ride
        // DispatchQueue.main, and a synchronous main-actor test body holds
        // the main queue's current work item, so a nested runloop would
        // pump layout while silently starving every scheduled pass — the
        // live app's idle runloop drains them normally.
        for _ in 0..<15 {
            window.displayIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(
            mirror.hostProbeView != nil,
            "the mirror view was never laid out — the probe never mounted, so the test exercised nothing"
        )
        #expect(
            window.frame.width <= 501,
            "the WINDOW grew toward the stale imposed width: \(window.frame.width)pt"
        )
        #expect(
            hostingView.frame.width <= window.frame.width + 1,
            "the content view marched off the window: \(hostingView.frame.width)pt in a \(window.frame.width)pt window"
        )
        let banked = try #require(mirror.containerSizePt)
        #expect(
            banked.width <= window.frame.width + 1,
            "the stale bank never healed: container still \(banked.width)pt inside a \(window.frame.width)pt window — the mirror is reading its own imposed width back"
        )
        withExtendedLifetime(connection) {}
    }

    /// The imposed render frame must never become the mirror view's reported
    /// size. The plan is derived from the BANKED container, the proposal from
    /// the live window, and under churn the two disagree: a window shrink
    /// leaves the plan wider than the region until the next sized pass, and
    /// the oversized-reading guard keeps the stale bank (deferring is
    /// correct — the reading is not the slot). The view must answer the
    /// region's proposal with the proposal and let the tree overflow in
    /// place. When the imposed width leaked into the reported size instead,
    /// every space-filling ancestor up to the main window's root content
    /// inherited it (observed live: the content view marching wider than the
    /// display-pinned window a step per layout pass, 2559pt and climbing),
    /// and the mirror then read its own imposed width back as its container.
    @Test func staleImposedRenderFrameDoesNotInflateTheMirrorViewsReportedSize() throws {
        let (mirror, connection) = try makeWideBankedMirror(
            hostingSource: { CGSize(width: 800, height: 620) }
        )

        final class MeasuredWidth { var value: CGFloat = 0 }
        let measured = MeasuredWidth()
        let appearance = PanelAppearance(
            backgroundColor: .black, foregroundColor: .white,
            dividerColor: .gray, unfocusedOverlayNSColor: .black,
            unfocusedOverlayOpacity: 0, usesClearContentBackground: false
        )
        let hostingView = NSHostingView(
            rootView: RemoteTmuxWindowMirrorSplitView(
                mirror: mirror,
                appearance: appearance,
                isOuterFocused: false,
                isVisibleInUI: true,
                portalPriority: 0,
                onOuterFocus: {}
            )
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                measured.value = width
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        let contentView = try #require(window.contentView)
        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<10 {
            contentView.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        defer { window.orderOut(nil) }

        #expect(
            measured.value > 0,
            "the geometry probe never fired — the view was not laid out"
        )
        #expect(
            measured.value <= 401,
            "the mirror view reported \(measured.value)pt to its ancestors inside a 400pt window — the imposed render frame leaked into the reported size"
        )
        withExtendedLifetime(connection) {}
    }

    /// Render ownership against the real renderer: a container change under a
    /// held imposition must NOT be fought. Bonsplit used to re-assert the old
    /// extent from its resize callback (inside the very layout pass that moved
    /// the frames — the recursive storm) and from update passes whenever the
    /// divider had "moved". Under one-writer, the stale extent stays wherever
    /// AppKit's proportional resize put it until a FRESH imposition — the
    /// authority re-planning from fresh inputs — retargets it exactly.
    @Test func containerChangeUnderImpositionIsNotFoughtUntilReimposed() throws {
        let host = try makeHostedHorizontalSplit()
        defer { host.window.orderOut(nil) }
        let contentView = try #require(host.window.contentView)

        let imposed = CGFloat(120)
        let settled = settleImposed(
            imposed, controller: host.controller, splitId: host.splitId,
            splitView: host.splitView, contentView: contentView
        )
        #expect(abs(settled.first - imposed) <= 1.5)

        // Shrink the hosting window: AppKit rescales the split proportionally.
        host.window.setContentSize(NSSize(width: 300, height: 300))
        for _ in 0..<12 {
            contentView.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let afterShrink = host.splitView.arrangedSubviews[0].frame.width
        #expect(
            afterShrink < imposed - 4,
            "stale imposition re-asserted after container change: first pane held \(afterShrink)pt (imposed \(imposed))"
        )

        // The authority retargets: a fresh imposition applies exactly.
        let reimposed = settleImposed(
            90, controller: host.controller, splitId: host.splitId,
            splitView: host.splitView, contentView: contentView
        )
        #expect(abs(reimposed.first - 90) <= 1.5)
    }

    @Test func imposedExtentDrivesRealFrameAndIsSpaceFilling() throws {
        let host = try makeHostedHorizontalSplit()
        defer { host.window.orderOut(nil) }
        let contentView = try #require(host.window.contentView)

        // A tiny extent (a ~1-cell pane), the middle, and a large extent. The
        // tiny case is the important one: min-pane=1pt must not clamp it up.
        for imposed in [CGFloat(8), 120, host.available / 2, host.available - 12] {
            let widths = settleImposed(
                imposed, controller: host.controller, splitId: host.splitId,
                splitView: host.splitView, contentView: contentView
            )
            #expect(
                abs(widths.first - imposed) <= 1.5,
                "imposed \(imposed)pt but first pane rendered \(widths.first)pt (min-pane clamp or ignored imposition?)"
            )
            #expect(
                abs((widths.first + widths.second) - host.available) <= 2.0,
                "panes do not tile: \(widths.first)+\(widths.second) != available \(host.available)"
            )
        }
    }

    /// The same plan-versus-view judgment the settle payload makes: every
    /// pane's hosted view must sit within tolerance of the outer size the
    /// last imposition granted it (planned height carries the per-pane tab
    /// bar; the hosted view is the content below it).
    private func planViewMismatch(_ mirror: RemoteTmuxWindowMirror) -> String? {
        guard let metrics = mirror.nativeLayoutMetrics() else { return "no metrics" }
        guard !mirror.lastPlannedOuterSizes.isEmpty else { return "no plan yet" }
        for (paneId, planned) in mirror.lastPlannedOuterSizes.sorted(by: { $0.key < $1.key }) {
            guard let view = mirror.panelsByPaneId[paneId]?.hostedView, view.window != nil else {
                return "%\(paneId) not hosted"
            }
            let content = CGSize(
                width: planned.width,
                height: max(0, planned.height - metrics.tabBarHeight)
            )
            if abs(content.width - view.frame.width) > 1.5
                || abs(content.height - view.frame.height) > 1.5 {
                return "%\(paneId) plan=\(Int(content.width))x\(Int(content.height)) view=\(Int(view.frame.width))x\(Int(view.frame.height))"
            }
        }
        return nil
    }

    /// The liveness half of render ownership. The sizing transaction's
    /// convergence proof is input-only: once a completed pass's inputs match
    /// the current inputs, every later trigger early-returns. An apply that
    /// terminates OFF-target with no input change — bonsplit parking a
    /// divider at a minimum, a retry budget expiring against mid-commit
    /// bounds — therefore never gets corrected: the live fuzz held a 1199pt
    /// plan against a 984pt view for 50+ seconds while every trigger said
    /// "settled". The rule this pins: an apply may never terminate
    /// off-target without a re-arm edge — the transaction must verify
    /// outcome parity and re-impose (bounded) when the views miss the plan.
    @Test func offPlanGeometryWithUnchangedSizingInputsReconverges() async throws {
        let layout = node(.horizontal([
            node(.pane(1), w: 61, h: 35, x: 0, y: 0),
            node(.pane(2), w: 61, h: 35, x: 62, y: 0),
        ]), w: 123, h: 35, x: 0, y: 0)
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "parity-\(UUID().uuidString)@host"),
            sessionName: "work"
        )
        let workspaceId = UUID()
        // Real panels: the parity judgment reads the panes' hosted terminal
        // views, so the fixture needs them mounted through the app's real
        // render chain. The spawn stays paced (no shells launch in a unit
        // test); only the view tree matters here.
        let mirror = RemoteTmuxWindowMirror(
            windowId: 0,
            panelId: UUID(),
            connection: connection,
            layout: layout,
            geometrySource: {
                RemoteTmuxMirrorGeometry(
                    cellWidthPx: 16, cellHeightPx: 34,
                    surfacePadWidthPx: 8, surfacePadHeightPx: 0,
                    scale: 2
                )
            },
            makePanel: { _ in
                TerminalPanel(workspaceId: workspaceId, runtimeSpawnPolicy: .pacedSessionRestore)
            }
        )
        // Freeze the live-sample channel. The injected geometrySource already
        // fixes the render constants; a real surface sample landing mid-test
        // would change the geometry SNAPSHOT — a sizing input — and the pass
        // would then re-impose on an input change, masking exactly the
        // no-input-change hole this test pins.
        for panel in mirror.panelsByPaneId.values {
            panel.surface.onManualSizeApplied = nil
            panel.surface.onRuntimeReady = nil
        }
        let appearance = PanelAppearance(
            backgroundColor: .black, foregroundColor: .white,
            dividerColor: .gray, unfocusedOverlayNSColor: .black,
            unfocusedOverlayOpacity: 0, usesClearContentBackground: false
        )
        let hostingView = NSHostingView(
            rootView: RemoteTmuxWindowMirrorSplitView(
                mirror: mirror,
                appearance: appearance,
                isOuterFocused: false,
                isVisibleInUI: true,
                portalPriority: 0,
                onOuterFocus: {}
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        let contentView = try #require(window.contentView)
        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)
        window.makeKeyAndOrderFront(nil)
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }

        // Pump with async suspensions, not RunLoop.run: sizing passes ride
        // DispatchQueue.main and a nested runloop would starve them (see
        // staleWideBankHealsThroughTheFullPaneChain).
        func pump(_ turns: Int, until done: () -> Bool = { false }) async throws {
            for _ in 0..<turns {
                window.displayIfNeeded()
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
                if done() { return }
            }
        }

        // Baseline: the fixture must reach plan == view on its own, or it
        // cannot judge anything. The extra drain pass afterwards consumes any
        // input drift still in flight (a surface sample swept mid-pass lands
        // AFTER that pass's input snapshot), so the fixed point captured
        // below really is one.
        try await pump(60, until: { planViewMismatch(mirror) == nil })
        try #require(
            planViewMismatch(mirror) == nil,
            "fixture never converged to its own plan: \(planViewMismatch(mirror) ?? "")"
        )
        mirror.setNeedsSizingPass()
        try await pump(6)
        try #require(planViewMismatch(mirror) == nil)
        let inputsAtSettle = try #require(mirror.lastCompletedSizingInputs)
        let splitId: UUID = try {
            guard case .split(let split) = mirror.bonsplitController.treeSnapshot(),
                  let id = UUID(uuidString: split.id) else { throw TestError.notASplit }
            return id
        }()

        // The perturbation: geometry moves, no sizing input changes — the
        // desk stand-in for bonsplit parking a divider off the imposed
        // extent. Clearing the imposition first is part of the simulation
        // (a parked apply leaves no live imposition holding the plan).
        _ = mirror.bonsplitController.setImposedFirstExtent(nil, forSplit: splitId, fromExternal: true)
        _ = mirror.bonsplitController.setDividerPosition(0.8, forSplit: splitId, fromExternal: true)
        try await pump(12, until: { planViewMismatch(mirror) != nil })
        try #require(
            planViewMismatch(mirror) != nil,
            "the perturbation moved nothing — the test exercised nothing"
        )
        // Fixture validity: the perturbation must not have completed a pass
        // (a changed input would re-impose legitimately and mask the hole).
        try #require(
            mirror.lastCompletedSizingInputs == inputsAtSettle,
            "sizing inputs drifted during the perturbation — this run judged an input change, not the liveness hole"
        )

        // A redundant trigger, exactly what the live app keeps delivering at
        // rest (surface samples, geometry echoes). Inputs are unchanged, so
        // today the pass early-returns and the views stay off-plan forever.
        mirror.setNeedsSizingPass()
        try await pump(60, until: { planViewMismatch(mirror) == nil })
        #expect(
            planViewMismatch(mirror) == nil,
            "off-plan geometry never re-converged with unchanged inputs: \(planViewMismatch(mirror) ?? "") — the apply terminated off-target and no re-arm edge exists"
        )
        withExtendedLifetime(connection) {}
    }

    /// A divider drag that sends a resize-pane enters a round-trip window
    /// where the plan is KNOWN stale: the user moved the divider, the tree
    /// holds the dragged fraction, and lastPlannedOuterSizes still holds the
    /// pre-drag extents until tmux's layout reply produces the next plan.
    /// The output-parity re-arm cannot tell that state from a genuine apply
    /// miss, so it re-imposed the stale plan — the divider visibly bounced
    /// back, then jumped to the reply's plan. During that window, redundant
    /// triggers must not re-impose the pre-drag extents; the reply then
    /// applies the settled plan.
    @Test func dividerDragThatSentAResizeDoesNotBounceBackBeforeTheReply() async throws {
        let layout = node(.horizontal([
            node(.pane(1), w: 61, h: 35, x: 0, y: 0),
            node(.pane(2), w: 61, h: 35, x: 62, y: 0),
        ]), w: 123, h: 35, x: 0, y: 0)
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "bounce-\(UUID().uuidString)@host"),
            sessionName: "work"
        )
        let pipe = Pipe()
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-bounce-test",
            maxPendingBytes: 1 << 16,
            onFailure: {}
        )
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        connection.installStdinWriterForTesting(writer)
        connection.handleMessageForTesting(.enter)
        let workspaceId = UUID()
        let mirror = RemoteTmuxWindowMirror(
            windowId: 0,
            panelId: UUID(),
            connection: connection,
            layout: layout,
            geometrySource: {
                RemoteTmuxMirrorGeometry(
                    cellWidthPx: 16, cellHeightPx: 34,
                    surfacePadWidthPx: 8, surfacePadHeightPx: 0,
                    scale: 2
                )
            },
            makePanel: { _ in
                TerminalPanel(workspaceId: workspaceId, runtimeSpawnPolicy: .pacedSessionRestore)
            }
        )
        for panel in mirror.panelsByPaneId.values {
            panel.surface.onManualSizeApplied = nil
            panel.surface.onRuntimeReady = nil
        }
        let appearance = PanelAppearance(
            backgroundColor: .black, foregroundColor: .white,
            dividerColor: .gray, unfocusedOverlayNSColor: .black,
            unfocusedOverlayOpacity: 0, usesClearContentBackground: false
        )
        let hostingView = NSHostingView(
            rootView: RemoteTmuxWindowMirrorSplitView(
                mirror: mirror,
                appearance: appearance,
                isOuterFocused: false,
                isVisibleInUI: true,
                portalPriority: 0,
                onOuterFocus: {}
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        let contentView = try #require(window.contentView)
        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)
        window.makeKeyAndOrderFront(nil)
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        func pump(_ turns: Int, until done: () -> Bool = { false }) async throws {
            for _ in 0..<turns {
                window.displayIfNeeded()
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
                if done() { return }
            }
        }

        // Converge to the plan's fixed point first — the bounce is only
        // observable from a settled state.
        try await pump(60, until: { planViewMismatch(mirror) == nil })
        try #require(
            planViewMismatch(mirror) == nil,
            "fixture never converged: \(planViewMismatch(mirror) ?? "")"
        )
        let split: ExternalSplitNode = try {
            guard case .split(let split) = mirror.bonsplitController.treeSnapshot() else {
                throw TestError.notASplit
            }
            return split
        }()
        let splitId = try #require(UUID(uuidString: split.id))
        let preDragFraction = split.dividerPosition
        let pendingBefore = connection.pendingCommandKindsForTesting.count

        // The user's drag through the hooks bonsplit drives live: session
        // begin, a committed multi-cell fraction, session end. Drag end
        // syncs the changed divider and sends the resize-pane. The no-reply
        // deadline is pushed past this test's pumping — the deliberate
        // round-trip window below must stay open until the reply.
        mirror.dividerResizeReplyGrace = 30
        mirror.bonsplitController.noteDividerDragSession(true)
        _ = mirror.bonsplitController.setDividerPosition(0.75, forSplit: splitId)
        mirror.bonsplitController.noteDividerDragSession(false)
        try #require(
            connection.pendingCommandKindsForTesting.count == pendingBefore + 1,
            "precondition: the drag must send exactly one resize-pane"
        )

        // The round-trip window: no reply yet. Pump passes and redundant
        // triggers — the parity re-arm must not re-impose the pre-drag plan.
        for _ in 0..<3 {
            mirror.setNeedsSizingPass()
            try await pump(4)
        }
        let fractionDuringRoundTrip: Double = try {
            guard case .split(let split) = mirror.bonsplitController.treeSnapshot() else {
                throw TestError.notASplit
            }
            return split.dividerPosition
        }()
        #expect(
            abs(fractionDuringRoundTrip - preDragFraction) > 0.1,
            "the divider bounced back to the pre-drag plan (\(preDragFraction)) during the tmux round trip — the parity re-arm re-imposed a known-stale plan"
        )

        // The reply lands: tmux assigned the dragged span. The settled plan
        // applies and the fixture converges on it.
        let draggedLayout = node(.horizontal([
            node(.pane(1), w: 92, h: 35, x: 0, y: 0),
            node(.pane(2), w: 30, h: 35, x: 93, y: 0),
        ]), w: 123, h: 35, x: 0, y: 0)
        mirror.reconcile(layout: draggedLayout)
        try await pump(60, until: { planViewMismatch(mirror) == nil })
        #expect(
            planViewMismatch(mirror) == nil,
            "the reply's plan must settle cleanly: \(planViewMismatch(mirror) ?? "")"
        )
        withExtendedLifetime(connection) {}
    }

    /// A sent divider resize that tmux never answers — the client clamp can
    /// produce a span tmux's own cascade minimums treat as a no-op, so no
    /// %layout-change comes back. The round-trip hold must be BOUNDED: at
    /// its deadline the re-arm returns and parity heals the divider back
    /// onto the plan. An unbounded hold left the divider parked off-grid
    /// with the parity guard disabled forever.
    @Test func swallowedDividerResizeHealsAtTheHoldDeadline() async throws {
        let layout = node(.horizontal([
            node(.pane(1), w: 61, h: 35, x: 0, y: 0),
            node(.pane(2), w: 61, h: 35, x: 62, y: 0),
        ]), w: 123, h: 35, x: 0, y: 0)
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "heal-\(UUID().uuidString)@host"),
            sessionName: "work"
        )
        let pipe = Pipe()
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-heal-test",
            maxPendingBytes: 1 << 16,
            onFailure: {}
        )
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        connection.installStdinWriterForTesting(writer)
        connection.handleMessageForTesting(.enter)
        let workspaceId = UUID()
        let mirror = RemoteTmuxWindowMirror(
            windowId: 0,
            panelId: UUID(),
            connection: connection,
            layout: layout,
            geometrySource: {
                RemoteTmuxMirrorGeometry(
                    cellWidthPx: 16, cellHeightPx: 34,
                    surfacePadWidthPx: 8, surfacePadHeightPx: 0,
                    scale: 2
                )
            },
            makePanel: { _ in
                TerminalPanel(workspaceId: workspaceId, runtimeSpawnPolicy: .pacedSessionRestore)
            }
        )
        for panel in mirror.panelsByPaneId.values {
            panel.surface.onManualSizeApplied = nil
            panel.surface.onRuntimeReady = nil
        }
        let appearance = PanelAppearance(
            backgroundColor: .black, foregroundColor: .white,
            dividerColor: .gray, unfocusedOverlayNSColor: .black,
            unfocusedOverlayOpacity: 0, usesClearContentBackground: false
        )
        let hostingView = NSHostingView(
            rootView: RemoteTmuxWindowMirrorSplitView(
                mirror: mirror,
                appearance: appearance,
                isOuterFocused: false,
                isVisibleInUI: true,
                portalPriority: 0,
                onOuterFocus: {}
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        let contentView = try #require(window.contentView)
        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)
        window.makeKeyAndOrderFront(nil)
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        func pump(_ turns: Int, until done: () -> Bool = { false }) async throws {
            for _ in 0..<turns {
                window.displayIfNeeded()
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
                if done() { return }
            }
        }

        try await pump(60, until: { planViewMismatch(mirror) == nil })
        try #require(
            planViewMismatch(mirror) == nil,
            "fixture never converged: \(planViewMismatch(mirror) ?? "")"
        )
        let splitId: UUID = try {
            guard case .split(let split) = mirror.bonsplitController.treeSnapshot() else {
                throw TestError.notASplit
            }
            return UUID(uuidString: split.id) ?? UUID()
        }()
        let pendingBefore = connection.pendingCommandKindsForTesting.count

        // A short deadline, then the swallowed send: the resize-pane goes
        // out and NOTHING ever answers it.
        mirror.dividerResizeReplyGrace = 0.5
        mirror.bonsplitController.noteDividerDragSession(true)
        _ = mirror.bonsplitController.setDividerPosition(0.75, forSplit: splitId)
        mirror.bonsplitController.noteDividerDragSession(false)
        try #require(
            connection.pendingCommandKindsForTesting.count == pendingBefore + 1,
            "precondition: the drag must send exactly one resize-pane"
        )

        // Past the deadline, the hold must have released and re-armed the
        // pass: parity heals the parked divider back onto the plan.
        try await pump(60, until: {
            mirror.dividerResizeInFlight == nil && planViewMismatch(mirror) == nil
        })
        #expect(
            mirror.dividerResizeInFlight == nil,
            "the no-reply hold must release at its deadline"
        )
        #expect(
            planViewMismatch(mirror) == nil,
            "the deadline must RE-ARM, not just clear: parity heals the parked divider back onto the plan — \(planViewMismatch(mirror) ?? "")"
        )
        withExtendedLifetime(connection) {}
    }

    /// An UNRELATED %layout-change landing during a divider send's round
    /// trip replans from a tree that is still pre-drag for the dragged
    /// split. The keyed hold must survive that replan and shield the
    /// dragged split's divider — clearing on any imposition brought the
    /// bounce back under churn.
    @Test func unrelatedLayoutChangeDuringRoundTripDoesNotBounceTheDraggedDivider() async throws {
        let layout = node(.horizontal([
            node(.pane(1), w: 61, h: 35, x: 0, y: 0),
            node(.vertical([
                node(.pane(2), w: 61, h: 17, x: 62, y: 0),
                node(.pane(3), w: 61, h: 17, x: 62, y: 18),
            ]), w: 61, h: 35, x: 62, y: 0),
        ]), w: 123, h: 35, x: 0, y: 0)
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "unrelated-\(UUID().uuidString)@host"),
            sessionName: "work"
        )
        let pipe = Pipe()
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-unrelated-test",
            maxPendingBytes: 1 << 16,
            onFailure: {}
        )
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        connection.installStdinWriterForTesting(writer)
        connection.handleMessageForTesting(.enter)
        let workspaceId = UUID()
        let mirror = RemoteTmuxWindowMirror(
            windowId: 0,
            panelId: UUID(),
            connection: connection,
            layout: layout,
            geometrySource: {
                RemoteTmuxMirrorGeometry(
                    cellWidthPx: 16, cellHeightPx: 34,
                    surfacePadWidthPx: 8, surfacePadHeightPx: 0,
                    scale: 2
                )
            },
            makePanel: { _ in
                TerminalPanel(workspaceId: workspaceId, runtimeSpawnPolicy: .pacedSessionRestore)
            }
        )
        for panel in mirror.panelsByPaneId.values {
            panel.surface.onManualSizeApplied = nil
            panel.surface.onRuntimeReady = nil
        }
        let appearance = PanelAppearance(
            backgroundColor: .black, foregroundColor: .white,
            dividerColor: .gray, unfocusedOverlayNSColor: .black,
            unfocusedOverlayOpacity: 0, usesClearContentBackground: false
        )
        let hostingView = NSHostingView(
            rootView: RemoteTmuxWindowMirrorSplitView(
                mirror: mirror,
                appearance: appearance,
                isOuterFocused: false,
                isVisibleInUI: true,
                portalPriority: 0,
                onOuterFocus: {}
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        let contentView = try #require(window.contentView)
        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)
        window.makeKeyAndOrderFront(nil)
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        func pump(_ turns: Int, until done: () -> Bool = { false }) async throws {
            for _ in 0..<turns {
                window.displayIfNeeded()
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
                if done() { return }
            }
        }

        try await pump(60, until: { planViewMismatch(mirror) == nil })
        try #require(
            planViewMismatch(mirror) == nil,
            "fixture never converged: \(planViewMismatch(mirror) ?? "")"
        )
        let rootId: UUID = try {
            guard case .split(let split) = mirror.bonsplitController.treeSnapshot() else {
                throw TestError.notASplit
            }
            return UUID(uuidString: split.id) ?? UUID()
        }()
        let preDragFraction: Double = try {
            guard case .split(let split) = mirror.bonsplitController.treeSnapshot() else {
                throw TestError.notASplit
            }
            return split.dividerPosition
        }()
        let pendingBefore = connection.pendingCommandKindsForTesting.count

        mirror.dividerResizeReplyGrace = 30
        mirror.bonsplitController.noteDividerDragSession(true)
        _ = mirror.bonsplitController.setDividerPosition(0.75, forSplit: rootId)
        mirror.bonsplitController.noteDividerDragSession(false)
        try #require(
            connection.pendingCommandKindsForTesting.count == pendingBefore + 1,
            "precondition: the root drag must send exactly one resize-pane"
        )

        // The unrelated change: the inner vertical split moved, the root's
        // spans did not. This replans from a tree that is still pre-drag
        // for the root split.
        let unrelated = node(.horizontal([
            node(.pane(1), w: 61, h: 35, x: 0, y: 0),
            node(.vertical([
                node(.pane(2), w: 61, h: 20, x: 62, y: 0),
                node(.pane(3), w: 61, h: 14, x: 62, y: 21),
            ]), w: 61, h: 35, x: 62, y: 0),
        ]), w: 123, h: 35, x: 0, y: 0)
        mirror.reconcile(layout: unrelated)
        try await pump(12)

        let rootFraction: Double = try {
            guard case .split(let split) = mirror.bonsplitController.treeSnapshot() else {
                throw TestError.notASplit
            }
            return split.dividerPosition
        }()
        #expect(
            abs(rootFraction - preDragFraction) > 0.1,
            "the unrelated replan re-imposed the dragged split's pre-drag extent (root fraction back at \(rootFraction), pre-drag \(preDragFraction)) — the bounce under churn"
        )
        #expect(
            mirror.dividerResizeInFlight != nil,
            "the keyed hold must survive an unrelated replan — only a layout that assigns the sent span (or the deadline) may end it"
        )
        withExtendedLifetime(connection) {}
    }

    /// A tab re-show races two host probes: SwiftUI mounts the NEW probe
    /// (which registers the mirror's window handle) before AppKit finishes
    /// tearing the OLD one out of its window, so the dying probe's final
    /// viewDidMoveToWindow fires with window == nil AFTER the replacement
    /// registered. It used to claim unconditionally, shadowing the live
    /// handle with a windowless view until the next SwiftUI update — and the
    /// sizing pass, probing for a window, went blind exactly when the
    /// re-shown tab needed it. A windowless probe must never claim, and only
    /// the registered probe may clear the slot.
    @Test func dyingProbeCannotShadowTheReplacementsWindowHandle() throws {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "probe-\(UUID().uuidString)@host"),
            sessionName: "work"
        )
        let mirror = RemoteTmuxWindowMirror(
            windowId: 0,
            panelId: UUID(),
            connection: connection,
            layout: RemoteTmuxLayoutNode(width: 80, height: 24, x: 0, y: 0, content: .pane(1)),
            makePanel: { _ in nil }
        )
        let old = MirrorHostProbeView()
        old.mirror = mirror
        mirror.hostProbeView = old
        let replacement = MirrorHostProbeView()
        replacement.mirror = mirror
        mirror.hostProbeView = replacement

        // The dying probe reports "left the window" after the replacement
        // already holds the slot: it must not steal it back.
        old.viewDidMoveToWindow()
        #expect(
            mirror.hostProbeView === replacement,
            "a windowless probe must not shadow the registered one"
        )

        // The registered probe losing its window clears the slot outright.
        replacement.viewDidMoveToWindow()
        #expect(mirror.hostProbeView == nil)

        // Gaining a window claims it (AppKit fires the hook on add).
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        defer { window.orderOut(nil) }
        try #require(window.contentView).addSubview(old)
        #expect(mirror.hostProbeView === old)
    }

    /// A deselected mirror tab's split tree must be hidden at the APPKIT
    /// level, not just faded out. The workspace bonsplit keeps every tab's
    /// content alive (`contentViewLifecycle: .keepAllAlive`) and hides
    /// deselected tabs with SwiftUI opacity 0, which never sets `isHidden`
    /// on the AppKit split trees the embedded mirrors render — a live lldb
    /// census found 21 split-view instances stacked in one window whose
    /// visible layout has two dividers. The unhidden foreign trees painted
    /// their dividers over the visible panes (the phantom interior divider),
    /// registered resize-cursor rects under the pointer, and their alpha-0
    /// drop zones sat above the selected tab and rejected pane drops (the
    /// embedded config forbids cross-pane tab moves). Bonsplit's
    /// `isInteractive` switch hides the split tree at the AppKit level; the
    /// mirror view must drive it at the same visibility edges that drive
    /// `isVisibleForSizing`. The divider-region census below is the same
    /// collection the portal uses to paint dividers, so an inflated count
    /// here IS the phantom divider.
    @Test func deselectedMirrorTabsHideTheirSplitTreesFromAppKit() async throws {
        func makeSplitMirror() -> (mirror: RemoteTmuxWindowMirror, connection: RemoteTmuxControlConnection) {
            let layout = node(.horizontal([
                node(.pane(1), w: 61, h: 35, x: 0, y: 0),
                node(.pane(2), w: 61, h: 35, x: 62, y: 0),
            ]), w: 123, h: 35, x: 0, y: 0)
            let connection = RemoteTmuxControlConnection(
                host: RemoteTmuxHost(destination: "user@host"), sessionName: "work"
            )
            let mirror = RemoteTmuxWindowMirror(
                windowId: 0,
                panelId: UUID(),
                connection: connection,
                layout: layout,
                makePanel: { _ in nil }
            )
            return (mirror, connection)
        }
        let (mirrorA, connectionA) = makeSplitMirror()
        let (mirrorB, connectionB) = makeSplitMirror()

        let appearance = PanelAppearance(
            backgroundColor: .black, foregroundColor: .white,
            dividerColor: .gray, unfocusedOverlayNSColor: .black,
            unfocusedOverlayOpacity: 0, usesClearContentBackground: false
        )
        // The workspace-style outer chain: one bonsplit pane holding both
        // mirror tabs, all content kept alive like the real workspace.
        var outerConfiguration = BonsplitConfiguration()
        outerConfiguration.contentViewLifecycle = .keepAllAlive
        let outer = BonsplitController(configuration: outerConfiguration)
        let rootPane = try #require(outer.allPaneIds.first)
        let tabA = try #require(outer.createTab(
            title: "A", icon: "terminal", kind: "terminal", inPane: rootPane
        ))
        let tabB = try #require(outer.createTab(
            title: "B", icon: "terminal", kind: "terminal", inPane: rootPane
        ))
        let root = BonsplitView(controller: outer) { tab, paneId in
            // A fresh controller carries a default welcome tab; only the two
            // mirror tabs render mirror views, so the census counts exactly
            // the trees the mirrors own.
            if tab.id == tabA || tab.id == tabB {
                RemoteTmuxWindowMirrorSplitView(
                    mirror: tab.id == tabA ? mirrorA : mirrorB,
                    appearance: appearance,
                    isOuterFocused: false,
                    isVisibleInUI: outer.selectedTab(inPane: paneId)?.id == tab.id,
                    portalPriority: 0,
                    onOuterFocus: {}
                )
            } else {
                Color.clear
            }
        } emptyPane: { _ in
            Color.clear
        }
        let hostingView = MainWindowHostingView(rootView: AnyView(root))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        let contentView = try #require(window.contentView)

        // Async suspensions, not RunLoop.run: a nested runloop would pump
        // layout while starving the main queue (see the stale-bank test).
        func settle() async throws {
            for _ in 0..<10 {
                window.displayIfNeeded()
                contentView.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        outer.selectTab(tabA)
        try await settle()

        let visibleWithASelected = effectivelyVisibleSplitViews(in: contentView)
        #expect(
            visibleWithASelected.count == 1,
            "with tab A selected, exactly its own split tree may be visible to AppKit — found \(visibleWithASelected.count) unhidden split views: \(visibleWithASelected.map { "\($0.frame) sub=\($0.arrangedSubviews.count) chain=\(Self.ancestorChain($0))" })"
        )
        let regionsWithASelected = PortalSplitDividerRegion.collect(in: contentView).regions
        #expect(
            regionsWithASelected.count == 1,
            "the divider census must see A's single divider, not the deselected tab's too — found \(regionsWithASelected.count)"
        )

        // The other direction exercises the visibility-change edge: B's tree
        // un-hides, A's hides.
        outer.selectTab(tabB)
        try await settle()

        let visibleWithBSelected = effectivelyVisibleSplitViews(in: contentView)
        #expect(
            visibleWithBSelected.count == 1,
            "with tab B selected, exactly its own split tree may be visible to AppKit — found \(visibleWithBSelected.count) unhidden split views"
        )
        #expect(
            PortalSplitDividerRegion.collect(in: contentView).regions.count == 1,
            "the divider census must see B's single divider after the switch"
        )
        if let before = visibleWithASelected.first, let after = visibleWithBSelected.first {
            #expect(
                before !== after,
                "selection moved from A to B, so the surviving visible tree must be the OTHER mirror's"
            )
        }
        withExtendedLifetime((connectionA, connectionB)) {}
    }
}

private func node(
    _ content: RemoteTmuxLayoutContent, w: Int, h: Int, x: Int, y: Int
) -> RemoteTmuxLayoutNode {
    RemoteTmuxLayoutNode(width: w, height: h, x: x, y: y, content: content)
}
