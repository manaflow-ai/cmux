# All settings keys

Hand-maintained from `web/data/cmux.schema.json` and known to lag it. The schema is
authoritative; `cmux-settings list-supported` enumerates what the helper accepts. For the
rendered docs, see `https://cmux.com/docs/configuration`.

## app

General app preferences from Settings > App.

| Key | Type | Default | Description |
|---|---|---|---|
| `app.language` | `"system"` or `"en"` or `"ar"` or `"bs"` or `"zh-Hans"` or `"zh-Hant"` or `"da"` or `"de"` or `"es"` or `"fr"` or `"it"` or `"ja"` or `"ko"` or `"nb"` or `"pl"` or `"pt-BR"` or `"ru"` or `"th"` or `"tr"` | `"system"` | Preferred app language. |
| `app.appearance` | `"system"` or `"light"` or `"dark"` | `"system"` | App appearance mode. |
| `app.appIcon` | `"automatic"` or `"light"` or `"dark"` | `"automatic"` | Dock and app switcher icon style. |
| `app.menuBarOnly` | boolean | `false` | Hide the Dock icon and app switcher entry while keeping cmux available from the menu bar. |
| `app.newWorkspacePlacement` | `"top"` or `"afterCurrent"` or `"end"` | `"afterCurrent"` | Where new workspaces are inserted in the sidebar. |
| `app.workspaceInheritWorkingDirectory` | boolean | `true` | When true, new workspaces inherit the current workspace working directory. When false, new workspaces use Ghostty's working-directory setting instead. |
| `app.minimalMode` | boolean | `false` | Hide the workspace title bar and move controls into the sidebar. |
| `app.keepWorkspaceOpenWhenClosingLastSurface` | boolean | `false` | When true, closing the last surface keeps the workspace open. |
| `app.focusPaneOnFirstClick` | boolean | `true` | When cmux is inactive, the first click can activate and focus the clicked pane. |
| `app.preferredEditor` | string | `""` | Custom editor command used when Cmd-click file previews are disabled or a file is unsupported. Leave empty to use the default. |
| `app.defaultWorkspacePath` | string | `""` | Folder the Open Folder panel starts in, for example ~/code. Supports a leading ~. Leave empty to start in the active workspace's directory. |
| `app.openSupportedFilesInCmux` | boolean | `true` | When enabled, Cmd-clicking readable local files opens supported previews in cmux, including text, code, PDFs, images, audio, video, and Quick Look files. Preview headers include an Open With menu based on the user's default and compatible macOS apps for that file. |
| `app.openMarkdownInCmuxViewer` | boolean | `true` | When enabled, Cmd-clicking .md/.markdown/.mkd/.mdx files opens the rendered cmux markdown viewer panel (with live reload) instead of the generic file preview. |
| `app.devWindowDisplay` | string | `""` | DEBUG-only display name used when opening new windows. An empty value uses the system default. |
| `app.reorderOnNotification` | boolean | `true` | Move workspaces with new notifications toward the top. |
| `app.iMessageMode` | boolean | `false` | Move a workspace to the top and show the submitted message when sending an agent prompt. |
| `app.sendAnonymousTelemetry` | boolean | `true` | Allow anonymous telemetry. |
| `app.warnBeforeQuit` | boolean | `true` | Show a confirmation before quitting cmux. |
| `app.warnBeforeClosingTab` | boolean | `true` | Show a confirmation before closing a tab. |
| `app.renameSelectsExistingName` | boolean | `true` | Select the current name when opening rename flows. |
| `app.commandPaletteSearchesAllSurfaces` | boolean | `false` | Search every surface in the command palette switcher instead of only the active workspace. |
| `app.windowTitleTemplate` | string | `""` | Optional NSWindow title template. Blank preserves cmux's existing default title behavior, including the current-directory fallback. Supported placeholders: {windowId}, {windowToken}, {activeWorkspace}, {activeDirectory}, {defaultTitle}, {appName}. |
| `app.forkConversationDefaultDestination` | `"right"` or `"left"` or `"top"` or `"bottom"` or `"newTab"` or `"newWorkspace"` | `"right"` | Default destination for the tab context menu's primary Fork Conversation action. The submenu still exposes every destination. |
| `app.paneResizeStepPixels` | integer | `20` | Pixels moved per keypress when using pane-resize shortcuts. |
| `app.focusHistoryIncludesPanesAndTabs` | boolean | `false` | When true, Back and Forward include focus changes between panes and tabs. When false, they navigate between workspaces only. |
| `app.globalFontMagnification` | integer | `100` | Scales cmux-owned terminals, tab titles, sidebars, settings, overlays, and app chrome by this percentage. Rendered browser page content is excluded. |
| `app.confirmQuit` | `"always"` or `"dirty-only"` or `"never"` | `"always"` | Control when cmux asks for confirmation before quitting. DEV builds always quit immediately regardless of this setting. Legacy app.warnBeforeQuit is still accepted as a boolean fallback. |
| `app.warnBeforeClosingTabXButton` | boolean | `false` | Show a confirmation before closing a tab with the tab close button. |
| `app.hideTabCloseButton` | boolean | `false` | Hide tab close buttons in the pane tab bar. |

