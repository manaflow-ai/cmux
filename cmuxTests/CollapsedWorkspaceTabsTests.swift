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

final class CollapsedWorkspaceTabsVisibilityTests: XCTestCase {
    func testHiddenWhenSidebarVisible() {
        XCTAssertFalse(
            CollapsedWorkspaceTabsPolicy.shouldShowCollapsedTabs(sidebarVisible: true, workspaceCount: 3)
        )
    }

    func testHiddenWithSingleWorkspace() {
        XCTAssertFalse(
            CollapsedWorkspaceTabsPolicy.shouldShowCollapsedTabs(sidebarVisible: false, workspaceCount: 1)
        )
    }

    func testHiddenWithZeroWorkspaces() {
        XCTAssertFalse(
            CollapsedWorkspaceTabsPolicy.shouldShowCollapsedTabs(sidebarVisible: false, workspaceCount: 0)
        )
    }

    func testVisibleWhenSidebarHiddenAndMultipleWorkspaces() {
        XCTAssertTrue(
            CollapsedWorkspaceTabsPolicy.shouldShowCollapsedTabs(sidebarVisible: false, workspaceCount: 2)
        )
    }

    func testVisibleWithManyWorkspaces() {
        XCTAssertTrue(
            CollapsedWorkspaceTabsPolicy.shouldShowCollapsedTabs(sidebarVisible: false, workspaceCount: 10)
        )
    }

    func testHiddenWhenSidebarVisibleEvenWithManyWorkspaces() {
        XCTAssertFalse(
            CollapsedWorkspaceTabsPolicy.shouldShowCollapsedTabs(sidebarVisible: true, workspaceCount: 10)
        )
    }
}


final class CollapsedWorkspaceTabsSeparatorTests: XCTestCase {
    func testSeparatorShownWhenSidebarVisible() {
        XCTAssertTrue(
            CollapsedWorkspaceTabsPolicy.shouldShowTitlebarSeparator(sidebarVisible: true, workspaceCount: 3)
        )
    }

    func testSeparatorShownWithSingleWorkspace() {
        XCTAssertTrue(
            CollapsedWorkspaceTabsPolicy.shouldShowTitlebarSeparator(sidebarVisible: false, workspaceCount: 1)
        )
    }

    func testSeparatorHiddenWhenCollapsedTabsVisible() {
        XCTAssertFalse(
            CollapsedWorkspaceTabsPolicy.shouldShowTitlebarSeparator(sidebarVisible: false, workspaceCount: 2)
        )
    }

    func testSeparatorAndCollapsedTabsAreMutuallyExclusive() {
        for sidebarVisible in [true, false] {
            for count in 0...5 {
                let showTabs = CollapsedWorkspaceTabsPolicy.shouldShowCollapsedTabs(
                    sidebarVisible: sidebarVisible, workspaceCount: count
                )
                let showSeparator = CollapsedWorkspaceTabsPolicy.shouldShowTitlebarSeparator(
                    sidebarVisible: sidebarVisible, workspaceCount: count
                )
                XCTAssertNotEqual(
                    showTabs, showSeparator,
                    "Tabs and separator must be mutually exclusive (sidebar=\(sidebarVisible), count=\(count))"
                )
            }
        }
    }
}


final class CollapsedWorkspaceTabsColorTests: XCTestCase {
    func testActiveTabUsesSidebarSelectedForeground() {
        let color = CollapsedWorkspaceTabsPolicy.foregroundNSColor(
            isActive: true, opacity: 1.0, colorScheme: .dark
        )
        let expected = sidebarSelectedWorkspaceForegroundNSColor(opacity: 1.0)
        guard let srgb = color.usingColorSpace(.sRGB),
              let expectedSrgb = expected.usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }
        XCTAssertEqual(srgb.redComponent, expectedSrgb.redComponent, accuracy: 0.001)
        XCTAssertEqual(srgb.greenComponent, expectedSrgb.greenComponent, accuracy: 0.001)
        XCTAssertEqual(srgb.blueComponent, expectedSrgb.blueComponent, accuracy: 0.001)
        XCTAssertEqual(srgb.alphaComponent, expectedSrgb.alphaComponent, accuracy: 0.001)
    }

    func testInactiveTabUsesSecondaryLabelColor() {
        let color = CollapsedWorkspaceTabsPolicy.foregroundNSColor(
            isActive: false, opacity: 0.7, colorScheme: .dark
        )
        let expected = NSColor.secondaryLabelColor.withAlphaComponent(0.7)
        guard let srgb = color.usingColorSpace(.sRGB),
              let expectedSrgb = expected.usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }
        XCTAssertEqual(srgb.redComponent, expectedSrgb.redComponent, accuracy: 0.001)
        XCTAssertEqual(srgb.greenComponent, expectedSrgb.greenComponent, accuracy: 0.001)
        XCTAssertEqual(srgb.blueComponent, expectedSrgb.blueComponent, accuracy: 0.001)
        XCTAssertEqual(srgb.alphaComponent, expectedSrgb.alphaComponent, accuracy: 0.001)
    }

    func testActiveBackgroundUsesSidebarSelectedBackground() {
        let color = CollapsedWorkspaceTabsPolicy.backgroundNSColor(isActive: true, colorScheme: .dark)
        let expected = sidebarSelectedWorkspaceBackgroundNSColor(for: .dark)
        guard let srgb = color.usingColorSpace(.sRGB),
              let expectedSrgb = expected.usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }
        XCTAssertEqual(srgb.redComponent, expectedSrgb.redComponent, accuracy: 0.001)
        XCTAssertEqual(srgb.greenComponent, expectedSrgb.greenComponent, accuracy: 0.001)
        XCTAssertEqual(srgb.blueComponent, expectedSrgb.blueComponent, accuracy: 0.001)
        XCTAssertEqual(srgb.alphaComponent, expectedSrgb.alphaComponent, accuracy: 0.001)
    }

    func testInactiveBackgroundIsClear() {
        let color = CollapsedWorkspaceTabsPolicy.backgroundNSColor(isActive: false, colorScheme: .dark)
        guard let srgb = color.usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }
        XCTAssertEqual(srgb.alphaComponent, 0, accuracy: 0.001)
    }
}
