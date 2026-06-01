# All settings keys

Auto-generated from `web/data/cmux.schema.json`. For the rendered docs, see `https://cmux.com/docs/configuration`.

## app

General app preferences from Settings > App.

| Key | Type | Default | Description |
|---|---|---|---|
| `app.language` | `"system"` or `"en"` or `"ar"` or `"bs"` or `"zh-Hans"` or `"zh-Hant"` or `"da"` or `"de"` or `"es"` or `"fr"` or `"it"` or `"ja"` or `"ko"` or `"nb"` or `"pl"` or `"pt-BR"` or `"ru"` or `"th"` or `"tr"` | `"system"` | Preferred app language. |
| `app.appearance` | `"system"` or `"light"` or `"dark"` | `"system"` | App appearance mode. |
| `app.appIcon` | `"automatic"` or `"light"` or `"dark"` | `"automatic"` | Dock and app switcher icon style. |
| `app.menuBarOnly` | boolean | `false` | Hide the Dock icon and app switcher entry while keeping cmux available from the menu bar. |
| `app.newWorkspacePlacement` | `"top"` or `"afterCurrent"` or `"end"` | `"afterCurrent"` | Where new workspaces are inserted in the sidebar. |
| `app.workspaceInheritWorkingDirectory` | boolean | `true` | When true, new workspaces inherit the current workspace working directory. When false, new workspaces leave the working directory unset so Ghostty's working-directory setting can provide the default. |
| `app.minimalMode` | boolean | `false` | Hide the workspace title bar and move controls into the sidebar. |
| `app.keepWorkspaceOpenWhenClosingLastSurface` | boolean | `false` | When true, closing the last surface keeps the workspace open. |
| `app.focusPaneOnFirstClick` | boolean | `true` | When cmux is inactive, the first click can activate and focus the clicked pane. |
| `app.preferredEditor` | string | `""` | Custom editor command used when Cmd-click file previews are disabled or a file is unsupported. Leave empty to use the default. |
| `app.openSupportedFilesInCmux` | boolean | `true` | When enabled, Cmd-clicking readable local files opens supported previews in cmux, including text, code, PDFs, images, audio, video, and Quick Look files. Preview headers include an Open With menu based on the user's default and compatible macOS apps for that file. |
| `app.openMarkdownInCmuxViewer` | boolean | `true` | When enabled, Cmd-clicking .md/.markdown/.mkd/.mdx files opens the rendered cmux markdown viewer panel (with live reload) instead of the generic file preview. |
| `app.reorderOnNotification` | boolean | `true` | Move workspaces with new notifications toward the top. |
| `app.iMessageMode` | boolean | `false` | Move a workspace to the top and show the submitted message when sending an agent prompt. |
| `app.sendAnonymousTelemetry` | boolean | `true` | Allow anonymous telemetry. |
| `app.warnBeforeQuit` | boolean | `true` | Show a confirmation before quitting cmux. |
| `app.warnBeforeClosingTab` | boolean | `true` | Show a confirmation before closing a tab. |
| `app.renameSelectsExistingName` | boolean | `true` | Select the current name when opening rename flows. |
| `app.commandPaletteSearchesAllSurfaces` | boolean | `false` | Search every surface in the command palette switcher instead of only the active workspace. |

## terminal

Terminal presentation settings from Settings > Terminal.

| Key | Type | Default | Description |
|---|---|---|---|
| `terminal.showScrollBar` | boolean | `true` | Show the right-edge terminal scroll bar when scrollback is available. cmux automatically suppresses it for alternate-screen style TUI surfaces. |
| `terminal.autoResumeAgentSessions` | boolean | `true` | Automatically run agent resume commands for restored terminal sessions when cmux reopens after quit. Set false to restore panes while keeping Claude Code, Codex, OpenCode, and other saved agent sessions idle until you resume them manually. |

## notifications

Notification behavior from Settings > Notifications.