## terminal

Terminal presentation settings from Settings > Terminal.

| Key | Type | Default | Description |
|---|---|---|---|
| `terminal.showScrollBar` | boolean | `true` | Show the right-edge terminal scroll bar when scrollback is available. cmux automatically suppresses it for alternate-screen style TUI surfaces. |
| `terminal.autoResumeAgentSessions` | boolean | `true` | Automatically run agent resume commands for restored terminal sessions when cmux reopens after quit. Set false to restore panes while keeping Claude Code, Codex, OpenCode, and other saved agent sessions idle until you resume them manually. |
| `terminal.adaptiveDefaultTheme` | boolean | `true` | When true (the default), cmux supplies an appearance-adaptive default palette unless a Ghostty theme or terminal colors are configured. Font and other settings are preserved. When false, Ghostty uses its fixed built-in palette. Explicit themes and colors always take precedence, including theme = light:X,dark:Y. |
| `terminal.scrollSpeed` | number | `1.0` | Multiplier applied to terminal scroll wheel and trackpad deltas. Higher values scroll faster; lower values scroll slower. |
| `terminal.sessionContentMaxWidth` | boolean or number | `false` | Optional maximum width, in points, for terminal and built-in agent chat content. Set false to use the full pane width. |
| `terminal.sessionContentAlignment` | `"left"` or `"center"` or `"right"` | `"center"` | Horizontal placement for terminal and built-in agent chat content when sessionContentMaxWidth is enabled. |
| `terminal.copyOnSelect` | boolean | `false` | When true, copy selected terminal text to the system clipboard when the selection is committed. When false, cmux does not emit a Ghostty copy-on-select override; Ghostty config and defaults control selection-clipboard behavior. |
| `terminal.showTextBoxOnNewTerminals` | boolean | `false` | Show the beta TextBox input by default for newly created workspaces, terminal tabs, and terminal splits. |
| `terminal.focusTextBoxOnNewTerminals` | boolean | `false` | Focus the beta TextBox input by default for newly created workspaces, terminal tabs, and terminal splits. Focusing also shows the TextBox. |
| `terminal.agentHibernation` | object | — | Routine Agent Hibernation settings. cmux kills idle background agent processes to free RAM and CPU, then resumes them with their saved session when their tab is visited. Routine hibernation requires a restorable coding agent whose lifecycle reports idle, an off-screen terminal, a live-terminal count above the configured limit, and unchanged output through the idle and confirmation windows. Independently, during critical memory pressure cmux may hibernate a bounded batch of safe idle background agents even when enabled is false; visible, running, needs-input, recently changed, and unprotectable agents remain excluded. The placeholder Resume button is a manual fallback. |
| `terminal.rendererRealization` | object | — | Reclaim off-screen terminal GPU renderer memory. cmux releases the Metal renderer (IOSurface) of a terminal that has stayed off-screen and idle while keeping its process and terminal state alive, then rebuilds the renderer instantly when the tab is visited again. Non-destructive and on by default. |
| `terminal.textBoxMaxLines` | integer | `10` | Maximum number of lines the rich terminal TextBox input can grow to before it scrolls. |
| `terminal.textBoxDefaultSubmitAction` | string | `"text-entry"` | Default TextBox submit action ID for new terminal sessions. Use text-entry for plain input or one of the configured action IDs. |
| `terminal.textBoxSubmitActions` | array<object> | `[]` | Configurable TextBox submit actions shown on the submit button, Shift-Tab cycle, and right-click menu. |
| `terminal.resumeCommands` | array<object> | `[]` | Signed command-prefix approvals for restoring non-agent terminal surfaces. cmux writes this list when you approve a surface resume command. |
| `terminal.uploadCommands` | array<object> | `[]` | Host-scoped rules that replace the built-in scp for terminal file drops and pastes over SSH. When the ssh destination matches a rule, cmux runs that rule's command once per file instead of scp, and inserts the command's stdout at the cursor (verbatim, with control characters stripped); if the command prints nothing, cmux inserts the shell-escaped remote path it chose instead. Per-file outputs are space-joined. First matching enabled rule wins; no match runs the built-in scp unchanged. A non-zero exit, timeout, or cancel inserts nothing. |

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
| `notifications.paneFlashColor` | string or null | `null` | Override the pane flash and unread ring color. Null keeps the built-in blue. |
| `notifications.suppressOnlyFocusedSurface` | boolean | `false` | When enabled, a notification banner is auto-withdrawn only when its surface is the exact focused surface. A banner delivered for a non-focused surface in the currently visible workspace stays up until you focus that surface (or click/dismiss it), instead of being retracted when the workspace becomes visible. Off preserves the legacy workspace-visibility withdraw. |
| `notifications.suppressWhenAppFocused` | boolean | `false` | When enabled, cmux skips the desktop banner and phone push for every notification while cmux is the active app, not only for the focused pane. Notifications still appear in the sidebar, and the sound and custom command still run. Off keeps showing banners for other workspaces and panes while cmux is focused. |
| `notifications.agentPermissionPrompt` | boolean | `true` | Notify when an agent (e.g. Claude Code) is blocked waiting for your permission to run a tool. On by default, since this is the alert you must act on to unblock the agent. |
| `notifications.agentTurnComplete` | `"whenIdle"` or `"always"` or `"never"` | `"whenIdle"` | When to notify that an agent finished a turn. whenIdle (default) suppresses the notification while the agent still has a running background task or a pending scheduled wakeup, so you are pinged once work truly drains. always notifies on every turn end; never disables it. |
| `notifications.agentIdleReminder` | boolean | `true` | Notify when an agent has been idle waiting for your input (about 60s after a turn ends). Suppressed while background work from the last turn is still pending, so a running build or watcher does not trigger a false waiting alert. |
| `notifications.soundOverrides` | object | `{}` | Sparse per-agent and per-alert-type notification sound overrides. Missing cells use notifications.sound. |

