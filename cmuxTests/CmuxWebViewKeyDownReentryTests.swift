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

private var cmuxUnitTestCmuxWebViewKeyDownOverrideInstalled = false
private var cmuxUnitTestCmuxWebViewKeyDownHook: ((CmuxWebView, NSEvent) -> Bool)?

private final class FakeWKInspectorUndoResponderView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private final class BrowserUndoMenuActionSpy: NSObject {
    private(set) var invoked = false

    @objc func didInvoke(_ sender: Any?) {
        _ = sender
        invoked = true
    }
}

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

@Suite(.serialized)
final class CmuxWebViewKeyDownReentryTests {
    @Test
    @MainActor
    func printableOptionTextRoutesToBrowserKeyDownOnce() throws {
        try withHookedBrowserKeyDownWindow { window, keyDownEvents in
            let event = try #require(makeKeyDownEvent(
                key: "å",
                modifiers: [.option],
                keyCode: 0,
                windowNumber: window.windowNumber
            ))

            #expect(window.performKeyEquivalent(with: event))
            #expect(keyDownEvents().map(\.keyCode) == [0])
        }
    }

    @Test
    @MainActor
    func printableOptionTextDoesNotReenterBrowserKeyDownDuringWebKitKeyDownDispatch() throws {
        try withHookedBrowserKeyDownWindow { window, keyDownEvents in
            let event = try #require(makeKeyDownEvent(
                key: "å",
                modifiers: [.option],
                keyCode: 0,
                windowNumber: window.windowNumber
            ))

            let handled = cmuxWithBrowserWebKitKeyDownDispatch {
                window.performKeyEquivalent(with: event)
            }

            #expect(!handled)
            #expect(keyDownEvents().isEmpty)
        }
    }

    @Test
    @MainActor
    func browserReturnDoesNotReenterBrowserKeyDownDuringWebKitKeyDownDispatch() throws {
        try withHookedBrowserKeyDownWindow { window, keyDownEvents in
            let event = try #require(makeKeyDownEvent(
                key: "\r",
                modifiers: [],
                keyCode: 36,
                windowNumber: window.windowNumber
            ))

            let handled = cmuxWithBrowserWebKitKeyDownDispatch {
                window.performKeyEquivalent(with: event)
            }

            #expect(!handled)
            #expect(keyDownEvents().isEmpty)
        }
    }

    @Test
    @MainActor
    func browserArrowDoesNotReenterBrowserKeyDownDuringWebKitKeyDownDispatch() throws {
        try withHookedBrowserKeyDownWindow { window, keyDownEvents in
            let event = try #require(makeKeyDownEvent(
                key: "\u{F701}",
                modifiers: [],
                keyCode: 125,
                windowNumber: window.windowNumber
            ))

            let handled = cmuxWithBrowserWebKitKeyDownDispatch {
                window.performKeyEquivalent(with: event)
            }

            #expect(!handled)
            #expect(keyDownEvents().isEmpty)
        }
    }

    @Test
    @MainActor
    func browserUndoRedoFallsBackToBrowserKeyDownWhenWebKitDeclines() throws {
        try withHookedBrowserKeyDownWindow { window, keyDownEvents in
            installCmuxUnitTestWKWebViewPerformKeyEquivalentOverride()

            var performKeyEquivalentEvents: [NSEvent] = []
            cmuxUnitTestWKWebViewPerformKeyEquivalentHook = { currentWebView, event in
                guard currentWebView.window === window else { return nil }
                performKeyEquivalentEvents.append(event)
                return false
            }
            defer { cmuxUnitTestWKWebViewPerformKeyEquivalentHook = nil }

            let event = try #require(makeKeyDownEvent(
                key: "z",
                modifiers: [.command],
                keyCode: UInt16(kVK_ANSI_Z),
                windowNumber: window.windowNumber
            ))

            #expect(window.performKeyEquivalent(with: event))
            #expect(performKeyEquivalentEvents.map(\.keyCode) == [UInt16(kVK_ANSI_Z)])
            #expect(keyDownEvents().map(\.keyCode) == [UInt16(kVK_ANSI_Z)])
        }
    }

    @Test
    @MainActor
    func browserUndoRedoDoesNotRouteDuringWebKitKeyDownReentry() throws {
        try withHookedBrowserKeyDownWindow { window, keyDownEvents in
            installCmuxUnitTestWKWebViewPerformKeyEquivalentOverride()

            var performKeyEquivalentEvents: [NSEvent] = []
            cmuxUnitTestWKWebViewPerformKeyEquivalentHook = { currentWebView, event in
                guard currentWebView.window === window else { return nil }
                performKeyEquivalentEvents.append(event)
                return false
            }
            defer { cmuxUnitTestWKWebViewPerformKeyEquivalentHook = nil }

            let event = try #require(makeKeyDownEvent(
                key: "z",
                modifiers: [.command],
                keyCode: UInt16(kVK_ANSI_Z),
                windowNumber: window.windowNumber
            ))

            let handled = cmuxWithBrowserWebKitKeyDownDispatch {
                window.performKeyEquivalent(with: event)
            }

            #expect(handled)
            #expect(performKeyEquivalentEvents.isEmpty)
            #expect(keyDownEvents().isEmpty)
        }
    }

    @Test
    @MainActor
    func browserUndoRedoDoesNotBypassMenuWhenWebInspectorResponderIsFocused() throws {
        try withHookedBrowserKeyDownWindow { window, keyDownEvents in
            installCmuxUnitTestWKWebViewPerformKeyEquivalentOverride()

            let spy = BrowserUndoMenuActionSpy()
            let previousMenu = installUndoMenu(target: spy)
            defer { NSApp.mainMenu = previousMenu }

            let webView = try #require(window.contentView?.subviews.compactMap { $0 as? CmuxWebView }.first)
            let inspectorView = FakeWKInspectorUndoResponderView(frame: NSRect(x: 0, y: 0, width: 32, height: 20))
            webView.addSubview(inspectorView)

            var performKeyEquivalentEvents: [NSEvent] = []
            cmuxUnitTestWKWebViewPerformKeyEquivalentHook = { currentWebView, event in
                guard currentWebView === webView else { return nil }
                performKeyEquivalentEvents.append(event)
                return true
            }
            defer { cmuxUnitTestWKWebViewPerformKeyEquivalentHook = nil }

            #expect(window.makeFirstResponder(inspectorView))
            let event = try #require(makeKeyDownEvent(
                key: "z",
                modifiers: [.command],
                keyCode: UInt16(kVK_ANSI_Z),
                windowNumber: window.windowNumber
            ))

            #expect(window.performKeyEquivalent(with: event))
            #expect(spy.invoked)
            #expect(performKeyEquivalentEvents.isEmpty)
            #expect(keyDownEvents().isEmpty)
        }
    }

    @MainActor
    private func withHookedBrowserKeyDownWindow(
        _ body: (NSWindow, () -> [NSEvent]) throws -> Void
    ) rethrows {
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

        #expect(window.makeFirstResponder(webView))
        try body(window, { keyDownEvents })
    }

    private func installUndoMenu(target: NSObject) -> NSMenu? {
        let previousMenu = NSApp.mainMenu
        let mainMenu = NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        let undoItem = NSMenuItem(
            title: "Undo",
            action: #selector(BrowserUndoMenuActionSpy.didInvoke(_:)),
            keyEquivalent: "z"
        )
        undoItem.keyEquivalentModifierMask = [.command]
        undoItem.target = target
        editMenu.addItem(undoItem)
        mainMenu.addItem(editItem)
        mainMenu.setSubmenu(editMenu, for: editItem)
        _ = NSApplication.shared
        NSApp.mainMenu = mainMenu
        return previousMenu
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
