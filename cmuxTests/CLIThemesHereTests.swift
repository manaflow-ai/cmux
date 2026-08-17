import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cmux themes here` recolors only the surface it runs in, so its whole contract is the byte
/// stream it writes to stdout. These tests read that stream directly rather than asserting on
/// config files, which `here` deliberately never touches.
extension CMUXCLIErrorOutputRegressionTests {
    private static let sampleThemeContents = """
        # Sample theme
        background = #1E1E2E
        foreground = cdd6f4
        cursor-color = #f5e0dc
        palette = 1=#f38ba8
        """

    private static let sampleThemeSequence =
        "\u{1B}]11;#1e1e2e\u{07}"
        + "\u{1B}]10;#cdd6f4\u{07}"
        + "\u{1B}]12;#f5e0dc\u{07}"
        + "\u{1B}]4;1;#f38ba8\u{07}"

    /// Writes a throwaway Ghostty resources tree holding one theme, and returns the environment
    /// that pins the CLI to it plus a home directory it cannot escape.
    private func themesHereEnvironment(
        root: URL,
        themeName: String,
        themeContents: String
    ) throws -> [String: String] {
        let themesDirectory = root
            .appendingPathComponent("resources", isDirectory: true)
            .appendingPathComponent("themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themesDirectory, withIntermediateDirectories: true)
        try themeContents.write(
            to: themesDirectory.appendingPathComponent(themeName, isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        return [
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_SOCKET_PATH": root.appendingPathComponent("cmux.sock").path,
            "CFFIXED_USER_HOME": home.path,
            "HOME": home.path,
            "GHOSTTY_RESOURCES_DIR": root.appendingPathComponent("resources", isDirectory: true).path,
            "PATH": "/usr/bin:/bin",
        ]
    }

    @Test func testThemesHereWritesOnlyDynamicColorSequencesForTheNamedTheme() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-themes-here-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let environment = try themesHereEnvironment(
            root: root,
            themeName: "Sample Theme",
            themeContents: Self.sampleThemeContents
        )

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["themes", "here", "Sample Theme"],
            environment: environment,
            timeout: 30
        )

        #expect(result.status == 0, "\(result.diagnostics)")
        // Exact match, with no trailing newline: `here` writes into a live surface, so any stray
        // byte it emits would scroll that surface or land in the user's shell prompt.
        #expect(result.stdout == Self.sampleThemeSequence, "\(result.diagnostics)")
    }

    @Test func testThemesHereResetWritesResetSequenceWithoutRequiringATheme() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-themes-here-reset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let environment = try themesHereEnvironment(
            root: root,
            themeName: "Sample Theme",
            themeContents: Self.sampleThemeContents
        )

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["themes", "here", "--reset"],
            environment: environment,
            timeout: 30
        )

        #expect(result.status == 0, "\(result.diagnostics)")
        #expect(result.stdout == CMUXCLI.paneThemeResetSequence, "\(result.diagnostics)")
    }

    @Test func testThemesHereRejectsUnknownThemeWithoutWritingToStdout() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-themes-here-unknown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let environment = try themesHereEnvironment(
            root: root,
            themeName: "Sample Theme",
            themeContents: Self.sampleThemeContents
        )

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["themes", "here", "No Such Theme"],
            environment: environment,
            timeout: 30
        )

        #expect(result.status != 0, "\(result.diagnostics)")
        // A half-applied theme is worse than none: a failed lookup must leave the surface alone.
        #expect(result.stdout.isEmpty, "\(result.diagnostics)")
    }

    @Test func testPaneThemeSequenceSkipsCommentsAndUnparseableColors() {
        let contents = """
            # background = #000000
            background = #123
            foreground = not-a-color
            palette = 300=#ffffff
            palette = 2 = #00FF00
            selection-background = #abcdef
            """

        // Short hex expands, the commented and malformed entries drop out, the out-of-range
        // palette slot drops out, and keys with no OSC equivalent are ignored.
        #expect(
            CMUXCLI.paneThemeSequence(forThemeContents: contents)
                == "\u{1B}]11;#112233\u{07}\u{1B}]4;2;#00ff00\u{07}"
        )
    }
}