## sidebar

Sidebar content and metadata visibility from Settings > Sidebar.

| Key | Type | Default | Description |
|---|---|---|---|
| `sidebar.hideAllDetails` | boolean | `false` | Hide all per-workspace detail rows. |
| `sidebar.showWorkspaceDescription` | boolean | `true` | Show custom workspace descriptions in the sidebar. |
| `sidebar.workspaceDescriptionColor` | colorHexOrNull | `null` | Override the workspace description text color in the sidebar. |
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
| `sidebar.wrapWorkspaceTitles` | boolean | `false` | Allow workspace titles in the sidebar to wrap to multiple lines instead of truncating after one line. |
| `sidebar.beta` | object | — | Experimental sidebar features. |
| `sidebar.notificationMessageLineLimit` | integer | `12` | Maximum lines shown for the latest notification below each workspace title. |
| `sidebar.watchGitStatus` | boolean | `true` | Watch repository files for sidebar branch and pull request metadata without polling git. |
| `sidebar.showAgentActivity` | boolean | `true` | Show the loading spinner on workspaces with running coding agents or active loaders. |
| `sidebar.loadingSpinnerPosition` | `"leading"` or `"trailing"` | `"leading"` | Which side of the workspace row the loading spinner appears on: leading (left, sharing the unread-badge slot) or trailing (right). |
| `sidebar.notificationBadgePosition` | `"leading"` or `"trailing"` | `"leading"` | Which side of the workspace row the unread notification badge appears on: leading (left) or trailing (right). |
| `sidebar.rightMaxWidth` | number | — | Maximum width in points for the right sidebar. When omitted, the built-in dynamic cap applies. |

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
| `automation.workspaceAutoNaming` | boolean | `false` | Opt-in AI auto-naming of workspaces and tabs from agent conversation content. When enabled, cmux summarizes supported agent sessions into short titles using each agent's own binary; manual renames always win. |
| `automation.autoNamingAgent` | string | `"auto"` | Which agent generates auto-names for every session. "auto" (default) names each session with its own agent; any agent slug (claude, codex, grok, opencode, pi, omp, …) overrides naming for all sessions, even other agents' sessions. Undriveable or uninstalled agents fall back to the session's own agent, so naming never breaks. |
| `automation.ripgrepBinaryPath` | string | `""` | Custom path to the ripgrep (rg) binary used by project search. |
| `automation.suppressSubagentNotifications` | boolean | `true` | Suppress visible completion notifications and status mutations from nested Codex or Claude child agents while keeping their events in Feed telemetry. |
| `automation.ampIntegration` | boolean | `true` | Enable cmux integration hooks for Amp. When disabled, the bundled plugin stays inactive without needing to be removed. |
| `automation.kiroIntegration` | boolean | `true` | Enable cmux integration hooks for Kiro CLI. |
| `automation.kiroNotificationLevel` | `"minimal"` or `"standard"` or `"verbose"` | `"standard"` | Controls how many Kiro tool events appear in Feed. |

