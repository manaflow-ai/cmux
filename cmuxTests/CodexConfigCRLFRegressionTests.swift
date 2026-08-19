import Foundation
import Testing

/// Covers the Codex `config.toml` install pipeline against a CRLF config —
/// `codexConfigTomlRemovingHookTrust` → `codexConfigTomlInstallingHooksFeature`
/// → `codexConfigTomlInstallingHookTrust`, driven through the real
/// `cmux hooks codex` commands.
///
/// TOML permits CRLF, and `tomlLines(from:)` used to split on `"\n"` and leave a
/// `"\r"` on every line, so the exact marker comparisons those functions run
/// never matched a CRLF config: reinstalling appended a second trust block over
/// an orphaned begin marker, and uninstall left the cmux `[features]` block with
/// `hooks = true` in the user's config.
@Suite(.serialized)
struct CodexConfigCRLFRegressionTests {
    @Test func codexHookInstallRefreshesCRLFConfigInPlaceAndUninstallRemovesIt() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-crlf-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = codexHome.appendingPathComponent("config.toml", isDirectory: false)
        let originalLF = "model = \"gpt-5\"\napproval_policy = \"on-request\"\n"
        try originalLF.write(to: configURL, atomically: true, encoding: .utf8)

        func runCodexHooks(_ subcommand: String) {
            let result = runCodexHookProcess(
                executablePath: cliPath,
                arguments: ["hooks", "codex", subcommand, "--yes"],
                environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
                timeout: 30
            )
            #expect(result.status == 0, Comment(rawValue: result.stderr))
        }

        runCodexHooks("install")
        let installedLF = try String(contentsOf: configURL, encoding: .utf8)
        #expect(markerCount(in: installedLF, prefix: Self.featureMarkerPrefix, suffix: "begin") == 1)
        #expect(markerCount(in: installedLF, prefix: Self.trustMarkerPrefix, suffix: "begin") == 1)

        // Hand the file back the way a Windows-side editor or a CRLF-normalizing
        // sync would, then let cmux refresh its own block.
        let installedCRLF = installedLF.replacingOccurrences(of: "\n", with: "\r\n")
        try installedCRLF.write(to: configURL, atomically: true, encoding: .utf8)
        runCodexHooks("install")

        let refreshed = try String(contentsOf: configURL, encoding: .utf8)
        // The refresh must find the existing blocks rather than append new ones,
        // must not grow a blank line, and must leave the file in CRLF: the whole
        // rewrite equals the LF install output with CRLF endings, line for line.
        #expect(refreshed == installedCRLF)
        #expect(markerCount(in: refreshed, prefix: Self.featureMarkerPrefix, suffix: "begin") == 1)
        #expect(markerCount(in: refreshed, prefix: Self.trustMarkerPrefix, suffix: "begin") == 1)
        #expect(markerCount(in: refreshed, prefix: Self.trustMarkerPrefix, suffix: "end") == 1)
        #expect(!refreshed.replacingOccurrences(of: "\r\n", with: "").contains("\n"))

        runCodexHooks("uninstall")

        let uninstalled = try String(contentsOf: configURL, encoding: .utf8)
        #expect(uninstalled == originalLF.replacingOccurrences(of: "\n", with: "\r\n"))
        #expect(!uninstalled.contains("cmux-codex"))
        #expect(!uninstalled.contains("hooks = true"))
    }

    /// Counts the cmux marker lines with `prefix` and `suffix`, ignoring the UUID
    /// between them so the test does not restate the marker constants.
    private func markerCount(in contents: String, prefix: String, suffix: String) -> Int {
        contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }
            .count
    }

    private static let featureMarkerPrefix = "# cmux-codex-hooks-feature-"
    private static let trustMarkerPrefix = "# cmux-codex-hook-trust-"
}
