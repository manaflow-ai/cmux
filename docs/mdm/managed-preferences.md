# cmux managed preferences

Generated from the cmux settings catalog by `ManagedPreferencesManifest` (CmuxNextSettings). Do not edit by hand; run `CMUX_UPDATE_MDM_SCHEMA=1 swift test --filter ManagedPreferencesManifestTests` in `Packages/macOS/CmuxNext`.

Domain: `com.manaflow.cmux` for every channel (stable, NIGHTLY, DEV). A forced value (any MDM custom settings payload) locks the setting and Settings shows "Managed by your organization". A non-forced value replaces the default and the user can still change it. Precedence, highest first: MDM forced, team policy enforced, the user's cmux.json, MDM non-forced, team policy default, product default.

Chat privacy exceptions: `agents.chats.roots` is the union of user roots and roots added by managed or team layers, deduplicated in layer order. Managed roots are locked rows, but users may still edit their own roots. `agents.chats.enabled` and `agents.chats.discovery` default to true; a forced false from either MDM or team policy turns them off, while a forced true never overrides a user false. Recommended booleans only supply missing user values. All three keys refuse agent writes (`privacy`). Managed chat roots and forced-off values are enforced while the cmux app runs; the acpmux daemon keeps the last values the app sent in its own `chat-settings.json`, so a daemon started without the app uses those values.

Chat roots must be absolute harness data folders. The root folder, home folder, Desktop, Documents, Downloads, Pictures, Music, Movies, Library/Mobile Documents, Library/CloudStorage, Library/Containers, Library/Group Containers, Library/Mail, Library/Messages, Library/Safari, Library/Calendars and their descendants are refused, as are /Volumes, /Network and /net. Checks are case-insensitive and include symbolic links. Refused roots remain visible with a reason, but are never read or sent to the daemon. The protected list mirrors acpmux protected_folders.rs.

The legacy forced keys `DisableAutoUpdate` and `DisableTelemetry` in `com.cmuxterm.app` keep working.

Files: `com.manaflow.cmux.plist` (ProfileManifests: iMazing Profile Editor, ProfileCreator), `com.manaflow.cmux.json` (Jamf Pro custom schema), `cmux-example.mobileconfig` (any MDM), `com.manaflow.cmux.intune.plist` (Intune preference file).

