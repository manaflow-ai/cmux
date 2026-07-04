import CoreGraphics
import CmuxWindowing
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Main window visible-frame fitting")
struct MainWindowVisibleFrameFitCoreTests {
    private let core = MainWindowVisibleFrameFitCore()

    private static let builtInDisplay = SessionDisplayGeometry(
        displayID: 42,
        frame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1_512, height: 944)
    )
    private static let rightDisplay = SessionDisplayGeometry(
        displayID: 77,
        frame: CGRect(x: 1_512, y: 0, width: 2_560, height: 1_440),
        visibleFrame: CGRect(x: 1_512, y: 0, width: 2_560, height: 1_415)
    )
    private static let minimumWidth: CGFloat = 300
    private static let minimumHeight: CGFloat = 200

    @Test func cutOffLeftWithReachableTitlebarIsFitIntoVisibleFrame() throws {
        let cutOff = CGRect(x: -220, y: 20, width: 1_800, height: 900)

        let fitted = try #require(core.fittedFrame(
            for: cutOff,
            displays: [Self.builtInDisplay],
            minimumWidth: Self.minimumWidth,
            minimumHeight: Self.minimumHeight
        ))

        #expect(Self.builtInDisplay.visibleFrame.contains(fitted))
        #expect(fitted.minX == 0)
        #expect(fitted.width == Self.builtInDisplay.visibleFrame.width)
        #expect(fitted.minY == cutOff.minY)
        #expect(fitted.height == cutOff.height)
    }

    @Test func mostlyOffscreenRightIsClampedIntoCurrentScreen() throws {
        let mostlyOffscreen = CGRect(x: 1_440, y: 120, width: 900, height: 600)

        let fitted = try #require(core.fittedFrame(
            for: mostlyOffscreen,
            displays: [Self.builtInDisplay],
            minimumWidth: Self.minimumWidth,
            minimumHeight: Self.minimumHeight
        ))

        #expect(Self.builtInDisplay.visibleFrame.contains(fitted))
        #expect(fitted.maxX == Self.builtInDisplay.visibleFrame.maxX)
        #expect(fitted.width == mostlyOffscreen.width)
        #expect(fitted.minY == mostlyOffscreen.minY)
    }

    @Test func oversizedFrameIsShrunkToOnlyRemainingScreen() throws {
        let oversized = CGRect(x: -100, y: -80, width: 3_000, height: 2_000)

        let fitted = try #require(core.fittedFrame(
            for: oversized,
            displays: [Self.builtInDisplay],
            minimumWidth: Self.minimumWidth,
            minimumHeight: Self.minimumHeight
        ))

        #expect(fitted == Self.builtInDisplay.visibleFrame)
    }

    @Test func fullyVisibleFrameReturnsNil() {
        let visible = CGRect(x: 100, y: 100, width: 800, height: 600)

        let fitted = core.fittedFrame(
            for: visible,
            displays: [Self.builtInDisplay],
            minimumWidth: Self.minimumWidth,
            minimumHeight: Self.minimumHeight
        )

        #expect(fitted == nil)
    }

    @Test func frameExactlyEqualToVisibleFrameReturnsNil() {
        let fitted = core.fittedFrame(
            for: Self.builtInDisplay.visibleFrame,
            displays: [Self.builtInDisplay],
            minimumWidth: Self.minimumWidth,
            minimumHeight: Self.minimumHeight
        )

        #expect(fitted == nil)
    }

    @Test func degenerateDisplayListsReturnNil() {
        let cutOff = CGRect(x: -220, y: 20, width: 1_800, height: 900)
        let degenerate = SessionDisplayGeometry(
            displayID: 99,
            frame: CGRect(x: 0, y: 0, width: 0, height: 0),
            visibleFrame: CGRect(x: 0, y: 0, width: 0, height: 0)
        )

        #expect(core.fittedFrame(
            for: cutOff,
            displays: [],
            minimumWidth: Self.minimumWidth,
            minimumHeight: Self.minimumHeight
        ) == nil)
        #expect(core.fittedFrame(
            for: cutOff,
            displays: [degenerate],
            minimumWidth: Self.minimumWidth,
            minimumHeight: Self.minimumHeight
        ) == nil)
    }

    @Test func straddlingFrameTargetsGreatestVisibleOverlapDisplay() throws {
        let straddling = CGRect(x: 1_300, y: 80, width: 900, height: 600)

        let fitted = try #require(core.fittedFrame(
            for: straddling,
            displays: [Self.builtInDisplay, Self.rightDisplay],
            minimumWidth: Self.minimumWidth,
            minimumHeight: Self.minimumHeight
        ))

        #expect(Self.rightDisplay.visibleFrame.contains(fitted))
    }

    @Test func topologySignatureIgnoresSideAndBottomDockInsetChanges() {
        let dockResized = SessionDisplayGeometry(
            displayID: Self.builtInDisplay.displayID,
            frame: Self.builtInDisplay.frame,
            visibleFrame: CGRect(x: 120, y: 80, width: 1_392, height: 864)
        )

        #expect(core.topologySignature(of: [Self.builtInDisplay])
            == core.topologySignature(of: [dockResized]))
    }

    @Test func topologySignatureChangesWhenTopInsetChanges() {
        let menuBarMoved = SessionDisplayGeometry(
            displayID: Self.builtInDisplay.displayID,
            frame: Self.builtInDisplay.frame,
            visibleFrame: Self.builtInDisplay.frame
        )

        #expect(core.topologySignature(of: [Self.builtInDisplay])
            != core.topologySignature(of: [menuBarMoved]))
    }

    @Test func topologySignatureChangesWhenDisplayIDChanges() {
        let renumbered = SessionDisplayGeometry(
            displayID: 99,
            frame: Self.builtInDisplay.frame,
            visibleFrame: Self.builtInDisplay.visibleFrame
        )

        #expect(core.topologySignature(of: [Self.builtInDisplay])
            != core.topologySignature(of: [renumbered]))
    }

    @Test func restoreClampsReachableTitlebarFrameCutOffPastLeftEdgeWhenDisplayChanged() throws {
        let savedFrame = SessionRectSnapshot(x: -220, y: 20, width: 1_800, height: 900)
        let savedDisplay = SessionDisplaySnapshot(
            displayID: 42,
            frame: SessionRectSnapshot(x: -512, y: 0, width: 2_560, height: 1_440),
            visibleFrame: SessionRectSnapshot(x: -512, y: 0, width: 2_560, height: 1_415)
        )
        let currentDisplay = Self.builtInDisplay

        let restored = try #require(AppDelegate.resolvedWindowFrame(
            from: savedFrame,
            display: savedDisplay,
            availableDisplays: [currentDisplay],
            fallbackDisplay: currentDisplay
        ))

        #expect(currentDisplay.visibleFrame.contains(restored))
        #expect(restored.minX == 0)
        #expect(restored.width == currentDisplay.visibleFrame.width)
        #expect(restored.minY == CGFloat(savedFrame.y))
        #expect(restored.height == CGFloat(savedFrame.height))
    }
}
