import JavaScriptCore
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for https://github.com/manaflow-ai/cmux — the address-bar
/// focus tracker used to stamp `data-cmux-addressbar-focus-id` onto focused inputs
/// via `setAttribute`, which mutated server-rendered DOM nodes and broke
/// React/Next.js hydration on localhost dev pages. Focus identity now lives in an
/// in-page WeakMap registry, so capture must not touch the DOM while capture →
/// restore still round-trips.
final class BrowserAddressBarFocusTrackingTests: XCTestCase {
    private func makeContextWithMockDOM() -> JSContext {
        let context = JSContext()!
        context.exceptionHandler = { _, exception in
            XCTFail("Unexpected JS exception: \(exception?.toString() ?? "unknown")")
        }
        // Minimal DOM stand-in. getAttribute always returns null and querySelector
        // never matches, so any code that relies on the focus-id attribute (the old
        // behavior) cannot recover the element — only the registry can.
        context.evaluateScript(
            """
            var window = {};
            window.top = window;
            var __setAttrCalls = [];
            var el = {
              tagName: "INPUT",
              type: "text",
              isContentEditable: false,
              isConnected: true,
              value: "hello",
              selectionStart: 1,
              selectionEnd: 3,
              __focused: false,
              getAttribute: function () { return null; },
              setAttribute: function (name) { __setAttrCalls.push(name); },
              focus: function () { this.__focused = true; document.activeElement = this; },
              matches: function () { return this.__focused; },
              setSelectionRange: function (start, end) { this.__selStart = start; this.__selEnd = end; }
            };
            var document = {
              activeElement: el,
              querySelector: function () { return null; },
              querySelectorAll: function () { return []; },
              addEventListener: function () {}
            };
            el.ownerDocument = document;
            """
        )
        return context
    }

    func testCaptureDoesNotWriteFocusIdAttributeToDOM() {
        let context = makeContextWithMockDOM()

        let result = context.evaluateScript(BrowserPanel.addressBarFocusCaptureScript)?.toString() ?? ""
        XCTAssertTrue(result.hasPrefix("captured:"), "capture should record the focused editable element; got \(result)")

        let setAttrCalls = context.evaluateScript("__setAttrCalls.join(',')")?.toString() ?? ""
        XCTAssertFalse(
            setAttrCalls.contains("data-cmux-addressbar-focus-id"),
            "focus tracking must not write data-cmux-addressbar-focus-id to the DOM (it regressed React hydration); setAttribute calls were: \(setAttrCalls)"
        )

        let stateId = context.evaluateScript("(window.__cmuxAddressBarFocusState || {}).id || \"\"")?.toString() ?? ""
        XCTAssertFalse(stateId.isEmpty, "capture should still produce a focus-state id")
    }

    func testCaptureThenRestoreRoundTripsViaRegistry() {
        let context = makeContextWithMockDOM()

        _ = context.evaluateScript(BrowserPanel.addressBarFocusCaptureScript)
        // Clear focus so restore must re-find the element through the registry
        // rather than reading document.activeElement or a DOM attribute selector.
        context.evaluateScript("el.__focused = false; document.activeElement = null;")

        let restored = context.evaluateScript(BrowserPanel.addressBarFocusRestoreScript)?.toString()
        XCTAssertEqual(restored, "restored", "focus restore must find the element via the registry without the DOM attribute")

        let selStart = context.evaluateScript("el.__selStart")?.toInt32()
        let selEnd = context.evaluateScript("el.__selEnd")?.toInt32()
        XCTAssertEqual(selStart, 1, "restore should reapply the captured selection start")
        XCTAssertEqual(selEnd, 3, "restore should reapply the captured selection end")
    }
}
