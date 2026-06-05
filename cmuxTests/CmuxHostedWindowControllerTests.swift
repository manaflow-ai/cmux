import AppKit
import SwiftUI
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class CmuxHostedWindowControllerTests: XCTestCase {
    private func makeController(
        identifier: String,
        onWindowWillClose: @escaping @MainActor () -> Void = {}
    ) -> CmuxHostedWindowController {
        CmuxHostedWindowController(
            identifier: identifier,
            title: "Test",
            contentSize: NSSize(width: 400, height: 300),
            minSize: NSSize(width: 200, height: 150),
            rootView: Color.clear,
            onWindowWillClose: onWindowWillClose
        )
    }

    func testWindowIsConfiguredAsAuxiliary() {
        let controller = makeController(identifier: "cmux.settings.test.aux")
        guard let window = controller.window else { return XCTFail("no window") }
        defer { window.orderOut(nil) }

        XCTAssertEqual(window.identifier?.rawValue, "cmux.settings.test.aux")
        XCTAssertTrue(window.isExcludedFromWindowsMenu)
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    func testCloseInvokesCallbackAndBreaksHostingCycle() {
        var closed = false
        let controller = makeController(identifier: "cmux.settings.test.close") { closed = true }
        guard let window = controller.window else { return XCTFail("no window") }

        XCTAssertNotNil(window.contentViewController, "hosting controller is the window's content")
        window.makeKeyAndOrderFront(nil)
        window.close()

        XCTAssertTrue(closed, "windowWillClose must invoke onWindowWillClose")
        // The cycle-break nils the content view controller + toolbar so the
        // NSHostingController <-> window sceneBridging retain cycle releases and
        // the window can deallocate (issue #5321).
        XCTAssertNil(window.contentViewController)
        XCTAssertNil(window.toolbar)
    }

    /// #5321 regression: a closed hosted Settings window must actually
    /// deallocate and leave `NSApp.windows`, otherwise a third-party window
    /// switcher (AltTab) or the Window menu can resurrect a "closed" window.
    /// Without the `windowWillClose` cycle-break this fails — the sceneBridging
    /// retain cycle keeps the window alive and listed.
    func testClosedHostedWindowDeallocatesAndLeavesWindowList() {
        let identifier = "cmux.settings.test.dealloc.\(UUID().uuidString)"
        weak var weakWindow: NSWindow?

        autoreleasepool {
            var controller: CmuxHostedWindowController? = makeController(identifier: identifier)
            weakWindow = controller?.window
            controller?.window?.makeKeyAndOrderFront(nil)
            XCTAssertTrue(
                NSApp.windows.contains { $0.identifier?.rawValue == identifier },
                "window should be listed while open"
            )
            controller?.window?.close()
            // The presenter drops its controller reference in didCloseWindow; do
            // the same here so nothing keeps the window alive.
            controller = nil
        }

        XCTAssertNil(weakWindow, "hosted window should deallocate after close")
        XCTAssertFalse(
            NSApp.windows.contains { $0.identifier?.rawValue == identifier },
            "closed hosted window must leave NSApp.windows (issue #5321)"
        )
    }
}
