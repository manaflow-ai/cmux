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

    @Test
    func defaultMinimumSidebarWidthIsPersistedProductDefault() {
        let suiteName = "SidebarWidthPolicyTests.defaultMinimum.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(abs(SessionPersistencePolicy.defaultMinimumSidebarWidth - 240) <= 0.001)
        #expect(
            abs(SessionPersistencePolicy.resolvedMinimumSidebarWidth(defaults: defaults) - 240) <= 0.001
        )
    }

    @Test
    func contentViewClampKeepsMinimumSidebarWidth() {
        #expect(
            abs(
                ContentView.clampedSidebarWidth(184, maximumWidth: 600)
                    - CGFloat(SessionPersistencePolicy.minimumSidebarWidth)
            ) <= 0.001
        )
    }

    @Test
    func contentViewClampCanUseSmallerConfiguredMinimumSidebarWidth() {
        #expect(
            abs(ContentView.clampedSidebarWidth(184, maximumWidth: 600, minimumWidth: 160) - 184) <= 0.001
        )
        #expect(
            abs(ContentView.clampedSidebarWidth(140, maximumWidth: 600, minimumWidth: 160) - 160) <= 0.001
        )
    }

    @Test
    func sessionPersistenceReadsConfiguredMinimumSidebarWidth() {
        let suiteName = "SidebarWidthPolicyTests.minimumSidebarWidth.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(160.0, forKey: SessionPersistencePolicy.sidebarMinimumWidthKey)
        #expect(
            abs(SessionPersistencePolicy.sanitizedSidebarWidth(nil, defaults: defaults) - 160) <= 0.001)
        #expect(
            abs(SessionPersistencePolicy.sanitizedSidebarWidth(140, defaults: defaults) - 160) <= 0.001)
        #expect(
            abs(SessionPersistencePolicy.sanitizedSidebarWidth(184, defaults: defaults) - 184) <= 0.001)
    }

    @Test
    func sessionPersistenceFallbackNeverExceedsMaximumSidebarWidth() {
        let suiteName = "SidebarWidthPolicyTests.maximumSidebarWidth.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            SessionPersistencePolicy.maximumSidebarWidth + 100,
            forKey: SessionPersistencePolicy.sidebarMinimumWidthKey
        )
        let fallback = SessionPersistencePolicy.sanitizedSidebarWidth(nil, defaults: defaults)

        #expect(fallback <= SessionPersistencePolicy.maximumSidebarWidth)
    }

    @Test
    func rightSidebarClampAllowsWideExplorerOnLargeWindows() {
        #expect(abs(ContentView.clampedRightSidebarWidth(900, availableWidth: 1600) - 900) <= 0.001)
    }

    @Test
    func rightSidebarFirstCustomMaximumMatchesBuiltInCap() {
        #expect(
            abs(
                ContentView.clampedRightSidebarWidth(10_000, availableWidth: 10_000)
                    - CGFloat(RightSidebarWidthSettings.defaultConfiguredMaximumWidth)
            ) <= 0.001
        )
    }

    @Test
    func rightSidebarClampLeavesTerminalWidthWhenMaxWidthSettingIsMissing() {
        #expect(abs(ContentView.clampedRightSidebarWidth(10_000, availableWidth: 1000) - 640) <= 0.001)
    }

    @Test
    func rightSidebarConfiguredMaxCanExceedBuiltInDefaultOnWideWindows() {
        #expect(
            abs(
                ContentView.clampedRightSidebarWidth(
                    10_000,
                    availableWidth: 2400,
                    configuredMaximumWidth: 1_500
                ) - 1_500
            ) <= 0.001
        )
    }

    @Test
    func rightSidebarConfiguredMaxStillLeavesTerminalWidth() {
        #expect(
            abs(
                ContentView.clampedRightSidebarWidth(
                    10_000,
                    availableWidth: 1000,
                    configuredMaximumWidth: 1_400
                ) - 640
            ) <= 0.001
        )
    }

    @Test
    func rightSidebarConfiguredMaxBelowMinimumClampsToMinimumWidth() {
        #expect(
            abs(
                ContentView.clampedRightSidebarWidth(
                    10_000,
                    availableWidth: 1000,
                    configuredMaximumWidth: 120
                ) - 276
            ) <= 0.001
        )
    }

    @Test
    func rightSidebarClampKeepsMinimumWidth() {
        #expect(abs(ContentView.clampedRightSidebarWidth(20, availableWidth: 1000) - 276) <= 0.001)
    }

    @Test
    func settingsFileStoreAppliesRightSidebarMaxWidthSetting() throws {
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

        #expect(abs(defaults.double(forKey: managedKey) - 900) <= 0.001)
        let configuredMaximumWidth = try #require(
            RightSidebarWidthSettings().configuredMaximumWidth(from: defaults.double(forKey: managedKey))
        )
        #expect(abs(configuredMaximumWidth - 900) <= 0.001)
    }

    @Test
    func settingsFileStoreClampsRightSidebarMaxWidthSetting() throws {
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

        #expect(
            abs(
                defaults.double(forKey: managedKey)
                    - RightSidebarWidthSettings.settingsEditorMaximumWidth
            ) <= 0.001
        )
        let configuredMaximumWidth = try #require(
            RightSidebarWidthSettings().configuredMaximumWidth(from: defaults.double(forKey: managedKey))
        )
        #expect(
            abs(configuredMaximumWidth - RightSidebarWidthSettings.settingsEditorMaximumWidth) <= 0.001
        )
    }

    @Test
    func leadingSidebarResizeRangeFavorsSidebarSide() {
        let range = SidebarResizeInteraction.Edge.leading.hitRange(dividerX: 200)

        #expect(abs(range.lowerBound - 194) <= 0.001)
        #expect(abs(range.upperBound - 204) <= 0.001)
        #expect(range.contains(196))
        #expect(range.contains(202))
        #expect(!range.contains(193.9))
        #expect(!range.contains(204.1))
    }

    @Test
    func trailingSidebarResizeRangeFavorsSidebarSide() {
        let range = SidebarResizeInteraction.Edge.trailing.hitRange(dividerX: 680)

        #expect(abs(range.lowerBound - 676) <= 0.001)
        #expect(abs(range.upperBound - 686) <= 0.001)
        #expect(range.contains(678))
        #expect(range.contains(684))
        #expect(!range.contains(675.9))
        #expect(!range.contains(686.1))
    }
}

