import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("SettingsSearchIndex")
struct SettingsSearchIndexTests {
    @Test func alternativeSearchTermsFindSettingsRows() {
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
        assertSearch("textbox new terminals", contains: SettingsSearchIndex.settingID(for: .textBox, idSuffix: "show-textbox-new-terminals"))
        assertSearch("textbox focus", contains: SettingsSearchIndex.settingID(for: .textBox, idSuffix: "focus-textbox-new-terminals"))
        assertSearch("textbox height", contains: SettingsSearchIndex.settingID(for: .textBox, idSuffix: "textbox-max-lines"))
        assertSearch("tmux resume command approval", contains: SettingsSearchIndex.settingID(for: .terminal, idSuffix: "resume-commands"))
        assertSearch("ctrl b", contains: SettingsSearchIndex.settingID(for: .keyboardShortcuts, idSuffix: "shortcut-chords"))
        assertSearch("split right", contains: SettingsSearchIndex.settingID(for: .keyboardShortcuts, idSuffix: "shortcuts"))
        assertSearch("factory defaults", contains: SettingsSearchIndex.settingID(for: .reset, idSuffix: "reset-all"))
        assertSearch("imessage", contains: SettingsSearchIndex.settingID(for: .app, idSuffix: "imessage-mode"))
        assertSearch("chat prompt", contains: SettingsSearchIndex.settingID(for: .app, idSuffix: "imessage-mode"))
        assertSearch("reset shortcut defaults", contains: SettingsSearchIndex.settingID(for: .keyboardShortcuts, idSuffix: "reset-defaults"))
        assertSearch("clickable pr", contains: SettingsSearchIndex.settingID(for: .sidebarAppearance, idSuffix: "make-pr-clickable"))
        assertSearch("clickable pull requests", contains: SettingsSearchIndex.settingID(for: .sidebarAppearance, idSuffix: "make-pr-clickable"))
        assertSearch("naming", contains: SettingsSearchIndex.settingID(for: .automation, idSuffix: "workspace-auto-naming"))
        assertSearch("nmaing", contains: SettingsSearchIndex.settingID(for: .automation, idSuffix: "workspace-auto-naming"))
        assertSearch("auto name", contains: SettingsSearchIndex.settingID(for: .automation, idSuffix: "workspace-auto-naming"))
        assertSearch("rename workspace", contains: SettingsSearchIndex.settingID(for: .automation, idSuffix: "workspace-auto-naming"))
        assertSearch("naming agent", contains: SettingsSearchIndex.settingID(for: .automation, idSuffix: "workspace-auto-naming"))
        assertSearch("automation.autoNamingAgent", contains: SettingsSearchIndex.settingID(for: .automation, idSuffix: "workspace-auto-naming"))
        assertSearch("autoNamingAgent", contains: SettingsSearchIndex.settingID(for: .automation, idSuffix: "workspace-auto-naming"))
        assertSearch("option as alt", contains: SettingsSearchIndex.settingID(for: .app, idSuffix: "terminal-config"))
        assertSearch("option", contains: SettingsSearchIndex.settingID(for: .app, idSuffix: "terminal-config"))
        assertSearch("environment variables", contains: SettingsSearchIndex.settingID(for: .app, idSuffix: "notification-command"))
        assertSearch("canvas", contains: SettingsSearchIndex.settingID(for: .app, idSuffix: "canvas-pane-gap"))
        assertSearch("canvas", contains: SettingsSearchIndex.settingID(for: .app, idSuffix: "canvas-snapping"))
        assertSearch("canvas", contains: SettingsSearchIndex.settingID(for: .keyboardShortcuts, idSuffix: "shortcuts"))
    }

    @Test func exactAndSubstringMatchesRankAheadOfFuzzyFallbacks() {
        #expect(
            SettingsSearchIndex.entries(matching: "Terminal Config").first?.id
                == SettingsSearchIndex.settingID(for: .app, idSuffix: "terminal-config")
        )
        #expect(
            SettingsSearchIndex.entries(matching: "copy on select").first?.id
                == SettingsSearchIndex.settingID(for: .terminal, idSuffix: "copy-on-select")
        )
    }

    @Test func settingsPathAnchorIncludesBrowserEnabled() {
        #expect(
            SettingsSearchIndex.anchorID(forSettingsPath: "browser.enabled")
                == SettingsSearchIndex.settingID(for: .browser, idSuffix: "enable-browser")
        )
    }

    @Test func settingsPathAnchorIncludesAgentAutoResume() {
        #expect(
            SettingsSearchIndex.anchorID(forSettingsPath: "terminal.autoResumeAgentSessions")
                == SettingsSearchIndex.settingID(for: .terminal, idSuffix: "agent-auto-resume")
        )
    }

    @Test func conditionalAutoNamingAgentDoesNotReuseWorkspaceAutoNamingAnchor() {
        #expect(SettingsSearchIndex.anchorID(forSettingsPath: "automation.autoNamingAgent") == nil)
    }

    @Test func settingsPathAnchorIncludesTextBoxMaxLines() {
        #expect(
            SettingsSearchIndex.anchorID(forSettingsPath: "terminal.textBoxMaxLines")
                == SettingsSearchIndex.settingID(for: .textBox, idSuffix: "textbox-max-lines")
        )
    }

    @Test func settingsPathAnchorIncludesShowTextBoxOnNewTerminals() {
        #expect(
            SettingsSearchIndex.anchorID(forSettingsPath: "terminal.showTextBoxOnNewTerminals")
                == SettingsSearchIndex.settingID(for: .textBox, idSuffix: "show-textbox-new-terminals")
        )
    }

    @Test func settingsPathAnchorIncludesFocusTextBoxOnNewTerminals() {
        #expect(
            SettingsSearchIndex.anchorID(forSettingsPath: "terminal.focusTextBoxOnNewTerminals")
                == SettingsSearchIndex.settingID(for: .textBox, idSuffix: "focus-textbox-new-terminals")
        )
    }

    @Test func settingsPathAnchorIncludesWorkspaceWorkingDirectoryInheritance() {
        #expect(
            SettingsSearchIndex.anchorID(forSettingsPath: "app.workspaceInheritWorkingDirectory")
                == SettingsSearchIndex.settingID(for: .app, idSuffix: "workspace-inherit-working-directory")
        )
    }

    @Test func settingsPathAnchorIncludesIMessageMode() {
        #expect(
            SettingsSearchIndex.anchorID(forSettingsPath: "app.iMessageMode")
                == SettingsSearchIndex.settingID(for: .app, idSuffix: "imessage-mode")
        )
    }

    @Test func settingsPathAnchorIncludesClickablePullRequests() {
        #expect(
            SettingsSearchIndex.anchorID(forSettingsPath: "sidebar.makePullRequestsClickable")
                == SettingsSearchIndex.settingID(for: .sidebarAppearance, idSuffix: "make-pr-clickable")
        )
    }

    @Test func settingsPathAnchorIncludesShortcutBindings() {
        #expect(
            SettingsSearchIndex.anchorID(forSettingsPath: "shortcuts.bindings")
                == SettingsSearchIndex.settingID(for: .keyboardShortcuts, idSuffix: "shortcuts")
        )
    }

    private func assertSearch(_ query: String, contains expectedID: String) {
        let resultIDs = Set(SettingsSearchIndex.entries(matching: query).map(\.id))
        #expect(
            resultIDs.contains(expectedID),
            "Expected settings search for '\(query)' to include \(expectedID), got \(resultIDs.sorted())"
        )
    }
}
