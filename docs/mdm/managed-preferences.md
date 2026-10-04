# cmux managed preferences

Generated from the cmux settings catalog by `ManagedPreferencesManifest` (CmuxNextSettings). Do not edit by hand; run `CMUX_UPDATE_MDM_SCHEMA=1 swift test --filter ManagedPreferencesManifestTests` in `Packages/macOS/CmuxNext`.

Domain: `com.manaflow.cmux` for every channel (stable, NIGHTLY, DEV). A forced value (any MDM custom settings payload) locks the setting and Settings shows "Managed by your organization". A non-forced value replaces the default and the user can still change it. Precedence, highest first: MDM forced, team policy enforced, the user's cmux.json, MDM non-forced, team policy default, product default.

The legacy forced key `DisableAutoUpdate` in `com.cmuxterm.app` keeps working.

Files: `com.manaflow.cmux.plist` (ProfileManifests: iMazing Profile Editor, ProfileCreator), `com.manaflow.cmux.json` (Jamf Pro custom schema), `cmux-example.mobileconfig` (any MDM), `com.manaflow.cmux.intune.plist` (Intune preference file).

| Key | Type | Default | Allowed values | Description |
| --- | --- | --- | --- | --- |
| `history.terminalCommands` | boolean | `false` |  | Record Terminal Commands. Lists finished shell commands in History. Command lines can contain secrets. |
| `navigation.historyScope` | string | `"workspace"` | `workspace`, `window`, `surface` | Back and Forward. What Go Back and Go Forward walk: places in this workspace, in this window, or the focused page's own history. |
| `window.titlebar` | string | `"minimal"` | `minimal`, `standard` | Titlebar. Minimal has no titlebar strip; the top row moves the window. |
| `window.titlebarButtons` | string | `"hover"` | `hover`, `always` | Titlebar Buttons. On Hover hides Back and Forward until the pointer is over the top row. The sidebar button always shows. |
| `tabs.newTabKind` | string | `"page"` | `same-kind`, `terminal`, `browser`, `agent`, `page`, `auto` | New Tab Opens. What Cmd-T and the + button open. Auto picks the kind you last opened in that folder. |
| `tabs.plusButton` | string | `"hover"` | `hover`, `always` | New Tab Button. On Hover shows each tab bar's + only while the pointer is over that tab bar. |
| `newTerminal.opensWorkspace` | boolean | `false` |  | New Terminal Opens a Workspace. Create a new workspace in the current space instead of a tab. Hold Option to reverse this for one click. |
| `app.quitBehavior` | string | `"ask"` | `ask`, `keep`, `end-keep-layout`, `end-everything` | When Quitting. Terminals run in cmux-tui and keep running after cmux quits unless you end them. |
| `layout.defaultColumnWidth` | real | `0.5` | 0.1 to 1 | Fixed Column Width. A share of the window width, for Fixed Width new columns. |
| `layout.centerFocusedColumn` | string | `"never"` | `never`, `always`, `on-overflow` | Center Focused Column |
| `layout.stripScrollbar` | string | `"auto"` | `auto`, `always`, `off` | Column Scroll Bar. A thin bar under the columns that shows and moves the visible range. |
| `layout.closeFocus` | string | `"previousNeighbor"` | `previousNeighbor`, `mostRecent` | Focus After Closing a Pane. Which pane gets focus when the focused pane closes. |
| `updates.checkAutomatically` | boolean | `true` |  | Check for Updates Automatically |
| `updates.checkIntervalSeconds` | real | `3600` | 900 to 604800 | Check Every |
| `updates.downloadAutomatically` | boolean | `true` |  | Download Updates Automatically. Off: a found update waits, and one click downloads and installs it. |
| `updates.installOnQuit` | boolean | `true` |  | Install Updates When Quitting. A downloaded update installs as cmux quits. Terminals keep running. |
| `updates.notify` | string | `"card"` | `card`, `badge`, `silent` | When an Update Is Ready |
| `updates.quietHours` | dictionary |  | `start`: HH:MM, `end`: HH:MM | Quiet Hours. No update card between these times. |
| `layout.splitSizing` | string | `"even"` | `even`, `halve` | Split Sizing. Even gives every pane in the column the same size after a split. |
| `layout.newColumnWidth` | string | `"matchCurrent"` | `matchCurrent`, `fitScreen`, `fixed` | New Column Sizing |
| `layout.dockColumnEdge` | string | `"nearest"` | `nearest`, `right`, `left`, `top`, `bottom` | Dock Column Edge |
| `layout.dockColumnMode` | string | `"docked"` | `docked`, `overlay` | Dock Column Mode |
| `layout.frameOrientation` | string | `"columnMajor"` | `columnMajor`, `rowMajor` | Dock Corners |
| `layout.rows` | boolean | `true` |  | Rows. Off hides New Row and fits a column's existing rows into it without scrolling. |
| `layout.minimumPaneWidth` | real | `200` | 80 to 800 | Minimum Pane Width |
| `layout.minimumPaneHeight` | real | `64` | 32 to 600 | Minimum Pane Height |
| `palette.scopes.tabs.prefix` | string | `"@"` | `@`, `#`, `>`, `,`, `?`, `!`, `/`, `;`, `:`, `%`, `&`, `+`, `=`, `~`, `$`, `^`, `*`, `.`, `none` | Tabs Prefix. Typed into an empty query, this character enters the scope. A prefix you assign moves from any other scope. |
| `palette.scopes.workspaces.prefix` | string | `"#"` | `@`, `#`, `>`, `,`, `?`, `!`, `/`, `;`, `:`, `%`, `&`, `+`, `=`, `~`, `$`, `^`, `*`, `.`, `none` | Workspaces Prefix. Typed into an empty query, this character enters the scope. A prefix you assign moves from any other scope. |
| `palette.scopes.commands.prefix` | string | `">"` | `@`, `#`, `>`, `,`, `?`, `!`, `/`, `;`, `:`, `%`, `&`, `+`, `=`, `~`, `$`, `^`, `*`, `.`, `none` | Commands Prefix. Typed into an empty query, this character enters the scope. A prefix you assign moves from any other scope. |
| `palette.scopes.settings.prefix` | string | `","` | `@`, `#`, `>`, `,`, `?`, `!`, `/`, `;`, `:`, `%`, `&`, `+`, `=`, `~`, `$`, `^`, `*`, `.`, `none` | Settings Prefix. Typed into an empty query, this character enters the scope. A prefix you assign moves from any other scope. |
| `palette.scopes.scopes.prefix` | string | `"?"` | `@`, `#`, `>`, `,`, `?`, `!`, `/`, `;`, `:`, `%`, `&`, `+`, `=`, `~`, `$`, `^`, `*`, `.`, `none` | Scope List Prefix. Typed into an empty query, this character enters the scope. A prefix you assign moves from any other scope. |
| `picker.pinned` | array | `[]` |  | Pinned Folders. The picker lists these folders under Locations, after Home and Downloads. Use full paths or ~/ paths. |
| `tasks.layout` | string | `"inbox"` | `list`, `board`, `inbox` | Tasks Layout. Inbox lists what needs you first, with the task beside it. Changes apply at once. |
| `appearance.theme` | string |  |  | Theme. Colors for cmux and its terminals. A space, workspace or terminal theme overrides it. |
| `appearance.backdropArt` | string | `"none"` | `none`, `wheat-field-with-cypresses`, `met-saint-catherine-436908`, `met-woman-man-casement-436896`, `met-women-picking-olives-436536`, `met-sunflowers-436524` | Backdrop Art. A public-domain painting behind the window material. Lower Opacity to reveal it. Attribution is linked above. |
| `appearance.background` | string | `"none"` | `none`, `wheat-field-with-cypresses`, `met-saint-catherine-436908`, `met-woman-man-casement-436896`, `met-women-picking-olives-436536`, `met-sunflowers-436524` | Background. Choose a bundled public-domain painting or a macOS system wallpaper behind the window material. |
| `appearance.experimentalControls` | boolean | `false` |  | Experimental Appearance Controls. Show the wallpaper grid and live appearance tuner while they are being integrated. |
| `appearance.backgroundOpacity` | real |  | 0 to 1 | Opacity. How much of the theme color covers the material behind the window. |
| `appearance.backgroundBlur` | string |  | `frosted`, `glass`, `glass-clear`, `none` | Material. Unset, the window follows Ghostty's background-opacity and background-blur. |
| `appearance.glassTransparency` | real | `0` | 0 to 1 | Glass Transparency. How much of the desktop or wallpaper shows through the glass. |
| `appearance.hue` | real | `0.5` | 0 to 1 | Hue. Shift the tint color around the hue wheel. |
| `appearance.saturation` | real | `1` | 0 to 2 | Saturation. Increase or reduce the tint color intensity. |
| `appearance.density` | string | `"compact"` | `compact`, `comfortable` | Density |
| `appearance.metrics.chromeFontSize` | real |  | 10 to 16 | Interface Size. Text size of tabs, the sidebar and other controls. Terminal text has its own size. |
| `appearance.borders` | string | `"default"` | `default`, `none` | Borders. None removes every border, hairline and separator in the app. |
| `appearance.focusIndicator` | string | `"both"` | `border`, `tabs`, `both`, `none` | Focused Pane. How the focused pane stands out: its border, subtler tabs in the other panes, both or neither. |
| `focus.inactiveTabStyle` | string | `"fade"` | `fade`, `tonal`, `quiet` | Unfocused Pane Tabs. How the other panes' tabs draw subtler when Focused Pane marks tabs: Fade dims them, Tonal steps their text down, Quiet drops the selected pill. |
| `ui.animationSpeed` | string | `"fast"` | `fast`, `normal`, `off` | Animations |
| `layout.paneSeparation` | string | `"borders"` | `none`, `dividers`, `borders`, `cards` | Separation. How panes are told apart. None draws no border or divider at all; dragging between panes still resizes them. |
| `layout.panePadding` | real |  | 0 to 16 | Padding |
| `layout.paneCornerRadius` | real |  | 0 to 20 | Corner Radius |
| `layout.paneBorder` | string | `"subtle"` | `subtle`, `none` | Border |
| `layout.paneBorderColor` | string |  |  | Border Color |
| `layout.paneBorderWidth` | real |  | 0.5 to 4 | Border Width |
| `focusRing.enabled` | boolean | `true` |  | Show Focus Ring |
| `focusRing.style` | string | `"ring"` | `ring`, `glow`, `none` | Style |
| `focusRing.contrast` | string | `"subtle"` | `subtle`, `standard`, `strong` | Contrast |
| `focusRing.color` | string |  |  | Color |
| `focusRing.width` | real | `1` | 0.5 to 8 | Width |
| `focusRing.showWhenSinglePane` | boolean | `false` |  | Show With One Pane |
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
| `appearance.statusIndicator.style` | string | `"arc"` | `arc`, `native`, `dot`, `braille`, `none` | Style. How sidebar rows, tabs and panes show work in progress. |
| `appearance.statusIndicator.size` | real | `1` | 0.5 to 1.5 | Size |
| `appearance.statusIndicator.thickness` | real | `1.5` | 0.5 to 4 | Line Width |
| `appearance.statusIndicator.color` | string |  |  | Color |
| `appearance.statusIndicator.honorStatusStyle` | boolean | `true` |  | Let Statuses Choose Their Style. A status that asks for a style (cmux status set --style) uses it. |
| `status.inferCommandBusy` | boolean | `true` |  | Show Running Commands. A shell command that runs a while shows as busy. |
| `status.inferCommandBusyAfter` | real | `3` | 0 to 600 | Show After |
| `terminal.fontFamily` | string |  |  | Font Family. A monospaced font installed on this Mac. |
| `terminal.fontSize` | real |  | 4 to 96 | Font Size |
| `sidebar.border` | boolean | `false` |  | Border. A line on the sidebar's edge. Off, the edge shows a line only while you hover or drag it. |
| `sidebar.borderWidth` | real |  | 0.5 to 4 | Border Width |
| `sidebar.sectionLook` | string | `"quiet"` | `quiet`, `card`, `tray`, `lines`, `linesIcons` | Section Look. How the sections above and below the workspace list draw. |
| `sidebar.topBandMaxShare` | real | `0.3333333333333333` | 0.1 to 0.9 | Top Sections Height. The share of the sidebar the top sections fill before they scroll. |
| `sidebar.bottomBandMaxShare` | real | `0.25` | 0.1 to 0.9 | Bottom Sections Height. The share of the sidebar the bottom sections fill before they scroll. |
| `sidebar.pinnedBandsScroll` | boolean | `true` |  | Scroll Tall Sections. Off: the top and bottom sections never scroll and the workspace list gets smaller. |
| `sidebar.showWorkspaceTabs` | boolean | `false` |  | Show Workspace Tabs. Lists tabs beneath each workspace in the sidebar. |
| `sidebar.minimalMode` | string | `"bottom"` | `off`, `bottom`, `top`, `both` | Minimal Mode. Hides the chosen sections until the pointer is over the sidebar. |
| `sidebar.side` | string | `"left"` | `left`, `right` | Sidebar Side. The window edge the sidebar sits on. On the right, the window buttons sit over the tab bar. |
| `sidebar.spacesPosition` | string | `"bottom"` | `top`, `bottom` | Spaces Position. Where the spaces dots sit in the sidebar: under the window buttons or above the Settings row. |
| `browser.defaultEngine` | string | `"chromium"` | `chromium`, `webkit` | Default Engine. New browser tabs open in this engine. |
| `browser.newTabPage` | string | `""` |  | New Tab Page. An address such as https://example.com. Empty opens a blank page. |
| `browser.showBookmarksBar` | boolean | `false` |  | Show Bookmarks Bar. A row of bookmarks under each browser toolbar. |
| `browser.hibernation` | string | `"moderate"` | `moderate`, `aggressive`, `off` | Hibernate Hidden Tabs. Frees memory; history and position are kept. Also accepts a number from 1 to 1440 in a raw profile. |
| `browser.hibernationExclusions` | array | `[]` |  | Never Hibernate. Hosts such as mail.google.com or *.example.com. |
| `browser.hibernatePinnedTabs` | boolean | `false` |  | Hibernate Pinned Tabs |
| `browser.remoteLocalhost` | boolean | `true` |  | Open localhost on the Workspace's Machine |
| `notifications.dismissal` | string | `"keystroke"` | `keystroke`, `click`, `focus`, `explicit`, `timeout`, `never` | Clear Notification When |
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
| `feed.mirrorNotifications.agents` | boolean | `true` |  | Copy Agent Notifications to the Feed. Notifications from agents and cmux notify go to your cmux account's feed and can reach your iPhone. |
| `feed.mirrorNotifications.terminal` | string | `"off"` | `off`, `title`, `full` | Copy Terminal Notifications to the Feed. Notifications that programs send through the terminal can contain secrets. Off sends nothing to your cmux account. |
| `notifications.attention.style` | string | `"blink"` | `blink`, `pulse`, `steady`, `none` | Style |
| `notifications.attention.color` | string |  |  | Color |
| `notifications.attention.width` | real | `2` | 0.5 to 8 | Width |
| `notifications.attention.blinkCount` | real | `2` | 1 to 10 | Blinks |
| `notifications.attention.duration` | real | `3` | 0.3 to 30 | Pulse Duration |
| `notifications.attention.persist` | boolean | `true` |  | Keep Ring Until Read |
| `notifications.attention.showOnTab` | boolean | `true` |  | Mark the Tab |
| `notifications.attention.showOnSidebar` | boolean | `true` |  | Mark the Sidebar Row |
| `labs.previewFeatures` | boolean | `false` |  | Show Preview Features. Unfinished surfaces, such as the agent session's coverage label and Pull requests view. |
| `feed.github.enabled` | boolean | `false` |  | Connect GitHub. Uses your gh login to read notifications and review requests on this Mac. Sign in with gh auth login first. |
| `feed.github.pollIntervalSeconds` | real | `120` | 60 to 900 | Refresh Interval. Seconds between GitHub refreshes. Refresh in the Inbox runs immediately. |
| `EnrollmentToken` | string |  |  | Team enrollment token from the cmux dashboard. Signed-in users in a verified domain of the team join it; the token alone never grants membership. |
| `ManagedTeam` | string |  |  | Team id (team_...) that manages this device. |
| `RestrictToManagedTeam` | boolean |  |  | Refuse sign-in to any team other than ManagedTeam on this device. |
| `DisabledFeatures` | array |  | `computerUse`, `browserAutomation`, `mcp`, `cloud`, `apps`, `remoteHosts` | Features to turn off: their UI, actions and host operations are removed. |
| `UpdateChannel` | string |  | `stable`, `nightly` | Update channel this device follows. |
| `MinimumVersion` | string |  |  | Oldest cmux version allowed to sign in, for example 1.2.0. |
| `AllowedSignInMethods` | array |  | `sso`, `password`, `oauth` | Sign-in methods the app offers. |
| `DisableAutoUpdate` | boolean |  |  | Turn off automatic updates (also honored in the legacy com.cmuxterm.app domain). |
