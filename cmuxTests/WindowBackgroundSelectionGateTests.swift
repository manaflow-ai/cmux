@preconcurrency import XCTest
import CmuxSettings
import CmuxSocketControl
import AppKit
import Combine
import CoreText
import WebKit
import Darwin
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


final class WindowBackgroundSelectionGateTests: XCTestCase {
    func testShouldApplyWindowBackgroundUsesOwningWindowSelectionWhenAvailable() {
        let tabId = UUID()
        let activeSelectedTabId = UUID()

        XCTAssertTrue(
            GhosttyNSView.shouldApplyWindowBackground(
                surfaceTabId: tabId,
                owningManagerExists: true,
                owningSelectedTabId: tabId,
                activeSelectedTabId: activeSelectedTabId
            )
        )
    }

    func testShouldApplyWindowBackgroundRejectsWhenOwningSelectionDiffers() {
        let tabId = UUID()

        XCTAssertFalse(
            GhosttyNSView.shouldApplyWindowBackground(
                surfaceTabId: tabId,
                owningManagerExists: true,
                owningSelectedTabId: UUID(),
                activeSelectedTabId: tabId
            )
        )
    }

    func testShouldApplyWindowBackgroundAllowsWhenOwningManagerSelectionIsTemporarilyNil() {
        let tabId = UUID()

        XCTAssertTrue(
            GhosttyNSView.shouldApplyWindowBackground(
                surfaceTabId: tabId,
                owningManagerExists: true,
                owningSelectedTabId: nil,
                activeSelectedTabId: UUID()
            )
        )
    }

    func testShouldApplyWindowBackgroundFallsBackToActiveSelection() {
        let tabId = UUID()

        XCTAssertTrue(
            GhosttyNSView.shouldApplyWindowBackground(
                surfaceTabId: tabId,
                owningManagerExists: false,
                owningSelectedTabId: nil,
                activeSelectedTabId: tabId
            )
        )
        XCTAssertFalse(
            GhosttyNSView.shouldApplyWindowBackground(
                surfaceTabId: tabId,
                owningManagerExists: false,
                owningSelectedTabId: nil,
                activeSelectedTabId: UUID()
            )
        )
    }

    func testShouldApplyWindowBackgroundAllowsWhenNoSelectionContext() {
        XCTAssertTrue(
            GhosttyNSView.shouldApplyWindowBackground(
                surfaceTabId: UUID(),
                owningManagerExists: false,
                owningSelectedTabId: nil,
                activeSelectedTabId: nil
            )
        )
        XCTAssertTrue(
            GhosttyNSView.shouldApplyWindowBackground(
                surfaceTabId: nil,
                owningManagerExists: false,
                owningSelectedTabId: nil,
                activeSelectedTabId: nil
            )
        )
        XCTAssertTrue(
            GhosttyNSView.shouldApplyWindowBackground(
                surfaceTabId: nil,
                owningManagerExists: true,
                owningSelectedTabId: UUID(),
                activeSelectedTabId: UUID()
            )
        )
    }
}

