import AppKit
import Combine
import SwiftUI
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SidebarWidthPolicyTests: XCTestCase {
    func testContentViewClampAllowsNarrowSidebarBelowLegacyMinimum() {
        XCTAssertEqual(
            ContentView.clampedSidebarWidth(184, maximumWidth: 600),
            184,
            accuracy: 0.001
        )
    }

    func testRightSidebarClampAllowsWideExplorerOnLargeWindows() {
        XCTAssertEqual(
            ContentView.clampedRightSidebarWidth(900, availableWidth: 1600),
            900,
            accuracy: 0.001
        )
    }

    func testRightSidebarClampLeavesTerminalWidth() {
        XCTAssertEqual(
            ContentView.clampedRightSidebarWidth(10_000, availableWidth: 1000),
            640,
            accuracy: 0.001
        )
    }

    func testRightSidebarClampKeepsMinimumWidth() {
        XCTAssertEqual(
            ContentView.clampedRightSidebarWidth(20, availableWidth: 1000),
            276,
            accuracy: 0.001
        )
    }

    func testLeadingSidebarResizeRangeFavorsSidebarSide() {
        let range = SidebarResizeInteraction.Edge.leading.hitRange(dividerX: 200)

        XCTAssertEqual(range.lowerBound, 194, accuracy: 0.001)
        XCTAssertEqual(range.upperBound, 204, accuracy: 0.001)
        XCTAssertTrue(range.contains(196))
        XCTAssertTrue(range.contains(202))
        XCTAssertFalse(range.contains(193.9))
        XCTAssertFalse(range.contains(204.1))
    }

    func testTrailingSidebarResizeRangeFavorsSidebarSide() {
        let range = SidebarResizeInteraction.Edge.trailing.hitRange(dividerX: 680)

        XCTAssertEqual(range.lowerBound, 676, accuracy: 0.001)
        XCTAssertEqual(range.upperBound, 686, accuracy: 0.001)
        XCTAssertTrue(range.contains(678))
        XCTAssertTrue(range.contains(684))
        XCTAssertFalse(range.contains(675.9))
        XCTAssertFalse(range.contains(686.1))
    }

    func testLeftSidebarVisibilityTogglePublishesSingleInvalidation() {
        let state = SidebarState(isVisible: true)
        var invalidationCount = 0
        let cancellable = state.objectWillChange.sink {
            invalidationCount += 1
        }

        state.toggle()

        withExtendedLifetime(cancellable) {}
        XCTAssertEqual(invalidationCount, 1)
    }

    func testRightSidebarVisibilityTogglePublishesSingleInvalidation() {
        let defaults = UserDefaults.standard
        let hadStoredVisibility = defaults.object(forKey: "fileExplorer.isVisible") != nil
        let storedVisibility = defaults.bool(forKey: "fileExplorer.isVisible")
        defaults.set(true, forKey: "fileExplorer.isVisible")
        defer {
            if hadStoredVisibility {
                defaults.set(storedVisibility, forKey: "fileExplorer.isVisible")
            } else {
                defaults.removeObject(forKey: "fileExplorer.isVisible")
            }
        }

        let state = FileExplorerState()
        var invalidationCount = 0
        let cancellable = state.objectWillChange.sink {
            invalidationCount += 1
        }

        state.toggle()

        withExtendedLifetime(cancellable) {}
        XCTAssertEqual(invalidationCount, 1)
    }
}

@MainActor
final class SidebarVisibilityShortcutTests: XCTestCase {
    func testEnqueuedLeftSidebarVisibilityShortcutRunsImmediatelyAndTargetsPreferredWindow() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondWindow = window(withId: secondWindowId),
              let firstVisibleBefore = appDelegate.sidebarVisibility(windowId: firstWindowId),
              let secondVisibleBefore = appDelegate.sidebarVisibility(windowId: secondWindowId) else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        appDelegate.tabManager = firstManager
        appDelegate.enqueueLeftSidebarVisibilityShortcut(preferredWindow: secondWindow)

