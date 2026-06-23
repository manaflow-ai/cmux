import XCTest
import AppKit
import WebKit
import ObjectiveC.runtime

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private var cmuxUnitTestCmuxWebViewKeyDownOverrideInstalled = false
private var cmuxUnitTestCmuxWebViewKeyDownHook: ((CmuxWebView, NSEvent) -> Bool)?

extension CmuxWebView {
    @objc func cmuxUnitTest_keyDown(with event: NSEvent) {
        if cmuxUnitTestCmuxWebViewKeyDownHook?(self, event) == true {
            return
        }
        cmuxUnitTest_keyDown(with: event)
    }
}

private func installCmuxUnitTestCmuxWebViewKeyDownOverride() {
    guard !cmuxUnitTestCmuxWebViewKeyDownOverrideInstalled else { return }

    let originalSelector = #selector(CmuxWebView.keyDown(with:))
    let swizzledSelector = #selector(CmuxWebView.cmuxUnitTest_keyDown(with:))

    guard let originalMethod = class_getInstanceMethod(CmuxWebView.self, originalSelector),
          let swizzledMethod = class_getInstanceMethod(CmuxWebView.self, swizzledSelector) else {
        fatalError("Unable to locate CmuxWebView keyDown methods for swizzling")
    }

    method_exchangeImplementations(originalMethod, swizzledMethod)
    cmuxUnitTestCmuxWebViewKeyDownOverrideInstalled = true
}

final class CmuxWebViewKeyDownReentryTests: XCTestCase {
    @MainActor
    func testPrintableOptionTextRoutesToBrowserKeyDownOnce() {
        withHookedBrowserKeyDownWindow { window, keyDownEvents in
            guard let event = makeKeyDownEvent(
                key: "å",
                modifiers: [.option],
                keyCode: 0,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct printable Option event")
                return
            }

            XCTAssertTrue(window.performKeyEquivalent(with: event))
            XCTAssertEqual(keyDownEvents().map(\.keyCode), [0])
        }
    }

    @MainActor
    func testPrintableOptionTextDoesNotReenterBrowserKeyDownDuringWebKitKeyDownDispatch() {
        withHookedBrowserKeyDownWindow { window, keyDownEvents in
            guard let event = makeKeyDownEvent(
                key: "å",
                modifiers: [.option],
                keyCode: 0,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct printable Option event")
                return
            }

            let handled = cmuxWithBrowserWebKitKeyDownDispatch {
                window.performKeyEquivalent(with: event)
            }

            XCTAssertFalse(handled)
            XCTAssertTrue(keyDownEvents().isEmpty)
        }
    }

    @MainActor
    func testBrowserReturnDoesNotReenterBrowserKeyDownDuringWebKitKeyDownDispatch() {
        withHookedBrowserKeyDownWindow { window, keyDownEvents in
            guard let event = makeKeyDownEvent(
                key: "\r",
                modifiers: [],
                keyCode: 36,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct Return event")
                return
            }

            let handled = cmuxWithBrowserWebKitKeyDownDispatch {
                window.performKeyEquivalent(with: event)
            }

            XCTAssertFalse(handled)
            XCTAssertTrue(keyDownEvents().isEmpty)
        }
    }

    @MainActor
    func testBrowserArrowDoesNotReenterBrowserKeyDownDuringWebKitKeyDownDispatch() {
        withHookedBrowserKeyDownWindow { window, keyDownEvents in
            guard let event = makeKeyDownEvent(
                key: "\u{F701}",
                modifiers: [],
                keyCode: 125,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct Down Arrow event")
                return
            }

            let handled = cmuxWithBrowserWebKitKeyDownDispatch {
                window.performKeyEquivalent(with: event)
            }

            XCTAssertFalse(handled)
            XCTAssertTrue(keyDownEvents().isEmpty)
        }
    }

    @MainActor
    private func withHookedBrowserKeyDownWindow(
        _ body: (NSWindow, () -> [NSEvent]) -> Void
    ) {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()
        installCmuxUnitTestCmuxWebViewKeyDownOverride()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let webView = CmuxWebView(frame: container.bounds, configuration: WKWebViewConfiguration())
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        var keyDownEvents: [NSEvent] = []
        cmuxUnitTestCmuxWebViewKeyDownHook = { currentWebView, event in
            guard currentWebView === webView else { return false }
            keyDownEvents.append(event)
            return true
        }

        window.makeKeyAndOrderFront(nil)
        defer {
            cmuxUnitTestCmuxWebViewKeyDownHook = nil
            window.orderOut(nil)
        }

        XCTAssertTrue(window.makeFirstResponder(webView))
        body(window, { keyDownEvents })
    }

    private func makeKeyDownEvent(
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}
