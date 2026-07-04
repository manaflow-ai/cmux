import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct SidebarWidthPolicyTests {
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"

    @Test func defaultMinimumSidebarWidthIsPersistedProductDefault() {
        let suiteName = "SidebarWidthPolicyTests.defaultMinimum.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        expectApproximatelyEqual(
            SessionPersistencePolicy.defaultMinimumSidebarWidth,
            216
        )
        expectApproximatelyEqual(
            SessionPersistencePolicy.resolvedMinimumSidebarWidth(defaults: defaults),
            216
        )
    }

    @Test func contentViewClampKeepsMinimumSidebarWidth() {
        expectApproximatelyEqual(
            ContentView.clampedSidebarWidth(184, maximumWidth: 600),
            CGFloat(SessionPersistencePolicy.minimumSidebarWidth)
        )
    }

    @Test func contentViewClampCanUseSmallerConfiguredMinimumSidebarWidth() {
        expectApproximatelyEqual(
            ContentView.clampedSidebarWidth(184, maximumWidth: 600, minimumWidth: 160),
            184
        )
        expectApproximatelyEqual(
            ContentView.clampedSidebarWidth(140, maximumWidth: 600, minimumWidth: 160),
            160
        )
    }

    @Test func sessionPersistenceReadsConfiguredMinimumSidebarWidth() {
        let suiteName = "SidebarWidthPolicyTests.minimumSidebarWidth.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(160.0, forKey: SessionPersistencePolicy.sidebarMinimumWidthKey)
        expectApproximatelyEqual(
            SessionPersistencePolicy.sanitizedSidebarWidth(140, defaults: defaults),
            160
        )
        expectApproximatelyEqual(
            SessionPersistencePolicy.sanitizedSidebarWidth(184, defaults: defaults),
            184
        )
    }

    @Test func rightSidebarClampAllowsWideExplorerOnLargeWindows() {
        expectApproximatelyEqual(
            ContentView.clampedRightSidebarWidth(900, availableWidth: 1600),
            900
        )
    }

    @Test func rightSidebarFirstCustomMaximumMatchesBuiltInCap() {
        expectApproximatelyEqual(
            ContentView.clampedRightSidebarWidth(10_000, availableWidth: 10_000),
            CGFloat(RightSidebarWidthSettings.defaultConfiguredMaximumWidth)
        )
    }

    @Test func rightSidebarClampLeavesTerminalWidthWhenMaxWidthSettingIsMissing() {
        expectApproximatelyEqual(
            ContentView.clampedRightSidebarWidth(10_000, availableWidth: 1000),
            640
        )
    }

    @Test func rightSidebarConfiguredMaxCanExceedBuiltInDefaultOnWideWindows() {
        expectApproximatelyEqual(
            ContentView.clampedRightSidebarWidth(
                10_000,
                availableWidth: 2400,
                configuredMaximumWidth: 1_500
            ),
            1_500
        )
    }

    @Test func rightSidebarConfiguredMaxStillLeavesTerminalWidth() {
        expectApproximatelyEqual(
            ContentView.clampedRightSidebarWidth(
                10_000,
                availableWidth: 1000,
                configuredMaximumWidth: 1_400
            ),
            640
        )
    }

    @Test func rightSidebarConfiguredMaxBelowMinimumClampsToMinimumWidth() {
        expectApproximatelyEqual(
            ContentView.clampedRightSidebarWidth(
                10_000,
                availableWidth: 1000,
                configuredMaximumWidth: 120
            ),
            276
        )
    }

    @Test func rightSidebarClampKeepsMinimumWidth() {
        expectApproximatelyEqual(
            ContentView.clampedRightSidebarWidth(20, availableWidth: 1000),
            276
        )
    }

    @Test func settingsFileStoreAppliesRightSidebarMaxWidthSetting() throws {
        let defaults = UserDefaults.standard
        let managedKey = RightSidebarWidthSettings.maxWidthKey
        let previousValues = [
            managedKey,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey,
        ].reduce(into: [String: Any]()) { values, key in
            values[key] = defaults.object(forKey: key)
        }
        defer {
            for key in [managedKey, settingsFileBackupsDefaultsKey, importedManagedDefaultsKey] {
                if let value = previousValues[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        defaults.removeObject(forKey: managedKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
        defaults.removeObject(forKey: importedManagedDefaultsKey)

        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "right-sidebar-width-settings-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "sidebar": {
            "rightMaxWidth": 900
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )

        expectApproximatelyEqual(defaults.double(forKey: managedKey), 900)
        let configuredMaximumWidth = try #require(
            RightSidebarWidthSettings().configuredMaximumWidth(from: defaults.double(forKey: managedKey))
        )
        expectApproximatelyEqual(configuredMaximumWidth, 900)
    }

    @Test func settingsFileStoreClampsRightSidebarMaxWidthSetting() throws {
        let defaults = UserDefaults.standard
        let managedKey = RightSidebarWidthSettings.maxWidthKey
        let previousValues = [
            managedKey,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey,
        ].reduce(into: [String: Any]()) { values, key in
            values[key] = defaults.object(forKey: key)
        }
        defer {
            for key in [managedKey, settingsFileBackupsDefaultsKey, importedManagedDefaultsKey] {
                if let value = previousValues[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        defaults.removeObject(forKey: managedKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
        defaults.removeObject(forKey: importedManagedDefaultsKey)

        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "right-sidebar-width-settings-clamped-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "sidebar": {
            "rightMaxWidth": 10000
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )

        expectApproximatelyEqual(
            defaults.double(forKey: managedKey),
            RightSidebarWidthSettings.settingsEditorMaximumWidth
        )
        let configuredMaximumWidth = try #require(
            RightSidebarWidthSettings().configuredMaximumWidth(from: defaults.double(forKey: managedKey))
        )
        expectApproximatelyEqual(
            configuredMaximumWidth,
            RightSidebarWidthSettings.settingsEditorMaximumWidth
        )
    }

    @Test func leadingSidebarResizeRangeFavorsSidebarSide() {
        let range = SidebarResizeInteraction.Edge.leading.hitRange(dividerX: 200)

        expectApproximatelyEqual(range.lowerBound, 194)
        expectApproximatelyEqual(range.upperBound, 204)
        #expect(range.contains(196))
        #expect(range.contains(202))
        #expect(!range.contains(193.9))
        #expect(!range.contains(204.1))
    }

    @Test func trailingSidebarResizeRangeFavorsSidebarSide() {
        let range = SidebarResizeInteraction.Edge.trailing.hitRange(dividerX: 680)

        expectApproximatelyEqual(range.lowerBound, 676)
        expectApproximatelyEqual(range.upperBound, 686)
        #expect(range.contains(678))
        #expect(range.contains(684))
        #expect(!range.contains(675.9))
        #expect(!range.contains(686.1))
    }

    private func expectApproximatelyEqual<T: BinaryFloatingPoint>(
        _ actual: T,
        _ expected: T,
        accuracy: T = 0.001
    ) {
        #expect(abs(actual - expected) <= accuracy)
    }
}

@Suite
struct SidebarWorkspaceSelectionColorTests {
    @Test func selectedColoredWorkspaceUsesStandardSelectionBackgroundInLightAndDark() {
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

            expectApproximatelyEqual(coloredSelected.opacity, standardSelected.opacity)
            expectApproximatelyEqual(coloredSelected.opacity, 1)
            assertColor(coloredSelected.color, equals: standardSelected.color)

            let unselectedColored = sidebarWorkspaceRowBackgroundStyle(
                activeTabIndicatorStyle: .solidFill,
                isActive: false,
                isMultiSelected: false,
                customColorHex: "#E85D75",
                colorScheme: colorScheme,
                sidebarSelectionColorHex: nil
            )
            expectApproximatelyEqual(unselectedColored.opacity, 0.7)
            #expect(
                !colorsAreEqual(coloredSelected.color, unselectedColored.color),
                "Selected row should use the standard selection background, not the workspace tab color"
            )
        }
    }

    @Test func selectedColoredWorkspaceUsesConfiguredSelectionBackground() {
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

        expectApproximatelyEqual(coloredSelected.opacity, 1)
        assertColor(coloredSelected.color, equals: standardSelected.color)
        assertColor(coloredSelected.color, equals: NSColor(hex: selectionHex))
    }

    @Test func defaultSelectedForegroundFallsBackForPaleSelectionBackground() throws {
        let background = try #require(NSColor(hex: "#F7F7F7"))
        let foreground = sidebarSelectedWorkspaceForegroundNSColor(
            on: background,
            opacity: 1.0
        )

        assertColor(foreground, equals: .black)
        #expect(cmuxContrastRatio(foreground: foreground, background: background) >= 4.5)
    }

    @Test func selectedForegroundPrefersWhiteForSaturatedSelectionBackground() throws {
        let background = try #require(NSColor(hex: "#0088FF"))
        let foreground = sidebarSelectedWorkspaceForegroundNSColor(
            on: background,
            opacity: 1.0
        )

        assertColor(foreground, equals: .white)
        #expect(cmuxContrastRatio(foreground: foreground, background: background) >= 3.0)
    }

    @Test func selectedForegroundKeepsWhiteForStandardInactiveSelectionBlue() throws {
        let background = try #require(NSColor(hex: "#6795F5"))
        let foreground = sidebarSelectedWorkspaceForegroundNSColor(
            on: background,
            opacity: 0.75
        )

        assertColor(foreground, equals: NSColor.white.withAlphaComponent(0.75))
    }

    @Test func titlebarControlForegroundContrastsWithLightTerminalBackground() throws {
        let background = try #require(NSColor(hex: "#F7F7F7"))
        let snapshot = makeWindowAppearanceSnapshot(background: background)
        let foreground = titlebarControlForegroundNSColor(
            opacity: 1.0,
            appearance: snapshot
        )

        assertColor(foreground, equals: .black)
        #expect(
            cmuxContrastRatio(
                foreground: foreground,
                background: snapshot.compositedTerminalBackgroundColor
            ) >= 4.5
        )
    }

    private func assertColor(
        _ actual: NSColor?,
        equals expected: NSColor?
    ) {
        guard let actual else {
            Issue.record("Expected actual color to be non-nil")
            return
        }
        guard let expected else {
            Issue.record("Expected comparison color to be non-nil")
            return
        }

        #expect(
            colorsAreEqual(actual, expected),
            "Expected \(colorDescription(actual)) to equal \(colorDescription(expected))"
        )
    }

    private func expectApproximatelyEqual<T: BinaryFloatingPoint>(
        _ actual: T,
        _ expected: T,
        accuracy: T = 0.001
    ) {
        #expect(abs(actual - expected) <= accuracy)
    }

    private func makeWindowAppearanceSnapshot(background: NSColor) -> WindowAppearanceSnapshot {
        WindowAppearanceSnapshot(
            terminalBackgroundColor: background,
            terminalBackgroundOpacity: 1.0,
            terminalBackgroundBlur: .disabled,
            terminalRenderingMode: .windowHostBackdrop,
            unifySurfaceBackdrops: true,
            sidebarSettings: SidebarBackdropSettingsSnapshot(
                materialRawValue: SidebarMaterialOption.sidebar.rawValue,
                blendModeRawValue: SidebarBlendModeOption.withinWindow.rawValue,
                stateRawValue: SidebarStateOption.followWindow.rawValue,
                tintHex: SidebarTintDefaults().hex,
                tintHexLight: nil,
                tintHexDark: nil,
                tintOpacity: SidebarTintDefaults().opacity,
                cornerRadius: 0,
                blurOpacity: 1,
                colorScheme: .light
            ),
            windowGlassSettings: WindowGlassSettingsSnapshot(
                sidebarBlendModeRawValue: SidebarBlendModeOption.withinWindow.rawValue,
                isEnabled: false,
                tintHex: "#000000",
                tintOpacity: 0,
                terminalBackgroundBlur: .disabled,
                terminalGlassTintColor: background
            )
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
