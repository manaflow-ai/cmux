import AppKit
import CmuxWindowing
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct AppDelegateOversizedFrameRestoreTests {
    @Test
    func oversizedSavedFrameClampsToItsDisplay() throws {
        let visible = CGRect(x: 0, y: 0, width: 1_512, height: 944)
        let display = AppDelegate.SessionDisplayGeometry(
            displayID: 1,
            stableID: "uuid:BUILTIN",
            frame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
            visibleFrame: visible
        )
        let restored = try #require(AppDelegate.resolvedWindowFrame(
            from: SessionRectSnapshot(CGRect(x: 4, y: 4, width: 13_375, height: 889)),
            display: SessionDisplaySnapshot(
                displayID: 1,
                stableID: "uuid:BUILTIN",
                frame: SessionRectSnapshot(display.frame),
                visibleFrame: SessionRectSnapshot(visible)
            ),
            availableDisplays: [display],
            fallbackDisplay: display
        ))
        #expect(restored.width <= visible.width)
        #expect(restored.height <= visible.height)
        #expect(visible.contains(restored))
    }

    @Test
    func displaySpanningSavedFrameIsPreserved() throws {
        let builtIn = AppDelegate.SessionDisplayGeometry(
            displayID: 1,
            stableID: "uuid:BUILTIN",
            frame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_512, height: 944)
        )
        let external = AppDelegate.SessionDisplayGeometry(
            displayID: 2,
            stableID: "uuid:EXTERNAL",
            frame: CGRect(x: 1_512, y: 0, width: 1_920, height: 1_080),
            visibleFrame: CGRect(x: 1_512, y: 0, width: 1_920, height: 1_055)
        )
        let spanning = CGRect(x: 500, y: 100, width: 2_500, height: 700)
        let restored = try #require(AppDelegate.resolvedWindowFrame(
            from: SessionRectSnapshot(spanning),
            display: SessionDisplaySnapshot(
                displayID: 1,
                stableID: "uuid:BUILTIN",
                frame: SessionRectSnapshot(builtIn.frame),
                visibleFrame: SessionRectSnapshot(builtIn.visibleFrame)
            ),
            availableDisplays: [builtIn, external],
            fallbackDisplay: builtIn
        ))
        #expect(restored == spanning)
    }

    @Test
    func fullPhysicalDisplayHeightIsPreserved() {
        let display = AppDelegate.SessionDisplayGeometry(
            displayID: 1,
            stableID: "uuid:BUILTIN",
            frame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_512, height: 944)
        )
        let saved = CGRect(x: 0, y: 0, width: 1_200, height: 982)

        let restored = AppDelegate.preservingOrClampingExactFrame(
            saved,
            targetDisplay: display,
            availableDisplays: [display],
            minWidth: 400,
            minHeight: 300
        )

        #expect(restored == saved)
    }

    @Test
    func runtimeCapKeepsAnIntersectingLeftEdgeFrameReachable() {
        let display = CGRect(x: 0, y: 0, width: 1_512, height: 982)
        let runaway = CGRect(x: -12_000, y: 120, width: 12_400, height: 700)

        let capped = CmuxMainWindow.frameByCappingOversizedDimensions(
            runaway,
            displayFrames: [(frame: display, visibleFrame: display)]
        )

        #expect(capped.width == display.width)
        #expect(CmuxMainWindow.isTitlebarReachable(frame: capped, visibleFrame: display))
    }

    @Test
    func runtimeCapKeepsAnIntersectingBottomEdgeFrameReachable() {
        let display = CGRect(x: 0, y: 0, width: 1_512, height: 982)
        let runaway = CGRect(x: 100, y: -9_000, width: 900, height: 9_500)

        let capped = CmuxMainWindow.frameByCappingOversizedDimensions(
            runaway,
            displayFrames: [(frame: display, visibleFrame: display)]
        )

        #expect(capped.height == display.height)
        #expect(CmuxMainWindow.isTitlebarReachable(frame: capped, visibleFrame: display))
    }

    @Test
    func runtimeCapKeepsTheTitlebarBelowTheMenuBar() {
        let physical = CGRect(x: 0, y: 0, width: 1_512, height: 982)
        let visible = CGRect(x: 0, y: 0, width: 1_512, height: 944)
        let runaway = CGRect(x: 100, y: 500, width: 900, height: 9_500)

        let capped = CmuxMainWindow.frameByCappingOversizedDimensions(
            runaway,
            displayFrames: [(frame: physical, visibleFrame: visible)]
        )

        #expect(capped.height == physical.height)
        #expect(CmuxMainWindow.isTitlebarReachable(frame: capped, visibleFrame: visible))
    }

    @Test
    func runtimeCapPreservesLegitimatePartialAndSpanningFrames() {
        let displays = [
            (
                frame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
                visibleFrame: CGRect(x: 0, y: 0, width: 1_512, height: 982)
            ),
            (
                frame: CGRect(x: 1_512, y: 0, width: 1_920, height: 1_080),
                visibleFrame: CGRect(x: 1_512, y: 0, width: 1_920, height: 1_080)
            ),
        ]
        let partial = CGRect(x: -300, y: 120, width: 900, height: 700)
        let spanning = CGRect(x: 1_000, y: 100, width: 2_000, height: 700)

        #expect(CmuxMainWindow.frameByCappingOversizedDimensions(
            partial,
            displayFrames: displays
        ) == partial)
        #expect(CmuxMainWindow.frameByCappingOversizedDimensions(
            spanning,
            displayFrames: displays
        ) == spanning)
    }
}
