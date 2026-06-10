import XCTest
import AppKit
import ObjectiveC.runtime

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private var cjkIMEInterpretKeyEventsSwizzled = false
var cjkIMEInterpretKeyEventsHook: ((GhosttyNSView, [NSEvent]) -> Bool)?
private var ghosttyPasteActionSwizzled = false
var ghosttyPasteActionHook: ((GhosttyNSView, Any?) -> Void)?
private var ghosttyPasteAsPlainTextActionSwizzled = false
var ghosttyPasteAsPlainTextActionHook: ((GhosttyNSView, Any?) -> Void)?

private extension GhosttyNSView {
    @objc func cmuxUnitTest_interpretKeyEvents(_ eventArray: [NSEvent]) {
        if let hook = cjkIMEInterpretKeyEventsHook, hook(self, eventArray) {
            return
        }
        cmuxUnitTest_interpretKeyEvents(eventArray)
    }

    @objc func cmuxUnitTest_paste(_ sender: Any?) {
        ghosttyPasteActionHook?(self, sender)
        cmuxUnitTest_paste(sender)
    }

    @objc func cmuxUnitTest_pasteAsPlainText(_ sender: Any?) {
        ghosttyPasteAsPlainTextActionHook?(self, sender)
        cmuxUnitTest_pasteAsPlainText(sender)
    }
}

func installCJKIMEInterpretKeyEventsSwizzle() {
    guard !cjkIMEInterpretKeyEventsSwizzled else { return }

    let originalSelector = #selector(GhosttyNSView.interpretKeyEvents(_:))
    let swizzledSelector = #selector(GhosttyNSView.cmuxUnitTest_interpretKeyEvents(_:))

    guard let originalMethod = class_getInstanceMethod(GhosttyNSView.self, originalSelector),
          let swizzledMethod = class_getInstanceMethod(GhosttyNSView.self, swizzledSelector) else {
        fatalError("Unable to locate GhosttyNSView interpretKeyEvents methods for swizzling")
    }

    let didAddMethod = class_addMethod(
        GhosttyNSView.self,
        originalSelector,
        method_getImplementation(swizzledMethod),
        method_getTypeEncoding(swizzledMethod)
    )

    if didAddMethod {
        class_replaceMethod(
            GhosttyNSView.self,
            swizzledSelector,
            method_getImplementation(originalMethod),
            method_getTypeEncoding(originalMethod)
        )
    } else {
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    cjkIMEInterpretKeyEventsSwizzled = true
}

func installGhosttyPasteActionSwizzle() {
    guard !ghosttyPasteActionSwizzled else { return }

    let originalSelector = #selector(GhosttyNSView.paste(_:))
    let swizzledSelector = #selector(GhosttyNSView.cmuxUnitTest_paste(_:))

    guard let originalMethod = class_getInstanceMethod(GhosttyNSView.self, originalSelector),
          let swizzledMethod = class_getInstanceMethod(GhosttyNSView.self, swizzledSelector) else {
        fatalError("Unable to locate GhosttyNSView paste methods for swizzling")
    }

    let didAddMethod = class_addMethod(
        GhosttyNSView.self,
        originalSelector,
        method_getImplementation(swizzledMethod),
        method_getTypeEncoding(swizzledMethod)
    )

    if didAddMethod {
        class_replaceMethod(
            GhosttyNSView.self,
            swizzledSelector,
            method_getImplementation(originalMethod),
            method_getTypeEncoding(originalMethod)
        )
    } else {
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    ghosttyPasteActionSwizzled = true

    guard !ghosttyPasteAsPlainTextActionSwizzled else { return }

    let plainTextOriginalSelector = #selector(GhosttyNSView.pasteAsPlainText(_:))
    let plainTextSwizzledSelector = #selector(GhosttyNSView.cmuxUnitTest_pasteAsPlainText(_:))

    guard let plainTextOriginalMethod = class_getInstanceMethod(GhosttyNSView.self, plainTextOriginalSelector),
          let plainTextSwizzledMethod = class_getInstanceMethod(GhosttyNSView.self, plainTextSwizzledSelector) else {
        fatalError("Unable to locate GhosttyNSView pasteAsPlainText methods for swizzling")
    }

    let didAddPlainTextMethod = class_addMethod(
        GhosttyNSView.self,
        plainTextOriginalSelector,
        method_getImplementation(plainTextSwizzledMethod),
        method_getTypeEncoding(plainTextSwizzledMethod)
    )

    if didAddPlainTextMethod {
        class_replaceMethod(
            GhosttyNSView.self,
            plainTextSwizzledSelector,
            method_getImplementation(plainTextOriginalMethod),
            method_getTypeEncoding(plainTextOriginalMethod)
        )
    } else {
        method_exchangeImplementations(plainTextOriginalMethod, plainTextSwizzledMethod)
    }

    ghosttyPasteAsPlainTextActionSwizzled = true
}

func findGhosttyNSView(in view: NSView) -> GhosttyNSView? {
    if let view = view as? GhosttyNSView {
        return view
    }

    for subview in view.subviews {
        if let match = findGhosttyNSView(in: subview) {
            return match
        }
    }

    return nil
}
