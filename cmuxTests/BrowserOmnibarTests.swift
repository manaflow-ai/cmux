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


// MARK: - Omnibar and address bar focus, registry, and keyboard navigation
final class BrowserAddressBarTrackingPolicyTests: XCTestCase {
    func testNonPointerWebViewFocusPreservesTrackedAddressBarWithLiveOmnibarField() {
        XCTAssertTrue(
            shouldPreserveBrowserAddressBarTrackingDuringWebViewFocus(
                BrowserAddressBarTrackingContext(
                    trackedPanelMatchesWebView: true,
                    omnibarResponderActive: false,
                    preferredFocusIntentIsAddressBar: true,
                    suppressesWebViewFocus: false,
                    pointerInitiatedWebFocus: false,
                    liveOmnibarFieldExists: true
                )
            )
        )
    }

    func testPointerWebViewFocusCanClearTrackedAddressBar() {
        XCTAssertFalse(
            shouldPreserveBrowserAddressBarTrackingDuringWebViewFocus(
                BrowserAddressBarTrackingContext(
                    trackedPanelMatchesWebView: true,
                    omnibarResponderActive: false,
                    preferredFocusIntentIsAddressBar: true,
                    suppressesWebViewFocus: true,
                    pointerInitiatedWebFocus: true,
                    liveOmnibarFieldExists: true
                )
            )
        )
    }

    func testOtherPanelWebViewFocusDoesNotPreserveAddressBarTracking() {
        XCTAssertFalse(
            shouldPreserveBrowserAddressBarTrackingDuringWebViewFocus(
                BrowserAddressBarTrackingContext(
                    trackedPanelMatchesWebView: false,
                    omnibarResponderActive: true,
                    preferredFocusIntentIsAddressBar: true,
                    suppressesWebViewFocus: true,
                    pointerInitiatedWebFocus: false,
                    liveOmnibarFieldExists: true
                )
            )
        )
    }
}

