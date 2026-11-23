# cmux managed preferences

Generated from the cmux settings catalog by `ManagedPreferencesManifest` (CmuxNextSettings). Do not edit by hand; run `CMUX_UPDATE_MDM_SCHEMA=1 swift test --filter ManagedPreferencesManifestTests` in `Packages/macOS/CmuxNext`.

Domain: `com.manaflow.cmux` for every channel (stable, NIGHTLY, DEV). A forced value (any MDM custom settings payload) locks the setting and Settings shows "Managed by your organization". A non-forced value replaces the default and the user can still change it. Precedence, highest first: MDM forced, team policy enforced, the user's cmux.json, MDM non-forced, team policy default, product default.

Chat privacy exceptions: `agents.chats.roots` is the union of user roots and roots added by managed or team layers, deduplicated in layer order. Managed roots are locked rows, but users may still edit their own roots. `agents.chats.enabled` and `agents.chats.discovery` default to true; a forced false from either MDM or team policy turns them off, while a forced true never overrides a user false. Recommended booleans only supply missing user values. All three keys refuse agent writes (`privacy`). Managed chat roots and forced-off values are enforced while the cmux app runs; the acpmux daemon keeps the last values the app sent in its own `chat-settings.json`, so a daemon started without the app uses those values.

Chat roots must be absolute harness data folders. The root folder, home folder, Desktop, Documents, Downloads, Pictures, Music, Movies, Library/Mobile Documents, Library/CloudStorage, Library/Containers, Library/Group Containers, Library/Mail, Library/Messages, Library/Safari, Library/Calendars and their descendants are refused, as are /Volumes, /Network and /net. Checks are case-insensitive and include symbolic links. Refused roots remain visible with a reason, but are never read or sent to the daemon. The protected list mirrors acpmux protected_folders.rs.

The legacy forced keys `DisableAutoUpdate` and `DisableTelemetry` in `com.cmuxterm.app` keep working.

Files: `com.manaflow.cmux.plist` (ProfileManifests: iMazing Profile Editor, ProfileCreator), `com.manaflow.cmux.json` (Jamf Pro custom schema), `cmux-example.mobileconfig` (any MDM), `com.manaflow.cmux.intune.plist` (Intune preference file).

