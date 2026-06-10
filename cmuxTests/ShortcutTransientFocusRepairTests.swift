import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Sparkle
import CmuxUpdater

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Transient focus guard and repair for shortcut routing
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

final class CommandEquivalentTransientFocusRepairTests: XCTestCase {
    func testRepairsCommandEquivalentWhenFirstResponderFallsBackToWindow() {
        XCTAssertTrue(
            shouldRepairFocusedTerminalCommandEquivalentInputs(
                flags: [.command],
                responderIsWindow: true,
                responderHasViableKeyRoutingOwner: false
            )
        )
    }

    func testRepairsCommandEquivalentWhenResponderHasNoViableOwner() {
        XCTAssertTrue(
            shouldRepairFocusedTerminalCommandEquivalentInputs(
                flags: [.command],
                responderIsWindow: false,
                responderHasViableKeyRoutingOwner: false
            )
        )
    }

    func testDoesNotRepairCommandEquivalentWhenLiveResponderDiffersFromSelectedPane() {
        XCTAssertFalse(
            shouldRepairFocusedTerminalCommandEquivalentInputs(
                flags: [.command],
                responderIsWindow: false,
                responderHasViableKeyRoutingOwner: true
            )
        )
    }

    func testDoesNotRepairCommandEquivalentWhenResponderHasViableOwner() {
        XCTAssertFalse(
            shouldRepairFocusedTerminalCommandEquivalentInputs(
                flags: [.command],
                responderIsWindow: false,
                responderHasViableKeyRoutingOwner: true
            )
        )
    }

    func testIgnoresNonCommandEvents() {
        XCTAssertFalse(
            shouldRepairFocusedTerminalCommandEquivalentInputs(
                flags: [],
                responderIsWindow: true,
                responderHasViableKeyRoutingOwner: false
            )
        )
    }
}