@MainActor
@Suite(.serialized)
struct SidebarWidthWindowCreationTests {
    @Test func newWindowUsesConfiguredMinimumWhenNoWidthWasPersisted() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = NSApplication.shared
            let defaults = UserDefaults.standard
            let key = SessionPersistencePolicy.sidebarMinimumWidthKey
            let savedValue = defaults.object(forKey: key)
            let previousAppDelegate = AppDelegate.shared

            defaults.set(160.0, forKey: key)
            let appDelegate = AppDelegate()
            AppDelegate.shared = appDelegate
            var windowId: UUID?
            defer {
                if let windowId {
                    _ = appDelegate.closeMainWindow(windowId: windowId, recordHistory: false)
                }
                if let savedValue {
                    defaults.set(savedValue, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
                AppDelegate.shared = previousAppDelegate
            }

            let createdWindowId = appDelegate.createMainWindow(shouldActivate: false)
            windowId = createdWindowId
            let context = try #require(
                appDelegate.mainWindowContexts.values.first { $0.windowId == createdWindowId }
            )

            #expect(context.sidebarState.persistedWidth == 160)
        }
    }
}

@MainActor
@Suite("App web theme contrast")
struct AppWebThemeContrastTests {
    @Test
    func keepsReadableCmuxBlue() throws {
        let accent = try #require(NSColor(hex: "#0088FF"))
        let background = try #require(NSColor(hex: "#171717"))
        let adjusted = AppWebThemeSnapshot.contrastAdjustedAccentNSColor(
            accent,
            on: background
        )

        #expect(adjusted.hexString() == accent.hexString())
    }

