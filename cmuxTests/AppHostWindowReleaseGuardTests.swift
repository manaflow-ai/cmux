import AppKit
import XCTest

/// Guards the process-wide window-release guard installed by
/// `CmuxTestWindowReleaseGuard.m`.
///
/// AppKit defaults code-created windows to `isReleasedWhenClosed == true`,
/// which under ARC means `close()` over-releases the window and XCTest's
/// post-test autorelease-pool drain crashes the shared app host
/// (EXC_BAD_ACCESS in objc_release, reported by xcodebuild as "Restarting
/// after unexpected exit"). The guard swizzles NSWindow's designated
/// initializers so every window created in the test process defaults to
/// `isReleasedWhenClosed == false`, making test-teardown `close()` calls safe
/// regardless of whether the individual test remembered to set the flag.
final class AppHostWindowReleaseGuardTests: XCTestCase {
    func testCodeCreatedWindowDefaultsToNotReleasedWhenClosed() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        XCTAssertFalse(
            window.isReleasedWhenClosed,
            "Test-process windows must not be released on close: ARC already owns them, " +
            "and the extra release crashes the app host in the post-test pool drain"
        )
        window.close()
    }

    func testPanelInheritsGuardedDefault() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 60),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        XCTAssertFalse(panel.isReleasedWhenClosed)
        panel.close()
    }
}
