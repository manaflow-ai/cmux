import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Combine

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Sidebar workspace presentation
final class SidebarSelectedWorkspaceColorTests: XCTestCase {
    func testLightModeUsesConfiguredSelectedWorkspaceBackgroundColor() {
        guard let color = sidebarSelectedWorkspaceBackgroundNSColor(for: .light).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(color.redComponent, 0, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 136.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 1.0, accuracy: 0.001)
    }

    func testDarkModeUsesConfiguredSelectedWorkspaceBackgroundColor() {
        guard let color = sidebarSelectedWorkspaceBackgroundNSColor(for: .dark).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(color.redComponent, 0, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 145.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 1.0, accuracy: 0.001)
    }

    func testSelectedWorkspaceForegroundUsesBlackOnLightSelectionBackground() {
        guard let color = sidebarSelectedWorkspaceForegroundNSColor(
            on: NSColor(hex: "#FFFFFF")!,
            opacity: 0.65
        ).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(color.redComponent, 0.0, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 0.0, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 0.0, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 0.65, accuracy: 0.001)
    }

    func testSelectedWorkspaceForegroundUsesWhiteOnDarkSelectionBackground() {
        guard let color = sidebarSelectedWorkspaceForegroundNSColor(
            on: NSColor(hex: "#123456")!,
            opacity: 0.65
        ).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(color.redComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 0.65, accuracy: 0.001)
    }

    func testDefaultSelectedWorkspaceForegroundUsesNativeSelectionTextOnAccentBackground() {
        guard let color = sidebarSelectedWorkspaceForegroundNSColor(
            on: sidebarSelectedWorkspaceBackgroundNSColor(for: .light),
            opacity: 0.65
        ).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(color.redComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 0.65, accuracy: 0.001)
    }

    @MainActor
    func testSolidFillKeepsSelectedBackgroundForActiveCustomColoredWorkspaceRow() {
        let manager = TabManager()
        guard let workspace = manager.tabs.first else {
            XCTFail("Expected TabManager to initialise with a workspace")
            return
        }

        var observedSidebarInvalidation = false
        let cancellable = workspace.sidebarImmediateObservationPublisher.sink {
            observedSidebarInvalidation = true
        }

        manager.setTabColor(tabId: workspace.id, color: "#C0392B")

        XCTAssertEqual(workspace.customColor, "#C0392B")
        XCTAssertTrue(observedSidebarInvalidation)

        let background = sidebarWorkspaceRowBackgroundStyle(
            activeTabIndicatorStyle: .solidFill,
            isActive: true,
            isMultiSelected: false,
            customColorHex: workspace.customColor,
            colorScheme: .light,
            sidebarSelectionColorHex: nil
        )

        XCTAssertEqual(
            background.color?.hexString(),
            sidebarSelectedWorkspaceBackgroundNSColor(for: .light).hexString()
        )
        XCTAssertEqual(background.opacity, 1.0, accuracy: 0.001)
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testLeftRailKeepsSelectedBackgroundForActiveCustomColoredWorkspaceRow() {
        let manager = TabManager()
        guard let workspace = manager.tabs.first else {
            XCTFail("Expected TabManager to initialise with a workspace")
            return
        }

        var observedSidebarInvalidation = false
        let cancellable = workspace.sidebarImmediateObservationPublisher.sink {
            observedSidebarInvalidation = true
        }

        manager.setTabColor(tabId: workspace.id, color: "#C0392B")

        XCTAssertEqual(workspace.customColor, "#C0392B")
        XCTAssertTrue(observedSidebarInvalidation)

        let background = sidebarWorkspaceRowBackgroundStyle(
            activeTabIndicatorStyle: .leftRail,
            isActive: true,
            isMultiSelected: false,
            customColorHex: workspace.customColor,
            colorScheme: .light,
            sidebarSelectionColorHex: nil
        )

        XCTAssertEqual(
            background.color?.hexString(),
            sidebarSelectedWorkspaceBackgroundNSColor(for: .light).hexString()
        )
        XCTAssertEqual(background.opacity, 1.0, accuracy: 0.001)
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testLeftRailLeavesInactiveCustomColoredWorkspaceRowTransparent() {
        let manager = TabManager()
        guard let workspace = manager.tabs.first else {
            XCTFail("Expected TabManager to initialise with a workspace")
            return
        }

        manager.setTabColor(tabId: workspace.id, color: "#C0392B")

        let background = sidebarWorkspaceRowBackgroundStyle(
            activeTabIndicatorStyle: .leftRail,
            isActive: false,
            isMultiSelected: false,
            customColorHex: workspace.customColor,
            colorScheme: .light,
            sidebarSelectionColorHex: nil
        )

        XCTAssertNil(background.color)
        XCTAssertEqual(background.opacity, 0, accuracy: 0.001)
    }

    @MainActor
    func testLeftRailResolvesExplicitRailColorForCustomColoredWorkspaceRow() {
        let manager = TabManager()
        guard let workspace = manager.tabs.first else {
            XCTFail("Expected TabManager to initialise with a workspace")
            return
        }

        manager.setTabColor(tabId: workspace.id, color: "#C0392B")

        let railColor = sidebarWorkspaceRowExplicitRailNSColor(
            activeTabIndicatorStyle: .leftRail,
            customColorHex: workspace.customColor,
            colorScheme: .light
        )

        XCTAssertNotNil(railColor)
        XCTAssertEqual(railColor?.hexString(), "#C0392B")
    }

    @MainActor
    func testSolidFillUsesInactiveCustomWorkspaceColorAsBackground() {
        let manager = TabManager()
        guard let workspace = manager.tabs.first else {
            XCTFail("Expected TabManager to initialise with a workspace")
            return
        }

        manager.setTabColor(tabId: workspace.id, color: "#C0392B")

        let background = sidebarWorkspaceRowBackgroundStyle(
            activeTabIndicatorStyle: .solidFill,
            isActive: false,
            isMultiSelected: false,
            customColorHex: workspace.customColor,
            colorScheme: .light,
            sidebarSelectionColorHex: nil
        )

        XCTAssertEqual(background.color?.hexString(), "#C0392B")
        XCTAssertEqual(background.opacity, 0.7, accuracy: 0.001)
    }

    @MainActor
    func testBatchWorkspaceColorAppliesOnlyRequestedWorkspaces() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.applyWorkspaceColor("#C0392B", toWorkspaceIds: [second.id])

        manager.applyWorkspaceColor("#1565C0", toWorkspaceIds: [first.id, third.id])

        XCTAssertEqual(first.customColor, "#1565C0")
        XCTAssertEqual(second.customColor, "#C0392B")
        XCTAssertEqual(third.customColor, "#1565C0")
    }

    @MainActor
    func testBatchWorkspaceTerminalScrollBarVisibilityAppliesOnlyRequestedWorkspaces() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.setWorkspaceTerminalScrollBarHidden(hidden: true, forWorkspaceIds: [first.id, second.id, third.id])

        manager.setWorkspaceTerminalScrollBarHidden(hidden: false, forWorkspaceIds: [first.id, third.id])

        XCTAssertFalse(first.terminalScrollBarHidden)
        XCTAssertTrue(second.terminalScrollBarHidden)
        XCTAssertFalse(third.terminalScrollBarHidden)
    }
}


