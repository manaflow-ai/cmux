import AppKit
import Combine
import WebKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Theme & Typography Settings
extension MarkdownPanelTests {
    func testMarkdownThemeUsesTransparentPageAndOverlayTintsForTranslucentBackgrounds() throws {
        let theme = MarkdownWebTheme.resolve(
            backgroundColor: NSColor(
                srgbRed: 0.10,
                green: 0.12,
                blue: 0.14,
                alpha: 0.42
            )
        )

        XCTAssertTrue(theme.isDark)
        XCTAssertEqual(theme.background, "transparent")
        XCTAssertEqual(Self.cssRGBAComponents(theme.mutedBackground)?.red, 255)
        XCTAssertEqual(Self.cssRGBAComponents(theme.mutedBackground)?.green, 255)
        XCTAssertEqual(Self.cssRGBAComponents(theme.mutedBackground)?.blue, 255)
        XCTAssertEqual(Self.cssRGBAComponents(theme.neutralMutedBackground)?.red, 255)
        XCTAssertGreaterThan(
            try XCTUnwrap(Self.cssRGBAComponents(theme.neutralMutedBackground)?.alpha),
            try XCTUnwrap(Self.cssRGBAComponents(theme.mutedBackground)?.alpha)
        )
        XCTAssertFalse(theme.mutedBackground.contains("0.420"))
        XCTAssertFalse(theme.neutralMutedBackground.contains("0.420"))
    }

    func testMarkdownThemeOverlayFallsBackToFullOverlayWhenContrastIsUnreachable() {
        let base = NSColor(srgbRed: 0.2, green: 0.24, blue: 0.28, alpha: 0.4)
        let overlay = base.markdownThemeOverlay(targetContrast: 21, of: base)

        XCTAssertEqual(overlay.alphaComponent, 1, accuracy: 0.0001)
    }

    func testMarkdownFontSizeSettingsClampAndPageZoom() {
        XCTAssertEqual(MarkdownFontSizeSettings.clamp(5), MarkdownFontSizeSettings.minimumPointSize)
        XCTAssertEqual(MarkdownFontSizeSettings.clamp(1000), MarkdownFontSizeSettings.maximumPointSize)
        XCTAssertEqual(MarkdownFontSizeSettings.clamp(20), 20)

        // pageZoom = pointSize / baseRenderPointSize (15px body).
        XCTAssertEqual(MarkdownFontSizeSettings.pageZoom(forPointSize: 15), 1.0, accuracy: 0.0001)
        XCTAssertEqual(MarkdownFontSizeSettings.pageZoom(forPointSize: 30), 2.0, accuracy: 0.0001)
        // Out-of-range sizes clamp before converting to a zoom factor.
        XCTAssertEqual(
            MarkdownFontSizeSettings.pageZoom(forPointSize: 4),
            CGFloat(MarkdownFontSizeSettings.minimumPointSize / MarkdownFontSizeSettings.baseRenderPointSize),
            accuracy: 0.0001
        )
    }

    func testMarkdownFontSizeSettingsResolvedDefaultHonorsDefaults() throws {
        let suiteName = "cmux.markdownFontSizeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Unset -> baseline default.
        XCTAssertEqual(MarkdownFontSizeSettings.resolvedDefault(defaults: defaults), MarkdownFontSizeSettings.defaultPointSize)

        // In-range override is honored.
        defaults.set(22, forKey: MarkdownFontSizeSettings.key)
        XCTAssertEqual(MarkdownFontSizeSettings.resolvedDefault(defaults: defaults), 22)

        // Out-of-range override is clamped.
        defaults.set(500, forKey: MarkdownFontSizeSettings.key)
        XCTAssertEqual(MarkdownFontSizeSettings.resolvedDefault(defaults: defaults), MarkdownFontSizeSettings.maximumPointSize)
    }

