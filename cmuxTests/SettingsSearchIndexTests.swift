import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SettingsSearchIndexTests: XCTestCase {
    func testAlternativeSearchTermsFindSettingsRows() {
        assertSearch("dockless", contains: SettingsSearchIndex.settingID(for: .app, idSuffix: "menu-bar-only"))
        assertSearch("menubar", contains: SettingsSearchIndex.settingID(for: .app, idSuffix: "show-menu-bar"))
        assertSearch("vscode", contains: SettingsSearchIndex.settingID(for: .app, idSuffix: "preferred-editor"))
        assertSearch("cmd q", contains: SettingsSearchIndex.settingID(for: .app, idSuffix: "warn-before-quit"))
        assertSearch("sound file", contains: SettingsSearchIndex.settingID(for: .app, idSuffix: "notification-sound"))
        assertSearch("disable browser", contains: SettingsSearchIndex.settingID(for: .browser, idSuffix: "enable-browser"))
        assertSearch("http allowlist", contains: SettingsSearchIndex.settingID(for: .browser, idSuffix: "http-allowlist"))
        assertSearch("claude executable", contains: SettingsSearchIndex.settingID(for: .automation, idSuffix: "claude-path"))
        assertSearch("resume on reopen", contains: SettingsSearchIndex.settingID(for: .terminal, idSuffix: "agent-auto-resume"))
        assertSearch("claude sessions", contains: SettingsSearchIndex.settingID(for: .terminal, idSuffix: "agent-auto-resume"))
        assertSearch("opencode resume", contains: SettingsSearchIndex.settingID(for: .terminal, idSuffix: "agent-auto-resume"))
        assertSearch("status command", contains: SettingsSearchIndex.settingID(for: .terminal, idSuffix: "status-bar"))
        assertSearch("pinned bottom rows", contains: SettingsSearchIndex.settingID(for: .terminal, idSuffix: "status-bar"))
        assertSearch("ctrl b", contains: SettingsSearchIndex.settingID(for: .keyboardShortcuts, idSuffix: "shortcut-chords"))
        assertSearch("split right", contains: SettingsSearchIndex.settingID(for: .keyboardShortcuts, idSuffix: "shortcuts"))
        assertSearch("factory defaults", contains: SettingsSearchIndex.settingID(for: .reset, idSuffix: "reset-all"))
    }

    func testSettingsPathAnchorIncludesBrowserEnabled() {
        XCTAssertEqual(
            SettingsSearchIndex.anchorID(forSettingsPath: "browser.enabled"),
            SettingsSearchIndex.settingID(for: .browser, idSuffix: "enable-browser")
        )
    }

    func testSettingsPathAnchorIncludesAgentAutoResume() {
        XCTAssertEqual(
            SettingsSearchIndex.anchorID(forSettingsPath: "terminal.autoResumeAgentSessions"),
            SettingsSearchIndex.settingID(for: .terminal, idSuffix: "agent-auto-resume")
        )
    }

    func testSettingsPathAnchorIncludesTerminalStatusBar() {
        XCTAssertEqual(
            SettingsSearchIndex.anchorID(forSettingsPath: "terminal.statusBar.command"),
            SettingsSearchIndex.settingID(for: .terminal, idSuffix: "status-bar")
        )
    }

    private func assertSearch(
        _ query: String,
        contains expectedID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let resultIDs = Set(SettingsSearchIndex.entries(matching: query).map(\.id))
        XCTAssertTrue(
            resultIDs.contains(expectedID),
            "Expected settings search for '\(query)' to include \(expectedID), got \(resultIDs.sorted())",
            file: file,
            line: line
        )
    }
}