| Key | Type | Default | Description |
|---|---|---|---|
| `notifications.dockBadge` | boolean | `true` | Show the unread count in the Dock tile. |
| `notifications.showInMenuBar` | boolean | `true` | Show the menu bar extra. |
| `notifications.unreadPaneRing` | boolean | `true` | Highlight panes with unread notifications. |
| `notifications.paneFlash` | boolean | `true` | Flash the focused pane when requested. |
| `notifications.sound` | `"default"` or `"Basso"` or `"Blow"` or `"Bottle"` or `"Frog"` or `"Funk"` or `"Glass"` or `"Hero"` or `"Morse"` or `"Ping"` or `"Pop"` or `"Purr"` or `"Sosumi"` or `"Submarine"` or `"Tink"` or `"custom_file"` or `"none"` | `"default"` | Notification sound preset. |
| `notifications.customSoundFilePath` | string | `""` | Local path to the custom notification sound file. |
| `notifications.command` | string | `""` | Optional shell command to run alongside notification delivery. |
| `notifications.hooksMode` | `"append"` or `"replace"` | `"append"` | Controls whether project-local notification hooks append to inherited hooks or replace them. |
| `notifications.hooks` | array<object> | `[]` | Composable shell hooks that receive notification policy JSON on stdin and return updated policy JSON on stdout. |

## sidebar

Sidebar content and metadata visibility from Settings > Sidebar.

| Key | Type | Default | Description |
|---|---|---|---|
| `sidebar.hideAllDetails` | boolean | `false` | Hide all per-workspace detail rows. |
| `sidebar.showWorkspaceDescription` | boolean | `true` | Show custom workspace descriptions in the sidebar. |
| `sidebar.branchLayout` | `"vertical"` or `"inline"` | `"vertical"` | Show git branch details stacked vertically or inline. |
| `sidebar.showNotificationMessage` | boolean | `true` | Show the latest notification text in the sidebar. |
| `sidebar.showBranchDirectory` | boolean | `true` | Show the workspace working directory. |
| `sidebar.showPullRequests` | boolean | `true` | Show pull request metadata in the sidebar. |
| `sidebar.makePullRequestsClickable` | boolean | `true` | Allow sidebar pull request metadata to open links when clicked. |
| `sidebar.openPullRequestLinksInCmuxBrowser` | boolean | `true` | Open sidebar pull request links in the embedded cmux browser. |
| `sidebar.openPortLinksInCmuxBrowser` | boolean | `true` | Open sidebar port links in the embedded cmux browser. |
| `sidebar.showSSH` | boolean | `true` | Show SSH connection details. |
| `sidebar.showPorts` | boolean | `true` | Show listening ports. |
| `sidebar.showLog` | boolean | `true` | Show recent log snippets. |
| `sidebar.showProgress` | boolean | `true` | Show progress indicators. |
| `sidebar.showCustomMetadata` | boolean | `true` | Show custom metadata pills. |

## workspaceColors

Workspace tab and badge colors from Settings > Workspace Colors.

| Key | Type | Default | Description |
|---|---|---|---|
| `workspaceColors.indicatorStyle` | `"leftRail"` or `"solidFill"` or `"rail"` or `"border"` or `"wash"` or `"lift"` or `"typography"` or `"washRail"` or `"blueWashColorRail"` | `"leftRail"` | Active workspace indicator style. Legacy aliases are accepted and normalized. |
| `workspaceColors.selectionColor` | colorHexOrNull | `null` | Override the selected workspace background color. |
| `workspaceColors.notificationBadgeColor` | colorHexOrNull | `null` | Override the unread notification badge color. |
| `workspaceColors.colors` | object | `{"Red": "#C0392B", "Crimson": "#922B21", "Orange": "#A04000", "Amber": "#7D6608", "Olive": "#4A5C18", "Green": "#196F3D", "Teal": "#006B6B", "Aqua": "#0E6B8C", "Blue": "#1565C0", "Navy": "#1A5276", "Indigo": "#283593", "Purple": "#6A1B9A", "Magenta": "#AD1457", "Rose": "#880E4F", "Brown": "#7B3F00", "Charcoal": "#3E4B5E"}` | Full named workspace color palette. Include built-in entries you want to keep, remove keys to remove colors, and add more named entries to extend the picker. |
| `workspaceColors.paletteOverrides` | object | `{}` | Legacy workspace color overrides for built-in palette names. Prefer workspaceColors.colors for new configs. |
| `workspaceColors.customColors` | array<colorHex> | `[]` | Legacy list of custom workspace colors. Prefer workspaceColors.colors for new configs. |

