@preconcurrency import XCTest
import CmuxSettings
import CmuxSocketControl
import AppKit
import Combine
import CoreText
import WebKit
import Darwin
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Theme name candidates, search paths, themes list
extension GhosttyConfigTests {
    func testResolveThemeNamePrefersLightEntryForPairedTheme() {
        let resolved = GhosttyConfig.resolveThemeName(
            from: "light:Builtin Solarized Light,dark:Builtin Solarized Dark",
            preferredColorScheme: .light
        )

        XCTAssertEqual(resolved, "Builtin Solarized Light")
    }

    func testResolveThemeNamePrefersDarkEntryForPairedTheme() {
        let resolved = GhosttyConfig.resolveThemeName(
            from: "light:Builtin Solarized Light,dark:Builtin Solarized Dark",
            preferredColorScheme: .dark
        )

        XCTAssertEqual(resolved, "Builtin Solarized Dark")
    }

    func testThemeNameCandidatesIncludeBuiltinAliasForms() {
        let candidates = GhosttyConfig.themeNameCandidates(from: "Builtin Solarized Light")
        XCTAssertEqual(candidates.first, "Builtin Solarized Light")
        XCTAssertTrue(candidates.contains("Solarized Light"))
        XCTAssertTrue(candidates.contains("iTerm2 Solarized Light"))
    }

    func testThemeNameCandidatesMapSolarizedDarkToITerm2Alias() {
        let candidates = GhosttyConfig.themeNameCandidates(from: "Builtin Solarized Dark")
        XCTAssertTrue(candidates.contains("Solarized Dark"))
        XCTAssertTrue(candidates.contains("iTerm2 Solarized Dark"))
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

    func testThemeSearchPathsIncludeCmuxUserThemesDirectory() {
        let paths = GhosttyConfig.themeSearchPaths(
            forThemeName: "Zag Light",
            environment: [:],
            bundleResourceURL: nil
        )

        XCTAssertTrue(
            paths.contains(
                "\(NSHomeDirectory())/Library/Application Support/com.cmuxterm.app/themes/Zag Light"
            )
        )
    }

    func testThemeSearchPathsIncludeCmuxUserThemesDirectoryFromFixedHome() {
        let fixedHome = "/tmp/cmux-fixed-home-\(UUID().uuidString)"
        let paths = GhosttyConfig.themeSearchPaths(
            forThemeName: "Zag Light",
            environment: ["CFFIXED_USER_HOME": fixedHome],
            bundleResourceURL: nil
        )

        XCTAssertTrue(
            paths.contains(
                "\(fixedHome)/Library/Application Support/com.cmuxterm.app/themes/Zag Light"
            )
        )
    }

    func testThemesListIncludesCmuxUserThemesDirectory() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-user-theme-list-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let themesDirectory = root
            .appendingPathComponent("Library/Application Support/com.cmuxterm.app/themes", isDirectory: true)
        try fileManager.createDirectory(at: themesDirectory, withIntermediateDirectories: true)
        try "background = #ffffff\nforeground = #1f2328\n".write(
            to: themesDirectory.appendingPathComponent("Zag Light", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        let configURL = themesDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("config.ghostty", isDirectory: false)
        try "theme = Zag Light\n".write(to: configURL, atomically: true, encoding: .utf8)

        let result = runCLI(
            try bundledCLIPath(),
            arguments: ["--json", "themes", "list"],
            environment: ["CFFIXED_USER_HOME": root.path],
            timeout: 10
        )

        XCTAssertFalse(result.timedOut, result.output)
        XCTAssertEqual(result.status, 0, result.output)

        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]
        )
        let themes = try XCTUnwrap(payload["themes"] as? [[String: Any]])
        XCTAssertTrue(themes.contains { ($0["name"] as? String) == "Zag Light" }, result.output)
        let current = try XCTUnwrap(payload["current"] as? [String: Any])
        XCTAssertEqual(current["light"] as? String, "Zag Light")
        XCTAssertEqual(current["dark"] as? String, "Zag Light")
        XCTAssertEqual(current["source_path"] as? String, configURL.path)
    }

    private struct CLIResult {
        let status: Int32
        let output: String
        let timedOut: Bool
    }

    private func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: Self.self)
    }

    private func runCLI(
        _ cliPath: String,
        arguments: [String],
        environment overrides: [String: String],
        timeout: TimeInterval
    ) -> CLIResult {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in overrides {
            environment[key] = value
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            return CLIResult(status: -1, output: String(describing: error), timedOut: false)
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = exitSignal.wait(timeout: .now() + 1)
        }

        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return CLIResult(status: process.terminationStatus, output: output, timedOut: timedOut)
    }

}
