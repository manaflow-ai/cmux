import XCTest
import Combine
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Network

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

var cmuxUnitTestInspectorAssociationKey: UInt8 = 0
var cmuxUnitTestInspectorOverrideInstalled = false
var cmuxUnitTestWKWebViewPerformKeyEquivalentOverrideInstalled = false
var cmuxUnitTestWKWebViewPerformKeyEquivalentHook: ((WKWebView, NSEvent) -> Bool?)?

extension CmuxWebView {
    @objc func cmuxUnitTestInspector() -> NSObject? {
        objc_getAssociatedObject(self, &cmuxUnitTestInspectorAssociationKey) as? NSObject
    }
}

extension WKWebView {
    @objc func cmuxUnitTest_performKeyEquivalent(with event: NSEvent) -> Bool {
        if let hook = cmuxUnitTestWKWebViewPerformKeyEquivalentHook,
           let result = hook(self, event) {
            return result
        }
        return cmuxUnitTest_performKeyEquivalent(with: event)
    }

    func cmuxSetUnitTestInspector(_ inspector: NSObject?) {
        objc_setAssociatedObject(
            self,
            &cmuxUnitTestInspectorAssociationKey,
            inspector,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
}

func installCmuxUnitTestInspectorOverride() {
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

func installCmuxUnitTestWKWebViewPerformKeyEquivalentOverride() {
    guard !cmuxUnitTestWKWebViewPerformKeyEquivalentOverrideInstalled else { return }

    let originalSelector = #selector(NSResponder.performKeyEquivalent(with:))
    let swizzledSelector = #selector(WKWebView.cmuxUnitTest_performKeyEquivalent(with:))

    guard let originalMethod = class_getInstanceMethod(WKWebView.self, originalSelector),
          let swizzledMethod = class_getInstanceMethod(WKWebView.self, swizzledSelector) else {
        fatalError("Unable to locate WKWebView performKeyEquivalent methods for swizzling")
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

    cmuxUnitTestWKWebViewPerformKeyEquivalentOverrideInstalled = true
}

final class CmuxWebViewKeyEquivalentTests: XCTestCase {
    final class ActionSpy: NSObject {
        private(set) var invoked: Bool = false

        @objc func didInvoke(_ sender: Any?) {
            invoked = true
        }
    }

    final class WindowCyclingActionSpy: NSObject {
        weak var firstWindow: NSWindow?
        weak var secondWindow: NSWindow?
        private(set) var invocationCount = 0

        @objc func cycleWindow(_ sender: Any?) {
            invocationCount += 1
            guard let firstWindow, let secondWindow else { return }

            if NSApp.keyWindow === firstWindow {
                secondWindow.makeKeyAndOrderFront(nil)
            } else {
                firstWindow.makeKeyAndOrderFront(nil)
            }
        }
    }

    final class FirstResponderView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    final class FakeWKInspectorResponderView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    final class DelegateProbeTextView: NSTextView {
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

    final class FieldEditorProbeTextView: NSTextView {
        private(set) var delegateReadCount = 0
        private(set) var keyDownKeyCodes: [UInt16] = []
        var reportsMarkedText = false

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

        override func keyDown(with event: NSEvent) {
            keyDownKeyCodes.append(event.keyCode)
        }

        override func hasMarkedText() -> Bool {
            reportsMarkedText
        }

        func resetKeyDownKeyCodes() {
            keyDownKeyCodes.removeAll()
        }
    }

    final class FieldEditorProbeWindow: NSWindow {
        let testFieldEditor = FieldEditorProbeTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 24))

        override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
            testFieldEditor
        }
    }
    func installMenu(spy: ActionSpy, key: String, modifiers: NSEvent.ModifierFlags) {
        installMenu(
            target: spy,
            action: #selector(ActionSpy.didInvoke(_:)),
            key: key,
            modifiers: modifiers
        )
    }

    func installMenu(
        target: NSObject,
        action: Selector,
        key: String,
        modifiers: NSEvent.ModifierFlags
    ) {
        let mainMenu = NSMenu()

        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")

        let item = NSMenuItem(title: "Test Item", action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        fileMenu.addItem(item)

        mainMenu.addItem(fileItem)
        mainMenu.setSubmenu(fileMenu, for: fileItem)

        // Ensure NSApp exists and has a menu for performKeyEquivalent to consult.
        _ = NSApplication.shared
        NSApp.mainMenu = mainMenu
    }

    func makeKeyDownEvent(
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int = 0
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


@MainActor
final class BrowserDeveloperToolsVisibilityPersistenceTests: XCTestCase {
    final class WKInspectorProbeView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    final class WKInspectorProbeWebView: WKWebView {
    }

    final class FakeInspector: NSObject {
        enum HideBehavior {
            case unsupported
            case noEffect
            case hides
        }

        private(set) var attachCount = 0
        private(set) var showCount = 0
        private(set) var hideCount = 0
        private(set) var closeCount = 0
        private let hideBehavior: HideBehavior
        private let requiresAttachmentToShow: Bool
        private var visible = false
        private var attached = false
        private weak var frontendWebView: WKWebView?

        init(
            hideBehavior: HideBehavior = .unsupported,
            requiresAttachmentToShow: Bool = false
        ) {
            self.hideBehavior = hideBehavior
            self.requiresAttachmentToShow = requiresAttachmentToShow
            super.init()
        }

        override func responds(to aSelector: Selector!) -> Bool {
            guard NSStringFromSelector(aSelector) == "hide" else {
                return super.responds(to: aSelector)
            }
            return hideBehavior != .unsupported
        }

        @objc func isVisible() -> Bool {
            visible
        }

        @objc func isAttached() -> Bool {
            attached
        }

        @objc func attach() {
            attachCount += 1
            attached = true
            show()
        }

        @objc func show() {
            showCount += 1
            guard !requiresAttachmentToShow ||
                (attached && frontendWebView?.window != nil) else { return }
            visible = true
        }

        @objc func hide() {
            hideCount += 1
            guard hideBehavior == .hides else { return }
            visible = false
        }

        @objc func close() {
            closeCount += 1
            visible = false
            attached = false
        }

        @objc func inspectorWebView() -> WKWebView? {
            frontendWebView
        }

        func setFrontendWebView(_ webView: WKWebView?) {
            frontendWebView = webView
        }
    }

    override class func setUp() {
        super.setUp()
        installCmuxUnitTestInspectorOverride()
    }

    func makePanelWithInspector(
        hideBehavior: FakeInspector.HideBehavior = .unsupported,
        requiresAttachmentToShow: Bool = false
    ) -> (BrowserPanel, FakeInspector) {
        let panel = BrowserPanel(workspaceId: UUID())
        let inspector = FakeInspector(
            hideBehavior: hideBehavior,
            requiresAttachmentToShow: requiresAttachmentToShow
        )
        panel.webView.cmuxSetUnitTestInspector(inspector)
        return (panel, inspector)
    }

    func spinRunLoopOneTick() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    func window(withId windowId: UUID) -> NSWindow? {
        let identifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == identifier })
    }

    func findHostContainerView(in root: NSView) -> WebViewRepresentable.HostContainerView? {
        if let host = root as? WebViewRepresentable.HostContainerView {
            return host
        }
        for subview in root.subviews {
            if let host = findHostContainerView(in: subview) {
                return host
            }
        }
        return nil
    }

    func waitForDeveloperToolsTransitions() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    func closeBrowserPanel(_ panel: BrowserPanel) {
        panel.close()
        BrowserWindowPortalRegistry.detach(webView: panel.webView)
        panel.webView.cmuxSetUnitTestInspector(nil)
        panel.webView.removeFromSuperview()
    }

    func closeWindow(_ window: NSWindow) {
        window.contentView = nil
        window.orderOut(nil)
        window.close()
    }

    func tearDownMainWindow(
        _ window: NSWindow,
        manager: TabManager
    ) {
        let browserPanels = manager.tabs.flatMap { workspace in
            workspace.panels.values.compactMap { $0 as? BrowserPanel }
        }
        for workspace in manager.tabs {
            workspace.teardownAllPanels()
        }
        for browserPanel in browserPanels {
            BrowserWindowPortalRegistry.detach(webView: browserPanel.webView)
            browserPanel.webView.cmuxSetUnitTestInspector(nil)
            browserPanel.webView.removeFromSuperview()
        }
        closeWindow(window)
        spinRunLoopOneTick()
    }

    func findWindowBrowserSlotView(in root: NSView) -> WindowBrowserSlotView? {
        if let slot = root as? WindowBrowserSlotView {
            return slot
        }
        for subview in root.subviews {
            if let slot = findWindowBrowserSlotView(in: subview) {
                return slot
            }
        }
        return nil
    }

    func attachPanelWebViewToWindow(_ panel: BrowserPanel) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let host = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView?.addSubview(host)
        panel.webView.frame = NSRect(x: 0, y: 0, width: 180, height: host.bounds.height)
        host.addSubview(panel.webView)
        // Intentionally not made key / ordered front: consume's attach gate only
        // needs webView.window != nil, and a key window + live WKWebView + runloop
        // spin can recurse SwiftUI<->AppKit layout in the unit-test host.
        return window
    }

    func teardownWindowedPanel(_ panel: BrowserPanel, window: NSWindow) {
        // Detach the live WKWebView from the window before any teardown so the
        // window-close cascade never walks the web view's responder/layout tree
        // (that path can recurse SwiftUI<->AppKit and overflow the stack here).
        panel.webView.removeFromSuperview()
        BrowserWindowPortalRegistry.detach(webView: panel.webView)
        panel.webView.cmuxSetUnitTestInspector(nil)
        window.contentView = nil
        window.orderOut(nil)
        panel.close()
    }

}


