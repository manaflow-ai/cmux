import XCTest
import AppKit
import SwiftUI
import WebKit
import SwiftUI
import ObjectiveC.runtime

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private var cmuxUnitTestInspectorAssociationKey: UInt8 = 0
private var cmuxUnitTestInspectorOverrideInstalled = false

private extension CmuxWebView {
    @objc func cmuxUnitTestInspector() -> NSObject? {
        objc_getAssociatedObject(self, &cmuxUnitTestInspectorAssociationKey) as? NSObject
    }
}

private extension WKWebView {
    func cmuxSetUnitTestInspector(_ inspector: NSObject?) {
        objc_setAssociatedObject(
            self,
            &cmuxUnitTestInspectorAssociationKey,
            inspector,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
}

private func installCmuxUnitTestInspectorOverride() {
    guard !cmuxUnitTestInspectorOverrideInstalled else { return }

    guard let replacementMethod = class_getInstanceMethod(
        CmuxWebView.self,
        #selector(CmuxWebView.cmuxUnitTestInspector)
    ) else {
        fatalError("Unable to locate test inspector replacement method")
    }

    let added = class_addMethod(
        CmuxWebView.self,
        NSSelectorFromString("_inspector"),
        method_getImplementation(replacementMethod),
        method_getTypeEncoding(replacementMethod)
    )
    guard added else {
        fatalError("Unable to install CmuxWebView _inspector test override")
    }

    cmuxUnitTestInspectorOverrideInstalled = true
}

final class SplitShortcutTransientFocusGuardTests: XCTestCase {
    func testSuppressesWhenFirstResponderFallsBackAndHostedViewIsTiny() {
        XCTAssertTrue(
            shouldSuppressSplitShortcutForTransientTerminalFocusInputs(
                firstResponderIsWindow: true,
                hostedSize: CGSize(width: 79, height: 0),
                hostedHiddenInHierarchy: false,
                hostedAttachedToWindow: true
            )
        )
    }

    func testSuppressesWhenFirstResponderFallsBackAndHostedViewIsDetached() {
        XCTAssertTrue(
            shouldSuppressSplitShortcutForTransientTerminalFocusInputs(
                firstResponderIsWindow: true,
                hostedSize: CGSize(width: 1051.5, height: 1207),
                hostedHiddenInHierarchy: false,
                hostedAttachedToWindow: false
            )
        )
    }

    func testAllowsWhenFirstResponderFallsBackButGeometryIsHealthy() {
        XCTAssertFalse(
            shouldSuppressSplitShortcutForTransientTerminalFocusInputs(
                firstResponderIsWindow: true,
                hostedSize: CGSize(width: 1051.5, height: 1207),
                hostedHiddenInHierarchy: false,
                hostedAttachedToWindow: true
            )
        )
    }

    func testAllowsWhenFirstResponderIsTerminalEvenIfViewIsTiny() {
        XCTAssertFalse(
            shouldSuppressSplitShortcutForTransientTerminalFocusInputs(
                firstResponderIsWindow: false,
                hostedSize: CGSize(width: 79, height: 0),
                hostedHiddenInHierarchy: false,
                hostedAttachedToWindow: true
            )
        )
    }
}

final class CmuxWebViewKeyEquivalentTests: XCTestCase {
    private final class ActionSpy: NSObject {
        private(set) var invoked: Bool = false

        @objc func didInvoke(_ sender: Any?) {
            invoked = true
        }
    }

    private final class FirstResponderView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private final class DelegateProbeTextView: NSTextView {
        private(set) var delegateReadCount = 0

        override var delegate: NSTextViewDelegate? {
            get {
                delegateReadCount += 1
                return super.delegate
            }
            set {
                super.delegate = newValue
            }
        }
    }

    private final class FieldEditorProbeTextView: NSTextView {
        private(set) var delegateReadCount = 0

        override var delegate: NSTextViewDelegate? {
            get {
                delegateReadCount += 1
                return super.delegate
            }
            set {
                super.delegate = newValue
            }
        }

        override var isFieldEditor: Bool {
            get { true }
            set {}
        }
    }

    func testCmdNRoutesToMainMenuWhenWebViewIsFirstResponder() {
        let spy = ActionSpy()
        installMenu(spy: spy, key: "n", modifiers: [.command])

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let event = makeKeyDownEvent(key: "n", modifiers: [.command], keyCode: 45) // kVK_ANSI_N
        XCTAssertNotNil(event)

        XCTAssertTrue(webView.performKeyEquivalent(with: event!))
        XCTAssertTrue(spy.invoked)
    }

    func testCmdWRoutesToMainMenuWhenWebViewIsFirstResponder() {
        let spy = ActionSpy()
        installMenu(spy: spy, key: "w", modifiers: [.command])

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let event = makeKeyDownEvent(key: "w", modifiers: [.command], keyCode: 13) // kVK_ANSI_W
        XCTAssertNotNil(event)

        XCTAssertTrue(webView.performKeyEquivalent(with: event!))
        XCTAssertTrue(spy.invoked)
    }

    func testCmdRRoutesToMainMenuWhenWebViewIsFirstResponder() {
        let spy = ActionSpy()
        installMenu(spy: spy, key: "r", modifiers: [.command])

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let event = makeKeyDownEvent(key: "r", modifiers: [.command], keyCode: 15) // kVK_ANSI_R
        XCTAssertNotNil(event)

        XCTAssertTrue(webView.performKeyEquivalent(with: event!))
        XCTAssertTrue(spy.invoked)
    }

    func testReturnDoesNotRouteToMainMenuWhenWebViewIsFirstResponder() {
        let spy = ActionSpy()
        installMenu(spy: spy, key: "\r", modifiers: [])

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let event = makeKeyDownEvent(key: "\r", modifiers: [], keyCode: 36) // kVK_Return
        XCTAssertNotNil(event)

        XCTAssertFalse(webView.performKeyEquivalent(with: event!))
        XCTAssertFalse(spy.invoked)
    }

    func testCmdReturnDoesNotRouteToMainMenuWhenWebViewIsFirstResponder() {
        let spy = ActionSpy()
        installMenu(spy: spy, key: "\r", modifiers: [.command])

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let event = makeKeyDownEvent(key: "\r", modifiers: [.command], keyCode: 36) // kVK_Return
        XCTAssertNotNil(event)

        XCTAssertFalse(webView.performKeyEquivalent(with: event!))
        XCTAssertFalse(spy.invoked)
    }

    func testKeypadEnterDoesNotRouteToMainMenuWhenWebViewIsFirstResponder() {
        let spy = ActionSpy()
        installMenu(spy: spy, key: "\r", modifiers: [])

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let event = makeKeyDownEvent(key: "\r", modifiers: [], keyCode: 76) // kVK_ANSI_KeypadEnter
        XCTAssertNotNil(event)

        XCTAssertFalse(webView.performKeyEquivalent(with: event!))
        XCTAssertFalse(spy.invoked)
    }

    @MainActor
    func testCanBlockFirstResponderAcquisitionWhenPaneIsUnfocused() {
        _ = NSApplication.shared

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

        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        webView.allowsFirstResponderAcquisition = true
        XCTAssertTrue(window.makeFirstResponder(webView))

        _ = window.makeFirstResponder(nil)
        webView.allowsFirstResponderAcquisition = false
        XCTAssertFalse(webView.becomeFirstResponder())

        _ = window.makeFirstResponder(webView)
        if let firstResponderView = window.firstResponder as? NSView {
            XCTAssertFalse(firstResponderView === webView || firstResponderView.isDescendant(of: webView))
        }
    }

    @MainActor
    func testPointerFocusAllowanceCanTemporarilyOverrideBlockedFirstResponderAcquisition() {
        _ = NSApplication.shared

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

        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        webView.allowsFirstResponderAcquisition = false
        _ = window.makeFirstResponder(nil)
        XCTAssertFalse(webView.becomeFirstResponder(), "Expected focus to stay blocked by policy")

        webView.withPointerFocusAllowance {
            XCTAssertTrue(webView.becomeFirstResponder(), "Expected explicit pointer intent to bypass policy")
        }

        _ = window.makeFirstResponder(nil)
        XCTAssertFalse(webView.becomeFirstResponder(), "Expected pointer allowance to be temporary")
    }

    @MainActor
    func testWindowFirstResponderGuardBlocksDescendantWhenPaneIsUnfocused() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

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

        let descendant = FirstResponderView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        webView.addSubview(descendant)

        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        webView.allowsFirstResponderAcquisition = true
        XCTAssertTrue(window.makeFirstResponder(descendant))

        _ = window.makeFirstResponder(nil)
        webView.allowsFirstResponderAcquisition = false
        XCTAssertFalse(window.makeFirstResponder(descendant))

        if let firstResponderView = window.firstResponder as? NSView {
            XCTAssertFalse(firstResponderView === descendant || firstResponderView.isDescendant(of: webView))
        }
    }

    @MainActor
    func testWindowFirstResponderGuardAllowsDescendantDuringPointerFocusAllowance() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

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

        let descendant = FirstResponderView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        webView.addSubview(descendant)

        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        webView.allowsFirstResponderAcquisition = false
        _ = window.makeFirstResponder(nil)
        XCTAssertFalse(window.makeFirstResponder(descendant), "Expected blocked focus outside pointer allowance")

        _ = window.makeFirstResponder(nil)
        webView.withPointerFocusAllowance {
            XCTAssertTrue(window.makeFirstResponder(descendant), "Expected pointer allowance to bypass guard")
        }

        _ = window.makeFirstResponder(nil)
        XCTAssertFalse(window.makeFirstResponder(descendant), "Expected pointer allowance to remain temporary")
    }

    @MainActor
    func testWindowFirstResponderGuardAllowsPointerInitiatedClickFocusWhenPolicyIsBlocked() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

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

        let descendant = FirstResponderView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        webView.addSubview(descendant)

        window.makeKeyAndOrderFront(nil)
        defer {
            AppDelegate.clearWindowFirstResponderGuardTesting()
            window.orderOut(nil)
        }

        webView.allowsFirstResponderAcquisition = false
        _ = window.makeFirstResponder(nil)
        XCTAssertFalse(window.makeFirstResponder(descendant), "Expected blocked focus without pointer click context")

        let timestamp = ProcessInfo.processInfo.systemUptime
        let pointerDownEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 5, y: 5),
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        )
        XCTAssertNotNil(pointerDownEvent)

        AppDelegate.setWindowFirstResponderGuardTesting(currentEvent: pointerDownEvent, hitView: descendant)
        _ = window.makeFirstResponder(nil)
        XCTAssertTrue(window.makeFirstResponder(descendant), "Expected pointer click context to bypass blocked policy")

        AppDelegate.clearWindowFirstResponderGuardTesting()
        _ = window.makeFirstResponder(nil)
        XCTAssertFalse(window.makeFirstResponder(descendant), "Expected pointer bypass to be limited to click context")
    }

    @MainActor
    func testWindowFirstResponderGuardAvoidsTextViewDelegateLookupForWebViewResolution() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let textView = DelegateProbeTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        container.addSubview(textView)

        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        _ = window.makeFirstResponder(nil)
        _ = window.makeFirstResponder(textView)

        XCTAssertEqual(
            textView.delegateReadCount,
            0,
            "WebView ownership resolution should not touch NSTextView.delegate (unsafe-unretained in AppKit)"
        )
    }

    @MainActor
    func testWindowFirstResponderGuardResolvesTrackedWebViewForFieldEditorResponder() {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

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

        let descendant = FirstResponderView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        webView.addSubview(descendant)

        let fieldEditor = FieldEditorProbeTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))

        window.makeKeyAndOrderFront(nil)
        defer {
            AppDelegate.clearWindowFirstResponderGuardTesting()
            window.orderOut(nil)
        }

        webView.allowsFirstResponderAcquisition = true
        XCTAssertTrue(window.makeFirstResponder(descendant))

        let timestamp = ProcessInfo.processInfo.systemUptime
        let pointerDownEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 5, y: 5),
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        )
        XCTAssertNotNil(pointerDownEvent)

        AppDelegate.setWindowFirstResponderGuardTesting(currentEvent: pointerDownEvent, hitView: descendant)
        XCTAssertTrue(window.makeFirstResponder(fieldEditor))

        AppDelegate.clearWindowFirstResponderGuardTesting()
        _ = window.makeFirstResponder(nil)
        webView.allowsFirstResponderAcquisition = false
        XCTAssertFalse(window.makeFirstResponder(fieldEditor))
        XCTAssertEqual(
            fieldEditor.delegateReadCount,
            0,
            "Field-editor webview ownership should come from tracked associations, not NSTextView.delegate"
        )
    }

    private func installMenu(spy: ActionSpy, key: String, modifiers: NSEvent.ModifierFlags) {
        let mainMenu = NSMenu()

        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")

        let item = NSMenuItem(title: "Test Item", action: #selector(ActionSpy.didInvoke(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = spy
        fileMenu.addItem(item)

        mainMenu.addItem(fileItem)
        mainMenu.setSubmenu(fileMenu, for: fileItem)

        // Ensure NSApp exists and has a menu for performKeyEquivalent to consult.
        _ = NSApplication.shared
        NSApp.mainMenu = mainMenu
    }

    private func makeKeyDownEvent(key: String, modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}

@MainActor
final class AppDelegateWindowContextRoutingTests: XCTestCase {
    private func makeMainWindow(id: UUID) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(id.uuidString)")
        return window
    }

    func testSynchronizeActiveMainWindowContextPrefersProvidedWindowOverStaleActiveManager() {
        _ = NSApplication.shared
        let app = AppDelegate()

        let windowAId = UUID()
        let windowBId = UUID()
        let windowA = makeMainWindow(id: windowAId)
        let windowB = makeMainWindow(id: windowBId)
        defer {
            windowA.orderOut(nil)
            windowB.orderOut(nil)
        }

        let managerA = TabManager()
        let managerB = TabManager()
        app.registerMainWindow(
            windowA,
            windowId: windowAId,
            tabManager: managerA,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )
        app.registerMainWindow(
            windowB,
            windowId: windowBId,
            tabManager: managerB,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )

        windowB.makeKeyAndOrderFront(nil)
        _ = app.synchronizeActiveMainWindowContext(preferredWindow: windowB)
        XCTAssertTrue(app.tabManager === managerB)

        windowA.makeKeyAndOrderFront(nil)
        let resolved = app.synchronizeActiveMainWindowContext(preferredWindow: windowA)
        XCTAssertTrue(resolved === managerA, "Expected provided active window to win over stale active manager")
        XCTAssertTrue(app.tabManager === managerA)
    }

    func testSynchronizeActiveMainWindowContextFallsBackToActiveManagerWithoutFocusedWindow() {
        _ = NSApplication.shared
        let app = AppDelegate()

        let windowAId = UUID()
        let windowBId = UUID()
        let windowA = makeMainWindow(id: windowAId)
        let windowB = makeMainWindow(id: windowBId)
        defer {
            windowA.orderOut(nil)
            windowB.orderOut(nil)
        }

        let managerA = TabManager()
        let managerB = TabManager()
        app.registerMainWindow(
            windowA,
            windowId: windowAId,
            tabManager: managerA,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )
        app.registerMainWindow(
            windowB,
            windowId: windowBId,
            tabManager: managerB,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )

        // Seed active manager and clear focus windows to force fallback routing.
        windowA.makeKeyAndOrderFront(nil)
        _ = app.synchronizeActiveMainWindowContext(preferredWindow: windowA)
        XCTAssertTrue(app.tabManager === managerA)
        windowA.orderOut(nil)
        windowB.orderOut(nil)

        let resolved = app.synchronizeActiveMainWindowContext(preferredWindow: nil)
        XCTAssertTrue(resolved === managerA, "Expected fallback to preserve current active manager instead of arbitrary window")
        XCTAssertTrue(app.tabManager === managerA)
    }

    func testSynchronizeActiveMainWindowContextUsesRegisteredWindowEvenIfIdentifierMutates() {
        _ = NSApplication.shared
        let app = AppDelegate()

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        defer { window.orderOut(nil) }

        let manager = TabManager()
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )

        // SwiftUI can replace the NSWindow identifier string at runtime.
        window.identifier = NSUserInterfaceItemIdentifier("SwiftUI.AppWindow.IdentifierChanged")

        let resolved = app.synchronizeActiveMainWindowContext(preferredWindow: window)
        XCTAssertTrue(resolved === manager, "Expected registered window object identity to win even if identifier string changed")
        XCTAssertTrue(app.tabManager === manager)
    }
}

final class FocusFlashPatternTests: XCTestCase {
    func testFocusFlashPatternMatchesTerminalDoublePulseShape() {
        XCTAssertEqual(FocusFlashPattern.values, [0, 1, 0, 1, 0])
        XCTAssertEqual(FocusFlashPattern.keyTimes, [0, 0.25, 0.5, 0.75, 1])
        XCTAssertEqual(FocusFlashPattern.duration, 0.9, accuracy: 0.0001)
        XCTAssertEqual(FocusFlashPattern.curves, [.easeOut, .easeIn, .easeOut, .easeIn])
        XCTAssertEqual(FocusFlashPattern.ringInset, 6, accuracy: 0.0001)
        XCTAssertEqual(FocusFlashPattern.ringCornerRadius, 10, accuracy: 0.0001)
    }

    func testFocusFlashPatternSegmentsCoverFullDoublePulseTimeline() {
        let segments = FocusFlashPattern.segments
        XCTAssertEqual(segments.count, 4)

        XCTAssertEqual(segments[0].delay, 0.0, accuracy: 0.0001)
        XCTAssertEqual(segments[0].duration, 0.225, accuracy: 0.0001)
        XCTAssertEqual(segments[0].targetOpacity, 1, accuracy: 0.0001)
        XCTAssertEqual(segments[0].curve, .easeOut)

        XCTAssertEqual(segments[1].delay, 0.225, accuracy: 0.0001)
        XCTAssertEqual(segments[1].duration, 0.225, accuracy: 0.0001)
        XCTAssertEqual(segments[1].targetOpacity, 0, accuracy: 0.0001)
        XCTAssertEqual(segments[1].curve, .easeIn)

        XCTAssertEqual(segments[2].delay, 0.45, accuracy: 0.0001)
        XCTAssertEqual(segments[2].duration, 0.225, accuracy: 0.0001)
        XCTAssertEqual(segments[2].targetOpacity, 1, accuracy: 0.0001)
        XCTAssertEqual(segments[2].curve, .easeOut)

        XCTAssertEqual(segments[3].delay, 0.675, accuracy: 0.0001)
        XCTAssertEqual(segments[3].duration, 0.225, accuracy: 0.0001)
        XCTAssertEqual(segments[3].targetOpacity, 0, accuracy: 0.0001)
        XCTAssertEqual(segments[3].curve, .easeIn)
    }
}

@MainActor
final class CmuxWebViewContextMenuTests: XCTestCase {
    private func makeRightMouseDownEvent() -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            fatalError("Failed to create rightMouseDown event")
        }
        return event
    }

    func testWillOpenMenuAddsOpenLinkInDefaultBrowserAndRoutesSelectionToDefaultBrowserOpener() {
        _ = NSApplication.shared
        let webView = CmuxWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: WKWebViewConfiguration())
        let menu = NSMenu()
        let openLinkItem = NSMenuItem(title: "Open Link", action: nil, keyEquivalent: "")
        openLinkItem.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLink")
        menu.addItem(openLinkItem)
        menu.addItem(NSMenuItem(title: "Copy Link", action: nil, keyEquivalent: ""))

        var openedURL: URL?
        webView.contextMenuLinkURLProvider = { _, _, completion in
            completion(URL(string: "https://example.com/docs")!)
        }
        webView.contextMenuDefaultBrowserOpener = { url in
            openedURL = url
            return true
        }

        webView.willOpenMenu(menu, with: makeRightMouseDownEvent())

        guard let defaultBrowserItemIndex = menu.items.firstIndex(where: { $0.title == "Open Link in Default Browser" }) else {
            XCTFail("Expected Open Link in Default Browser item in context menu")
            return
        }
        guard let openLinkIndex = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLink" }) else {
            XCTFail("Expected Open Link item in context menu")
            return
        }

        XCTAssertEqual(defaultBrowserItemIndex, openLinkIndex + 1)
        let defaultBrowserItem = menu.items[defaultBrowserItemIndex]
        XCTAssertTrue(defaultBrowserItem.target === webView)
        XCTAssertNotNil(defaultBrowserItem.action)

        let dispatched = NSApp.sendAction(
            defaultBrowserItem.action!,
            to: defaultBrowserItem.target,
            from: defaultBrowserItem
        )
        XCTAssertTrue(dispatched)
        XCTAssertEqual(openedURL?.absoluteString, "https://example.com/docs")
    }

    func testWillOpenMenuSkipsDefaultBrowserItemWhenContextHasNoOpenLinkEntry() {
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Back", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Forward", action: nil, keyEquivalent: ""))

        webView.willOpenMenu(menu, with: makeRightMouseDownEvent())

        XCTAssertFalse(menu.items.contains { $0.title == "Open Link in Default Browser" })
    }

    func testWillOpenMenuHooksDownloadImageToDiskMenuVariant() {
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let menu = NSMenu()
        let originalTarget = NSObject()
        let originalAction = NSSelectorFromString("downloadImageToDisk:")
        let downloadItem = NSMenuItem(title: "Download Image As...", action: originalAction, keyEquivalent: "")
        downloadItem.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierDownloadImageToDisk")
        downloadItem.target = originalTarget
        menu.addItem(downloadItem)

        webView.willOpenMenu(menu, with: makeRightMouseDownEvent())

        XCTAssertTrue(downloadItem.target === webView)
        XCTAssertNotNil(downloadItem.action)
        XCTAssertNotEqual(downloadItem.action, originalAction)
    }

    func testWillOpenMenuHooksDownloadLinkedFileToDiskMenuVariant() {
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let menu = NSMenu()
        let originalTarget = NSObject()
        let originalAction = NSSelectorFromString("downloadLinkToDisk:")
        let downloadItem = NSMenuItem(title: "Download Linked File As...", action: originalAction, keyEquivalent: "")
        downloadItem.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierDownloadLinkToDisk")
        downloadItem.target = originalTarget
        menu.addItem(downloadItem)

        webView.willOpenMenu(menu, with: makeRightMouseDownEvent())

        XCTAssertTrue(downloadItem.target === webView)
        XCTAssertNotNil(downloadItem.action)
        XCTAssertNotEqual(downloadItem.action, originalAction)
    }
}

final class BrowserDevToolsButtonDebugSettingsTests: XCTestCase {
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "BrowserDevToolsButtonDebugSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    func testIconCatalogIncludesExpandedChoices() {
        XCTAssertGreaterThanOrEqual(BrowserDevToolsIconOption.allCases.count, 10)
        XCTAssertTrue(BrowserDevToolsIconOption.allCases.contains(.terminal))
        XCTAssertTrue(BrowserDevToolsIconOption.allCases.contains(.globe))
        XCTAssertTrue(BrowserDevToolsIconOption.allCases.contains(.curlyBracesSquare))
    }

    func testIconOptionFallsBackToDefaultForUnknownRawValue() {
        let defaults = makeIsolatedDefaults()
        defaults.set("this.symbol.does.not.exist", forKey: BrowserDevToolsButtonDebugSettings.iconNameKey)

        XCTAssertEqual(
            BrowserDevToolsButtonDebugSettings.iconOption(defaults: defaults),
            BrowserDevToolsButtonDebugSettings.defaultIcon
        )
    }

    func testColorOptionFallsBackToDefaultForUnknownRawValue() {
        let defaults = makeIsolatedDefaults()
        defaults.set("notAValidColor", forKey: BrowserDevToolsButtonDebugSettings.iconColorKey)

        XCTAssertEqual(
            BrowserDevToolsButtonDebugSettings.colorOption(defaults: defaults),
            BrowserDevToolsButtonDebugSettings.defaultColor
        )
    }

    func testCopyPayloadUsesPersistedValues() {
        let defaults = makeIsolatedDefaults()
        defaults.set(BrowserDevToolsIconOption.scope.rawValue, forKey: BrowserDevToolsButtonDebugSettings.iconNameKey)
        defaults.set(BrowserDevToolsIconColorOption.bonsplitActive.rawValue, forKey: BrowserDevToolsButtonDebugSettings.iconColorKey)

        let payload = BrowserDevToolsButtonDebugSettings.copyPayload(defaults: defaults)
        XCTAssertTrue(payload.contains("browserDevToolsIconName=scope"))
        XCTAssertTrue(payload.contains("browserDevToolsIconColor=bonsplitActive"))
    }
}

final class BrowserThemeSettingsTests: XCTestCase {
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "BrowserThemeSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    func testDefaultsMatchConfiguredFallbacks() {
        let defaults = makeIsolatedDefaults()
        XCTAssertEqual(
            BrowserThemeSettings.mode(defaults: defaults),
            BrowserThemeSettings.defaultMode
        )
    }

    func testModeReadsPersistedValue() {
        let defaults = makeIsolatedDefaults()
        defaults.set(BrowserThemeMode.dark.rawValue, forKey: BrowserThemeSettings.modeKey)
        XCTAssertEqual(BrowserThemeSettings.mode(defaults: defaults), .dark)

        defaults.set(BrowserThemeMode.light.rawValue, forKey: BrowserThemeSettings.modeKey)
        XCTAssertEqual(BrowserThemeSettings.mode(defaults: defaults), .light)
    }

    func testModeMigratesLegacyForcedDarkModeFlag() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: BrowserThemeSettings.legacyForcedDarkModeEnabledKey)
        XCTAssertEqual(BrowserThemeSettings.mode(defaults: defaults), .dark)
        XCTAssertEqual(defaults.string(forKey: BrowserThemeSettings.modeKey), BrowserThemeMode.dark.rawValue)

        let otherDefaults = makeIsolatedDefaults()
        otherDefaults.set(false, forKey: BrowserThemeSettings.legacyForcedDarkModeEnabledKey)
        XCTAssertEqual(BrowserThemeSettings.mode(defaults: otherDefaults), .system)
        XCTAssertEqual(otherDefaults.string(forKey: BrowserThemeSettings.modeKey), BrowserThemeMode.system.rawValue)
    }
}

final class BrowserPanelChromeBackgroundColorTests: XCTestCase {
    func testLightModeUsesThemeBackgroundColor() {
        assertResolvedColorMatchesTheme(for: .light)
    }

    func testDarkModeUsesThemeBackgroundColor() {
        assertResolvedColorMatchesTheme(for: .dark)
    }

    private func assertResolvedColorMatchesTheme(
        for colorScheme: ColorScheme,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let themeBackground = NSColor(srgbRed: 0.13, green: 0.29, blue: 0.47, alpha: 1.0)

        guard
            let actual = resolvedBrowserChromeBackgroundColor(
                for: colorScheme,
                themeBackgroundColor: themeBackground
            ).usingColorSpace(.sRGB),
            let expected = themeBackground.usingColorSpace(.sRGB)
        else {
            XCTFail("Expected sRGB-convertible colors", file: file, line: line)
            return
        }

        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 0.001, file: file, line: line)
    }
}

final class BrowserPanelOmnibarPillBackgroundColorTests: XCTestCase {
    func testLightModeSlightlyDarkensThemeBackground() {
        assertResolvedColorMatchesExpectedBlend(for: .light, darkenMix: 0.04)
    }

    func testDarkModeSlightlyDarkensThemeBackground() {
        assertResolvedColorMatchesExpectedBlend(for: .dark, darkenMix: 0.05)
    }

    private func assertResolvedColorMatchesExpectedBlend(
        for colorScheme: ColorScheme,
        darkenMix: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let themeBackground = NSColor(srgbRed: 0.94, green: 0.93, blue: 0.91, alpha: 1.0)
        let expected = themeBackground.blended(withFraction: darkenMix, of: .black) ?? themeBackground

        guard
            let actual = resolvedBrowserOmnibarPillBackgroundColor(
                for: colorScheme,
                themeBackgroundColor: themeBackground
            ).usingColorSpace(.sRGB),
            let expectedSRGB = expected.usingColorSpace(.sRGB),
            let themeSRGB = themeBackground.usingColorSpace(.sRGB)
        else {
            XCTFail("Expected sRGB-convertible colors", file: file, line: line)
            return
        }

        XCTAssertEqual(actual.redComponent, expectedSRGB.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, expectedSRGB.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, expectedSRGB.blueComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.alphaComponent, expectedSRGB.alphaComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertNotEqual(actual.redComponent, themeSRGB.redComponent, file: file, line: line)
    }
}

final class SidebarActiveForegroundColorTests: XCTestCase {
    func testLightAppearanceUsesBlackWithRequestedOpacity() {
        guard let lightAppearance = NSAppearance(named: .aqua),
              let color = sidebarActiveForegroundNSColor(
                  opacity: 0.8,
                  appAppearance: lightAppearance
              ).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(color.redComponent, 0, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 0, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 0, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 0.8, accuracy: 0.001)
    }

