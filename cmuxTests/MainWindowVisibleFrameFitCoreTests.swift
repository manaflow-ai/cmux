import CoreGraphics
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Main window visible-frame fitting")
struct MainWindowVisibleFrameFitCoreTests {
    @Test func restoreClampsReachableTitlebarFrameCutOffPastLeftEdgeWhenDisplayChanged() throws {
        let savedFrame = SessionRectSnapshot(x: -220, y: 20, width: 1_800, height: 900)
        let savedDisplay = SessionDisplaySnapshot(
            displayID: 42,
            frame: SessionRectSnapshot(x: -512, y: 0, width: 2_560, height: 1_440),
            visibleFrame: SessionRectSnapshot(x: -512, y: 0, width: 2_560, height: 1_415)
        )
        let currentDisplay = AppDelegate.SessionDisplayGeometry(
            displayID: 42,
            frame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_512, height: 944)
        )

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