## browser

Embedded browser settings from Settings > Browser.

| Key | Type | Default | Description |
|---|---|---|---|
| `browser.defaultSearchEngine` | `"google"` or `"duckduckgo"` or `"bing"` or `"kagi"` or `"startpage"` | `"google"` | Default search engine for non-URL queries. |
| `browser.showSearchSuggestions` | boolean | `true` | Show omnibar search suggestions. |
| `browser.theme` | `"system"` or `"light"` or `"dark"` | `"system"` | Embedded browser theme. |
| `browser.defaultZoomLevel` | number | `1` | Default page zoom factor for newly opened browser pages (0.25–5; 1 = 100%). |
| `browser.openTerminalLinksInCmuxBrowser` | boolean | `true` | Open clicked terminal links in the embedded browser. |
| `browser.interceptTerminalOpenCommandInCmuxBrowser` | boolean | `true` | Intercept terminal open http(s) commands and route them through the embedded browser. |
| `browser.hostsToOpenInEmbeddedBrowser` | array<string> | `[]` | Allowlist of hosts that should stay inside the embedded browser. |
| `browser.urlsToAlwaysOpenExternally` | array<string> | `[]` | Rules that always open matching URLs in the system browser. |
| `browser.insecureHttpHostsAllowedInEmbeddedBrowser` | array<string> | `["localhost", "*.localhost", "127.0.0.1", "::1", "0.0.0.0", "*.localtest.me"]` | HTTP hosts allowed in the embedded browser without a warning prompt. |
| `browser.showImportHintOnBlankTabs` | boolean | `true` | Show the browser import hint on blank tabs. |
| `browser.reactGrabVersion` | string | `"0.1.29"` | Pinned react-grab version for the browser toolbar helper. |
| `browser.customSearchEngineName` | string | `""` | Display name used when defaultSearchEngine is custom. |
| `browser.customSearchEngineURLTemplate` | string | `"https://www.google.com/search?q={query}"` | Search URL used when defaultSearchEngine is custom. Include {query} or %s for the encoded query. If omitted, cmux appends q= to the URL. |
| `browser.discardHiddenWebViews` | boolean | `true` | Allow hidden browser tabs to release page memory and restore when shown again. |
| `browser.hiddenWebViewDiscardDelaySeconds` | number | `300` | Seconds a browser tab must stay hidden before cmux frees its page memory. |
| `browser.askWhereToSaveDownloads` | boolean | `false` | Show a save panel for browser downloads instead of saving directly to Downloads. |
| `browser.urlAllowlist` | array<string> | `["localhost", "*.localhost", "127.0.0.1", "::1", "0.0.0.0", "*.localtest.me"]` | Host or URL patterns that restrict embedded-browser navigation. The Settings UI suggests local development origins; saving a list opts into the optional restriction. Remove entries to block them, or leave the user value empty to disable it when no managed policy applies. |

## shortcuts

Keyboard shortcut settings from Settings > Keyboard Shortcuts.

| Key | Type | Default | Description |
|---|---|---|---|
| `shortcuts.bindings` | object | `{}` | Shortcut overrides keyed by cmux action id. Use a string for a single shortcut, an array for a chord, null, an empty string, none, clear, unbound, or disabled to unbind. |
| `shortcuts.showModifierHoldHints` | boolean | `true` | Show shortcut-hint chips while holding Cmd or Control. |
| `shortcuts.when` | object | `{}` | Optional per-action context predicates (VS Code-style `when` clauses), keyed by cmux action id. Each value is a boolean expression over context keys combined with !, &&, \|\|, and parentheses. Boolean keys: sidebarFocus, browserFocus, markdownFocus, filePreviewTextEditorFocus, simulatorFocus, terminalFocus, commandPaletteVisible, terminalFindVisible, workspaceCanvasLayout. Typed keys support comparisons: the string sidebarMode (files, find, sessions, feed, or dock) and the integers paneCount and workspaceCount. Comparison operators are ==, !=, =~ (regex), <, <=, >, >=, and `in [a, b]`; an unknown or absent key reads as false. The boolean literals true and false are also accepted; `key == false` is the same as `!key`. The action's shortcut only fires (and only conflicts with other shortcuts) when the clause holds. Examples: { "selectWorkspaceByNumber": "!sidebarFocus" } selects workspaces with Ctrl+1–9 everywhere except when the right sidebar is focused; { "selectSurfaceByNumber": "sidebarMode == 'find' && paneCount > 1" } scopes a binding to the Find sidebar when the workspace has multiple panes. |