    func testDarkAppearanceUsesWhiteWithRequestedOpacity() {
        guard let darkAppearance = NSAppearance(named: .darkAqua),
              let color = sidebarActiveForegroundNSColor(
                  opacity: 0.65,
                  appAppearance: darkAppearance
              ).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(color.redComponent, 1, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 1, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 1, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 0.65, accuracy: 0.001)
    }
}

final class SidebarSelectedWorkspaceColorTests: XCTestCase {
    func testLightModeUsesConfiguredSelectedWorkspaceBackgroundColor() {
        guard let color = sidebarSelectedWorkspaceBackgroundNSColor(for: .light).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(color.redComponent, 0, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 136.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 1.0, accuracy: 0.001)
    }

    func testDarkModeUsesConfiguredSelectedWorkspaceBackgroundColor() {
        guard let color = sidebarSelectedWorkspaceBackgroundNSColor(for: .dark).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(color.redComponent, 0, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 145.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 1.0, accuracy: 0.001)
    }

    func testSelectedWorkspaceForegroundAlwaysUsesWhiteWithRequestedOpacity() {
        guard let color = sidebarSelectedWorkspaceForegroundNSColor(opacity: 0.65).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(color.redComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 0.65, accuracy: 0.001)
    }
}
final class BrowserDeveloperToolsShortcutDefaultsTests: XCTestCase {
    func testSafariDefaultShortcutForToggleDeveloperTools() {
        let shortcut = KeyboardShortcutSettings.Action.toggleBrowserDeveloperTools.defaultShortcut
        XCTAssertEqual(shortcut.key, "i")
        XCTAssertTrue(shortcut.command)
        XCTAssertTrue(shortcut.option)
        XCTAssertFalse(shortcut.shift)
        XCTAssertFalse(shortcut.control)
    }

    func testSafariDefaultShortcutForShowJavaScriptConsole() {
        let shortcut = KeyboardShortcutSettings.Action.showBrowserJavaScriptConsole.defaultShortcut
        XCTAssertEqual(shortcut.key, "c")
        XCTAssertTrue(shortcut.command)
        XCTAssertTrue(shortcut.option)
        XCTAssertFalse(shortcut.shift)
        XCTAssertFalse(shortcut.control)
    }
}

final class WorkspaceRenameShortcutDefaultsTests: XCTestCase {
    func testRenameTabShortcutDefaultsAndMetadata() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.renameTab.label, "Rename Tab")
        XCTAssertEqual(KeyboardShortcutSettings.Action.renameTab.defaultsKey, "shortcut.renameTab")

        let shortcut = KeyboardShortcutSettings.Action.renameTab.defaultShortcut
        XCTAssertEqual(shortcut.key, "r")
        XCTAssertTrue(shortcut.command)
        XCTAssertFalse(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertFalse(shortcut.control)
    }

    func testCloseWindowShortcutDefaultsAndMetadata() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.closeWindow.label, "Close Window")
        XCTAssertEqual(KeyboardShortcutSettings.Action.closeWindow.defaultsKey, "shortcut.closeWindow")

        let shortcut = KeyboardShortcutSettings.Action.closeWindow.defaultShortcut
        XCTAssertEqual(shortcut.key, "w")
        XCTAssertTrue(shortcut.command)
        XCTAssertFalse(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertTrue(shortcut.control)
    }

    func testRenameWorkspaceShortcutDefaultsAndMetadata() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.renameWorkspace.label, "Rename Workspace")
        XCTAssertEqual(KeyboardShortcutSettings.Action.renameWorkspace.defaultsKey, "shortcut.renameWorkspace")

        let shortcut = KeyboardShortcutSettings.Action.renameWorkspace.defaultShortcut
        XCTAssertEqual(shortcut.key, "r")
        XCTAssertTrue(shortcut.command)
        XCTAssertTrue(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertFalse(shortcut.control)
    }

    func testRenameWorkspaceShortcutConvertsToMenuShortcut() {
        let shortcut = KeyboardShortcutSettings.Action.renameWorkspace.defaultShortcut
        XCTAssertNotNil(shortcut.keyEquivalent)
        XCTAssertTrue(shortcut.eventModifiers.contains(.command))
        XCTAssertTrue(shortcut.eventModifiers.contains(.shift))
        XCTAssertFalse(shortcut.eventModifiers.contains(.option))
        XCTAssertFalse(shortcut.eventModifiers.contains(.control))
    }

    func testCloseWorkspaceShortcutDefaultsAndMetadata() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.closeWorkspace.label, "Close Workspace")
        XCTAssertEqual(KeyboardShortcutSettings.Action.closeWorkspace.defaultsKey, "shortcut.closeWorkspace")

        let shortcut = KeyboardShortcutSettings.Action.closeWorkspace.defaultShortcut
        XCTAssertEqual(shortcut.key, "w")
        XCTAssertTrue(shortcut.command)
        XCTAssertTrue(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertFalse(shortcut.control)
    }

    func testCloseWorkspaceShortcutConvertsToMenuShortcut() {
        let shortcut = KeyboardShortcutSettings.Action.closeWorkspace.defaultShortcut
        XCTAssertNotNil(shortcut.keyEquivalent)
        XCTAssertTrue(shortcut.eventModifiers.contains(.command))
        XCTAssertTrue(shortcut.eventModifiers.contains(.shift))
        XCTAssertFalse(shortcut.eventModifiers.contains(.option))
        XCTAssertFalse(shortcut.eventModifiers.contains(.control))
    }

    func testNextPreviousWorkspaceShortcutDefaultsAndMetadata() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.nextSidebarTab.label, "Next Workspace")
        XCTAssertEqual(KeyboardShortcutSettings.Action.prevSidebarTab.label, "Previous Workspace")
        XCTAssertEqual(KeyboardShortcutSettings.Action.nextSidebarTab.defaultsKey, "shortcut.nextSidebarTab")
        XCTAssertEqual(KeyboardShortcutSettings.Action.prevSidebarTab.defaultsKey, "shortcut.prevSidebarTab")

        let nextShortcut = KeyboardShortcutSettings.Action.nextSidebarTab.defaultShortcut
        XCTAssertEqual(nextShortcut.key, "]")
        XCTAssertTrue(nextShortcut.command)
        XCTAssertFalse(nextShortcut.shift)
        XCTAssertFalse(nextShortcut.option)
        XCTAssertTrue(nextShortcut.control)

        let prevShortcut = KeyboardShortcutSettings.Action.prevSidebarTab.defaultShortcut
        XCTAssertEqual(prevShortcut.key, "[")
        XCTAssertTrue(prevShortcut.command)
        XCTAssertFalse(prevShortcut.shift)
        XCTAssertFalse(prevShortcut.option)
        XCTAssertTrue(prevShortcut.control)
    }

    func testNextPreviousWorkspaceShortcutsConvertToMenuShortcut() {
        let nextShortcut = KeyboardShortcutSettings.Action.nextSidebarTab.defaultShortcut
        XCTAssertNotNil(nextShortcut.keyEquivalent)
        XCTAssertEqual(nextShortcut.menuItemKeyEquivalent, "]")
        XCTAssertTrue(nextShortcut.eventModifiers.contains(.command))
        XCTAssertTrue(nextShortcut.eventModifiers.contains(.control))

        let prevShortcut = KeyboardShortcutSettings.Action.prevSidebarTab.defaultShortcut
        XCTAssertNotNil(prevShortcut.keyEquivalent)
        XCTAssertEqual(prevShortcut.menuItemKeyEquivalent, "[")
        XCTAssertTrue(prevShortcut.eventModifiers.contains(.command))
        XCTAssertTrue(prevShortcut.eventModifiers.contains(.control))
    }

    func testMenuItemKeyEquivalentHandlesArrowAndTabKeys() {
        XCTAssertNotNil(StoredShortcut(key: "←", command: true, shift: false, option: false, control: false).menuItemKeyEquivalent)
        XCTAssertNotNil(StoredShortcut(key: "→", command: true, shift: false, option: false, control: false).menuItemKeyEquivalent)
        XCTAssertNotNil(StoredShortcut(key: "↑", command: true, shift: false, option: false, control: false).menuItemKeyEquivalent)
        XCTAssertNotNil(StoredShortcut(key: "↓", command: true, shift: false, option: false, control: false).menuItemKeyEquivalent)
        XCTAssertEqual(
            StoredShortcut(key: "\t", command: true, shift: false, option: false, control: false).menuItemKeyEquivalent,
            "\t"
        )
    }

    func testShortcutDefaultsKeysRemainUnique() {
        let keys = KeyboardShortcutSettings.Action.allCases.map(\.defaultsKey)
        XCTAssertEqual(Set(keys).count, keys.count)
    }
}

@MainActor
final class BrowserDeveloperToolsConfigurationTests: XCTestCase {
    func testBrowserPanelEnablesInspectableWebViewAndDeveloperExtras() {
        let panel = BrowserPanel(workspaceId: UUID())
        let developerExtras = panel.webView.configuration.preferences.value(forKey: "developerExtrasEnabled") as? Bool
        XCTAssertEqual(developerExtras, true)

        if #available(macOS 13.3, *) {
            XCTAssertTrue(panel.webView.isInspectable)
        }
    }

    func testBrowserPanelRefreshesUnderPageBackgroundColorWhenGhosttyBackgroundChanges() {
        let panel = BrowserPanel(workspaceId: UUID())
        let updatedColor = NSColor(srgbRed: 0.18, green: 0.29, blue: 0.44, alpha: 1.0)
        let updatedOpacity = 0.57

        NotificationCenter.default.post(
            name: .ghosttyDefaultBackgroundDidChange,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.backgroundColor: updatedColor,
                GhosttyNotificationKey.backgroundOpacity: updatedOpacity
            ]
        )

        guard let actual = panel.webView.underPageBackgroundColor?.usingColorSpace(.sRGB),
              let expected = updatedColor.withAlphaComponent(updatedOpacity).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible under-page background colors")
            return
        }

        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.005)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.005)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.005)
        XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 0.005)
    }

    func testBrowserPanelStartsAsNewTabWithoutLoadingAboutBlank() {
        let panel = BrowserPanel(workspaceId: UUID())

        XCTAssertEqual(panel.displayTitle, "New tab")
        XCTAssertFalse(panel.shouldRenderWebView)
        XCTAssertTrue(panel.isShowingNewTabPage)
        XCTAssertNil(panel.webView.url)
        XCTAssertNil(panel.currentURL)
    }

    func testBrowserPanelLeavesNewTabPageStateWhenNavigationStarts() {
        let panel = BrowserPanel(workspaceId: UUID())

        XCTAssertTrue(panel.isShowingNewTabPage)
        panel.navigate(to: URL(string: "https://example.com")!)
        XCTAssertFalse(panel.isShowingNewTabPage)
    }

    func testBrowserPanelThemeModeUpdatesWebViewAppearance() {
        let panel = BrowserPanel(workspaceId: UUID())

        panel.setBrowserThemeMode(.dark)
        XCTAssertEqual(panel.webView.appearance?.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)

        panel.setBrowserThemeMode(.light)
        XCTAssertEqual(panel.webView.appearance?.bestMatch(from: [.aqua, .darkAqua]), .aqua)

        panel.setBrowserThemeMode(.system)
        XCTAssertNil(panel.webView.appearance)
    }
}

final class BrowserNavigationNewTabDecisionTests: XCTestCase {
    func testLinkActivatedCmdClickOpensInNewTab() {
        XCTAssertTrue(
            browserNavigationShouldOpenInNewTab(
                navigationType: .linkActivated,
                modifierFlags: [.command],
                buttonNumber: 0
            )
        )
    }

    func testLinkActivatedMiddleClickOpensInNewTab() {
        XCTAssertTrue(
            browserNavigationShouldOpenInNewTab(
                navigationType: .linkActivated,
                modifierFlags: [],
                buttonNumber: 2
            )
        )
    }

    func testLinkActivatedPlainLeftClickStaysInCurrentTab() {
        XCTAssertFalse(
            browserNavigationShouldOpenInNewTab(
                navigationType: .linkActivated,
                modifierFlags: [],
                buttonNumber: 0
            )
        )
    }

    func testOtherNavigationMiddleClickOpensInNewTab() {
        XCTAssertTrue(
            browserNavigationShouldOpenInNewTab(
                navigationType: .other,
                modifierFlags: [],
                buttonNumber: 2
            )
        )
    }

    func testOtherNavigationLeftClickStaysInCurrentTab() {
        XCTAssertFalse(
            browserNavigationShouldOpenInNewTab(
                navigationType: .other,
                modifierFlags: [],
                buttonNumber: 0
            )
        )
    }

    func testLinkActivatedButtonFourWithoutMiddleIntentStaysInCurrentTab() {
        XCTAssertFalse(
            browserNavigationShouldOpenInNewTab(
                navigationType: .linkActivated,
                modifierFlags: [],
                buttonNumber: 4,
                hasRecentMiddleClickIntent: false
            )
        )
    }

    func testLinkActivatedButtonFourWithRecentMiddleIntentOpensInNewTab() {
        XCTAssertTrue(
            browserNavigationShouldOpenInNewTab(
                navigationType: .linkActivated,
                modifierFlags: [],
                buttonNumber: 4,
                hasRecentMiddleClickIntent: true
            )
        )
    }

    func testLinkActivatedUsesCurrentEventFallbackForMiddleClick() {
        XCTAssertTrue(
            browserNavigationShouldOpenInNewTab(
                navigationType: .linkActivated,
                modifierFlags: [],
                buttonNumber: 0,
                currentEventType: .otherMouseUp,
                currentEventButtonNumber: 2
            )
        )
    }

    func testCurrentEventFallbackDoesNotAffectNonLinkNavigation() {
        XCTAssertFalse(
            browserNavigationShouldOpenInNewTab(
                navigationType: .reload,
                modifierFlags: [],
                buttonNumber: 0,
                currentEventType: .otherMouseUp,
                currentEventButtonNumber: 2
            )
        )
    }

    func testNonLinkNavigationNeverForcesNewTab() {
        XCTAssertFalse(
            browserNavigationShouldOpenInNewTab(
                navigationType: .reload,
                modifierFlags: [.command],
                buttonNumber: 2
            )
        )
    }
}

@MainActor
final class BrowserJavaScriptDialogDelegateTests: XCTestCase {
    func testBrowserPanelUIDelegateImplementsJavaScriptDialogSelectors() {
        let panel = BrowserPanel(workspaceId: UUID())
        guard let uiDelegate = panel.webView.uiDelegate as? NSObject else {
            XCTFail("Expected BrowserPanel webView.uiDelegate to be an NSObject")
            return
        }

        XCTAssertTrue(
            uiDelegate.responds(
                to: #selector(
                    WKUIDelegate.webView(
                        _:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:
                    )
                )
            ),
            "Browser UI delegate must implement JavaScript alert handling"
        )
        XCTAssertTrue(
            uiDelegate.responds(
                to: #selector(
                    WKUIDelegate.webView(
                        _:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:
                    )
                )
            ),
            "Browser UI delegate must implement JavaScript confirm handling"
        )
        XCTAssertTrue(
            uiDelegate.responds(
                to: #selector(
                    WKUIDelegate.webView(
                        _:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:
                    )
                )
            ),
            "Browser UI delegate must implement JavaScript prompt handling"
        )
    }
}

@MainActor
final class BrowserSessionHistoryRestoreTests: XCTestCase {
    func testSessionNavigationHistorySnapshotUsesRestoredStacks() {
        let panel = BrowserPanel(workspaceId: UUID())

        panel.restoreSessionNavigationHistory(
            backHistoryURLStrings: [
                "https://example.com/a",
                "https://example.com/b"
            ],
            forwardHistoryURLStrings: [
                "https://example.com/d"
            ],
            currentURLString: "https://example.com/c"
        )

        XCTAssertTrue(panel.canGoBack)
        XCTAssertTrue(panel.canGoForward)

        let snapshot = panel.sessionNavigationHistorySnapshot()
        XCTAssertEqual(
            snapshot.backHistoryURLStrings,
            ["https://example.com/a", "https://example.com/b"]
        )
        XCTAssertEqual(
            snapshot.forwardHistoryURLStrings,
            ["https://example.com/d"]
        )
    }

    func testSessionNavigationHistoryBackAndForwardUpdateStacks() {
        let panel = BrowserPanel(workspaceId: UUID())

        panel.restoreSessionNavigationHistory(
            backHistoryURLStrings: [
                "https://example.com/a",
                "https://example.com/b"
            ],
            forwardHistoryURLStrings: [
                "https://example.com/d"
            ],
            currentURLString: "https://example.com/c"
        )

        panel.goBack()
        let afterBack = panel.sessionNavigationHistorySnapshot()
        XCTAssertEqual(afterBack.backHistoryURLStrings, ["https://example.com/a"])
        XCTAssertEqual(
            afterBack.forwardHistoryURLStrings,
            ["https://example.com/c", "https://example.com/d"]
        )
        XCTAssertTrue(panel.canGoBack)
        XCTAssertTrue(panel.canGoForward)

        panel.goForward()
        let afterForward = panel.sessionNavigationHistorySnapshot()
        XCTAssertEqual(
            afterForward.backHistoryURLStrings,
            ["https://example.com/a", "https://example.com/b"]
        )
        XCTAssertEqual(afterForward.forwardHistoryURLStrings, ["https://example.com/d"])
        XCTAssertTrue(panel.canGoBack)
        XCTAssertTrue(panel.canGoForward)
    }
}

@MainActor
final class BrowserDeveloperToolsVisibilityPersistenceTests: XCTestCase {
    private final class FakeInspector: NSObject {
        private(set) var showCount = 0
        private(set) var closeCount = 0
        private var visible = false

        @objc func isVisible() -> Bool {
            visible
        }

        @objc func show() {
            showCount += 1
            visible = true
        }

        @objc func close() {
            closeCount += 1
            visible = false
        }
    }

    override class func setUp() {
        super.setUp()
        installCmuxUnitTestInspectorOverride()
    }

    private func makePanelWithInspector() -> (BrowserPanel, FakeInspector) {
        let panel = BrowserPanel(workspaceId: UUID())
        let inspector = FakeInspector()
        panel.webView.cmuxSetUnitTestInspector(inspector)
        return (panel, inspector)
    }

    func testRestoreReopensInspectorAfterAttachWhenPreferredVisible() {
        let (panel, inspector) = makePanelWithInspector()

        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertTrue(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.showCount, 1)

        // Simulate WebKit closing inspector during detach/reattach churn.
        inspector.close()
        XCTAssertFalse(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.closeCount, 1)

        panel.restoreDeveloperToolsAfterAttachIfNeeded()
        XCTAssertTrue(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.showCount, 2)
    }

    func testSyncRespectsManualCloseAndPreventsUnexpectedRestore() {
        let (panel, inspector) = makePanelWithInspector()

        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertEqual(inspector.showCount, 1)

        // Simulate user closing inspector before detach.
        inspector.close()
        panel.syncDeveloperToolsPreferenceFromInspector()

        panel.restoreDeveloperToolsAfterAttachIfNeeded()
        XCTAssertFalse(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.showCount, 1)
    }

    func testSyncCanPreserveVisibleIntentDuringDetachChurn() {
        let (panel, inspector) = makePanelWithInspector()

        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertEqual(inspector.showCount, 1)

        // Simulate a transient close caused by view detach, not user intent.
        inspector.close()
        panel.syncDeveloperToolsPreferenceFromInspector(preserveVisibleIntent: true)
        panel.restoreDeveloperToolsAfterAttachIfNeeded()

        XCTAssertTrue(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.showCount, 2)
    }

    func testForcedRefreshAfterAttachKeepsVisibleInspectorState() {
        let (panel, inspector) = makePanelWithInspector()

        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertTrue(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.showCount, 1)
        XCTAssertEqual(inspector.closeCount, 0)

        panel.requestDeveloperToolsRefreshAfterNextAttach(reason: "unit-test")
        panel.restoreDeveloperToolsAfterAttachIfNeeded()

        XCTAssertTrue(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.closeCount, 0)
        XCTAssertEqual(inspector.showCount, 1)

        // The force-refresh request should be one-shot.
        panel.restoreDeveloperToolsAfterAttachIfNeeded()
        XCTAssertEqual(inspector.closeCount, 0)
        XCTAssertEqual(inspector.showCount, 1)
    }

    func testRefreshRequestTracksPendingStateUntilRestoreRuns() {
        let (panel, _) = makePanelWithInspector()

        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertFalse(panel.hasPendingDeveloperToolsRefreshAfterAttach())

        panel.requestDeveloperToolsRefreshAfterNextAttach(reason: "unit-test")
        XCTAssertTrue(panel.hasPendingDeveloperToolsRefreshAfterAttach())

        panel.restoreDeveloperToolsAfterAttachIfNeeded()
        XCTAssertFalse(panel.hasPendingDeveloperToolsRefreshAfterAttach())
    }

    func testTransientHideAttachmentPreserveFollowsDeveloperToolsIntent() {
        let (panel, _) = makePanelWithInspector()

        XCTAssertFalse(panel.shouldPreserveWebViewAttachmentDuringTransientHide())
        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertTrue(panel.shouldPreserveWebViewAttachmentDuringTransientHide())
        XCTAssertTrue(panel.hideDeveloperTools())
        XCTAssertFalse(panel.shouldPreserveWebViewAttachmentDuringTransientHide())
    }

    func testWebViewDismantleSkipsDetachWhenDeveloperToolsIntentIsVisible() {
        let (panel, _) = makePanelWithInspector()
        XCTAssertTrue(panel.showDeveloperTools())

        let representable = WebViewRepresentable(
            panel: panel,
            shouldAttachWebView: true,
            shouldFocusWebView: false,
            isPanelFocused: true,
            portalZPriority: 0
        )
        let coordinator = representable.makeCoordinator()
        coordinator.webView = panel.webView
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        host.addSubview(panel.webView)

        WebViewRepresentable.dismantleNSView(host, coordinator: coordinator)

        XCTAssertTrue(panel.webView.superview === host)
    }

    func testWebViewDismantleDetachesWhenDeveloperToolsIntentIsHidden() {
        let (panel, _) = makePanelWithInspector()
        XCTAssertFalse(panel.shouldPreserveWebViewAttachmentDuringTransientHide())

        let representable = WebViewRepresentable(
            panel: panel,
            shouldAttachWebView: true,
            shouldFocusWebView: false,
            isPanelFocused: true,
            portalZPriority: 0
        )
        let coordinator = representable.makeCoordinator()
        coordinator.webView = panel.webView
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        host.addSubview(panel.webView)

        WebViewRepresentable.dismantleNSView(host, coordinator: coordinator)

        XCTAssertNil(panel.webView.superview)
    }
}

final class WorkspaceShortcutMapperTests: XCTestCase {
    func testCommandNineMapsToLastWorkspaceIndex() {
        XCTAssertEqual(WorkspaceShortcutMapper.workspaceIndex(forCommandDigit: 9, workspaceCount: 1), 0)
        XCTAssertEqual(WorkspaceShortcutMapper.workspaceIndex(forCommandDigit: 9, workspaceCount: 4), 3)
        XCTAssertEqual(WorkspaceShortcutMapper.workspaceIndex(forCommandDigit: 9, workspaceCount: 12), 11)
    }

    func testCommandDigitBadgesUseNineForLastWorkspaceWhenNeeded() {
        XCTAssertEqual(WorkspaceShortcutMapper.commandDigitForWorkspace(at: 0, workspaceCount: 12), 1)
        XCTAssertEqual(WorkspaceShortcutMapper.commandDigitForWorkspace(at: 7, workspaceCount: 12), 8)
        XCTAssertEqual(WorkspaceShortcutMapper.commandDigitForWorkspace(at: 11, workspaceCount: 12), 9)
        XCTAssertNil(WorkspaceShortcutMapper.commandDigitForWorkspace(at: 8, workspaceCount: 12))
    }
}

final class BrowserOmnibarCommandNavigationTests: XCTestCase {
    func testArrowNavigationDeltaRequiresFocusedAddressBarAndNoModifierFlags() {
        XCTAssertNil(
            browserOmnibarSelectionDeltaForArrowNavigation(
                hasFocusedAddressBar: false,
                flags: [],
                keyCode: 126
            )
        )
        XCTAssertNil(
            browserOmnibarSelectionDeltaForArrowNavigation(
                hasFocusedAddressBar: true,
                flags: [.command],
                keyCode: 126
            )
        )
        XCTAssertEqual(
            browserOmnibarSelectionDeltaForArrowNavigation(
                hasFocusedAddressBar: true,
                flags: [],
                keyCode: 126
            ),
            -1
        )
        XCTAssertEqual(
            browserOmnibarSelectionDeltaForArrowNavigation(
                hasFocusedAddressBar: true,
                flags: [],
                keyCode: 125
            ),
            1
        )
    }

    func testArrowNavigationDeltaIgnoresCapsLockModifier() {
        XCTAssertEqual(
            browserOmnibarSelectionDeltaForArrowNavigation(
                hasFocusedAddressBar: true,
                flags: [.capsLock],
                keyCode: 126
            ),
            -1
        )
        XCTAssertEqual(
            browserOmnibarSelectionDeltaForArrowNavigation(
                hasFocusedAddressBar: true,
                flags: [.capsLock],
                keyCode: 125
            ),
            1
        )
    }

    func testCommandNavigationDeltaRequiresFocusedAddressBarAndCommandOrControlOnly() {
        XCTAssertNil(
            browserOmnibarSelectionDeltaForCommandNavigation(
                hasFocusedAddressBar: false,
                flags: [.command],
                chars: "n"
            )
        )

        XCTAssertEqual(
            browserOmnibarSelectionDeltaForCommandNavigation(
                hasFocusedAddressBar: true,
                flags: [.command],
                chars: "n"
            ),
            1
        )

        XCTAssertEqual(
            browserOmnibarSelectionDeltaForCommandNavigation(
                hasFocusedAddressBar: true,
                flags: [.command],
                chars: "p"
            ),
            -1
        )

        XCTAssertNil(
            browserOmnibarSelectionDeltaForCommandNavigation(
                hasFocusedAddressBar: true,
                flags: [.command, .shift],
                chars: "n"
            )
        )

        XCTAssertEqual(
            browserOmnibarSelectionDeltaForCommandNavigation(
                hasFocusedAddressBar: true,
                flags: [.control],
                chars: "p"
            ),
            -1
        )

        XCTAssertEqual(
            browserOmnibarSelectionDeltaForCommandNavigation(
                hasFocusedAddressBar: true,
                flags: [.control],
                chars: "n"
            ),
            1
        )
    }

    func testCommandNavigationDeltaIgnoresCapsLockModifier() {
        XCTAssertEqual(
            browserOmnibarSelectionDeltaForCommandNavigation(
                hasFocusedAddressBar: true,
                flags: [.control, .capsLock],
                chars: "n"
            ),
            1
        )
        XCTAssertEqual(
            browserOmnibarSelectionDeltaForCommandNavigation(
                hasFocusedAddressBar: true,
                flags: [.command, .capsLock],
                chars: "p"
            ),
            -1
        )
    }

    func testSubmitOnReturnIgnoresCapsLockModifier() {
        XCTAssertTrue(browserOmnibarShouldSubmitOnReturn(flags: []))
        XCTAssertTrue(browserOmnibarShouldSubmitOnReturn(flags: [.shift]))
        XCTAssertTrue(browserOmnibarShouldSubmitOnReturn(flags: [.capsLock]))
        XCTAssertTrue(browserOmnibarShouldSubmitOnReturn(flags: [.shift, .capsLock]))
        XCTAssertFalse(browserOmnibarShouldSubmitOnReturn(flags: [.command, .capsLock]))
    }
}

final class BrowserReturnKeyDownRoutingTests: XCTestCase {
    func testRoutesForReturnWhenBrowserFirstResponder() {
        XCTAssertTrue(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 36,
                firstResponderIsBrowser: true
            )
        )
    }

    func testRoutesForKeypadEnterWhenBrowserFirstResponder() {
        XCTAssertTrue(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 76,
                firstResponderIsBrowser: true
            )
        )
    }

    func testDoesNotRouteForNonEnterKey() {
        XCTAssertFalse(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 13,
                firstResponderIsBrowser: true
            )
        )
    }

    func testDoesNotRouteWhenFirstResponderIsNotBrowser() {
        XCTAssertFalse(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 36,
                firstResponderIsBrowser: false
            )
        )
    }
}

