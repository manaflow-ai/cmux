import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Browser Omnibar Native Field & Overlay
@MainActor
final class BrowserOmnibarNativeFieldRegistryWindowSelectionTests: XCTestCase {
    func testFieldLookupPrefersMatchingWindowAndNilWindowPrefersAttachedField() throws {
        let panelId = UUID()
        let registry = BrowserOmnibarNativeFieldRegistry()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 32),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 32))
        let visibleField = OmnibarNativeTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        let offWindowField = OmnibarNativeTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        visibleField.panelId = panelId
        offWindowField.panelId = panelId
        contentView.addSubview(visibleField)
        window.contentView = contentView
        defer {
            registry.unregister(visibleField, panelId: panelId)
            registry.unregister(offWindowField, panelId: panelId)
            visibleField.removeFromSuperview()
            window.contentView = nil
            window.orderOut(nil)
        }

        registry.register(visibleField, panelId: panelId)
        registry.register(offWindowField, panelId: panelId)

        XCTAssertTrue(registry.field(for: panelId, in: window) === visibleField)
        XCTAssertTrue(registry.field(for: panelId, in: nil) === visibleField)
        XCTAssertTrue(registry.field(for: panelId) === visibleField)

        registry.unregister(offWindowField, panelId: panelId)

        XCTAssertTrue(registry.field(for: panelId) === visibleField)
    }

    func testWindowLookupDoesNotFallBackAcrossWindows() throws {
        let panelId = UUID()
        let registry = BrowserOmnibarNativeFieldRegistry()
        let sourceWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 32),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let requestedWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 32),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 32))
        let sourceField = OmnibarNativeTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        sourceField.panelId = panelId
        contentView.addSubview(sourceField)
        sourceWindow.contentView = contentView
        defer {
            registry.unregister(sourceField, panelId: panelId)
            sourceField.removeFromSuperview()
            sourceWindow.contentView = nil
            sourceWindow.orderOut(nil)
            requestedWindow.orderOut(nil)
        }

        registry.register(sourceField, panelId: panelId)

        XCTAssertTrue(registry.field(for: panelId, in: sourceWindow) === sourceField)
        XCTAssertNil(registry.field(for: panelId, in: requestedWindow))
    }

    func testInteractionOverlayPassesThroughUntilFieldIsRegisteredInWindow() throws {
        let panelId = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 32),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 32))
        let field = OmnibarNativeTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        let interactionView = BrowserOmnibarInteractionView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.panelId = panelId
        interactionView.panelId = panelId
        contentView.addSubview(field)
        contentView.addSubview(interactionView)
        window.contentView = contentView
        defer {
            BrowserOmnibarNativeFieldRegistry.shared.unregister(field, panelId: panelId)
            field.removeFromSuperview()
            interactionView.removeFromSuperview()
            window.contentView = nil
            window.orderOut(nil)
        }

        XCTAssertNil(
            interactionView.hitTest(NSPoint(x: 12, y: 12)),
            "The overlay must not swallow the first click before it has a forwarding target"
        )

        BrowserOmnibarNativeFieldRegistry.shared.register(field, panelId: panelId)

        XCTAssertTrue(
            interactionView.hitTest(NSPoint(x: 12, y: 12)) === interactionView,
            "The overlay should capture events once it can forward to the same-window native field"
        )
    }
}

@MainActor
final class BrowserPortalOmnibarSuggestionsTests: XCTestCase {
    func testPortalSuggestionsOverlayPassesHitTestingOutsidePopupFrame() {
        let slot = WindowBrowserSlotView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
        let item = OmnibarSuggestion.search(engineName: "Google", query: "news")
        let popupFrame = CGRect(
            x: 40,
            y: 12,
            width: 220,
            height: OmnibarSuggestionsView.popupHeight(for: [item])
        )

        slot.setOmnibarSuggestions(
            BrowserPortalOmnibarSuggestionsConfiguration(
                panelId: UUID(),
                popupFrame: popupFrame,
                colorScheme: .dark,
                engineName: "Google",
                items: [item],
                selectedIndex: 0,
                isLoadingRemoteSuggestions: false,
                searchSuggestionsEnabled: true,
                onCommit: { _ in XCTFail("Unexpected commit") },
                onHighlight: { _ in XCTFail("Unexpected highlight") }
            )
        )
        slot.layoutSubtreeIfNeeded()

        let overlay = slot.subviews.first {
            String(describing: type(of: $0)).contains("OmnibarSuggestionsHostingView")
        }
        XCTAssertNotNil(overlay)
        guard let overlay else { return }

        XCTAssertNil(overlay.hitTest(NSPoint(x: 8, y: 8)))

        let insideTopLeftPoint = NSPoint(x: popupFrame.midX, y: popupFrame.midY)
        let insidePoint = overlay.isFlipped
            ? insideTopLeftPoint
            : NSPoint(x: insideTopLeftPoint.x, y: overlay.bounds.height - insideTopLeftPoint.y)
        XCTAssertNotNil(overlay.hitTest(insidePoint))
    }
}

@MainActor
final class BrowserOmnibarFieldEditorResolutionTests: XCTestCase {
    func testPanelIdResolutionUsesLiveOmnibarFieldWhenFieldEditorResponderChainIsStale() {
        _ = NSApplication.shared

        let panelId = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView

        let staleWebView = CmuxWebView(frame: NSRect(x: 0, y: 0, width: 420, height: 80), configuration: WKWebViewConfiguration())
        contentView.addSubview(staleWebView)

        let field = OmnibarNativeTextField(frame: NSRect(x: 8, y: 28, width: 300, height: 24))
        field.panelId = panelId
        contentView.addSubview(field)

        window.makeKeyAndOrderFront(nil)
        defer {
            field.removeFromSuperview()
            staleWebView.removeFromSuperview()
            window.contentView = nil
            window.orderOut(nil)
        }

        XCTAssertTrue(window.makeFirstResponder(field))
        guard let editor = field.currentEditor() as? NSTextView else {
            XCTFail("Expected omnibar field editor after focusing text field")
            return
        }

        let originalNextResponder = editor.nextResponder
        editor.nextResponder = staleWebView
        defer {
            editor.nextResponder = originalNextResponder
        }

        XCTAssertEqual(
            browserOmnibarPanelId(for: editor),
            panelId,
            "A live omnibar field editor must resolve to its owning omnibar field even when AppKit leaves a stale browser responder chain behind"
        )
    }
}


