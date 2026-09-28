import Foundation
import Testing

/// `cmux themes export` renders the terminal theme cmux resolves (the Ghostty
/// theme pair plus colors set in the config) as an agent theme file. Each test
/// runs the bundled CLI against its own temporary HOME, so the user's real
/// ~/.claude and ~/.config are never read or written.
@Suite(.serialized)
struct CLIThemesExportTests {
    private static let timeout: TimeInterval = 60
    private static let darkTheme = """
    background = #101020
    foreground = #c0c0d0
    palette = 4=#4080ff
    palette = 5=#c060e0
    selection-background = #303050
    """
    private static let lightTheme = """
    background = #f4f4f8
    foreground = #303040
    palette = 4=#1050c0
    palette = 5=#9030b0
    """

    @Test func claudeExportPrintsTheResolvedDarkThemeWithConfigColors() throws {
        let fixture = try Fixture()
        let result = try fixture.run(["themes", "export", "--to", "claude", "--appearance", "dark"])

        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(json["name"] as? String == "Export Test Dark (cmux)")
        #expect(json["base"] as? String == "dark")
        let overrides = try #require(json["overrides"] as? [String: String])
        #expect(overrides["claude"] == "#c060e0")
        #expect(overrides["selectionBg"] == "#303050")
        // The config's `foreground` wins over the theme file's.
        #expect(overrides["text"] == "#e0e0e0")
        #expect(fixture.writtenFiles().isEmpty)
    }

    @Test func colorsFromConfigFileIncludesApplyLikeTheApp() throws {
        let fixture = try Fixture()
        let ghostty = fixture.home.appendingPathComponent(".config/ghostty", isDirectory: true)
        try "palette = 5=#123456\n".write(
            to: ghostty.appendingPathComponent("colors.ghostty"), atomically: true, encoding: .utf8
        )
        let config = ghostty.appendingPathComponent("config")
        let contents = try String(contentsOf: config, encoding: .utf8)
        try (contents + "\nconfig-file = colors.ghostty\n").write(to: config, atomically: true, encoding: .utf8)

        let result = try fixture.run(["themes", "export", "--to", "claude", "--appearance", "dark"])

        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let overrides = try #require(json["overrides"] as? [String: String])
        #expect(overrides["claude"] == "#123456")
        #expect(overrides["text"] == "#e0e0e0")
    }

