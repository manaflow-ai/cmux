import AppKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
@MainActor
final class CmuxMainWindowFullScreenCapabilityTests: XCTestCase {
    // cmux creates its main window programmatically and never loaded fullscreen
    // capability from a nib, so it historically relied on AppKit *implicitly*
    // granting `.fullScreenPrimary` to a resizable, titled window. That implicit
    // grant is not reliable across macOS versions / display arrangements: on
    // macOS 26 (Tahoe) a freshly-created CmuxMainWindow reports an empty
    // collection behavior (`rawValue == 0`) and AppKit does NOT treat it as
    // fullscreen-capable — so `toggleFullScreen(_:)`, ⌃⌘F, and the green
    // traffic-light button all fail to enter a native fullscreen Space (the
    // green button only zooms). See issue #5933.
    //
    // A CmuxMainWindow must therefore *declare* `.fullScreenPrimary` itself so
    // native fullscreen is reachable regardless of the OS's implicit default.
    func testMainWindowDeclaresFullScreenPrimaryCapability() {
        let window = CmuxMainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil)
            window.close()
        }

        XCTAssertTrue(
            window.collectionBehavior.contains(.fullScreenPrimary),
            "Main window must declare .fullScreenPrimary so native fullscreen is reachable"
        )
        XCTAssertFalse(
            window.collectionBehavior.contains(.fullScreenNone),
            "Main window must never carry .fullScreenNone, which suppresses native fullscreen"
        )
    }
}
#endif