final class BrowserZoomShortcutActionTests: XCTestCase {
    func testZoomInSupportsEqualsAndPlusVariants() {
        XCTAssertEqual(
            browserZoomShortcutAction(flags: [.command], chars: "=", keyCode: 24),
            .zoomIn
        )
        XCTAssertEqual(
            browserZoomShortcutAction(flags: [.command], chars: "+", keyCode: 24),
            .zoomIn
        )
        XCTAssertEqual(
            browserZoomShortcutAction(flags: [.command, .shift], chars: "+", keyCode: 24),
            .zoomIn
        )
        XCTAssertEqual(
            browserZoomShortcutAction(flags: [.command], chars: "+", keyCode: 30),
            .zoomIn
        )
    }

    func testZoomOutSupportsMinusAndUnderscoreVariants() {
        XCTAssertEqual(
            browserZoomShortcutAction(flags: [.command], chars: "-", keyCode: 27),
            .zoomOut
        )
        XCTAssertEqual(
            browserZoomShortcutAction(flags: [.command, .shift], chars: "_", keyCode: 27),
            .zoomOut
        )
    }

    func testZoomRequiresCommandWithoutOptionOrControl() {
        XCTAssertNil(browserZoomShortcutAction(flags: [], chars: "=", keyCode: 24))
        XCTAssertNil(browserZoomShortcutAction(flags: [.command, .option], chars: "=", keyCode: 24))
        XCTAssertNil(browserZoomShortcutAction(flags: [.command, .control], chars: "-", keyCode: 27))
    }

    func testResetSupportsCommandZero() {
        XCTAssertEqual(
            browserZoomShortcutAction(flags: [.command], chars: "0", keyCode: 29),
            .reset
        )
    }
}

final class BrowserZoomShortcutRoutingPolicyTests: XCTestCase {
    func testRoutesWhenGhosttyIsFirstResponderAndShortcutIsZoom() {
        XCTAssertTrue(
            shouldRouteTerminalFontZoomShortcutToGhostty(
                firstResponderIsGhostty: true,
                flags: [.command],
                chars: "=",
                keyCode: 24
            )
        )
        XCTAssertTrue(
            shouldRouteTerminalFontZoomShortcutToGhostty(
                firstResponderIsGhostty: true,
                flags: [.command],
                chars: "-",
                keyCode: 27
            )
        )
        XCTAssertTrue(
            shouldRouteTerminalFontZoomShortcutToGhostty(
                firstResponderIsGhostty: true,
                flags: [.command],
                chars: "0",
                keyCode: 29
            )
        )
    }

    func testDoesNotRouteWhenFirstResponderIsNotGhostty() {
        XCTAssertFalse(
            shouldRouteTerminalFontZoomShortcutToGhostty(
                firstResponderIsGhostty: false,
                flags: [.command],
                chars: "=",
                keyCode: 24
            )
        )
    }

    func testDoesNotRouteForNonZoomShortcuts() {
        XCTAssertFalse(
            shouldRouteTerminalFontZoomShortcutToGhostty(
                firstResponderIsGhostty: true,
                flags: [.command],
                chars: "n",
                keyCode: 45
            )
        )
    }
}

final class GhosttyResponderResolutionTests: XCTestCase {
    private final class FocusProbeView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    func testResolvesGhosttyViewFromDescendantResponder() {
        let ghosttyView = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let descendant = FocusProbeView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        ghosttyView.addSubview(descendant)

        XCTAssertTrue(cmuxOwningGhosttyView(for: descendant) === ghosttyView)
    }

    func testResolvesGhosttyViewFromGhosttyResponder() {
        let ghosttyView = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        XCTAssertTrue(cmuxOwningGhosttyView(for: ghosttyView) === ghosttyView)
    }

    func testReturnsNilForUnrelatedResponder() {
        let view = FocusProbeView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        XCTAssertNil(cmuxOwningGhosttyView(for: view))
    }
}

final class CommandPaletteKeyboardNavigationTests: XCTestCase {
    func testArrowKeysMoveSelectionWithoutModifiers() {
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [],
                chars: "",
                keyCode: 125
            ),
            1
        )
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [],
                chars: "",
                keyCode: 126
            ),
            -1
        )
        XCTAssertNil(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.shift],
                chars: "",
                keyCode: 125
            )
        )
    }

    func testControlLetterNavigationSupportsPrintableAndControlChars() {
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "n",
                keyCode: 45
            ),
            1
        )
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "\u{0e}",
                keyCode: 45
            ),
            1
        )
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "p",
                keyCode: 35
            ),
            -1
        )
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "\u{10}",
                keyCode: 35
            ),
            -1
        )
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "j",
                keyCode: 38
            ),
            1
        )
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "\u{0a}",
                keyCode: 38
            ),
            1
        )
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "k",
                keyCode: 40
            ),
            -1
        )
        XCTAssertEqual(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "\u{0b}",
                keyCode: 40
            ),
            -1
        )
    }

    func testIgnoresUnsupportedModifiersAndKeys() {
        XCTAssertNil(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.command],
                chars: "n",
                keyCode: 45
            )
        )
        XCTAssertNil(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control, .shift],
                chars: "n",
                keyCode: 45
            )
        )
        XCTAssertNil(
            commandPaletteSelectionDeltaForKeyboardNavigation(
                flags: [.control],
                chars: "x",
                keyCode: 7
            )
        )
    }
}

final class CommandPaletteOpenShortcutConsumptionTests: XCTestCase {
    func testDoesNotConsumeWhenPaletteIsNotVisible() {
        XCTAssertFalse(
            shouldConsumeShortcutWhileCommandPaletteVisible(
                isCommandPaletteVisible: false,
                normalizedFlags: [.command],
                chars: "n",
                keyCode: 45
            )
        )
    }

    func testConsumesAppCommandShortcutsWhenPaletteIsVisible() {
        XCTAssertTrue(
            shouldConsumeShortcutWhileCommandPaletteVisible(
                isCommandPaletteVisible: true,
                normalizedFlags: [.command],
                chars: "n",
                keyCode: 45
            )
        )
        XCTAssertTrue(
            shouldConsumeShortcutWhileCommandPaletteVisible(
                isCommandPaletteVisible: true,
                normalizedFlags: [.command],
                chars: "t",
                keyCode: 17
            )
        )
        XCTAssertTrue(
            shouldConsumeShortcutWhileCommandPaletteVisible(
                isCommandPaletteVisible: true,
                normalizedFlags: [.command, .shift],
                chars: ",",
                keyCode: 43
            )
        )
    }

    func testAllowsClipboardAndUndoShortcutsForPaletteTextEditing() {
        XCTAssertFalse(
            shouldConsumeShortcutWhileCommandPaletteVisible(
                isCommandPaletteVisible: true,
                normalizedFlags: [.command],
                chars: "v",
                keyCode: 9
            )
        )
        XCTAssertFalse(
            shouldConsumeShortcutWhileCommandPaletteVisible(
                isCommandPaletteVisible: true,
                normalizedFlags: [.command],
                chars: "z",
                keyCode: 6
            )
        )
        XCTAssertFalse(
            shouldConsumeShortcutWhileCommandPaletteVisible(
                isCommandPaletteVisible: true,
                normalizedFlags: [.command, .shift],
                chars: "z",
                keyCode: 6
            )
        )
    }

    func testAllowsArrowAndDeleteEditingCommandsForPaletteTextEditing() {
        XCTAssertFalse(
            shouldConsumeShortcutWhileCommandPaletteVisible(
                isCommandPaletteVisible: true,
                normalizedFlags: [.command],
                chars: "",
                keyCode: 123
            )
        )
        XCTAssertFalse(
            shouldConsumeShortcutWhileCommandPaletteVisible(
                isCommandPaletteVisible: true,
                normalizedFlags: [.command],
                chars: "",
                keyCode: 51
            )
        )
    }
}

final class CommandPaletteRestoreFocusStateMachineTests: XCTestCase {
    func testRestoresBrowserAddressBarWhenPaletteOpenedFromFocusedAddressBar() {
        let panelId = UUID()
        XCTAssertTrue(
            ContentView.shouldRestoreBrowserAddressBarAfterCommandPaletteDismiss(
                focusedPanelIsBrowser: true,
                focusedBrowserAddressBarPanelId: panelId,
                focusedPanelId: panelId
            )
        )
    }

    func testDoesNotRestoreBrowserAddressBarWhenFocusedPanelIsNotBrowser() {
        let panelId = UUID()
        XCTAssertFalse(
            ContentView.shouldRestoreBrowserAddressBarAfterCommandPaletteDismiss(
                focusedPanelIsBrowser: false,
                focusedBrowserAddressBarPanelId: panelId,
                focusedPanelId: panelId
            )
        )
    }

    func testDoesNotRestoreBrowserAddressBarWhenAnotherPanelHadAddressBarFocus() {
        XCTAssertFalse(
            ContentView.shouldRestoreBrowserAddressBarAfterCommandPaletteDismiss(
                focusedPanelIsBrowser: true,
                focusedBrowserAddressBarPanelId: UUID(),
                focusedPanelId: UUID()
            )
        )
    }
}

final class CommandPaletteRenameSelectionSettingsTests: XCTestCase {
    private let suiteName = "cmux.tests.commandPaletteRenameSelection.\(UUID().uuidString)"

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testDefaultsToSelectAllWhenUnset() {
        let defaults = makeDefaults()
        XCTAssertTrue(CommandPaletteRenameSelectionSettings.selectAllOnFocusEnabled(defaults: defaults))
    }

    func testReturnsFalseWhenStoredFalse() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: CommandPaletteRenameSelectionSettings.selectAllOnFocusKey)
        XCTAssertFalse(CommandPaletteRenameSelectionSettings.selectAllOnFocusEnabled(defaults: defaults))
    }

    func testReturnsTrueWhenStoredTrue() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: CommandPaletteRenameSelectionSettings.selectAllOnFocusKey)
        XCTAssertTrue(CommandPaletteRenameSelectionSettings.selectAllOnFocusEnabled(defaults: defaults))
    }
}

final class CommandPaletteSelectionScrollBehaviorTests: XCTestCase {
    func testFirstEntryPinsToTopAnchor() {
        let anchor = ContentView.commandPaletteScrollPositionAnchor(
            selectedIndex: 0,
            resultCount: 20
        )
        XCTAssertEqual(anchor, UnitPoint.top)
    }

    func testLastEntryPinsToBottomAnchor() {
        let anchor = ContentView.commandPaletteScrollPositionAnchor(
            selectedIndex: 19,
            resultCount: 20
        )
        XCTAssertEqual(anchor, UnitPoint.bottom)
    }

    func testMiddleEntryUsesNilAnchorForMinimalScroll() {
        let anchor = ContentView.commandPaletteScrollPositionAnchor(
            selectedIndex: 6,
            resultCount: 20
        )
        XCTAssertNil(anchor)
    }

    func testEmptyResultsProduceNoAnchor() {
        let anchor = ContentView.commandPaletteScrollPositionAnchor(
            selectedIndex: 0,
            resultCount: 0
        )
        XCTAssertNil(anchor)
    }
}

final class SidebarCommandHintPolicyTests: XCTestCase {
    func testCommandHintRequiresCommandOnlyModifier() {
        XCTAssertTrue(SidebarCommandHintPolicy.shouldShowHints(for: [.command]))
        XCTAssertFalse(SidebarCommandHintPolicy.shouldShowHints(for: []))
        XCTAssertFalse(SidebarCommandHintPolicy.shouldShowHints(for: [.command, .shift]))
        XCTAssertFalse(SidebarCommandHintPolicy.shouldShowHints(for: [.command, .option]))
        XCTAssertFalse(SidebarCommandHintPolicy.shouldShowHints(for: [.command, .control]))
    }

    func testCommandHintUsesIntentionalHoldDelay() {
        XCTAssertGreaterThanOrEqual(SidebarCommandHintPolicy.intentionalHoldDelay, 0.25)
    }

    func testCurrentWindowRequiresHostWindowToBeKeyAndMatchEventWindow() {
        XCTAssertTrue(
            SidebarCommandHintPolicy.isCurrentWindow(
                hostWindowNumber: 42,
                hostWindowIsKey: true,
                eventWindowNumber: 42,
                keyWindowNumber: 42
            )
        )

        XCTAssertFalse(
            SidebarCommandHintPolicy.isCurrentWindow(
                hostWindowNumber: 42,
                hostWindowIsKey: true,
                eventWindowNumber: 7,
                keyWindowNumber: 42
            )
        )

        XCTAssertFalse(
            SidebarCommandHintPolicy.isCurrentWindow(
                hostWindowNumber: 42,
                hostWindowIsKey: false,
                eventWindowNumber: 42,
                keyWindowNumber: 42
            )
        )
    }

    func testWindowScopedCommandHintsUseKeyWindowWhenNoEventWindowIsAvailable() {
        XCTAssertTrue(
            SidebarCommandHintPolicy.shouldShowHints(
                for: [.command],
                hostWindowNumber: 42,
                hostWindowIsKey: true,
                eventWindowNumber: nil,
                keyWindowNumber: 42
            )
        )

        XCTAssertFalse(
            SidebarCommandHintPolicy.shouldShowHints(
                for: [.command],
                hostWindowNumber: 42,
                hostWindowIsKey: true,
                eventWindowNumber: nil,
                keyWindowNumber: 7
            )
        )
    }
}

final class ShortcutHintDebugSettingsTests: XCTestCase {
    func testClampKeepsValuesWithinSupportedRange() {
        XCTAssertEqual(ShortcutHintDebugSettings.clamped(0.0), 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.clamped(4.0), 4.0)
        XCTAssertEqual(ShortcutHintDebugSettings.clamped(-100.0), ShortcutHintDebugSettings.offsetRange.lowerBound)
        XCTAssertEqual(ShortcutHintDebugSettings.clamped(100.0), ShortcutHintDebugSettings.offsetRange.upperBound)
    }

    func testDefaultOffsetsMatchCurrentBadgePlacements() {
        XCTAssertEqual(ShortcutHintDebugSettings.defaultSidebarHintX, 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultSidebarHintY, 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultTitlebarHintX, 4.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultTitlebarHintY, 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultPaneHintX, 0.0)
        XCTAssertEqual(ShortcutHintDebugSettings.defaultPaneHintY, 0.0)
        XCTAssertFalse(ShortcutHintDebugSettings.defaultAlwaysShowHints)
    }
}

final class ShortcutHintLanePlannerTests: XCTestCase {
    func testAssignLanesKeepsSeparatedIntervalsOnSingleLane() {
        let intervals: [ClosedRange<CGFloat>] = [0...20, 28...40, 48...64]
        XCTAssertEqual(ShortcutHintLanePlanner.assignLanes(for: intervals, minSpacing: 4), [0, 0, 0])
    }

    func testAssignLanesStacksOverlappingIntervalsIntoAdditionalLanes() {
        let intervals: [ClosedRange<CGFloat>] = [0...20, 18...34, 22...38, 40...56]
        XCTAssertEqual(ShortcutHintLanePlanner.assignLanes(for: intervals, minSpacing: 4), [0, 1, 2, 0])
    }
}

final class ShortcutHintHorizontalPlannerTests: XCTestCase {
    func testAssignRightEdgesResolvesOverlapWithMinimumSpacing() {
        let intervals: [ClosedRange<CGFloat>] = [0...20, 18...34, 30...46]
        let rightEdges = ShortcutHintHorizontalPlanner.assignRightEdges(for: intervals, minSpacing: 6)

        XCTAssertEqual(rightEdges.count, intervals.count)

        let adjustedIntervals = zip(intervals, rightEdges).map { interval, rightEdge in
            let width = interval.upperBound - interval.lowerBound
            return (rightEdge - width)...rightEdge
        }

        XCTAssertGreaterThanOrEqual(adjustedIntervals[1].lowerBound - adjustedIntervals[0].upperBound, 6)
        XCTAssertGreaterThanOrEqual(adjustedIntervals[2].lowerBound - adjustedIntervals[1].upperBound, 6)
    }

    func testAssignRightEdgesKeepsAlreadySeparatedIntervalsInPlace() {
        let intervals: [ClosedRange<CGFloat>] = [0...12, 20...32, 40...52]
        let rightEdges = ShortcutHintHorizontalPlanner.assignRightEdges(for: intervals, minSpacing: 4)
        XCTAssertEqual(rightEdges, [12, 32, 52])
    }
}

final class WorkspacePlacementSettingsTests: XCTestCase {
    func testCurrentPlacementDefaultsToAfterCurrentWhenUnset() {
        let suiteName = "WorkspacePlacementSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(WorkspacePlacementSettings.current(defaults: defaults), .afterCurrent)
    }

    func testCurrentPlacementReadsStoredValidValueAndFallsBackForInvalid() {
        let suiteName = "WorkspacePlacementSettingsTests.Stored.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(NewWorkspacePlacement.top.rawValue, forKey: WorkspacePlacementSettings.placementKey)
        XCTAssertEqual(WorkspacePlacementSettings.current(defaults: defaults), .top)

        defaults.set("nope", forKey: WorkspacePlacementSettings.placementKey)
        XCTAssertEqual(WorkspacePlacementSettings.current(defaults: defaults), .afterCurrent)
    }

    func testInsertionIndexTopInsertsBeforeUnpinned() {
        let index = WorkspacePlacementSettings.insertionIndex(
            placement: .top,
            selectedIndex: 4,
            selectedIsPinned: false,
            pinnedCount: 2,
            totalCount: 7
        )
        XCTAssertEqual(index, 2)
    }

    func testInsertionIndexAfterCurrentHandlesPinnedAndUnpinnedSelection() {
        let afterUnpinned = WorkspacePlacementSettings.insertionIndex(
            placement: .afterCurrent,
            selectedIndex: 3,
            selectedIsPinned: false,
            pinnedCount: 2,
            totalCount: 6
        )
        XCTAssertEqual(afterUnpinned, 4)

        let afterPinned = WorkspacePlacementSettings.insertionIndex(
            placement: .afterCurrent,
            selectedIndex: 0,
            selectedIsPinned: true,
            pinnedCount: 2,
            totalCount: 6
        )
        XCTAssertEqual(afterPinned, 2)
    }

    func testInsertionIndexEndAndNoSelectionAppend() {
        let endIndex = WorkspacePlacementSettings.insertionIndex(
            placement: .end,
            selectedIndex: 1,
            selectedIsPinned: false,
            pinnedCount: 1,
            totalCount: 5
        )
        XCTAssertEqual(endIndex, 5)

        let noSelectionIndex = WorkspacePlacementSettings.insertionIndex(
            placement: .afterCurrent,
            selectedIndex: nil,
            selectedIsPinned: false,
            pinnedCount: 0,
            totalCount: 5
        )
        XCTAssertEqual(noSelectionIndex, 5)
    }
}

@MainActor
final class WorkspaceCreationPlacementTests: XCTestCase {
    func testAddWorkspaceDefaultPlacementMatchesCurrentSetting() {
        let currentPlacement = WorkspacePlacementSettings.current()

        let defaultManager = makeManagerWithThreeWorkspaces()
        let defaultBaselineOrder = defaultManager.tabs.map(\.id)
        let defaultInserted = defaultManager.addWorkspace()
        guard let defaultInsertedIndex = defaultManager.tabs.firstIndex(where: { $0.id == defaultInserted.id }) else {
            XCTFail("Expected inserted workspace in tab list")
            return
        }
        XCTAssertEqual(defaultManager.tabs.map(\.id).filter { $0 != defaultInserted.id }, defaultBaselineOrder)

        let explicitManager = makeManagerWithThreeWorkspaces()
        let explicitBaselineOrder = explicitManager.tabs.map(\.id)
        let explicitInserted = explicitManager.addWorkspace(placementOverride: currentPlacement)
        guard let explicitInsertedIndex = explicitManager.tabs.firstIndex(where: { $0.id == explicitInserted.id }) else {
            XCTFail("Expected inserted workspace in tab list")
            return
        }
        XCTAssertEqual(explicitManager.tabs.map(\.id).filter { $0 != explicitInserted.id }, explicitBaselineOrder)
        XCTAssertEqual(defaultInsertedIndex, explicitInsertedIndex)
    }

    func testAddWorkspaceEndOverrideAlwaysAppends() {
        let manager = makeManagerWithThreeWorkspaces()
        let baselineCount = manager.tabs.count
        guard baselineCount >= 3 else {
            XCTFail("Expected at least three workspaces for placement regression test")
            return
        }

        let inserted = manager.addWorkspace(placementOverride: .end)
        guard let insertedIndex = manager.tabs.firstIndex(where: { $0.id == inserted.id }) else {
            XCTFail("Expected inserted workspace in tab list")
            return
        }

        XCTAssertEqual(insertedIndex, baselineCount)
    }

    private func makeManagerWithThreeWorkspaces() -> TabManager {
        let manager = TabManager()
        _ = manager.addWorkspace()
        _ = manager.addWorkspace()
        if let first = manager.tabs.first {
            manager.selectWorkspace(first)
        }
        return manager
    }
}

final class WorkspaceTabColorSettingsTests: XCTestCase {
    func testNormalizedHexAcceptsAndNormalizesValidInput() {
        XCTAssertEqual(WorkspaceTabColorSettings.normalizedHex("#abc123"), "#ABC123")
        XCTAssertEqual(WorkspaceTabColorSettings.normalizedHex("  aBcDeF "), "#ABCDEF")
        XCTAssertNil(WorkspaceTabColorSettings.normalizedHex("#1234"))
        XCTAssertNil(WorkspaceTabColorSettings.normalizedHex("#GG1234"))
    }

    func testBuiltInPaletteMatchesOriginalPRPalette() {
        let suiteName = "WorkspaceTabColorSettingsTests.BuiltInPalette.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let palette = WorkspaceTabColorSettings.defaultPaletteWithOverrides(defaults: defaults)
        XCTAssertEqual(palette.count, 16)
        XCTAssertEqual(palette.first?.name, "Red")
        XCTAssertEqual(palette.first?.hex, "#C0392B")
        XCTAssertEqual(palette.last?.name, "Charcoal")
        XCTAssertFalse(palette.contains(where: { $0.name == "Gold" }))
    }

    func testDefaultOverrideRoundTripFallsBackWhenResetToBase() {
        let suiteName = "WorkspaceTabColorSettingsTests.DefaultOverride.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = WorkspaceTabColorSettings.defaultPalette[0]
        XCTAssertEqual(
            WorkspaceTabColorSettings.defaultColorHex(named: first.name, defaults: defaults),
            first.hex
        )

        WorkspaceTabColorSettings.setDefaultColor(named: first.name, hex: "#00aa33", defaults: defaults)
        XCTAssertEqual(
            WorkspaceTabColorSettings.defaultColorHex(named: first.name, defaults: defaults),
            "#00AA33"
        )

        WorkspaceTabColorSettings.setDefaultColor(named: first.name, hex: first.hex, defaults: defaults)
        XCTAssertEqual(
            WorkspaceTabColorSettings.defaultColorHex(named: first.name, defaults: defaults),
            first.hex
        )
    }

    func testAddCustomColorPersistsAndDeduplicatesByMostRecent() {
        let suiteName = "WorkspaceTabColorSettingsTests.CustomColors.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            WorkspaceTabColorSettings.addCustomColor(" #00aa33 ", defaults: defaults),
            "#00AA33"
        )
        XCTAssertEqual(
            WorkspaceTabColorSettings.addCustomColor("#112233", defaults: defaults),
            "#112233"
        )
        XCTAssertEqual(
            WorkspaceTabColorSettings.addCustomColor("#00AA33", defaults: defaults),
            "#00AA33"
        )
        XCTAssertNil(WorkspaceTabColorSettings.addCustomColor("nope", defaults: defaults))

        XCTAssertEqual(
            WorkspaceTabColorSettings.customColors(defaults: defaults),
            ["#00AA33", "#112233"]
        )
    }

    func testPaletteIncludesCustomEntriesAndResetClearsAll() {
        let suiteName = "WorkspaceTabColorSettingsTests.Reset.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = WorkspaceTabColorSettings.defaultPalette[0]
        WorkspaceTabColorSettings.setDefaultColor(named: first.name, hex: "#334455", defaults: defaults)
        _ = WorkspaceTabColorSettings.addCustomColor("#778899", defaults: defaults)

        let paletteBeforeReset = WorkspaceTabColorSettings.palette(defaults: defaults)
        XCTAssertEqual(paletteBeforeReset.count, WorkspaceTabColorSettings.defaultPalette.count + 1)
        XCTAssertEqual(paletteBeforeReset[0].hex, "#334455")
        XCTAssertEqual(paletteBeforeReset.last?.name, "Custom 1")
        XCTAssertEqual(paletteBeforeReset.last?.hex, "#778899")

        WorkspaceTabColorSettings.reset(defaults: defaults)

        XCTAssertEqual(WorkspaceTabColorSettings.customColors(defaults: defaults), [])
        XCTAssertEqual(
            WorkspaceTabColorSettings.defaultColorHex(named: first.name, defaults: defaults),
            first.hex
        )
    }

    func testDisplayColorLightModeKeepsOriginalHex() {
        let originalHex = "#1A5276"
        let rendered = WorkspaceTabColorSettings.displayNSColor(
            hex: originalHex,
            colorScheme: .light
        )

        XCTAssertEqual(rendered?.hexString(), originalHex)
    }

    func testDisplayColorDarkModeBrightensColor() {
        let originalHex = "#1A5276"
        guard let base = NSColor(hex: originalHex),
              let rendered = WorkspaceTabColorSettings.displayNSColor(
                  hex: originalHex,
                  colorScheme: .dark
              ) else {
            XCTFail("Expected valid color conversion")
            return
        }

        XCTAssertNotEqual(rendered.hexString(), originalHex)
        XCTAssertGreaterThan(rendered.luminance, base.luminance)
    }

    func testDisplayColorDarkModeKeepsGrayscaleNeutral() {
        let originalHex = "#808080"
        guard let base = NSColor(hex: originalHex),
              let rendered = WorkspaceTabColorSettings.displayNSColor(
                  hex: originalHex,
                  colorScheme: .dark
              ),
              let renderedSRGB = rendered.usingColorSpace(.sRGB) else {
            XCTFail("Expected valid color conversion")
            return
        }

        XCTAssertGreaterThan(rendered.luminance, base.luminance)
        XCTAssertLessThan(abs(renderedSRGB.redComponent - renderedSRGB.greenComponent), 0.003)
        XCTAssertLessThan(abs(renderedSRGB.greenComponent - renderedSRGB.blueComponent), 0.003)
    }

    func testDisplayColorForceBrightensInLightMode() {
        let originalHex = "#1A5276"
        guard let base = NSColor(hex: originalHex),
              let rendered = WorkspaceTabColorSettings.displayNSColor(
                  hex: originalHex,
                  colorScheme: .light,
                  forceBright: true
              ) else {
            XCTFail("Expected valid color conversion")
            return
        }

        XCTAssertNotEqual(rendered.hexString(), originalHex)
        XCTAssertGreaterThan(rendered.luminance, base.luminance)
    }
}

final class WorkspaceAutoReorderSettingsTests: XCTestCase {
    func testDefaultIsEnabled() {
        let suiteName = "WorkspaceAutoReorderSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(WorkspaceAutoReorderSettings.isEnabled(defaults: defaults))
    }

    func testDisabledWhenSetToFalse() {
        let suiteName = "WorkspaceAutoReorderSettingsTests.Disabled.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: WorkspaceAutoReorderSettings.key)
        XCTAssertFalse(WorkspaceAutoReorderSettings.isEnabled(defaults: defaults))
    }

    func testEnabledWhenSetToTrue() {
        let suiteName = "WorkspaceAutoReorderSettingsTests.Enabled.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: WorkspaceAutoReorderSettings.key)
        XCTAssertTrue(WorkspaceAutoReorderSettings.isEnabled(defaults: defaults))
    }
}

final class SidebarBranchLayoutSettingsTests: XCTestCase {
    func testDefaultUsesVerticalLayout() {
        let suiteName = "SidebarBranchLayoutSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(SidebarBranchLayoutSettings.usesVerticalLayout(defaults: defaults))
    }

