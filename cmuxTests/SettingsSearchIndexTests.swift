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
        assertSearch("workspace cwd", contains: SettingsSearchIndex.settingID(for: .app, idSuffix: "workspace-inherit-working-directory"))
        assertSearch("claude sessions", contains: SettingsSearchIndex.settingID(for: .terminal, idSuffix: "agent-auto-resume"))
        assertSearch("opencode resume", contains: SettingsSearchIndex.settingID(for: .terminal, idSuffix: "agent-auto-resume"))
        assertSearch("ctrl b", contains: SettingsSearchIndex.settingID(for: .keyboardShortcuts, idSuffix: "shortcut-chords"))
        assertSearch("split right", contains: SettingsSearchIndex.settingID(for: .keyboardShortcuts, idSuffix: "shortcuts"))
        assertSearch("factory defaults", contains: SettingsSearchIndex.settingID(for: .reset, idSuffix: "reset-all"))
        assertSearch("imessage", contains: SettingsSearchIndex.settingID(for: .app, idSuffix: "imessage-mode"))
        assertSearch("chat prompt", contains: SettingsSearchIndex.settingID(for: .app, idSuffix: "imessage-mode"))
        assertSearch("reset shortcut defaults", contains: SettingsSearchIndex.settingID(for: .keyboardShortcuts, idSuffix: "reset-defaults"))
        assertSearch("clickable pr", contains: SettingsSearchIndex.settingID(for: .sidebarAppearance, idSuffix: "make-pr-clickable"))
        assertSearch("clickable pull requests", contains: SettingsSearchIndex.settingID(for: .sidebarAppearance, idSuffix: "make-pr-clickable"))
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

    func testSettingsPathAnchorIncludesWorkspaceWorkingDirectoryInheritance() {
        XCTAssertEqual(
            SettingsSearchIndex.anchorID(forSettingsPath: "app.workspaceInheritWorkingDirectory"),
            SettingsSearchIndex.settingID(for: .app, idSuffix: "workspace-inherit-working-directory")
        )
    }

    func testSettingsPathAnchorIncludesIMessageMode() {
        XCTAssertEqual(
            SettingsSearchIndex.anchorID(forSettingsPath: "app.iMessageMode"),
            SettingsSearchIndex.settingID(for: .app, idSuffix: "imessage-mode")
        )
    }

    func testSettingsPathAnchorIncludesClickablePullRequests() {
        XCTAssertEqual(
            SettingsSearchIndex.anchorID(forSettingsPath: "sidebar.makePullRequestsClickable"),
            SettingsSearchIndex.settingID(for: .sidebarAppearance, idSuffix: "make-pr-clickable")
        )
    }

    func testSettingsPathAnchorIncludesShortcutBindings() {
        XCTAssertEqual(
            SettingsSearchIndex.anchorID(forSettingsPath: "shortcuts.bindings"),
            SettingsSearchIndex.settingID(for: .keyboardShortcuts, idSuffix: "shortcuts")
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