| Key | Type | Default | Allowed values | Description |
| --- | --- | --- | --- | --- |
| `app.language` | string | `"system"` | `system`, `en`, `ar`, `bs`, `da`, `de`, `es`, `fr`, `it`, `nb`, `pl`, `pt-BR`, `tr`, `vi`, `ru`, `uk`, `th`, `km`, `ja`, `ko`, `zh-Hans`, `zh-Hant` | Language. The language of cmux's menus, pages and messages. |
| `history.terminalCommands` | boolean | `false` |  | Record Terminal Commands. Lists finished shell commands in History. Command lines can contain secrets. |
| `navigation.historyScope` | string | `"workspace"` | `workspace`, `window`, `surface` | Back and Forward. What Go Back and Go Forward walk. |
| `navigation.history.scope` | string | `"workspaces"` | `workspaces`, `everything` | Back and Forward Steps. Everything also steps through tabs and panes inside a workspace. |
| `history.commandRetentionDays` | real | `30` | 1 to 3650 | Keep Terminal Commands For. Each machine deletes recorded commands that are older. |
| `history.closed.maxGroups` | real | `0` | 0 to 10000 | Recently Closed Items to Keep. Older closed tabs, workspaces and windows are deleted. 0 keeps them all. |
| `history.closed.maxAgeDays` | real | `0` | 0 to 3650 | Keep Recently Closed Items For. Each machine deletes closed items that are older. 0 keeps them however old they are. |
| `window.titlebar` | string | `"minimal"` | `minimal`, `standard` | Titlebar. Minimal has no titlebar strip; the top row moves the window. |
| `window.titlebarButtons` | string | `"hover"` | `hover`, `always` | Titlebar Buttons. With the sidebar hidden, On Hover shows its buttons only over the top row. |
| `app.globalHotKey` | boolean | `false` |  | Global Hot Key. Show/Hide All Windows (⌃⌥⌘.) works while another app is in front. |
| `app.startAgentGlobalHotKey` | boolean | `false` |  | Start Agent from Any App. ⌃⌥⌘Space starts an agent while another app is in front. |
| `app.hideDockIconWithoutWindows` | boolean | `false` |  | Hide Dock Icon When No Windows Are Open. cmux stays in the menu bar until a window opens. |
| `app.showMenuBarIcon` | boolean | `true` |  | Show Menu Bar Icon |
| `tabs.newTabTemplate` | string | `"minimal"` | `minimal`, `classic`, `terminal` | New Tab Template. The layout of the New Tab page. Terminal opens a terminal instead. |
| `tabs.nativeNewTabPage` | boolean | `false` |  | Native New Tab Page. Cmd-T opens the faster native New Tab page. Recent chats and widgets are web only. |
| `tabs.newTabApp` | string |  |  | New Tab App. An extension that draws over the New Tab composer, by its id, such as "local/showcase-newtab". The composer always stays. Not used by the native New Tab page. |
| `tabs.newTabPosition` | string | `"afterCurrent"` | `afterCurrent`, `end`, `start` | New Tab Position (Cmd-T) |
| `tabs.newTabButtonPosition` | string | `"end"` | `afterCurrent`, `end`, `start` | New Tab Position (+ Button) |
| `tabs.plusButton` | string | `"hover"` | `hover`, `always` | + Button Visibility. Applies in Minimal Mode; otherwise the + always shows. |
| `tabs.barPosition` | string | `"top"` | `top`, `bottom` | Tab Bar Position |
| `browser.toolbarPosition` | string | `"top"` | `top`, `bottom` | Browser Toolbar Position. Where the address bar of browser and Markdown panes sits. |
| `tabs.barOrder` | string | `"aboveToolbar"` | `aboveToolbar`, `belowToolbar` | Tab Bar and Browser Toolbar. Whether the tab bar sits above or below the address bar. |
| `tabs.toolbarButtons` | array | `[]` | `splitRight`, `splitDown`, `openDiffViewer`, `file.open`, `agentPane.searchChats`, `toggleSplitZoom` | Tab Bar Buttons. The rest are in the More menu. |
| `appearance.metrics.tabFontSize` | real |  | 10 to 18 | Tab Text Size. Text size of tab titles. Unset, tabs follow the interface size. |
| `appearance.metrics.tabStripHeight` | real |  | 22 to 44 | Tab Bar Height. Height of a pane's tab bar. Its tabs grow and shrink with it. |
| `tabs.overflow` | string | `"shrink"` | `shrink`, `scroll` | Tab Overflow. Shrink narrows tabs before scrolling; Scroll keeps them wide. |
| `tabs.shellIconTheme` | string | `"default"` | `default`, `machine` | Shell Tab Icons. Machines shows each shell tab with the icon of the machine it runs on. |
| `appearance.metrics.tabMaxWidth` | real |  | 120 to 320 | Maximum Tab Width. Widest a tab gets when the strip has room. |
| `appearance.metrics.tabMinActiveWidth` | real |  | 32 to 320 | Minimum Selected Tab Width. The selected tab stays at least this wide when tabs shrink. |
| `appearance.metrics.tabMinInactiveWidth` | real |  | 16 to 320 | Minimum Tab Width. Narrowest the other tabs get before the strip scrolls. |
| `appearance.metrics.tabPinnedWidth` | real |  | 24 to 120 | Pinned Tab Width. Width of a pinned tab. |
| `newTerminal.opensWorkspace` | boolean | `false` |  | New Terminal Opens a Workspace. Hold Option to reverse it for one click. |
| `tabs.verticalTabs` | boolean | `false` |  | Use Vertical Tabs for All Workspaces. Tabs in a list beside the panes. A tab bar's menu changes one workspace. |
| `tabs.verticalTabsExpandOnHover` | boolean | `true` |  | Expand Collapsed Vertical Tabs on Hover. Show titles while the pointer is over the collapsed list. |
| `tabs.hideLoneChatTab` | boolean | `false` |  | Hide the Tab of a Chat Alone in Its Pane |
| `tabs.swapCmdTAndCmdN` | boolean | `false` |  | Swap Cmd-T and Cmd-N. Cmd-T opens a workspace and Cmd-N opens a tab. |
| `app.warnBeforeClosingTab` | boolean | `true` |  | Warn Before Closing a Running Program |
| `app.warnBeforeClosingAgentSession` | boolean | `true` |  | Warn Before Closing a Working Agent |
| `app.quitBehavior` | string | `"keep"` | `keep`, `end-keep-layout`, `end-everything` | When Quitting. Terminals run in cmux-tui and keep running after cmux quits unless you end them. |
| `app.confirmQuit` | boolean | `true` |  | Ask Before Quitting Ends Agents or Terminals. Ask before Cmd-Q ends agents or terminals. |
| `layout.defaultColumnWidth` | real | `0.6666666666666666` | 0.1 to 1 | Fixed Column Width. A share of the window width, for Fixed Width new columns. |
| `layout.centerFocusedColumn` | string | `"never"` | `never`, `always`, `on-overflow` | Center Focused Column |
| `layout.stripScrollbar` | string | `"system"` | `system`, `auto`, `always`, `off` | Column Scroll Bar. A thin bar under the columns that shows and moves the visible range. |
| `layout.closeFocus` | string | `"mostRecent"` | `previousNeighbor`, `mostRecent` | Focus After Closing a Pane. Which pane gets focus when the focused pane closes. |
| `shortcuts.showModifierHoldHints` | boolean | `true` |  | Show Shortcuts When Holding a Modifier. Hold Command or Control for 0.30 seconds to show shortcut hints. |
| `updates.channel` | string | `"nightly"` | `stable`, `nightly`, `canary`, `dev` | Update Channel. Stable gets builds that ran a week without problems; Canary and Dev get them first. |
| `updates.checkAutomatically` | boolean | `true` |  | Check for Updates Automatically |
| `updates.checkIntervalSeconds` | real | `3600` | 900 to 604800 | Check Every |
| `updates.downloadAutomatically` | boolean | `true` |  | Download Updates Automatically. Off: cmux asks before downloading. It always asks before restarting. |
| `updates.oneClickInstall` | boolean | `false` |  | Update in One Click. One click on Update downloads, installs and restarts. Terminals and agents keep running. |
| `updates.whatsNewInstall` | boolean | `false` |  | Install Versions from What's New. An Install button for each version listed in What's New. |
| `updates.meteredNetwork` | string | `"defer-low-data"` | `defer-low-data`, `defer-expensive`, `download` | On Metered Networks. While downloads wait, a found update shows on Settings and one click downloads it. |
| `updates.web` | string | `"every-merge"` | `every-merge`, `nightly`, `off` | Web UI Updates. Every Merge gets web UI changes minutes after they land. |
| `updates.liveWebReload` | boolean | `true` |  | cmux Live. Lets cmux live start show your checkout's web UI, each saved edit at once. |
| `updates.installOnQuit` | boolean | `false` |  | Install Updates When Quitting. A downloaded update installs as cmux quits. Terminals keep running. |
| `updates.installWhenIdle` | boolean | `false` |  | Update When Idle. Installs a downloaded update after cmux has been idle for the time below, never while an agent is working or a message is unsent. Agents keep running. |
| `updates.installWhenIdleMinutes` | real | `15` | 1 to 240 | Idle Time Before Updating. How long cmux must be idle before Update When Idle installs. |
| `updates.notify` | string | `"badge"` | `badge`, `silent` | When an Update Is Ready |
| `updates.keepPreviousVersions` | real | `1` | 0 to 5 | Keep Previous Versions. Earlier builds kept so you can roll back. Uses almost no disk until files change. |
| `updates.showWhatsNew` | boolean | `true` |  | Show What's New After Updates. A sidebar card links to What's New after an update. |
| `updates.showFeatureTips` | boolean | `false` |  | Show Feature Tips. A small tip now and then points at a feature an update added. |
| `updates.idleInstallMaxWaitSeconds` | real | `600` | 60 to 7200 | Install Within. A nightly installs when you are idle, and never waits longer than this. |
| `updates.idleInstallQuietSeconds` | real | `60` | 5 to 600 | Quiet Time Before Installing. How long you must be idle before a nightly installs. |
| `announcements.enabled` | boolean | `true` |  | Show Announcements. Short cards from the cmux team above Settings, shown when the pointer is over the sidebar. |
| `announcements.fetch` | boolean | `true` |  | Download Announcements. Off: cmux never asks the network for announcements. The request carries no identifiers. |
| `computerUse.mode` | string | `"fullAccess"` | `fullAccess`, `approvedApps`, `askEveryTime`, `lookOnly`, `off` | Computer Use. What agents may do with the apps on this Mac. Denied apps are never used, in any mode. |
| `computerUse.deniedApps` | array | `["com.apple.keychainaccess","com.apple.Passwords","com.1password.*","com.agilebits.onepassword*","com.bitwarden.*","com.dashlane.*","com.lastpass.*","com.nordpass.*","me.proton.pass","org.keepassxc.keepassxc","com.markmcguill.strongbox","in.sinew.enpass*","com.keepersecurity.*","1password.exe","bitwarden.exe","keepass.exe","keepassxc.exe","org.keepassxc.KeePassXC","1password","bitwarden","com.apple.systempreferences","com.apple.Terminal","com.googlecode.iterm2","com.mitchellh.ghostty","net.kovidgoyal.kitty","com.github.wez.wezterm","org.alacritty","dev.warp.*","windowsterminal.exe","cmd.exe","powershell.exe","pwsh.exe","org.gnome.Terminal","org.gnome.Ptyxis","org.kde.konsole","com.cmuxterm.app","com.cmuxterm.app.*"]` |  | Denied Apps. Apps no agent may use, in any mode: an app ID, an ID prefix ending in *, or name: and the app's name. |
| `computerUse.allowOwnMachines` | boolean | `true` |  | Allow My Other Machines. Agents on your other machines, signed in to the same account, may use this Mac's apps. |
| `computerUse.pauseOnTakeover` | boolean | `true` |  | Pause When I Use the Mouse or Keyboard. While you use the mouse or keyboard, agents wait before their next click or key press. |
| `computerUse.showCursor` | boolean | `true` |  | Show Agent Cursor. A blue cursor shows wherever an agent clicks or types. |
| `computerUse.cursorTag` | string | `"hover"` | `hover`, `always`, `never` | Agent Cursor Tag. Each agent cursor can carry a tag: the agent's workspace name, or a tag the agent sets. Show it when your pointer is over the cursor, always, or never. |
| `computerUse.settle` | string | `"adaptive"` | `adaptive`, `anthropic`, `openai` | After Each Action. What an agent waits for after each click or key press before it looks again: the screen to stop changing, a fixed 2 seconds, or nothing. |
| `computerUse.livePreview` | boolean | `true` |  | Live Preview in Chat. A small live view of the app an agent uses. Click it for Agent Activity. |
| `computerUse.menus` | string | `"open"` | `open`, `refuse` | Menus in Background Apps. Agents may open pop-up and context menus of apps in the background to choose an item. Menu bar menus never open in the background. |
| `computerUse.allowForeground` | boolean | `false` |  | Allow Foreground Input. Advanced. Agents may bring an app to the front and move your pointer when it takes no background input. |
| `freeModel.enabled` | boolean | `true` |  | Free AI Model Without Sign-In. Agents can use the free cmux model while signed out. cmux checks this is a real Mac. |
| `sessions.keepAwake` | string | `"pluggedIn"` | `off`, `pluggedIn`, `always` | Keep Mac Awake While Agents Work. Stops idle sleep while an agent works. Closing the lid still sleeps the Mac. |
| `sessions.keepAwakeForCommands` | boolean | `false` |  | Also While Terminal Commands Run. A build or test running over a minute keeps the Mac awake. |
| `sessions.resumeAgents` | boolean | `true` |  | Resume Agents After Restart. Terminal agents reopen their session after a crash or restart. |
| `sessions.allowFullAccess` | boolean | `true` |  | Allow Full-Access Modes. Off, cmux won't switch an agent into a mode that skips approvals. |
| `sessions.promptSuggestions` | boolean | `true` |  | Suggest Follow-Up Tasks. Agents suggest next tasks you can start as child chats. |
| `agents.promptSuggestions` | boolean | `true` |  | Suggest Next Prompt. Suggests your next prompt in grey; Tab takes it. Each one is an extra model call. |
| `phone.keepAwake` | string | `"pluggedIn"` | `off`, `pluggedIn`, `always` | Keep Mac Awake for Your Phone. Closing the lid still puts the Mac to sleep. |
| `phone.cloudReplica` | boolean | `false` |  | Show This Mac's Workspaces on Your Phone While It's Off. Stores workspace names, colors and unread counts. No paths, titles or output. |
| `phone.cloudDesktop` | boolean | `false` |  | Show Your Cloud Machine's Screen on Your Phone. View only, streamed by this Mac while the page is open. |
| `appearance.machineColors` | dictionary | `{}` |  | Machine Color. By machine name: "#RRGGBB" or an accent name, such as red or blue. |
| `ssh.linkAllowedHosts` | array | `[]` |  | Always Allowed SSH Link Hosts. ssh:// links from other apps connect to these hosts without asking. |
| `cloud.newWorkspacesInCloud` | boolean | `false` |  | Run New Workspaces in Cloud. Each new workspace gets its own Cloud machine, and its chats run there. |
| `cloud.newWorkspaceFolder` | string | `"inherit"` | `inherit`, `empty` | New Cloud Workspaces Start In. Current Folder copies your git working copy to the new machine. |
| `cloud.agentsStartWithoutAsking` | boolean | `true` |  | Let Agents Use Cloud Without Asking. Agents, `cmux cloud` in a terminal and scripts create Cloud machines, move chats to Cloud and start sessions there with no card asking you first. Your plan's limits still apply. Only you can change this. |
| `cloud.turnCheckpoints` | boolean | `false` |  | Save a Checkpoint Before Each Cloud Chat Turn. Back to Before This Turn restores the machine in seconds. Keeps the newest few. |
| `agents.subsessions.enabled` | boolean | `true` |  | Let Agents Start Sub-sessions. Agents can start sessions that work in parallel, shown under theirs. |
| `agents.subsessions.answerQuestions` | boolean | `false` |  | Let Sessions Answer Their Sub-sessions' Questions. When an agent in a sub-session asks a question, the session that started it can answer, and the answer shows who gave it. Permission requests always wait for you. Off: only you answer. |
| `agents.subsessions.maxChildren` | real | `1000` | 1 to 1000 | Open Sub-sessions per Session. Finished and closed sub-sessions don't count. |
| `agents.subsessions.maxRunning` | real | `1000` | 1 to 1000 | Running Sub-sessions per Session. More wait their turn. Lowering it never stops running ones. |
| `agents.subsessions.maxDepth` | real | `10` | 1 to 100 | Deepest Nesting. 1 means sub-sessions cannot start their own. |
| `agents.guidance.claude` | boolean | `true` |  | cmux Guidance for Claude Code. Tells new Claude Code chats how cmux shows plans, side sessions and recaps. |
| `agents.guidance.codex` | boolean | `true` |  | cmux Guidance for Codex. Tells new Codex chats how cmux shows plans, side sessions and recaps. |
| `agents.guidance.otherAgents` | boolean | `true` |  | cmux Guidance for Other Agents. Gemini, OpenCode and agents you added get the same guidance. |
| `agents.guidance.userSkills` | boolean | `true` |  | Your Skills in Every Chat. Skills in ~/.config/cmux/skills (a folder with a SKILL.md each) reach every new chat. |
| `agents.mcpServers.enabled` | boolean | `true` |  | Saved Servers in Agent Chats. New chats can use the servers listed above. |
| `agents.autoRetry.enabled` | boolean | `true` |  | Retry Automatically. Retries after rate limits, capacity errors or a dropped connection. |
| `agents.autoRetry.intervalSeconds` | real | `0` | 0 to 3600 | Seconds Between Retries. 0 waits longer after each failed try. |
| `agents.autoRetry.attempts` | real | `4` | 1 to 12 | Retries per Error. How many times the chat tries again before it stops and waits for you. |
| `models.spreadUsage` | boolean | `true` |  | Spread Usage Across My Subscriptions. When one subscription runs out, a chat moves to another with the same model. |
| `agents.cacheCompact.enabled` | boolean | `false` |  | Compact Before the Cache Expires. Compacts an idle Claude chat while its cache is warm, so the next message costs less. |
| `agents.cacheCompact.minContextPercent` | real | `50` | 10 to 95 | Only Above Context Used (%). Chats using less of their context window than this are left as they are. |
| `agents.trust.autoTrust` | boolean | `false` |  | Trust My Own Folders Without Asking. Agents start in folders under your project roots, and in repositories owned by your organizations, without asking. Other folders ask first. |
| `agents.trust.projectRoots` | array | `[]` |  | Trusted Project Roots. Everything inside these folders is trusted. Use full paths or ~/ paths. |
| `agents.trust.ownOrgs` | array | `[]` |  | Trusted GitHub Owners. A repository is trusted when all of its GitHub remotes belong to these users or organizations. |
| `mobile.allowIPhoneConnections` | boolean | `false` |  | Allow iPhone Connections. The cmux app on your iPhone can open this Mac's workspaces, on the same account. |
| `mobile.terminalSizing` | string | `"smallest"` | `smallest`, `mac`, `latest`, `priority` | Terminal Size When Shared. The size of a terminal shown on this Mac and a phone at once. |
| `mobile.terminalSizingOrder` | array | `[]` |  | Terminal Size Priority. The devices a shared terminal sizes to first, highest first. |
| `layout.splitSizing` | string | `"even"` | `even`, `halve` | Split Sizing. Even gives every pane in the column the same size after a split. |
| `layout.newColumnWidth` | string | `"fixed"` | `matchCurrent`, `fitScreen`, `fixed` | New Column Sizing |
| `layout.dockColumnEdge` | string | `"nearest"` | `nearest`, `right`, `left`, `top`, `bottom` | Dock Column Edge |
| `layout.dockColumnMode` | string | `"docked"` | `docked`, `overlay` | Dock Column Mode |
| `layout.frameOrientation` | string | `"columnMajor"` | `columnMajor`, `rowMajor` | Dock Corners |
| `layout.rows` | boolean | `true` |  | Rows. Off hides New Row and fits a column's existing rows into it without scrolling. |
| `layout.focusFollowsMouse` | boolean | `false` |  | Focus Follows Mouse. Pointing at or scrolling over a pane focuses it. |
| `layout.scrollAreas` | boolean | `false` |  | Scroll Areas. Panes that do not fit scroll sideways instead of shrinking. |
| `layout.scrollModifier` | string | `"command"` | `command`, `none` | Scroll Columns and Rows With. What moves columns and rows: Command + Scroll, or a plain sideways scroll. |
| `layout.pagesHandleCommandScroll` | boolean | `true` |  | Web Pages Get Command + Scroll First. Pages like Figma keep Command + Scroll. Off, it always moves columns. |
| `layout.minimumPaneWidth` | real | `200` | 80 to 800 | Minimum Pane Width |
| `layout.minimumPaneHeight` | real | `64` | 32 to 600 | Minimum Pane Height |
| `layout.newPanePlacement` | string | `"tab"` | `tab`, `split` | New Terminals and Browsers. Split Automatically splits the largest pane. |
| `layout.tileBrowsers` | boolean | `false` |  | Split for Browsers Too. With Split Automatically, new browsers also get their own pane instead of a tab. |
| `layout.linkPlacement` | string | `"split-right"` | `split-right`, `new-column`, `same-pane` | Open Links and Files |
| `layout.mainPane` | string | `"agent-chats"` | `agent-chats`, `off` | Main Pane. Keeps a chat as the main pane, with what it opens in a column on its right. |
| `workspaces.newPlacement` | string | `"top"` | `top`, `afterCurrent`, `bottom` | New Workspace Position |
| `sidebar.groupByComputer` | boolean | `false` |  | Group Workspaces by Computer |
| `workspaces.autoName` | boolean | `true` |  | Name Workspaces from Tabs. An unnamed workspace shows its front tab's name. Your own name always wins. |
| `palette.scopes.tabs.prefix` | string | `"@"` | `@`, `#`, `>`, `,`, `?`, `!`, `/`, `;`, `:`, `%`, `&`, `+`, `=`, `~`, `$`, `^`, `*`, `.`, `none` | Tabs Prefix. Typed into an empty query, this character enters the scope. |
| `palette.scopes.workspaces.prefix` | string | `"#"` | `@`, `#`, `>`, `,`, `?`, `!`, `/`, `;`, `:`, `%`, `&`, `+`, `=`, `~`, `$`, `^`, `*`, `.`, `none` | Workspaces Prefix. Typed into an empty query, this character enters the scope. |
| `palette.scopes.commands.prefix` | string | `">"` | `@`, `#`, `>`, `,`, `?`, `!`, `/`, `;`, `:`, `%`, `&`, `+`, `=`, `~`, `$`, `^`, `*`, `.`, `none` | Commands Prefix. Typed into an empty query, this character enters the scope. |
| `palette.scopes.settings.prefix` | string | `","` | `@`, `#`, `>`, `,`, `?`, `!`, `/`, `;`, `:`, `%`, `&`, `+`, `=`, `~`, `$`, `^`, `*`, `.`, `none` | Settings Prefix. Typed into an empty query, this character enters the scope. |
| `palette.scopes.scopes.prefix` | string | `"?"` | `@`, `#`, `>`, `,`, `?`, `!`, `/`, `;`, `:`, `%`, `&`, `+`, `=`, `~`, `$`, `^`, `*`, `.`, `none` | Scope List Prefix. Typed into an empty query, this character enters the scope. |
| `palette.aliases` | dictionary | `{}` |  | Command Aliases. A word for a command, such as "vs": "splitRight". |
| `palette.pins` | array | `[]` |  | Pinned Commands. Commands shown first when the command palette opens, in this order, by action id. |
| `palette.searchHistory` | boolean | `true` |  | Remember Palette Searches. Rows you pick and use often rank higher. Off records nothing. |
| `agents.chats.enabled` | boolean | `true` |  | Enable Chats. Show chats stored on this device. Nothing is uploaded. |
| `agents.chats.discovery` | boolean | `true` |  | Discover Chat Folders. Find harness chat folders automatically. When off, only the listed folders are used. |
| `agents.chats.roots` | array | `[]` |  | Chat Folders. Folders agents may also use. |
| `agents.chats.sessionRecap` | boolean | `true` |  | Session Recap. A line on where a Claude chat stands when you come back. Each is a small model call. |
| `agents.chats.coldArchive` | boolean | `false` |  | Compress Old Chats. Unused chats are compressed into one small file each and open as before. |
| `agents.chats.coldArchiveAfterDays` | real | `30` | 1 to 3650 | Compress Chats Idle For. Days unused before a chat is compressed. Busy chats never are. |
| `agents.chats.archiveInactive` | string | `"never"` | `never`, `1d`, `3d`, `7d`, `30d` | Archive Inactive Chats. Archives chats after a period of no activity. Chats that are running or have background work never are. |
| `chat.on` | string | `""` |  | Default Chat Target. Where cmux chat starts a chat with no --on: here, cloud, vm:NAME or a device name. |
| `picker.pinned` | array | `[]` |  | Pinned Folders. Listed under Locations. Use full or ~/ paths. |
| `screenshots.findTools` | boolean | `true` |  | Find Screenshot Apps. Also shows the folders of apps like CleanShot X and Shottr. |
| `screenshots.folders` | array | `[]` |  | More Screenshot Folders. Also shows the pictures and videos in these folders. |
| `workspaces.autoArchive.style` | string | `"manual"` | `suggest`, `quiet`, `groups`, `manual`, `off` | Idle Workspaces. Archived workspaces stay dimmed in their group and come back when opened. |
| `workspaces.autoArchive.idleDays` | real | `3` | 1 to 365 | Idle For. Days unopened and unchanged. Pinned, running and waiting workspaces never archive. |
| `workspaces.hibernation.enabled` | boolean | `true` |  | Hibernate Idle Workspaces. Frees the memory of unused workspaces. Terminals and agents keep running. |
| `workspaces.hibernation.idleMinutes` | real | `60` | 5 to 10080 | Hibernate After. Minutes a workspace goes unopened and unchanged before it hibernates. |
| `workspaces.hibernation.hiddenSpaceMinutes` | real | `15` | 5 to 1440 | Hibernate Hidden Spaces After. Idle minutes before the workspaces of a space no window shows hibernate. |
| `workspaces.freeing.enabled` | boolean | `true` |  | Free Idle Terminals. Ends idle shells of long-unused workspaces; they restart in the same folder. |
| `workspaces.freeing.idleMinutes` | real | `1440` | 60 to 43200 | Free Terminals After. Minutes before a hibernated workspace's idle shells end (1440 is a day). |
| `workspaces.freeing.agents` | boolean | `true` |  | Free Idle Agents. Also ends idle Claude Code and Codex sessions; opening the tab resumes them. |
| `workspaces.freeing.runningCommands` | string | `"never"` | `never`, `relaunch` | Running Commands. What happens to a command that still runs in a workspace that frees its terminals. |
| `tasks.layout` | string | `"inbox"` | `list`, `board`, `inbox` | Tasks Layout. Inbox lists what needs you first, with the task beside it. Changes apply at once. |
| `appearance.iconTheme` | string | `"default"` | `default`, `neko` | Icon Theme. The icon drawings used by cmux. |
| `appearance.theme` | string |  |  | Theme. Colors for terminals. A space, workspace or terminal theme overrides it. |
| `appearance.appTheme` | string | `"followTerminal"` |  | App Theme. Colors for the window, sidebar, tabs and pages. Terminals use Terminal Theme. |
| `appearance.themeEdits` | dictionary | `{}` |  | Theme Edits. Your color changes to a theme, such as "Rose Pine/background": "#1f1d2e". |
| `appearance.favoriteThemes` | array | `[]` |  | Starred Themes. Themes starred in a theme picker. The picker lists them first. |
| `appearance.rotateFavoriteThemes` | string | `"off"` | `off`, `launch`, `daily` | Rotate Starred Themes. Switches the terminal theme to the next starred one. Needs two starred themes. |
| `appearance.accent` | string | `"neutral"` | `neutral`, `theme`, `art`, `red`, `green`, `yellow`, `blue`, `magenta`, `cyan` | Accent. The color of selection, focus and the Send button. |
| `appearance.selection` | string | `"accent"` | `accent`, `neutral` | Selection. Accent tints the selected row and tab with the accent. Neutral keeps them gray. |
| `appearance.themeFile` | string |  |  | Theme File. A theme file in ~/.config/cmux/themes, such as "tokyo" for tokyo.json. |
| `appearance.themeFileExceptions` | array | `[]` |  | Changed Over Theme File. Settings you changed while a theme file sets them. Your value applies over the file's; resetting the row returns to the file's. Choosing another theme file clears the list. |
| `appearance.highlightColor` | string |  |  | Highlight Color. The color of selected text everywhere. Unset uses the terminal theme's. |
| `customize.doctorNotice` | boolean | `true` |  | Customization notices |
| `appearance.backdropArt` | string | `"none"` | `none`, `david-death-of-marat`, `velde-small-ship-storm`, `bosch-ascent-blessed`, `goya-witches-flight`, `martin-pandemonium`, `moran-burning-philadelphia`, `goya-burial-sardine`, `arbo-wild-hunt`, `altdorfer-battle-of-issus`, `munch-madonna`, `klee-fish-magic`, `friedrich-forest-moonlight`, `bosch-garden-left`, `rembrandt-storm-galilee`, `cole-voyage-manhood`, `munch-scream`, `bruegel-fall-rebel-angels`, `wright-vesuvius`, `gerome-botsaris`, `martin-joshua`, `velde-gale`, `hogai-nio`, `bosch-garden-central`, `martin-great-day-wrath`, `bonheur-wounded-eagle`, `cole-voyage-old-age`, `friedrich-abbey-oakwood`, `goya-sleep-of-reason`, `bosch-garden-fragment`, `spilliaert-vertigo`, `rothaug-melpomene`, `aivazovsky-ship-stormy-seas`, `cabanel-fallen-angel`, `spilliaert-woman-shoreline`, `el-greco-view-of-toledo`, `rembrandt-prodigal-son`, `velazquez-las-meninas`, `matejko-stanczyk`, `sargent-madame-x`, `millais-joan-of-arc`, `cot-storm`, `rembrandt-night-watch`, `vigee-lebrun-madame-grand`, `waterhouse-lady-shalott`, `fragonard-swing`, `rubens-st-francis-xavier`, `vermeer-pearl-earring`, `danielson-gambogi-self`, `beard-his-majesty`, `marc-foxes`, `degas-green-dancers`, `modigliani-nude-divan`, `raphael-sistine-madonna`, `bouguereau-virgin-lilies`, `wood-american-gothic`, `steinlen-chat-noir`, `degas-blue-dancers`, `botticelli-primavera`, `van-gogh-cafe-terrace`, `matisse-red-room`, `kandinsky-deepened-impulse`, `friedrich-wanderer`, `klimt-adele`, `mucha-job`, `van-gogh-starry-night`, `klimt-tree-of-life`, `klimt-the-kiss`, `van-gogh-starry-night-rhone`, `delacroix-liberty`, `van-gogh-sunflowers`, `klimt-mada-primavesi`, `schiele-kneeling-orange`, `van-gogh-sunflowers-munich`, `michelangelo-sistine-ceiling`, `mondrian-composition-red-plane`, `lemoyne-apotheosis-hercules`, `schiele-moa`, `aivazovsky-ninth-wave`, `popova-painterly-architectonic`, `bruegel-tower-babel`, `botticelli-birth-of-venus`, `kandinsky-yellow-red-blue`, `kandinsky-composition-viii`, `kramskoi-unknown-woman`, `michelangelo-creation-of-adam`, `hokusai-great-wave`, `holbein-ambassadors`, `brueghel-wooden-vessel`, `dahl-dresden-moonlight`, `bosschaert-wan-li-vase`, `cot-springtime`, `ruysch-flowers`, `van-gogh-flowering-plum`, `toulmouche-reluctant-bride`, `rosso-musical-angel`, `grimshaw-blackman-street`, `waterhouse-ophelia`, `biard-magdalena-bay`, `renoir-vase-roses`, `roerich-himalayas`, `velde-close-hauled`, `sohlberg-flower-meadow`, `dahl-cloud-study`, `friedrich-two-men-moon`, `monet-waterlily-pond`, `hesselbom-dusk`, `toulmouche-vanity`, `hiroshige-zoshigaya`, `monet-water-lilies`, `monet-water-lilies-1907`, `bierstadt-storm-rockies`, `korovin-place-opera`, `klimt-garden-sunflowers`, `redon-butterflies`, `aivazovsky-winter-landscape`, `aivazovsky-along-coast`, `grimshaw-silver-moonlight`, `monet-water-lilies-setting-sun`, `hiroshige-hota-coast`, `durer-praying-hands`, `cole-voyage-childhood`, `monet-impression-sunrise`, `monet-woman-parasol`, `velde-cannon-shot`, `cross-pink-cloud`, `laurence-mckinley`, `van-gogh-irises`, `kramskoi-christ-in-the-desert`, `turner-temeraire`, `leonardo-vitruvian-man`, `bruegel-hunters-snow`, `cole-voyage-youth`, `friedrich-monk-by-the-sea`, `van-gogh-wheat-field-cypresses`, `monet-cliff-pourville`, `van-gogh-almond-blossom`, `van-gogh-fishing-boats`, `hokusai-umezawa`, `whistler-falling-rocket`, `dore-fall-of-satan`, `dore-wolves-sheep`, `dore-leviathan`, `dore-paradise-lost-book-vi`, `dore-moses-tables`, `dore-empyrean`, `dore-raven`, `hokusai-red-fuji`, `hokusai-storm-below-fuji`, `hokusai-kajikazawa`, `hiroshige-sudden-shower`, `hiroshige-kanbara-snow`, `hiroshige-plum-garden`, `hiroshige-moon-pine`, `korin-irises`, `tohaku-pine-trees`, `jakuchu-mandarin-ducks`, `fan-kuan-travelers`, `guo-xi-early-spring`, `ma-yuan-clouds-green-sea`, `zhang-zeduan-qingming`, `wang-ximeng-thousand-li`, `jeong-seon-inwang`, `jeong-seon-geumgang`, `kim-hong-do-samgong` | Backdrop Art. A painting behind the window. Lower Opacity to see it. |
| `appearance.background` | string | `"none"` | `none`, `daily`, `appearance`, `schedule`, `david-death-of-marat`, `velde-small-ship-storm`, `bosch-ascent-blessed`, `goya-witches-flight`, `martin-pandemonium`, `moran-burning-philadelphia`, `goya-burial-sardine`, `arbo-wild-hunt`, `altdorfer-battle-of-issus`, `munch-madonna`, `klee-fish-magic`, `friedrich-forest-moonlight`, `bosch-garden-left`, `rembrandt-storm-galilee`, `cole-voyage-manhood`, `munch-scream`, `bruegel-fall-rebel-angels`, `wright-vesuvius`, `gerome-botsaris`, `martin-joshua`, `velde-gale`, `hogai-nio`, `bosch-garden-central`, `martin-great-day-wrath`, `bonheur-wounded-eagle`, `cole-voyage-old-age`, `friedrich-abbey-oakwood`, `goya-sleep-of-reason`, `bosch-garden-fragment`, `spilliaert-vertigo`, `rothaug-melpomene`, `aivazovsky-ship-stormy-seas`, `cabanel-fallen-angel`, `spilliaert-woman-shoreline`, `el-greco-view-of-toledo`, `rembrandt-prodigal-son`, `velazquez-las-meninas`, `matejko-stanczyk`, `sargent-madame-x`, `millais-joan-of-arc`, `cot-storm`, `rembrandt-night-watch`, `vigee-lebrun-madame-grand`, `waterhouse-lady-shalott`, `fragonard-swing`, `rubens-st-francis-xavier`, `vermeer-pearl-earring`, `danielson-gambogi-self`, `beard-his-majesty`, `marc-foxes`, `degas-green-dancers`, `modigliani-nude-divan`, `raphael-sistine-madonna`, `bouguereau-virgin-lilies`, `wood-american-gothic`, `steinlen-chat-noir`, `degas-blue-dancers`, `botticelli-primavera`, `van-gogh-cafe-terrace`, `matisse-red-room`, `kandinsky-deepened-impulse`, `friedrich-wanderer`, `klimt-adele`, `mucha-job`, `van-gogh-starry-night`, `klimt-tree-of-life`, `klimt-the-kiss`, `van-gogh-starry-night-rhone`, `delacroix-liberty`, `van-gogh-sunflowers`, `klimt-mada-primavesi`, `schiele-kneeling-orange`, `van-gogh-sunflowers-munich`, `michelangelo-sistine-ceiling`, `mondrian-composition-red-plane`, `lemoyne-apotheosis-hercules`, `schiele-moa`, `aivazovsky-ninth-wave`, `popova-painterly-architectonic`, `bruegel-tower-babel`, `botticelli-birth-of-venus`, `kandinsky-yellow-red-blue`, `kandinsky-composition-viii`, `kramskoi-unknown-woman`, `michelangelo-creation-of-adam`, `hokusai-great-wave`, `holbein-ambassadors`, `brueghel-wooden-vessel`, `dahl-dresden-moonlight`, `bosschaert-wan-li-vase`, `cot-springtime`, `ruysch-flowers`, `van-gogh-flowering-plum`, `toulmouche-reluctant-bride`, `rosso-musical-angel`, `grimshaw-blackman-street`, `waterhouse-ophelia`, `biard-magdalena-bay`, `renoir-vase-roses`, `roerich-himalayas`, `velde-close-hauled`, `sohlberg-flower-meadow`, `dahl-cloud-study`, `friedrich-two-men-moon`, `monet-waterlily-pond`, `hesselbom-dusk`, `toulmouche-vanity`, `hiroshige-zoshigaya`, `monet-water-lilies`, `monet-water-lilies-1907`, `bierstadt-storm-rockies`, `korovin-place-opera`, `klimt-garden-sunflowers`, `redon-butterflies`, `aivazovsky-winter-landscape`, `aivazovsky-along-coast`, `grimshaw-silver-moonlight`, `monet-water-lilies-setting-sun`, `hiroshige-hota-coast`, `durer-praying-hands`, `cole-voyage-childhood`, `monet-impression-sunrise`, `monet-woman-parasol`, `velde-cannon-shot`, `cross-pink-cloud`, `laurence-mckinley`, `van-gogh-irises`, `kramskoi-christ-in-the-desert`, `turner-temeraire`, `leonardo-vitruvian-man`, `bruegel-hunters-snow`, `cole-voyage-youth`, `friedrich-monk-by-the-sea`, `van-gogh-wheat-field-cypresses`, `monet-cliff-pourville`, `van-gogh-almond-blossom`, `van-gogh-fishing-boats`, `hokusai-umezawa`, `whistler-falling-rocket`, `dore-fall-of-satan`, `dore-wolves-sheep`, `dore-leviathan`, `dore-paradise-lost-book-vi`, `dore-moses-tables`, `dore-empyrean`, `dore-raven`, `hokusai-red-fuji`, `hokusai-storm-below-fuji`, `hokusai-kajikazawa`, `hiroshige-sudden-shower`, `hiroshige-kanbara-snow`, `hiroshige-plum-garden`, `hiroshige-moon-pine`, `korin-irises`, `tohaku-pine-trees`, `jakuchu-mandarin-ducks`, `fan-kuan-travelers`, `guo-xi-early-spring`, `ma-yuan-clouds-green-sea`, `zhang-zeduan-qingming`, `wang-ximeng-thousand-li`, `jeong-seon-inwang`, `jeong-seon-geumgang`, `kim-hong-do-samgong`, `desktop` | Background. A painting, your wallpaper or a macOS wallpaper behind the window. |
| `appearance.backgroundRotation` | string | `"daily"` | `15m`, `hourly`, `daily` | Change Picture. How often a shuffled background changes. Also accepts a number from 1 to 1440 in a raw profile. |
| `appearance.backgroundLight` | string |  | `david-death-of-marat`, `velde-small-ship-storm`, `bosch-ascent-blessed`, `goya-witches-flight`, `martin-pandemonium`, `moran-burning-philadelphia`, `goya-burial-sardine`, `arbo-wild-hunt`, `altdorfer-battle-of-issus`, `munch-madonna`, `klee-fish-magic`, `friedrich-forest-moonlight`, `bosch-garden-left`, `rembrandt-storm-galilee`, `cole-voyage-manhood`, `munch-scream`, `bruegel-fall-rebel-angels`, `wright-vesuvius`, `gerome-botsaris`, `martin-joshua`, `velde-gale`, `hogai-nio`, `bosch-garden-central`, `martin-great-day-wrath`, `bonheur-wounded-eagle`, `cole-voyage-old-age`, `friedrich-abbey-oakwood`, `goya-sleep-of-reason`, `bosch-garden-fragment`, `spilliaert-vertigo`, `rothaug-melpomene`, `aivazovsky-ship-stormy-seas`, `cabanel-fallen-angel`, `spilliaert-woman-shoreline`, `el-greco-view-of-toledo`, `rembrandt-prodigal-son`, `velazquez-las-meninas`, `matejko-stanczyk`, `sargent-madame-x`, `millais-joan-of-arc`, `cot-storm`, `rembrandt-night-watch`, `vigee-lebrun-madame-grand`, `waterhouse-lady-shalott`, `fragonard-swing`, `rubens-st-francis-xavier`, `vermeer-pearl-earring`, `danielson-gambogi-self`, `beard-his-majesty`, `marc-foxes`, `degas-green-dancers`, `modigliani-nude-divan`, `raphael-sistine-madonna`, `bouguereau-virgin-lilies`, `wood-american-gothic`, `steinlen-chat-noir`, `degas-blue-dancers`, `botticelli-primavera`, `van-gogh-cafe-terrace`, `matisse-red-room`, `kandinsky-deepened-impulse`, `friedrich-wanderer`, `klimt-adele`, `mucha-job`, `van-gogh-starry-night`, `klimt-tree-of-life`, `klimt-the-kiss`, `van-gogh-starry-night-rhone`, `delacroix-liberty`, `van-gogh-sunflowers`, `klimt-mada-primavesi`, `schiele-kneeling-orange`, `van-gogh-sunflowers-munich`, `michelangelo-sistine-ceiling`, `mondrian-composition-red-plane`, `lemoyne-apotheosis-hercules`, `schiele-moa`, `aivazovsky-ninth-wave`, `popova-painterly-architectonic`, `bruegel-tower-babel`, `botticelli-birth-of-venus`, `kandinsky-yellow-red-blue`, `kandinsky-composition-viii`, `kramskoi-unknown-woman`, `michelangelo-creation-of-adam`, `hokusai-great-wave`, `holbein-ambassadors`, `brueghel-wooden-vessel`, `dahl-dresden-moonlight`, `bosschaert-wan-li-vase`, `cot-springtime`, `ruysch-flowers`, `van-gogh-flowering-plum`, `toulmouche-reluctant-bride`, `rosso-musical-angel`, `grimshaw-blackman-street`, `waterhouse-ophelia`, `biard-magdalena-bay`, `renoir-vase-roses`, `roerich-himalayas`, `velde-close-hauled`, `sohlberg-flower-meadow`, `dahl-cloud-study`, `friedrich-two-men-moon`, `monet-waterlily-pond`, `hesselbom-dusk`, `toulmouche-vanity`, `hiroshige-zoshigaya`, `monet-water-lilies`, `monet-water-lilies-1907`, `bierstadt-storm-rockies`, `korovin-place-opera`, `klimt-garden-sunflowers`, `redon-butterflies`, `aivazovsky-winter-landscape`, `aivazovsky-along-coast`, `grimshaw-silver-moonlight`, `monet-water-lilies-setting-sun`, `hiroshige-hota-coast`, `durer-praying-hands`, `cole-voyage-childhood`, `monet-impression-sunrise`, `monet-woman-parasol`, `velde-cannon-shot`, `cross-pink-cloud`, `laurence-mckinley`, `van-gogh-irises`, `kramskoi-christ-in-the-desert`, `turner-temeraire`, `leonardo-vitruvian-man`, `bruegel-hunters-snow`, `cole-voyage-youth`, `friedrich-monk-by-the-sea`, `van-gogh-wheat-field-cypresses`, `monet-cliff-pourville`, `van-gogh-almond-blossom`, `van-gogh-fishing-boats`, `hokusai-umezawa`, `whistler-falling-rocket`, `dore-fall-of-satan`, `dore-wolves-sheep`, `dore-leviathan`, `dore-paradise-lost-book-vi`, `dore-moses-tables`, `dore-empyrean`, `dore-raven`, `hokusai-red-fuji`, `hokusai-storm-below-fuji`, `hokusai-kajikazawa`, `hiroshige-sudden-shower`, `hiroshige-kanbara-snow`, `hiroshige-plum-garden`, `hiroshige-moon-pine`, `korin-irises`, `tohaku-pine-trees`, `jakuchu-mandarin-ducks`, `fan-kuan-travelers`, `guo-xi-early-spring`, `ma-yuan-clouds-green-sea`, `zhang-zeduan-qingming`, `wang-ximeng-thousand-li`, `jeong-seon-inwang`, `jeong-seon-geumgang`, `kim-hong-do-samgong`, `desktop` | Light Picture. Unset, it shows the dark picture. |
| `appearance.backgroundDark` | string |  | `david-death-of-marat`, `velde-small-ship-storm`, `bosch-ascent-blessed`, `goya-witches-flight`, `martin-pandemonium`, `moran-burning-philadelphia`, `goya-burial-sardine`, `arbo-wild-hunt`, `altdorfer-battle-of-issus`, `munch-madonna`, `klee-fish-magic`, `friedrich-forest-moonlight`, `bosch-garden-left`, `rembrandt-storm-galilee`, `cole-voyage-manhood`, `munch-scream`, `bruegel-fall-rebel-angels`, `wright-vesuvius`, `gerome-botsaris`, `martin-joshua`, `velde-gale`, `hogai-nio`, `bosch-garden-central`, `martin-great-day-wrath`, `bonheur-wounded-eagle`, `cole-voyage-old-age`, `friedrich-abbey-oakwood`, `goya-sleep-of-reason`, `bosch-garden-fragment`, `spilliaert-vertigo`, `rothaug-melpomene`, `aivazovsky-ship-stormy-seas`, `cabanel-fallen-angel`, `spilliaert-woman-shoreline`, `el-greco-view-of-toledo`, `rembrandt-prodigal-son`, `velazquez-las-meninas`, `matejko-stanczyk`, `sargent-madame-x`, `millais-joan-of-arc`, `cot-storm`, `rembrandt-night-watch`, `vigee-lebrun-madame-grand`, `waterhouse-lady-shalott`, `fragonard-swing`, `rubens-st-francis-xavier`, `vermeer-pearl-earring`, `danielson-gambogi-self`, `beard-his-majesty`, `marc-foxes`, `degas-green-dancers`, `modigliani-nude-divan`, `raphael-sistine-madonna`, `bouguereau-virgin-lilies`, `wood-american-gothic`, `steinlen-chat-noir`, `degas-blue-dancers`, `botticelli-primavera`, `van-gogh-cafe-terrace`, `matisse-red-room`, `kandinsky-deepened-impulse`, `friedrich-wanderer`, `klimt-adele`, `mucha-job`, `van-gogh-starry-night`, `klimt-tree-of-life`, `klimt-the-kiss`, `van-gogh-starry-night-rhone`, `delacroix-liberty`, `van-gogh-sunflowers`, `klimt-mada-primavesi`, `schiele-kneeling-orange`, `van-gogh-sunflowers-munich`, `michelangelo-sistine-ceiling`, `mondrian-composition-red-plane`, `lemoyne-apotheosis-hercules`, `schiele-moa`, `aivazovsky-ninth-wave`, `popova-painterly-architectonic`, `bruegel-tower-babel`, `botticelli-birth-of-venus`, `kandinsky-yellow-red-blue`, `kandinsky-composition-viii`, `kramskoi-unknown-woman`, `michelangelo-creation-of-adam`, `hokusai-great-wave`, `holbein-ambassadors`, `brueghel-wooden-vessel`, `dahl-dresden-moonlight`, `bosschaert-wan-li-vase`, `cot-springtime`, `ruysch-flowers`, `van-gogh-flowering-plum`, `toulmouche-reluctant-bride`, `rosso-musical-angel`, `grimshaw-blackman-street`, `waterhouse-ophelia`, `biard-magdalena-bay`, `renoir-vase-roses`, `roerich-himalayas`, `velde-close-hauled`, `sohlberg-flower-meadow`, `dahl-cloud-study`, `friedrich-two-men-moon`, `monet-waterlily-pond`, `hesselbom-dusk`, `toulmouche-vanity`, `hiroshige-zoshigaya`, `monet-water-lilies`, `monet-water-lilies-1907`, `bierstadt-storm-rockies`, `korovin-place-opera`, `klimt-garden-sunflowers`, `redon-butterflies`, `aivazovsky-winter-landscape`, `aivazovsky-along-coast`, `grimshaw-silver-moonlight`, `monet-water-lilies-setting-sun`, `hiroshige-hota-coast`, `durer-praying-hands`, `cole-voyage-childhood`, `monet-impression-sunrise`, `monet-woman-parasol`, `velde-cannon-shot`, `cross-pink-cloud`, `laurence-mckinley`, `van-gogh-irises`, `kramskoi-christ-in-the-desert`, `turner-temeraire`, `leonardo-vitruvian-man`, `bruegel-hunters-snow`, `cole-voyage-youth`, `friedrich-monk-by-the-sea`, `van-gogh-wheat-field-cypresses`, `monet-cliff-pourville`, `van-gogh-almond-blossom`, `van-gogh-fishing-boats`, `hokusai-umezawa`, `whistler-falling-rocket`, `dore-fall-of-satan`, `dore-wolves-sheep`, `dore-leviathan`, `dore-paradise-lost-book-vi`, `dore-moses-tables`, `dore-empyrean`, `dore-raven`, `hokusai-red-fuji`, `hokusai-storm-below-fuji`, `hokusai-kajikazawa`, `hiroshige-sudden-shower`, `hiroshige-kanbara-snow`, `hiroshige-plum-garden`, `hiroshige-moon-pine`, `korin-irises`, `tohaku-pine-trees`, `jakuchu-mandarin-ducks`, `fan-kuan-travelers`, `guo-xi-early-spring`, `ma-yuan-clouds-green-sea`, `zhang-zeduan-qingming`, `wang-ximeng-thousand-li`, `jeong-seon-inwang`, `jeong-seon-geumgang`, `kim-hong-do-samgong`, `desktop` | Dark Picture. Unset, it shows the light picture. |
| `appearance.backgroundSchedule` | dictionary |  |  | Time of Day Pictures. A time (07:00) or sun event (sunset-30m) for each picture. |
| `appearance.backgroundDynamic` | string | `"appearance"` | `appearance`, `time` | Dynamic Wallpaper. Follow light and dark, or change with the sun through the day. |
| `appearance.backgroundLocation` | string |  |  | Sun Location. Latitude,longitude for sunrise and sunset, such as 37.77,-122.42. Unset: your time zone. |
| `appearance.backgroundMemory` | dictionary |  |  | Background Mode Memory. The folder and picture each background mode last showed, so switching back restores them. |
| `appearance.displayBackgrounds` | dictionary |  |  | Per-display Backgrounds. Display ID to daily, folder:<path>, desktop, a background or none. |
| `appearance.displayBackgroundRotations` | dictionary |  |  | Per-display Background Rotation. Display ID to 15m, hourly or daily. Others use the global rotation. |
| `appearance.paneBackgrounds` | string | `"shared"` | `shared`, `perPane` | Pane Backgrounds. One background behind the window, or a copy in each pane. |
| `ui.reducedBackgrounds` | boolean | `false` |  | Plain Backgrounds. The plain theme color, without paintings, wallpapers or glass. |
| `appearance.agentGlow` | boolean | `false` |  | React to Agents. Calm while agents are idle; a soft glow in the machine's color when an agent needs you. |
| `appearance.previousGlass` | boolean | `false` |  | Previous Glass Look. Draws menus, popovers, the composer and cards with the glass from before November 2026. |
| `appearance.experimentalControls` | boolean | `false` |  | Experimental Appearance Controls. Applies Hue and Saturation to the window's tint. Off, they have no effect. |
| `appearance.backgroundOpacity` | real |  | 0 to 1 | Opacity. How much of the theme color covers the material behind the window. |
| `appearance.backgroundBlur` | string |  | `frosted`, `glass`, `glass-clear`, `none` | Material. Unset, the window follows Ghostty's background-opacity and background-blur. |
| `appearance.inactiveWindowDim` | real | `0` | 0 to 1 | Dim Inactive Windows. How much windows behind the front one are tinted. 0 keeps them the same. |
| `appearance.wallpaperTint` | boolean | `true` |  | Tint with Desktop Wallpaper. The glass takes the colors of your desktop picture. |
| `appearance.glassTransparency` | real | `0` | 0 to 1 | Glass Transparency. How much of the desktop or wallpaper shows through the glass. |
| `appearance.hue` | real | `0.5` | 0 to 1 | Hue. Shift the tint color around the hue wheel. |
| `appearance.saturation` | real | `1` | 0 to 2 | Saturation. Increase or reduce the tint color intensity. |
| `appearance.density` | string | `"cozy"` | `ultraCompact`, `compact`, `cozy`, `comfortable`, `spacious` | Density. Row height, padding, corners, icons and text size together. |
| `appearance.customDensity` | string |  |  | Custom Density |
| `appearance.customDensities` | string | `[]` |  | Custom Densities |
| `app.uiScale` | real | `1` | 0.25 to 5 | App Zoom. Zoom for chat, Settings and other app pages. |
| `appearance.metrics.chromeFontSize` | real |  | 10 to 20 | Text Size. Text size of the sidebar, tabs, menus and chat. Terminals have their own size. |
| `appearance.fontSmoothing` | string | `"auto"` | `auto`, `antialiased`, `subpixel` | Text Smoothing. How text draws. Some text changes after cmux restarts; terminals keep their own. |
| `appearance.interfaceScale` | real |  | 0.9 to 1.25 | Interface Size. Text size of tabs, the sidebar and other controls. Terminal text has its own size. |
| `appearance.metrics.sidebarWidth` | real |  | 160 to 420 | Sidebar Width |
| `appearance.metrics.columnGap` | real |  | 0 to 24 | Column Gap |
| `appearance.metrics.dividerThickness` | real |  | 0 to 6 | Divider Thickness |
| `appearance.metrics.dividerHitWidth` | real |  | 1 to 24 | Divider Drag Width |
| `appearance.metrics.titlebarHeight` | real |  | 24 to 56 | Titlebar Height |
| `appearance.metrics.sidebarRowHeight` | real |  | 20 to 48 | Workspace Row Height |
| `appearance.borders` | string | `"default"` | `default`, `none` | Borders. None removes every border, hairline and separator in the app. |
| `appearance.focusIndicator` | string | `"tabs"` | `border`, `tabs`, `both`, `none` | Focused Pane. How the focused pane stands out. |
| `focus.inactiveTabStyle` | string | `"fade"` | `fade`, `tonal`, `quiet` | Unfocused Pane Tabs. How other panes' tabs look subtler when Focused Pane marks tabs. |
| `ui.animationSpeed` | string | `"fast"` | `fast`, `normal`, `off` | Animations |
| `appearance.chromeStyle` | string | `"flat"` | `default`, `card`, `card-outlined`, `flat`, `flat-sidebar-line`, `bare`, `panes`, `two-tone`, `floating`, `blocks` | Window Style. Whether panes sit in one rounded card, and where lines are drawn. |
| `appearance.titleAreaTone` | string | `"oneColor"` | `oneColor`, `subtleTone` | Title Area. The title bar, tab bar and sidebar in the content's color, or shaded apart. |
| `appearance.titleAreaContrast` | real | `1` | 0 to 2 | Title Area Contrast. How much darker the title bar, tab bar and sidebar are. 1 is the default. |
| `appearance.twoTone` | string | `"off"` | `off`, `auto`, `inkSakura`, `charcoalRose`, `inkMagenta`, `creamForest`, `navySand`, `boneOxblood`, `slateMatcha`, `plumAmber` | Two-Tone. The sidebar and tab bar in one tone, the panes in another. Works with every window style and theme. |
| `appearance.cornerFlush` | string | `"flush"` | `off`, `flush`, `flush-tight`, `flush-goo` | Selected Tab Shape. How the selected tab meets the content below it: a pill, flush with it, or flowing into it like a drop of water. |
| `ui.paneAnimations` | boolean | `true` |  | Animate Panes. Splits, closes, moves, zooms and column scrolls slide into place. |
| `ui.animations.newTab` | boolean | `true` |  | Animate New Tabs. A new tab grows into its place in the tab bar. Off shows it there at once. |
| `ui.animations.newWorkspace` | boolean | `true` |  | Animate New Workspaces. A new workspace row opens in the sidebar. Off shows it there at once. |
| `layout.paneSeparation` | string |  | `none`, `dividers`, `borders`, `cards` | Separation. How panes are told apart. |
| `layout.panePadding` | real |  | 0 to 16 | Padding |
| `layout.paneCornerRadius` | real |  | 0 to 20 | Corner Radius. One radius for panes, tabs, panels, popovers and cards. |
| `layout.cornerPadding` | real |  | 0 to 12 | Corner Padding. Space between a pane's edge and its tabs. Inner corners use the corner radius minus this. |
| `layout.paneBorder` | string | `"subtle"` | `subtle`, `none` | Border |
| `layout.paneBorderColor` | string |  |  | Border Color |
| `layout.paneBorderWidth` | real |  | 0.5 to 4 | Border Width |
| `focusRing.enabled` | boolean | `false` |  | Show Focus Ring |
| `focusRing.style` | string | `"ring"` | `ring`, `glow`, `none` | Style |
| `focusRing.contrast` | string | `"subtle"` | `subtle`, `standard`, `strong` | Contrast |
| `focusRing.color` | string |  |  | Color |
| `focusRing.width` | real | `1` | 0.5 to 8 | Width |
| `focusRing.showWhenSinglePane` | boolean | `false` |  | Show With One Pane |
| `ui.calm` | string | `"off"` | `off`, `calm`, `still` | Calm Mode. Calm stops sliding, spinning and hover highlights; Still also makes animations instant. |
| `ui.animations.enabled` | boolean | `true` |  | Play Animations. Off turns every animation off. On, the switches below pick by area. |
| `ui.animations.sidebar` | boolean | `true` |  | Animate the Sidebar. Rows, groups and the sidebar itself slide as they change. |
| `ui.animations.tabs` | boolean | `true` |  | Animate Tabs. Tabs grow, shrink and slide as they open, close and move. |
| `ui.animations.panes` | boolean | `true` |  | Animate Panes and Windows. Splits, closes, zooms, dividers and windows move with motion. |
| `ui.animations.overlays` | boolean | `true` |  | Animate Menus and Cards. Menus, popovers, the palette, sheets, toasts and cards fade and slide. |
| `ui.animations.hoverCards` | boolean | `true` |  | Animate Hover Cards. Hover cards and tooltips fade and slide in. Off: they show and hide at once. |
| `ui.animations.home` | boolean | `true` |  | Animate Home and Chats. The Chief chat, its bubbles, the composer and the Home list move and fade. |
| `ui.animations.cursor` | boolean | `true` |  | Animate the Agent Cursor. The agent cursor glides and shows click ripples. |
| `ui.animations.indicators` | boolean | `true` |  | Animate Spinners and Progress. Spinners turn, status dots pulse and attention flashes blink. |
| `ui.animations.feedback` | boolean | `true` |  | Animate Highlights and Colors. Hover, press, focus and theme color changes ease in. |
| `ui.animations.web` | boolean | `true` |  | Animate cmux Web Pages. Animations in cmux's own pages, such as chats and New Tab. Websites are unchanged. |
| `appearance.surfaces.sidebar.color` | string |  |  | Sidebar Color |
| `appearance.surfaces.sidebar.opacity` | real |  | 0 to 1 | Sidebar Opacity |
| `appearance.surfaces.tabBar.color` | string |  |  | Tab Bar Color |
| `appearance.surfaces.tabBar.opacity` | real |  | 0 to 1 | Tab Bar Opacity |
| `appearance.surfaces.terminal.color` | string |  |  | Terminal Color |
| `appearance.surfaces.terminal.opacity` | real |  | 0 to 1 | Terminal Opacity |
| `appearance.surfaces.agentPane.color` | string |  |  | Agent Chat Color |
| `appearance.surfaces.agentPane.opacity` | real |  | 0 to 1 | Agent Chat Opacity |
| `appearance.surfaces.settings.color` | string |  |  | Settings Color |
| `appearance.surfaces.settings.opacity` | real |  | 0 to 1 | Settings Opacity |
| `appearance.surfaces.newTabPage.color` | string |  |  | New Tab Page Color |
| `appearance.surfaces.newTabPage.opacity` | real |  | 0 to 1 | New Tab Page Opacity |
| `appearance.surfaces.home.color` | string |  |  | Home Color |
| `appearance.surfaces.home.opacity` | real |  | 0 to 1 | Home Opacity |
| `appearance.surfaces.browserChrome.color` | string |  |  | Browser Toolbar Color |
| `appearance.surfaces.browserChrome.opacity` | real |  | 0 to 1 | Browser Toolbar Opacity |
| `appearance.surfaces.internalPage.color` | string |  |  | Internal Pages Color |
| `appearance.surfaces.internalPage.opacity` | real |  | 0 to 1 | Internal Pages Opacity |
| `appearance.surfaces.splitDivider.color` | string |  |  | Split Divider Color |
| `appearance.surfaces.splitDivider.opacity` | real |  | 0 to 1 | Split Divider Opacity |
| `appearance.surfaces.docks.color` | string |  |  | Docked Columns Color |
| `appearance.surfaces.docks.opacity` | real |  | 0 to 1 | Docked Columns Opacity |
| `appearance.surfaces.diff.color` | string |  |  | Diff Viewer Color |
| `appearance.surfaces.diff.opacity` | real |  | 0 to 1 | Diff Viewer Opacity |
| `appearance.surfaces.markdown.color` | string |  |  | Markdown Editor Color |
| `appearance.surfaces.markdown.opacity` | real |  | 0 to 1 | Markdown Editor Opacity |
| `appearance.surfaces.editor.color` | string |  |  | Code Editor Color |
| `appearance.surfaces.editor.opacity` | real |  | 0 to 1 | Code Editor Opacity |
| `appearance.statusIndicator.style` | string | `"arc"` | `arc`, `native`, `dot`, `braille`, `none` | Style. How sidebar rows, tabs and panes show work in progress. |
| `appearance.statusIndicator.animation` | string | `"animated"` | `animated`, `static` | Status Indicators. Static draws a still, distinct shape for each state. Reduce Motion always uses Static. |
| `appearance.statusIndicator.size` | real | `1` | 0.5 to 1.5 | Size |
| `appearance.statusIndicator.thickness` | real | `1.5` | 0.5 to 4 | Line Width |
| `appearance.statusIndicator.color` | string |  |  | Color |
| `appearance.statusIndicator.showAgentWorkingOnTabs` | boolean | `true` |  | Show Agent Working on Tabs. Three dots take the tab's icon place while an agent works. |
| `appearance.statusIndicator.showPageLoading` | boolean | `true` |  | Show Page Loading on Tabs. A spinner takes a browser tab's icon place while its page loads. |
| `appearance.statusIndicator.honorStatusStyle` | boolean | `true` |  | Let Statuses Choose Their Style. A status that asks for a style (cmux status set --style) uses it. |
| `status.inferCommandBusy` | boolean | `false` |  | Show Running Commands. A shell command that runs a while shows as busy. |
| `status.inferCommandBusyAfter` | real | `3` | 0 to 600 | Show After |
| `diff.layout` | string | `"auto"` | `auto`, `split`, `unified` | Layout |
| `diff.diffIndicators` | string | `"bars"` | `bars`, `classic`, `none` | Change Markers |
| `diff.colors` | string | `"theme"` | `theme`, `muted`, `standard` | Diff Colors |
| `diff.wordWrap` | boolean | `false` |  | Wrap Lines |
| `diff.wordDiffs` | boolean | `true` |  | Highlight Word Changes |
| `diff.lineNumbers` | boolean | `true` |  | Line Numbers |
| `diff.showBackgrounds` | boolean | `true` |  | Change Backgrounds |
| `diff.expandUnchanged` | boolean | `false` |  | Expand Unchanged Lines |
| `diff.groupByKind` | boolean | `false` |  | Group Files by Kind |
| `diff.hideWhitespace` | boolean | `false` |  | Hide White Space |
| `diff.showBulkActions` | boolean | `true` |  | Stage All and Revert All Bar |
| `markdown.remoteImages` | boolean | `false` |  | Load Web Images Automatically. Image sites can see your address and when you open a document. |
| `markdown.layout.width` | real | `72` | 30 to 1000 | Text Width. The widest a line gets, in characters. |
| `markdown.layout.fullWidth` | boolean | `false` |  | Full Width. Text fills the whole pane instead of the text width. |
| `markdown.font.size` | real | `16` | 8 to 40 | Default Font Size. The size viewers open at. Cmd-= and Cmd-- change one viewer. |
| `markdown.font.preset` | string | `"system"` | `system`, `serif`, `mono` | Font |
| `markdown.font.lineHeight` | real | `1.6` | 1 to 2.4 | Line Height |
| `markdown.spacing.paragraph` | real | `1` | 0 to 3 | Paragraph Spacing. The gap after each paragraph, as a share of the text size. |
| `markdown.code.scale` | real | `0.875` | 0.6 to 1.25 | Code Font Size. Code size as a share of the text size. |
| `markdown.code.family` | string |  |  | Code Font. Empty uses the terminal font. |
| `markdown.code.blockSize` | real |  | 8 to 32 | Code Block Size |
| `markdown.tables` | string | `"scroll"` | `scroll`, `wrap` | Wide Tables |
| `markdown.theme` | string | `"app"` | `app`, `light`, `dark` | Page Theme |
| `agentPane.display.width` | string | `800` | `narrow`, `medium`, `wide` | Chat Text Width. The widest the chat's column gets. On a wider pane the chat stays centered. Also accepts a number from 480 to 4000 in a raw profile. |
| `agentPane.display.fullWidth` | boolean | `false` |  | Chat Full Width. The chat fills the whole pane instead of the text width. |
| `agentPane.display.vscodeMinimap` | boolean | `false` |  | VS Code Minimap. A small picture of the whole chat at its right edge. Click or drag it to scroll. |
| `agentPane.display.pinnedPlan` | boolean | `false` |  | Pin Task List in Chat. Keeps the agent's task list under the latest message, not over the composer. |
| `agentPane.display.finishSound` | boolean | `false` |  | Play Sound When Work Finishes. A soft sound when a long turn ends, its checks pass or its pull request merges. |
| `agentPane.display.trayTucked` | boolean | `false` |  | Tuck Away Running Tray. Hides the running work bar. Hover the top of the composer to bring it back. |
| `agentPane.display.trayHandle` | string | `"middle"` | `left`, `middle`, `right` | Running Tray Handle. Where the running tray's handle sits on top of the composer. |
| `agentPane.display.unreadBanner` | string | `"off"` | `expanded`, `collapsed`, `off` | Unread Banner. A banner for new turns when you come back to a chat. Right-click it to hide it. |
| `agentPane.display.senderIcon.lead` | string | `"family"` | `family`, `session` | Sender Icon Emphasis. Which is big in a sender's icon: the model's mark or the session badge. |
| `agentPane.display.senderIcon.badge` | string | `"diamond"` | `diamond`, `robot`, `none` | Sender Badge. The small colored glyph on a sender's icon that tells sessions of one model family apart. |
| `agentPane.display.senderIcon.corner` | string | `"bottom-right"` | `bottom-right`, `bottom-left`, `top-right`, `top-left` | Sender Badge Corner. Where the small glyph sits on a sender's icon. |
| `agentPane.display.font.preset` | string | `"markdown"` | `markdown`, `system`, `serif`, `mono` | Chat Font |
| `agentPane.display.font.ui` | string | `"system-ui"` | `system-ui`, `system-ui-tight`, `inter-tuned`, `inter`, `verdana`, `roboto`, `plex`, `source-sans`, `geist`, `cmux-sans`, `hanken`, `atkinson` | Chat Interface Font. The font of the whole chat: replies, the composer, cards and menus. |
| `agentPane.display.font.uiFamily` | string |  |  | Chat Interface Font Family. A font family or a comma list of them. When set, it replaces the Chat Interface Font. |
| `agentPane.display.font.proseFamily` | string |  |  | Chat Reply Font Family. The font of the agent's replies. When set, it replaces the Chat Font. |
| `agentPane.display.font.faces` | dictionary |  |  | Chat Font Files. A font file for each family, such as "Lora:italic": "file:~/Fonts/Lora-Italic.woff2". |
| `agentPane.display.font.size` | real | `14` | 10 to 28 | Chat Font Size |
| `agentPane.display.font.lineHeight` | real | `1.625` | 1.2 to 2.4 | Chat Line Height |
| `agentPane.display.code.family` | string |  |  | Chat Code Font. Empty uses the Markdown viewer's code font. |
| `agentPane.display.code.scale` | real |  | 0.6 to 1.25 | Chat Code Size. Code as a share of the chat's text size. Empty uses the Markdown viewer's. |
| `agentPane.display.sessionInfo.placement` | string | `"overlay"` | `push`, `overlay` | Session Info. Push narrows the chat; Overlay covers it. |
| `agentPane.display.environment.placement` | string | `"left"` | `left`, `right`, `off` | Session Info Chip. Where the chip sits: under the tabs (Left) or in the header (Right). |
| `agentPane.display.minimap` | string | `"compact"` | `compact`, `full`, `off` | Chat Minimap. What runs down the chat's edge. |
| `agentPane.display.transcriptView` | string | `"normal"` | `normal`, `thinking`, `verbose` | Transcript View. How much of each turn a chat shows. A chat's ··· menu sets its own. |
| `agentPane.display.presentation` | string | `"transcript"` | `transcript`, `messages` | Chat Presentation |
| `agentPane.display.promptCoach` | boolean | `true` |  | Prompt Coach. After a chat with many corrections, shows a better first prompt. |
| `agentPane.display.statusVerbs.mode` | string | `"thinking"` | `thinking`, `rotate`, `custom` | Working Status Verbs. Choose whether the live status line rotates through verbs or stays on Thinking. |
| `agentPane.display.statusVerbs.custom` | string |  |  | Custom Working Verbs. Comma-separated -ing verbs for the live status line. |
| `agentPane.display.thinking.shimmer` | string | `"cadenced"` | `cadenced`, `continuous` | Thinking Shimmer. How the light band moves across the live status line. |
| `agentPane.display.thinking.shimmerPeriod` | real | `1250` | 600 to 4000 | Shimmer Speed. How long one continuous pass of the shimmer takes. |
| `agentPane.display.thinking.shimmerBand` | real | `0` | 0 to 240 | Shimmer Width. The width of the shimmer's light band. 0 uses half the line. |
| `agentPane.display.thinking.jumpButton` | string | `"arrow"` | `arrow`, `dots` | Jump to Latest While Working. What the Jump to latest button shows while the agent works. |
| `agentPane.display.harnessPlacement` | string | `"symbols"` | `symbols`, `left`, `top`, `compact` | Model Picker Harness Placement |
| `agentPane.display.rail.side` | string | `"left"` | `left`, `right` | Prompt Rail Side. Right-click the rail to move it. |
| `agentPane.display.rail.show` | string | `"prompts"` | `prompts`, `mine`, `received`, `replies`, `everything`, `errors`, `edits`, `tools`, `subagents` | Prompt Rail Shows. Right-click the rail to change it. |
| `agentPane.display.rail.control` | boolean | `false` |  | Prompt Rail Button. Shows what the rail lists above it while you point at it. |
| `agentPane.display.commandLabels` | string | `[]` |  | Command Labels. The names the chat shows for background commands. |
| `terminal.fontFamily` | string |  |  | Font Family. A monospaced font installed on this Mac. |
| `terminal.fontSize` | real |  | 4 to 96 | Font Size |
| `terminal.linkOpener.default` | string | `"cmux"` |  | Open Program Links In. Where terminal programs open URLs: cmux, system, chrome, safari, app:<name> or command:<cmd>. |
| `terminal.linkOpener.rules` | array | `[]` |  | Program Link Rules. <match> -> <target>, first match wins. Example: caller:gh github.com -> safari |
| `terminal.term` | string | `"xterm-256color"` | `xterm-256color`, `xterm-ghostty` | Terminal Type (TERM). xterm-ghostty needs Ghostty's terminfo on every host you ssh to. |
| `editor.fontFamily` | string |  |  | Font Family. Empty uses the terminal font. |
| `editor.fontSize` | real |  | 6 to 72 | Font Size. Empty uses the terminal font size. Cmd-= and Cmd-- change it in one editor. |
| `editor.fontWeight` | string | `"normal"` | `normal`, `bold`, `300`, `500`, `600` | Font Weight |
| `editor.fontLigatures` | boolean | `false` |  | Font Ligatures |
| `editor.lineHeight` | real | `0` | 0 to 150 | Line Height. 0 computes it from the font size. A value under 8 multiplies the font size. |
| `editor.letterSpacing` | real | `0` | -5 to 20 | Letter Spacing |
| `editor.tabSize` | real | `4` | 1 to 16 | Tab Size |
| `editor.insertSpaces` | boolean | `true` |  | Insert Spaces. Tab inserts spaces. Off inserts a tab character. |
| `editor.detectIndentation` | boolean | `true` |  | Detect Indentation. Tab size and spaces follow the file's own indentation. |
| `editor.wordWrap` | string | `"off"` | `off`, `on`, `wordWrapColumn`, `bounded` | Word Wrap. Opt-Z turns it on and off. |
| `editor.wordWrapColumn` | real | `80` | 10 to 1000 | Wrap Column |
| `editor.lineNumbers` | string | `"on"` | `on`, `off`, `relative`, `interval` | Line Numbers |
| `editor.rulers` | array | `[]` |  | Rulers. Columns where a vertical line shows. |
| `editor.minimap.enabled` | boolean | `false` |  | Minimap |
| `editor.renderWhitespace` | string | `"selection"` | `none`, `boundary`, `selection`, `trailing`, `all` | Show Whitespace |
| `editor.renderControlCharacters` | boolean | `true` |  | Show Control Characters |
| `editor.renderLineHighlight` | string | `"line"` | `none`, `gutter`, `line`, `all` | Current Line Highlight |
| `editor.bracketPairColorization.enabled` | boolean | `true` |  | Color Bracket Pairs |
| `editor.guides.bracketPairs` | boolean | `false` |  | Bracket Pair Guides |
| `editor.guides.indentation` | boolean | `true` |  | Indentation Guides |
| `editor.matchBrackets` | string | `"always"` | `always`, `near`, `never` | Highlight Matching Brackets |
| `editor.stickyScroll.enabled` | boolean | `true` |  | Sticky Scroll. The lines that open the scopes around the top line stay at the top while you scroll. |
| `editor.folding` | boolean | `true` |  | Code Folding |
| `editor.scrollBeyondLastLine` | boolean | `false` |  | Scroll Past the Last Line |
| `editor.smoothScrolling` | boolean | `false` |  | Smooth Scrolling |
| `editor.mouseWheelZoom` | boolean | `false` |  | Zoom with Command and the Scroll Wheel |
| `editor.cursorStyle` | string | `"line"` | `line`, `block`, `underline`, `line-thin`, `block-outline`, `underline-thin` | Cursor Style |
| `editor.cursorBlinking` | string | `"blink"` | `blink`, `smooth`, `phase`, `expand`, `solid` | Cursor Blinking |
| `editor.cursorSmoothCaretAnimation` | string | `"off"` | `off`, `explicit`, `on` | Animate Cursor Movement |
| `editor.cursorSurroundingLines` | real | `0` | 0 to 50 | Lines Kept Around the Cursor |
| `editor.multiCursorModifier` | string | `"alt"` | `alt`, `ctrlCmd` | Add a Cursor With. The key you hold while you click to add a cursor. |
| `editor.autoClosingBrackets` | boolean | `true` |  | Close Brackets |
| `editor.autoClosingQuotes` | boolean | `true` |  | Close Quotes |
| `editor.linkedEditing` | boolean | `false` |  | Rename Matching Tags Together |
| `editor.quickSuggestions` | boolean | `false` |  | Suggest While Typing |
| `editor.wordBasedSuggestions` | boolean | `true` |  | Suggest Words from the File |
| `editor.acceptSuggestionOnEnter` | string | `"on"` | `on`, `smart`, `off` | Return Accepts a Suggestion |
| `editor.emptySelectionClipboard` | boolean | `true` |  | Copy the Line When Nothing Is Selected |
| `editor.find.seedSearchStringFromSelection` | string | `"always"` | `always`, `selection`, `never` | Find Starts With |
| `editor.autoSave` | string | `"afterDelay"` | `afterDelay`, `off` | Save Automatically |
| `editor.autoSaveDelay` | real | `1000` | 100 to 60000 | Pause Before Saving |
| `editor.trimTrailingWhitespace` | boolean | `false` |  | Remove Trailing Spaces on Save |
| `editor.insertFinalNewline` | boolean | `false` |  | End Files with a Newline on Save |
| `editor.formatOnSave` | boolean | `false` |  | Format on Save. Runs the language's formatter when one is installed. |
| `editor.importFrom` | string | `"auto"` | `auto`, `vscode`, `cursor`, `windsurf`, `vscodium`, `zed`, `none` | Take Defaults From. cmux reads that editor's settings and keybindings, never changing them. |
| `appearance.sidebarSurface` | string | `"same"` | `same`, `separate` | Sidebar Background. Separate shades the sidebar darker than the main pane. |
| `sidebar.border` | boolean | `false` |  | Border. A line on the sidebar's edge. Off, the edge shows a line only while you hover or drag it. |
| `sidebar.borderWidth` | real |  | 0.5 to 4 | Border Width |
| `sidebar.sectionLook` | string | `"quiet"` | `quiet`, `card`, `tray`, `lines`, `linesIcons` | Section Look. How the sections above and below the workspace list draw. |
| `sidebar.topBandMaxShare` | real | `0.3333333333333333` | 0.1 to 0.9 | Top Sections Height. The share of the sidebar the top sections fill before they scroll. |
| `sidebar.bottomBandMaxShare` | real | `0.25` | 0.1 to 0.9 | Bottom Sections Height. The share of the sidebar the bottom sections fill before they scroll. |
| `sidebar.pinnedBandsScroll` | boolean | `true` |  | Scroll Tall Sections. Off: the top and bottom sections never scroll and the workspace list gets smaller. |
| `sidebar.showChats` | boolean | `true` |  | Show All Chats on New Tab. New Tab lists every agent chat on this computer, not only recent ones. |
| `sidebar.sessionTree` | boolean | `false` |  | Session Tree. Lists workspaces an agent started under the workspace that started them. |
| `sidebar.showProjects` | boolean | `true` |  | Show Projects |
| `sidebar.groupBy` | string | `"none"` | `none`, `folder`, `recents` | Group Projects By |
| `sidebar.nav` | array | `[]` |  | Sidebar Nav Rows. Rows at the top of the sidebar that run cmux actions, by action id, optionally "id \| Title \| symbol". Empty shows none. |
| `sidebar.showSpaces` | boolean | `false` |  | Show Spaces. Spaces show once you have more than one. New Space is in the command palette. |
| `sidebar.showProfileControl` | boolean | `true` |  | Show Profile Button |
| `sidebar.showSearchButton` | boolean | `false` |  | Show Search Button. A search button after the profile button. Off: search from the palette. |
| `sidebar.showNewWorkspaceChooser` | boolean | `false` |  | Show New Workspace Menu Button. A chevron beside the + opens the New Workspace menu. Off: right-click the +. |
| `sidebar.workspacesAsTabs` | boolean | `false` |  | Workspaces as Tabs. Each workspace is one line, and Cmd-Shift-[ and ] switch workspaces. |
| `sidebar.chromeGroups` | boolean | `false` |  | Chrome-Style Groups. Groups get a colored rail with a rounded end, like Chrome's tab groups. |
| `sidebar.sideBySide` | boolean | `false` |  | Workspaces Side by Side. Drag a workspace row onto a pane's edge to show it beside the current one. |
| `sidebar.noFade` | boolean | `false` |  | Show Whole Sidebar Without Fade. Stops the sidebar's edges fading and hides the bottom profile and search bar. |
| `sidebar.controlsOnHover` | boolean | `false` |  | Show Sidebar Controls Only on Hover. The sidebar's buttons show only while the pointer is over it. |
| `sidebar.floatOnHover` | boolean | `true` |  | Float Hidden Sidebar on Hover. With the sidebar hidden, point at the window's edge to show it over your work. |
| `sidebar.minimal` | boolean | `false` |  | Minimal Mode. Sidebar and tab bar buttons show only while the pointer is over them. |
| `sidebar.look` | string | `"cmux"` | `cmux`, `claude`, `codex`, `studio` | Sidebar Look. Rows, headers and status marks like another app's sidebar. Your own sidebar settings still win. |
| `sidebar.style` | string | `"standard"` | `standard`, `rail` | Sidebar Style. Rail shrinks the sidebar to a strip; point at it to open the full sidebar. |
| `sidebar.density` | string | `"compact"` | `compact`, `comfortable`, `expanded` | Sidebar Density. Expanded shows status, age, pull request and computer under each name. |
| `sidebar.textSize` | string | `"default"` | `default`, `large`, `larger` | Sidebar Text Size. Makes the sidebar's names, icons and rows larger together. |
| `sidebar.detailedStatusIcons` | boolean | `false` |  | Detailed Status Icons. Icons for working, waiting, error and done. Off: a spinner and a dot. |
| `sidebar.showTimestamps` | boolean | `false` |  | Show Timestamps. Rows show when they last changed, such as 3d. |
| `sidebar.settleFinished` | boolean | `false` |  | Settle Finished Chats. A chat whose answer you have read folds into Settled at the end of its list until its next turn. |
| `sidebar.showAutomaticSessions` | boolean | `false` |  | Show Automatic Sessions. Sessions that scripts and tools start show in place. Off, they wait in Automatic at the end of their list. |
| `sidebar.showColors` | boolean | `true` |  | Show Workspace Colors |
| `workspaceColors.indicatorStyle` | string | `"leftRail"` | `dot`, `leftRail`, `fill` | Workspace Color Style. How a workspace's color shows in the sidebar. |
| `sidebar.showLocalMachine` | boolean | `false` |  | Mark This Mac's Workspaces. With more than one computer, this Mac's workspaces show its icon too. |
| `sidebar.groupHeader.memberCount` | boolean | `false` |  | Show Group Member Count. A collapsed group shows how many workspaces it holds. |
| `sidebar.groupHeader.unreadCount` | boolean | `false` |  | Show Group Unread Count. A collapsed group shows its unread notification count. |
| `sidebar.groupHeader.background` | string | `"folder"` | `folder`, `auto`, `glass`, `solid`, `sections` | Group Background. How a group draws. Folders shows plain folders; Sections shows plain headings. |
| `sidebar.groupPalette` | string | `"glass"` | `glass`, `theme`, `wallpaper`, `grayscale`, `vibrant`, `gradient`, `pictorial` | Group Colors. Where group colors come from. A color you pick for a group stays. |
| `sidebar.groupGradient` | string | `"sunset"` | `sunset`, `aurora`, `lagoon`, `twoTone` | Group Gradient. The gradient Group Colors uses when set to Gradient. |
| `sidebar.minimalMode` | string | `"off"` | `off`, `bottom`, `top`, `both` | Hide Bands Until Hover. Hides the chosen sections until the pointer is over the sidebar. |
| `sidebar.cards.tips` | boolean | `false` |  | Show Tips. A daily card shows one cmux feature you have not used yet. |
| `sidebar.priorityView.enabled` | boolean | `false` |  | Priority View. A bell listing every agent chat, the ones waiting on you first. |
| `sidebar.priorityView.shown` | boolean | `true` |  | Show Priority View. The sidebar bell's state while the Priority view is on. Off, the sidebar is unchanged. |
| `sidebar.side` | string | `"left"` | `left`, `right` | Sidebar Side. On the right, the window buttons sit over the tab bar. |
| `sidebar.spacesPosition` | string | `"bottom"` | `top`, `bottom` | Spaces Position. Under the window buttons or above the Settings row. |
| `sidebar.spacesVisibility` | string | `"hover"` | `hover`, `always` | Show Spaces. On Hover hides the spaces with the other sidebar controls. |
| `tabs.commandDigits` | string | `"workspaces"` | `workspaces`, `tabs` | Command-1 to 9 Select. Control-1 to 9 selects the other one. |
| `sidebar.numbering` | string | `"allItems"` | `allItems`, `workspacesOnly` | Command-Number Shortcuts. Every Item: Home is Command-1. Workspaces Only: the first workspace is Command-1. |
| `sidebar.cmd9` | string | `"last"` | `last`, `ninth` | Command-9. Goes to the last item, as in browsers, or to the ninth. |
| `sidebar.stepping` | string | `"allItems"` | `allItems`, `workspacesOnly` | Next and Previous Item. What Command-Control-] and Command-Control-[ step through. |
| `sidebar.steppingWraps` | boolean | `true` |  | Wrap Around. Past the last item, the next item is the first again. |
| `sidebar.hoverCards.enabled` | boolean | `true` |  | Show Hover Cards. A card with details opens when the pointer rests on a workspace or a tab. |
| `sidebar.hoverCards.delay` | real | `1300` | 0 to 5000 | Hover Card Delay. How long the pointer rests before a card opens. |
| `sidebar.hoverCards.layout` | string | `"compact"` | `timeline`, `compact`, `log`, `classic`, `minimal` | Workspace Card Layout. What a workspace's hover card shows. |
| `sidebar.hoverCards.sections.timings` | boolean | `true` |  | Show Running Times in Workspace Cards. How long the workspace has worked or waited, and how long its command has run. |
| `sidebar.hoverCards.sections.prompts` | boolean | `true` |  | Show Prompts in Workspace Cards. Each prompt you sent and when, in the card's history. |
| `sidebar.hoverCards.sections.waiting` | boolean | `true` |  | Show Waits in Workspace Cards. When an agent waited for your input or finished its turn, in the card's history. |
| `sidebar.hoverCards.sections.git` | boolean | `true` |  | Show Branch in Workspace Cards. The workspace's branch and pull request. |
| `sidebar.hoverCards.sections.ports` | boolean | `true` |  | Show Ports in Workspace Cards. The ports the workspace listens on. |
| `sidebar.hoverCards.maxRows` | real | `20` | 1 to 100 | Workspace Card History Lines. The most prompts, waits and finished turns a workspace's card lists. The list scrolls. |
| `sidebar.hoverCards.groups.workspaceGroups` | boolean | `true` |  | Cards on Workspace Groups. A summary card opens when the pointer rests on a workspace group's header. |
| `sidebar.hoverCards.groups.tabGroups` | boolean | `true` |  | Cards on Tab Groups. A summary card opens when the pointer rests on a tab group's chip. |
| `sidebar.hoverCards.groups.delay` | real | `1300` | 0 to 5000 | Group Card Delay. How long the pointer rests on a group before its summary card opens. |
| `sidebar.hoverCards.groups.order` | string | `"status"` | `status`, `members`, `activity` | Group Card Leads With. Which part of a group's card comes first. |
| `sidebar.hoverCards.groups.maxMembers` | real | `8` | 1 to 50 | Group Card Members. The most members a group's card lists by name. |
| `sidebar.hoverCards.groups.sections.status` | boolean | `true` |  | Group Card: Status. Show how many members work, wait, failed or have unread items. |
| `sidebar.hoverCards.groups.sections.members` | boolean | `true` |  | Group Card: Members. Show the member count and the members' names. |
| `sidebar.hoverCards.groups.sections.activity` | boolean | `true` |  | Group Card: Latest Activity. Show the member that changed last, and when. |
| `sidebar.hoverCards.groups.sections.git` | boolean | `true` |  | Group Card: Branches. Show the members' git branches. |
| `sidebar.hoverCards.groups.sections.ports` | boolean | `true` |  | Group Card: Ports. Show the members' listening ports. |
| `sidebar.nowPlaying.enabled` | boolean | `false` |  | Show Now Playing. A player for what is playing, at the bottom of the sidebar. |
| `sidebar.nowPlaying.otherApps` | boolean | `false` |  | Include Other Apps in Now Playing. Also shows what plays in apps like Spotify or Music. |
| `tabs.newTabNowPlaying` | boolean | `false` |  | Show Now Playing on New Tab. A player for what is playing, on the New Tab page. |
| `media.pictureInPicture.enabled` | boolean | `true` |  | Picture in Picture. Offer Picture in Picture for web videos. |
| `appearance.colorTransition.enabled` | boolean | `true` |  | Animate Color Changes. Old colors blend into new ones on workspace and theme changes. |
| `appearance.colorTransition.duration` | real | `200` | 0 to 2000 | Color Change Duration. How long a color change takes. 0 changes colors at once. |
| `appearance.colorTransition.curve` | string | `"easeOut"` | `easeOut`, `easeInOut`, `linear`, `spring`, `cubicBezier` | Color Change Curve. How a color change moves over its duration. |
| `appearance.colorTransition.springResponse` | real | `0.3` | 0.05 to 2 | Spring Response. Seconds a spring color change takes to reach its new colors. |
| `appearance.colorTransition.springDamping` | real | `1` | 0.1 to 2 | Spring Damping. 1 arrives smoothly with no overshoot. Above 1 is slower; below 1 arrives sooner. |
| `appearance.colorTransition.bezierX1` | real | `0.42` | 0 to 1 | Bezier X1. A control point of the Custom (Bezier) curve, as in CSS cubic-bezier(). |
| `appearance.colorTransition.bezierY1` | real | `0` | -1 to 2 | Bezier Y1. A control point of the Custom (Bezier) curve, as in CSS cubic-bezier(). |
| `appearance.colorTransition.bezierX2` | real | `0.58` | 0 to 1 | Bezier X2. A control point of the Custom (Bezier) curve, as in CSS cubic-bezier(). |
| `appearance.colorTransition.bezierY2` | real | `1` | -1 to 2 | Bezier Y2. A control point of the Custom (Bezier) curve, as in CSS cubic-bezier(). |
| `appearance.colorTransition.colorSpace` | string | `"oklab"` | `oklab`, `srgb` | Color Blend Space. OKLab blends with even lightness. sRGB mixes the red, green and blue channels. |
| `appearance.colorTransition.reduceMotion` | string | `"crossfade"` | `crossfade`, `instant`, `full` | With Reduce Motion. What color changes do while Reduce Motion is on in macOS. |
| `sidebar.workspaceRow.icon` | boolean | `true` |  | Icon. The icon or emoji you chose for a workspace. |
| `sidebar.workspaceRow.directory` | boolean | `false` |  | Folder |
| `sidebar.workspaceRow.branch` | boolean | `false` |  | Git Branch |
| `sidebar.workspaceRow.process` | boolean | `false` |  | Running Program. The terminal's title, which the shell or program sets. |
| `sidebar.workspaceRow.agentStatus` | boolean | `false` |  | Agent Status. The status agents and hooks report, one line each. |
| `sidebar.workspaceRow.tabCount` | boolean | `false` |  | Tab Count |
| `sidebar.workspaceRow.ports` | boolean | `false` |  | Ports. Set by a hook: cmux workspace status set ports <text>. |
| `sidebar.workspaceRow.lastActivity` | boolean | `false` |  | Last Activity |
| `sidebar.workspaceRow.pullRequest` | boolean | `false` |  | Pull Request. Set by a hook: cmux workspace status set pr <text>. |
| `sidebar.workspaceRow.progress` | boolean | `true` |  | Progress. A progress bar under the row and the busy mark of running work. |
| `sidebar.workspaceRow.working` | boolean | `true` |  | Agent Working. A mark while an agent works in the workspace. |
| `sidebar.workspaceRow.log` | boolean | `false` |  | Log. The newest line agents and scripts log: cmux workspace log append <text>. |
| `sidebar.workspaceRow.notification` | boolean | `false` |  | Latest Notification. The text of the workspace's newest unread notification. |
| `sidebar.workspaceRow.secondLineOrder` | array | `["notification","directory","branch","process","agentStatus","ports","lastActivity"]` | `notification`, `directory`, `branch`, `process`, `agentStatus`, `ports`, `lastActivity` | Second Line Order. The order of the shown items under the workspace name. |
| `sidebar.workspaceRow.terminal.icon` | boolean |  |  | Icon |
| `sidebar.workspaceRow.terminal.directory` | boolean |  |  | Folder |
| `sidebar.workspaceRow.terminal.branch` | boolean |  |  | Git Branch |
| `sidebar.workspaceRow.terminal.process` | boolean |  |  | Running Program |
| `sidebar.workspaceRow.terminal.agentStatus` | boolean |  |  | Agent Status |
| `sidebar.workspaceRow.terminal.tabCount` | boolean |  |  | Tab Count |
| `sidebar.workspaceRow.terminal.ports` | boolean |  |  | Ports |
| `sidebar.workspaceRow.terminal.lastActivity` | boolean |  |  | Last Activity |
| `sidebar.workspaceRow.terminal.pullRequest` | boolean |  |  | Pull Request |
| `sidebar.workspaceRow.terminal.progress` | boolean |  |  | Progress |
| `sidebar.workspaceRow.terminal.working` | boolean |  |  | Agent Working |
| `sidebar.workspaceRow.terminal.log` | boolean |  |  | Log |
| `sidebar.workspaceRow.terminal.notification` | boolean |  |  | Latest Notification |
| `sidebar.workspaceRow.terminal.secondLineOrder` | array |  | `notification`, `directory`, `branch`, `process`, `agentStatus`, `ports`, `lastActivity` | Second Line Order |
| `sidebar.workspaceRow.agent.icon` | boolean |  |  | Icon |
| `sidebar.workspaceRow.agent.directory` | boolean |  |  | Folder |
| `sidebar.workspaceRow.agent.branch` | boolean |  |  | Git Branch |
| `sidebar.workspaceRow.agent.process` | boolean |  |  | Running Program |
| `sidebar.workspaceRow.agent.agentStatus` | boolean |  |  | Agent Status |
| `sidebar.workspaceRow.agent.tabCount` | boolean |  |  | Tab Count |
| `sidebar.workspaceRow.agent.ports` | boolean |  |  | Ports |
| `sidebar.workspaceRow.agent.lastActivity` | boolean |  |  | Last Activity |
| `sidebar.workspaceRow.agent.pullRequest` | boolean |  |  | Pull Request |
| `sidebar.workspaceRow.agent.progress` | boolean |  |  | Progress |
| `sidebar.workspaceRow.agent.working` | boolean |  |  | Agent Working |
| `sidebar.workspaceRow.agent.log` | boolean |  |  | Log |
| `sidebar.workspaceRow.agent.notification` | boolean |  |  | Latest Notification |
| `sidebar.workspaceRow.agent.secondLineOrder` | array |  | `notification`, `directory`, `branch`, `process`, `agentStatus`, `ports`, `lastActivity` | Second Line Order |
| `sidebar.workspaceRow.browser.icon` | boolean |  |  | Icon |
| `sidebar.workspaceRow.browser.directory` | boolean |  |  | Folder |
| `sidebar.workspaceRow.browser.branch` | boolean |  |  | Git Branch |
| `sidebar.workspaceRow.browser.process` | boolean |  |  | Running Program |
| `sidebar.workspaceRow.browser.agentStatus` | boolean |  |  | Agent Status |
| `sidebar.workspaceRow.browser.tabCount` | boolean |  |  | Tab Count |
| `sidebar.workspaceRow.browser.ports` | boolean |  |  | Ports |
| `sidebar.workspaceRow.browser.lastActivity` | boolean |  |  | Last Activity |
| `sidebar.workspaceRow.browser.pullRequest` | boolean |  |  | Pull Request |
| `sidebar.workspaceRow.browser.progress` | boolean |  |  | Progress |
| `sidebar.workspaceRow.browser.working` | boolean |  |  | Agent Working |
| `sidebar.workspaceRow.browser.log` | boolean |  |  | Log |
| `sidebar.workspaceRow.browser.notification` | boolean |  |  | Latest Notification |
| `sidebar.workspaceRow.browser.secondLineOrder` | array |  | `notification`, `directory`, `branch`, `process`, `agentStatus`, `ports`, `lastActivity` | Second Line Order |
| `sidebar.workspaceRow.mixed.icon` | boolean |  |  | Icon |
| `sidebar.workspaceRow.mixed.directory` | boolean |  |  | Folder |
| `sidebar.workspaceRow.mixed.branch` | boolean |  |  | Git Branch |
| `sidebar.workspaceRow.mixed.process` | boolean |  |  | Running Program |
| `sidebar.workspaceRow.mixed.agentStatus` | boolean |  |  | Agent Status |
| `sidebar.workspaceRow.mixed.tabCount` | boolean |  |  | Tab Count |
| `sidebar.workspaceRow.mixed.ports` | boolean |  |  | Ports |
| `sidebar.workspaceRow.mixed.lastActivity` | boolean |  |  | Last Activity |
| `sidebar.workspaceRow.mixed.pullRequest` | boolean |  |  | Pull Request |
| `sidebar.workspaceRow.mixed.progress` | boolean |  |  | Progress |
| `sidebar.workspaceRow.mixed.working` | boolean |  |  | Agent Working |
| `sidebar.workspaceRow.mixed.log` | boolean |  |  | Log |
| `sidebar.workspaceRow.mixed.notification` | boolean |  |  | Latest Notification |
| `sidebar.workspaceRow.mixed.secondLineOrder` | array |  | `notification`, `directory`, `branch`, `process`, `agentStatus`, `ports`, `lastActivity` | Second Line Order |
| `browser.toolbarButtons` | array | `["media","zoom","downloads"]` | `media`, `zoom`, `favorites`, `downloads`, `designMode`, `profile`, `theme`, `devTools` | Toolbar Buttons. The rest are in the More menu. |
| `browser.showLoadingBar` | boolean | `false` |  | Show Loading Bar. A thin line under the address bar while a page loads. |
| `browser.defaultEngine` | string | `"chromium"` | `chromium`, `webkit` | Browser Engine. Browser tabs and cmux pages, such as History and Apps, open in this engine. |
| `browser.siteEngines` | dictionary | `{"amazon.com/gp/video":"webkit","disneyplus.com":"webkit","hulu.com":"webkit","max.com":"webkit","music.apple.com":"webkit","netflix.com":"webkit","primevideo.com":"webkit","spotify.com":"webkit","tv.apple.com":"webkit"}` |  | Site Engines. Sites that always open in chromium or webkit, such as spotify.com. |
| `browser.newTabPage` | string | `""` |  | New Tab Page. An address such as https://example.com. Empty opens a blank page. |
| `browser.showBookmarksBar` | boolean | `false` |  | Show Bookmarks Bar. A row of bookmarks under each browser toolbar. |
| `browser.import.enabled` | boolean | `true` |  | Import from Other Browsers. Offers to import bookmarks, history, passwords and sign-ins. Off hides the offers. |
| `browser.import.cookieBanner` | boolean | `true` |  | Offer to Import Cookies. Browser tabs offer to import cookies from your other browsers. |
| `browser.import.cookieSync` | boolean | `true` |  | Keep Imported Cookies in Sync. Brings over changed cookies from the browser you imported from. Stays on this Mac. |
| `browser.showAgentCursor` | boolean | `true` |  | Show Agent Cursor. Shows an agent's cursor, clicks and typing in browser tabs. Passwords show dots. |
| `browser.agentMouse.motion` | string | `"human"` | `human`, `instant` | Agent Pointer Motion. Human moves along a curve and pauses before clicks; Instant jumps. |
| `browser.agentMouse.maxMoveMs` | real | `350` | 60 to 1000 | Longest Agent Pointer Move. The longest time one agent pointer move takes with human motion. Short moves take less. |
| `browser.builtInAdBlocker` | boolean | `true` |  | Built-in uBlock Origin. Blocks ads and trackers in Chromium tabs. Takes effect after cmux restarts. |
| `browser.hibernation` | string |  | `moderate`, `aggressive`, `off` | Hibernate Hidden Tabs. Frees memory; history and position are kept. Also accepts a number from 1 to 1440 in a raw profile. |
| `browser.hibernationExclusions` | array | `[]` |  | Never Hibernate. Hosts such as mail.google.com or *.example.com. |
| `browser.hibernatePinnedTabs` | boolean | `false` |  | Hibernate Pinned Tabs |
| `browser.freezeHiddenTabs` | string | `30` | `off` | Freeze Hidden Tabs. A hidden Chromium tab stops running until you show it, to save power. Also accepts a number from 5 to 3600 in a raw profile. |
| `browser.keepNeighborTabsAwake` | real | `1` | 0 to 3 | Keep Neighbor Tabs Awake. Tabs beside the shown one stay loaded so switching is instant. 0 turns it off. |
| `browser.wakeTabsOnHover` | boolean | `false` |  | Wake Tabs on Hover. Sleeping pages start loading when the pointer rests on their tab. Uses more memory. |
| `browser.remoteLocalhost` | boolean | `true` |  | Open localhost on the Workspace's Machine |
| `browser.searchEngine` | string | `"google"` | `google`, `duckduckgo`, `bing`, `brave`, `kagi`, `custom` | Search Engine. The address bar searches here and asks it for suggestions. |
| `browser.customSearchEngine.search` | string | `""` |  | Custom Search Address. Used when Search Engine is Custom. Put {searchTerms} where the typed text goes. |
| `browser.customSearchEngine.suggest` | string | `""` |  | Custom Suggestions Address. An OpenSearch suggestions URL, with {searchTerms} for the typed text. |
| `browser.omnibar.remoteSuggestions` | boolean | `true` |  | Search Suggestions. Sends what you type to the search engine. Never addresses, files or local hosts. |
| `browser.omnibar.inlineAutocomplete` | boolean | `true` |  | Complete Addresses Inline. Completes a site you typed before or visit often. |
| `browser.omnibar.maxRows` | real | `6` | 3 to 15 | Suggestions Shown |
| `browser.omnibar.calculator` | boolean | `true` |  | Calculator Answers. Shows the answer to arithmetic you type. Return copies it. |
| `browser.omnibar.showFullURLs` | boolean | `false` |  | Always Show Full URLs. Shows the whole address, with https:// and www., when you are not editing it. |
| `browser.omnibar.glass` | string | `"off"` | `transparent`, `regular`, `clear`, `off` | Address Bar Glass |
| `browser.omnibar.glassTint` | string | `"background"` | `background`, `accent`, `none` | Glass Tint. The color over the glass, from the terminal theme. |
| `browser.omnibar.glassTintStrength` | real | `0.35` | 0 to 1 | Tint Strength |
| `browser.omnibar.cornerRadius` | string | `"theme"` | `theme`, `capsule` | Address Bar Corners. Match Theme uses the standard bar radius. Capsule rounds the ends fully. Also accepts a number from 0 to 16 in a raw profile. |
| `browser.omnibar.shadow` | boolean | `false` |  | Address Bar Shadow. A soft shadow under the glass address bar. |
| `browser.omnibar.backgroundOpacity` | real | `0` | 0 to 1 | Address Bar Opacity. How much the address bar covers a see-through window. |
| `browser.omnibar.height` | string | `"density"` | `density` | Address Bar Height. Match Density follows the density. The bar always grows to fit its text. Also accepts a number from 20 to 56 in a raw profile. |
| `browser.omnibar.fontSize` | string | `"density"` | `density` | Address Bar Text Size. The size of the address and the suggestions. Match Density follows the density. Also accepts a number from 10 to 24 in a raw profile. |
| `browser.links.cmdClick` | string | `"linkPlacement"` | `linkPlacement`, `backgroundTab`, `foregroundTab`, `newWindow`, `currentTab`, `download` | Command-Click. In Chromium tabs, Download keeps Chrome's default. |
| `browser.links.cmdShiftClick` | string | `"foregroundTab"` | `linkPlacement`, `backgroundTab`, `foregroundTab`, `newWindow`, `currentTab`, `download` | Shift-Command-Click. Shift-middle-click does the same. |
| `browser.links.shiftClick` | string | `"newWindow"` | `linkPlacement`, `backgroundTab`, `foregroundTab`, `newWindow`, `currentTab`, `download` | Shift-Click. In Chromium tabs, Download keeps Chrome's default. |
| `browser.links.optionClick` | string | `"download"` | `linkPlacement`, `backgroundTab`, `foregroundTab`, `newWindow`, `currentTab`, `download` | Option-Click. Chromium tabs always download. |
| `browser.links.middleClick` | string | `"backgroundTab"` | `linkPlacement`, `backgroundTab`, `foregroundTab`, `newWindow`, `currentTab`, `download` | Middle-Click. Chromium tabs use the Command-Click setting. |
| `browser.vimKeys` | boolean | `true` |  | Vim Keys in Pages. Outside text fields: f clicks a link, j and k scroll, gg and Shift-G jump to the ends. |
| `browser.enabled` | boolean | `true` |  | Enable cmux Browser. Off: every link opens in your default browser. |
| `browser.openLinksInCmuxBrowser` | boolean | `true` |  | Open Links in cmux Browser. Off: links open in your default browser. Shift-Cmd-click opens the other one. |
| `browser.openSignInPagesInCmux` | boolean | `true` |  | Open Sign-In Pages in cmux Browser. Sign-in pages open in cmux even when other links open in your default browser. |
| `browser.openPullRequestsInGitHubPage` | boolean | `false` |  | Open Pull Requests in cmux GitHub Page. Pull request links in agent chats open cmux's GitHub page. Off: github.com in a tab. |
| `browser.openTerminalLinksInCmuxBrowser` | boolean | `true` |  | Open Terminal Links in cmux Browser. When off, links clicked in terminal output open in your default browser. |
| `browser.hostsToOpenInEmbeddedBrowser` | array | `[]` |  | Hosts to Open in Embedded Browser. Only these hosts open in cmux, such as *.example.com. Empty opens all. |
| `browser.urlsToAlwaysOpenExternally` | array | `[]` |  | URLs to Always Open Externally. Text matches anywhere; * and ? are wildcards; re: starts a regular expression. |
| `files.textEditor` | string | `""` |  | Text Editor. An app name, bundle ID or app path. Empty uses your source code app. |
| `browser.passwords.offerToSave` | boolean | `true` |  | Offer to Save Passwords. A browser tab asks to save a sign-in you submit. Tabs an agent drives never ask. |
| `browser.passwords.generate` | boolean | `true` |  | Suggest Strong Passwords. Offers a generated password when a site asks for a new one, and saves it. |
| `browser.passwords.allowExport` | boolean | `false` |  | Allow Password Export. The Passwords page can export every password to a plain-text CSV, after Touch ID. |
| `browser.verificationAutofill.enabled` | boolean | `false` |  | Fill Codes from Verification Emails. Offers emailed codes on the sender's own site. Never filled without your click. |
| `browser.verificationAutofill.accounts` | array | `[]` |  | Email Accounts for Codes. Codes come only from these addresses. Mail is read on this Mac, never stored or sent. |
| `home.server` | string | `"hosted"` | `hosted` | Server. Self-hosted: a Tailscale MagicDNS address, such as http://mini.tail1234.ts.net:7320. Also accepts a dictionary {"selfHosted": "http(s)://host[:port]"} in a raw profile. |
| `home.chiefBubbleStyle` | string | `"imessage"` | `imessage`, `theme` | Bubble Style. iMessage: blue and gray. Theme: your theme's colors. |
| `home.feedInChief` | boolean | `true` |  | Show the Feed in Chief. Feed notices show among the Chief's messages. The Chief does not read them. |
| `home.bubbleColors.sent` | string |  |  | My Bubble Color. Right-click a chat and choose Chat Colors to set its own. |
| `home.bubbleColors.sentText` | string |  |  | My Text Color. Right-click a chat and choose Chat Colors to set its own. |
| `home.bubbleColors.received` | string |  |  | Their Bubble Color. Right-click a chat and choose Chat Colors to set its own. |
| `home.bubbleColors.receivedText` | string |  |  | Their Text Color. Right-click a chat and choose Chat Colors to set its own. |
| `home.attachments.keepLocation` | boolean | `false` |  | Keep Location in Photos and Videos. When off, location data is removed from photos and videos before they are attached. |
| `home.channelsEnabled` | boolean | `false` |  | Channels. Show Channels below Home in the sidebar. |
| `home.chiefPetEnabled` | boolean | `false` |  | Show Chief Pet. A small Chief over every app shows agent events. ⌃⌥⌘C opens its reply box. |
| `home.chiefPetMascot` | string | `"orb"` | `fox`, `machine`, `machine-cyan`, `machine-blue`, `moon`, `moon-blue`, `mochi`, `captain`, `sprout`, `bolt`, `fox-arctic`, `machine-violet`, `machine-gold`, `moon-rose`, `orb`, `orb-spark`, `orb-hood` | Character |
| `home.chiefDock.sidePanel` | boolean | `false` |  | Chief in Side Panel. Keeps the Chief docked beside every workspace. Cmd-I hides or shows it. |
| `home.chiefDock.edge` | string | `"left"` | `left`, `right`, `top`, `bottom` | Dock Edge. The window edge the Chief docks to. |
| `home.chiefPanel.style` | string | `"composeBar"` | `composeBar`, `pill`, `card`, `panel`, `bubble`, `seeThrough`, `seeThroughBar` | Floating Chief Style. How the Chief looks floating over a workspace. Drag any style by its grip. |
| `home.chiefDock.openBeside` | boolean | `false` |  | Show Chief When Opening Workspaces. Links in the Chief open their workspace with the Chief over it. Esc hides it. |
| `home.chiefEngine` | string | `"auto"` | `auto`, `local`, `hosted` | Engine. Auto uses this Mac's Chief while it runs, else the Hosted Chief. |
| `chief.reactionsCanWake` | boolean | `true` |  | Reactions Can Wake the Chief. A reaction on a Chief message can start a turn, such as ? on a question. |
| `chief.reactionClassifier.harness` | string | `""` |  | Reaction Classifier Harness. The agent that reads reactions, such as claude or codex. Empty uses the Chief's. |
| `chief.reactionClassifier.model` | string | `"claude-haiku-5-5"` |  | Reaction Classifier Model. The model that decides whether a reaction starts a turn. |
| `chief.reactionClassifier.prompt` | string | `""` |  | Reaction Classifier Instructions. What the classifier is told when it decides. Empty uses the built-in instructions. |
| `chief.permissionMode` | string | `"bypassPermissions"` | `bypassPermissions`, `auto`, `default` | Chief Permission Mode. How the Chief's own turns handle permissions. Bypass runs every command without asking. Auto lets a safety check decide each command. Manual refuses each change that would need approval. Applies from the next turn. |
| `chief.autoRouteSubagents` | boolean | `false` |  | Route Subagents to the Best Agent. The Chief picks each subagent's agent, such as Codex for code. Off: the Chief's own. |
| `chief.subagentSidebar` | string | `"auto"` | `auto`, `always`, `never` | Subagent Workspaces. Where subagent workspaces go: the sidebar or the collapsed Chief's group. |
| `chief.subagentSidebarShowWords` | array | `[]` |  | Sidebar for Tasks That Mention. Words that put a subagent in the sidebar, added to the built-in ones. |
| `chief.subagentSidebarHideWords` | array | `[]` |  | Chief's Workspaces for Tasks That Mention. Words that put a subagent in Chief's workspaces, added to the built-in ones. |
| `chief.subagentSidebarMinWords` | real | `50` | 0 to 1000 | Sidebar for Tasks Longer Than. Tasks with at least this many words go in the sidebar. |
| `notifications.dismissal` | string | `"focus"` | `keystroke`, `click`, `focus`, `explicit`, `timeout`, `never` | Clear Notification When |
| `notifications.timeoutSeconds` | real | `30` | 1 to 86400 | Timeout. Used when a source clears after a timeout. |
| `notifications.sources.agent.dismissal` | string |  | `keystroke`, `click`, `focus`, `explicit`, `timeout`, `never` | Agents |
| `notifications.sources.terminal.dismissal` | string |  | `keystroke`, `click`, `focus`, `explicit`, `timeout`, `never` | Terminal Programs |
| `notifications.sources.cli.dismissal` | string |  | `keystroke`, `click`, `focus`, `explicit`, `timeout`, `never` | cmux notify |
| `notifications.desktop` | string | `"unlessFocused"` | `unlessFocused`, `always`, `whenInactive`, `never` | macOS Banners |
| `notifications.sound` | string | `"default"` |  | Sound |
| `notifications.quietHours` | dictionary |  | `start`: HH:MM, `end`: HH:MM | Quiet Hours. No banners or sounds between these times. |
| `notifications.suppressWhileTypingSeconds` | real | `0` | 0 to 60 | Quiet After Typing. A pane typed into this recently is marked read at once. 0 turns it off. |
| `status.runNotifyMinimumSeconds` | real | `10` | 0 to 3600 | Notify When a Run Takes. cmux status run notifies when the command took at least this long. |
| `status.runNotifyWhenVisible` | boolean | `false` |  | Notify Even When the Terminal Is Visible |
| `notifications.dockBadge` | boolean | `true` |  | Unread Count on Dock Icon |
| `notifications.dockBounce` | string | `"once"` | `off`, `once`, `untilActive` | Bounce Dock Icon. When a notification alerts while cmux isn't the active app. |
| `notifications.showPreviews` | string | `"whenUnlocked"` | `always`, `whenUnlocked`, `never` | Show Message in Banners. Whether a banner shows what the agent said, or only where and what state. |
| `feed.mirrorNotifications.agents` | boolean | `true` |  | Copy Agent Notifications to the Feed. Agent and cmux notify notifications go to your feed and can reach your iPhone. |
| `feed.mirrorNotifications.terminal` | string | `"off"` | `off`, `title`, `full` | Copy Terminal Notifications to the Feed. Terminal notifications can contain secrets. Off sends nothing. |
| `feed.agentPermissionPrompts` | boolean | `false` |  | Send Agent Permission Requests to the Feed. Each request's tool and command summary goes to your own cmux feed, so your iPhone can answer it. |
| `feed.needsYouInChief` | boolean | `false` |  | Pin Needs You in Chief. Pins open requests and questions at the top of the Chief's chat. |
| `notifications.attention.style` | string | `"steady"` | `blink`, `pulse`, `steady`, `none` | Style |
| `notifications.attention.color` | string |  |  | Color |
| `notifications.attention.terminals` | string | `"glow"` | `glow`, `ring`, `none` | Ring Terminal Panes |
| `notifications.attention.agentChats` | string | `"none"` | `glow`, `ring`, `none` | Ring Agent Chat Panes. Ring an agent chat's pane when its turn ends, until you click or type in it. |
| `notifications.attention.agentChatBlinkCount` | real | `1` | 1 to 10 | Agent Chat Blinks |
| `notifications.attention.width` | real | `2` | 0.5 to 8 | Width |
| `notifications.attention.blinkCount` | real | `2` | 1 to 10 | Blinks |
| `notifications.attention.duration` | real | `3` | 0.3 to 30 | Pulse Duration |
| `notifications.attention.persist` | boolean | `true` |  | Keep Ring Until Read |
| `notifications.attention.flash` | boolean | `true` |  | Flash the Pane When Read. Clicking an unread pane, typing in it or jumping to it flashes its ring as it goes. |
| `notifications.attention.flashOnTyping` | boolean | `true` |  | Flash When Typing Reads It |
| `notifications.attention.showOnTab` | boolean | `true` |  | Mark the Tab |
| `notifications.attention.showOnSidebar` | boolean | `true` |  | Mark the Sidebar Row |
| `notifications.attention.mark` | string | `"badge"` | `badge`, `glow` | Needs You Look. How a tab and a sidebar row that wait for you show it: the badge, or a gentle glow until you look at them. |
| `notifications.attention.moveToTop` | boolean | `true` |  | Move the Workspace to the Top. A notification moves its workspace to the top, unless you are looking at it. |
| `notifications.attention.moveToTopOnAgentFinish` | boolean | `false` |  | Move the Workspace to the Top When Its Agent Finishes. Unless you are looking at its pane. |
| `notifications.mutedWorkspaces` | array | `[]` |  | Muted Workspaces. Workspace ids whose notifications are silent. Mute a workspace from its sidebar row menu. |
| `notifications.sounds.events.finished` | string |  |  | Agent Finished |
| `notifications.sounds.events.needsInput` | string |  |  | Agent Needs Input |
| `notifications.sounds.events.error` | string |  |  | Error |
| `notifications.sounds.events.bell` | string |  |  | Terminal Notification |
| `notifications.sounds.events.message` | string |  |  | cmux notify Message |
| `notifications.sounds.volume` | real | `1` | 0 to 1 | Volume. Sounds cmux plays itself. A banner's default sound follows the system alert volume. |
| `notifications.sounds.when` | string | `"unlessViewed"` | `unlessViewed`, `whenInactive`, `always` | Play Sounds |
| `notifications.sounds.cooldownSeconds` | real | `1.5` | 0 to 60 | Burst Cooldown. Many notifications at once sound once. 0 turns it off. |
| `notifications.sounds.workspaces` | dictionary | `{}` |  | Workspace Sounds. Sounds per workspace id. Set one from the workspace's sidebar menu. |
| `notifications.sounds.groups` | dictionary | `{}` |  | Group Sounds. Sounds per group id or name. Set one from the group's sidebar menu. |
| `notifications.sounds.agents` | dictionary | `{}` |  | Agent Sounds. Sounds per agent kind, such as claude or codex. |
| `notifications.delivery.permissionRequest` | string | `"banner"` | `off`, `badge`, `banner` | Permission Request |
| `notifications.delivery.question` | string | `"banner"` | `off`, `badge`, `banner` | Question |
| `notifications.delivery.taskComplete` | string | `"banner"` | `off`, `banner` | Task Complete |
| `labs.previewFeatures` | boolean | `false` |  | Show Preview Features. Unfinished surfaces, such as the App Store and the agent session's coverage label and Pull requests view. |
| `labs.liveTree` | boolean | `false` |  | Live Tree. Show the shared live-tree path and compile lanes in the agent pane. |
| `labs.voiceRoom` | boolean | `false` |  | Voice Room. While a room is open, cmux sends a transcript of your mic and your screen's text to it. |
| `labs.voiceRoomURL` | string | `""` |  | Voice Room Address. The room's web address. Empty uses the room server on this Mac. |
| `labs.machineJoin` | boolean | `false` |  | Screen Sharing for Joined Machines. Shows Screen sharing and Control in Settings > Devices once this Mac joins. |
| `labs.liveCode` | boolean | `false` |  | Live Code. Swift changes you compile apply to the running app. Takes effect after cmux restarts. |
| `labs.pauseAgentMachines` | boolean | `false` |  | Pause Agent Machines. Pause a new agent machine after 15 idle minutes; it resumes when work arrives. |
| `customize.fromTheApp` | boolean | `false` |  | Customize From the Window. Hold Option over a part of the window to see what changes it, and right-click it for Customize…. Turn this off to hide both. |
| `labs.agentCustomization` | boolean | `false` |  | Claude Code and Codex Customization. Show and edit the MCP servers, skills and commands Claude Code and Codex use, in their own config files. |
| `experiments.glassToolbarGroups` | boolean | `false` |  | Glass Toolbar Groups. The chat header's buttons become round glass buttons, with related actions sharing one glass capsule, a search chip and shortcut keycaps. |
| `experiments.composerV2` | boolean | `false` |  | Composer Refresh. A glass composer with mode chips, mention chips and a round send button. Still being shaped. |
| `experiments.agentBadges` | boolean | `false` |  | Agent Badges. Agent tabs show a count of unread messages and approvals, and sidebar rows show a status pill: Running, Needs approval or Done. |
| `experiments.agentBadgesBeam` | boolean | `false` |  | Agent Badges: Running Beam. With Agent Badges on, a thin light travels along a sidebar row's edge while its agent runs. |
| `experiments.toastsV2` | boolean | `false` |  | Toasts v2. Spinner toasts that turn into their result in place, and an Undo after closing a tab or workspace or archiving a chat. |
| `experiments.chatWidgets` | boolean | `false` |  | Extension Chat Widgets. Installed extensions can show a card under a finished tool call in agent chat. |
| `feed.github.enabled` | boolean | `false` |  | GitHub Inbox. Inbox shows your GitHub notifications |
| `feed.github.pollIntervalSeconds` | real | `120` | 60 to 900 | Refresh Interval. Seconds between GitHub refreshes. Refresh in the Inbox runs immediately. |
| `agentPane.links.outsideRoots` | string | `"open"` | `confirm`, `text`, `open` | Files Outside the Project. What a link to a file outside the chat's folders does. Keys and .env files never open. |
| `agentPane.links.openCitationsInEditor` | boolean | `false` |  | Open File Citations in Text Editor. Open local chat links that name a line in your chosen text editor. |
| `agentPane.images.remote` | string | `"click"` | `click`, `never`, `always` | Web Images in Replies. A web image loads from its site, which then sees that you read the reply. |
| `agentPane.needsYou.enabled` | boolean | `false` |  | Needs You. A badge in the chat header counts what your agents wait on. |
| `agentPane.editedFiles.show` | string | `"always"` | `always`, `collapsed`, `never` | Edited Files Card. The card that lists a turn's edited files, with Undo and View changes. |
| `agentPane.editedFiles.maxRows` | real | `3` | 1 to 50 | Edited Files Shown |
| `agentPane.editedFiles.scope` | string | `"turn"` | `turn`, `session` | Edited Files Card Covers |
| `agentPane.showContextUsage` | boolean | `true` |  | Show Context Usage. The ring beside the model that fills as the chat uses its context window. |
| `agentPane.composerRing` | string | `"context"` | `context`, `planUsage` | Composer Ring. What the ring at the end of the composer shows. |
| `agentPane.showDictation` | boolean | `true` |  | Show Dictation Button. The microphone beside Send in every composer, including the New Tab page. |
| `agentPane.dictationSource` | string | `"cmux"` | `cmux`, `macos`, `chatgpt`, `claude`, `gemini`, `wisprFlow`, `superwhisper` | Dictate With |
| `agentPane.dictationShortcut` | string | `""` |  | Dictation App Shortcut. The shortcut sent to your dictation app. Empty uses the app's default. |
| `agentPane.spellChecking` | boolean | `false` |  | Check Spelling While Typing. Underlines misspellings and offers system suggestions in the composer. |
| `agentPane.attachmentView` | string | `"inline"` | `inline`, `strip`, `both` | Attachment View. How pictures and files show in the composer and in sent messages. |
| `agentPane.scrollToBottomOnSend` | boolean | `true` |  | Scroll to Bottom When I Send. When off, sending while you are reading up keeps your place and shows new messages below. |
| `agentPane.showMachineLoadWarnings` | boolean | `true` |  | Show Machine Load Warnings. Shows a warning when a remote machine is at its CPU or memory budget in the Computer menu. |
| `agentPane.newChatsIn` | string | `"local"` | `local`, `cloud` | Start New Chats In. Cloud copies your project to your Cloud machine. A chat's composer can change it. |
| `agentPane.sessionWorktrees` | string | `"off"` | `off`, `shared`, `project` | Session Worktrees. Choose where to keep worktrees for local chats and forks. |
| `agentPane.zoom` | real | `1` | 0.5 to 2 | Agent Chat Zoom. The display size for agent chat. Cmd-0 resets it. |
| `agents.defaultPermissionMode` | string | `"fullAccess"` | `fullAccess`, `standard`, `ask` | Permission Mode for New Chats. What a new chat may do without asking. A mode you pick in a chat applies to that chat only. |
| `agents.promptCache` | string | `"1h"` | `1h`, `5m` | Prompt Cache. One hour keeps replies after a pause cheap; its cache writes cost a little more. |
| `agents.modelRouter.model` | string | `"deepseek/deepseek-v4.1-flash-1017"` | `deepseek/deepseek-v4.1-flash-1017`, `deepseek/deepseek-v4.1-flash`, `deepseek/deepseek-v4-flash`, `deepseek/deepseek-v4-pro` | cmux Model Router Model. The model new cmux model router chats start on. |
| `agents.cmuxMcp` | string | `"ask"` | `ask`, `on`, `off` | cmux Tools for Agents in cmux. Agents you start in cmux get cmux’s tools, Computer Use included: Claude Code and Codex in cmux’s terminals and agent chats. Until you choose, they get nothing. cmux never changes your agents’ own settings. |
| `diagnostics.hangReports` | boolean | `false` |  | Send Hang Reports. Nightly builds send daily hang stacks and timings, never your files, URLs or text. |
| `diagnostics.usagePatterns` | boolean | `false` |  | Record Usage Patterns. Counts how you use cmux on this Mac. Nothing you type is recorded; nothing is sent. |
| `developerTools.appPages` | boolean | `true` |  | Developer Tools for cmux Pages. Inspect Element and ⌥⌘I in chats, Home, Markdown and Settings. |
| `app.internalDeveloperMode` | boolean | `false` |  | Internal Developer Mode. Shows "Debug: …" commands in the Command Palette. |
| `macScreen.systemShortcuts` | boolean | `false` |  | Send System Shortcuts to the Remote Mac. Shortcuts like ⌘Tab and ⌘Space go to the other Mac. Needs Accessibility. |
| `macScreen.shareWithoutAsking` | boolean | `false` |  | Share This Mac Without Asking. Your own cmux CLI, agents and devices turn sharing on with no sheet. Each device's access still applies. |
| `macScreen.debug.relayOnly` | boolean | `false` |  | Relay Only. Mac Screen tabs connect only through the relay, to test it. |
| `remote.endSharingOnQuit` | boolean | `false` |  | End Sharing When cmux Quits. Off: this Mac stays available to your devices while cmux is quit. |
| `remote.ultra` | string | `"auto"` | `off`, `auto`, `always` | Ultra Connection Mode. Sends repair data so lossy networks stay fast. Always uses 2 to 3 times the data. |
| `remote.screenSharingProfile` | string | `"balanced"` | `balanced`, `ultra` | Screen Sharing Profile. Ultra spends the link on a fast direct connection when viewing another Mac: up to 120 fps, up to 150 Mbps, near-lossless text. Balanced is the default. Not Ultra Connection Mode, which repairs a lossy network. |
| `deviceHub.url` | string | `""` |  | Device Hub Address. The device hub for Mac Screen sharing. Empty uses the built-in one. |
| `contextMenus.showCustomizeItem` | boolean | `false` |  | Show Customize Menu…. Adds Customize Menu… to the end of every right-click menu. |
| `imessage.enabled` | boolean | `false` |  | Connect iMessage. Lets cmux read Messages conversations on this Mac. Sending needs your click. |
| `imessage.automationSkipped` | boolean | `false` |  | Skip Messages Automation. Remembers that you skipped the Messages Automation step. |
| `EnrollmentToken` | string |  |  | Team enrollment token from the cmux dashboard. Signed-in users in a verified domain of the team join it; the token alone never grants membership. |
| `ManagedTeam` | string |  |  | Team id (team_...) that manages this device. |
| `RestrictToManagedTeam` | boolean |  |  | Refuse sign-in to any team other than ManagedTeam on this device. |
| `DisabledFeatures` | array |  | `computerUse`, `browserAutomation`, `mcp`, `cloud`, `apps`, `remoteHosts` | Features to turn off: their UI, actions and host operations are removed. |
| `UpdateChannel` | string |  | `stable`, `nightly` | Update channel this device follows. |
| `MinimumVersion` | string |  |  | Oldest cmux version allowed to sign in, for example 1.2.0. |
| `AllowedSignInMethods` | array |  | `sso`, `password`, `oauth` | Sign-in methods the app offers. |
| `DisableAutoUpdate` | boolean |  |  | Turn off automatic updates (also honored in the legacy com.cmuxterm.app domain). |
| `DisableTelemetry` | boolean |  |  | Turn off anonymous telemetry, crash reports included, whatever the user chose (also honored in the legacy com.cmuxterm.app domain). |
| `ComputerUseActsAsPerson` | boolean |  |  | Computer use can act as me: clicks and key presses computer use makes in a chat count as the person's for Send, Retry and Approve, and nothing else. Off by default. Honored only as a forced value from an installed profile; the person can still turn it off until cmux restarts, and every action it lets through is logged. |