    func testStoredPreferenceOverridesDefault() {
        let suiteName = "SidebarBranchLayoutSettingsTests.Stored.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: SidebarBranchLayoutSettings.key)
        XCTAssertFalse(SidebarBranchLayoutSettings.usesVerticalLayout(defaults: defaults))

        defaults.set(true, forKey: SidebarBranchLayoutSettings.key)
        XCTAssertTrue(SidebarBranchLayoutSettings.usesVerticalLayout(defaults: defaults))
    }
}

final class SidebarActiveTabIndicatorSettingsTests: XCTestCase {
    func testDefaultStyleWhenUnset() {
        let suiteName = "SidebarActiveTabIndicatorSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.removeObject(forKey: SidebarActiveTabIndicatorSettings.styleKey)
        XCTAssertEqual(
            SidebarActiveTabIndicatorSettings.current(defaults: defaults),
            SidebarActiveTabIndicatorSettings.defaultStyle
        )
    }

    func testStoredStyleParsesAndInvalidFallsBack() {
        let suiteName = "SidebarActiveTabIndicatorSettingsTests.Stored.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(SidebarActiveTabIndicatorStyle.leftRail.rawValue, forKey: SidebarActiveTabIndicatorSettings.styleKey)
        XCTAssertEqual(SidebarActiveTabIndicatorSettings.current(defaults: defaults), .leftRail)

        defaults.set("rail", forKey: SidebarActiveTabIndicatorSettings.styleKey)
        XCTAssertEqual(SidebarActiveTabIndicatorSettings.current(defaults: defaults), .leftRail)

        defaults.set("not-a-style", forKey: SidebarActiveTabIndicatorSettings.styleKey)
        XCTAssertEqual(
            SidebarActiveTabIndicatorSettings.current(defaults: defaults),
            SidebarActiveTabIndicatorSettings.defaultStyle
        )
    }
}

final class AppearanceSettingsTests: XCTestCase {
    func testResolvedModeDefaultsToSystemWhenUnset() {
        let suiteName = "AppearanceSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.removeObject(forKey: AppearanceSettings.appearanceModeKey)

        let resolved = AppearanceSettings.resolvedMode(defaults: defaults)
        XCTAssertEqual(resolved, .system)
        XCTAssertEqual(defaults.string(forKey: AppearanceSettings.appearanceModeKey), AppearanceMode.system.rawValue)
    }
}

final class QuitWarningSettingsTests: XCTestCase {
    func testDefaultWarnBeforeQuitIsEnabledWhenUnset() {
        let suiteName = "QuitWarningSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.removeObject(forKey: QuitWarningSettings.warnBeforeQuitKey)

        XCTAssertTrue(QuitWarningSettings.isEnabled(defaults: defaults))
    }

    func testStoredPreferenceOverridesDefault() {
        let suiteName = "QuitWarningSettingsTests.Stored.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: QuitWarningSettings.warnBeforeQuitKey)
        XCTAssertFalse(QuitWarningSettings.isEnabled(defaults: defaults))

        defaults.set(true, forKey: QuitWarningSettings.warnBeforeQuitKey)
        XCTAssertTrue(QuitWarningSettings.isEnabled(defaults: defaults))
    }
}

final class UpdateChannelSettingsTests: XCTestCase {
    func testResolvedFeedFallsBackWhenInfoFeedMissing() {
        let resolved = UpdateFeedResolver.resolvedFeedURLString(infoFeedURL: nil)
        XCTAssertEqual(resolved.url, UpdateFeedResolver.fallbackFeedURL)
        XCTAssertFalse(resolved.isNightly)
        XCTAssertTrue(resolved.usedFallback)
    }

    func testResolvedFeedFallsBackWhenInfoFeedEmpty() {
        let resolved = UpdateFeedResolver.resolvedFeedURLString(infoFeedURL: "")
        XCTAssertEqual(resolved.url, UpdateFeedResolver.fallbackFeedURL)
        XCTAssertFalse(resolved.isNightly)
        XCTAssertTrue(resolved.usedFallback)
    }

    func testResolvedFeedUsesInfoFeedForStableChannel() {
        let infoFeed = "https://example.com/custom/appcast.xml"
        let resolved = UpdateFeedResolver.resolvedFeedURLString(infoFeedURL: infoFeed)
        XCTAssertEqual(resolved.url, infoFeed)
        XCTAssertFalse(resolved.isNightly)
        XCTAssertFalse(resolved.usedFallback)
    }

    func testResolvedFeedDetectsNightlyFromInfoFeedURL() {
        let resolved = UpdateFeedResolver.resolvedFeedURLString(
            infoFeedURL: "https://example.com/nightly/appcast.xml"
        )
        XCTAssertEqual(resolved.url, "https://example.com/nightly/appcast.xml")
        XCTAssertTrue(resolved.isNightly)
        XCTAssertFalse(resolved.usedFallback)
    }
}

final class WorkspaceReorderTests: XCTestCase {
    @MainActor
    func testReorderWorkspaceMovesWorkspaceToRequestedIndex() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()

        manager.selectWorkspace(second)
        XCTAssertEqual(manager.selectedTabId, second.id)

        XCTAssertTrue(manager.reorderWorkspace(tabId: second.id, toIndex: 0))
        XCTAssertEqual(manager.tabs.map(\.id), [second.id, first.id, third.id])
        XCTAssertEqual(manager.selectedTabId, second.id)
    }

    @MainActor
    func testReorderWorkspaceClampsOutOfRangeTargetIndex() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()

        XCTAssertTrue(manager.reorderWorkspace(tabId: first.id, toIndex: 999))
        XCTAssertEqual(manager.tabs.map(\.id), [second.id, third.id, first.id])
    }

    @MainActor
    func testReorderWorkspaceReturnsFalseForUnknownWorkspace() {
        let manager = TabManager()
        XCTAssertFalse(manager.reorderWorkspace(tabId: UUID(), toIndex: 0))
    }
}

@MainActor
final class TabManagerChildExitCloseTests: XCTestCase {
    func testChildExitOnLastPanelClosesSelectedWorkspaceAndKeepsIndexStable() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()

        manager.selectWorkspace(second)
        XCTAssertEqual(manager.selectedTabId, second.id)

        guard let secondPanelId = second.focusedPanelId else {
            XCTFail("Expected focused panel in selected workspace")
            return
        }

        manager.closePanelAfterChildExited(tabId: second.id, surfaceId: secondPanelId)

        XCTAssertEqual(manager.tabs.map(\.id), [first.id, third.id])
        XCTAssertEqual(
            manager.selectedTabId,
            third.id,
            "Expected selection to stay at the same index after deleting the selected workspace"
        )
    }

    func testChildExitOnLastPanelInLastWorkspaceSelectsPreviousWorkspace() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()

        manager.selectWorkspace(second)
        XCTAssertEqual(manager.selectedTabId, second.id)

        guard let secondPanelId = second.focusedPanelId else {
            XCTFail("Expected focused panel in selected workspace")
            return
        }

        manager.closePanelAfterChildExited(tabId: second.id, surfaceId: secondPanelId)

        XCTAssertEqual(manager.tabs.map(\.id), [first.id])
        XCTAssertEqual(
            manager.selectedTabId,
            first.id,
            "Expected previous workspace to be selected after closing the last-index workspace"
        )
    }

    func testChildExitOnNonLastPanelClosesOnlyPanel() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let initialPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        guard let splitPanel = workspace.newTerminalSplit(from: initialPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panel to be created")
            return
        }

        let panelCountBefore = workspace.panels.count
        manager.closePanelAfterChildExited(tabId: workspace.id, surfaceId: splitPanel.id)

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(manager.tabs.first?.id, workspace.id)
        XCTAssertEqual(workspace.panels.count, panelCountBefore - 1)
        XCTAssertNotNil(workspace.panels[initialPanelId], "Expected sibling panel to remain")
    }
}

@MainActor
final class TabManagerPendingUnfocusPolicyTests: XCTestCase {
    func testDoesNotUnfocusWhenPendingTabIsCurrentlySelected() {
        let tabId = UUID()

        XCTAssertFalse(
            TabManager.shouldUnfocusPendingWorkspace(
                pendingTabId: tabId,
                selectedTabId: tabId
            )
        )
    }

    func testUnfocusesWhenPendingTabIsNotSelected() {
        XCTAssertTrue(
            TabManager.shouldUnfocusPendingWorkspace(
                pendingTabId: UUID(),
                selectedTabId: UUID()
            )
        )
        XCTAssertTrue(
            TabManager.shouldUnfocusPendingWorkspace(
                pendingTabId: UUID(),
                selectedTabId: nil
            )
        )
    }
}

@MainActor
final class TabManagerSurfaceCreationTests: XCTestCase {
    func testNewSurfaceFocusesCreatedSurface() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected a selected workspace")
            return
        }

        let beforePanels = Set(workspace.panels.keys)
        manager.newSurface()
        let afterPanels = Set(workspace.panels.keys)

        let createdPanels = afterPanels.subtracting(beforePanels)
        XCTAssertEqual(createdPanels.count, 1, "Expected one new surface for Cmd+T path")
        guard let createdPanelId = createdPanels.first else { return }

        XCTAssertEqual(
            workspace.focusedPanelId,
            createdPanelId,
            "Expected newly created surface to be focused"
        )
    }

    func testOpenBrowserInsertAtEndPlacesNewBrowserAtPaneEnd() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let paneId = workspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected focused workspace and pane")
            return
        }

        // Add one extra surface so we verify append-to-end rather than first insert behavior.
        _ = workspace.newTerminalSurface(inPane: paneId, focus: false)

        guard let browserPanelId = manager.openBrowser(insertAtEnd: true) else {
            XCTFail("Expected browser panel to be created")
            return
        }

        let tabs = workspace.bonsplitController.tabs(inPane: paneId)
        guard let lastSurfaceId = tabs.last?.id else {
            XCTFail("Expected at least one surface in pane")
            return
        }

        XCTAssertEqual(
            workspace.panelIdFromSurfaceId(lastSurfaceId),
            browserPanelId,
            "Expected Cmd+Shift+B/Cmd+L open path to append browser surface at end"
        )
        XCTAssertEqual(workspace.focusedPanelId, browserPanelId, "Expected opened browser surface to be focused")
    }

    func testOpenBrowserInWorkspaceSplitRightSelectsTargetWorkspaceAndCreatesSplit() {
        let manager = TabManager()
        guard let initialWorkspace = manager.selectedWorkspace else {
            XCTFail("Expected initial selected workspace")
            return
        }
        guard let url = URL(string: "https://example.com/pull/123") else {
            XCTFail("Expected test URL to be valid")
            return
        }

        let targetWorkspace = manager.addWorkspace(select: false)
        manager.selectWorkspace(initialWorkspace)
        let initialPaneCount = targetWorkspace.bonsplitController.allPaneIds.count
        let initialPanelCount = targetWorkspace.panels.count

        guard let browserPanelId = manager.openBrowser(
            inWorkspace: targetWorkspace.id,
            url: url,
            preferSplitRight: true,
            insertAtEnd: true
        ) else {
            XCTFail("Expected browser panel to be created in target workspace")
            return
        }

        XCTAssertEqual(manager.selectedTabId, targetWorkspace.id, "Expected target workspace to become selected")
        XCTAssertEqual(
            targetWorkspace.bonsplitController.allPaneIds.count,
            initialPaneCount + 1,
            "Expected split-right browser open to create a new pane"
        )
        XCTAssertEqual(
            targetWorkspace.panels.count,
            initialPanelCount + 1,
            "Expected browser panel count to increase by one"
        )
        XCTAssertEqual(
            targetWorkspace.focusedPanelId,
            browserPanelId,
            "Expected created browser panel to be focused in target workspace"
        )
        XCTAssertTrue(
            targetWorkspace.panels[browserPanelId] is BrowserPanel,
            "Expected created panel to be a browser panel"
        )
    }

    func testOpenBrowserInWorkspaceSplitRightReusesTopRightPaneWhenAlreadySplit() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let topRightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal),
              workspace.newTerminalSplit(from: topRightPanel.id, orientation: .vertical) != nil,
              let topRightPaneId = workspace.paneId(forPanelId: topRightPanel.id),
              let url = URL(string: "https://example.com/pull/456") else {
            XCTFail("Expected split setup to succeed")
            return
        }

        let initialPaneCount = workspace.bonsplitController.allPaneIds.count

        guard let browserPanelId = manager.openBrowser(
            inWorkspace: workspace.id,
            url: url,
            preferSplitRight: true,
            insertAtEnd: true
        ) else {
            XCTFail("Expected browser panel to be created")
            return
        }

        XCTAssertEqual(
            workspace.bonsplitController.allPaneIds.count,
            initialPaneCount,
            "Expected split-right browser open to reuse existing panes"
        )
        XCTAssertEqual(
            workspace.paneId(forPanelId: browserPanelId),
            topRightPaneId,
            "Expected browser to open in the top-right pane when multiple splits already exist"
        )

        let targetPaneTabs = workspace.bonsplitController.tabs(inPane: topRightPaneId)
        guard let lastSurfaceId = targetPaneTabs.last?.id else {
            XCTFail("Expected top-right pane to contain tabs")
            return
        }
        XCTAssertEqual(
            workspace.panelIdFromSurfaceId(lastSurfaceId),
            browserPanelId,
            "Expected browser surface to be appended at end in the reused top-right pane"
        )
    }
}

@MainActor
final class WorkspaceTerminalConfigInheritanceSelectionTests: XCTestCase {
    func testPrefersSelectedTerminalInTargetPaneOverFocusedTerminalElsewhere() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal),
              let leftPaneId = workspace.paneId(forPanelId: leftPanelId) else {
            XCTFail("Expected workspace split setup to succeed")
            return
        }

        // Programmatic split focuses the new right panel by default.
        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id)

        let sourcePanel = workspace.terminalPanelForConfigInheritance(inPane: leftPaneId)
        XCTAssertEqual(
            sourcePanel?.id,
            leftPanelId,
            "Expected inheritance to use the selected terminal in the target pane"
        )
    }

    func testFallsBackToAnotherTerminalInPaneWhenSelectedTabIsBrowser() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let terminalPanelId = workspace.focusedPanelId,
              let paneId = workspace.paneId(forPanelId: terminalPanelId),
              let browserPanel = workspace.newBrowserSurface(inPane: paneId, focus: true) else {
            XCTFail("Expected workspace browser setup to succeed")
            return
        }

        XCTAssertEqual(workspace.focusedPanelId, browserPanel.id)

        let sourcePanel = workspace.terminalPanelForConfigInheritance(inPane: paneId)
        XCTAssertEqual(
            sourcePanel?.id,
            terminalPanelId,
            "Expected inheritance to fall back to a terminal in the pane when browser is selected"
        )
    }

    func testPreferredTerminalPanelWinsWhenProvided() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let terminalPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with a terminal panel")
            return
        }

        let sourcePanel = workspace.terminalPanelForConfigInheritance(preferredPanelId: terminalPanelId)
        XCTAssertEqual(sourcePanel?.id, terminalPanelId)
    }

    func testPrefersLastFocusedTerminalWhenBrowserFocusedInDifferentPane() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftTerminalPanelId = workspace.focusedPanelId,
              let rightTerminalPanel = workspace.newTerminalSplit(from: leftTerminalPanelId, orientation: .horizontal),
              let rightPaneId = workspace.paneId(forPanelId: rightTerminalPanel.id) else {
            XCTFail("Expected split setup to succeed")
            return
        }

        workspace.focusPanel(leftTerminalPanelId)
        _ = workspace.newBrowserSurface(inPane: rightPaneId, focus: true)
        XCTAssertNotEqual(workspace.focusedPanelId, leftTerminalPanelId)

        let sourcePanel = workspace.terminalPanelForConfigInheritance(inPane: rightPaneId)
        XCTAssertEqual(
            sourcePanel?.id,
            leftTerminalPanelId,
            "Expected inheritance to prefer last focused terminal when browser is focused in another pane"
        )
    }
}

@MainActor
final class TabManagerWorkspaceConfigInheritanceSourceTests: XCTestCase {
    func testUsesFocusedTerminalWhenTerminalIsFocused() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let terminalPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused terminal")
            return
        }

        let sourcePanel = manager.terminalPanelForWorkspaceConfigInheritanceSource()
        XCTAssertEqual(sourcePanel?.id, terminalPanelId)
    }

    func testFallsBackToTerminalWhenBrowserIsFocused() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let terminalPanelId = workspace.focusedPanelId,
              let paneId = workspace.paneId(forPanelId: terminalPanelId),
              let browserPanel = workspace.newBrowserSurface(inPane: paneId, focus: true) else {
            XCTFail("Expected selected workspace setup to succeed")
            return
        }

        XCTAssertEqual(workspace.focusedPanelId, browserPanel.id)

        let sourcePanel = manager.terminalPanelForWorkspaceConfigInheritanceSource()
        XCTAssertEqual(
            sourcePanel?.id,
            terminalPanelId,
            "Expected new workspace inheritance source to resolve to the pane terminal when browser is focused"
        )
    }

    func testPrefersLastFocusedTerminalAcrossPanesWhenBrowserIsFocused() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftTerminalPanelId = workspace.focusedPanelId,
              let rightTerminalPanel = workspace.newTerminalSplit(from: leftTerminalPanelId, orientation: .horizontal),
              let rightPaneId = workspace.paneId(forPanelId: rightTerminalPanel.id) else {
            XCTFail("Expected split setup to succeed")
            return
        }

        workspace.focusPanel(leftTerminalPanelId)
        _ = workspace.newBrowserSurface(inPane: rightPaneId, focus: true)
        XCTAssertNotEqual(workspace.focusedPanelId, leftTerminalPanelId)

        let sourcePanel = manager.terminalPanelForWorkspaceConfigInheritanceSource()
        XCTAssertEqual(
            sourcePanel?.id,
            leftTerminalPanelId,
            "Expected workspace inheritance source to use last focused terminal across panes"
        )
    }
}

@MainActor
final class TabManagerReopenClosedBrowserFocusTests: XCTestCase {
    func testReopenFromDifferentWorkspaceFocusesReopenedBrowser() {
        let manager = TabManager()
        guard let workspace1 = manager.selectedWorkspace,
              let closedBrowserId = manager.openBrowser(url: URL(string: "https://example.com/ws-switch")) else {
            XCTFail("Expected initial workspace and browser panel")
            return
        }

        drainMainQueue()
        XCTAssertTrue(workspace1.closePanel(closedBrowserId, force: true))
        drainMainQueue()

        let workspace2 = manager.addWorkspace()
        XCTAssertEqual(manager.selectedTabId, workspace2.id)

        XCTAssertTrue(manager.reopenMostRecentlyClosedBrowserPanel())
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, workspace1.id)
        XCTAssertTrue(isFocusedPanelBrowser(in: workspace1))
    }

    func testReopenFallsBackToCurrentWorkspaceAndFocusesBrowserWhenOriginalWorkspaceDeleted() {
        let manager = TabManager()
        guard let originalWorkspace = manager.selectedWorkspace,
              let closedBrowserId = manager.openBrowser(url: URL(string: "https://example.com/deleted-ws")) else {
            XCTFail("Expected initial workspace and browser panel")
            return
        }

        drainMainQueue()
        XCTAssertTrue(originalWorkspace.closePanel(closedBrowserId, force: true))
        drainMainQueue()

        let currentWorkspace = manager.addWorkspace()
        manager.closeWorkspace(originalWorkspace)

        XCTAssertEqual(manager.selectedTabId, currentWorkspace.id)
        XCTAssertFalse(manager.tabs.contains(where: { $0.id == originalWorkspace.id }))

        XCTAssertTrue(manager.reopenMostRecentlyClosedBrowserPanel())
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, currentWorkspace.id)
        XCTAssertTrue(isFocusedPanelBrowser(in: currentWorkspace))
    }

    func testReopenCollapsedSplitFromDifferentWorkspaceFocusesBrowser() {
        let manager = TabManager()
        guard let workspace1 = manager.selectedWorkspace,
              let sourcePanelId = workspace1.focusedPanelId,
              let splitBrowserId = manager.newBrowserSplit(
                tabId: workspace1.id,
                fromPanelId: sourcePanelId,
                orientation: .horizontal,
                insertFirst: false,
                url: URL(string: "https://example.com/collapsed-split")
              ) else {
            XCTFail("Expected to create browser split")
            return
        }

        drainMainQueue()
        XCTAssertTrue(workspace1.closePanel(splitBrowserId, force: true))
        drainMainQueue()

        let workspace2 = manager.addWorkspace()
        XCTAssertEqual(manager.selectedTabId, workspace2.id)

        XCTAssertTrue(manager.reopenMostRecentlyClosedBrowserPanel())
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, workspace1.id)
        XCTAssertTrue(isFocusedPanelBrowser(in: workspace1))
    }

    func testReopenFromDifferentWorkspaceWinsAgainstSingleDeferredStaleFocus() {
        let manager = TabManager()
        guard let workspace1 = manager.selectedWorkspace,
              let preReopenPanelId = workspace1.focusedPanelId,
              let closedBrowserId = manager.openBrowser(url: URL(string: "https://example.com/stale-focus-cross-ws")) else {
            XCTFail("Expected initial workspace state and browser panel")
            return
        }

        drainMainQueue()
        XCTAssertTrue(workspace1.closePanel(closedBrowserId, force: true))
        drainMainQueue()

        let panelIdsBeforeReopen = Set(workspace1.panels.keys)
        let workspace2 = manager.addWorkspace()
        XCTAssertEqual(manager.selectedTabId, workspace2.id)

        XCTAssertTrue(manager.reopenMostRecentlyClosedBrowserPanel())
        guard let reopenedPanelId = singleNewPanelId(in: workspace1, comparedTo: panelIdsBeforeReopen) else {
            XCTFail("Expected reopened browser panel ID")
            return
        }

        // Simulate one delayed stale focus callback from the panel that was focused before reopen.
        DispatchQueue.main.async {
            workspace1.focusPanel(preReopenPanelId)
        }

        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, workspace1.id)
        XCTAssertEqual(workspace1.focusedPanelId, reopenedPanelId)
        XCTAssertTrue(workspace1.panels[reopenedPanelId] is BrowserPanel)
    }

    func testReopenInSameWorkspaceWinsAgainstSingleDeferredStaleFocus() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let preReopenPanelId = workspace.focusedPanelId,
              let closedBrowserId = manager.openBrowser(url: URL(string: "https://example.com/stale-focus-same-ws")) else {
            XCTFail("Expected initial workspace state and browser panel")
            return
        }

        drainMainQueue()
        XCTAssertTrue(workspace.closePanel(closedBrowserId, force: true))
        drainMainQueue()

        let panelIdsBeforeReopen = Set(workspace.panels.keys)
        XCTAssertTrue(manager.reopenMostRecentlyClosedBrowserPanel())
        guard let reopenedPanelId = singleNewPanelId(in: workspace, comparedTo: panelIdsBeforeReopen) else {
            XCTFail("Expected reopened browser panel ID")
            return
        }

        // Simulate one delayed stale focus callback from the panel that was focused before reopen.
        DispatchQueue.main.async {
            workspace.focusPanel(preReopenPanelId)
        }

        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, workspace.id)
        XCTAssertEqual(workspace.focusedPanelId, reopenedPanelId)
        XCTAssertTrue(workspace.panels[reopenedPanelId] is BrowserPanel)
    }

    private func isFocusedPanelBrowser(in workspace: Workspace) -> Bool {
        guard let focusedPanelId = workspace.focusedPanelId else { return false }
        return workspace.panels[focusedPanelId] is BrowserPanel
    }

    private func singleNewPanelId(in workspace: Workspace, comparedTo previousPanelIds: Set<UUID>) -> UUID? {
        let newPanelIds = Set(workspace.panels.keys).subtracting(previousPanelIds)
        guard newPanelIds.count == 1 else { return nil }
        return newPanelIds.first
    }

    private func drainMainQueue() {
        let expectation = expectation(description: "drain main queue")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }
}

@MainActor
final class WorkspacePanelGitBranchTests: XCTestCase {
    private func drainMainQueue() {
        let expectation = expectation(description: "drain main queue")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testBrowserSplitWithFocusFalsePreservesOriginalFocusedPanel() {
        let workspace = Workspace()
        guard let originalFocusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        guard let browserSplitPanel = workspace.newBrowserSplit(
            from: originalFocusedPanelId,
            orientation: .horizontal,
            focus: false
        ) else {
            XCTFail("Expected browser split panel to be created")
            return
        }

        drainMainQueue()

        XCTAssertNotEqual(browserSplitPanel.id, originalFocusedPanelId)
        XCTAssertEqual(
            workspace.focusedPanelId,
            originalFocusedPanelId,
            "Expected non-focus browser split to preserve pre-split focus"
        )
    }

    func testTerminalSplitWithFocusFalsePreservesOriginalFocusedPanel() {
        let workspace = Workspace()
        guard let originalFocusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        guard let terminalSplitPanel = workspace.newTerminalSplit(
            from: originalFocusedPanelId,
            orientation: .horizontal,
            focus: false
        ) else {
            XCTFail("Expected terminal split panel to be created")
            return
        }

        drainMainQueue()

        XCTAssertNotEqual(terminalSplitPanel.id, originalFocusedPanelId)
        XCTAssertEqual(
            workspace.focusedPanelId,
            originalFocusedPanelId,
            "Expected non-focus terminal split to preserve pre-split focus"
        )
    }

    func testDetachLastSurfaceLeavesWorkspaceTemporarilyEmptyForMoveFlow() {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId,
              let paneId = workspace.paneId(forPanelId: panelId) else {
            XCTFail("Expected initial panel and pane")
            return
        }

        XCTAssertEqual(workspace.panels.count, 1)
#if DEBUG
        let baselineFocusReconcileDuringDetach = workspace.debugFocusReconcileScheduledDuringDetachCount
#endif

        guard let detached = workspace.detachSurface(panelId: panelId) else {
            XCTFail("Expected detach of last surface to succeed")
            return
        }

        XCTAssertEqual(detached.panelId, panelId)
        XCTAssertTrue(
            workspace.panels.isEmpty,
            "Detaching the last surface should not auto-create a replacement panel"
        )
        XCTAssertNil(workspace.surfaceIdFromPanelId(panelId))
        XCTAssertEqual(workspace.bonsplitController.tabs(inPane: paneId).count, 0)

        drainMainQueue()
        drainMainQueue()
#if DEBUG
        XCTAssertEqual(
            workspace.debugFocusReconcileScheduledDuringDetachCount,
            baselineFocusReconcileDuringDetach,
            "Detaching during cross-workspace moves should not schedule delayed source focus reconciliation"
        )
#endif

        let restoredPanelId = workspace.attachDetachedSurface(detached, inPane: paneId, focus: false)
        XCTAssertEqual(restoredPanelId, panelId)
        XCTAssertEqual(workspace.panels.count, 1)
    }

    func testDetachSurfaceWithRemainingPanelsSkipsDelayedFocusReconcile() {
        let workspace = Workspace()
        guard let originalPanelId = workspace.focusedPanelId,
              let movedPanel = workspace.newTerminalSplit(from: originalPanelId, orientation: .horizontal) else {
            XCTFail("Expected two panels before detach")
            return
        }

        drainMainQueue()
        drainMainQueue()
#if DEBUG
        let baselineFocusReconcileDuringDetach = workspace.debugFocusReconcileScheduledDuringDetachCount
#endif

        guard let detached = workspace.detachSurface(panelId: movedPanel.id) else {
            XCTFail("Expected detach to succeed")
            return
        }

        XCTAssertEqual(detached.panelId, movedPanel.id)
        XCTAssertEqual(workspace.panels.count, 1, "Expected source workspace to retain only the surviving panel")
        XCTAssertNotNil(workspace.panels[originalPanelId], "Expected the original panel to remain after detach")

        drainMainQueue()
        drainMainQueue()
#if DEBUG
        XCTAssertEqual(
            workspace.debugFocusReconcileScheduledDuringDetachCount,
            baselineFocusReconcileDuringDetach,
            "Detaching into another workspace should not enqueue delayed source focus reconciliation"
        )
#endif
    }

    func testDetachAttachAcrossWorkspacesPreservesNonCustomPanelTitle() {
        let source = Workspace()
        guard let panelId = source.focusedPanelId else {
            XCTFail("Expected source focused panel")
            return
        }

        XCTAssertTrue(source.updatePanelTitle(panelId: panelId, title: "detached-runtime-title"))

        guard let detached = source.detachSurface(panelId: panelId) else {
            XCTFail("Expected detach to succeed")
            return
        }

        XCTAssertEqual(detached.cachedTitle, "detached-runtime-title")
        XCTAssertNil(detached.customTitle)
        XCTAssertEqual(
            detached.title,
            "detached-runtime-title",
            "Detached transfer should carry the cached non-custom title"
        )

        let destination = Workspace()
        guard let destinationPane = destination.bonsplitController.allPaneIds.first else {
            XCTFail("Expected destination pane")
            return
        }

        let attachedPanelId = destination.attachDetachedSurface(
            detached,
            inPane: destinationPane,
            focus: false
        )
        XCTAssertEqual(attachedPanelId, panelId)
        XCTAssertEqual(destination.panelTitle(panelId: panelId), "detached-runtime-title")

        guard let attachedTabId = destination.surfaceIdFromPanelId(panelId),
              let attachedTab = destination.bonsplitController.tab(attachedTabId) else {
            XCTFail("Expected attached tab mapping")
            return
        }
        XCTAssertEqual(attachedTab.title, "detached-runtime-title")
        XCTAssertFalse(attachedTab.hasCustomTitle)
    }

    func testBrowserSplitWithFocusFalseRecoversFromDelayedStaleSelection() {
        let workspace = Workspace()
        guard let originalFocusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }
        guard let originalPaneId = workspace.paneId(forPanelId: originalFocusedPanelId) else {
            XCTFail("Expected focused pane for initial panel")
            return
        }

        guard let browserSplitPanel = workspace.newBrowserSplit(
            from: originalFocusedPanelId,
            orientation: .horizontal,
            focus: false
        ) else {
            XCTFail("Expected browser split panel to be created")
            return
        }
        guard let splitPaneId = workspace.paneId(forPanelId: browserSplitPanel.id),
              let splitTabId = workspace.surfaceIdFromPanelId(browserSplitPanel.id),
              let splitTab = workspace.bonsplitController
              .tabs(inPane: splitPaneId)
              .first(where: { $0.id == splitTabId }) else {
            XCTFail("Expected split pane/tab mapping")
            return
        }

        // Simulate one delayed stale split-selection callback from bonsplit.
        DispatchQueue.main.async {
            workspace.splitTabBar(workspace.bonsplitController, didSelectTab: splitTab, inPane: splitPaneId)
        }

        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(
            workspace.focusedPanelId,
            originalFocusedPanelId,
            "Expected non-focus split to reassert the pre-split focused panel"
        )
        XCTAssertEqual(
            workspace.bonsplitController.focusedPaneId,
            originalPaneId,
            "Expected focused pane to converge back to the pre-split pane"
        )
        XCTAssertEqual(
            workspace.bonsplitController.selectedTab(inPane: originalPaneId)?.id,
            workspace.surfaceIdFromPanelId(originalFocusedPanelId),
            "Expected selected tab to converge back to the pre-split focused panel"
        )
    }

