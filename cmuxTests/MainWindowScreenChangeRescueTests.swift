import AppKit
import CmuxWindowing
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Pure, screen-agnostic tests for the display-topology-change rescue core.
// Geometry mirrors a MacBook built-in display (menu bar occupying the top
// 38pt of the 982pt-tall frame) and a taller external display to its right.
@Suite("Main window screen-change rescue")
struct MainWindowScreenChangeRescueTests {
    private let core = MainWindowScreenRescueCore()

    private static let builtIn = SessionDisplayGeometry(
        displayID: 1,
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944)
    )
    private static let external = SessionDisplayGeometry(
        displayID: 2,
        frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415)
    )
    private static let minWidth: CGFloat = 300
    private static let minHeight: CGFloat = 200
    private static let strictThresholds = WindowTitlebarReachabilityThresholds(
        topStripHeight: WindowChromeMetrics.sharedChromeBarHeight,
        minimumVisibleWidth: 120,
        minimumVisibleHeight: 20
    )

    // MARK: - Topology signature

    @Test func signatureIsOrderIndependent() {
        let a = core.topologySignature(of: [Self.builtIn, Self.external])
        let b = core.topologySignature(of: [Self.external, Self.builtIn])
        #expect(a == b)
    }

    @Test func signatureChangesWhenDisplayDisconnects() {
        let both = core.topologySignature(of: [Self.builtIn, Self.external])
        let one = core.topologySignature(of: [Self.builtIn])
        #expect(both != one)
    }

    @Test func signatureChangesWhenVisibleFrameSideOrBottomInsetChanges() {
        // A Dock resize changes visibleFrame but not the display's frame or
        // top inset. It must run a lenient reachability pass because a
        // side/bottom Dock can newly cover an edge-parked titlebar, but it is
        // not a strict display-arrangement change.
        let dockResized = SessionDisplayGeometry(
            displayID: 1,
            frame: Self.builtIn.frame,
            visibleFrame: CGRect(x: 0, y: 90, width: 1512, height: 854)
        )
        let before = core.topologySignature(of: [Self.builtIn])
        let after = core.topologySignature(of: [dockResized])
        #expect(before != after)
        #expect(core.signaturesHaveSameArrangement(before, after))
    }

    @Test func signatureIgnoresDisplayIDRenumbering() {
        // Dock/KVM/Sidecar wake paths can re-enumerate the same physical
        // display arrangement with new NSScreenNumber values. Geometry and top
        // inset are what determine whether a window can be stranded.
        let renumberedBuiltIn = SessionDisplayGeometry(
            displayID: 101,
            frame: Self.builtIn.frame,
            visibleFrame: Self.builtIn.visibleFrame
        )
        let renumberedExternal = SessionDisplayGeometry(
            displayID: 202,
            frame: Self.external.frame,
            visibleFrame: Self.external.visibleFrame
        )
        let before = core.topologySignature(of: [Self.builtIn, Self.external])
        let after = core.topologySignature(of: [renumberedExternal, renumberedBuiltIn])
        #expect(before == after)
    }

    // MARK: - Rescue decisions

    @Test func strandedWindowIsRescuedIntoSurvivingScreen() throws {
        // The window lived high on the (now disconnected) external display;
        // its entire titlebar sits above the built-in screen's top.
        let stranded = CGRect(x: 200, y: 800, width: 1000, height: 700)
        let rescued = core.rescuedFrames(
            for: [stranded],
            displays: [Self.builtIn],
            thresholds: Self.strictThresholds,
            minimumWidth: Self.minWidth,
            minimumHeight: Self.minHeight
        )
        let frame = try #require(rescued[0], "stranded window must be rescued")
        #expect(Self.builtIn.visibleFrame.contains(frame))
        #expect(
            WindowTitlebarReachability(thresholds: Self.strictThresholds)
                .isTopStripReachable(frame, onAnyOf: [Self.builtIn.visibleFrame])
        )
    }

    @Test func reachableWindowIsNotMoved() {
        let fine = CGRect(x: 100, y: 100, width: 800, height: 600)
        let rescued = core.rescuedFrames(
            for: [fine],
            displays: [Self.builtIn],
            thresholds: Self.strictThresholds,
            minimumWidth: Self.minWidth,
            minimumHeight: Self.minHeight
        )
        #expect(rescued == [nil])
    }

    @Test func onlyStrandedWindowMovesInMixedSet() throws {
        let stranded = CGRect(x: 200, y: 800, width: 1000, height: 700)
        let fine = CGRect(x: 100, y: 100, width: 800, height: 600)
        let rescued = core.rescuedFrames(
            for: [stranded, fine],
            displays: [Self.builtIn],
            thresholds: Self.strictThresholds,
            minimumWidth: Self.minWidth,
            minimumHeight: Self.minHeight
        )
        #expect(rescued.count == 2)
        #expect(rescued[0] != nil)
        #expect(rescued[1] == nil)
    }

    @Test func tuckedUnderMenuBarIsRescuedFullyVisible() throws {
        // Titlebar band (top 28pt) fully inside the menu-bar band (944..982):
        // lenient-reachable, but the drag band itself is covered — after a real
        // topology change the rescue pulls it fully into the visible area.
        let tucked = CGRect(x: 320, y: 372, width: 800, height: 600) // maxY 972
        let rescued = core.rescuedFrames(
            for: [tucked],
            displays: [Self.builtIn],
            thresholds: Self.strictThresholds,
            minimumWidth: Self.minWidth,
            minimumHeight: Self.minHeight
        )
        let frame = try #require(rescued[0], "tucked window must be rescued on topology change")
        #expect(frame.maxY <= Self.builtIn.visibleFrame.maxY)
        #expect(
            WindowTitlebarReachability(thresholds: Self.strictThresholds)
                .isTopStripReachable(frame, onAnyOf: [Self.builtIn.visibleFrame])
        )
    }

    @Test func oversizedWindowIsClampedIntoVisibleFrame() throws {
        let huge = CGRect(x: -200, y: -200, width: 3000, height: 2000)
        let rescued = core.rescuedFrames(
            for: [huge],
            displays: [Self.builtIn],
            thresholds: Self.strictThresholds,
            minimumWidth: Self.minWidth,
            minimumHeight: Self.minHeight
        )
        let frame = try #require(rescued[0], "oversized stranded window must be rescued")
        #expect(Self.builtIn.visibleFrame.contains(frame))
        #expect(frame.width <= Self.builtIn.visibleFrame.width)
        #expect(frame.height <= Self.builtIn.visibleFrame.height)
    }

    @Test func emptyDisplayListRescuesNothing() {
        let stranded = CGRect(x: 200, y: 800, width: 1000, height: 700)
        let rescued = core.rescuedFrames(
            for: [stranded],
            displays: [],
            thresholds: Self.strictThresholds,
            minimumWidth: Self.minWidth,
            minimumHeight: Self.minHeight
        )
        #expect(rescued == [nil])
    }

    @Test func rescueTargetsGreatestOverlapDisplay() throws {
        // Stranded above both screens, but its body overlaps the external
        // display — the rescue should land it there, not on the built-in.
        let stranded = CGRect(x: 2000, y: 1400, width: 800, height: 600)
        let rescued = core.rescuedFrames(
            for: [stranded],
            displays: [Self.builtIn, Self.external],
            thresholds: Self.strictThresholds,
            minimumWidth: Self.minWidth,
            minimumHeight: Self.minHeight
        )
        let frame = try #require(rescued[0], "stranded window must be rescued")
        #expect(Self.external.visibleFrame.contains(frame))
    }

    @Test func rescueFallsBackToNearestDisplayWithoutOverlap() throws {
        // Far beyond both screens — zero overlap anywhere, so the rescue must
        // use the nearest-by-center-distance fallback (external is closer).
        let stranded = CGRect(x: 6000, y: 3000, width: 800, height: 600)
        let rescued = core.rescuedFrames(
            for: [stranded],
            displays: [Self.builtIn, Self.external],
            thresholds: Self.strictThresholds,
            minimumWidth: Self.minWidth,
            minimumHeight: Self.minHeight
        )
        let frame = try #require(rescued[0], "no-overlap stranded window must be rescued")
        #expect(Self.external.visibleFrame.contains(frame))
    }

    // MARK: - Menu-bar arrangement changes (top inset is part of the signature)

    @Test func signatureChangesWhenMenuBarCoversDisplayTop() {
        // The menu bar appearing on (or moving to) a display changes only its
        // visibleFrame — but it shrinks the visible area from the top, which
        // can newly cover a flush-top drag band, so it MUST read as a change.
        let withoutMenuBar = SessionDisplayGeometry(
            displayID: 1,
            frame: Self.builtIn.frame,
            visibleFrame: Self.builtIn.frame // no top inset
        )
        let before = core.topologySignature(of: [withoutMenuBar])
        let after = core.topologySignature(of: [Self.builtIn]) // 38pt inset
        #expect(before != after)
        #expect(!core.signaturesHaveSameArrangement(before, after))
    }

    // MARK: - Settled-back transient (dirty-only) uses veto thresholds

    @Test func vetoThresholdRescueLeavesTuckedWindowAlone() {
        // A wake flap (displays re-enumerate, then settle back) must not move
        // a titlebar tucked under the menu bar: at the constrain veto's
        // thresholds the tucked window is still reachable, so no rescue.
        let tucked = CGRect(x: 320, y: 372, width: 800, height: 600) // maxY 972
        let rescued = core.rescuedFrames(
            for: [tucked],
            displays: [Self.builtIn],
            thresholds: .constrainVeto,
            minimumWidth: Self.minWidth,
            minimumHeight: Self.minHeight
        )
        #expect(rescued == [nil])
    }

    @Test func vetoThresholdRescueStillFixesFullyStrandedWindow() throws {
        // The same settled-back pass must still rescue a window whose titlebar
        // is entirely above the screen — the shape a real transient strand
        // produces.
        let stranded = CGRect(x: 200, y: 800, width: 1000, height: 700)
        let rescued = core.rescuedFrames(
            for: [stranded],
            displays: [Self.builtIn],
            thresholds: .constrainVeto,
            minimumWidth: Self.minWidth,
            minimumHeight: Self.minHeight
        )
        let frame = try #require(rescued[0], "fully stranded window must be rescued even at veto thresholds")
        #expect(Self.builtIn.visibleFrame.contains(frame))
    }
}
