import CMUXAgentLaunch
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class ClaudeConfigDirectoryPathTests: XCTestCase {
    func testPrefersCodexAccountsAliasForSubrouterPath() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-config-home-\(UUID().uuidString)", isDirectory: true)
        let legacyConfig = home
            .appendingPathComponent(".subrouter", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: true)
            .appendingPathComponent("claude", isDirectory: true)
            .appendingPathComponent("_p1775010019397", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyConfig, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".codex-accounts", isDirectory: true),
            withDestinationURL: home.appendingPathComponent(".subrouter", isDirectory: true)
                .appendingPathComponent("codex", isDirectory: true)
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let preferred = ClaudeConfigDirectoryPath.preferredPath(
            legacyConfig.path,
            homeDirectory: home.path
        )

        XCTAssertEqual(
            preferred,
            home
                .appendingPathComponent(".codex-accounts", isDirectory: true)
                .appendingPathComponent("claude", isDirectory: true)
                .appendingPathComponent("_p1775010019397", isDirectory: true)
                .path
        )
    }
}
