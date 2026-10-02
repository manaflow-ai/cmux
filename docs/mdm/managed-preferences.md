# cmux managed preferences

Generated from the cmux settings catalog by `ManagedPreferencesManifest` (CmuxNextSettings). Do not edit by hand; run `CMUX_UPDATE_MDM_SCHEMA=1 swift test --filter ManagedPreferencesManifestTests` in `Packages/macOS/CmuxNext`.

Domain: `com.manaflow.cmux` for every channel (stable, NIGHTLY, DEV). A forced value (any MDM custom settings payload) locks the setting and Settings shows "Managed by your organization". A non-forced value replaces the default and the user can still change it. Precedence, highest first: MDM forced, team policy enforced, the user's cmux.json, MDM non-forced, team policy default, product default.

The legacy forced key `DisableAutoUpdate` in `com.cmuxterm.app` keeps working.

Files: `com.manaflow.cmux.plist` (ProfileManifests: iMazing Profile Editor, ProfileCreator), `com.manaflow.cmux.json` (Jamf Pro custom schema), `cmux-example.mobileconfig` (any MDM), `com.manaflow.cmux.intune.plist` (Intune preference file).

| Key | Type | Default | Allowed values | Description |
| --- | --- | --- | --- | --- |
| `history.terminalCommands` | boolean | `false` |  | Record Terminal Commands. Lists finished shell commands in History. Command lines can contain secrets. |
| `window.titlebar` | string | `"minimal"` | `minimal`, `standard` | Titlebar. Minimal has no titlebar strip; the top row moves the window. |
| `window.rail` | string | `"off"` | `off`, `leading`, `afterSidebar` | Action Rail. A column of buttons for new tabs, agent chats, notifications, history and accounts. |
| `app.quitBehavior` | string | `"ask"` | `ask`, `keep`, `end-keep-layout`, `end-everything` | When Quitting. Terminals run in cmux-tui and keep running after cmux quits unless you end them. |
| `layout.defaultColumnWidth` | real | `0.5` | 0.1 to 1 | Fixed Column Width. A share of the window width, for Fixed Width new columns. |
| `layout.centerFocusedColumn` | string | `"never"` | `never`, `always`, `on-overflow` | Center Focused Column |
| `layout.stripScrollbar` | string | `"auto"` | `auto`, `always`, `off` | Column Scroll Bar. A thin bar under the columns that shows and moves the visible range. |
| `layout.closeFocus` | string | `"previousNeighbor"` | `previousNeighbor`, `mostRecent` | Focus After Closing a Pane. Which pane gets focus when the focused pane closes. |
| `layout.splitSizing` | string | `"even"` | `even`, `halve` | Split Sizing. Even gives every pane in the column the same size after a split. |
| `layout.newColumnWidth` | string | `"matchCurrent"` | `matchCurrent`, `fitScreen`, `fixed` | New Column Sizing |
| `layout.stickyColumnEdge` | string | `"right"` | `right`, `left` | Sticky Column Edge |
| `layout.stickyColumnMode` | string | `"docked"` | `docked`, `overlay` | Sticky Column Mode |
| `layout.frameOrientation` | string | `"columnMajor"` | `columnMajor`, `rowMajor` | Dock Corners |
| `layout.minimumPaneWidth` | real | `200` | 80 to 800 | Minimum Pane Width |
| `layout.minimumPaneHeight` | real | `64` | 32 to 600 | Minimum Pane Height |
| `appearance.density` | string | `"compact"` | `compact`, `comfortable` | Density |
| `appearance.borders` | string | `"default"` | `default`, `none` | Borders. None removes every border, hairline and separator in the app. |
| `appearance.focusIndicator` | string | `"both"` | `border`, `tabs`, `both`, `none` | Focused Pane. How the focused pane stands out: its border, subtler tabs in the other panes, both or neither. |
| `appearance.tabBarBackground` | string | `"window"` | `window`, `darker` | Tab Bar Background. Window uses the window's own background around the tabs; Darker shades the tab bar. |
| `ui.animationSpeed` | string | `"fast"` | `fast`, `normal`, `off` | Animations |
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
| `appearance.statusIndicator.style` | string | `"arc"` | `arc`, `native`, `dot`, `none` | Style. How sidebar rows, tabs and panes show work in progress. |
| `appearance.statusIndicator.size` | real | `1` | 0.5 to 1.5 | Size |
| `appearance.statusIndicator.thickness` | real | `1.5` | 0.5 to 4 | Line Width |
| `appearance.statusIndicator.color` | string |  |  | Color |
| `appearance.statusIndicator.honorStatusStyle` | boolean | `true` |  | Let Statuses Choose Their Style. A status that asks for a style (cmux status set --style) uses it. |
| `status.inferCommandBusy` | boolean | `true` |  | Show Running Commands. A shell command that runs a while shows as busy. |
| `status.inferCommandBusyAfter` | real | `3` | 0 to 600 | Show After |
| `sidebar.sectionLook` | string | `"quiet"` | `quiet`, `card`, `tray`, `lines`, `linesIcons` | Section Look. How the sections above and below the workspace list draw. |
| `sidebar.topBandMaxShare` | real | `0.3333333333333333` | 0.1 to 0.9 | Top Sections Height. The share of the sidebar the top sections fill before they scroll. |
| `sidebar.bottomBandMaxShare` | real | `0.25` | 0.1 to 0.9 | Bottom Sections Height. The share of the sidebar the bottom sections fill before they scroll. |
| `sidebar.stickyBandsScroll` | boolean | `true` |  | Scroll Tall Sections. Off: the top and bottom sections never scroll and the workspace list gets smaller. |
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
| `notifications.attention.style` | string | `"blink"` | `blink`, `pulse`, `steady`, `none` | Style |
| `notifications.attention.color` | string |  |  | Color |
| `notifications.attention.width` | real | `2` | 0.5 to 8 | Width |
| `notifications.attention.blinkCount` | real | `2` | 1 to 10 | Blinks |
| `notifications.attention.duration` | real | `3` | 0.3 to 30 | Pulse Duration |
| `notifications.attention.persist` | boolean | `true` |  | Keep Ring Until Read |
| `notifications.attention.showOnTab` | boolean | `true` |  | Mark the Tab |
| `notifications.attention.showOnSidebar` | boolean | `true` |  | Mark the Sidebar Row |
| `EnrollmentToken` | string |  |  | Team enrollment token from the cmux dashboard. Signed-in users in a verified domain of the team join it; the token alone never grants membership. |
| `ManagedTeam` | string |  |  | Team id (team_...) that manages this device. |
| `RestrictToManagedTeam` | boolean |  |  | Refuse sign-in to any team other than ManagedTeam on this device. |
| `DisabledFeatures` | array |  | `computerUse`, `browserAutomation`, `mcp`, `cloud`, `apps`, `remoteHosts` | Features to turn off: their UI, actions and host operations are removed. |
| `UpdateChannel` | string |  | `stable`, `nightly` | Update channel this device follows. |
| `MinimumVersion` | string |  |  | Oldest cmux version allowed to sign in, for example 1.2.0. |
| `AllowedSignInMethods` | array |  | `sso`, `password`, `oauth` | Sign-in methods the app offers. |
| `DisableAutoUpdate` | boolean |  |  | Turn off automatic updates (also honored in the legacy com.cmuxterm.app domain). |
