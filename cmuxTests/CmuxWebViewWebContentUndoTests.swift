import AppKit
import Carbon.HIToolbox
import Testing
import WebKit
import ObjectiveC.runtime

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/9677.
///
/// With a browser web view focused, Cmd+Z / Cmd+Shift+Z are routed away from
/// the AppKit Edit menu (the stale-`NSUndoManager` crash fix for
/// https://github.com/manaflow-ai/cmux/issues/7272). When the page declines
/// the chord, WebKit resends it and the routing must perform the web view's
/// own editing undo/redo — not silently swallow the key, and not run it
/// against the window's shared undo manager whose entries can outlive their
/// web view.

private var cmuxUnitTestWKWebViewKeyDownOverrideInstalled = false
private var cmuxUnitTestWKWebViewKeyDownHook: ((WKWebView, NSEvent) -> Bool)?

extension WKWebView {
    @objc func cmuxUnitTestWebContentUndo_keyDown(with event: NSEvent) {
        if cmuxUnitTestWKWebViewKeyDownHook?(self, event) == true {
            return
        }
        cmuxUnitTestWebContentUndo_keyDown(with: event)
    }
}

/// Swizzles `WKWebView.keyDown(with:)` so tests can observe and suppress key
/// events forwarded into WebKit without launching a web content process.
private func installCmuxUnitTestWKWebViewKeyDownOverride() {
    guard !cmuxUnitTestWKWebViewKeyDownOverrideInstalled else { return }

    let originalSelector = #selector(NSResponder.keyDown(with:))
    let swizzledSelector = #selector(WKWebView.cmuxUnitTestWebContentUndo_keyDown(with:))

    guard let originalMethod = class_getInstanceMethod(WKWebView.self, originalSelector),
          let swizzledMethod = class_getInstanceMethod(WKWebView.self, swizzledSelector) else {
        fatalError("Unable to locate WKWebView keyDown methods for swizzling")
    }

    let didAddMethod = class_addMethod(
        WKWebView.self,
        originalSelector,
        method_getImplementation(swizzledMethod),
        method_getTypeEncoding(swizzledMethod)
    )

    if didAddMethod {
        class_replaceMethod(
            WKWebView.self,
            swizzledSelector,
            method_getImplementation(originalMethod),
            method_getTypeEncoding(originalMethod)
        )
    } else {
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    cmuxUnitTestWKWebViewKeyDownOverrideInstalled = true
}

private final class WebContentUndoSpy {
    var undoCount = 0
    var redoCount = 0
}

@Suite(.serialized)
final class CmuxWebViewWebContentUndoTests {
    @Test
    @MainActor
    func browserCmdZPerformsWebContentUndoWhenPageDeclinesTheChord() throws {
        try withBrowserUndoWindow { window, webView, forwardedKeyDownEvents in
            let spy = WebContentUndoSpy()
            let undoManager = try #require(webView.undoManager)
            undoManager.registerUndo(withTarget: spy) { $0.undoCount += 1 }
            #expect(undoManager.canUndo)

            let event = try #require(makeKeyDownEvent(
                key: "z",
                modifiers: [.command],
                keyCode: UInt16(kVK_ANSI_Z),
                windowNumber: window.windowNumber
            ))

            #expect(window.performKeyEquivalent(with: event))
            #expect(spy.undoCount == 1)
            #expect(forwardedKeyDownEvents().isEmpty)
        }
    }

    @Test
    @MainActor
    func browserCmdShiftZPerformsWebContentRedoWhenPageDeclinesTheChord() throws {
        try withBrowserUndoWindow { window, webView, forwardedKeyDownEvents in
            let spy = WebContentUndoSpy()
            let undoManager = try #require(webView.undoManager)
            undoManager.registerUndo(withTarget: spy) { target in
                target.undoCount += 1
                undoManager.registerUndo(withTarget: target) { $0.redoCount += 1 }
            }
            undoManager.undo()
            #expect(spy.undoCount == 1)
            #expect(undoManager.canRedo)

            let event = try #require(makeKeyDownEvent(
                key: "z",
                modifiers: [.command, .shift],
                keyCode: UInt16(kVK_ANSI_Z),
                windowNumber: window.windowNumber
            ))

            #expect(window.performKeyEquivalent(with: event))
            #expect(spy.redoCount == 1)
            #expect(forwardedKeyDownEvents().isEmpty)
        }
    }

    /// WebKit registers every web-content edit command on the web view's
    /// `undoManager`. The default NSResponder resolution reaches the window's
    /// shared undo manager, mixing every web view's edit commands into one
    /// stack whose targets can outlive their view — the stale-target crash
    /// class behind https://github.com/manaflow-ai/cmux/issues/7272. Each web
    /// view must own an undo manager scoped to its own lifetime.
    @Test
    @MainActor
    func webContentUndoManagerIsScopedPerWebView() throws {
        try withBrowserUndoWindow { window, webView, _ in
            let secondWebView = CmuxWebView(
                frame: webView.frame,
                configuration: WKWebViewConfiguration()
            )
            defer { secondWebView.removeFromSuperview() }
            webView.superview?.addSubview(secondWebView)

            let firstManager = try #require(webView.undoManager)
            let secondManager = try #require(secondWebView.undoManager)
            #expect(firstManager !== secondManager)
            #expect(firstManager !== window.undoManager)
            #expect(secondManager !== window.undoManager)
        }
    }

    @MainActor
    private func withBrowserUndoWindow(
        _ body: (NSWindow, CmuxWebView, () -> [NSEvent]) throws -> Void
    ) rethrows {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()
        installCmuxUnitTestWKWebViewPerformKeyEquivalentOverride()
        installCmuxUnitTestWKWebViewKeyDownOverride()

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

        // Model WebKit's resend of a page-unhandled chord: the web view
        // declines the key equivalent (WebViewImpl::doneWithKeyEvent resends
        // the event and performKeyEquivalent returns NO for a resent key).
        cmuxUnitTestWKWebViewPerformKeyEquivalentHook = { currentWebView, _ in
            guard currentWebView === webView else { return nil }
            return false
        }

        // Record any key events the browser view forwards into WebKit so the
        // tests can assert routed undo/redo chords are executed, not
        // re-forwarded, and so no web content process is spun up.
        var forwardedKeyDownEvents: [NSEvent] = []
        cmuxUnitTestWKWebViewKeyDownHook = { currentWebView, event in
            guard currentWebView === webView else { return false }
            forwardedKeyDownEvents.append(event)
            return true
        }

        window.makeKeyAndOrderFront(nil)
        defer {
            cmuxUnitTestWKWebViewPerformKeyEquivalentHook = nil
            cmuxUnitTestWKWebViewKeyDownHook = nil
            window.orderOut(nil)
        }

        #expect(window.makeFirstResponder(webView))
        try body(window, webView, { forwardedKeyDownEvents })
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