final class SidebarWorkspaceDetailSettingsTests: XCTestCase {
    func testDefaultPreferencesWhenUnset() {
        let suiteName = "SidebarWorkspaceDetailSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(SidebarWorkspaceDetailSettings.hidesAllDetails(defaults: defaults))
        XCTAssertTrue(SidebarWorkspaceDetailSettings.showsWorkspaceDescription(defaults: defaults))
        XCTAssertTrue(SidebarWorkspaceDetailSettings.showsNotificationMessage(defaults: defaults))
        XCTAssertTrue(
            SidebarWorkspaceDetailSettings.resolvedWorkspaceDescriptionVisibility(
                showWorkspaceDescription: SidebarWorkspaceDetailSettings.showsWorkspaceDescription(defaults: defaults),
                hideAllDetails: SidebarWorkspaceDetailSettings.hidesAllDetails(defaults: defaults)
            )
        )
        XCTAssertTrue(
            SidebarWorkspaceDetailSettings.resolvedNotificationMessageVisibility(
                showNotificationMessage: SidebarWorkspaceDetailSettings.showsNotificationMessage(defaults: defaults),
                hideAllDetails: SidebarWorkspaceDetailSettings.hidesAllDetails(defaults: defaults)
            )
        )
    }

    func testStoredPreferencesOverrideDefaults() {
        let suiteName = "SidebarWorkspaceDetailSettingsTests.Stored.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: SidebarWorkspaceDetailSettings.hideAllDetailsKey)
        defaults.set(false, forKey: SidebarWorkspaceDetailSettings.showWorkspaceDescriptionKey)
        defaults.set(false, forKey: SidebarWorkspaceDetailSettings.showNotificationMessageKey)

        XCTAssertTrue(SidebarWorkspaceDetailSettings.hidesAllDetails(defaults: defaults))
        XCTAssertFalse(SidebarWorkspaceDetailSettings.showsWorkspaceDescription(defaults: defaults))
        XCTAssertFalse(SidebarWorkspaceDetailSettings.showsNotificationMessage(defaults: defaults))
        XCTAssertFalse(
            SidebarWorkspaceDetailSettings.resolvedWorkspaceDescriptionVisibility(
                showWorkspaceDescription: SidebarWorkspaceDetailSettings.showsWorkspaceDescription(defaults: defaults),
                hideAllDetails: false
            )
        )
        XCTAssertFalse(
            SidebarWorkspaceDetailSettings.resolvedWorkspaceDescriptionVisibility(
                showWorkspaceDescription: true,
                hideAllDetails: SidebarWorkspaceDetailSettings.hidesAllDetails(defaults: defaults)
            )
        )
        XCTAssertFalse(
            SidebarWorkspaceDetailSettings.resolvedNotificationMessageVisibility(
                showNotificationMessage: SidebarWorkspaceDetailSettings.showsNotificationMessage(defaults: defaults),
                hideAllDetails: false
            )
        )
        XCTAssertFalse(
            SidebarWorkspaceDetailSettings.resolvedNotificationMessageVisibility(
                showNotificationMessage: true,
                hideAllDetails: SidebarWorkspaceDetailSettings.hidesAllDetails(defaults: defaults)
            )
        )
    }
}