    func testBrowserSplitWithFocusFalseAllowsSubsequentExplicitFocusOnSplitPanel() {
        let workspace = Workspace()
        guard let originalFocusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        guard let browserSplitPanel = workspace.newBrowserSplit(
            from: originalFocusedPanelId,
            orientation: .horizontal,
            focus: false
        ) else {
            XCTFail("Expected browser split panel to be created")
            return
        }

        workspace.focusPanel(browserSplitPanel.id)

        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(
            workspace.focusedPanelId,
            browserSplitPanel.id,
            "Expected explicit focus intent to keep the split panel focused"
        )
    }

    func testClosingFocusedSplitRestoresBranchForRemainingFocusedPanel() {
        let workspace = Workspace()
        guard let firstPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        workspace.updatePanelGitBranch(panelId: firstPanelId, branch: "main", isDirty: false)
        guard let secondPanel = workspace.newTerminalSplit(from: firstPanelId, orientation: .horizontal) else {
            XCTFail("Expected split panel to be created")
            return
        }

        workspace.updatePanelGitBranch(panelId: secondPanel.id, branch: "feature/bugfix", isDirty: true)
        XCTAssertEqual(workspace.focusedPanelId, secondPanel.id, "Expected split panel to be focused")
        XCTAssertEqual(workspace.gitBranch?.branch, "feature/bugfix")
        XCTAssertEqual(workspace.gitBranch?.isDirty, true)

        XCTAssertTrue(workspace.closePanel(secondPanel.id, force: true), "Expected split panel close to succeed")
        XCTAssertEqual(workspace.focusedPanelId, firstPanelId, "Expected surviving panel to become focused")
        XCTAssertEqual(workspace.gitBranch?.branch, "main")
        XCTAssertEqual(workspace.gitBranch?.isDirty, false)
    }

    func testSidebarGitBranchesFollowLeftToRightSplitOrder() {
        let workspace = Workspace()
        guard let leftPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        workspace.updatePanelGitBranch(panelId: leftPanelId, branch: "main", isDirty: false)
        guard let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split panel to be created")
            return
        }
        workspace.updatePanelGitBranch(panelId: rightPanel.id, branch: "feature/sidebar", isDirty: true)

        let ordered = workspace.sidebarGitBranchesInDisplayOrder()
        XCTAssertEqual(ordered.map(\.branch), ["main", "feature/sidebar"])
        XCTAssertEqual(ordered.map(\.isDirty), [false, true])
    }

    func testSidebarOrderingUsesPaneOrderThenTabOrderWithBranchDeduping() {
        let workspace = Workspace()
        guard let leftFirstPanelId = workspace.focusedPanelId,
              let leftPaneId = workspace.paneId(forPanelId: leftFirstPanelId),
              let rightFirstPanel = workspace.newTerminalSplit(from: leftFirstPanelId, orientation: .horizontal),
              let rightPaneId = workspace.paneId(forPanelId: rightFirstPanel.id),
              let leftSecondPanel = workspace.newTerminalSurface(inPane: leftPaneId, focus: false),
              let rightSecondPanel = workspace.newTerminalSurface(inPane: rightPaneId, focus: false) else {
            XCTFail("Expected panes and panels for ordering test")
            return
        }

        XCTAssertTrue(workspace.reorderSurface(panelId: leftFirstPanelId, toIndex: 0))
        XCTAssertTrue(workspace.reorderSurface(panelId: leftSecondPanel.id, toIndex: 1))
        XCTAssertTrue(workspace.reorderSurface(panelId: rightFirstPanel.id, toIndex: 0))
        XCTAssertTrue(workspace.reorderSurface(panelId: rightSecondPanel.id, toIndex: 1))

        workspace.updatePanelGitBranch(panelId: leftFirstPanelId, branch: "main", isDirty: false)
        workspace.updatePanelGitBranch(panelId: leftSecondPanel.id, branch: "feature/left", isDirty: false)
        workspace.updatePanelGitBranch(panelId: rightFirstPanel.id, branch: "main", isDirty: true)
        workspace.updatePanelGitBranch(panelId: rightSecondPanel.id, branch: "feature/right", isDirty: false)

        XCTAssertEqual(
            workspace.sidebarOrderedPanelIds(),
            [leftFirstPanelId, leftSecondPanel.id, rightFirstPanel.id, rightSecondPanel.id]
        )

        let branches = workspace.sidebarGitBranchesInDisplayOrder()
        XCTAssertEqual(branches.map(\.branch), ["main", "feature/left", "feature/right"])
        XCTAssertEqual(branches.map(\.isDirty), [true, false, false])
    }

    func testClosingPaneDropsBranchesFromClosedSide() {
        let workspace = Workspace()
        guard let leftPanelId = workspace.focusedPanelId,
              let leftPaneId = workspace.paneId(forPanelId: leftPanelId),
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected left/right split panes")
            return
        }

        workspace.updatePanelGitBranch(panelId: leftPanelId, branch: "branch1", isDirty: false)
        workspace.updatePanelGitBranch(panelId: rightPanel.id, branch: "branch2", isDirty: false)

        XCTAssertEqual(workspace.sidebarGitBranchesInDisplayOrder().map(\.branch), ["branch1", "branch2"])
        XCTAssertTrue(workspace.bonsplitController.closePane(leftPaneId))
        XCTAssertEqual(workspace.sidebarGitBranchesInDisplayOrder().map(\.branch), ["branch2"])
    }
}

final class SidebarBranchOrderingTests: XCTestCase {

    func testOrderedUniqueBranchesDedupesByNameAndMergesDirtyState() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let branches = SidebarBranchOrdering.orderedUniqueBranches(
            orderedPanelIds: [first, second, third],
            panelBranches: [
                first: SidebarGitBranchState(branch: "main", isDirty: false),
                second: SidebarGitBranchState(branch: "feature", isDirty: false),
                third: SidebarGitBranchState(branch: "main", isDirty: true)
            ],
            fallbackBranch: SidebarGitBranchState(branch: "fallback", isDirty: false)
        )

        XCTAssertEqual(
            branches,
            [
                SidebarBranchOrdering.BranchEntry(name: "main", isDirty: true),
                SidebarBranchOrdering.BranchEntry(name: "feature", isDirty: false)
            ]
        )
    }

    func testOrderedUniqueBranchesUsesFallbackWhenNoPanelBranchesExist() {
        let branches = SidebarBranchOrdering.orderedUniqueBranches(
            orderedPanelIds: [],
            panelBranches: [:],
            fallbackBranch: SidebarGitBranchState(branch: "fallback", isDirty: true)
        )

        XCTAssertEqual(
            branches,
            [SidebarBranchOrdering.BranchEntry(name: "fallback", isDirty: true)]
        )
    }

    func testOrderedUniqueBranchDirectoryEntriesDedupesPairsAndMergesDirtyState() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let fourth = UUID()
        let fifth = UUID()

        let rows = SidebarBranchOrdering.orderedUniqueBranchDirectoryEntries(
            orderedPanelIds: [first, second, third, fourth, fifth],
            panelBranches: [
                first: SidebarGitBranchState(branch: "main", isDirty: false),
                second: SidebarGitBranchState(branch: "feature", isDirty: false),
                third: SidebarGitBranchState(branch: "main", isDirty: true),
                fourth: SidebarGitBranchState(branch: "main", isDirty: false)
            ],
            panelDirectories: [
                first: "/repo/a",
                second: "/repo/b",
                third: "/repo/a",
                fourth: "/repo/d",
                fifth: "/repo/e"
            ],
            defaultDirectory: "/repo/default",
            fallbackBranch: SidebarGitBranchState(branch: "fallback", isDirty: false)
        )

        XCTAssertEqual(
            rows,
            [
                SidebarBranchOrdering.BranchDirectoryEntry(branch: "main", isDirty: true, directory: "/repo/a"),
                SidebarBranchOrdering.BranchDirectoryEntry(branch: "feature", isDirty: false, directory: "/repo/b"),
                SidebarBranchOrdering.BranchDirectoryEntry(branch: "main", isDirty: false, directory: "/repo/d"),
                SidebarBranchOrdering.BranchDirectoryEntry(branch: nil, isDirty: false, directory: "/repo/e")
            ]
        )
    }

    func testOrderedUniqueBranchDirectoryEntriesUsesFallbackBranchWhenPanelBranchesMissing() {
        let first = UUID()
        let second = UUID()

        let rows = SidebarBranchOrdering.orderedUniqueBranchDirectoryEntries(
            orderedPanelIds: [first, second],
            panelBranches: [:],
            panelDirectories: [
                first: "/repo/one",
                second: "/repo/two"
            ],
            defaultDirectory: "/repo/default",
            fallbackBranch: SidebarGitBranchState(branch: "main", isDirty: true)
        )

        XCTAssertEqual(
            rows,
            [
                SidebarBranchOrdering.BranchDirectoryEntry(branch: "main", isDirty: true, directory: "/repo/one"),
                SidebarBranchOrdering.BranchDirectoryEntry(branch: "main", isDirty: true, directory: "/repo/two")
            ]
        )
    }

    func testOrderedUniqueBranchDirectoryEntriesFallsBackWhenNoPanelsExist() {
        let rows = SidebarBranchOrdering.orderedUniqueBranchDirectoryEntries(
            orderedPanelIds: [],
            panelBranches: [:],
            panelDirectories: [:],
            defaultDirectory: "/repo/default",
            fallbackBranch: SidebarGitBranchState(branch: "main", isDirty: false)
        )

        XCTAssertEqual(
            rows,
            [SidebarBranchOrdering.BranchDirectoryEntry(branch: "main", isDirty: false, directory: "/repo/default")]
        )
    }

    func testOrderedUniquePullRequestsFollowsPanelOrderAcrossSplitsAndTabs() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let fourth = UUID()

        let pullRequests = SidebarBranchOrdering.orderedUniquePullRequests(
            orderedPanelIds: [first, second, third, fourth],
            panelPullRequests: [
                first: pullRequestState(
                    number: 337,
                    label: "PR",
                    url: "https://github.com/manaflow-ai/cmux/pull/337",
                    status: .open
                ),
                second: pullRequestState(
                    number: 18,
                    label: "MR",
                    url: "https://gitlab.com/manaflow/cmux/-/merge_requests/18",
                    status: .open
                ),
                third: pullRequestState(
                    number: 337,
                    label: "PR",
                    url: "https://github.com/manaflow-ai/cmux/pull/337",
                    status: .merged
                ),
                fourth: pullRequestState(
                    number: 92,
                    label: "PR",
                    url: "https://bitbucket.org/manaflow/cmux/pull-requests/92",
                    status: .closed
                )
            ],
            fallbackPullRequest: pullRequestState(
                number: 1,
                label: "PR",
                url: "https://example.invalid/fallback/1",
                status: .open
            )
        )

        XCTAssertEqual(
            pullRequests.map { "\($0.label)#\($0.number)" },
            ["PR#337", "MR#18", "PR#92"]
        )
        XCTAssertEqual(
            pullRequests.map(\.status),
            [.merged, .open, .closed]
        )
    }

    func testOrderedUniquePullRequestsTreatsSameNumberDifferentLabelsAsDistinct() {
        let first = UUID()
        let second = UUID()

        let pullRequests = SidebarBranchOrdering.orderedUniquePullRequests(
            orderedPanelIds: [first, second],
            panelPullRequests: [
                first: pullRequestState(
                    number: 42,
                    label: "PR",
                    url: "https://github.com/manaflow-ai/cmux/pull/42",
                    status: .open
                ),
                second: pullRequestState(
                    number: 42,
                    label: "MR",
                    url: "https://gitlab.com/manaflow/cmux/-/merge_requests/42",
                    status: .open
                )
            ],
            fallbackPullRequest: nil
        )

        XCTAssertEqual(
            pullRequests.map { "\($0.label)#\($0.number)" },
            ["PR#42", "MR#42"]
        )
    }

    func testOrderedUniquePullRequestsTreatsSameNumberAndLabelDifferentUrlsAsDistinct() {
        let first = UUID()
        let second = UUID()

        let pullRequests = SidebarBranchOrdering.orderedUniquePullRequests(
            orderedPanelIds: [first, second],
            panelPullRequests: [
                first: pullRequestState(
                    number: 42,
                    label: "PR",
                    url: "https://github.com/manaflow-ai/cmux/pull/42",
                    status: .open
                ),
                second: pullRequestState(
                    number: 42,
                    label: "PR",
                    url: "https://github.com/manaflow-ai/other-repo/pull/42",
                    status: .open
                )
            ],
            fallbackPullRequest: nil
        )

        XCTAssertEqual(
            pullRequests.map(\.url.absoluteString),
            [
                "https://github.com/manaflow-ai/cmux/pull/42",
                "https://github.com/manaflow-ai/other-repo/pull/42"
            ]
        )
    }

    func testOrderedUniquePullRequestsUsesFallbackWhenNoPanelPullRequestsExist() {
        let fallback = pullRequestState(
            number: 11,
            label: "PR",
            url: "https://github.com/manaflow-ai/cmux/pull/11",
            status: .open
        )
        let pullRequests = SidebarBranchOrdering.orderedUniquePullRequests(
            orderedPanelIds: [],
            panelPullRequests: [:],
            fallbackPullRequest: fallback
        )

        XCTAssertEqual(pullRequests, [fallback])
    }

    private func pullRequestState(
        number: Int,
        label: String,
        url: String,
        status: SidebarPullRequestStatus
    ) -> SidebarPullRequestState {
        SidebarPullRequestState(
            number: number,
            label: label,
            url: URL(string: url)!,
            status: status
        )
    }
}

@MainActor
final class BrowserPanelAddressBarFocusRequestTests: XCTestCase {
    func testRequestPersistsUntilAcknowledged() {
        let panel = BrowserPanel(workspaceId: UUID())
        XCTAssertNil(panel.pendingAddressBarFocusRequestId)

        let requestId = panel.requestAddressBarFocus()
        XCTAssertEqual(panel.pendingAddressBarFocusRequestId, requestId)
        XCTAssertTrue(panel.shouldSuppressWebViewFocus())

        panel.acknowledgeAddressBarFocusRequest(requestId)
        XCTAssertNil(panel.pendingAddressBarFocusRequestId)

        // Acknowledgement only clears the durable request; focus suppression follows
        // explicit blur state transitions.
        XCTAssertTrue(panel.shouldSuppressWebViewFocus())
        panel.endSuppressWebViewFocusForAddressBar()
        XCTAssertFalse(panel.shouldSuppressWebViewFocus())
    }

    func testRequestCoalescesWhilePending() {
        let panel = BrowserPanel(workspaceId: UUID())
        let firstRequest = panel.requestAddressBarFocus()
        let secondRequest = panel.requestAddressBarFocus()

        XCTAssertEqual(firstRequest, secondRequest)
        XCTAssertEqual(panel.pendingAddressBarFocusRequestId, firstRequest)
    }

    func testStaleAcknowledgementDoesNotClearNewestRequest() {
        let panel = BrowserPanel(workspaceId: UUID())
        let firstRequest = panel.requestAddressBarFocus()
        panel.acknowledgeAddressBarFocusRequest(firstRequest)
        let secondRequest = panel.requestAddressBarFocus()

        XCTAssertNotEqual(firstRequest, secondRequest)
        XCTAssertEqual(panel.pendingAddressBarFocusRequestId, secondRequest)

        panel.acknowledgeAddressBarFocusRequest(firstRequest)
        XCTAssertEqual(panel.pendingAddressBarFocusRequestId, secondRequest)

        panel.acknowledgeAddressBarFocusRequest(secondRequest)
        XCTAssertNil(panel.pendingAddressBarFocusRequestId)
    }
}

final class SidebarDropPlannerTests: XCTestCase {
    func testNoIndicatorForNoOpEdges() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: first,
                targetTabId: first,
                tabIds: tabIds
            )
        )
        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: third,
                targetTabId: nil,
                tabIds: tabIds
            )
        )
    }

    func testNoIndicatorWhenOnlyOneTabExists() {
        let only = UUID()
        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: only,
                targetTabId: nil,
                tabIds: [only]
            )
        )
        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: only,
                targetTabId: only,
                tabIds: [only]
            )
        )
    }

    func testIndicatorAppearsForRealMoveToEnd() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        let indicator = SidebarDropPlanner.indicator(
            draggedTabId: second,
            targetTabId: nil,
            tabIds: tabIds
        )
        XCTAssertEqual(indicator?.tabId, nil)
        XCTAssertEqual(indicator?.edge, .bottom)
    }

    func testTargetIndexForMoveToEndFromMiddle() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        let index = SidebarDropPlanner.targetIndex(
            draggedTabId: second,
            targetTabId: nil,
            indicator: SidebarDropIndicator(tabId: nil, edge: .bottom),
            tabIds: tabIds
        )
        XCTAssertEqual(index, 2)
    }

    func testNoIndicatorForSelfDropInMiddle() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: second,
                targetTabId: second,
                tabIds: tabIds
            )
        )
    }

    func testPointerEdgeTopCanSuppressNoOpWhenDraggingFirstOverSecond() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: first,
                targetTabId: second,
                tabIds: tabIds,
                pointerY: 2,
                targetHeight: 40
            )
        )
    }

    func testPointerEdgeBottomAllowsMoveWhenDraggingFirstOverSecond() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        let indicator = SidebarDropPlanner.indicator(
            draggedTabId: first,
            targetTabId: second,
            tabIds: tabIds,
            pointerY: 38,
            targetHeight: 40
        )
        XCTAssertEqual(indicator?.tabId, third)
        XCTAssertEqual(indicator?.edge, .top)
        XCTAssertEqual(
            SidebarDropPlanner.targetIndex(
                draggedTabId: first,
                targetTabId: second,
                indicator: indicator,
                tabIds: tabIds
            ),
            1
        )
    }

    func testEquivalentBoundaryInputsResolveToSingleCanonicalIndicator() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        let fromBottomOfFirst = SidebarDropPlanner.indicator(
            draggedTabId: third,
            targetTabId: first,
            tabIds: tabIds,
            pointerY: 38,
            targetHeight: 40
        )
        let fromTopOfSecond = SidebarDropPlanner.indicator(
            draggedTabId: third,
            targetTabId: second,
            tabIds: tabIds,
            pointerY: 2,
            targetHeight: 40
        )

        XCTAssertEqual(fromBottomOfFirst?.tabId, second)
        XCTAssertEqual(fromBottomOfFirst?.edge, .top)
        XCTAssertEqual(fromTopOfSecond?.tabId, second)
        XCTAssertEqual(fromTopOfSecond?.edge, .top)
    }

    func testPointerEdgeBottomSuppressesNoOpWhenDraggingLastOverSecond() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: third,
                targetTabId: second,
                tabIds: tabIds,
                pointerY: 38,
                targetHeight: 40
            )
        )
    }
}

final class SidebarDragAutoScrollPlannerTests: XCTestCase {
    func testAutoScrollPlanTriggersNearTopAndBottomOnly() {
        let topPlan = SidebarDragAutoScrollPlanner.plan(distanceToTop: 4, distanceToBottom: 96, edgeInset: 44, minStep: 2, maxStep: 12)
        XCTAssertEqual(topPlan?.direction, .up)
        XCTAssertNotNil(topPlan)

        let bottomPlan = SidebarDragAutoScrollPlanner.plan(distanceToTop: 96, distanceToBottom: 4, edgeInset: 44, minStep: 2, maxStep: 12)
        XCTAssertEqual(bottomPlan?.direction, .down)
        XCTAssertNotNil(bottomPlan)

        XCTAssertNil(
            SidebarDragAutoScrollPlanner.plan(distanceToTop: 60, distanceToBottom: 60, edgeInset: 44, minStep: 2, maxStep: 12)
        )
    }

    func testAutoScrollPlanSpeedsUpCloserToEdge() {
        let nearTop = SidebarDragAutoScrollPlanner.plan(distanceToTop: 1, distanceToBottom: 99, edgeInset: 44, minStep: 2, maxStep: 12)
        let midTop = SidebarDragAutoScrollPlanner.plan(distanceToTop: 22, distanceToBottom: 78, edgeInset: 44, minStep: 2, maxStep: 12)

        XCTAssertNotNil(nearTop)
        XCTAssertNotNil(midTop)
        XCTAssertGreaterThan(nearTop?.pointsPerTick ?? 0, midTop?.pointsPerTick ?? 0)
    }

    func testAutoScrollPlanStillTriggersWhenPointerIsPastEdge() {
        let aboveTop = SidebarDragAutoScrollPlanner.plan(distanceToTop: -500, distanceToBottom: 600, edgeInset: 44, minStep: 2, maxStep: 12)
        XCTAssertEqual(aboveTop?.direction, .up)
        XCTAssertEqual(aboveTop?.pointsPerTick, 12)

        let belowBottom = SidebarDragAutoScrollPlanner.plan(distanceToTop: 600, distanceToBottom: -500, edgeInset: 44, minStep: 2, maxStep: 12)
        XCTAssertEqual(belowBottom?.direction, .down)
        XCTAssertEqual(belowBottom?.pointsPerTick, 12)
    }
}

final class FinderServicePathResolverTests: XCTestCase {
    func testOrderedUniqueDirectoriesUsesParentForFilesAndDedupes() {
        let input: [URL] = [
            URL(fileURLWithPath: "/tmp/cmux-services/project", isDirectory: true),
            URL(fileURLWithPath: "/tmp/cmux-services/project/README.md", isDirectory: false),
            URL(fileURLWithPath: "/tmp/cmux-services/../cmux-services/project", isDirectory: true),
            URL(fileURLWithPath: "/tmp/cmux-services/other", isDirectory: true),
        ]

        let directories = FinderServicePathResolver.orderedUniqueDirectories(from: input)
        XCTAssertEqual(
            directories,
            [
                "/tmp/cmux-services/project",
                "/tmp/cmux-services/other",
            ]
        )
    }

    func testOrderedUniqueDirectoriesPreservesFirstSeenOrder() {
        let input: [URL] = [
            URL(fileURLWithPath: "/tmp/cmux-services/b", isDirectory: true),
            URL(fileURLWithPath: "/tmp/cmux-services/a/file.txt", isDirectory: false),
            URL(fileURLWithPath: "/tmp/cmux-services/a", isDirectory: true),
            URL(fileURLWithPath: "/tmp/cmux-services/b/file.txt", isDirectory: false),
        ]

        let directories = FinderServicePathResolver.orderedUniqueDirectories(from: input)
        XCTAssertEqual(
            directories,
            [
                "/tmp/cmux-services/b",
                "/tmp/cmux-services/a",
            ]
        )
    }
}

final class TerminalDirectoryOpenTargetAvailabilityTests: XCTestCase {
    private func environment(
        existingPaths: Set<String>,
        homeDirectoryPath: String = "/Users/tester"
    ) -> TerminalDirectoryOpenTarget.DetectionEnvironment {
        TerminalDirectoryOpenTarget.DetectionEnvironment(
            homeDirectoryPath: homeDirectoryPath,
            fileExistsAtPath: { existingPaths.contains($0) }
        )
    }

    func testAvailableTargetsDetectSystemApplications() {
        let env = environment(
            existingPaths: [
                "/Applications/Visual Studio Code.app",
                "/System/Library/CoreServices/Finder.app",
                "/System/Applications/Utilities/Terminal.app",
                "/Applications/Zed Preview.app",
            ]
        )

        let availableTargets = TerminalDirectoryOpenTarget.availableTargets(in: env)
        XCTAssertTrue(availableTargets.contains(.vscode))
        XCTAssertTrue(availableTargets.contains(.finder))
        XCTAssertTrue(availableTargets.contains(.terminal))
        XCTAssertTrue(availableTargets.contains(.zed))
        XCTAssertFalse(availableTargets.contains(.cursor))
    }

    func testAvailableTargetsFallbackToUserApplications() {
        let env = environment(
            existingPaths: [
                "/Users/tester/Applications/Cursor.app",
                "/Users/tester/Applications/Warp.app",
                "/Users/tester/Applications/Android Studio.app",
            ]
        )

        let availableTargets = TerminalDirectoryOpenTarget.availableTargets(in: env)
        XCTAssertTrue(availableTargets.contains(.cursor))
        XCTAssertTrue(availableTargets.contains(.warp))
        XCTAssertTrue(availableTargets.contains(.androidStudio))
        XCTAssertFalse(availableTargets.contains(.vscode))
    }

    func testITerm2DetectsLegacyBundleName() {
        let env = environment(existingPaths: ["/Applications/iTerm.app"])
        XCTAssertTrue(TerminalDirectoryOpenTarget.iterm2.isAvailable(in: env))
    }

    func testCommandPaletteShortcutsExcludeGenericIDEEntry() {
        let targets = TerminalDirectoryOpenTarget.commandPaletteShortcutTargets
        XCTAssertFalse(targets.contains(where: { $0.commandPaletteTitle == "Open Current Directory in IDE" }))
        XCTAssertFalse(targets.contains(where: { $0.commandPaletteCommandId == "palette.terminalOpenDirectory" }))
    }
}

final class BrowserSearchEngineTests: XCTestCase {
    func testGoogleSearchURL() throws {
        let url = try XCTUnwrap(BrowserSearchEngine.google.searchURL(query: "hello world"))
        XCTAssertEqual(url.host, "www.google.com")
        XCTAssertEqual(url.path, "/search")
        XCTAssertTrue(url.absoluteString.contains("q=hello%20world"))
    }

    func testDuckDuckGoSearchURL() throws {
        let url = try XCTUnwrap(BrowserSearchEngine.duckduckgo.searchURL(query: "hello world"))
        XCTAssertEqual(url.host, "duckduckgo.com")
        XCTAssertEqual(url.path, "/")
        XCTAssertTrue(url.absoluteString.contains("q=hello%20world"))
    }

