import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class GhosttyConfigTests: XCTestCase {
    func testThemeNameCandidatesIncludeBuiltinAliasForms() {
        let candidates = GhosttyConfig.themeNameCandidates(from: "Builtin Solarized Light")
        XCTAssertEqual(candidates.first, "Builtin Solarized Light")
        XCTAssertTrue(candidates.contains("Solarized Light"))
    }

    func testThemeSearchPathsIncludeXDGDataDirsThemes() {
        let pathA = "/tmp/cmux-theme-a"
        let pathB = "/tmp/cmux-theme-b"
        let paths = GhosttyConfig.themeSearchPaths(
            forThemeName: "Solarized Light",
            environment: ["XDG_DATA_DIRS": "\(pathA):\(pathB)"],
            bundleResourceURL: nil
        )

        XCTAssertTrue(paths.contains("\(pathA)/ghostty/themes/Solarized Light"))
        XCTAssertTrue(paths.contains("\(pathB)/ghostty/themes/Solarized Light"))
    }

    func testLoadThemeResolvesBuiltinAliasFromGhosttyResourcesDir() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-themes-\(UUID().uuidString)")
        let themesDir = root.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let themePath = themesDir.appendingPathComponent("Solarized Light")
        let themeContents = """
        background = #fdf6e3
        foreground = #657b83
        """
        try themeContents.write(to: themePath, atomically: true, encoding: .utf8)

        var config = GhosttyConfig()
        config.loadTheme(
            "Builtin Solarized Light",
            environment: ["GHOSTTY_RESOURCES_DIR": root.path],
            bundleResourceURL: nil
        )

        let background = config.backgroundColor.usingColorSpace(.sRGB)!
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        background.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        XCTAssertEqual(Int(round(red * 255)), 253)
        XCTAssertEqual(Int(round(green * 255)), 246)
        XCTAssertEqual(Int(round(blue * 255)), 227)
    }
}