    @Test func printingNeedsNoFileNameForAThemeWithoutASCIILetters() throws {
        let fixture = try Fixture()
        let ghostty = fixture.home.appendingPathComponent(".config/ghostty", isDirectory: true)
        try CLIThemesExportTests.darkTheme.write(
            to: ghostty.appendingPathComponent("themes/夜"), atomically: true, encoding: .utf8
        )
        try "theme = 夜\n".write(to: ghostty.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        let printed = try fixture.run(["themes", "export", "--to", "claude"])
        #expect(printed.status == 0, Comment(rawValue: printed.stderr))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(printed.stdout.utf8)) as? [String: Any])
        #expect(json["name"] as? String == "夜 (cmux)")

        let written = try fixture.run(["themes", "export", "--to", "claude", "--write"])
        #expect(written.status != 0)
        #expect(written.stderr.contains("--name"))
        #expect(fixture.writtenFiles().isEmpty)
    }

    @Test func openCodeExportCarriesBothHalvesOfTheThemePair() throws {
        let fixture = try Fixture()
        let result = try fixture.run(["themes", "export", "--to", "opencode"])

        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(json["$schema"] as? String == "https://opencode.ai/theme.json")
        let defs = try #require(json["defs"] as? [String: String])
        #expect(defs["darkBlue"] == "#4080ff")
        #expect(defs["lightBlue"] == "#1050c0")
        let theme = try #require(json["theme"] as? [String: Any])
        #expect(theme["primary"] as? [String: String] == ["dark": "darkBlue", "light": "lightBlue"])
        #expect(theme["background"] as? String == "none")
    }

    @Test func claudeWriteSavesACmuxPrefixedThemeAndLeavesOtherThemesAlone() throws {
        let fixture = try Fixture()
        let themes = fixture.home.appendingPathComponent(".claude/themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        let userTheme = themes.appendingPathComponent("my-theme.json")
        try "{\"name\":\"mine\"}".write(to: userTheme, atomically: true, encoding: .utf8)

        let result = try fixture.run([
            "themes", "export", "--to", "claude", "--write", "--name", "My Theme", "--appearance", "light",
        ])

        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let written = themes.appendingPathComponent("cmux-my-theme.json")
        let lines = result.stdout.split(separator: "\n").map(String.init)
        #expect(lines.first == written.path)
        #expect(lines.dropFirst().joined().contains("/theme"))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: written)) as? [String: Any])
        #expect(json["name"] as? String == "My Theme")
        #expect(json["base"] as? String == "light")
        #expect(try String(contentsOf: userTheme, encoding: .utf8) == "{\"name\":\"mine\"}")
    }

    @Test func openCodeWriteReportsThePathAsJSON() throws {
        let fixture = try Fixture()
        let result = try fixture.run(["themes", "export", "--to", "opencode", "--write", "--json"])

        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let slug = "cmux-export-test-dark-export-test-light"
        let expected = fixture.home.appendingPathComponent(".config/opencode/themes/\(slug).json")
        #expect(json["path"] as? String == expected.path)
        #expect(json["theme"] as? String == slug)
        #expect(FileManager.default.fileExists(atPath: expected.path))
    }

    @Test func invalidArgumentsFailWithoutWriting() throws {
        let fixture = try Fixture()
        for arguments in [
            ["themes", "export"],
            ["themes", "export", "--to", "vim", "--write"],
            ["themes", "export", "--to", "claude", "--write", "--appearance", "dim"],
            ["themes", "export", "--to", "claude", "--write", "--name", "!!!"],
            ["themes", "export", "--to", "claude", "--write", "extra"],
        ] {
            let result = try fixture.run(arguments)
            #expect(result.status != 0, Comment(rawValue: arguments.joined(separator: " ")))
            #expect(!result.stderr.isEmpty, Comment(rawValue: arguments.joined(separator: " ")))
        }
        #expect(fixture.writtenFiles().isEmpty)
    }

    /// A temporary HOME with a Ghostty config selecting a light/dark pair of
    /// test themes and overriding the foreground.
    private final class Fixture {
        let root: URL
        let home: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-cli-theme-export-\(UUID().uuidString)", isDirectory: true)
            home = root.appendingPathComponent("home", isDirectory: true)
            let ghostty = home.appendingPathComponent(".config/ghostty", isDirectory: true)
            let themes = ghostty.appendingPathComponent("themes", isDirectory: true)
            try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
            try CLIThemesExportTests.darkTheme.write(
                to: themes.appendingPathComponent("Export Test Dark"), atomically: true, encoding: .utf8
            )
            try CLIThemesExportTests.lightTheme.write(
                to: themes.appendingPathComponent("Export Test Light"), atomically: true, encoding: .utf8
            )
            try """
            theme = light:Export Test Light,dark:Export Test Dark
            foreground = #e0e0e0
            """.write(to: ghostty.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        func run(_ arguments: [String]) throws -> CLIHookProcessRunner.Result {
            let environment = [
                "CMUX_SOCKET_PATH": root.appendingPathComponent("missing.sock").path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CFFIXED_USER_HOME": home.path,
                "HOME": home.path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            ]
            let result = CLIHookProcessRunner.run(
                executablePath: try BundledCLITestSupport.bundledCLIPath(for: CLITestBundleAnchor.self),
                arguments: arguments,
                environment: environment,
                timeout: CLIThemesExportTests.timeout
            )
            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            return result
        }

        /// Files under the agent theme folders, which only `--write` creates.
        func writtenFiles() -> [String] {
            [".claude/themes", ".config/opencode/themes"].flatMap { path in
                (try? FileManager.default.contentsOfDirectory(
                    atPath: home.appendingPathComponent(path).path
                )) ?? []
            }
        }
    }
}