    func testBingSearchURL() throws {
        let url = try XCTUnwrap(BrowserSearchEngine.bing.searchURL(query: "hello world"))
        XCTAssertEqual(url.host, "www.bing.com")
        XCTAssertEqual(url.path, "/search")
        XCTAssertTrue(url.absoluteString.contains("q=hello%20world"))
    }
}

final class BrowserSearchSettingsTests: XCTestCase {
    func testCurrentSearchSuggestionsEnabledDefaultsToTrueWhenUnset() {
        let suiteName = "BrowserSearchSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.removeObject(forKey: BrowserSearchSettings.searchSuggestionsEnabledKey)
        XCTAssertTrue(BrowserSearchSettings.currentSearchSuggestionsEnabled(defaults: defaults))
    }

    func testCurrentSearchSuggestionsEnabledHonorsExplicitValue() {
        let suiteName = "BrowserSearchSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(false, forKey: BrowserSearchSettings.searchSuggestionsEnabledKey)
        XCTAssertFalse(BrowserSearchSettings.currentSearchSuggestionsEnabled(defaults: defaults))

        defaults.set(true, forKey: BrowserSearchSettings.searchSuggestionsEnabledKey)
        XCTAssertTrue(BrowserSearchSettings.currentSearchSuggestionsEnabled(defaults: defaults))
    }
}

final class BrowserHistoryStoreTests: XCTestCase {
    func testRecordVisitDedupesAndSuggests() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let fileURL = tempDir.appendingPathComponent("browser_history.json")
        let store = await MainActor.run { BrowserHistoryStore(fileURL: fileURL) }

        let u1 = try XCTUnwrap(URL(string: "https://example.com/foo"))
        let u2 = try XCTUnwrap(URL(string: "https://example.com/bar"))

        await MainActor.run {
            store.recordVisit(url: u1, title: "Example Foo")
            store.recordVisit(url: u2, title: "Example Bar")
            store.recordVisit(url: u1, title: "Example Foo Updated")
        }

        let suggestions = await MainActor.run { store.suggestions(for: "foo", limit: 10) }
        XCTAssertEqual(suggestions.first?.url, "https://example.com/foo")
        XCTAssertEqual(suggestions.first?.visitCount, 2)
        XCTAssertEqual(suggestions.first?.title, "Example Foo Updated")
    }

    func testSuggestionsLoadsPersistedHistoryImmediatelyOnFirstQuery() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let fileURL = tempDir.appendingPathComponent("browser_history.json")
        let now = Date()
        let seededEntries = [
            BrowserHistoryStore.Entry(
                id: UUID(),
                url: "https://go.dev/",
                title: "The Go Programming Language",
                lastVisited: now,
                visitCount: 3
            ),
            BrowserHistoryStore.Entry(
                id: UUID(),
                url: "https://www.google.com/",
                title: "Google",
                lastVisited: now.addingTimeInterval(-120),
                visitCount: 2
            ),
        ]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(seededEntries)
        try data.write(to: fileURL, options: [.atomic])

        let store = await MainActor.run { BrowserHistoryStore(fileURL: fileURL) }
        let suggestions = await MainActor.run { store.suggestions(for: "go", limit: 10) }

        XCTAssertGreaterThanOrEqual(suggestions.count, 2)
        XCTAssertEqual(suggestions.first?.url, "https://go.dev/")
        XCTAssertTrue(suggestions.contains(where: { $0.url == "https://www.google.com/" }))
    }
}

final class OmnibarStateMachineTests: XCTestCase {
    func testEscapeRevertsWhenEditingThenBlursOnSecondEscape() throws {
        var state = OmnibarState()

        var effects = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        XCTAssertTrue(state.isFocused)
        XCTAssertEqual(state.buffer, "https://example.com/")
        XCTAssertFalse(state.isUserEditing)
        XCTAssertTrue(effects.shouldSelectAll)

        effects = omnibarReduce(state: &state, event: .bufferChanged("exam"))
        XCTAssertTrue(state.isUserEditing)
        XCTAssertEqual(state.buffer, "exam")
        XCTAssertTrue(effects.shouldRefreshSuggestions)

        // Simulate an open popup.
        effects = omnibarReduce(
            state: &state,
            event: .suggestionsUpdated([.search(engineName: "Google", query: "exam")])
        )
        XCTAssertEqual(state.suggestions.count, 1)
        XCTAssertFalse(effects.shouldSelectAll)

        // First escape: revert + close popup + select-all.
        effects = omnibarReduce(state: &state, event: .escape)
        XCTAssertEqual(state.buffer, "https://example.com/")
        XCTAssertFalse(state.isUserEditing)
        XCTAssertTrue(state.suggestions.isEmpty)
        XCTAssertTrue(effects.shouldSelectAll)
        XCTAssertFalse(effects.shouldBlurToWebView)

        // Second escape: blur (since we're not editing and popup is closed).
        effects = omnibarReduce(state: &state, event: .escape)
        XCTAssertTrue(effects.shouldBlurToWebView)
    }

    func testPanelURLChangeDoesNotClobberUserBufferWhileEditing() throws {
        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://a.test/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("hello"))
        XCTAssertTrue(state.isUserEditing)

        _ = omnibarReduce(state: &state, event: .panelURLChanged(currentURLString: "https://b.test/"))
        XCTAssertEqual(state.currentURLString, "https://b.test/")
        XCTAssertEqual(state.buffer, "hello")
        XCTAssertTrue(state.isUserEditing)

        let effects = omnibarReduce(state: &state, event: .escape)
        XCTAssertEqual(state.buffer, "https://b.test/")
        XCTAssertTrue(effects.shouldSelectAll)
    }

    func testFocusLostRevertsUnlessSuppressed() throws {
        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("typed"))
        XCTAssertEqual(state.buffer, "typed")

        _ = omnibarReduce(state: &state, event: .focusLostPreserveBuffer(currentURLString: "https://example.com/"))
        XCTAssertEqual(state.buffer, "typed")

        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("typed2"))
        _ = omnibarReduce(state: &state, event: .focusLostRevertBuffer(currentURLString: "https://example.com/"))
        XCTAssertEqual(state.buffer, "https://example.com/")
    }

    func testSuggestionsUpdateKeepsSelectionAcrossNonEmptyListRefresh() throws {
        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("go"))

        let base: [OmnibarSuggestion] = [
            .search(engineName: "Google", query: "go"),
            .remoteSearchSuggestion("go tutorial"),
            .remoteSearchSuggestion("go json"),
        ]
        _ = omnibarReduce(state: &state, event: .suggestionsUpdated(base))
        XCTAssertEqual(state.selectedSuggestionIndex, 0)

        _ = omnibarReduce(state: &state, event: .moveSelection(delta: 2))
        XCTAssertEqual(state.selectedSuggestionIndex, 2)

        // Simulate remote merge update for the same query while popup remains open.
        let merged: [OmnibarSuggestion] = [
            .search(engineName: "Google", query: "go"),
            .remoteSearchSuggestion("go tutorial"),
            .remoteSearchSuggestion("go json"),
            .remoteSearchSuggestion("go fmt"),
        ]
        _ = omnibarReduce(state: &state, event: .suggestionsUpdated(merged))
        XCTAssertEqual(state.selectedSuggestionIndex, 2, "Expected selection to remain stable while list stays open")
    }

    func testSuggestionsReopenResetsSelectionToFirstRow() throws {
        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("go"))

        let rows: [OmnibarSuggestion] = [
            .search(engineName: "Google", query: "go"),
            .remoteSearchSuggestion("go tutorial"),
        ]
        _ = omnibarReduce(state: &state, event: .suggestionsUpdated(rows))
        _ = omnibarReduce(state: &state, event: .moveSelection(delta: 1))
        XCTAssertEqual(state.selectedSuggestionIndex, 1)

        _ = omnibarReduce(state: &state, event: .suggestionsUpdated([]))
        XCTAssertEqual(state.selectedSuggestionIndex, 0)

        _ = omnibarReduce(state: &state, event: .suggestionsUpdated(rows))
        XCTAssertEqual(state.selectedSuggestionIndex, 0, "Expected reopened popup to focus first row")
    }

    func testSuggestionsUpdatePrefersAutocompleteMatchWhenSelectionNotTracked() throws {
        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("gm"))

        let rows: [OmnibarSuggestion] = [
            .search(engineName: "Google", query: "gm"),
            .history(url: "https://google.com/", title: "Google"),
            .history(url: "https://gmail.com/", title: "Gmail"),
        ]
        _ = omnibarReduce(state: &state, event: .suggestionsUpdated(rows))
        XCTAssertEqual(state.selectedSuggestionIndex, 2, "Expected autocomplete candidate to become selected without explicit index state.")
        XCTAssertEqual(state.selectedSuggestionID, rows[2].id)
        XCTAssertTrue(omnibarSuggestionSupportsAutocompletion(query: "gm", suggestion: state.suggestions[state.selectedSuggestionIndex]))
        XCTAssertEqual(state.suggestions[state.selectedSuggestionIndex].completion, "https://gmail.com/")
    }
}

final class OmnibarRemoteSuggestionMergeTests: XCTestCase {
    func testMergeRemoteSuggestionsInsertsBelowSearchAndDedupes() {
        let now = Date()
        let entries: [BrowserHistoryStore.Entry] = [
            BrowserHistoryStore.Entry(
                id: UUID(),
                url: "https://go.dev/",
                title: "The Go Programming Language",
                lastVisited: now,
                visitCount: 10
            ),
        ]

        let merged = buildOmnibarSuggestions(
            query: "go",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [],
            remoteQueries: ["go tutorial", "go.dev", "go json"],
            resolvedURL: nil,
            limit: 8
        )

        let completions = merged.compactMap { $0.completion }
        XCTAssertGreaterThanOrEqual(completions.count, 5)
        XCTAssertEqual(completions[0], "https://go.dev/")
        XCTAssertEqual(completions[1], "go")

        let remoteCompletions = Array(completions.dropFirst(2))
        XCTAssertEqual(Set(remoteCompletions), Set(["go tutorial", "go.dev", "go json"]))
        XCTAssertEqual(remoteCompletions.count, 3)
    }

    func testStaleRemoteSuggestionsKeptForNearbyEdits() {
        let stale = staleOmnibarRemoteSuggestionsForDisplay(
            query: "go t",
            previousRemoteQuery: "go",
            previousRemoteSuggestions: ["go tutorial", "go json", "golang tips"],
            limit: 8
        )

        XCTAssertEqual(stale, ["go tutorial", "go json", "golang tips"])
    }

    func testStaleRemoteSuggestionsTrimAndRespectLimit() {
        let stale = staleOmnibarRemoteSuggestionsForDisplay(
            query: "gooo",
            previousRemoteQuery: "goo",
            previousRemoteSuggestions: [" go tutorial ", "", "go json", "   ", "go fmt"],
            limit: 2
        )

        XCTAssertEqual(stale, ["go tutorial", "go json"])
    }

    func testStaleRemoteSuggestionsDroppedForUnrelatedQuery() {
        let stale = staleOmnibarRemoteSuggestionsForDisplay(
            query: "python",
            previousRemoteQuery: "go",
            previousRemoteSuggestions: ["go tutorial", "go json"],
            limit: 8
        )

        XCTAssertTrue(stale.isEmpty)
    }
}

final class OmnibarSuggestionRankingTests: XCTestCase {
    private var fixedNow: Date {
        Date(timeIntervalSinceReferenceDate: 10_000_000)
    }

    func testSingleCharacterQueryPromotesAutocompletionMatchToFirstRow() {
        let entries: [BrowserHistoryStore.Entry] = [
            .init(
                id: UUID(),
                url: "https://news.ycombinator.com/",
                title: "News.YC",
                lastVisited: fixedNow,
                visitCount: 12,
                typedCount: 1,
                lastTypedAt: fixedNow
            ),
            .init(
                id: UUID(),
                url: "https://www.google.com/",
                title: "Google",
                lastVisited: fixedNow - 200,
                visitCount: 8,
                typedCount: 2,
                lastTypedAt: fixedNow - 200
            ),
        ]

        let results = buildOmnibarSuggestions(
            query: "n",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [],
            remoteQueries: ["search google for n", "news"],
            resolvedURL: nil,
            limit: 8,
            now: fixedNow
        )

        XCTAssertEqual(results.first?.completion, "https://news.ycombinator.com/")
        XCTAssertNotEqual(results.map(\.completion).first, "n")
        XCTAssertTrue(results.first.map { omnibarSuggestionSupportsAutocompletion(query: "n", suggestion: $0) } ?? false)
    }

    func testGmAutocompleteCandidateIsFirstOnExactQueryMatch() {
        let entries: [BrowserHistoryStore.Entry] = [
            .init(
                id: UUID(),
                url: "https://google.com/",
                title: "Google",
                lastVisited: fixedNow,
                visitCount: 4,
                typedCount: 1,
                lastTypedAt: fixedNow
            ),
            .init(
                id: UUID(),
                url: "https://gmail.com/",
                title: "Gmail",
                lastVisited: fixedNow,
                visitCount: 10,
                typedCount: 2,
                lastTypedAt: fixedNow
            ),
        ]

        let results = buildOmnibarSuggestions(
            query: "gm",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [],
            remoteQueries: ["gmail", "gmail.com", "google mail"],
            resolvedURL: nil,
            limit: 8,
            now: fixedNow
        )

        XCTAssertEqual(results.first?.completion, "https://gmail.com/")
        XCTAssertTrue(omnibarSuggestionSupportsAutocompletion(query: "gm", suggestion: results[0]))

        let inlineCompletion = omnibarInlineCompletionForDisplay(
            typedText: "gm",
            suggestions: results,
            isFocused: true,
            selectionRange: NSRange(location: 2, length: 0),
            hasMarkedText: false
        )
        XCTAssertNotNil(inlineCompletion)
    }

    func testAutocompletionCandidateWinsOverRemoteAndSearchRowsForTwoLetterQuery() {
        let entries: [BrowserHistoryStore.Entry] = [
            .init(
                id: UUID(),
                url: "https://google.com/",
                title: "Google",
                lastVisited: fixedNow,
                visitCount: 4,
                typedCount: 1,
                lastTypedAt: fixedNow
            ),
            .init(
                id: UUID(),
                url: "https://gmail.com/",
                title: "Gmail",
                lastVisited: fixedNow,
                visitCount: 10,
                typedCount: 2,
                lastTypedAt: fixedNow
            ),
        ]

        let results = buildOmnibarSuggestions(
            query: "gm",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [
                .init(
                    tabId: UUID(),
                    panelId: UUID(),
                    url: "https://gmail.com/",
                    title: "Gmail",
                    isKnownOpenTab: true
                ),
            ],
            remoteQueries: ["Search google for gm", "gmail", "gmail.com", "Google mail"],
            resolvedURL: nil,
            limit: 8,
            now: fixedNow
        )

        XCTAssertTrue(omnibarSuggestionSupportsAutocompletion(query: "gm", suggestion: results[0]))
        XCTAssertEqual(results.first?.completion, "https://gmail.com/")
    }

    func testSuggestionSelectionPrefersAutocompletionCandidateAfterSuggestionsUpdate() {
        let entries: [BrowserHistoryStore.Entry] = [
            .init(
                id: UUID(),
                url: "https://google.com/",
                title: "Google",
                lastVisited: fixedNow,
                visitCount: 4,
                typedCount: 1,
                lastTypedAt: fixedNow
            ),
            .init(
                id: UUID(),
                url: "https://gmail.com/",
                title: "Gmail",
                lastVisited: fixedNow,
                visitCount: 10,
                typedCount: 2,
                lastTypedAt: fixedNow
            ),
        ]

        let results = buildOmnibarSuggestions(
            query: "gm",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [],
            remoteQueries: ["Search google for gm", "gmail", "gmail.com"],
            resolvedURL: nil,
            limit: 8,
            now: fixedNow
        )

        var state = OmnibarState()
        let _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: ""))
        let _ = omnibarReduce(state: &state, event: .bufferChanged("gm"))
        let _ = omnibarReduce(state: &state, event: .suggestionsUpdated(results))

        XCTAssertEqual(state.selectedSuggestionIndex, 0)
        XCTAssertEqual(state.selectedSuggestionID, results[0].id)
        XCTAssertTrue(omnibarSuggestionSupportsAutocompletion(query: "gm", suggestion: state.suggestions[0]))
    }

    func testTwoCharQueryWithRemoteSuggestionsStillPromotesAutocompletionMatch() {
        let entries: [BrowserHistoryStore.Entry] = [
            .init(
                id: UUID(),
                url: "https://news.ycombinator.com/",
                title: "News.YC",
                lastVisited: fixedNow,
                visitCount: 12,
                typedCount: 1,
                lastTypedAt: fixedNow
            ),
            .init(
                id: UUID(),
                url: "https://www.google.com/",
                title: "Google",
                lastVisited: fixedNow - 200,
                visitCount: 8,
                typedCount: 2,
                lastTypedAt: fixedNow - 200
            ),
        ]

        let results = buildOmnibarSuggestions(
            query: "ne",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [],
            remoteQueries: ["netflix", "new york times", "newegg"],
            resolvedURL: nil,
            limit: 8,
            now: fixedNow
        )

        // The autocompletable history entry (news.ycombinator.com) should be first despite remote results.
        XCTAssertEqual(results.first?.completion, "https://news.ycombinator.com/")
        XCTAssertTrue(results.first.map { omnibarSuggestionSupportsAutocompletion(query: "ne", suggestion: $0) } ?? false)

        // Remote suggestions should still appear in the results (two-char queries include them).
        let remoteCompletions = results.filter {
            if case .remote = $0.kind { return true }
            return false
        }.map(\.completion)
        XCTAssertFalse(remoteCompletions.isEmpty, "Expected remote suggestions to be present for two-char query")
    }

    func testGmQueryWithRemoteSuggestionsAndOpenTabPromotesAutocompletionMatch() {
        let entries: [BrowserHistoryStore.Entry] = [
            .init(
                id: UUID(),
                url: "https://google.com/",
                title: "Google",
                lastVisited: fixedNow,
                visitCount: 4,
                typedCount: 1,
                lastTypedAt: fixedNow
            ),
            .init(
                id: UUID(),
                url: "https://gmail.com/",
                title: "Gmail",
                lastVisited: fixedNow,
                visitCount: 10,
                typedCount: 2,
                lastTypedAt: fixedNow
            ),
        ]

        let results = buildOmnibarSuggestions(
            query: "gm",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [
                .init(
                    tabId: UUID(),
                    panelId: UUID(),
                    url: "https://google.com/maps",
                    title: "Google Maps",
                    isKnownOpenTab: true
                ),
            ],
            remoteQueries: ["gmail login", "gm stock price", "gmail.com"],
            resolvedURL: nil,
            limit: 8,
            now: fixedNow
        )

        // Gmail should be first (autocompletable + typed history).
        XCTAssertEqual(results.first?.completion, "https://gmail.com/")
        XCTAssertTrue(omnibarSuggestionSupportsAutocompletion(query: "gm", suggestion: results[0]))

        // Verify remote suggestions are present alongside history/tab matches.
        let remoteCompletions = results.filter {
            if case .remote = $0.kind { return true }
            return false
        }.map(\.completion)
        XCTAssertFalse(remoteCompletions.isEmpty, "Expected remote suggestions in results")
        let hasSearch = results.contains {
            if case .search = $0.kind { return true }
            return false
        }
        XCTAssertTrue(hasSearch, "Expected search row in results")
    }

    func testHistorySuggestionDisplaysTitleAndUrlOnSingleLine() {
        let row = OmnibarSuggestion.history(
            url: "https://www.example.com/path?q=1",
            title: "Example Domain"
        )
        XCTAssertEqual(row.listText, "Example Domain — example.com/path?q=1")
        XCTAssertFalse(row.listText.contains("\n"))
    }

    func testPublishedBufferTextUsesTypedPrefixWhenInlineSuffixIsSelected() {
        let inline = OmnibarInlineCompletion(
            typedText: "l",
            displayText: "localhost:3000",
            acceptedText: "https://localhost:3000/"
        )

        let published = omnibarPublishedBufferTextForFieldChange(
            fieldValue: inline.displayText,
            inlineCompletion: inline,
            selectionRange: inline.suffixRange,
            hasMarkedText: false
        )

        XCTAssertEqual(published, "l")
    }

    func testPublishedBufferTextKeepsUserTypedValueWhenDisplayDiffersFromInlineText() {
        let inline = OmnibarInlineCompletion(
            typedText: "l",
            displayText: "localhost:3000",
            acceptedText: "https://localhost:3000/"
        )

        let published = omnibarPublishedBufferTextForFieldChange(
            fieldValue: "la",
            inlineCompletion: inline,
            selectionRange: NSRange(location: 2, length: 0),
            hasMarkedText: false
        )

        XCTAssertEqual(published, "la")
    }

    func testInlineCompletionRenderIgnoresStaleTypedPrefixMismatch() {
        let staleInline = OmnibarInlineCompletion(
            typedText: "g",
            displayText: "github.com",
            acceptedText: "https://github.com/"
        )

        let active = omnibarInlineCompletionIfBufferMatchesTypedPrefix(
            bufferText: "l",
            inlineCompletion: staleInline
        )

        XCTAssertNil(active)
    }

    func testInlineCompletionRenderKeepsMatchingTypedPrefix() {
        let inline = OmnibarInlineCompletion(
            typedText: "l",
            displayText: "localhost:3000",
            acceptedText: "https://localhost:3000/"
        )

        let active = omnibarInlineCompletionIfBufferMatchesTypedPrefix(
            bufferText: "l",
            inlineCompletion: inline
        )

        XCTAssertEqual(active, inline)
    }

    func testInlineCompletionSkipsTitleMatchWhoseURLDoesNotStartWithTypedText() {
        // History entry: visited google.com/search?q=localhost:3000 with title
        // "localhost:3000 - Google Search". Typing "l" should NOT inline-complete
        // to "google.com/..." because that replaces the typed "l" with "g".
        let suggestions: [OmnibarSuggestion] = [
            .history(
                url: "https://www.google.com/search?q=localhost:3000",
                title: "localhost:3000 - Google Search"
            ),
        ]

        let result = omnibarInlineCompletionForDisplay(
            typedText: "l",
            suggestions: suggestions,
            isFocused: true,
            selectionRange: NSRange(location: 1, length: 0),
            hasMarkedText: false
        )

        XCTAssertNil(result, "Should not inline-complete when display text does not start with typed prefix")
    }
}

@MainActor
final class NotificationDockBadgeTests: XCTestCase {
    private final class NotificationSettingsAlertSpy: NSAlert {
        private(set) var beginSheetModalCallCount = 0
        private(set) var runModalCallCount = 0
        var nextResponse: NSApplication.ModalResponse = .alertFirstButtonReturn

        override func beginSheetModal(
            for sheetWindow: NSWindow,
            completionHandler handler: ((NSApplication.ModalResponse) -> Void)?
        ) {
            beginSheetModalCallCount += 1
            handler?(nextResponse)
        }

        override func runModal() -> NSApplication.ModalResponse {
            runModalCallCount += 1
            return nextResponse
        }
    }

    override func tearDown() {
        TerminalNotificationStore.shared.resetNotificationSettingsPromptHooksForTesting()
        super.tearDown()
    }

    func testDockBadgeLabelEnabledAndCounted() {
        XCTAssertEqual(TerminalNotificationStore.dockBadgeLabel(unreadCount: 1, isEnabled: true), "1")
        XCTAssertEqual(TerminalNotificationStore.dockBadgeLabel(unreadCount: 42, isEnabled: true), "42")
        XCTAssertEqual(TerminalNotificationStore.dockBadgeLabel(unreadCount: 100, isEnabled: true), "99+")
    }

    func testDockBadgeLabelHiddenWhenDisabledOrZero() {
        XCTAssertNil(TerminalNotificationStore.dockBadgeLabel(unreadCount: 0, isEnabled: true))
        XCTAssertNil(TerminalNotificationStore.dockBadgeLabel(unreadCount: 5, isEnabled: false))
    }

    func testDockBadgeLabelShowsRunTagEvenWithoutUnread() {
        XCTAssertEqual(
            TerminalNotificationStore.dockBadgeLabel(unreadCount: 0, isEnabled: true, runTag: "verify-tag"),
            "verify-tag"
        )
    }

    func testDockBadgeLabelCombinesRunTagAndUnreadCount() {
        XCTAssertEqual(
            TerminalNotificationStore.dockBadgeLabel(unreadCount: 7, isEnabled: true, runTag: "verify"),
            "verify:7"
        )
        XCTAssertEqual(
            TerminalNotificationStore.dockBadgeLabel(unreadCount: 120, isEnabled: true, runTag: "verify"),
            "verify:99+"
        )
    }

    func testNotificationBadgePreferenceDefaultsToEnabled() {
        let suiteName = "NotificationDockBadgeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertTrue(NotificationBadgeSettings.isDockBadgeEnabled(defaults: defaults))

        defaults.set(false, forKey: NotificationBadgeSettings.dockBadgeEnabledKey)
        XCTAssertFalse(NotificationBadgeSettings.isDockBadgeEnabled(defaults: defaults))

        defaults.set(true, forKey: NotificationBadgeSettings.dockBadgeEnabledKey)
        XCTAssertTrue(NotificationBadgeSettings.isDockBadgeEnabled(defaults: defaults))
    }

    func testNotificationSettingsPromptUsesSheetAndNeverRunsModal() {
        let store = TerminalNotificationStore.shared
        let alertSpy = NotificationSettingsAlertSpy()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        var openedURL: URL?
        store.configureNotificationSettingsPromptHooksForTesting(
            windowProvider: { window },
            alertFactory: { alertSpy },
            scheduler: { _, block in block() },
            urlOpener: { openedURL = $0 }
        )

        store.promptToEnableNotificationsForTesting()
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)

        XCTAssertEqual(alertSpy.beginSheetModalCallCount, 1)
        XCTAssertEqual(alertSpy.runModalCallCount, 0)
        XCTAssertEqual(
            openedURL?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.notifications"
        )
    }

    func testNotificationSettingsPromptRetriesUntilWindowExists() {
        let store = TerminalNotificationStore.shared
        let alertSpy = NotificationSettingsAlertSpy()
        alertSpy.nextResponse = .alertSecondButtonReturn

        var queuedRetryBlocks: [() -> Void] = []
        var promptWindow: NSWindow?
        store.configureNotificationSettingsPromptHooksForTesting(
            windowProvider: { promptWindow },
            alertFactory: { alertSpy },
            scheduler: { _, block in queuedRetryBlocks.append(block) },
            urlOpener: { _ in XCTFail("Should not open settings for Not Now response") }
        )

        store.promptToEnableNotificationsForTesting()
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)

        XCTAssertEqual(alertSpy.beginSheetModalCallCount, 0)
        XCTAssertEqual(alertSpy.runModalCallCount, 0)
        XCTAssertEqual(queuedRetryBlocks.count, 1)

        promptWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        queuedRetryBlocks.removeFirst()()

        XCTAssertEqual(alertSpy.beginSheetModalCallCount, 1)
        XCTAssertEqual(alertSpy.runModalCallCount, 0)
    }
}


final class MenuBarBadgeLabelFormatterTests: XCTestCase {
    func testBadgeLabelFormatting() {
        XCTAssertNil(MenuBarBadgeLabelFormatter.badgeText(for: 0))
        XCTAssertEqual(MenuBarBadgeLabelFormatter.badgeText(for: 1), "1")
        XCTAssertEqual(MenuBarBadgeLabelFormatter.badgeText(for: 9), "9")
        XCTAssertEqual(MenuBarBadgeLabelFormatter.badgeText(for: 10), "9+")
        XCTAssertEqual(MenuBarBadgeLabelFormatter.badgeText(for: 47), "9+")
    }
}

final class NotificationMenuSnapshotBuilderTests: XCTestCase {
    func testSnapshotCountsUnreadAndLimitsRecentItems() {
        let notifications = (0..<8).map { index in
            TerminalNotification(
                id: UUID(),
                tabId: UUID(),
                surfaceId: nil,
                title: "N\(index)",
                subtitle: "",
                body: "",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                isRead: index.isMultiple(of: 2)
            )
        }

        let snapshot = NotificationMenuSnapshotBuilder.make(
            notifications: notifications,
            maxInlineNotificationItems: 3
        )

        XCTAssertEqual(snapshot.unreadCount, 4)
        XCTAssertTrue(snapshot.hasNotifications)
        XCTAssertTrue(snapshot.hasUnreadNotifications)
        XCTAssertEqual(snapshot.recentNotifications.count, 3)
        XCTAssertEqual(snapshot.recentNotifications.map(\.id), Array(notifications.prefix(3)).map(\.id))
    }

