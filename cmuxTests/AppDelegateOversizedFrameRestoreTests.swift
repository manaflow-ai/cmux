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
}
