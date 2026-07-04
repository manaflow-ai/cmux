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

private func expectEqual<T: BinaryFloatingPoint>(_ actual: T, _ expected: T, accuracy: T) {
    #expect(abs(actual - expected) <= accuracy)
}

@Suite(.serialized) struct SidebarWidthPolicyTests {
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"

    @Test func defaultMinimumSidebarWidthIsPersistedProductDefault() {
        let suiteName = "SidebarWidthPolicyTests.defaultMinimum.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        expectEqual(
            SessionPersistencePolicy.defaultMinimumSidebarWidth,
            216,
            accuracy: 0.001
        )
        expectEqual(
            SessionPersistencePolicy.resolvedMinimumSidebarWidth(defaults: defaults),
            216,
            accuracy: 0.001
        )
    }

    @Test func contentViewClampKeepsMinimumSidebarWidth() {
        expectEqual(
            ContentView.clampedSidebarWidth(184, maximumWidth: 600),
            CGFloat(SessionPersistencePolicy.minimumSidebarWidth),
            accuracy: 0.001
        )
    }

    @Test func contentViewClampCanUseSmallerConfiguredMinimumSidebarWidth() {
        expectEqual(
            ContentView.clampedSidebarWidth(184, maximumWidth: 600, minimumWidth: 160),
            184,
            accuracy: 0.001
        )
        expectEqual(
            ContentView.clampedSidebarWidth(140, maximumWidth: 600, minimumWidth: 160),
            160,
            accuracy: 0.001
        )
    }

    @Test func sessionPersistenceReadsConfiguredMinimumSidebarWidth() {
        let suiteName = "SidebarWidthPolicyTests.minimumSidebarWidth.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(160.0, forKey: SessionPersistencePolicy.sidebarMinimumWidthKey)
        expectEqual(
            SessionPersistencePolicy.sanitizedSidebarWidth(140, defaults: defaults),
            160,
            accuracy: 0.001
        )
        expectEqual(
            SessionPersistencePolicy.sanitizedSidebarWidth(184, defaults: defaults),
            184,
            accuracy: 0.001
        )
    }

    @Test func rightSidebarClampAllowsWideExplorerOnLargeWindows() {
        expectEqual(
            ContentView.clampedRightSidebarWidth(900, availableWidth: 1600),
            900,
            accuracy: 0.001
        )
    }

    @Test func rightSidebarFirstCustomMaximumMatchesBuiltInCap() {
        expectEqual(
            ContentView.clampedRightSidebarWidth(10_000, availableWidth: 10_000),
            CGFloat(RightSidebarWidthSettings.defaultConfiguredMaximumWidth),
            accuracy: 0.001
        )
    }

    @Test func rightSidebarClampLeavesTerminalWidthWhenMaxWidthSettingIsMissing() {
        expectEqual(
            ContentView.clampedRightSidebarWidth(10_000, availableWidth: 1000),
            640,
            accuracy: 0.001
        )
    }

    @Test func rightSidebarConfiguredMaxCanExceedBuiltInDefaultOnWideWindows() {
        expectEqual(
            ContentView.clampedRightSidebarWidth(
                10_000,
                availableWidth: 2400,
                configuredMaximumWidth: 1_500
            ),
            1_500,
            accuracy: 0.001
        )
    }

    @Test func rightSidebarConfiguredMaxStillLeavesTerminalWidth() {
        expectEqual(
            ContentView.clampedRightSidebarWidth(
                10_000,
                availableWidth: 1000,
                configuredMaximumWidth: 1_400
            ),
            640,
            accuracy: 0.001
        )
    }

    @Test func rightSidebarConfiguredMaxBelowMinimumClampsToMinimumWidth() {
        expectEqual(
            ContentView.clampedRightSidebarWidth(
                10_000,
                availableWidth: 1000,
                configuredMaximumWidth: 120
            ),
            276,
            accuracy: 0.001
        )
    }

    @Test func rightSidebarClampKeepsMinimumWidth() {
        expectEqual(
            ContentView.clampedRightSidebarWidth(20, availableWidth: 1000),
            276,
            accuracy: 0.001
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

        expectEqual(defaults.double(forKey: managedKey), 900, accuracy: 0.001)
        let configuredMaximumWidth = try #require(
            RightSidebarWidthSettings().configuredMaximumWidth(from: defaults.double(forKey: managedKey))
        )
        expectEqual(configuredMaximumWidth, 900, accuracy: 0.001)
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

        expectEqual(
            defaults.double(forKey: managedKey),
            RightSidebarWidthSettings.settingsEditorMaximumWidth,
            accuracy: 0.001
        )
        let configuredMaximumWidth = try #require(
            RightSidebarWidthSettings().configuredMaximumWidth(from: defaults.double(forKey: managedKey))
        )
        expectEqual(
            configuredMaximumWidth,
            RightSidebarWidthSettings.settingsEditorMaximumWidth,
            accuracy: 0.001
        )
    }

    @Test func leftSidebarMinWidthPolicyMatchesSessionPolicy() {
        expectEqual(LeftSidebarWidthSettings.defaultMinimumWidth, 216, accuracy: 0.001)
        expectEqual(LeftSidebarWidthSettings.lowerBound, 100, accuracy: 0.001)
        #expect(SessionPersistencePolicy.sidebarMinimumWidthRange == LeftSidebarWidthSettings.range)
        #expect(SessionPersistencePolicy.sidebarMinimumWidthKey == LeftSidebarWidthSettings.minimumWidthKey)
        // The configurable floor genuinely allows a narrower sidebar than the
        // historical 216 minimum (the point of issue #6784).
        let settings = LeftSidebarWidthSettings()
        expectEqual(settings.clampedMinimumWidth(120), 120, accuracy: 0.001)
        expectEqual(settings.clampedMinimumWidth(50), 100, accuracy: 0.001)
        expectEqual(settings.clampedMinimumWidth(10_000), 260, accuracy: 0.001)
        expectEqual(settings.clampedMinimumWidth(.nan), 216, accuracy: 0.001)
    }

    @Test func configuredLeftSidebarMinWidthLetsContentViewClampNarrower() {
        let suiteName = "SidebarWidthPolicyTests.leftMinWidth.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(120.0, forKey: SessionPersistencePolicy.sidebarMinimumWidthKey)
        let resolved = SessionPersistencePolicy.resolvedMinimumSidebarWidth(defaults: defaults)
        expectEqual(resolved, 120, accuracy: 0.001)
        // With a 120pt configured floor the sidebar can be dragged down to 120,
        // below the historical 216 hard minimum.
        expectEqual(
            ContentView.clampedSidebarWidth(120, maximumWidth: 600, minimumWidth: CGFloat(resolved)),
            120,
            accuracy: 0.001
        )
        expectEqual(
            ContentView.clampedSidebarWidth(90, maximumWidth: 600, minimumWidth: CGFloat(resolved)),
            120,
            accuracy: 0.001
        )
    }

    @Test func settingsFileStoreAppliesLeftSidebarMinWidthSetting() throws {
        let defaults = UserDefaults.standard
        let managedKey = LeftSidebarWidthSettings.minimumWidthKey
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
            "left-sidebar-min-width-settings-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "sidebar": {
            "leftMinWidth": 120
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )

        expectEqual(defaults.double(forKey: managedKey), 120, accuracy: 0.001)
    }

    @Test func settingsFileStoreClampsLeftSidebarMinWidthSetting() throws {
        let defaults = UserDefaults.standard
        let managedKey = LeftSidebarWidthSettings.minimumWidthKey
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
            "left-sidebar-min-width-settings-clamped-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "sidebar": {
            "leftMinWidth": 40
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )

        expectEqual(
            defaults.double(forKey: managedKey),
            LeftSidebarWidthSettings.lowerBound,
            accuracy: 0.001
        )
    }

    @Test func leadingSidebarResizeRangeFavorsSidebarSide() {
        let range = SidebarResizeInteraction.Edge.leading.hitRange(dividerX: 200)

        expectEqual(range.lowerBound, 194, accuracy: 0.001)
        expectEqual(range.upperBound, 204, accuracy: 0.001)
        #expect(range.contains(196))
        #expect(range.contains(202))
        #expect(!range.contains(193.9))
        #expect(!range.contains(204.1))
    }

    @Test func trailingSidebarResizeRangeFavorsSidebarSide() {
        let range = SidebarResizeInteraction.Edge.trailing.hitRange(dividerX: 680)

        expectEqual(range.lowerBound, 676, accuracy: 0.001)
        expectEqual(range.upperBound, 686, accuracy: 0.001)
        #expect(range.contains(678))
        #expect(range.contains(684))
        #expect(!range.contains(675.9))
        #expect(!range.contains(686.1))
    }
}

@Suite struct SidebarWorkspaceSelectionColorTests {
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

            expectEqual(coloredSelected.opacity, standardSelected.opacity, accuracy: 0.001)
            expectEqual(coloredSelected.opacity, 1, accuracy: 0.001)
            assertColor(coloredSelected.color, equals: standardSelected.color)

            let unselectedColored = sidebarWorkspaceRowBackgroundStyle(
                activeTabIndicatorStyle: .solidFill,
                isActive: false,
                isMultiSelected: false,
                customColorHex: "#E85D75",
                colorScheme: colorScheme,
                sidebarSelectionColorHex: nil
            )
            expectEqual(unselectedColored.opacity, 0.7, accuracy: 0.001)
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

        expectEqual(coloredSelected.opacity, 1, accuracy: 0.001)
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