## sidebarAppearance

Sidebar tint settings from Settings > Sidebar Appearance.

| Key | Type | Default | Description |
|---|---|---|---|
| `sidebarAppearance.matchTerminalBackground` | boolean | `false` | Use the terminal background instead of the sidebar tint. |
| `sidebarAppearance.tintColor` | colorHex | `"#000000"` | Base sidebar tint color used when light/dark overrides are not set. |
| `sidebarAppearance.lightModeTintColor` | colorHexOrNull | `null` | Sidebar tint override for light appearance. |
| `sidebarAppearance.darkModeTintColor` | colorHexOrNull | `null` | Sidebar tint override for dark appearance. |
| `sidebarAppearance.tintOpacity` | number | `0.03` | Sidebar tint opacity from 0 to 1. Note: this only controls the sidebar tint, not terminal/window transparency. For terminal background transparency or blur, set `background-opacity` and `background-blur` in `~/.config/ghostty/config` and run `cmux reload-config`. |

## automation

Socket control and automation settings from Settings > Automation.

| Key | Type | Default | Description |
|---|---|---|---|
| `automation.socketControlMode` | `"off"` or `"cmuxOnly"` or `"automation"` or `"password"` or `"allowAll"` or `"openAccess"` or `"fullOpenAccess"` or `"notifications"` or `"full"` | `"cmuxOnly"` | Socket control mode. Legacy aliases are accepted and normalized. |
| `automation.socketPassword` | string or null | `""` | Password for password-mode socket access. Use null or an empty string to clear it. |
| `automation.claudeCodeIntegration` | boolean | `true` | Enable cmux integration hooks for Claude Code. |
| `automation.claudeBinaryPath` | string | `""` | Custom path to the claude binary. |
| `automation.cursorIntegration` | boolean | `true` | Enable cmux integration hooks for Cursor. |
| `automation.geminiIntegration` | boolean | `true` | Enable cmux integration hooks for Gemini. |
| `automation.portBase` | integer | `9100` | Starting value for workspace CMUX_PORT assignments. |
| `automation.portRange` | integer | `10` | Number of ports reserved per workspace. |

## browser

Embedded browser settings from Settings > Browser.

| Key | Type | Default | Description |
|---|---|---|---|
| `browser.defaultSearchEngine` | `"google"` or `"duckduckgo"` or `"bing"` or `"kagi"` or `"startpage"` | `"google"` | Default search engine for non-URL queries. |
| `browser.showSearchSuggestions` | boolean | `true` | Show omnibar search suggestions. |
| `browser.theme` | `"system"` or `"light"` or `"dark"` | `"system"` | Embedded browser theme. |
| `browser.openTerminalLinksInCmuxBrowser` | boolean | `true` | Open clicked terminal links in the embedded browser. |
| `browser.interceptTerminalOpenCommandInCmuxBrowser` | boolean | `true` | Intercept terminal open http(s) commands and route them through the embedded browser. |
| `browser.hostsToOpenInEmbeddedBrowser` | array<string> | `[]` | Allowlist of hosts that should stay inside the embedded browser. |
| `browser.urlsToAlwaysOpenExternally` | array<string> | `[]` | Rules that always open matching URLs in the system browser. |
| `browser.insecureHttpHostsAllowedInEmbeddedBrowser` | array<string> | `["localhost", "*.localhost", "127.0.0.1", "::1", "0.0.0.0", "*.localtest.me"]` | HTTP hosts allowed in the embedded browser without a warning prompt. |
| `browser.showImportHintOnBlankTabs` | boolean | `true` | Show the browser import hint on blank tabs. |
| `browser.reactGrabVersion` | string | `"0.1.29"` | Pinned react-grab version for the browser toolbar helper. |

## shortcuts

Keyboard shortcut settings from Settings > Keyboard Shortcuts.

| Key | Type | Default | Description |
|---|---|---|---|
| `shortcuts.bindings` | object | `{}` | Shortcut overrides keyed by cmux action id. Use a string for a single shortcut, an array for a chord, null, an empty string, none, clear, unbound, or disabled to unbind. |