    func testMarkdownFontFamilyNormalizesDefaultsAndEscapesCSSValue() throws {
        let suiteName = "cmux.markdownFontFamilyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(MarkdownFontFamily.resolvedDefault(defaults: defaults), MarkdownFontFamily.systemDefault)
        XCTAssertNil(MarkdownFontFamily.cssValue(for: ""))

        MarkdownFontFamily.setDefault("  Avenir Next  \n", defaults: defaults)
        XCTAssertEqual(MarkdownFontFamily.resolvedDefault(defaults: defaults), "Avenir Next")
        XCTAssertEqual(MarkdownFontFamily.cssValue(for: #"Quote " Test \ Family"#), #""Quote \" Test \\ Family""#)

        MarkdownFontFamily.setDefault(" \n ", defaults: defaults)
        XCTAssertNil(defaults.object(forKey: MarkdownFontFamily.key))
    }

    func testMarkdownMaxWidthSettingsClampAndResolvedDefault() throws {
        XCTAssertEqual(MarkdownMaxWidthSettings.clamp(200), MarkdownMaxWidthSettings.minimumCSSPixels)
        XCTAssertEqual(MarkdownMaxWidthSettings.clamp(4000), MarkdownMaxWidthSettings.maximumCSSPixels)
        XCTAssertEqual(MarkdownMaxWidthSettings.clamp(980), 980)

        let suiteName = "cmux.markdownMaxWidthTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(MarkdownMaxWidthSettings.resolvedDefault(defaults: defaults), MarkdownMaxWidthSettings.defaultCSSPixels)

        MarkdownMaxWidthSettings.setDefault(1220, defaults: defaults)
        XCTAssertEqual(MarkdownMaxWidthSettings.resolvedDefault(defaults: defaults), 1220)

        defaults.set(10000, forKey: MarkdownMaxWidthSettings.key)
        XCTAssertEqual(MarkdownMaxWidthSettings.resolvedDefault(defaults: defaults), MarkdownMaxWidthSettings.maximumCSSPixels)

        MarkdownMaxWidthSettings.resetDefault(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: MarkdownMaxWidthSettings.key))
    }

    func testMarkdownPanelZoomStepsClampAndReset() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-markdown-zoom-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileURL = directoryURL.appendingPathComponent("README.md")
        try "# hello".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: directoryURL) }

        // Pin the persisted default to a non-boundary value so the reset
        // assertions below don't depend on (or mutate) the developer's settings.
        let defaultsKey = MarkdownFontSizeSettings.key
        let savedDefault = UserDefaults.standard.object(forKey: defaultsKey)
        UserDefaults.standard.set(20, forKey: defaultsKey)
        defer {
            if let savedDefault {
                UserDefaults.standard.set(savedDefault, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        let panel = MarkdownPanel(workspaceId: UUID(), filePath: fileURL.path, fontSize: 15)
        defer { panel.close() }

        XCTAssertEqual(panel.fontSize, 15)

        // Each step changes by exactly one point and reports the change.
        XCTAssertTrue(panel.zoomOut())
        XCTAssertEqual(panel.fontSize, 15 - MarkdownFontSizeSettings.stepPointSize)
        XCTAssertTrue(panel.zoomIn())
        XCTAssertEqual(panel.fontSize, 15)

        // Zooming out clamps at the minimum and then reports no change.
        var guardCount = 0
        while panel.zoomOut() { guardCount += 1; XCTAssertLessThan(guardCount, 1000) }
        XCTAssertEqual(panel.fontSize, MarkdownFontSizeSettings.minimumPointSize)
        XCTAssertFalse(panel.zoomOut())

        // Reset returns to the configured default (seeded to 20 above) and
        // reports the change.
        XCTAssertTrue(panel.resetZoom())
        XCTAssertEqual(panel.fontSize, 20)
        XCTAssertFalse(panel.resetZoom())
    }

    func testMarkdownPanelTypographyResetsToConfiguredDefaults() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-markdown-typography-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileURL = directoryURL.appendingPathComponent("README.md")
        try "# hello".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let savedSize = UserDefaults.standard.object(forKey: MarkdownFontSizeSettings.key)
        let savedFamily = UserDefaults.standard.object(forKey: MarkdownFontFamily.key)
        UserDefaults.standard.set(19, forKey: MarkdownFontSizeSettings.key)
        UserDefaults.standard.set("Avenir Next", forKey: MarkdownFontFamily.key)
        defer {
            if let savedSize {
                UserDefaults.standard.set(savedSize, forKey: MarkdownFontSizeSettings.key)
            } else {
                UserDefaults.standard.removeObject(forKey: MarkdownFontSizeSettings.key)
            }
            if let savedFamily {
                UserDefaults.standard.set(savedFamily, forKey: MarkdownFontFamily.key)
            } else {
                UserDefaults.standard.removeObject(forKey: MarkdownFontFamily.key)
            }
        }

        let panel = MarkdownPanel(workspaceId: UUID(), filePath: fileURL.path, fontSize: 15)
        defer { panel.close() }

        XCTAssertEqual(panel.fontFamily, "Avenir Next")
        XCTAssertTrue(panel.setFontFamily("  Menlo  \n"))
        XCTAssertEqual(panel.fontFamily, "Menlo")
        panel.resetTypography()
        XCTAssertEqual(panel.fontSize, 19)
        XCTAssertEqual(panel.fontFamily, "Avenir Next")
    }

    private static func cssRGBAComponents(_ css: String) -> (red: Int, green: Int, blue: Int, alpha: Double)? {
        let pattern = #"rgba\((\d+), (\d+), (\d+), ([0-9.]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: css, range: NSRange(css.startIndex..., in: css)),
              match.numberOfRanges == 5 else {
            return nil
        }
        func string(at index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: css) else { return nil }
            return String(css[range])
        }
        guard let red = string(at: 1).flatMap(Int.init),
              let green = string(at: 2).flatMap(Int.init),
              let blue = string(at: 3).flatMap(Int.init),
              let alpha = string(at: 4).flatMap(Double.init) else {
            return nil
        }
        return (red, green, blue, alpha)
    }

}