    @Test
    func darkensAgainstLightTheme() throws {
        let background = try #require(NSColor(hex: "#FDF6E3"))
        let adjusted = AppWebThemeSnapshot.contrastAdjustedAccentNSColor(
            try #require(NSColor(hex: "#0088FF")),
            on: background
        )

        #expect(adjusted.hexString() == "#0071D5")
        #expect(
            cmuxContrastRatio(
                foreground: adjusted,
                background: background
            ) >= 4.5
        )
    }

    @Test
    func lightensAgainstDarkSelectedButton() throws {
        let background = try #require(NSColor(hex: "#4A4543"))
        let adjusted = AppWebThemeSnapshot.contrastAdjustedAccentNSColor(
            try #require(NSColor(hex: "#0088FF")),
            on: background
        )

        #expect(adjusted.hexString() == "#6BB9FF")
        #expect(
            cmuxContrastRatio(
                foreground: adjusted,
                background: background
            ) >= 4.5
        )
    }

    @Test
    func choosesSmallestRGBAdjustmentWhenBothDirectionsAreReadable() throws {
        let adjusted = AppWebThemeSnapshot.contrastAdjustedAccentNSColor(
            try #require(NSColor(hex: "#000040")),
            on: try #require(NSColor(hex: "#8060D0"))
        )

        #expect(adjusted.hexString() == "#000000")
    }
}

@Suite
struct SidebarWorkspaceSelectionColorTests {
    @Test
    func selectedColoredWorkspaceUsesStandardSelectionBackgroundInLightAndDark() {
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

            #expect(abs(coloredSelected.opacity - standardSelected.opacity) <= 0.001)
            #expect(abs(coloredSelected.opacity - 1) <= 0.001)
            assertColor(coloredSelected.color, equals: standardSelected.color)

            let unselectedColored = sidebarWorkspaceRowBackgroundStyle(
                activeTabIndicatorStyle: .solidFill,
                isActive: false,
                isMultiSelected: false,
                customColorHex: "#E85D75",
                colorScheme: colorScheme,
                sidebarSelectionColorHex: nil
            )
            #expect(abs(unselectedColored.opacity - 0.7) <= 0.001)
            #expect(
                !colorsAreEqual(coloredSelected.color, unselectedColored.color),
                "Selected row should use the standard selection background, not the workspace tab color"
            )
        }
    }

    @Test
    func selectedColoredWorkspaceUsesConfiguredSelectionBackground() {
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

        #expect(abs(coloredSelected.opacity - 1) <= 0.001)
        assertColor(coloredSelected.color, equals: standardSelected.color)
        assertColor(coloredSelected.color, equals: NSColor(hex: selectionHex))
    }

    @Test
    func defaultSelectedForegroundFallsBackForPaleSelectionBackground() throws {
        let background = try #require(NSColor(hex: "#F7F7F7"))
        let foreground = sidebarSelectedWorkspaceForegroundNSColor(
            on: background,
            opacity: 1.0
        )

        assertColor(foreground, equals: .black)
        #expect(cmuxContrastRatio(foreground: foreground, background: background) >= 4.5)
    }

    @Test
    func selectedForegroundPrefersWhiteForSaturatedSelectionBackground() throws {
        let background = try #require(NSColor(hex: "#0088FF"))
        let foreground = sidebarSelectedWorkspaceForegroundNSColor(
            on: background,
            opacity: 1.0
        )

        assertColor(foreground, equals: .white)
        #expect(cmuxContrastRatio(foreground: foreground, background: background) >= 3.0)
    }

    @Test
    func selectedForegroundKeepsWhiteForStandardInactiveSelectionBlue() throws {
        let background = try #require(NSColor(hex: "#6795F5"))
        let foreground = sidebarSelectedWorkspaceForegroundNSColor(
            on: background,
            opacity: 0.75
        )

        assertColor(foreground, equals: NSColor.white.withAlphaComponent(0.75))
    }

    @Test
    func titlebarControlForegroundContrastsWithLightTerminalBackground() throws {
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
        equals expected: NSColor?,
    ) {
        guard let actual, let expected else {
            #expect(actual != nil)
            #expect(expected != nil)
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
            let rhsRGB = rhs.usingColorSpace(.sRGB)
        else {
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

        return abs(lhsRed - rhsRed) <= 0.001 && abs(lhsGreen - rhsGreen) <= 0.001
            && abs(lhsBlue - rhsBlue) <= 0.001 && abs(lhsAlpha - rhsAlpha) <= 0.001
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
