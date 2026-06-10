import XCTest
import Testing
import CmuxControlSocket
import CmuxTerminalCopyMode
import CmuxSocketControl
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import CMUXMobileCore
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


final class GhosttyResponderResolutionTests: XCTestCase {
    private final class FocusProbeView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private final class DelegateTrackingTextView: NSTextView {
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

    func testDoesNotReadTextViewDelegateForGhosttyResponderResolution() {
        let textView = DelegateTrackingTextView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))

        XCTAssertNil(cmuxOwningGhosttyView(for: textView))
        XCTAssertEqual(
            textView.delegateReadCount,
            0,
            "Ghostty responder resolution must avoid NSTextView.delegate because AppKit exposes it as unsafe-unretained"
        )
    }
}


