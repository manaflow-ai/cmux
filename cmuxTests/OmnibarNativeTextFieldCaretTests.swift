import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Darwin
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


@MainActor
final class OmnibarNativeTextFieldCaretTests: XCTestCase {
    /// A window that hands the omnibar field a real, controllable field editor so
    /// the click path can be exercised headlessly in CI (mirrors the probe pattern
    /// used by the omnibar key-routing tests in `BrowserConfigTests`).
    private final class CaretProbeWindow: NSWindow {
        let probeFieldEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 24))

        override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
            probeFieldEditor
        }
    }

    private func makeMouseEvent(
        type: NSEvent.EventType,
        location: NSPoint,
        window: NSWindow,
        clickCount: Int = 1,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1.0
        ) else {
            fatalError("Failed to create \(type) mouse event")
        }
        return event
    }

    private func makeCoordinator(
        panelId: UUID = UUID(),
        isFocused: Bool = true
    ) -> OmnibarTextFieldRepresentable.Coordinator {
        var text = ""
        var focused = isFocused
        return OmnibarTextFieldRepresentable.Coordinator(
            parent: OmnibarTextFieldRepresentable(
                panelId: panelId,
                fontSize: 12,
                text: Binding(
                    get: { text },
                    set: { text = $0 }
                ),
                isFocused: Binding(
                    get: { focused },
                    set: { focused = $0 }
                ),
                selectAllRequestId: 0,
                inlineCompletion: nil,
                placeholder: "",
                onTap: {},
                onSubmit: {},
                onEscape: {},
                onFieldLostFocus: {},
                onMoveSelection: { _ in },
                onDeleteSelectedSuggestion: {},
                onAcceptInlineCompletion: {},
                onDeleteBackwardWithInlineSelection: {},
                onClearTypedPrefixWithInlineSelection: {},
                onDeleteWordBackwardWithInlineSelection: {},
                onSelectionChanged: { _, _ in },
                shouldSuppressWebViewFocus: { false }
            )
        )
    }

    private func makeCaretProbeWindow() -> CaretProbeWindow {
        let window = CaretProbeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        return window
    }

    private func installOmnibarField(
        in window: NSWindow,
        stringValue: String = "https://github.com/manaflow-ai/cmux"
    ) -> OmnibarNativeTextField {
        let field = OmnibarNativeTextField(frame: NSRect(x: 12, y: 80, width: 360, height: 24))
        field.font = .systemFont(ofSize: 12)
        field.isEditable = true
        field.isSelectable = true
        field.isEnabled = true
        field.stringValue = stringValue
        window.contentView?.addSubview(field)
        return field
    }

    private func cleanup(window: NSWindow, field: OmnibarNativeTextField) {
        field.removeFromSuperview()
        window.contentView = nil
        window.orderOut(nil)
    }

    private func singleClick(field: OmnibarNativeTextField, in window: NSWindow) {
        let clickPoint = NSPoint(x: field.frame.midX, y: field.frame.midY)
        let pointInWindow = window.contentView?.convert(clickPoint, to: nil) ?? clickPoint
        field.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: pointInWindow, window: window))
        field.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: pointInWindow, window: window))
    }

    /// Regression for https://github.com/manaflow-ai/cmux/issues/5268: a single,
    /// unmodified click that focuses the omnibar must leave a caret (zero-length
    /// selection) at the click position, not select the entire URL.
    func testSingleClickFocusPlacesCaretInsteadOfSelectingAll() {
        let window = makeCaretProbeWindow()
        let field = installOmnibarField(in: window)
        window.makeKeyAndOrderFront(nil)
        defer {
            cleanup(window: window, field: field)
        }

        // Do NOT pre-focus: the bug only manifests on the click that first acquires
        // focus, where the old code forced a select-all on mouseUp.
        singleClick(field: field, in: window)

        guard let editor = field.currentEditor() as? NSTextView else {
            XCTFail("Expected a field editor after the click acquired focus")
            return
        }
        let textLength = (editor.string as NSString).length
        XCTAssertGreaterThan(textLength, 0, "Test precondition: the omnibar should contain a URL")
        XCTAssertEqual(
            editor.selectedRange().length,
            0,
            "A single click must place a caret, not select the whole URL"
        )
    }

    /// The native single-click path can place a caret correctly and still be
    /// clobbered later by the SwiftUI focus-gained effect. This exercises that
    /// full behavior path instead of only checking the field's mouse handlers.
    func testSwiftUIFocusGainedEffectDoesNotClobberSingleClickCaret() {
        let window = makeCaretProbeWindow()
        let field = installOmnibarField(in: window)
        window.makeKeyAndOrderFront(nil)
        defer {
            cleanup(window: window, field: field)
        }

        singleClick(field: field, in: window)

        guard let editor = field.currentEditor() as? NSTextView else {
            XCTFail("Expected a field editor after the click acquired focus")
            return
        }
        XCTAssertEqual(editor.selectedRange().length, 0, "Test precondition: native click should place a caret")

        var state = OmnibarState()
        let effects = omnibarReduce(
            state: &state,
            event: .focusGained(currentURLString: field.stringValue)
        )
        let coordinator = makeCoordinator()
        coordinator.parentField = field
        if effects.shouldSelectAll {
            coordinator.queueSelectAllRequest(1)
            _ = coordinator.applyPendingSelectAllIfPossible(field: field)
        }

        XCTAssertEqual(
            editor.selectedRange().length,
            0,
            "Focus-gained handling must preserve the caret placed by the focusing click"
        )
    }

    /// Pane focus reconciliation can reassert omnibar focus after the click has
    /// already placed the caret. That restore path must not treat the click as
    /// Cmd+L and select the full URL.
    func testFocusRestoreReassertionDoesNotClobberSingleClickCaret() {
        let window = makeCaretProbeWindow()
        let field = installOmnibarField(in: window)
        window.makeKeyAndOrderFront(nil)
        defer {
            cleanup(window: window, field: field)
        }

        singleClick(field: field, in: window)

        guard let editor = field.currentEditor() as? NSTextView else {
            XCTFail("Expected a field editor after the click acquired focus")
            return
        }
        XCTAssertEqual(editor.selectedRange().length, 0, "Test precondition: native click should place a caret")

        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: field.stringValue))
        let effects = omnibarReduce(
            state: &state,
            event: .focusReasserted(
                shouldSelectAll: browserOmnibarShouldSelectAllOnFocusReassertion(
                    selectionIntent: .preserveFieldEditorSelection
                )
            )
        )

        let coordinator = makeCoordinator()
        coordinator.parentField = field
        if effects.shouldSelectAll {
            coordinator.queueSelectAllRequest(1)
            _ = coordinator.applyPendingSelectAllIfPossible(field: field)
        }

        XCTAssertEqual(
            editor.selectedRange().length,
            0,
            "Focus-restore reassertion must preserve the caret placed by the focusing click"
        )
    }

    func testExplicitSelectAllRequestStillSelectsWholeURL() {
        let window = makeCaretProbeWindow()
        let field = installOmnibarField(in: window)
        window.makeKeyAndOrderFront(nil)
        defer {
            cleanup(window: window, field: field)
        }

        XCTAssertTrue(window.makeFirstResponder(field))
        guard let editor = field.currentEditor() as? NSTextView else {
            XCTFail("Expected a field editor after focusing text field")
            return
        }
        let textLength = (editor.string as NSString).length
        editor.setSelectedRange(NSRange(location: textLength, length: 0))

        let coordinator = makeCoordinator()
        coordinator.parentField = field
        coordinator.queueSelectAllRequest(1)

        XCTAssertTrue(coordinator.applyPendingSelectAllIfPossible(field: field))
        XCTAssertEqual(
            editor.selectedRange(),
            NSRange(location: 0, length: textLength),
            "Explicit omnibar focus requests such as Cmd+L must still select the whole URL"
        )
    }
}