| Key | Type | Default | Allowed values | Description |
| --- | --- | --- | --- | --- |
| `history.terminalCommands` | boolean | `false` |  | Record Terminal Commands. Lists finished shell commands in History. Command lines can contain secrets. |
| `navigation.historyScope` | string | `"workspace"` | `workspace`, `window`, `surface` | Back and Forward. What Go Back and Go Forward walk: places in this workspace, in this window, or the focused page's own history. |
| `navigation.history.scope` | string | `"workspaces"` | `workspaces`, `everything` | Back and Forward Steps. Workspaces: Go Back and Go Forward move between workspaces and top pages, and return to the tab each one last had focused. Everything: they also step through tabs and panes inside a workspace. |
| `history.commandRetentionDays` | real | `30` | 1 to 3650 | Keep Terminal Commands For. Each machine deletes recorded commands that are older. |
| `history.closed.maxGroups` | real | `0` | 0 to 10000 | Recently Closed Items to Keep. Each machine deletes its oldest closed tabs, screens, workspaces and windows past this many. 0 keeps them all. |
| `history.closed.maxAgeDays` | real | `0` | 0 to 3650 | Keep Recently Closed Items For. Each machine deletes closed items that are older. 0 keeps them however old they are. |
| `window.titlebar` | string | `"minimal"` | `minimal`, `standard` | Titlebar. Minimal has no titlebar strip; the top row moves the window. |
| `window.titlebarButtons` | string | `"hover"` | `hover`, `always` | Titlebar Buttons. On Hover hides Back and Forward until the pointer is over the top row. The sidebar button always shows. |
| `app.globalHotKey` | boolean | `false` |  | Global Hot Key. Show/Hide All Windows (⌃⌥⌘.) works while another app is in front. |
| `app.startAgentGlobalHotKey` | boolean | `false` |  | Start Agent from Any App. Start Agent (⌃⌥⌘Space) works while another app is in front. Change its key in Keyboard Shortcuts. |
| `tabs.newTabTemplate` | string | `"default"` | `default`, `composer`, `threads`, `console`, `classic`, `terminal` | New Tab Template. The layout of the New Tab page. Terminal skips the page and opens a terminal. The dots at the bottom of the page also change it. |
| `tabs.newTabPosition` | string | `"end"` | `end`, `afterCurrent` | New Tab Position. Where Cmd-T and the + button put the new tab. New Tab to the Right in a tab's menu always puts it after that tab. |
| `tabs.plusButton` | string | `"hover"` | `hover`, `always` | New Tab Button. On Hover shows each tab bar's + only while the pointer is over that tab bar. |
| `tabs.barPosition` | string | `"top"` | `top`, `bottom` | Tab Bar Position. Where each pane's tab bar sits. Bottom also shows the standard title bar, so the window buttons never cover a pane. |
| `tabs.barOrder` | string | `"aboveToolbar"` | `aboveToolbar`, `belowToolbar` | Tab Bar and Browser Toolbar. In a browser pane with the tab bar at the top: the tab bar above the address bar, or below it. |
| `tabs.toolbarButtons` | array | `[]` | `splitRight`, `splitDown`, `openDiffViewer`, `file.open`, `agentPane.searchChats`, `toggleSplitZoom` | Tab Bar Buttons. Actions shown as buttons next to the tab bar's More button. The rest are in the More menu, where Show in Tab Bar pins them back. |
| `tabs.overflow` | string | `"shrink"` | `shrink`, `scroll` | Tab Overflow. Shrink narrows every tab to the minimum width before the strip scrolls. Scroll keeps tabs wide and scrolls sooner. |
| `appearance.metrics.tabMaxWidth` | real |  | 120 to 320 | Maximum Tab Width. Widest a tab gets when the strip has room. |
| `appearance.metrics.tabMinActiveWidth` | real |  | 32 to 320 | Minimum Selected Tab Width. When the strip is crowded, every tab shrinks evenly to this width, and the selected tab stays at least this wide. |
| `appearance.metrics.tabMinInactiveWidth` | real |  | 16 to 320 | Minimum Tab Width. Narrowest the other tabs get before the strip scrolls. Never wider than the selected tab's minimum. |
| `appearance.metrics.tabPinnedWidth` | real |  | 24 to 120 | Pinned Tab Width. Width of a pinned tab. |
| `newTerminal.opensWorkspace` | boolean | `false` |  | New Terminal Opens a Workspace. Create a new workspace in the current space instead of a tab. Hold Option to reverse this for one click. |
| `tabs.cmdWClosesPinnedTabs` | boolean | `false` |  | Cmd-W Closes Pinned Tabs. When off, Cmd-W on a pinned tab selects the next tab and keeps the pinned tab. Close a pinned tab from its menu. |
| `tabs.swapCmdTAndCmdN` | boolean | `false` |  | Swap Cmd-T and Cmd-N. When on, Cmd-T opens a workspace in the current group and Cmd-N opens a tab. When off, Cmd-T opens a tab, or a workspace when an agent chat or a pane without tabs is focused. |
| `app.warnBeforeClosingTab` | boolean | `true` |  | Warn Before Closing a Running Program |
| `app.warnBeforeClosingAgentSession` | boolean | `true` |  | Warn Before Closing a Working Agent |
| `app.quitBehavior` | string | `"ask"` | `ask`, `keep`, `end-keep-layout`, `end-everything` | When Quitting. Terminals run in cmux-tui and keep running after cmux quits unless you end them. |
| `layout.defaultColumnWidth` | real | `0.5` | 0.1 to 1 | Fixed Column Width. A share of the window width, for Fixed Width new columns. |
| `layout.centerFocusedColumn` | string | `"never"` | `never`, `always`, `on-overflow` | Center Focused Column |
| `layout.stripScrollbar` | string | `"system"` | `system`, `auto`, `always`, `off` | Column Scroll Bar. A thin bar under the columns that shows and moves the visible range. |
| `layout.closeFocus` | string | `"previousNeighbor"` | `previousNeighbor`, `mostRecent` | Focus After Closing a Pane. Which pane gets focus when the focused pane closes. |
| `shortcuts.showModifierHoldHints` | boolean | `true` |  | Show Shortcuts When Holding a Modifier. Hold Command or Control for 0.30 seconds to show shortcut hints. |
| `updates.checkAutomatically` | boolean | `true` |  | Check for Updates Automatically |
| `updates.checkIntervalSeconds` | real | `3600` | 900 to 604800 | Check Every |
| `updates.downloadAutomatically` | boolean | `true` |  | Download Updates Automatically. Off: a found update waits, and one click downloads and installs it. |
| `updates.meteredNetwork` | string | `"defer-low-data"` | `defer-low-data`, `defer-expensive`, `download` | On Metered Networks. While downloads wait, a found update shows on Settings and one click downloads it. |
| `updates.installOnQuit` | boolean | `true` |  | Install Updates When Quitting. A downloaded update installs as cmux quits. Terminals keep running. |
| `updates.notify` | string | `"badge"` | `badge`, `silent` | When an Update Is Ready |
| `updates.keepPreviousVersions` | real | `1` | 0 to 5 | Keep Previous Versions. Earlier builds kept so you can roll back. Uses almost no disk until files change. |
| `updates.showWhatsNew` | boolean | `true` |  | Show What's New After Updates. After an update, a card at the bottom of the sidebar links to What's New until you open or dismiss it. |
| `announcements.enabled` | boolean | `true` |  | Show Announcements. Short cards from the cmux team above Settings, shown when the pointer is over the sidebar. |
| `announcements.fetch` | boolean | `true` |  | Download Announcements. Off: cmux never asks the network for announcements. The request carries no identifiers. |
| `computerUse.enabled` | boolean | `false` |  | Computer Use. Lets agents see and use your apps through the signed cmux Computer Use helper. macOS asks for Accessibility and Screen Recording when you first allow them. |
| `computerUse.driver` | string | `"legacy"` | `legacy`, `upstream` | Computer Use Driver. Legacy runs the current cmux Computer Use helper. Upstream runs the new helper built on the upstream Cua Driver; macOS asks for its permissions separately. |
| `freeModel.enabled` | boolean | `true` |  | Free AI Model Without Sign-In. Lets agents use the free cmux AI model while you are signed out. The first time an agent uses it, cmux proves to the Cloud service that this is a real Mac. Sign in for more models and higher limits. |
| `sessions.keepAwake` | string | `"pluggedIn"` | `off`, `pluggedIn`, `always` | Keep Mac Awake While Agents Work. Stops idle sleep while an agent on this Mac is working. Your display can still turn off, and closing the lid still puts the Mac to sleep. |
| `phone.allowConnections` | boolean | `false` |  | Let Your Phone Use This Mac. So your phone can find this Mac, cmux registers with its servers this Mac's name, device ID and platform, the app's bundle ID, version and build channel, the Mac's relay address and connection key, and your account and team IDs. Workspace names, folders, full paths and terminal output go only over the encrypted link to your phone. None of that, and no branch name or repo URL, is sent to cmux servers. Exception: while “Show This Mac's Workspaces on Your Phone While It's Off” is on, cmux servers store each workspace's ID, resource ID, short ID, name, name revision, group, color, icon, pinned state, unread mark, unread count and whether it is active. |
| `phone.startSessions` | boolean | `true` |  | Let Your Phone Start New Workspaces. Off, your phone can still follow, type into and answer what's already running. |
| `phone.keepAwake` | string | `"pluggedIn"` | `off`, `pluggedIn`, `always` | Keep Mac Awake for Your Phone. A sleeping Mac can't be reached from your phone until it wakes. Closing the lid still puts the Mac to sleep. |
| `phone.cloudReplica` | boolean | `false` |  | Show This Mac's Workspaces on Your Phone While It's Off. cmux stores this Mac's workspace names, colors and unread counts so your phone can show them while the Mac is off. A workspace name can be a folder's name. No paths, tab titles or terminal output. Turning this off deletes the copy. |
| `agents.subsessions.enabled` | boolean | `true` |  | Let Agents Start Sub-sessions. An agent can start other agent sessions to work on parts of a task in parallel. They show under its session in the sidebar. |
| `agents.subsessions.maxChildren` | real | `50` | 1 to 1000 | Open Sub-sessions per Session. The most sub-sessions one session can have open at the same time. Closing a sub-session frees its place. |
| `agents.subsessions.maxDepth` | real | `10` | 1 to 100 | Deepest Nesting. How many levels of sub-sessions can start under a session. 1 lets a session start sub-sessions that cannot start their own. |
| `layout.splitSizing` | string | `"even"` | `even`, `halve` | Split Sizing. Even gives every pane in the column the same size after a split. |
| `layout.newColumnWidth` | string | `"matchCurrent"` | `matchCurrent`, `fitScreen`, `fixed` | New Column Sizing |
| `layout.dockColumnEdge` | string | `"nearest"` | `nearest`, `right`, `left`, `top`, `bottom` | Dock Column Edge |
| `layout.dockColumnMode` | string | `"docked"` | `docked`, `overlay` | Dock Column Mode |
| `layout.frameOrientation` | string | `"columnMajor"` | `columnMajor`, `rowMajor` | Dock Corners |
| `layout.rows` | boolean | `true` |  | Rows. Off hides New Row and fits a column's existing rows into it without scrolling. |
| `layout.minimumPaneWidth` | real | `200` | 80 to 800 | Minimum Pane Width |
| `layout.minimumPaneHeight` | real | `64` | 32 to 600 | Minimum Pane Height |
| `layout.newPanePlacement` | string | `"tab"` | `tab`, `split` | New Terminals and Browsers. Open a Tab adds a tab to the focused pane. Split Automatically splits the largest pane, like New Pane (Auto Layout). |
| `layout.tileBrowsers` | boolean | `false` |  | Split for Browsers Too. With Split Automatically, new browsers also get their own pane instead of a tab. |
| `workspaces.newPlacement` | string | `"top"` | `top`, `afterCurrent`, `bottom` | New Workspace Position. Where Cmd-N, the + button and the CLI put a new workspace in the sidebar. Pinned workspaces stay above it. |
| `sidebar.groupByComputer` | boolean | `false` |  | Group Workspaces by Computer. Off: one list of workspaces, and a workspace on another computer names it under its title. On: a section per computer. |
| `workspaces.autoName` | boolean | `true` |  | Name Workspaces from Tabs. A workspace you have not named shows its front tab's name: a page's title, an agent chat's title, or a terminal's title or folder. Your own name always wins. |
| `palette.scopes.tabs.prefix` | string | `"@"` | `@`, `#`, `>`, `,`, `?`, `!`, `/`, `;`, `:`, `%`, `&`, `+`, `=`, `~`, `$`, `^`, `*`, `.`, `none` | Tabs Prefix. Typed into an empty query, this character enters the scope. A prefix you assign moves from any other scope. |
| `palette.scopes.workspaces.prefix` | string | `"#"` | `@`, `#`, `>`, `,`, `?`, `!`, `/`, `;`, `:`, `%`, `&`, `+`, `=`, `~`, `$`, `^`, `*`, `.`, `none` | Workspaces Prefix. Typed into an empty query, this character enters the scope. A prefix you assign moves from any other scope. |
| `palette.scopes.commands.prefix` | string | `">"` | `@`, `#`, `>`, `,`, `?`, `!`, `/`, `;`, `:`, `%`, `&`, `+`, `=`, `~`, `$`, `^`, `*`, `.`, `none` | Commands Prefix. Typed into an empty query, this character enters the scope. A prefix you assign moves from any other scope. |
| `palette.scopes.settings.prefix` | string | `","` | `@`, `#`, `>`, `,`, `?`, `!`, `/`, `;`, `:`, `%`, `&`, `+`, `=`, `~`, `$`, `^`, `*`, `.`, `none` | Settings Prefix. Typed into an empty query, this character enters the scope. A prefix you assign moves from any other scope. |
| `palette.scopes.scopes.prefix` | string | `"?"` | `@`, `#`, `>`, `,`, `?`, `!`, `/`, `;`, `:`, `%`, `&`, `+`, `=`, `~`, `$`, `^`, `*`, `.`, `none` | Scope List Prefix. Typed into an empty query, this character enters the scope. A prefix you assign moves from any other scope. |
| `palette.aliases` | dictionary | `{}` |  | Command Aliases. A word that names a command by its action id ("vs": "splitRight"). Typing the whole word in the command palette puts that command first. |
| `palette.pins` | array | `[]` |  | Pinned Commands. Commands shown first when the command palette opens, in this order, by action id. |
| `agents.chats.enabled` | boolean | `true` |  | Enable Chats. Show chats stored on this device. Nothing is uploaded. |
| `agents.chats.discovery` | boolean | `true` |  | Discover Chat Folders. Find harness chat folders automatically. When off, only the listed folders are used. |
| `agents.chats.roots` | array | `[]` |  | Chat Folders. Add absolute paths to harness data folders. Protected folders are refused. Your organization can add locked folders. |
| `picker.pinned` | array | `[]` |  | Pinned Folders. The picker lists these folders under Locations, after Home and Downloads. Use full paths or ~/ paths. |
| `tasks.layout` | string | `"inbox"` | `list`, `board`, `inbox` | Tasks Layout. Inbox lists what needs you first, with the task beside it. Changes apply at once. |
| `appearance.theme` | string |  |  | Theme. Colors for cmux and its terminals. A space, workspace or terminal theme overrides it. |
| `appearance.appTheme` | string | `"followTerminal"` |  | App Theme. Colors for cmux's own pages. Every bundled theme works here, and each color meets WCAG AA contrast. |
| `appearance.themeEdits` | dictionary | `{}` |  | Theme Edits. Your color changes to a theme, such as "Rose Pine/background": "#1f1d2e". The theme itself never changes; remove an entry to reset that color. |
| `appearance.accent` | string | `"neutral"` | `neutral`, `theme`, `art`, `red`, `green`, `yellow`, `blue`, `magenta`, `cyan` | Accent. The color of selection, focus and the Send button. Theme Color takes the theme's own hue, such as Rose Pine's iris. |
| `appearance.backdropArt` | string | `"none"` | `none`, `david-death-of-marat`, `goya-saturn`, `velde-small-ship-storm`, `bosch-garden-right`, `bosch-ascent-blessed`, `goya-witches-flight`, `bocklin-self-portrait-death`, `caravaggio-medusa`, `martin-pandemonium`, `moran-burning-philadelphia`, `goya-burial-sardine`, `arbo-wild-hunt`, `caravaggio-david-goliath`, `van-gogh-skeleton-cigarette`, `altdorfer-battle-of-issus`, `gentileschi-judith`, `munch-madonna`, `bocklin-isle-of-the-dead`, `klee-fish-magic`, `friedrich-forest-moonlight`, `goya-witches-sabbath`, `bosch-garden-left`, `rembrandt-storm-galilee`, `cole-voyage-manhood`, `fuseli-nightmare-2`, `hiremy-hirschl-souls-of-acheron`, `munch-scream`, `klimt-judith`, `repin-ivan`, `millais-ophelia`, `bruegel-fall-rebel-angels`, `fuseli-nightmare`, `bundy-death-general`, `wright-vesuvius`, `gerome-botsaris`, `durer-knight-death-devil`, `martin-joshua`, `velde-gale`, `hogai-nio`, `klimt-death-and-life`, `klimt-medicine`, `bosch-garden-central`, `martin-great-day-wrath`, `bonheur-wounded-eagle`, `gerome-pollice-verso`, `cole-voyage-old-age`, `friedrich-abbey-oakwood`, `goya-sleep-of-reason`, `bosch-garden-fragment`, `bruegel-triumph-death`, `spilliaert-vertigo`, `rothaug-melpomene`, `schiele-death-and-the-maiden`, `aivazovsky-ship-stormy-seas`, `vereshchagin-apotheosis-war`, `ensor-skeleton-painter`, `cabanel-fallen-angel`, `spilliaert-woman-shoreline`, `el-greco-view-of-toledo`, `gericault-raft-of-the-medusa`, `moreau-apparition`, `rembrandt-prodigal-son`, `velazquez-las-meninas`, `matejko-stanczyk`, `sargent-madame-x`, `millais-joan-of-arc`, `cot-storm`, `rembrandt-night-watch`, `vigee-lebrun-madame-grand`, `waterhouse-lady-shalott`, `draper-lament-icarus`, `fragonard-swing`, `rubens-st-francis-xavier`, `vermeer-pearl-earring`, `danielson-gambogi-self`, `beard-his-majesty`, `marc-foxes`, `degas-green-dancers`, `modigliani-nude-divan`, `raphael-sistine-madonna`, `bouguereau-virgin-lilies`, `wood-american-gothic`, `steinlen-chat-noir`, `degas-blue-dancers`, `botticelli-primavera`, `van-gogh-cafe-terrace`, `matisse-red-room`, `kandinsky-deepened-impulse`, `friedrich-wanderer`, `klimt-adele`, `mucha-job`, `van-gogh-starry-night`, `klimt-tree-of-life`, `klimt-the-kiss`, `van-gogh-starry-night-rhone`, `delacroix-liberty`, `van-gogh-sunflowers`, `klimt-mada-primavesi`, `schiele-kneeling-orange`, `van-gogh-sunflowers-munich`, `michelangelo-sistine-ceiling`, `mondrian-composition-red-plane`, `lemoyne-apotheosis-hercules`, `schiele-moa`, `aivazovsky-ninth-wave`, `popova-painterly-architectonic`, `bruegel-tower-babel`, `botticelli-birth-of-venus`, `kandinsky-yellow-red-blue`, `kandinsky-composition-viii`, `kramskoi-unknown-woman`, `michelangelo-creation-of-adam`, `hokusai-great-wave`, `holbein-ambassadors`, `brueghel-wooden-vessel`, `dahl-dresden-moonlight`, `bosschaert-wan-li-vase`, `cot-springtime`, `ruysch-flowers`, `van-gogh-flowering-plum`, `toulmouche-reluctant-bride`, `rosso-musical-angel`, `grimshaw-blackman-street`, `waterhouse-ophelia`, `biard-magdalena-bay`, `renoir-vase-roses`, `roerich-himalayas`, `velde-close-hauled`, `sohlberg-flower-meadow`, `dahl-cloud-study`, `friedrich-two-men-moon`, `monet-waterlily-pond`, `hesselbom-dusk`, `toulmouche-vanity`, `hiroshige-zoshigaya`, `monet-water-lilies`, `monet-water-lilies-1907`, `bierstadt-storm-rockies`, `korovin-place-opera`, `klimt-garden-sunflowers`, `redon-butterflies`, `aivazovsky-winter-landscape`, `aivazovsky-along-coast`, `grimshaw-silver-moonlight`, `monet-water-lilies-setting-sun`, `hiroshige-hota-coast`, `durer-praying-hands`, `cole-voyage-childhood`, `monet-impression-sunrise`, `monet-woman-parasol`, `velde-cannon-shot`, `cross-pink-cloud`, `laurence-mckinley`, `van-gogh-irises`, `kramskoi-christ-in-the-desert`, `turner-temeraire`, `leonardo-vitruvian-man`, `bruegel-hunters-snow`, `cole-voyage-youth`, `friedrich-monk-by-the-sea`, `van-gogh-wheat-field-cypresses`, `monet-cliff-pourville`, `van-gogh-almond-blossom`, `van-gogh-fishing-boats`, `hokusai-umezawa`, `whistler-falling-rocket`, `dore-fall-of-satan`, `dore-flood`, `dore-wolves-sheep`, `dore-leviathan`, `dore-paradise-lost-book-vi`, `dore-moses-tables`, `dore-empyrean`, `dore-raven` | Backdrop Art. A public-domain painting behind the window material. Lower Opacity to reveal it. Attribution is linked above. |
| `appearance.background` | string | `"none"` | `none`, `daily`, `david-death-of-marat`, `goya-saturn`, `velde-small-ship-storm`, `bosch-garden-right`, `bosch-ascent-blessed`, `goya-witches-flight`, `bocklin-self-portrait-death`, `caravaggio-medusa`, `martin-pandemonium`, `moran-burning-philadelphia`, `goya-burial-sardine`, `arbo-wild-hunt`, `caravaggio-david-goliath`, `van-gogh-skeleton-cigarette`, `altdorfer-battle-of-issus`, `gentileschi-judith`, `munch-madonna`, `bocklin-isle-of-the-dead`, `klee-fish-magic`, `friedrich-forest-moonlight`, `goya-witches-sabbath`, `bosch-garden-left`, `rembrandt-storm-galilee`, `cole-voyage-manhood`, `fuseli-nightmare-2`, `hiremy-hirschl-souls-of-acheron`, `munch-scream`, `klimt-judith`, `repin-ivan`, `millais-ophelia`, `bruegel-fall-rebel-angels`, `fuseli-nightmare`, `bundy-death-general`, `wright-vesuvius`, `gerome-botsaris`, `durer-knight-death-devil`, `martin-joshua`, `velde-gale`, `hogai-nio`, `klimt-death-and-life`, `klimt-medicine`, `bosch-garden-central`, `martin-great-day-wrath`, `bonheur-wounded-eagle`, `gerome-pollice-verso`, `cole-voyage-old-age`, `friedrich-abbey-oakwood`, `goya-sleep-of-reason`, `bosch-garden-fragment`, `bruegel-triumph-death`, `spilliaert-vertigo`, `rothaug-melpomene`, `schiele-death-and-the-maiden`, `aivazovsky-ship-stormy-seas`, `vereshchagin-apotheosis-war`, `ensor-skeleton-painter`, `cabanel-fallen-angel`, `spilliaert-woman-shoreline`, `el-greco-view-of-toledo`, `gericault-raft-of-the-medusa`, `moreau-apparition`, `rembrandt-prodigal-son`, `velazquez-las-meninas`, `matejko-stanczyk`, `sargent-madame-x`, `millais-joan-of-arc`, `cot-storm`, `rembrandt-night-watch`, `vigee-lebrun-madame-grand`, `waterhouse-lady-shalott`, `draper-lament-icarus`, `fragonard-swing`, `rubens-st-francis-xavier`, `vermeer-pearl-earring`, `danielson-gambogi-self`, `beard-his-majesty`, `marc-foxes`, `degas-green-dancers`, `modigliani-nude-divan`, `raphael-sistine-madonna`, `bouguereau-virgin-lilies`, `wood-american-gothic`, `steinlen-chat-noir`, `degas-blue-dancers`, `botticelli-primavera`, `van-gogh-cafe-terrace`, `matisse-red-room`, `kandinsky-deepened-impulse`, `friedrich-wanderer`, `klimt-adele`, `mucha-job`, `van-gogh-starry-night`, `klimt-tree-of-life`, `klimt-the-kiss`, `van-gogh-starry-night-rhone`, `delacroix-liberty`, `van-gogh-sunflowers`, `klimt-mada-primavesi`, `schiele-kneeling-orange`, `van-gogh-sunflowers-munich`, `michelangelo-sistine-ceiling`, `mondrian-composition-red-plane`, `lemoyne-apotheosis-hercules`, `schiele-moa`, `aivazovsky-ninth-wave`, `popova-painterly-architectonic`, `bruegel-tower-babel`, `botticelli-birth-of-venus`, `kandinsky-yellow-red-blue`, `kandinsky-composition-viii`, `kramskoi-unknown-woman`, `michelangelo-creation-of-adam`, `hokusai-great-wave`, `holbein-ambassadors`, `brueghel-wooden-vessel`, `dahl-dresden-moonlight`, `bosschaert-wan-li-vase`, `cot-springtime`, `ruysch-flowers`, `van-gogh-flowering-plum`, `toulmouche-reluctant-bride`, `rosso-musical-angel`, `grimshaw-blackman-street`, `waterhouse-ophelia`, `biard-magdalena-bay`, `renoir-vase-roses`, `roerich-himalayas`, `velde-close-hauled`, `sohlberg-flower-meadow`, `dahl-cloud-study`, `friedrich-two-men-moon`, `monet-waterlily-pond`, `hesselbom-dusk`, `toulmouche-vanity`, `hiroshige-zoshigaya`, `monet-water-lilies`, `monet-water-lilies-1907`, `bierstadt-storm-rockies`, `korovin-place-opera`, `klimt-garden-sunflowers`, `redon-butterflies`, `aivazovsky-winter-landscape`, `aivazovsky-along-coast`, `grimshaw-silver-moonlight`, `monet-water-lilies-setting-sun`, `hiroshige-hota-coast`, `durer-praying-hands`, `cole-voyage-childhood`, `monet-impression-sunrise`, `monet-woman-parasol`, `velde-cannon-shot`, `cross-pink-cloud`, `laurence-mckinley`, `van-gogh-irises`, `kramskoi-christ-in-the-desert`, `turner-temeraire`, `leonardo-vitruvian-man`, `bruegel-hunters-snow`, `cole-voyage-youth`, `friedrich-monk-by-the-sea`, `van-gogh-wheat-field-cypresses`, `monet-cliff-pourville`, `van-gogh-almond-blossom`, `van-gogh-fishing-boats`, `hokusai-umezawa`, `whistler-falling-rocket`, `dore-fall-of-satan`, `dore-flood`, `dore-wolves-sheep`, `dore-leviathan`, `dore-paradise-lost-book-vi`, `dore-moses-tables`, `dore-empyrean`, `dore-raven`, `desktop` | Background. Choose a public-domain painting, your desktop wallpaper, or a macOS system wallpaper behind the window material. |
| `appearance.experimentalControls` | boolean | `false` |  | Experimental Appearance Controls. Show the wallpaper grid and live appearance tuner while they are being integrated. |
| `appearance.backgroundOpacity` | real |  | 0 to 1 | Opacity. How much of the theme color covers the material behind the window. |
| `appearance.backgroundBlur` | string |  | `frosted`, `glass`, `glass-clear`, `none` | Material. Unset, the window follows Ghostty's background-opacity and background-blur. |
| `appearance.glassTransparency` | real | `0` | 0 to 1 | Glass Transparency. How much of the desktop or wallpaper shows through the glass. |
| `appearance.hue` | real | `0.5` | 0 to 1 | Hue. Shift the tint color around the hue wheel. |
| `appearance.saturation` | real | `1` | 0 to 2 | Saturation. Increase or reduce the tint color intensity. |
| `appearance.density` | string | `"compact"` | `compact`, `comfortable` | Density |
| `app.uiScale` | real | `1` | 0.85 to 1.5 | Interface Scale |
| `appearance.metrics.chromeFontSize` | real |  | 10 to 16 | Interface Size. Text size of tabs, the sidebar and other controls. Terminal text has its own size. |
| `appearance.interfaceScale` | real |  | 0.9 to 1.25 | Interface Size. Text size of tabs, the sidebar and other controls. Terminal text has its own size. |
| `appearance.metrics.sidebarWidth` | real |  | 160 to 420 | Sidebar Width |
| `appearance.metrics.columnGap` | real |  | 0 to 24 | Column Gap |
| `appearance.metrics.titlebarHeight` | real |  | 24 to 56 | Titlebar Height |
| `appearance.borders` | string | `"default"` | `default`, `none` | Borders. None removes every border, hairline and separator in the app. |
| `appearance.focusIndicator` | string | `"tabs"` | `border`, `tabs`, `both`, `none` | Focused Pane. How the focused pane stands out: its border, subtler tabs in the other panes, both or neither. |
| `focus.inactiveTabStyle` | string | `"fade"` | `fade`, `tonal`, `quiet` | Unfocused Pane Tabs. How the other panes' tabs draw subtler when Focused Pane marks tabs: Fade dims them, Tonal steps their text down, Quiet drops the selected pill. |
| `ui.animationSpeed` | string | `"fast"` | `fast`, `normal`, `off` | Animations |
| `appearance.chromeStyle` | string | `"flat-sidebar-line"` | `default`, `card`, `card-outlined`, `flat`, `flat-sidebar-line`, `bare`, `panes`, `two-tone`, `floating` | Window Style. The look of the window: whether panes sit in one rounded card, and where lines are drawn. Separation, Sidebar Background and the sidebar border still win when you set them. |
| `ui.paneAnimations` | boolean | `true` |  | Animate Panes. Splits, closes, moves, zooms, column scrolls and screen switches slide into place. Off: they change at once. |
| `ui.animations.newTab` | boolean | `true` |  | Animate New Tabs. A new tab grows into its place in the tab bar. Off shows it there at once. |
| `ui.animations.newWorkspace` | boolean | `true` |  | Animate New Workspaces. A new workspace row opens in the sidebar. Off shows it there at once. |
| `ui.animations.bounce` | string | `"none"` | `none`, `subtle` | Animation Bounce. None stops tabs, rows and panes exactly at their place. Subtle lets them settle with a small bounce. |
| `layout.paneSeparation` | string |  | `none`, `dividers`, `borders`, `cards` | Separation. How panes are told apart. None draws no border or divider at all; dragging between panes still resizes them. Default: dividers inside the curved main pane, borders otherwise. |
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
| `diff.layout` | string | `"unified"` | `split`, `unified` | Layout |
| `diff.diffIndicators` | string | `"bars"` | `bars`, `classic`, `none` | Change Markers |
| `diff.colors` | string | `"theme"` | `theme`, `muted`, `standard` | Diff Colors |
| `diff.wordWrap` | boolean | `false` |  | Wrap Lines |
| `diff.wordDiffs` | boolean | `false` |  | Highlight Word Changes |
| `diff.lineNumbers` | boolean | `true` |  | Line Numbers |
| `diff.showBackgrounds` | boolean | `true` |  | Change Backgrounds |
| `diff.expandUnchanged` | boolean | `false` |  | Expand Unchanged Lines |
| `markdown.layout.width` | real | `72` | 30 to 1000 | Text Width. The widest a line of text gets, in characters (30 to 1000). On a wider window the text stays centered with margins. Wide tables and code scroll sideways in their own box. |
| `markdown.layout.fullWidth` | boolean | `false` |  | Full Width. Text fills the whole pane instead of the text width. |
| `markdown.font.size` | real | `16` | 8 to 40 | Default Font Size. The text size every markdown viewer opens at. Cmd-= and Cmd-- change it in one viewer; Cmd-0 goes back to this size. |
| `markdown.font.preset` | string | `"system"` | `system`, `serif`, `mono` | Font |
| `markdown.font.lineHeight` | real | `1.6` | 1 to 2.4 | Line Height |
| `markdown.spacing.paragraph` | real | `1` | 0 to 3 | Paragraph Spacing. The gap after each paragraph, as a share of the text size. |
| `markdown.code.scale` | real | `0.875` | 0.6 to 1.25 | Code Font Size. Code as a share of the text size. A monospaced font looks bigger than the text font at the same size, so code is a little smaller by default. |
| `markdown.code.blockSize` | real |  | 8 to 32 | Code Block Size |
| `markdown.tables` | string | `"scroll"` | `scroll`, `wrap` | Wide Tables |
| `markdown.theme` | string | `"app"` | `app`, `light`, `dark` | Page Theme |
| `terminal.fontFamily` | string |  |  | Font Family. A monospaced font installed on this Mac. |
| `terminal.fontSize` | real |  | 4 to 96 | Font Size |
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
| `editor.importFrom` | string | `"auto"` | `auto`, `vscode`, `cursor`, `windsurf`, `vscodium`, `zed`, `none` | Take Defaults From. cmux reads that editor's settings and keybindings files and never changes them. A setting you make here wins. |
| `appearance.sidebarSurface` | string | `"same"` | `same`, `separate` | Sidebar Background. Same as Main Pane gives the sidebar the main pane's background. Separate shades the sidebar darker than the main pane. |
| `sidebar.border` | boolean | `false` |  | Border. A line on the sidebar's edge. Off, the edge shows a line only while you hover or drag it. |
| `sidebar.borderWidth` | real |  | 0.5 to 4 | Border Width |
| `sidebar.sectionLook` | string | `"quiet"` | `quiet`, `card`, `tray`, `lines`, `linesIcons` | Section Look. How the sections above and below the workspace list draw. |
| `sidebar.topBandMaxShare` | real | `0.3333333333333333` | 0.1 to 0.9 | Top Sections Height. The share of the sidebar the top sections fill before they scroll. |
| `sidebar.bottomBandMaxShare` | real | `0.25` | 0.1 to 0.9 | Bottom Sections Height. The share of the sidebar the bottom sections fill before they scroll. |
| `sidebar.pinnedBandsScroll` | boolean | `true` |  | Scroll Tall Sections. Off: the top and bottom sections never scroll and the workspace list gets smaller. |
| `sidebar.showWorkspaceTabs` | boolean | `false` |  | Show Workspace Tabs. Lists tabs beneath each workspace in the sidebar. |
| `sidebar.showChats` | boolean | `true` |  | Show All Chats. Shows every coding agent chat on this computer, newest first, at the bottom of the sidebar. |
| `sidebar.showProjects` | boolean | `true` |  | Show Projects |
| `sidebar.groupBy` | string | `"none"` | `none`, `folder` | Group Projects By |
| `sidebar.showSpaces` | boolean | `true` |  | Show Spaces |
| `sidebar.showProfileControl` | boolean | `true` |  | Show Profile Button |
| `sidebar.minimal` | boolean | `false` |  | Minimal Mode. Workspace rows show only their icon, name and unread mark, and section titles become thin lines. |
| `sidebar.density` | string | `"compact"` | `compact`, `comfortable`, `expanded` | Sidebar Density. Comfortable rows keep one line on taller rows with more space around them. Expanded rows show each workspace's status or folder under its name, how long ago it changed, and its pull request and computer. |
| `sidebar.detailedStatusIcons` | boolean | `false` |  | Detailed Status Icons. Workspace rows show a separate icon for working, waiting for input, error and done. Off, a row shows a spinner while it works and a blue dot when it is ready for you. |
| `sidebar.minimalMode` | string | `"off"` | `off`, `bottom`, `top`, `both` | Hide Bands Until Hover. Hides the chosen sections until the pointer is over the sidebar. |
| `sidebar.cards.tips` | boolean | `true` |  | Show Tips. A "Did you know" card above the account button shows one cmux feature a day that you have not used yet. Each tip shows only once. |
| `sidebar.side` | string | `"left"` | `left`, `right` | Sidebar Side. The window edge the sidebar sits on. On the right, the window buttons sit over the tab bar. |
| `sidebar.spacesPosition` | string | `"bottom"` | `top`, `bottom` | Spaces Position. Where the spaces dots sit in the sidebar: under the window buttons or above the Settings row. |
| `sidebar.spacesVisibility` | string | `"hover"` | `hover`, `always` | Show Spaces. On Hover shows the spaces only while the pointer is over the sidebar, like its other buttons. |
| `sidebar.numbering` | string | `"allItems"` | `allItems`, `workspacesOnly` | Command-Number Shortcuts. Every item: Home is Command-1, the App Store Command-2, the first workspace Command-3. Workspaces only: the first workspace is Command-1. |
| `sidebar.cmd9` | string | `"last"` | `last`, `ninth` | Command-9. Goes to the last item, as in browsers, or to the ninth. |
| `sidebar.stepping` | string | `"allItems"` | `allItems`, `workspacesOnly` | Next and Previous Item. What Command-Control-] and Command-Control-[ step through. |
| `sidebar.steppingWraps` | boolean | `true` |  | Wrap Around. Past the last item, the next item is the first again. |
| `sidebar.hoverCards.enabled` | boolean | `true` |  | Show Hover Cards. A card with details opens when the pointer rests on a workspace or a tab. |
| `sidebar.hoverCards.delay` | real | `250` | 0 to 5000 | Hover Card Delay. How long the pointer rests on a workspace or a tab before its card opens. While a card shows, the next one opens at once. |
| `sidebar.nowPlaying.enabled` | boolean | `false` |  | Show Now Playing. A player for what is playing, at the bottom of the sidebar and on the new chat page. |
| `appearance.colorTransition.enabled` | boolean | `true` |  | Animate Color Changes. Workspace, theme and color changes blend from the old colors to the new ones. Off: they change at once. |
| `appearance.colorTransition.duration` | real | `200` | 0 to 2000 | Color Change Duration. How long a color change takes. 0 changes colors at once. |
| `appearance.colorTransition.curve` | string | `"easeOut"` | `easeOut`, `easeInOut`, `linear`, `spring`, `cubicBezier` | Color Change Curve. How a color change moves over its duration. Spring uses Spring Response and Spring Damping; Custom uses the four Bezier values. |
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
| `sidebar.workspaceRow.agentStatus` | boolean | `true` |  | Agent Status. The status agents and hooks report, one line each. |
| `sidebar.workspaceRow.tabCount` | boolean | `false` |  | Tab Count |
| `sidebar.workspaceRow.ports` | boolean | `false` |  | Ports. Set by a hook: cmux workspace status set ports <text>. |
| `sidebar.workspaceRow.lastActivity` | boolean | `false` |  | Last Activity |
| `sidebar.workspaceRow.pullRequest` | boolean | `false` |  | Pull Request. Set by a hook: cmux workspace status set pr <text>. |
| `sidebar.workspaceRow.progress` | boolean | `true` |  | Progress. A progress bar under the row and the busy mark of running work. |
| `sidebar.workspaceRow.working` | boolean | `true` |  | Agent Working. A mark while an agent works in the workspace. |
| `sidebar.workspaceRow.log` | boolean | `true` |  | Log. The newest line agents and scripts log: cmux workspace log append <text>. |
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
| `browser.toolbarButtons` | array | `["media","zoom","downloads"]` | `media`, `zoom`, `favorites`, `downloads`, `designMode`, `profile`, `theme`, `devTools` | Toolbar Buttons. Buttons shown next to the address bar. The rest are in the More menu, where Show in Toolbar pins them back. |
| `browser.defaultEngine` | string | `"chromium"` | `chromium`, `webkit` | Default Engine. New browser tabs open in this engine. |
| `browser.newTabPage` | string | `""` |  | New Tab Page. An address such as https://example.com. Empty opens a blank page. |
| `browser.showBookmarksBar` | boolean | `false` |  | Show Bookmarks Bar. A row of bookmarks under each browser toolbar. |
| `browser.showAgentCursor` | boolean | `true` |  | Show Agent Cursor. When an agent drives a browser tab, show its cursor, clicks and typed keys on the page. Password fields show dots. |
| `browser.builtInAdBlocker` | boolean | `true` |  | Built-in uBlock Origin. The full uBlock Origin blocks ads and trackers in Chromium tabs. Takes effect after cmux restarts. |
| `browser.hibernation` | string | `"moderate"` | `moderate`, `aggressive`, `off` | Hibernate Hidden Tabs. Frees memory; history and position are kept. Also accepts a number from 1 to 1440 in a raw profile. |
| `browser.hibernationExclusions` | array | `[]` |  | Never Hibernate. Hosts such as mail.google.com or *.example.com. |
| `browser.hibernatePinnedTabs` | boolean | `false` |  | Hibernate Pinned Tabs |
| `browser.remoteLocalhost` | boolean | `true` |  | Open localhost on the Workspace's Machine |
| `browser.searchEngine` | string | `"google"` | `google`, `duckduckgo`, `bing`, `brave`, `kagi`, `custom` | Search Engine. The address bar searches here and asks it for suggestions. |
| `browser.customSearchEngine.search` | string | `""` |  | Custom Search Address. Used when Search Engine is Custom. Put {searchTerms} where the typed text goes. |
| `browser.customSearchEngine.suggest` | string | `""` |  | Custom Suggestions Address. Optional. Answers in the OpenSearch suggestions format, with {searchTerms} for the typed text. |
| `browser.omnibar.remoteSuggestions` | boolean | `true` |  | Search Suggestions. Sends what you type to the search engine for suggestions. Never addresses, files or local hosts. |
| `browser.omnibar.inlineAutocomplete` | boolean | `true` |  | Complete Addresses Inline. Completes a site you typed before or visit often. |
| `browser.omnibar.maxRows` | real | `8` | 3 to 15 | Suggestions Shown |
| `browser.omnibar.calculator` | boolean | `true` |  | Calculator Answers. Shows the answer to arithmetic you type. Return copies it. |
| `browser.omnibar.glass` | string | `"off"` | `transparent`, `regular`, `clear`, `off` | Address Bar Glass. The material of the address bar. Transparent draws no fill. Clear glass shows more of what is behind it. Off uses the flat theme color. |
| `browser.omnibar.glassTint` | string | `"background"` | `background`, `accent`, `none` | Glass Tint. The color over the glass, from the terminal theme. Accent is the theme's own accent color, or gray when the theme has none. |
| `browser.omnibar.glassTintStrength` | real | `0.35` | 0 to 1 | Tint Strength |
| `browser.omnibar.cornerRadius` | string | `"theme"` | `theme`, `capsule` | Address Bar Corners. Match Theme uses the standard bar radius. Capsule rounds the ends fully. Also accepts a number from 0 to 16 in a raw profile. |
| `browser.omnibar.shadow` | boolean | `false` |  | Address Bar Shadow. A soft shadow under the glass address bar. |
| `browser.omnibar.backgroundOpacity` | real | `0` | 0 to 1 | Address Bar Opacity. How much the address bar covers a see-through window. At 0 it is as see-through as the window, but never so clear that its text stops being readable. |
| `browser.links.cmdClick` | string | `"backgroundTab"` | `backgroundTab`, `foregroundTab`, `newWindow`, `currentTab`, `download` | Command-Click. In Chromium tabs, Download keeps Chrome's default. |
| `browser.links.cmdShiftClick` | string | `"foregroundTab"` | `backgroundTab`, `foregroundTab`, `newWindow`, `currentTab`, `download` | Shift-Command-Click. Shift-middle-click does the same. |
| `browser.links.shiftClick` | string | `"newWindow"` | `backgroundTab`, `foregroundTab`, `newWindow`, `currentTab`, `download` | Shift-Click. In Chromium tabs, Download keeps Chrome's default. |
| `browser.links.optionClick` | string | `"download"` | `backgroundTab`, `foregroundTab`, `newWindow`, `currentTab`, `download` | Option-Click. Chromium tabs always download. |
| `browser.links.middleClick` | string | `"backgroundTab"` | `backgroundTab`, `foregroundTab`, `newWindow`, `currentTab`, `download` | Middle-Click. Chromium tabs use the Command-Click setting. |
| `browser.openLinksInCmuxBrowser` | boolean | `true` |  | Open Links in cmux Browser. When off, links you click in terminals, agent chats, Home and cmux pages open in your default browser. Shift-Command-click opens a link in the other browser. |
| `browser.openTerminalLinksInCmuxBrowser` | boolean | `true` |  | Open Terminal Links in cmux Browser. When off, links clicked in terminal output open in your default browser. |
| `browser.hostsToOpenInEmbeddedBrowser` | array | `[]` |  | Hosts to Open in Embedded Browser. Only these hosts open in cmux, such as example.com or *.example.com. Empty opens every host in cmux. |
| `browser.urlsToAlwaysOpenExternally` | array | `[]` |  | URLs to Always Open Externally. Links that match open in your default browser. Text matches anywhere in the URL, * and ? are wildcards, and re: starts a regular expression. |
| `files.textEditor` | string | `""` |  | Text Editor. The app Open in Text Editor uses for a path: an app name, a bundle ID or the path of an app. Empty uses the app that opens source code. |
| `browser.passwords.offerToSave` | boolean | `true` |  | Offer to Save Passwords. A browser tab asks to save a sign-in you submit. Tabs an agent drives never ask. |
| `browser.passwords.generate` | boolean | `true` |  | Suggest Strong Passwords. Offers a generated password when a site asks for a new one, and saves it. |
| `browser.passwords.allowExport` | boolean | `false` |  | Allow Password Export. Lets the Passwords page write every saved password to a plain-text CSV file, after you confirm with Touch ID or your password. |
| `browser.verificationAutofill.enabled` | boolean | `false` |  | Fill Codes from Verification Emails. When a site emails you a code or link, its tab offers it. Only on the sender's own site, never filled without your click, and never stored. |
| `home.attachments.keepLocation` | boolean | `false` |  | Keep Location in Photos and Videos. When off, location data is removed from photos and videos before they are attached. |
| `home.channelsEnabled` | boolean | `false` |  | Channels. Show Channels below Home in the sidebar. You can also turn it on or off from the command palette. |
| `home.chiefPetEnabled` | boolean | `false` |  | Show Chief Pet. A small Chief floats over every app and shows agent events above it. Drag it anywhere; click it to message the Chief or reply to a session. |
| `home.chiefPetMascot` | string | `"orb"` | `orb`, `orb-spark`, `orb-hood`, `machine`, `machine-cyan`, `machine-blue`, `moon`, `moon-blue`, `fox` | Character |
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
| `notifications.dockBounce` | string | `"once"` | `off`, `once`, `untilActive` | Bounce Dock Icon. When a notification alerts while cmux isn't the active app. |
| `feed.mirrorNotifications.agents` | boolean | `true` |  | Copy Agent Notifications to the Feed. Notifications from agents and cmux notify go to your cmux account's feed and can reach your iPhone. |
| `feed.mirrorNotifications.terminal` | string | `"off"` | `off`, `title`, `full` | Copy Terminal Notifications to the Feed. Notifications that programs send through the terminal can contain secrets. Off sends nothing to your cmux account. |
| `feed.agentPermissionPrompts` | boolean | `false` |  | Send Agent Permission Requests to the Feed. Each request's tool and command summary goes to your own cmux feed, so your iPhone can answer it. |
| `notifications.attention.style` | string | `"blink"` | `blink`, `pulse`, `steady`, `none` | Style |
| `notifications.attention.color` | string |  |  | Color |
| `notifications.attention.width` | real | `2` | 0.5 to 8 | Width |
| `notifications.attention.blinkCount` | real | `2` | 1 to 10 | Blinks |
| `notifications.attention.duration` | real | `3` | 0.3 to 30 | Pulse Duration |
| `notifications.attention.persist` | boolean | `true` |  | Keep Ring Until Read |
| `notifications.attention.showOnTab` | boolean | `true` |  | Mark the Tab |
| `notifications.attention.showOnSidebar` | boolean | `true` |  | Mark the Sidebar Row |
| `notifications.attention.moveToTop` | boolean | `true` |  | Move the Workspace to the Top. A notification moves its workspace to the top of the unpinned rows, unless you are looking at its pane. |
| `notifications.mutedWorkspaces` | array | `[]` |  | Muted Workspaces. Workspace ids whose notifications are silent. Mute a workspace from its sidebar row menu. |
| `labs.previewFeatures` | boolean | `false` |  | Show Preview Features. Unfinished surfaces, such as the agent session's coverage label and Pull requests view. |
| `labs.classicHome` | boolean | `false` |  | Classic Home. Show Home as a full page instead of a workspace with the Chief docked on the left. Takes effect after cmux restarts. |
| `feed.github.enabled` | boolean | `false` |  | Connect GitHub. Uses your gh login to read notifications and review requests on this Mac. Sign in with gh auth login first. |
| `feed.github.pollIntervalSeconds` | real | `120` | 60 to 900 | Refresh Interval. Seconds between GitHub refreshes. Refresh in the Inbox runs immediately. |
| `agentPane.links.outsideRoots` | string | `"open"` | `confirm`, `text`, `open` | Files Outside the Project. What a file link in a reply does when the file is outside the chat's folders. Keys and .env files never open. |
| `agentPane.images.remote` | string | `"click"` | `click`, `never`, `always` | Web Images in Replies. A web image loads from its site, which then sees that you read the reply. |
| `agentPane.editedFiles.show` | string | `"always"` | `always`, `collapsed`, `never` | Edited Files Card. The card that lists a turn's edited files, with Undo and View changes. |
| `agentPane.editedFiles.maxRows` | real | `5` | 1 to 50 | Edited Files Shown |
| `agentPane.editedFiles.scope` | string | `"turn"` | `turn`, `session` | Edited Files Card Covers |
| `agentPane.showContextUsage` | boolean | `true` |  | Show Context Usage. The ring beside the model that fills as the chat uses its context window. |
| `agentPane.showDictation` | boolean | `true` |  | Show Dictation Button. The microphone beside Send in every composer, including the New Tab page. |
| `agentPane.zoom` | real | `1` | 0.5 to 2 | Agent Chat Zoom. The display size for agent chat. Cmd-0 resets it. |
| `agents.defaultPermissionMode` | string | `"fullAccess"` | `fullAccess`, `standard`, `ask` | Permission Mode for New Chats. What a new chat may do without asking. Picking a mode in a chat sets it too, until you change this setting again. |
| `EnrollmentToken` | string |  |  | Team enrollment token from the cmux dashboard. Signed-in users in a verified domain of the team join it; the token alone never grants membership. |
| `ManagedTeam` | string |  |  | Team id (team_...) that manages this device. |
| `RestrictToManagedTeam` | boolean |  |  | Refuse sign-in to any team other than ManagedTeam on this device. |
| `DisabledFeatures` | array |  | `computerUse`, `browserAutomation`, `mcp`, `cloud`, `apps`, `remoteHosts` | Features to turn off: their UI, actions and host operations are removed. |
| `UpdateChannel` | string |  | `stable`, `nightly` | Update channel this device follows. |
| `MinimumVersion` | string |  |  | Oldest cmux version allowed to sign in, for example 1.2.0. |
| `AllowedSignInMethods` | array |  | `sso`, `password`, `oauth` | Sign-in methods the app offers. |
| `DisableAutoUpdate` | boolean |  |  | Turn off automatic updates (also honored in the legacy com.cmuxterm.app domain). |
| `DisableTelemetry` | boolean |  |  | Turn off anonymous telemetry, crash reports included, whatever the user chose (also honored in the legacy com.cmuxterm.app domain). |