    func testStateHintTitleHandlesSingularPluralAndZero() {
        XCTAssertEqual(NotificationMenuSnapshotBuilder.stateHintTitle(unreadCount: 0), "No unread notifications")
        XCTAssertEqual(NotificationMenuSnapshotBuilder.stateHintTitle(unreadCount: 1), "1 unread notification")
        XCTAssertEqual(NotificationMenuSnapshotBuilder.stateHintTitle(unreadCount: 2), "2 unread notifications")
    }
}

final class MenuBarBuildHintFormatterTests: XCTestCase {
    func testReleaseBuildShowsNoHint() {
        XCTAssertNil(MenuBarBuildHintFormatter.menuTitle(appName: "cmux DEV menubar-extra", isDebugBuild: false))
    }

    func testDebugBuildWithTagShowsTag() {
        XCTAssertEqual(
            MenuBarBuildHintFormatter.menuTitle(appName: "cmux DEV menubar-extra", isDebugBuild: true),
            "Build Tag: menubar-extra"
        )
    }

    func testDebugBuildWithoutTagShowsUntagged() {
        XCTAssertEqual(
            MenuBarBuildHintFormatter.menuTitle(appName: "cmux DEV", isDebugBuild: true),
            "Build: DEV (untagged)"
        )
    }
}

final class MenuBarNotificationLineFormatterTests: XCTestCase {
    func testPlainTitleContainsUnreadDotBodyAndTab() {
        let notification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: "Build finished",
            subtitle: "",
            body: "All checks passed",
            createdAt: Date(timeIntervalSince1970: 0),
            isRead: false
        )

        let line = MenuBarNotificationLineFormatter.plainTitle(notification: notification, tabTitle: "workspace-1")
        XCTAssertTrue(line.hasPrefix("● Build finished"))
        XCTAssertTrue(line.contains("All checks passed"))
        XCTAssertTrue(line.contains("workspace-1"))
    }

    func testPlainTitleFallsBackToSubtitleWhenBodyEmpty() {
        let notification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: "Deploy",
            subtitle: "staging",
            body: "",
            createdAt: Date(timeIntervalSince1970: 0),
            isRead: true
        )

        let line = MenuBarNotificationLineFormatter.plainTitle(notification: notification, tabTitle: nil)
        XCTAssertTrue(line.hasPrefix("  Deploy"))
        XCTAssertTrue(line.contains("staging"))
    }

    func testMenuTitleWrapsAndTruncatesToThreeLines() {
        let notification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: "Extremely long notification title for wrapping behavior validation",
            subtitle: "",
            body: Array(repeating: "this body should wrap and eventually truncate", count: 8).joined(separator: " "),
            createdAt: Date(timeIntervalSince1970: 0),
            isRead: false
        )

        let title = MenuBarNotificationLineFormatter.menuTitle(
            notification: notification,
            tabTitle: "workspace-with-a-very-long-name",
            maxWidth: 120,
            maxLines: 3
        )

        XCTAssertLessThanOrEqual(title.components(separatedBy: "\n").count, 3)
        XCTAssertTrue(title.hasSuffix("…"))
    }

    func testMenuTitlePreservesShortTextWithoutEllipsis() {
        let notification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: "Done",
            subtitle: "",
            body: "All checks passed",
            createdAt: Date(timeIntervalSince1970: 0),
            isRead: false
        )

        let title = MenuBarNotificationLineFormatter.menuTitle(
            notification: notification,
            tabTitle: "w1",
            maxWidth: 320,
            maxLines: 3
        )

        XCTAssertFalse(title.hasSuffix("…"))
    }
}


final class MenuBarIconDebugSettingsTests: XCTestCase {
    func testDisplayedUnreadCountUsesPreviewOverrideWhenEnabled() {
        let suiteName = "MenuBarIconDebugSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: MenuBarIconDebugSettings.previewEnabledKey)
        defaults.set(7, forKey: MenuBarIconDebugSettings.previewCountKey)

        XCTAssertEqual(MenuBarIconDebugSettings.displayedUnreadCount(actualUnreadCount: 2, defaults: defaults), 7)
    }

    func testBadgeRenderConfigClampsInvalidValues() {
        let suiteName = "MenuBarIconDebugSettingsTests.Clamp.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(-100, forKey: MenuBarIconDebugSettings.badgeRectXKey)
        defaults.set(200, forKey: MenuBarIconDebugSettings.badgeRectYKey)
        defaults.set(-100, forKey: MenuBarIconDebugSettings.singleDigitFontSizeKey)
        defaults.set(100, forKey: MenuBarIconDebugSettings.multiDigitXAdjustKey)

        let config = MenuBarIconDebugSettings.badgeRenderConfig(defaults: defaults)
        XCTAssertEqual(config.badgeRect.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(config.badgeRect.origin.y, 20, accuracy: 0.001)
        XCTAssertEqual(config.singleDigitFontSize, 6, accuracy: 0.001)
        XCTAssertEqual(config.multiDigitXAdjust, 4, accuracy: 0.001)
    }

    func testBadgeRenderConfigUsesLegacySingleDigitXAdjustWhenNewKeyMissing() {
        let suiteName = "MenuBarIconDebugSettingsTests.LegacyX.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(2.5, forKey: MenuBarIconDebugSettings.legacySingleDigitXAdjustKey)

        let config = MenuBarIconDebugSettings.badgeRenderConfig(defaults: defaults)
        XCTAssertEqual(config.singleDigitXAdjust, 2.5, accuracy: 0.001)
    }
}

@MainActor

final class MenuBarIconRendererTests: XCTestCase {
    func testImageWidthDoesNotShiftWhenBadgeAppears() {
        let noBadge = MenuBarIconRenderer.makeImage(unreadCount: 0)
        let withBadge = MenuBarIconRenderer.makeImage(unreadCount: 2)

        XCTAssertEqual(noBadge.size.width, 18, accuracy: 0.001)
        XCTAssertEqual(withBadge.size.width, 18, accuracy: 0.001)
    }
}

final class WorkspaceMountPolicyTests: XCTestCase {
    func testDefaultPolicyMountsOnlySelectedWorkspace() {
        let a = UUID()
        let b = UUID()
        let orderedTabIds: [UUID] = [a, b]

        let next = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: [a],
            selected: b,
            pinnedIds: [],
            orderedTabIds: orderedTabIds,
            isCycleHot: false,
            maxMounted: WorkspaceMountPolicy.maxMountedWorkspaces
        )

        XCTAssertEqual(next, [b])
    }

    func testSelectedWorkspaceMovesToFrontAndMountCountIsBounded() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let orderedTabIds: [UUID] = [a, b, c]

        let next = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: [a, b, c],
            selected: c,
            pinnedIds: [],
            orderedTabIds: orderedTabIds,
            isCycleHot: false,
            maxMounted: 2
        )

        XCTAssertEqual(next, [c, a])
    }

    func testMissingWorkspacesArePruned() {
        let a = UUID()
        let b = UUID()

        let next = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: [b, a],
            selected: nil,
            pinnedIds: [],
            orderedTabIds: [a],
            isCycleHot: false,
            maxMounted: 2
        )

        XCTAssertEqual(next, [a])
    }

    func testSelectedWorkspaceIsInsertedWhenAbsentFromCurrentCache() {
        let a = UUID()
        let b = UUID()
        let orderedTabIds: [UUID] = [a, b]

        let next = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: [a],
            selected: b,
            pinnedIds: [],
            orderedTabIds: orderedTabIds,
            isCycleHot: false,
            maxMounted: 2
        )

        XCTAssertEqual(next, [b, a])
    }

    func testMaxMountedIsClampedToAtLeastOne() {
        let a = UUID()
        let b = UUID()
        let orderedTabIds: [UUID] = [a, b]

        let next = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: [a, b],
            selected: nil,
            pinnedIds: [],
            orderedTabIds: orderedTabIds,
            isCycleHot: false,
            maxMounted: 0
        )

        XCTAssertEqual(next, [a])
    }

    func testCycleHotModeKeepsOnlySelectedWhenNoPinnedHandoff() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let d = UUID()
        let orderedTabIds: [UUID] = [a, b, c, d]

        let next = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: [a],
            selected: c,
            pinnedIds: [],
            orderedTabIds: orderedTabIds,
            isCycleHot: true,
            maxMounted: WorkspaceMountPolicy.maxMountedWorkspacesDuringCycle
        )

        XCTAssertEqual(next, [c])
    }

    func testCycleHotModeRespectsMaxMountedLimit() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let orderedTabIds: [UUID] = [a, b, c]

        let next = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: [a, b, c],
            selected: b,
            pinnedIds: [],
            orderedTabIds: orderedTabIds,
            isCycleHot: true,
            maxMounted: 2
        )

        XCTAssertEqual(next, [b])
    }

    func testPinnedIdsAreRetainedAcrossReconcile() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let orderedTabIds: [UUID] = [a, b, c]

        let next = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: [a],
            selected: c,
            pinnedIds: [a],
            orderedTabIds: orderedTabIds,
            isCycleHot: false,
            maxMounted: 2
        )

        XCTAssertEqual(next, [c, a])
    }

    func testCycleHotModeKeepsRetiringWorkspaceWhenPinned() {
        let a = UUID()
        let b = UUID()
        let orderedTabIds: [UUID] = [a, b]

        let next = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: [a],
            selected: b,
            pinnedIds: [a],
            orderedTabIds: orderedTabIds,
            isCycleHot: true,
            maxMounted: WorkspaceMountPolicy.maxMountedWorkspacesDuringCycle
        )

        XCTAssertEqual(next, [b, a])
    }
}

@MainActor
final class WindowTerminalHostViewTests: XCTestCase {
    private final class CapturingView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class BonsplitMockSplitDelegate: NSObject, NSSplitViewDelegate {}

    func testHostViewPassesThroughWhenNoTerminalSubviewIsHit() {
        let host = WindowTerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))

        XCTAssertNil(host.hitTest(NSPoint(x: 10, y: 10)))
    }

    func testHostViewReturnsSubviewWhenSubviewIsHit() {
        let host = WindowTerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let child = CapturingView(frame: NSRect(x: 20, y: 15, width: 40, height: 30))
        host.addSubview(child)

        XCTAssertTrue(host.hitTest(NSPoint(x: 25, y: 20)) === child)
        XCTAssertNil(host.hitTest(NSPoint(x: 150, y: 100)))
    }

    func testHostViewPassesThroughDividerWhenAdjacentPaneIsCollapsed() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let splitView = NSSplitView(frame: contentView.bounds)
        splitView.autoresizingMask = [.width, .height]
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let splitDelegate = BonsplitMockSplitDelegate()
        splitView.delegate = splitDelegate
        let first = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: contentView.bounds.height))
        let second = NSView(frame: NSRect(x: 121, y: 0, width: 179, height: contentView.bounds.height))
        splitView.addSubview(first)
        splitView.addSubview(second)
        contentView.addSubview(splitView)
        splitView.setPosition(1, ofDividerAt: 0)
        splitView.adjustSubviews()
        contentView.layoutSubtreeIfNeeded()

        let host = WindowTerminalHostView(frame: contentView.bounds)
        host.autoresizingMask = [.width, .height]
        let child = CapturingView(frame: host.bounds)
        child.autoresizingMask = [.width, .height]
        host.addSubview(child)
        contentView.addSubview(host)

        let dividerPointInSplit = NSPoint(
            x: splitView.arrangedSubviews[0].frame.maxX + (splitView.dividerThickness * 0.5),
            y: splitView.bounds.midY
        )
        let dividerPointInWindow = splitView.convert(dividerPointInSplit, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)
        XCTAssertLessThanOrEqual(splitView.arrangedSubviews[0].frame.width, 1.5)
        XCTAssertNil(
            host.hitTest(dividerPointInHost),
            "Host view must pass through divider hits even when one pane is nearly collapsed"
        )

        let contentPointInSplit = NSPoint(x: dividerPointInSplit.x + 40, y: splitView.bounds.midY)
        let contentPointInWindow = splitView.convert(contentPointInSplit, to: nil)
        let contentPointInHost = host.convert(contentPointInWindow, from: nil)
        XCTAssertTrue(host.hitTest(contentPointInHost) === child)
    }
}

@MainActor
final class WindowBrowserHostViewTests: XCTestCase {
    private final class CapturingView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class BonsplitMockSplitDelegate: NSObject, NSSplitViewDelegate {}

    func testHostViewPassesThroughDividerWhenAdjacentPaneIsCollapsed() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let splitView = NSSplitView(frame: contentView.bounds)
        splitView.autoresizingMask = [.width, .height]
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let splitDelegate = BonsplitMockSplitDelegate()
        splitView.delegate = splitDelegate
        let first = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: contentView.bounds.height))
        let second = NSView(frame: NSRect(x: 121, y: 0, width: 179, height: contentView.bounds.height))
        splitView.addSubview(first)
        splitView.addSubview(second)
        contentView.addSubview(splitView)
        splitView.setPosition(1, ofDividerAt: 0)
        splitView.adjustSubviews()
        contentView.layoutSubtreeIfNeeded()

        let host = WindowBrowserHostView(frame: contentView.bounds)
        host.autoresizingMask = [.width, .height]
        let child = CapturingView(frame: host.bounds)
        child.autoresizingMask = [.width, .height]
        host.addSubview(child)
        contentView.addSubview(host)

        let dividerPointInSplit = NSPoint(
            x: splitView.arrangedSubviews[0].frame.maxX + (splitView.dividerThickness * 0.5),
            y: splitView.bounds.midY
        )
        let dividerPointInWindow = splitView.convert(dividerPointInSplit, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)
        XCTAssertLessThanOrEqual(splitView.arrangedSubviews[0].frame.width, 1.5)
        XCTAssertNil(
            host.hitTest(dividerPointInHost),
            "Browser host must pass through divider hits even when one pane is nearly collapsed"
        )

        let contentPointInSplit = NSPoint(x: dividerPointInSplit.x + 40, y: splitView.bounds.midY)
        let contentPointInWindow = splitView.convert(contentPointInSplit, to: nil)
        let contentPointInHost = host.convert(contentPointInWindow, from: nil)
        XCTAssertTrue(host.hitTest(contentPointInHost) === child)
    }
}

@MainActor
final class WindowDragHandleHitTests: XCTestCase {
    private final class CapturingView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class HostContainerView: NSView {}
    private final class BlockingTopHitContainerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }
    private final class PassThroughProbeView: NSView {
        var onHitTest: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(point) else { return nil }
            onHitTest?()
            return nil
        }
    }
    private final class PassiveHostContainerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(point) else { return nil }
            return super.hitTest(point) ?? self
        }
    }

    func testDragHandleCapturesHitWhenNoSiblingClaimsPoint() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        XCTAssertTrue(
            windowDragHandleShouldCaptureHit(NSPoint(x: 180, y: 18), in: dragHandle),
            "Empty titlebar space should drag the window"
        )
    }

    func testDragHandleYieldsWhenSiblingClaimsPoint() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let folderIconHost = CapturingView(frame: NSRect(x: 10, y: 10, width: 16, height: 16))
        container.addSubview(folderIconHost)

        XCTAssertFalse(
            windowDragHandleShouldCaptureHit(NSPoint(x: 14, y: 14), in: dragHandle),
            "Interactive titlebar controls should receive the mouse event"
        )
        XCTAssertTrue(windowDragHandleShouldCaptureHit(NSPoint(x: 180, y: 18), in: dragHandle))
    }

    func testDragHandleIgnoresHiddenSiblingWhenResolvingHit() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let hidden = CapturingView(frame: NSRect(x: 10, y: 10, width: 16, height: 16))
        hidden.isHidden = true
        container.addSubview(hidden)

        XCTAssertTrue(windowDragHandleShouldCaptureHit(NSPoint(x: 14, y: 14), in: dragHandle))
    }

    func testDragHandleDoesNotCaptureOutsideBounds() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        XCTAssertFalse(windowDragHandleShouldCaptureHit(NSPoint(x: 240, y: 18), in: dragHandle))
    }

    func testPassiveHostingTopHitClassification() {
        XCTAssertTrue(windowDragHandleShouldTreatTopHitAsPassiveHost(HostContainerView(frame: .zero)))
        XCTAssertFalse(windowDragHandleShouldTreatTopHitAsPassiveHost(NSButton(frame: .zero)))
    }

    func testDragHandleIgnoresPassiveHostSiblingHit() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let passiveHost = PassiveHostContainerView(frame: container.bounds)
        container.addSubview(passiveHost)

        XCTAssertTrue(
            windowDragHandleShouldCaptureHit(NSPoint(x: 180, y: 18), in: dragHandle),
            "Passive host wrappers should not block titlebar drag capture"
        )
    }

    func testDragHandleRespectsInteractiveChildInsidePassiveHost() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let passiveHost = PassiveHostContainerView(frame: container.bounds)
        let folderControl = CapturingView(frame: NSRect(x: 10, y: 10, width: 16, height: 16))
        passiveHost.addSubview(folderControl)
        container.addSubview(passiveHost)

        XCTAssertFalse(
            windowDragHandleShouldCaptureHit(NSPoint(x: 14, y: 14), in: dragHandle),
            "Interactive controls inside passive host wrappers should still receive hits"
        )
    }

    func testTopHitResolutionStateIsScopedPerWindow() {
        let point = NSPoint(x: 100, y: 18)

        let outerWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 36),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { outerWindow.orderOut(nil) }
        guard let outerContentView = outerWindow.contentView else {
            XCTFail("Expected outer content view")
            return
        }
        let outerContainer = NSView(frame: outerContentView.bounds)
        outerContainer.autoresizingMask = [.width, .height]
        outerContentView.addSubview(outerContainer)
        let outerDragHandle = NSView(frame: outerContainer.bounds)
        outerDragHandle.autoresizingMask = [.width, .height]
        outerContainer.addSubview(outerDragHandle)

        let nestedWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 36),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { nestedWindow.orderOut(nil) }
        guard let nestedContentView = nestedWindow.contentView else {
            XCTFail("Expected nested content view")
            return
        }
        let nestedContainer = BlockingTopHitContainerView(frame: nestedContentView.bounds)
        nestedContainer.autoresizingMask = [.width, .height]
        nestedContentView.addSubview(nestedContainer)
        let nestedDragHandle = NSView(frame: nestedContainer.bounds)
        nestedDragHandle.autoresizingMask = [.width, .height]
        nestedContainer.addSubview(nestedDragHandle)

        XCTAssertFalse(
            windowDragHandleShouldCaptureHit(point, in: nestedDragHandle),
            "Nested window drag handle should be blocked by top-hit titlebar container"
        )

        var nestedCaptureResult: Bool?
        let probe = PassThroughProbeView(frame: outerContainer.bounds)
        probe.autoresizingMask = [.width, .height]
        probe.onHitTest = {
            nestedCaptureResult = windowDragHandleShouldCaptureHit(point, in: nestedDragHandle)
        }
        outerContainer.addSubview(probe)

        _ = windowDragHandleShouldCaptureHit(point, in: outerDragHandle)

        XCTAssertEqual(
            nestedCaptureResult,
            false,
            "Top-hit recursion in one window must not disable top-hit resolution in another window"
        )
    }
}

@MainActor
final class DraggableFolderHitTests: XCTestCase {
    func testFolderHitTestReturnsContainerWhenInsideBounds() {
        let folderView = DraggableFolderNSView(directory: "/tmp")
        folderView.frame = NSRect(x: 0, y: 0, width: 16, height: 16)

        guard let hit = folderView.hitTest(NSPoint(x: 8, y: 8)) else {
            XCTFail("Expected folder icon to capture inside hit")
            return
        }
        XCTAssertTrue(hit === folderView)
    }

    func testFolderHitTestReturnsNilOutsideBounds() {
        let folderView = DraggableFolderNSView(directory: "/tmp")
        folderView.frame = NSRect(x: 0, y: 0, width: 16, height: 16)

        XCTAssertNil(folderView.hitTest(NSPoint(x: 20, y: 8)))
    }

    func testFolderIconDisablesWindowMoveBehavior() {
        let folderView = DraggableFolderNSView(directory: "/tmp")
        XCTAssertFalse(folderView.mouseDownCanMoveWindow)
    }
}

@MainActor
final class TitlebarLeadingInsetPassthroughViewTests: XCTestCase {
    func testLeadingInsetViewDoesNotParticipateInHitTesting() {
        let view = TitlebarLeadingInsetPassthroughView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        XCTAssertNil(view.hitTest(NSPoint(x: 20, y: 10)))
    }

    func testLeadingInsetViewCannotMoveWindowViaMouseDown() {
        let view = TitlebarLeadingInsetPassthroughView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        XCTAssertFalse(view.mouseDownCanMoveWindow)
    }
}

@MainActor
final class FolderWindowMoveSuppressionTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    func testSuppressionDisablesMovableWindow() {
        let window = makeWindow()
        window.isMovable = true

        let previous = temporarilyDisableWindowDragging(window: window)

        XCTAssertEqual(previous, true)
        XCTAssertFalse(window.isMovable)
    }

    func testSuppressionPreservesAlreadyImmovableWindow() {
        let window = makeWindow()
        window.isMovable = false

        let previous = temporarilyDisableWindowDragging(window: window)

        XCTAssertEqual(previous, false)
        XCTAssertFalse(window.isMovable)
    }

    func testRestoreAppliesPreviousMovableState() {
        let window = makeWindow()
        window.isMovable = false

        restoreWindowDragging(window: window, previousMovableState: true)
        XCTAssertTrue(window.isMovable)

        restoreWindowDragging(window: window, previousMovableState: false)
        XCTAssertFalse(window.isMovable)
    }

    func testWindowDragSuppressionDepthLifecycle() {
        let window = makeWindow()
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 0)
        XCTAssertFalse(isWindowDragSuppressed(window: window))

        XCTAssertEqual(beginWindowDragSuppression(window: window), 1)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 1)
        XCTAssertTrue(isWindowDragSuppressed(window: window))

        XCTAssertEqual(endWindowDragSuppression(window: window), 0)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 0)
        XCTAssertFalse(isWindowDragSuppressed(window: window))
    }

    func testWindowDragSuppressionIsReferenceCounted() {
        let window = makeWindow()
        XCTAssertEqual(beginWindowDragSuppression(window: window), 1)
        XCTAssertEqual(beginWindowDragSuppression(window: window), 2)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 2)
        XCTAssertTrue(isWindowDragSuppressed(window: window))

        XCTAssertEqual(endWindowDragSuppression(window: window), 1)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 1)
        XCTAssertTrue(isWindowDragSuppressed(window: window))

        XCTAssertEqual(endWindowDragSuppression(window: window), 0)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 0)
        XCTAssertFalse(isWindowDragSuppressed(window: window))
    }

    func testTemporaryWindowMovableEnableRestoresImmovableWindow() {
        let window = makeWindow()
        window.isMovable = false

        let previous = withTemporaryWindowMovableEnabled(window: window) {
            XCTAssertTrue(window.isMovable)
        }

        XCTAssertEqual(previous, false)
        XCTAssertFalse(window.isMovable)
    }

    func testTemporaryWindowMovableEnablePreservesMovableWindow() {
        let window = makeWindow()
        window.isMovable = true

        let previous = withTemporaryWindowMovableEnabled(window: window) {
            XCTAssertTrue(window.isMovable)
        }

        XCTAssertEqual(previous, true)
        XCTAssertTrue(window.isMovable)
    }
}

@MainActor
final class WindowMoveSuppressionHitPathTests: XCTestCase {
    private func makeWindowWithContentView() -> (NSWindow, NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView
        return (window, contentView)
    }

    private func makeMouseEvent(type: NSEvent.EventType, location: NSPoint, window: NSWindow) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            fatalError("Failed to create \(type) mouse event")
        }
        return event
    }

    func testSuppressionHitPathRecognizesFolderView() {
        let folderView = DraggableFolderNSView(directory: "/tmp")
        XCTAssertTrue(shouldSuppressWindowMoveForFolderDrag(hitView: folderView))
    }

    func testSuppressionHitPathRecognizesDescendantOfFolderView() {
        let folderView = DraggableFolderNSView(directory: "/tmp")
        let child = NSView(frame: .zero)
        folderView.addSubview(child)
        XCTAssertTrue(shouldSuppressWindowMoveForFolderDrag(hitView: child))
    }

    func testSuppressionHitPathIgnoresUnrelatedViews() {
        XCTAssertFalse(shouldSuppressWindowMoveForFolderDrag(hitView: NSView(frame: .zero)))
        XCTAssertFalse(shouldSuppressWindowMoveForFolderDrag(hitView: nil))
    }

    func testSuppressionEventPathRecognizesFolderHitInsideWindow() {
        let (window, contentView) = makeWindowWithContentView()
        window.isMovable = true
        let folderView = DraggableFolderNSView(directory: "/tmp")
        folderView.frame = NSRect(x: 10, y: 10, width: 16, height: 16)
        contentView.addSubview(folderView)

        let event = makeMouseEvent(type: .leftMouseDown, location: NSPoint(x: 14, y: 14), window: window)

        XCTAssertTrue(shouldSuppressWindowMoveForFolderDrag(window: window, event: event))
    }

    func testSuppressionEventPathRejectsNonFolderAndNonMouseDownEvents() {
        let (window, contentView) = makeWindowWithContentView()
        window.isMovable = true
        let plainView = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        contentView.addSubview(plainView)

        let down = makeMouseEvent(type: .leftMouseDown, location: NSPoint(x: 20, y: 20), window: window)
        XCTAssertFalse(shouldSuppressWindowMoveForFolderDrag(window: window, event: down))

        let dragged = makeMouseEvent(type: .leftMouseDragged, location: NSPoint(x: 20, y: 20), window: window)
        XCTAssertFalse(shouldSuppressWindowMoveForFolderDrag(window: window, event: dragged))
    }
}

@MainActor
final class GhosttySurfaceOverlayTests: XCTestCase {
    func testInactiveOverlayVisibilityTracksRequestedState() {
        let hostedView = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 80, height: 50))
        )

        hostedView.setInactiveOverlay(color: .black, opacity: 0.35, visible: true)
        var state = hostedView.debugInactiveOverlayState()
        XCTAssertFalse(state.isHidden)
        XCTAssertEqual(state.alpha, 0.35, accuracy: 0.01)

        hostedView.setInactiveOverlay(color: .black, opacity: 0.35, visible: false)
        state = hostedView.debugInactiveOverlayState()
        XCTAssertTrue(state.isHidden)
    }

    func testWindowResignKeyClearsFocusedTerminalFirstResponder() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let hostedView = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
        )
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        hostedView.moveFocus()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(
            hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to be first responder before window blur"
        )

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertFalse(
            hostedView.isSurfaceViewFirstResponder(),
            "Window blur should force terminal surface to resign first responder"
        )
    }

    func testSearchOverlayMountsAndUnmountsWithSearchState() {
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        XCTAssertFalse(hostedView.debugHasSearchOverlay())

        let searchState = TerminalSurface.SearchState(needle: "example")
        hostedView.setSearchOverlay(searchState: searchState)
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        hostedView.setSearchOverlay(searchState: nil)
        XCTAssertFalse(hostedView.debugHasSearchOverlay())
    }

    func testSearchOverlayMountDoesNotRetainTerminalSurface() {
        weak var weakSurface: TerminalSurface?

        let hostedView: GhosttySurfaceScrollView = {
            let surface = TerminalSurface(
                tabId: UUID(),
                context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
                configTemplate: nil,
                workingDirectory: nil
            )
            weakSurface = surface
            let hostedView = surface.hostedView
            hostedView.setSearchOverlay(searchState: TerminalSurface.SearchState(needle: "retain-check"))
            return hostedView
        }()

        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        XCTAssertTrue(hostedView.debugHasSearchOverlay())
        XCTAssertNil(weakSurface, "Mounted search overlay must not retain TerminalSurface")
    }

    func testSearchOverlaySurvivesPortalRebindDuringSplitLikeChurn() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let portal = WindowTerminalPortal(window: window)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchorA = NSView(frame: NSRect(x: 20, y: 20, width: 180, height: 140))
        let anchorB = NSView(frame: NSRect(x: 220, y: 20, width: 180, height: 140))
        contentView.addSubview(anchorA)
        contentView.addSubview(anchorB)

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        hostedView.setSearchOverlay(searchState: TerminalSurface.SearchState(needle: "split"))
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        portal.bind(hostedView: hostedView, to: anchorA, visibleInUI: true)
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        portal.bind(hostedView: hostedView, to: anchorB, visibleInUI: true)
        XCTAssertTrue(
            hostedView.debugHasSearchOverlay(),
            "Split-like anchor churn should not unmount terminal search overlay"
        )
    }

    func testSearchOverlaySurvivesPortalVisibilityToggleDuringWorkspaceSwitchLikeChurn() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let portal = WindowTerminalPortal(window: window)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 40, width: 220, height: 160))
        contentView.addSubview(anchor)

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        hostedView.setSearchOverlay(searchState: TerminalSurface.SearchState(needle: "workspace"))
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        portal.bind(hostedView: hostedView, to: anchor, visibleInUI: true)
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        portal.bind(hostedView: hostedView, to: anchor, visibleInUI: false)
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        portal.bind(hostedView: hostedView, to: anchor, visibleInUI: true)
        XCTAssertTrue(
            hostedView.debugHasSearchOverlay(),
            "Workspace-switch-like visibility toggles should not unmount terminal search overlay"
        )
    }
}