final class SidebarWorkspaceAuxiliaryDetailVisibilityTests: XCTestCase {
    func testResolvedVisibilityPreservesPerRowTogglesWhenDetailsAreShown() {
        XCTAssertEqual(
            SidebarWorkspaceAuxiliaryDetailVisibility.resolved(
                showMetadata: true,
                showLog: false,
                showProgress: true,
                showBranchDirectory: false,
                showPullRequests: true,
                showPorts: false,
                hideAllDetails: false
            ),
            SidebarWorkspaceAuxiliaryDetailVisibility(
                showsMetadata: true,
                showsLog: false,
                showsProgress: true,
                showsBranchDirectory: false,
                showsPullRequests: true,
                showsPorts: false
            )
        )
    }

    func testResolvedVisibilityHidesAllAuxiliaryRowsWhenDetailsAreHidden() {
        XCTAssertEqual(
            SidebarWorkspaceAuxiliaryDetailVisibility.resolved(
                showMetadata: true,
                showLog: true,
                showProgress: true,
                showBranchDirectory: true,
                showPullRequests: true,
                showPorts: true,
                hideAllDetails: true
            ),
            .hidden
        )
    }
}


final class SidebarWorkspaceSelectionSyncPolicyTests: XCTestCase {
    @MainActor
    func testReconciledSelectionPreservesMultiSelectionAfterReorder() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let fourth = UUID()
        let previousSelection: Set<UUID> = [second, third]

        let result = SidebarWorkspaceSelectionSyncPolicy.reconciledSelection(
            previousSelectionIds: previousSelection,
            liveWorkspaceIds: [first, third, fourth, second],
            fallbackSelectedWorkspaceId: second
        )

        XCTAssertEqual(result, previousSelection)
        XCTAssertEqual(
            SidebarWorkspaceSelectionSyncPolicy.anchorIndex(
                preferredWorkspaceId: second,
                selectedWorkspaceIds: result,
                liveWorkspaceIds: [first, third, fourth, second]
            ),
            3
        )
    }

    @MainActor
    func testReconciledSelectionFallsBackToActiveWorkspaceWhenPreviousSelectionIsGone() {
        let first = UUID()
        let second = UUID()
        let removed = UUID()

        let result = SidebarWorkspaceSelectionSyncPolicy.reconciledSelection(
            previousSelectionIds: [removed],
            liveWorkspaceIds: [first, second],
            fallbackSelectedWorkspaceId: second
        )

        XCTAssertEqual(result, [second])
    }
}


@MainActor
final class SidebarWorkspaceShortcutHintMetricsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SidebarWorkspaceShortcutHintMetrics.resetCacheForTesting()
    }

    override func tearDown() {
        SidebarWorkspaceShortcutHintMetrics.resetCacheForTesting()
        super.tearDown()
    }

    func testHintWidthCachesRepeatedMeasurements() {
        XCTAssertEqual(SidebarWorkspaceShortcutHintMetrics.measurementCountForTesting(), 0)

        let first = SidebarWorkspaceShortcutHintMetrics.hintWidth(for: "⌘1")
        XCTAssertGreaterThan(first, 0)
        XCTAssertEqual(SidebarWorkspaceShortcutHintMetrics.measurementCountForTesting(), 1)

        let second = SidebarWorkspaceShortcutHintMetrics.hintWidth(for: "⌘1")
        XCTAssertEqual(second, first)
        XCTAssertEqual(SidebarWorkspaceShortcutHintMetrics.measurementCountForTesting(), 1)

        _ = SidebarWorkspaceShortcutHintMetrics.hintWidth(for: "⌘2")
        XCTAssertEqual(SidebarWorkspaceShortcutHintMetrics.measurementCountForTesting(), 2)
    }

    func testSlotWidthAppliesMinimumAndDebugInset() {
        let nilLabelWidth = SidebarWorkspaceShortcutHintMetrics.slotWidth(label: nil, debugXOffset: 999)
        XCTAssertEqual(nilLabelWidth, 28)

        let base = SidebarWorkspaceShortcutHintMetrics.slotWidth(label: "⌘1", debugXOffset: 0)
        let widened = SidebarWorkspaceShortcutHintMetrics.slotWidth(label: "⌘1", debugXOffset: 10)
        XCTAssertGreaterThan(widened, base)
    }
}

