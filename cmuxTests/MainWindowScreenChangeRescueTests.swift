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

    // MARK: - Topology signature

    @Test func signatureIsOrderIndependent() {
        let a = MainWindowScreenRescueCore.topologySignature(of: [Self.builtIn, Self.external])
        let b = MainWindowScreenRescueCore.topologySignature(of: [Self.external, Self.builtIn])
        #expect(a == b)
    }

    @Test func signatureChangesWhenDisplayDisconnects() {
        let both = MainWindowScreenRescueCore.topologySignature(of: [Self.builtIn, Self.external])
        let one = MainWindowScreenRescueCore.topologySignature(of: [Self.builtIn])
        #expect(both != one)
    }

    @Test func signatureIgnoresVisibleFrameOnlyChanges() {
        // A Dock resize changes visibleFrame but not the display's frame or
        // identity — it must not read as a topology change.
        let dockResized = SessionDisplayGeometry(
            displayID: 1,
            frame: Self.builtIn.frame,
            visibleFrame: CGRect(x: 0, y: 90, width: 1512, height: 854)
        )
        let before = MainWindowScreenRescueCore.topologySignature(of: [Self.builtIn])
        let after = MainWindowScreenRescueCore.topologySignature(of: [dockResized])
        #expect(before == after)
    }

    // MARK: - Rescue decisions

    @Test func strandedWindowIsRescuedIntoSurvivingScreen() throws {
        // The window lived high on the (now disconnected) external display;
        // its entire titlebar sits above the built-in screen's top.
        let stranded = CGRect(x: 200, y: 800, width: 1000, height: 700)
        let rescued = MainWindowScreenRescueCore.rescuedFrames(
            for: [stranded],
            displays: [Self.builtIn],
            minimumWidth: Self.minWidth,
            minimumHeight: Self.minHeight
        )
        let frame = try #require(rescued[0], "stranded window must be rescued")
        #expect(Self.builtIn.visibleFrame.contains(frame))
        #expect(
            WindowTitlebarReachability.isTopStripReachable(
                frame,
                onAnyOf: [Self.builtIn.visibleFrame],
                thresholds: .strict
            )
        )
    }

    @Test func reachableWindowIsNotMoved() {
        let fine = CGRect(x: 100, y: 100, width: 800, height: 600)
        let rescued = MainWindowScreenRescueCore.rescuedFrames(
            for: [fine],
            displays: [Self.builtIn],
            minimumWidth: Self.minWidth,
            minimumHeight: Self.minHeight
        )
        #expect(rescued == [nil])
    }

    @Test func onlyStrandedWindowMovesInMixedSet() throws {
        let stranded = CGRect(x: 200, y: 800, width: 1000, height: 700)
        let fine = CGRect(x: 100, y: 100, width: 800, height: 600)
        let rescued = MainWindowScreenRescueCore.rescuedFrames(
            for: [stranded, fine],
            displays: [Self.builtIn],
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
        let rescued = MainWindowScreenRescueCore.rescuedFrames(
            for: [tucked],
            displays: [Self.builtIn],
            minimumWidth: Self.minWidth,
            minimumHeight: Self.minHeight
        )
        let frame = try #require(rescued[0], "tucked window must be rescued on topology change")
        #expect(frame.maxY <= Self.builtIn.visibleFrame.maxY)
        #expect(
            WindowTitlebarReachability.isTopStripReachable(
                frame,
                onAnyOf: [Self.builtIn.visibleFrame],
                thresholds: .strict
            )
        )
    }

    @Test func oversizedWindowIsClampedIntoVisibleFrame() throws {
        let huge = CGRect(x: -200, y: -200, width: 3000, height: 2000)
        let rescued = MainWindowScreenRescueCore.rescuedFrames(
            for: [huge],
            displays: [Self.builtIn],
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
        let rescued = MainWindowScreenRescueCore.rescuedFrames(
            for: [stranded],
            displays: [],
            minimumWidth: Self.minWidth,
            minimumHeight: Self.minHeight
        )
        #expect(rescued == [nil])
    }

    @Test func rescueTargetsGreatestOverlapDisplay() throws {
        // Stranded above both screens, but its body overlaps the external
        // display — the rescue should land it there, not on the built-in.
        let stranded = CGRect(x: 2000, y: 1400, width: 800, height: 600)
        let rescued = MainWindowScreenRescueCore.rescuedFrames(
            for: [stranded],
            displays: [Self.builtIn, Self.external],
            minimumWidth: Self.minWidth,
            minimumHeight: Self.minHeight
        )
        let frame = try #require(rescued[0], "stranded window must be rescued")
        #expect(Self.external.visibleFrame.contains(frame))
    }
}