@MainActor
final class TerminalWindowPortalLifecycleTests: XCTestCase {
    private func realizeWindowLayout(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func testPortalHostInstallsAboveContentViewForVisibility() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let portal = WindowTerminalPortal(window: window)
        _ = portal.viewAtWindowPoint(NSPoint(x: 1, y: 1))

        guard let contentView = window.contentView,
              let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        guard let hostIndex = container.subviews.firstIndex(where: { $0 is WindowTerminalHostView }),
              let contentIndex = container.subviews.firstIndex(where: { $0 === contentView }) else {
            XCTFail("Expected host/content views in same container")
            return
        }

        XCTAssertGreaterThan(
            hostIndex,
            contentIndex,
            "Portal host must remain above content view so portal-hosted terminals stay visible"
        )
    }

    func testRegistryPrunesPortalWhenWindowCloses() {
        let baseline = TerminalWindowPortalRegistry.debugPortalCount()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        _ = TerminalWindowPortalRegistry.viewAtWindowPoint(NSPoint(x: 1, y: 1), in: window)
        XCTAssertEqual(TerminalWindowPortalRegistry.debugPortalCount(), baseline + 1)

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        XCTAssertEqual(TerminalWindowPortalRegistry.debugPortalCount(), baseline)
    }

    func testPruneDeadEntriesDetachesAnchorlessHostedView() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let portal = WindowTerminalPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let hosted1 = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 40, height: 30))
        )

        var anchor1: NSView? = NSView(frame: NSRect(x: 20, y: 20, width: 120, height: 80))
        contentView.addSubview(anchor1!)
        portal.bind(hostedView: hosted1, to: anchor1!, visibleInUI: true)

        anchor1?.removeFromSuperview()
        anchor1 = nil

        let hosted2 = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 40, height: 30))
        )
        let anchor2 = NSView(frame: NSRect(x: 180, y: 20, width: 120, height: 80))
        contentView.addSubview(anchor2)
        portal.bind(hostedView: hosted2, to: anchor2, visibleInUI: true)

        XCTAssertEqual(portal.debugEntryCount(), 1, "Only the live anchored hosted view should remain tracked")
        XCTAssertEqual(portal.debugHostedSubviewCount(), 1, "Stale anchorless hosted views should be detached from hostView")
    }

    func testTerminalViewAtWindowPointResolvesPortalHostedSurface() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let portal = WindowTerminalPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 50, width: 200, height: 120))
        contentView.addSubview(anchor)

        let hosted = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
        )
        portal.bind(hostedView: hosted, to: anchor, visibleInUI: true)

        let center = NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY)
        let windowPoint = anchor.convert(center, to: nil)
        XCTAssertNotNil(
            portal.terminalViewAtWindowPoint(windowPoint),
            "Portal hit-testing should resolve the terminal view for Finder file drops"
        )
    }

    func testVisibilityTransitionBringsHostedViewToFront() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let portal = WindowTerminalPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor1 = NSView(frame: NSRect(x: 20, y: 20, width: 220, height: 180))
        let anchor2 = NSView(frame: NSRect(x: 80, y: 60, width: 220, height: 180))
        contentView.addSubview(anchor1)
        contentView.addSubview(anchor2)

        let terminal1 = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let hosted1 = GhosttySurfaceScrollView(surfaceView: terminal1)
        let terminal2 = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let hosted2 = GhosttySurfaceScrollView(surfaceView: terminal2)

        portal.bind(hostedView: hosted1, to: anchor1, visibleInUI: true)
        portal.bind(hostedView: hosted2, to: anchor2, visibleInUI: true)

        let overlapInContent = NSPoint(x: 120, y: 100)
        let overlapInWindow = contentView.convert(overlapInContent, to: nil)
        XCTAssertTrue(
            portal.terminalViewAtWindowPoint(overlapInWindow) === terminal2,
            "Latest bind should be top-most before visibility transition"
        )

        portal.bind(hostedView: hosted1, to: anchor1, visibleInUI: false)
        portal.bind(hostedView: hosted1, to: anchor1, visibleInUI: true)
        XCTAssertTrue(
            portal.terminalViewAtWindowPoint(overlapInWindow) === terminal1,
            "Becoming visible should refresh z-order for already-hosted view"
        )
    }

    func testPriorityIncreaseBringsHostedViewToFrontWithoutVisibilityToggle() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let portal = WindowTerminalPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor1 = NSView(frame: NSRect(x: 20, y: 20, width: 220, height: 180))
        let anchor2 = NSView(frame: NSRect(x: 80, y: 60, width: 220, height: 180))
        contentView.addSubview(anchor1)
        contentView.addSubview(anchor2)

        let terminal1 = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let hosted1 = GhosttySurfaceScrollView(surfaceView: terminal1)
        let terminal2 = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let hosted2 = GhosttySurfaceScrollView(surfaceView: terminal2)

        portal.bind(hostedView: hosted1, to: anchor1, visibleInUI: true, zPriority: 1)
        portal.bind(hostedView: hosted2, to: anchor2, visibleInUI: true, zPriority: 2)

        let overlapInContent = NSPoint(x: 120, y: 100)
        let overlapInWindow = contentView.convert(overlapInContent, to: nil)
        XCTAssertTrue(
            portal.terminalViewAtWindowPoint(overlapInWindow) === terminal2,
            "Higher-priority terminal should initially be top-most"
        )

        portal.bind(hostedView: hosted1, to: anchor1, visibleInUI: true, zPriority: 2)
        XCTAssertTrue(
            portal.terminalViewAtWindowPoint(overlapInWindow) === terminal1,
            "Promoting z-priority should bring an already-visible terminal to front"
        )
    }

    func testHiddenPortalDefersRevealUntilFrameHasUsableSize() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let portal = WindowTerminalPortal(window: window)
        realizeWindowLayout(window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 40, width: 280, height: 220))
        contentView.addSubview(anchor)

        let hosted = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        )
        portal.bind(hostedView: hosted, to: anchor, visibleInUI: true)
        XCTAssertFalse(hosted.isHidden, "Healthy geometry should be visible")

        // Collapse to a tiny frame first.
        anchor.frame = NSRect(x: 160.5, y: 1037.0, width: 79.0, height: 0.0)
        portal.synchronizeHostedViewForAnchor(anchor)
        XCTAssertTrue(hosted.isHidden, "Tiny geometry should hide the portal-hosted terminal")

        // Then restore to a non-zero but still too-small frame. It should remain hidden.
        anchor.frame = NSRect(x: 160.9, y: 1026.5, width: 93.6, height: 10.3)
        portal.synchronizeHostedViewForAnchor(anchor)
        XCTAssertTrue(
            hosted.isHidden,
            "Portal should defer reveal until geometry reaches a usable size"
        )

        // Once the frame is large enough again, reveal should resume.
        anchor.frame = NSRect(x: 40, y: 40, width: 180, height: 40)
        portal.synchronizeHostedViewForAnchor(anchor)
        XCTAssertFalse(hosted.isHidden, "Portal should unhide after geometry is usable")
    }
}

@MainActor
final class BrowserWindowPortalLifecycleTests: XCTestCase {
    private func realizeWindowLayout(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func testPortalHostInstallsAboveContentViewForVisibility() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let portal = WindowBrowserPortal(window: window)
        _ = portal.webViewAtWindowPoint(NSPoint(x: 1, y: 1))

        guard let contentView = window.contentView,
              let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        guard let hostIndex = container.subviews.firstIndex(where: { $0 is WindowBrowserHostView }),
              let contentIndex = container.subviews.firstIndex(where: { $0 === contentView }) else {
            XCTFail("Expected host/content views in same container")
            return
        }

        XCTAssertGreaterThan(
            hostIndex,
            contentIndex,
            "Browser portal host must remain above content view so portal-hosted web views stay visible"
        )
    }

    func testAnchorRebindKeepsWebViewInStablePortalSuperview() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor1 = NSView(frame: NSRect(x: 20, y: 20, width: 180, height: 120))
        let anchor2 = NSView(frame: NSRect(x: 240, y: 40, width: 180, height: 120))
        contentView.addSubview(anchor1)
        contentView.addSubview(anchor2)

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor1, visibleInUI: true)
        let firstSuperview = webView.superview

        XCTAssertNotNil(firstSuperview)
        XCTAssertTrue(firstSuperview is WindowBrowserSlotView)

        portal.bind(webView: webView, to: anchor2, visibleInUI: true)
        XCTAssertTrue(webView.superview === firstSuperview, "Anchor moves should not reparent the web view")

        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor2)
        guard let slot = webView.superview as? WindowBrowserSlotView,
              let host = slot.superview as? WindowBrowserHostView else {
            XCTFail("Expected browser slot + host views")
            return
        }
        let expectedFrame = host.convert(anchor2.bounds, from: anchor2)
        XCTAssertEqual(slot.frame.origin.x, expectedFrame.origin.x, accuracy: 0.5)
        XCTAssertEqual(slot.frame.origin.y, expectedFrame.origin.y, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.width, expectedFrame.size.width, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.height, expectedFrame.size.height, accuracy: 0.5)
    }

    func testPortalClampsWebViewFrameToHostBoundsWhenAnchorOverflowsSidebar() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        // Simulate a transient oversized anchor rect during split churn.
        let anchor = NSView(frame: NSRect(x: 120, y: 20, width: 260, height: 150))
        contentView.addSubview(anchor)

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected web view slot")
            return
        }

        XCTAssertFalse(slot.isHidden, "Partially visible browser anchor should stay visible")
        XCTAssertEqual(slot.frame.origin.x, 120, accuracy: 0.5)
        XCTAssertEqual(slot.frame.origin.y, 20, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.width, 200, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.height, 150, accuracy: 0.5)
    }

    func testPortalSyncNormalizesOutOfBoundsWebFrame() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 20, width: 220, height: 160))
        contentView.addSubview(anchor)

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        // Reproduce observed drift from logs where WebKit shifts/expands frame beyond slot bounds.
        webView.frame = NSRect(x: 0, y: 250, width: slot.bounds.width, height: slot.bounds.height)
        XCTAssertGreaterThan(webView.frame.maxY, slot.bounds.maxY)

        portal.synchronizeWebViewForAnchor(anchor)
        XCTAssertEqual(webView.frame.origin.x, slot.bounds.origin.x, accuracy: 0.5)
        XCTAssertEqual(webView.frame.origin.y, slot.bounds.origin.y, accuracy: 0.5)
        XCTAssertEqual(webView.frame.size.width, slot.bounds.size.width, accuracy: 0.5)
        XCTAssertEqual(webView.frame.size.height, slot.bounds.size.height, accuracy: 0.5)
    }

    func testPortalHostBoundsBecomeReadyAfterBindingInFrameDrivenHierarchy() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        let anchor = NSView(frame: NSRect(x: 40, y: 24, width: 220, height: 160))
        contentView.addSubview(anchor)

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView,
              let host = slot.superview as? WindowBrowserHostView else {
            XCTFail("Expected portal slot + host views")
            return
        }
        XCTAssertGreaterThan(host.bounds.width, 1, "Portal host width should be ready for clipping/sync")
        XCTAssertGreaterThan(host.bounds.height, 1, "Portal host height should be ready for clipping/sync")
    }

    func testRegistryDetachRemovesPortalHostedWebView() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 180, height: 120))
        contentView.addSubview(anchor)
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())

        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
        XCTAssertNotNil(webView.superview)

        BrowserWindowPortalRegistry.detach(webView: webView)
        XCTAssertNil(webView.superview)
    }
}

final class BrowserLinkOpenSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "BrowserLinkOpenSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testTerminalLinksDefaultToCmuxBrowser() {
        XCTAssertTrue(BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowser(defaults: defaults))
    }

    func testTerminalLinksPreferenceUsesStoredValue() {
        defaults.set(false, forKey: BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey)
        XCTAssertFalse(BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowser(defaults: defaults))

        defaults.set(true, forKey: BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey)
        XCTAssertTrue(BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowser(defaults: defaults))
    }

    func testSidebarPullRequestLinksDefaultToCmuxBrowser() {
        XCTAssertTrue(BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowser(defaults: defaults))
    }

    func testSidebarPullRequestLinksPreferenceUsesStoredValue() {
        defaults.set(false, forKey: BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowserKey)
        XCTAssertFalse(BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowser(defaults: defaults))

        defaults.set(true, forKey: BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowserKey)
        XCTAssertTrue(BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowser(defaults: defaults))
    }

    func testOpenCommandInterceptionDefaultsToCmuxBrowser() {
        XCTAssertTrue(BrowserLinkOpenSettings.interceptTerminalOpenCommandInCmuxBrowser(defaults: defaults))
    }

    func testOpenCommandInterceptionUsesStoredValue() {
        defaults.set(false, forKey: BrowserLinkOpenSettings.interceptTerminalOpenCommandInCmuxBrowserKey)
        XCTAssertFalse(BrowserLinkOpenSettings.interceptTerminalOpenCommandInCmuxBrowser(defaults: defaults))

        defaults.set(true, forKey: BrowserLinkOpenSettings.interceptTerminalOpenCommandInCmuxBrowserKey)
        XCTAssertTrue(BrowserLinkOpenSettings.interceptTerminalOpenCommandInCmuxBrowser(defaults: defaults))
    }

    func testOpenCommandInterceptionFallsBackToLegacyLinkToggleWhenUnset() {
        defaults.set(false, forKey: BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey)
        XCTAssertFalse(BrowserLinkOpenSettings.interceptTerminalOpenCommandInCmuxBrowser(defaults: defaults))

        defaults.set(true, forKey: BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey)
        XCTAssertTrue(BrowserLinkOpenSettings.interceptTerminalOpenCommandInCmuxBrowser(defaults: defaults))
    }

    func testSettingsInitialOpenCommandInterceptionValueFallsBackToLegacyLinkToggleWhenUnset() {
        defaults.set(false, forKey: BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey)
        XCTAssertFalse(BrowserLinkOpenSettings.initialInterceptTerminalOpenCommandInCmuxBrowserValue(defaults: defaults))

        defaults.set(true, forKey: BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey)
        XCTAssertTrue(BrowserLinkOpenSettings.initialInterceptTerminalOpenCommandInCmuxBrowserValue(defaults: defaults))
    }
}

final class TerminalOpenURLTargetResolutionTests: XCTestCase {
    func testResolvesHTTPSAsEmbeddedBrowser() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("https://example.com/path?q=1"))
        switch target {
        case let .embeddedBrowser(url):
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "example.com")
            XCTAssertEqual(url.path, "/path")
        default:
            XCTFail("Expected web URL to route to embedded browser")
        }
    }

    func testResolvesBareDomainAsEmbeddedBrowser() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("example.com/docs"))
        switch target {
        case let .embeddedBrowser(url):
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "example.com")
            XCTAssertEqual(url.path, "/docs")
        default:
            XCTFail("Expected bare domain to be normalized as an HTTPS browser URL")
        }
    }

    func testResolvesFileSchemeAsExternal() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("file:///tmp/cmux.txt"))
        switch target {
        case let .external(url):
            XCTAssertTrue(url.isFileURL)
            XCTAssertEqual(url.path, "/tmp/cmux.txt")
        default:
            XCTFail("Expected file URL to open externally")
        }
    }

    func testResolvesAbsolutePathAsExternalFileURL() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("/tmp/cmux-path.txt"))
        switch target {
        case let .external(url):
            XCTAssertTrue(url.isFileURL)
            XCTAssertEqual(url.path, "/tmp/cmux-path.txt")
        default:
            XCTFail("Expected absolute file path to open externally")
        }
    }

    func testResolvesNonWebSchemeAsExternal() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("mailto:test@example.com"))
        switch target {
        case let .external(url):
            XCTAssertEqual(url.scheme, "mailto")
        default:
            XCTFail("Expected non-web scheme to open externally")
        }
    }

    func testResolvesHostlessHTTPSAsExternal() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("https:///tmp/cmux.txt"))
        switch target {
        case let .external(url):
            XCTAssertEqual(url.scheme, "https")
            XCTAssertNil(url.host)
            XCTAssertEqual(url.path, "/tmp/cmux.txt")
        default:
            XCTFail("Expected hostless HTTPS URL to open externally")
        }
    }
}

final class BrowserExternalNavigationSchemeTests: XCTestCase {
    func testCustomAppSchemesOpenExternally() throws {
        let discord = try XCTUnwrap(URL(string: "discord://login/one-time?token=abc"))
        let slack = try XCTUnwrap(URL(string: "slack://open"))
        let zoom = try XCTUnwrap(URL(string: "zoommtg://zoom.us/join"))
        let mailto = try XCTUnwrap(URL(string: "mailto:test@example.com"))

        XCTAssertTrue(browserShouldOpenURLExternally(discord))
        XCTAssertTrue(browserShouldOpenURLExternally(slack))
        XCTAssertTrue(browserShouldOpenURLExternally(zoom))
        XCTAssertTrue(browserShouldOpenURLExternally(mailto))
    }

    func testEmbeddedBrowserSchemesStayInWebView() throws {
        let https = try XCTUnwrap(URL(string: "https://example.com"))
        let http = try XCTUnwrap(URL(string: "http://example.com"))
        let about = try XCTUnwrap(URL(string: "about:blank"))
        let data = try XCTUnwrap(URL(string: "data:text/plain,hello"))
        let blob = try XCTUnwrap(URL(string: "blob:https://example.com/550e8400-e29b-41d4-a716-446655440000"))
        let javascript = try XCTUnwrap(URL(string: "javascript:void(0)"))
        let webkitInternal = try XCTUnwrap(URL(string: "applewebdata://local/page"))

        XCTAssertFalse(browserShouldOpenURLExternally(https))
        XCTAssertFalse(browserShouldOpenURLExternally(http))
        XCTAssertFalse(browserShouldOpenURLExternally(about))
        XCTAssertFalse(browserShouldOpenURLExternally(data))
        XCTAssertFalse(browserShouldOpenURLExternally(blob))
        XCTAssertFalse(browserShouldOpenURLExternally(javascript))
        XCTAssertFalse(browserShouldOpenURLExternally(webkitInternal))
    }
}

final class BrowserHostWhitelistTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "BrowserHostWhitelistTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testEmptyWhitelistAllowsAll() {
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("example.com", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("localhost", defaults: defaults))
    }

    func testExactMatch() {
        defaults.set("localhost\n127.0.0.1", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("localhost", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("127.0.0.1", defaults: defaults))
        XCTAssertFalse(BrowserLinkOpenSettings.hostMatchesWhitelist("example.com", defaults: defaults))
    }

    func testExactMatchIsCaseInsensitive() {
        defaults.set("LocalHost", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("localhost", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("LOCALHOST", defaults: defaults))
    }

    func testWildcardSuffix() {
        defaults.set("*.localtest.me", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("app.localtest.me", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("sub.app.localtest.me", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("localtest.me", defaults: defaults))
        XCTAssertFalse(BrowserLinkOpenSettings.hostMatchesWhitelist("example.com", defaults: defaults))
    }

    func testWildcardIsCaseInsensitive() {
        defaults.set("*.Example.COM", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("sub.example.com", defaults: defaults))
    }

    func testBlankLinesAndWhitespaceIgnored() {
        defaults.set("  localhost  \n\n  127.0.0.1  \n", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("localhost", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("127.0.0.1", defaults: defaults))
        XCTAssertFalse(BrowserLinkOpenSettings.hostMatchesWhitelist("example.com", defaults: defaults))
    }

    func testMixedExactAndWildcard() {
        defaults.set("localhost\n127.0.0.1\n*.local.dev", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("localhost", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("127.0.0.1", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("app.local.dev", defaults: defaults))
        XCTAssertFalse(BrowserLinkOpenSettings.hostMatchesWhitelist("github.com", defaults: defaults))
    }

    func testDefaultWhitelistIsEmpty() {
        let patterns = BrowserLinkOpenSettings.hostWhitelist(defaults: defaults)
        XCTAssertTrue(patterns.isEmpty)
    }

    func testWildcardRequiresDotBoundary() {
        defaults.set("*.example.com", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertFalse(BrowserLinkOpenSettings.hostMatchesWhitelist("badexample.com", defaults: defaults))
        XCTAssertFalse(BrowserLinkOpenSettings.hostMatchesWhitelist("example.com.evil", defaults: defaults))
    }

    func testWhitelistNormalizesSchemesPortsAndTrailingDots() {
        defaults.set("https://LOCALHOST:3000/path\n*.Example.COM:443", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("localhost.", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("api.example.com", defaults: defaults))
    }

    func testInvalidWhitelistEntriesDoNotImplicitlyAllowAll() {
        defaults.set("http://\n*.\n", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertFalse(BrowserLinkOpenSettings.hostMatchesWhitelist("example.com", defaults: defaults))
    }

    func testUnicodeWhitelistEntryMatchesPunycodeHost() {
        defaults.set("b\u{00FC}cher.example", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("xn--bcher-kva.example", defaults: defaults))
    }
}

final class TerminalControllerSidebarDedupeTests: XCTestCase {
    func testShouldReplaceStatusEntryReturnsFalseForUnchangedPayload() {
        let current = SidebarStatusEntry(
            key: "agent",
            value: "idle",
            icon: "bolt",
            color: "#ffffff",
            timestamp: Date(timeIntervalSince1970: 123)
        )
        XCTAssertFalse(
            TerminalController.shouldReplaceStatusEntry(
                current: current,
                key: "agent",
                value: "idle",
                icon: "bolt",
                color: "#ffffff",
                url: nil,
                priority: 0,
                format: .plain
            )
        )
    }

    func testShouldReplaceStatusEntryReturnsTrueWhenValueChanges() {
        let current = SidebarStatusEntry(
            key: "agent",
            value: "idle",
            icon: "bolt",
            color: "#ffffff",
            timestamp: Date(timeIntervalSince1970: 123)
        )
        XCTAssertTrue(
            TerminalController.shouldReplaceStatusEntry(
                current: current,
                key: "agent",
                value: "running",
                icon: "bolt",
                color: "#ffffff",
                url: nil,
                priority: 0,
                format: .plain
            )
        )
    }

    func testShouldReplaceProgressReturnsFalseForUnchangedPayload() {
        XCTAssertFalse(
            TerminalController.shouldReplaceProgress(
                current: SidebarProgressState(value: 0.42, label: "indexing"),
                value: 0.42,
                label: "indexing"
            )
        )
    }

    func testShouldReplaceGitBranchReturnsFalseForUnchangedPayload() {
        XCTAssertFalse(
            TerminalController.shouldReplaceGitBranch(
                current: SidebarGitBranchState(branch: "main", isDirty: true),
                branch: "main",
                isDirty: true
            )
        )
    }

    func testShouldReplacePortsIgnoresOrderAndDuplicates() {
        XCTAssertFalse(
            TerminalController.shouldReplacePorts(
                current: [9229, 3000],
                next: [3000, 9229, 3000]
            )
        )
        XCTAssertTrue(
            TerminalController.shouldReplacePorts(
                current: [9229, 3000],
                next: [3000]
            )
        )
    }

    func testExplicitSocketScopeParsesValidUUIDTabAndPanel() {
        let workspaceId = UUID()
        let panelId = UUID()
        let scope = TerminalController.explicitSocketScope(
            options: [
                "tab": workspaceId.uuidString,
                "panel": panelId.uuidString
            ]
        )
        XCTAssertEqual(scope?.workspaceId, workspaceId)
        XCTAssertEqual(scope?.panelId, panelId)
    }

    func testExplicitSocketScopeAcceptsSurfaceAlias() {
        let workspaceId = UUID()
        let panelId = UUID()
        let scope = TerminalController.explicitSocketScope(
            options: [
                "tab": workspaceId.uuidString,
                "surface": panelId.uuidString
            ]
        )
        XCTAssertEqual(scope?.workspaceId, workspaceId)
        XCTAssertEqual(scope?.panelId, panelId)
    }

    func testExplicitSocketScopeRejectsMissingOrInvalidValues() {
        XCTAssertNil(TerminalController.explicitSocketScope(options: [:]))
        XCTAssertNil(TerminalController.explicitSocketScope(options: ["tab": "workspace:1", "panel": UUID().uuidString]))
        XCTAssertNil(TerminalController.explicitSocketScope(options: ["tab": UUID().uuidString, "panel": "surface:1"]))
    }

    func testNormalizeReportedDirectoryTrimsWhitespace() {
        XCTAssertEqual(
            TerminalController.normalizeReportedDirectory("   /Users/cmux/project   "),
            "/Users/cmux/project"
        )
    }

    func testNormalizeReportedDirectoryResolvesFileURL() {
        XCTAssertEqual(
            TerminalController.normalizeReportedDirectory("file:///Users/cmux/project"),
            "/Users/cmux/project"
        )
    }

    func testNormalizeReportedDirectoryLeavesInvalidURLTrimmed() {
        XCTAssertEqual(
            TerminalController.normalizeReportedDirectory("  file://bad host  "),
            "file://bad host"
        )
    }
}

final class TerminalControllerSocketTextChunkTests: XCTestCase {
    func testSocketTextChunksReturnsSingleChunkForPlainText() {
        XCTAssertEqual(
            TerminalController.socketTextChunks("echo hello"),
            [.text("echo hello")]
        )
    }

    func testSocketTextChunksSplitsControlScalars() {
        XCTAssertEqual(
            TerminalController.socketTextChunks("abc\rdef\tghi"),
            [
                .text("abc"),
                .control("\r".unicodeScalars.first!),
                .text("def"),
                .control("\t".unicodeScalars.first!),
                .text("ghi")
            ]
        )
    }

    func testSocketTextChunksDoesNotEmitEmptyTextChunksAroundConsecutiveControls() {
        XCTAssertEqual(
            TerminalController.socketTextChunks("\r\n\t"),
            [
                .control("\r".unicodeScalars.first!),
                .control("\n".unicodeScalars.first!),
                .control("\t".unicodeScalars.first!)
            ]
        )
    }
}

final class BrowserOmnibarFocusPolicyTests: XCTestCase {
    func testReacquiresFocusWhenWebViewSuppressionIsActiveAndNextResponderIsNotAnotherTextField() {
        XCTAssertTrue(
            browserOmnibarShouldReacquireFocusAfterEndEditing(
                suppressWebViewFocus: true,
                nextResponderIsOtherTextField: false
            )
        )
    }

    func testDoesNotReacquireFocusWhenAnotherTextFieldAlreadyTookFocus() {
        XCTAssertFalse(
            browserOmnibarShouldReacquireFocusAfterEndEditing(
                suppressWebViewFocus: true,
                nextResponderIsOtherTextField: true
            )
        )
    }

    func testDoesNotReacquireFocusWhenWebViewSuppressionIsInactive() {
        XCTAssertFalse(
            browserOmnibarShouldReacquireFocusAfterEndEditing(
                suppressWebViewFocus: false,
                nextResponderIsOtherTextField: false
            )
        )
    }
}

final class GhosttyTerminalViewVisibilityPolicyTests: XCTestCase {
    func testImmediateStateUpdateAllowedWhenHostNotInWindow() {
        XCTAssertTrue(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                hostWindowAttached: false,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: false
            )
        )
    }

    func testImmediateStateUpdateAllowedWhenBoundToCurrentHost() {
        XCTAssertTrue(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                hostWindowAttached: true,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: true
            )
        )
    }

    func testImmediateStateUpdateSkippedForStaleHostBoundElsewhere() {
        XCTAssertFalse(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                hostWindowAttached: true,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: false
            )
        )
    }

    func testImmediateStateUpdateAllowedWhenUnboundAndNotAttachedAnywhere() {
        XCTAssertTrue(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                hostWindowAttached: true,
                hostedViewHasSuperview: false,
                isBoundToCurrentHost: false
            )
        )
    }
}