        XCTAssertEqual(appDelegate.sidebarVisibility(windowId: firstWindowId), firstVisibleBefore)
        XCTAssertEqual(
            appDelegate.sidebarVisibility(windowId: secondWindowId),
            !secondVisibleBefore,
            "Left-sidebar shortcut should route through the preferred window without a main-actor turn delay"
        )
    }

    private func window(withId windowId: UUID) -> NSWindow? {
        let identifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == identifier })
    }

    private func closeWindow(withId windowId: UUID) {
        guard let window = window(withId: windowId) else { return }
        window.performClose(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
}

final class SidebarWorkspaceSelectionColorTests: XCTestCase {
    func testSelectedColoredWorkspaceUsesStandardSelectionBackgroundInLightAndDark() {
        for colorScheme in [ColorScheme.light, .dark] {
            let coloredSelected = sidebarWorkspaceRowBackgroundStyle(
                activeTabIndicatorStyle: .solidFill,
                isActive: true,
                isMultiSelected: false,
                customColorHex: "#E85D75",
                colorScheme: colorScheme,
                sidebarSelectionColorHex: nil
            )
            let standardSelected = sidebarWorkspaceRowBackgroundStyle(
                activeTabIndicatorStyle: .solidFill,
                isActive: true,
                isMultiSelected: false,
                customColorHex: nil,
                colorScheme: colorScheme,
                sidebarSelectionColorHex: nil
            )

            XCTAssertEqual(coloredSelected.opacity, standardSelected.opacity, accuracy: 0.001)
            XCTAssertEqual(coloredSelected.opacity, 1, accuracy: 0.001)
            assertColor(coloredSelected.color, equals: standardSelected.color)

            let unselectedColored = sidebarWorkspaceRowBackgroundStyle(
                activeTabIndicatorStyle: .solidFill,
                isActive: false,
                isMultiSelected: false,
                customColorHex: "#E85D75",
                colorScheme: colorScheme,
                sidebarSelectionColorHex: nil
            )
            XCTAssertEqual(unselectedColored.opacity, 0.7, accuracy: 0.001)
            XCTAssertFalse(
                colorsAreEqual(coloredSelected.color, unselectedColored.color),
                "Selected row should use the standard selection background, not the workspace tab color"
            )
        }
    }

    func testSelectedColoredWorkspaceUsesConfiguredSelectionBackground() {
        let selectionHex = "#123456"
        let coloredSelected = sidebarWorkspaceRowBackgroundStyle(
            activeTabIndicatorStyle: .solidFill,
            isActive: true,
            isMultiSelected: false,
            customColorHex: "#E85D75",
            colorScheme: .light,
            sidebarSelectionColorHex: selectionHex
        )
        let standardSelected = sidebarWorkspaceRowBackgroundStyle(
            activeTabIndicatorStyle: .solidFill,
            isActive: true,
            isMultiSelected: false,
            customColorHex: nil,
            colorScheme: .light,
            sidebarSelectionColorHex: selectionHex
        )

        XCTAssertEqual(coloredSelected.opacity, 1, accuracy: 0.001)
        assertColor(coloredSelected.color, equals: standardSelected.color)
        assertColor(coloredSelected.color, equals: NSColor(hex: selectionHex))
    }

    private func assertColor(
        _ actual: NSColor?,
        equals expected: NSColor?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual, let expected else {
            XCTAssertNotNil(actual, file: file, line: line)
            XCTAssertNotNil(expected, file: file, line: line)
            return
        }

        XCTAssertTrue(
            colorsAreEqual(actual, expected),
            "Expected \(colorDescription(actual)) to equal \(colorDescription(expected))",
            file: file,
            line: line
        )
    }

    private func colorsAreEqual(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
        guard let lhs, let rhs else {
            return lhs == nil && rhs == nil
        }
        guard let lhsRGB = lhs.usingColorSpace(.sRGB),
              let rhsRGB = rhs.usingColorSpace(.sRGB) else {
            return false
        }

        var lhsRed: CGFloat = 0
        var lhsGreen: CGFloat = 0
        var lhsBlue: CGFloat = 0
        var lhsAlpha: CGFloat = 0
        var rhsRed: CGFloat = 0
        var rhsGreen: CGFloat = 0
        var rhsBlue: CGFloat = 0
        var rhsAlpha: CGFloat = 0
        lhsRGB.getRed(&lhsRed, green: &lhsGreen, blue: &lhsBlue, alpha: &lhsAlpha)
        rhsRGB.getRed(&rhsRed, green: &rhsGreen, blue: &rhsBlue, alpha: &rhsAlpha)

        return abs(lhsRed - rhsRed) <= 0.001 &&
            abs(lhsGreen - rhsGreen) <= 0.001 &&
            abs(lhsBlue - rhsBlue) <= 0.001 &&
            abs(lhsAlpha - rhsAlpha) <= 0.001
    }

    private func colorDescription(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else {
            return color.description
        }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "rgba(%.3f, %.3f, %.3f, %.3f)",
            red,
            green,
            blue,
            alpha
        )
    }
}