final class BrowserOmnibarNativeFieldRegistryTests: XCTestCase {
    @MainActor
    func testSpecificWindowLookupDoesNotReturnFieldFromAnotherWindow() {
        let panelId = UUID()
        let registry = BrowserOmnibarNativeFieldRegistry.shared
        let firstWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let secondWindow = NSWindow(
            contentRect: NSRect(x: 20, y: 20, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let firstContainer = NSView(frame: firstWindow.contentRect(forFrameRect: firstWindow.frame))
        let secondContainer = NSView(frame: secondWindow.contentRect(forFrameRect: secondWindow.frame))
        firstWindow.contentView = firstContainer
        secondWindow.contentView = secondContainer

        let field = OmnibarNativeTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.panelId = panelId
        firstContainer.addSubview(field)
        registry.register(field, panelId: panelId)

        defer {
            registry.unregister(field, panelId: panelId)
            field.removeFromSuperview()
            firstWindow.contentView = nil
            secondWindow.contentView = nil
            firstWindow.orderOut(nil)
            secondWindow.orderOut(nil)
        }

        XCTAssertTrue(registry.field(for: panelId, in: firstWindow) === field)
        XCTAssertNil(registry.field(for: panelId, in: secondWindow))
    }

    @MainActor
    func testNilWindowLookupPrefersAttachedFieldBeforeDetachedField() {
        let panelId = UUID()
        let registry = BrowserOmnibarNativeFieldRegistry.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let attachedField = OmnibarNativeTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        attachedField.panelId = panelId
        container.addSubview(attachedField)

        let detachedField = OmnibarNativeTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        detachedField.panelId = panelId

        registry.register(attachedField, panelId: panelId)
        registry.register(detachedField, panelId: panelId)

        defer {
            registry.unregister(attachedField, panelId: panelId)
            registry.unregister(detachedField, panelId: panelId)
            attachedField.removeFromSuperview()
            window.contentView = nil
            window.orderOut(nil)
        }

        XCTAssertTrue(registry.field(for: panelId) === attachedField)
    }
}

final class BrowserOmnibarKeyboardNavigationTests: XCTestCase {
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

    func testControlNavigationDeltaRequiresFocusedAddressBarAndControlOnly() {
        XCTAssertNil(
            browserOmnibarSelectionDeltaForControlNavigation(
                hasFocusedAddressBar: false,
                flags: [.control],
                chars: "n"
            )
        )

        XCTAssertNil(
            browserOmnibarSelectionDeltaForControlNavigation(
                hasFocusedAddressBar: true,
                flags: [.command],
                chars: "n"
            )
        )

        XCTAssertNil(
            browserOmnibarSelectionDeltaForControlNavigation(
                hasFocusedAddressBar: true,
                flags: [.command],
                chars: "p"
            )
        )

        XCTAssertNil(
            browserOmnibarSelectionDeltaForControlNavigation(
                hasFocusedAddressBar: true,
                flags: [.command, .shift],
                chars: "n"
            )
        )

        XCTAssertEqual(
            browserOmnibarSelectionDeltaForControlNavigation(
                hasFocusedAddressBar: true,
                flags: [.control],
                chars: "p"
            ),
            -1
        )

        XCTAssertEqual(
            browserOmnibarSelectionDeltaForControlNavigation(
                hasFocusedAddressBar: true,
                flags: [.control],
                chars: "n"
            ),
            1
        )
    }

    func testControlNavigationDeltaIgnoresCapsLockModifier() {
        XCTAssertEqual(
            browserOmnibarSelectionDeltaForControlNavigation(
                hasFocusedAddressBar: true,
                flags: [.control, .capsLock],
                chars: "n"
            ),
            1
        )
        XCTAssertNil(
            browserOmnibarSelectionDeltaForControlNavigation(
                hasFocusedAddressBar: true,
                flags: [.command, .capsLock],
                chars: "p"
            )
        )
    }

    func testMarkedTextBypassesOmnibarShortcutRoutingUnlessCommandModified() {
        XCTAssertTrue(
            browserOmnibarShouldBypassShortcutRoutingForMarkedText(
                hasFocusedAddressBar: true,
                firstResponderHasMarkedText: true,
                flags: []
            )
        )
        XCTAssertTrue(
            browserOmnibarShouldBypassShortcutRoutingForMarkedText(
                hasFocusedAddressBar: true,
                firstResponderHasMarkedText: true,
                flags: [.control]
            )
        )
        XCTAssertTrue(
            browserOmnibarShouldBypassShortcutRoutingForMarkedText(
                hasFocusedAddressBar: true,
                firstResponderHasMarkedText: true,
                flags: [.function]
            )
        )
        XCTAssertFalse(
            browserOmnibarShouldBypassShortcutRoutingForMarkedText(
                hasFocusedAddressBar: true,
                firstResponderHasMarkedText: true,
                flags: [.command]
            )
        )
        XCTAssertFalse(
            browserOmnibarShouldBypassShortcutRoutingForMarkedText(
                hasFocusedAddressBar: false,
                firstResponderHasMarkedText: true,
                flags: []
            )
        )
        XCTAssertFalse(
            browserOmnibarShouldBypassShortcutRoutingForMarkedText(
                hasFocusedAddressBar: true,
                firstResponderHasMarkedText: false,
                flags: []
            )
        )
    }

    func testControlNavigationRepeatLifecycleRequiresControlOnly() {
        XCTAssertTrue(browserOmnibarShouldContinueControlNavigationRepeat(flags: [.control]))
        XCTAssertTrue(browserOmnibarShouldContinueControlNavigationRepeat(flags: [.control, .capsLock]))
        XCTAssertFalse(browserOmnibarShouldContinueControlNavigationRepeat(flags: [.control, .command]))
        XCTAssertFalse(browserOmnibarShouldContinueControlNavigationRepeat(flags: [.control, .option]))
        XCTAssertFalse(browserOmnibarShouldContinueControlNavigationRepeat(flags: [.control, .shift]))
        XCTAssertFalse(browserOmnibarShouldContinueControlNavigationRepeat(flags: []))
    }

    func testSubmitOnReturnIgnoresCapsLockModifier() {
        XCTAssertTrue(browserOmnibarShouldSubmitOnReturn(flags: []))
        XCTAssertTrue(browserOmnibarShouldSubmitOnReturn(flags: [.shift]))
        XCTAssertTrue(browserOmnibarShouldSubmitOnReturn(flags: [.capsLock]))
        XCTAssertTrue(browserOmnibarShouldSubmitOnReturn(flags: [.shift, .capsLock]))
        XCTAssertFalse(browserOmnibarShouldSubmitOnReturn(flags: [.command, .capsLock]))
    }
}


final class BrowserOmnibarFocusPolicyTests: XCTestCase {
    func testReacquiresFocusWhenOmnibarStillWantsFocusAndNextResponderIsNotAnotherTextField() {
        XCTAssertTrue(
            browserOmnibarShouldReacquireFocusAfterEndEditing(
                desiredOmnibarFocus: true,
                nextResponderIsOtherTextField: false
            )
        )
    }

    func testDoesNotReacquireFocusWhenAnotherTextFieldAlreadyTookFocus() {
        XCTAssertFalse(
            browserOmnibarShouldReacquireFocusAfterEndEditing(
                desiredOmnibarFocus: true,
                nextResponderIsOtherTextField: true
            )
        )
    }

    func testDoesNotReacquireFocusWhenOmnibarNoLongerWantsFocus() {
        XCTAssertFalse(
            browserOmnibarShouldReacquireFocusAfterEndEditing(
                desiredOmnibarFocus: false,
                nextResponderIsOtherTextField: false
            )
        )
    }
}
