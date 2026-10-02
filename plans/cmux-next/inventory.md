# cmux next: inventory of the old app

Research output for [REWRITE.md](REWRITE.md). Snapshot of `feat-cmux-next` at base `fde44232c35`, 2026-09-28. Line counts are non-test Swift lines unless stated. Built from greps, not full reads, so small counts can be off by a few percent.

Scale: `Sources/` 546,344 lines (1,434 root files + 20 subdirs), `Packages/macOS` 342,787, `Packages/Shared` 89,901 (shared with iOS), `CLI/` 102,404, `cmuxTests` 494,631, `cmuxUITests` 27,260, `tests_v2` 30,308 (Python), `tests` 137,683 (Python). `vendor/bonsplit` is an uninitialized submodule here (24,804 lines at pin `c5cb292`).

Legend. Surfaces: P palette, K `KeyboardShortcutSettings.Action`, M main menu (includes Help, dock menu, menu-bar extra), C context menu (includes + button and toolbar dropdowns). Files: KSS `KeyboardShortcutSettings.swift`, CV `ContentView.swift`, RSP `ContentView+RightSidebarCommandPalette.swift`, VCP `ContentView+ViewCommandPalette.swift`, SWR `SidebarWorkspaceRowCommands.swift`, TIV Bonsplit `TabItemView.swift`, GTV `GhosttyTerminalView.swift`, CWV `CmuxWebView.swift`.

---

## 1. Action catalog

Counts: K = 159 cases (34 unbound). P = 209 fixed ids plus dynamic families (37 setting toggles, keymap presets, saved layouts, workspace statuses, 16 open-directory targets, workspace colors, config issues, custom `cmux.json` actions, extension sidebars, workspace/surface switcher rows). M = about 98 non-debug items plus about 50 debug items. C = about 150 items (workspace row 45, group header 12, tab 28, terminal 12, browser 8, cloud tree 25, file explorer 10, other 30). Merged: about 290 action rows, 55 of them on 3 or more surfaces.

Registry rule for the new palette: one row below = one registered action with a stable id. The K id is the canonical id where one exists, because users store it in `cmux.json` `shortcuts`.

### Window / app

| id | title | default | src | file |
|---|---|---|---|---|
| openSettings | Settings… | ⌘, | PKM | KSS:84, CV:7764, cmuxApp:524 |
| newWindow | New Window | ⇧⌘N | PKMC | KSS:89, CV:7535, cmuxApp:881, AppDelegate:8324 |
| closeWindow | Close Window | ⌃⌘W | PK | KSS:90, CV:7636 |
| toggleFullScreen | Toggle Full Screen | ⌃⌘F | PKM | KSS:91, CV:7644, cmuxApp:1215 |
| quit | Quit cmux | ⌘Q | KM | KSS:92, cmuxApp:565 |
| showHideAllWindows | Show/Hide All Windows (global) | ⌃⌥⌘. | K | KSS:87 |
| globalSearch | Search All Windows… | ⌥⌘F | PKM | KSS:88, MenuBarExtraController:28 |
| commandPalette | Command Palette… | ⇧⌘P | KM | KSS:103, cmuxApp:956 |
| commandPaletteNext / Previous | Palette: Next / Previous | ⌃N / ⌃P | K | KSS:104-105 |
| goToWorkspace | Go to Workspace… | ⌘P | KM | KSS:102, cmuxApp:951 |
| focusHistoryBack / Forward / Last | Focus Back / Forward / Last | ⌘[ / ⌘] / — | KM | KSS:134-136, cmuxApp+HistoryMenu:11 |
| (history) | Recently Focused / Recently Closed lists | — | M | cmuxApp+HistoryMenu:65,90 |
| palette.openTaskManager | Task Manager | — | PM | VCP:31, cmuxApp:1080 |
| palette.sleepyMode | Sleepy Mode | — | PM | VCP:37 |
| keepMacAwake | Keep Mac Awake | — | M | cmuxApp:541 |
| showMainWindow | Show cmux | — | M | MenuBarExtraController:29 |
| about | About cmux | — | M | cmuxApp:550 |
| (task manager row) | View Workspace / View Terminal / Kill Process… | — | C | TaskManagerView:394 |

### Workspace

| id | title | default | src | file |
|---|---|---|---|---|
| newTab (workspace) | New Workspace | ⌘N | PKMC | KSS:95, CV:7512, cmuxApp:885, CmuxConfig:1765 |
| newBrowserWorkspace | New Browser Workspace | ⌥⌘N | PKM | KSS:96, CV:7520 |
| openFolder | Open Folder… | ⌘O | PKM | KSS:100, CV:7561 |
| palette.openFolderInVSCodeInline | Open Folder in VS Code (Inline)… | — | PM | CV:7569 |
| reopenPreviousSession | Restore Previous App Launch | ⇧⌘O | PKM | KSS:101, CV:7588 |
| reopenClosedWorkspace | Reopen Closed Workspace | — | PKM | KSS:150, CV:7652 |
| nextSidebarTab / prevSidebarTab | Next / Previous Workspace | ⌃⌘] / ⌃⌘[ | PKM | KSS:129-130, CV:7975 |
| nextSidebarTabInGroup / prev | Next / Previous Workspace in Group | — | K | KSS:131-132 |
| moveWorkspaceUp / Down | Move Workspace Up / Down | ⌃⌥⌘[ / ⌃⌥⌘] | PKMC | KSS:133, CV:7993, SWR:590 |
| palette.moveWorkspaceToTop | Move to Top | — | PMC | CV:8013, SWR:602 |
| selectWorkspaceByNumber | Workspace 1…9 | ⌘1…9 | KM | KSS:137, cmuxApp:1268 |
| moveWorkspaceToWindow | Move Workspace to Window ▸ | — | MC | cmuxApp:1561, SWR:613 |
| renameWorkspace | Rename Workspace… | ⇧⌘R | PKMC | KSS:139, CV:7899, SWR:481 |
| palette.clearWorkspaceName | Clear Workspace Name | — | PMC | CV:7919, SWR:488 |
| editWorkspaceDescription | Edit Workspace Description… | ⌥⌘E | PKMC | KSS:140, CV:7909, SWR:496 |
| palette.clearWorkspaceDescription | Clear Workspace Description | — | PC | CV:7931, SWR:504 |
| markWorkspaceDone | Mark Workspace as Done | ⌘; | PKC | KSS:141, SWR:458 |
| cycleWorkspaceStatus | Cycle Workspace Status | ⇧⌘; | PK | KSS:142 |
| palette.workspaceStatus.* | Workspace Status: <s> / Auto | — | PC | TabItemView+WorkspaceTodo:89, SWR:452 |
| palette.addWorkspaceChecklistItem | Add Checklist Item… | — | PC | TabItemView+WorkspaceTodo:170, SWR:469 |
| toggleChecklistItemComplete | Toggle Checklist Item Complete | ⌘↩ | K | KSS:143 |
| palette.openWorkspaceTodoPane | Open Todo Pane | — | P | TabItemView+WorkspaceTodo:185 |
| closeWorkspace | Close Workspace | ⇧⌘W | PKMC | KSS:146, CV:7627, SWR:642 |
| palette.closeOtherWorkspaces | Close Other Workspaces | — | PMC | CV:8023, SWR:651 |
| palette.closeWorkspacesBelow / Above | Close Workspaces Below / Above | — | PMC | CV:8033, SWR:660 |
| palette.toggleWorkspacePin | Pin / Unpin Workspace | — | PMC | CV:7943, SWR:318 |
| palette.markWorkspaceRead / Unread | Mark Workspace Read / Unread | — | PMC | CV:8053, SWR:682 |
| palette.workspaceColor.* / resetWorkspaceColor | Workspace Color ▸, Custom Color…, Reset | — | PC | CV:7954, SWR:545 |
| (row) | Reconnect / Disconnect Workspace, Copy SSH Error | — | C | SWR:522, 583 |
| (row) | Clear Latest Notification(s), Show in Finder | — | C | SWR:707, 796 |
| palette.copyWorkspaceID / IDAndRef / Link | Copy Workspace ID / ID and Ref / Link | — | PC | ContentViewIdentifierCopyCommands:17, SWR:773 |
| newWorkspaceGroup | New Workspace Group | ⌃⌘G | KMC | KSS:147, cmuxApp:927, SWR:340 |
| groupSelectedWorkspaces | Group Selected Workspaces | ⇧⌘G | PKC | KSS:148, VCP:119, SWR:366 |
| toggleFocusedWorkspaceGroupCollapsed | Toggle Group Collapse | ⌃⌘. | PK | KSS:149 |
| (row) | Move to Group ▸ / Remove from Group | — | C | SWR:376 |
| (group header) | New Workspace in Group, Rename, Pin/Unpin, Mark Read/Unread, Clear Notifications, Ungroup, Delete, Edit Group Config…, Docs | — | C | SidebarGroupHeaderRowView:571 |
| saveLayoutTemplate | Save Layout as Template… | ⌃⌘S | PKC | KSS:99, ContentView+SavedLayoutCommands:26 |
| palette.layout.open.<name> | New Workspace from Template <name> | — | PC | ContentView+SavedLayoutCommands:165 |
| (+ menu) | Manage Layouts ▸ (default, none, delete) | — | C | AppDelegate+NewWorkspaceMenuRendering:50 |
| palette.openWorkspacePullRequests | Open All Workspace PR Links | — | P | CV:8130 |
| palette.findWork / currentWork.* | Find Work | — | P | ContentView+CurrentWorkCommandPalette:10 |
| switcher.workspace.<uuid> | workspace switcher rows | — | P | CV:5884 |

### Pane / split / canvas / simulator

| id | title | default | src | file |
|---|---|---|---|---|
| splitRight | Split Right | ⌘D | PKMC | KSS:165, CV:8500, GTV:9295 |
| splitDown | Split Down | ⇧⌘D | PKMC | KSS:166, CV:8581, GTV:9283 |
| newPaneAutoLayout | New Pane (Auto Layout) | ⌃⌘N | PKM | KSS:166, ContentView+PaneResizeCommands:21 |
| toggleSplitZoom | Toggle Pane Zoom | ⇧⌘↩ | PKC | KSS:166, CV:8614, TIV |
| equalizeSplits | Equalize Splits | ⌃⇧⌘= | PKM | KSS:170 |
| resizePaneLeft/Right/Up/Down | Resize Pane | ⌃⇧H/L/K/J | PKM | KSS:171-174, RSP:117 |
| focusLeft/Right/Up/Down | Focus Pane | ⌥⌘←→↑↓ | PK | KSS:159-162 |
| focusPreviousPane / focusNextPane | Focus Previous / Next Pane | — | PK | KSS:163-164 |
| triggerFlash | Flash Focused Panel | ⇧⌘H | PKC | KSS:120, GTV:9254 |
| palette.swapWithSession | Swap With Session… | — | PC | VCP:21, GTV:9306 |
| increase/decrease/resetWorkspaceTerminalFontSize | Workspace Terminal Font Size +/−/reset | ⌃⌘= / ⌃⌘- / ⌃⌘0 | PK | KSS:167-169 |
| toggleCanvasLayout | Toggle Canvas Layout | ⌃⌘C | PKM | KSS:179 |
| canvasOverview / canvasTidy / canvasRevealFocusedPane | Canvas Overview / Tidy / Reveal | ⌃⌘O / ⌃⌘T / ⌃⌘R | PK(M) | KSS:180-185 |
| canvasZoomIn/Out/Reset | Canvas Zoom | ⌥⌘= / ⌥⌘- / ⌘0 | PK | KSS:182-184 |
| canvasAlign*, canvasEqualize*, canvasDistribute* | Canvas align / equalize / distribute (8) | — | PK | KSS:186-193 |
| palette.newSimulatorPane | New Simulator Pane | — | PM | SimulatorCommandPaletteIntegration:10 |
| simulatorHome/RotateLeft/RotateRight/ToggleAppearance/ToggleSoftwareKeyboard | Simulator actions | ⇧⌘H / ⌘← / ⌘→ / ⇧⌘A / ⌘K | K | KSS:231-232 |
| palette.openFilesPane / FindPane / VaultPane / CloudPane | Open Files / Find / Vault / Cloud as Pane | — | P | RSP:200-206 |

### Tab (surface)

| id | title | default | src | file |
|---|---|---|---|---|
| newSurface | New Tab (Terminal) | ⌃⇧⌘T in cmux-next (⌘T is `newTab.sameKind`; #16620) | PKC | KSS:152, CV:7596, TIV |
| newTab.sameKind (cmux-next) | New Tab: same kind as the focused pane (browser pane: browser tab on its engine; else terminal) | ⌘T | PKMC, CLI `tab new` | user decision 2026-09-30 |
| openBrowser | New Tab (Browser) | ⇧⌘L | PKC | KSS:202, CV:7605, TIV |
| closeTab | Close Tab | ⌘W | PKM | KSS:144, CV:7618 |
| closeOtherTabsInPane | Close Other Tabs | ⌥⌘T | KMC | KSS:145, TIV |
| (tab) closeToLeft / closeToRight | Close Tabs to Left / Right | — | C | TIV |
| renameTab | Rename Tab… | ⌘R | PKC | KSS:138, CV:8081 |
| palette.clearTabName | Clear Tab Name | — | PC | CV:8091 |
| nextSurface / prevSurface | Next / Previous Tab in Pane | ⇧⌘] / ⇧⌘[ | PKM | KSS:122-123 |
| moveSurfaceLeft / Right | Reorder Tab Left / Right | ⇧⌥⌘[ / ⇧⌥⌘] | KM | KSS:124 |
| moveSurfaceToPreviousPane / NextPane | Move Tab to Previous / Next Pane | ⌃⇧⌘[ / ⌃⇧⌘] | PKM | KSS:125 |
| moveSurfaceToPaneLeft/Right/Up/Down | Move Tab to Pane (dir) | ⇧⌥⌘←→↑↓ | PKMC | KSS:126-127, TIV:1444 |
| selectSurfaceByNumber | Tab 1…9 | ⌃1…9 | K | KSS:128 |
| palette.moveTabToNewWorkspace | Move Tab to New Workspace | — | PC | ContentView+MoveTabToNewWorkspace:13 |
| palette.toggleTabPin / toggleTabUnread | Pin Tab / Mark Tab Unread | — | PC | CV:8104, 8115 |
| palette.toggleFullWidthTab | Full Width Tab | — | PC | CV:8626 |
| (tab) duplicate / reload / toggleAudioMute / disconnectRemote | Duplicate, Reload, Mute, Disconnect SSH | — | (P)C | CV:8330, TIV |
| palette.copyIdentifiers / copyPaneID / copyPaneLink / copySurfaceID / copySurfaceLink | Copy IDs / links | — | PC | ContentViewIdentifierCopyCommands:50-78 |
| reopenClosedBrowserPanel | Reopen Last Closed | ⇧⌘T | PKM | KSS:151, CV:7660 |
| switcher.surface.<uuid> | surface switcher rows | — | P | CV:5928 |

### Terminal

| id | title | default | src | file |
|---|---|---|---|---|
| toggleTerminalCopyMode | Toggle Copy Mode | ⇧⌘M | PK | KSS:153 |
| focusTextBoxInput / palette.terminalToggleTextBoxInput | Focus / Toggle TextBox | ⇧⌘A | PK | KSS:154, CV:8437 |
| cycleTextBoxSubmitAction | Cycle TextBox Submit Action | ⇧Tab | K | KSS:154 |
| attachTextBoxFile | Attach File to TextBox | ⇧⌥⌘A | PK | KSS:154 |
| sendCtrlFToTerminal | Send Ctrl-F | — | PKM | KSS:155 |
| pasteLastScreenshot | Paste Last Screenshot | — | PK | KSS:156 |
| clearScreenKeepScrollback | Clear Screen (Keep Scrollback) | ⇧⌘K | PK | KSS:157 |
| find / findInDirectory | Find… / Find in Directory… | ⌘F / ⇧⌘F | PKM | KSS:212-213 |
| findNext / findPrevious / hideFind / useSelectionForFind | Find Next / Prev / Hide / Use Selection | ⌘G / ⌥⌘G / ⇧⌥⌘F / ⌘E | PKM | KSS:214-217 |
| (right-click) | Copy, Paste, Reset Terminal, Reconnect Pane | — | C | GTV:9263-9318 |
| (right-click) | Resume Commands ▸ Set / Edit / Clear | — | C | GhosttyNSView+ForkConversationContextMenu:41 |
| palette.terminalOpenDirectory.<app> | Open Current Directory in <App> (16) | — | P | TerminalDirectoryOpenSupport:108 |

### Browser / viewers

| id | title | default | src | file |
|---|---|---|---|---|
| browserBack / Forward / Reload / HardReload | Back / Forward / Reload / Hard Refresh | ⌘[ / ⌘] / ⌘R / ⇧⌘R | PKM | KSS:204-205 |
| focusBrowserAddressBar | Focus Address Bar | ⌘L | PK | KSS:203 |
| browserZoomIn/Out/Reset, markdownZoom* | Zoom | ⌘= / ⌘- / ⌘0 | PKM | KSS:206-211 |
| toggleBrowserDeveloperTools / showBrowserJavaScriptConsole | DevTools / JS Console | ⌥⌘I / ⌥⌘C | PKM | KSS:218-219 |
| toggleBrowserFocusMode | Browser Focus Mode | ⌥⌘↩ | PKMC | KSS:220, CWV:1672 |
| toggleBrowserDesignMode | Browser Design Mode | ⌃⌥⌘D | KM | KSS:221 |
| toggleReactGrab | React Grab | ⇧⌘G | PKM | KSS:222 |
| splitBrowserRight / Down | Split Browser Right / Down | ⌥⌘D / ⇧⌥⌘D | PKM | KSS:175-176 |
| palette.browserOpenDefault / ToggleOmnibar / ClearHistory | Open in Default Browser / Omnibar / Clear History | — | P(M) | CV:8196-8297 |
| importFromBrowser | Import Browser Data… | — | MC | cmuxApp:1187 |
| palette.enableBrowser / disableBrowser | Enable / Disable cmux Browser | — | P | CV:7873 |
| (web right-click) | Open Link in New Tab / Default Browser | — | C | CWV:2248 |
| (more menu) | Screenshot Page/Section, Browser Theme, New/Rename Profile | — | C | BrowserPanelView:1567 |
| saveFilePreview / toggleFileEditorWordWrap | Save File / Word Wrap | ⌘S / ⌥Z | K(M) | KSS:201 |
| (file preview) | Open With ▸, Open Externally, Reveal in Finder | — | C | FilePreviewPanel:131 |
| openDiffViewer / palette.openDirectoryDiffViewer | Diff Viewer / Directory Diff | ⌃⇧⌘G (was ⌃⇧⌘D; that is New Row now) | PK | KSS:223 |
| diffViewer* (11) | j/k, ⌃D/⌃U, ⌃N/⌃P, G/gg, /, ]f/[f | vim-style | K | KSS:224-233 |
| palette.vscodeServeWebStop / Restart | VS Code Inline Server | — | P | CV:8356 |

### Sidebar

| id | title | default | src | file |
|---|---|---|---|---|
| toggleSidebar | Toggle Left Sidebar | ⌘B | PKM | KSS:94 |
| toggleRightSidebar (raw `toggleFileExplorer`) | Toggle Right Sidebar | ⌥⌘B | KM | KSS:196 |
| focusRightSidebar | Right Sidebar Focus | ⇧⌘E | KM | KSS:113 |
| switchRightSidebarTo{Files,Find,Sessions,Feed,Dock,Machines} | Show Files / Find / Vault / Feed / Dock / Cloud | ⌃1…⌃6 by position | PK | KSS:114-119 |
| fileExplorerOpenSelection / FinderAlias | Open Selection | ↩ / ⌘↓ | K | KSS:197-198 |
| (file explorer) | Open in cmux, Reveal, Copy Path / Relative Path, Open With ▸ | — | C | FileExplorerView:2023 |
| (vault row) | Focus / Open / Resume in New Workspace, Copy Resume Command, Open PR, … (9) | — | C | SessionIndexView:1038 |
| (checklist) | Edit, In Progress, Remove, Complete, Open as Pane, Attach Images | — | C | SidebarWorkspaceChecklistView:88,433 |
| palette.toggleMatchTerminalBackground / enable/disableMinimalMode | Match Terminal BG / Minimal Mode | — | P | CV:7693-7714 |
| palette.extensionSidebar.<hash> | extension sidebar rows | — | P | CV:8710 |

### Notifications

| id | title | default | src | file |
|---|---|---|---|---|
| showNotifications | Show Notifications | ⌘I | PKM | KSS:107 |
| jumpToUnread | Jump to Latest Unread | ⇧⌘U | PKM | KSS:108 |
| toggleUnread | Toggle Unread | ⌥⌘U | PKM | KSS:109 |
| markOldestUnreadAndJumpNext | Mark Oldest Unread, Jump Next | ⌃⌘U | PK | KSS:110 |
| markAllNotificationsRead / clearAllNotifications | Mark All Read / Clear All | — | KM | KSS:111-112 |
| (row) | Open, Copy, Mark Read/Unread, Dismiss | — | C | NotificationPopoverRow:74 |

### Agents

| id | title | default | src | file |
|---|---|---|---|---|
| palette.newAgentChat | New agent chat | ⇧⌘I (#16620) | P | ContentView+AgentChatCommandPalette:31 |
| palette.openTerminalChatView | Open terminal as chat | — | P | :37 |
| palette.launchClaudeTeams / launchCodexTeams | Claude / Codex Teams | — | P | :88 |
| palette.forkAgentConversation{Right,Left,Top,Bottom,NewTab,NewWorkspace} | Fork Conversation To ▸ | — | PC | CV:8509, GhosttyNSView+ForkConversationContextMenu:288 |
| palette.computerUse.* | Computer Use Setup / Accessibility / Screen Recording | — | P | ContentView+ComputerUseCommandPalette:5 |
| (status menu) | Focus Computer Use / Calling Terminal / Stop Using <App> | — | M | ComputerUseMenuBarController:12 |

### Cloud / account / mobile

| id | title | default | src | file |
|---|---|---|---|---|
| newCloudWorkspace | New Cloud Workspace | ⇧⌘Y | KMC | KSS:97 |
| newCloudMachine | New Cloud Machine… | ⌘Y | PKMC | KSS:98 |
| palette.cloud.{fork,snapshot,restore,promoteTemplate,status,ports,tools,handoff} | Cloud VM ops (8) | — | P | ContentView+AuthCommandPalette:83-90. cmux-next: tools runs the `cmux vm tools` probe through `POST /api/vm/{id}/exec`; handoff shows the live status and the `cmux cloud open-machine` / `machine-tools` commands for the machine; promoteTemplate takes a snapshot named `template-<id12>-<unix>`, as `cmux vm promote-template` did |
| (cloud tree) | New Terminal, Open, Rename, Kill, Copy Link/Port/ID, Resize ▸ (25) | — | C | CloudTreeOutlineView:624, CloudTreeResizeMenu |
| cloudDiagnostics | Cloud Diagnostics… | — | M | CmuxHelpCommands:14 |
| openTeamPicker | Team Picker | ⌥⇧⌘T | PK | KSS:85 |
| palette.auth.signIn / signOut | Sign In / Out | — | P | ContentView+AuthCommandPalette:18 |
| palette.mobileConnect | Open Mobile Pairing | — | P | CV:7796 |

### Settings / config / updates / help

| id | title | default | src | file |
|---|---|---|---|---|
| reloadConfiguration | Reload Configuration | ⇧⌘, | KM | KSS:86 |
| palette.openCmuxSettingsFile / openGhosttySettings | Open cmux.json / Ghostty config | — | PM | CV:7773 |
| palette.makeDefaultTerminal | Make Default Terminal | — | PM | CV:7808 |
| palette.toggleSetting.<id> | Enable/Disable <setting> (~37) | — | P | CommandPaletteSettingsToggle:139 |
| palette.shortcutKeymap.<preset> | Base Keymap | — | P | ContentView+KeymapPresetCommands:8 |
| (custom actions) | user `cmux.json` actions | — | P | CV:9544 |
| palette.installCLI / uninstallCLI / restartSocketListener | CLI in PATH / Restart CLI Listener | — | P | CV:7543, 7865 |
| palette.checkForUpdates / applyUpdateIfAvailable / attemptUpdate / switchAppChannel | Updates / channel | — | PM | CV:7830-7857 |
| palette.pro.upgrade / welcomeChecklist | Pro upgrade / welcome | — | PM | ContentView+ProCommandPalette:20 |
| sendFeedback | Send Feedback | — | KM | KSS:106 |
| (Help) | Shortcuts, Feature Flags, 14 doc links | — | M | CmuxHelpCommands:28-86 |

### Debug (DEBUG builds)

Debug menu (~12 items), Debug Windows ▸ (~24 labs and galleries), Update Pill menu (6). `cmuxApp:571-873`. Recommendation: do not port. Rebuild only the labs the new UI needs.

---

## 2. External contracts

### 2.1 Summary

| Contract | Where | Lines | Verdict |
|---|---|---|---|
| `cmux` CLI | `CLI/` (`cmux.swift` 42,301; dispatch switch `cmux.swift:5572-8490`) | 102,404 | KEEP binary and verb names. Layout/terminal verbs forward to cmux-tui. |
| Control socket v2 | `Packages/macOS/CmuxControlSocket` + `Sources/TerminalController*.swift` | ~95k combined, 590 methods | REWRITE as a thin router: forward namespaces go to cmux-tui, the app serves the rest. |
| cmux-tui protocol | `cmux-tui/spec/commands.md` (89 sections, ~70 implemented, protocol v12), `spec/native-frontend.md` | — | New source of truth for layout, terminals, persistence. |
| `cmux.json` | schema `web/data/cmux.schema.json` (32 top-level keys), loader `Sources/CmuxConfig*.swift` (5,245), `Packages/macOS/CmuxSettings` | ~23k | KEEP the file and schema. The terminal part is split into cmux-tui config. |
| Agent hooks | `CLI/CMUXCLI+AgentHook*`, `ClaudeHook*`, feed/notify | ~8.3k | REWRITE onto cmux-tui `agent hook install` / `report-agent`. Hook command strings already written into users' agent settings must keep resolving. |
| OSC 9/777 | `GhosttyTerminalView.swift:3143,3432`, `RemoteTmuxSessionMirror+OutputRouting.swift:18` | — | REWRITE. cmux-tui owns the VT, so OSC must arrive as `subscribe` events. |
| Notifications store | `Sources/TerminalNotificationStore*` (3,404), `CmuxNotifications` pkg | ~7.3k | KEEP. Re-key to cmux-tui surface ids. |
| URL schemes | `Resources/Info.plist:184-209` (`http`, `https`, `cmux`/`cmux-nightly`/`cmux-rc`/`cmux-dev`, `ssh`), `AppDelegate+CmuxSSHURL.swift` (1,070), `AppDelegate+CmuxNavigationDeepLinks.swift` (212), `CmuxSSHURLRequest.swift` (996) | ~2.3k | KEEP schemes. `cmux://workspace/<id>`, `/pane`, `/surface` resolve against cmux-tui ids. `cmux://ssh` / `ssh://` run through cmux-remote. |
| Mobile host | `CmuxMobileHost` (4,326) + `Sources/Mobile` (17,092); transports in Shared | ~21k app + ~62k transport | KEEP. 84 `mobile.*` RPCs; `terminal.*` and `workspace.list` re-back onto cmux-tui `attach-surface` / `vt-state` / `list-workspaces`. |
| Cloud VMs | `CmuxCloud*` pkgs (~28k), `Sources/Cloud` (20,798), `CmuxAPIClient` | ~49k | KEEP client. Rewrite the UI. `/api/vm/*`, billing, coderouter, devices endpoints. |
| Updater | `CmuxUpdater` (4,729), `CmuxUpdaterUI` (1,513), `Sources/Update` (4,358) | ~10.6k | KEEP Sparkle. Feeds: `github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml`, `files.cmux.com/{nightly,rc}/appcast*.xml`. New: must also update bundled `bin/cmux-tui` in lockstep. |
| Auth | `CmuxAuthRuntime` (7,843), `CMUXAuthCore` (543), `Sources/Auth` (2,792) | ~11k | KEEP unchanged. Keychain services `com.cmuxterm.app`, `com.cmuxterm.app.auth` must not change, or every user is signed out. Stack Auth, callback `https://cmux.com/auth/callback`. |

### 2.2 CLI verbs by group

| Group | Verbs | Verdict |
|---|---|---|
| system | `ping`, `identify`, `capabilities`, `version`, `socket-status`, `rpc`, `tree`, `top`, `memory`, `events`, `reload-config` | FORWARD (`identify`, `ping`, `reload-config`, `events`→`subscribe`), KEEP rest |
| window | `list-windows`, `new-window`, `focus-window`, `close-window`, `resize-window`, `move-workspace-to-window` | APP-OWNED (native windows = frontend projections) |
| workspace | `new-workspace`, `close-workspace`, `select-workspace`, `rename-workspace`, `list-workspaces`, `reorder-workspace(s)`, `workspace-action`, `workspace-group`, `layout`, `restore-session`, `session(s)` | FORWARD |
| pane | `new-split`, `new-pane`, `list-panes`, `focus-pane`, `split-off`, `drag-surface-to-split`, `list-panels`, `focus-panel` | FORWARD |
| surface/tab | `new-surface`, `close-surface`, `move-surface`, `reorder-surface`, `list-pane-surfaces`, `surface-health`, `surface-resume`, `tab-action`, `rename-tab`, `move-tab-to-new-workspace`, `current` | FORWARD |
| terminal I/O | `send`, `send-key`, `send-panel`, `paste`, `read-screen`, `read-selection`, `clear` | FORWARD (`send-key` is proposed in cmux-tui, needs landing) |
| tmux compat | `__tmux-compat`, `tmux`, inner verbs (`capture-pane`, `split-window`, …) | FORWARD via shim |
| browser | `browser …` tree, `open-browser`, `navigate`, `get-url`, … | APP-OWNED. App registers as cmux-tui browser provider. |
| notify | `notify`, `list/dismiss/open-notification`, `jump-to-unread`, `clear-notifications` | APP-OWNED (cmux-tui `notify` only proposed) |
| sidebar status | `set-status`, `set-progress`, `log`, `report_pwd`, `report_git_branch`, `report_pr_action`, `sidebar`, `right-sidebar` | REWRITE, keyed on cmux-tui surface ids |
| hooks/agents | `hooks`, `claude-hook`, `codex-hook`, `feed-hook`, `setup-hooks`, `agent`, `agent-hibernation`, `claude-teams`, `codex-teams`, per-agent wrappers | REWRITE onto cmux-tui hooks |
| feed, settings, config, themes, import, docs, feedback | — | APP-OWNED KEEP |
| cloud/vm | `vm`/`cloud`, `vm-*-attach`, `remote(s)`, `vpn`, `billing`, `coderouter` | KEEP (overlaps `cmux-tui/crates/cmux-cloud-cli`) |
| auth | `auth`, `login`, `logout` | KEEP |
| ssh | `ssh`, `mosh`, `ssh-tmux`, `ssh-pty-attach`, `ssh-session-*` | REWRITE toward cmux-tui cmux-remote |
| mobile | `mobile`, `iroh-diag`, `ios`, `simulator` | KEEP |
| misc | `canvas`, `todo`, `comments`, `vault`, `project`, `markdown`, `open`, `diff`, `review`, `automation`, `sudo` | KEEP; `canvas` DROP (see 3) |
| debug/internal | `debug-terminals`, `trigger-flash`, `simulate-*`, `__*` | DROP |

### 2.3 Socket v2 namespaces

| Namespace | Methods | tests_v2 files | Verdict |
|---|---|---|---|
| workspace | 66 | 43 | FORWARD (except `cloud_vm_*`: app) |
| surface | 33 | 37 | FORWARD |
| pane | 9 | 13 | FORWARD |
| terminal | 9 | 1 | FORWARD |
| tab | 1 | 2 | FORWARD |
| layout | 5 | 1 | FORWARD (`export-layout` / `apply-layout`) |
| session | 7 | 2 | FORWARD journal parts; agent recovery stays app |
| provider | 4 | 0 | FORWARD |
| system | 6 | 4 | FORWARD `ping`/`identify`, app merges `capabilities`/`tree` |
| remote | 13 | 0 | DROP remote tmux mirror; cmux-remote replaces it |
| browser | 101 | 15 | APP |
| mobile | 84 | 2 | APP |
| vm | 66 | 2 | APP |
| simulator | 30 | 1 | APP (or DROP with the simulator, see 3) |
| notification | 15 | 1 | APP |
| window | 7 | 9 | APP |
| auth, coderouter, automation, vault, feed, project, remotes, phone_push, comments, sync, feedback, caffeine, settings, markdown, file, extension, chat | 1-8 each | 0 | APP |
| canvas | 12 | 0 | DROP |
| sidebar | 4 | 0 | REWRITE (`custom.*` → cmux-tui `sidebar-plugin`) |
| agent | 4 | 1 | REWRITE |
| debug | 49 | 24 | DROP. Port only what the new tests need. |

About 150 of 590 methods forward. Forwarding removes the need to own their semantics in Swift, so `ControlCommandCoordinator+Workspace/Surface/Pane` (~2.3k) and most of `TerminalController.swift` (16,396) are deleted outright.

### 2.4 `cmux.json` key groups

| Group | Keys | Verdict |
|---|---|---|
| meta | `$schema`, `schemaVersion`, `packs` | KEEP |
| actions | `actions`, `commands`, `newWorkspaceCommand`, `surfaceTabBarButtons`, `ui` | KEEP; execution forwards to cmux-tui |
| terminal/look | `terminal`, `paneBorderColor`, `activePaneBorderColor`, `workspaceColors`, `app` | SPLIT: VT keys into cmux-tui config, chrome stays |
| sidebar | `sidebar`, `sidebarAppearance`, `customSidebars`, `rightSidebar`, `workspaceGroups` | KEEP keys, REWRITE semantics; `customSidebars` see decision D4 |
| agents | `agents`, `agentChat`, `notifications`, `automation`, `computerUse` | KEEP |
| panels | `browser`, `markdown`, `canvas`, `fileEditor`, `fileExplorer`, `diffViewer`, `vault` | KEEP; `canvas` becomes a no-op with a deprecation diagnostic |
| other | `mobile`, `shortcuts` | KEEP; `shortcuts` ids = K ids in section 1 |

---

## 3. Subsystem map

DELETE = replaced by cmux-tui or obsolete. REWRITE = new code needed, old code is reference only. KEEP-AS-LIBRARY = link unchanged (after stripping Bonsplit / UI edges). Bias: maximum deletion.

### 3.1 Packages/macOS (342,787 lines)

| Package | Lines | Bonsplit | Verdict | Why |
|---|---|---|---|---|
| CmuxSimulator | 34,064 | – | DELETE (v1) | iOS Simulator pane. Large, niche. Re-add later as a pane provider. **Decision D1.** |
| CmuxControlSocket | 31,818 | – | REWRITE | Replaced by a thin router (see 2.3). Keep only `Wire/` framing if the router needs it. |
| CmuxBrowser | 23,942 | 3 files | KEEP-AS-LIBRARY | `CmuxWebView`, WebAuthn (1,891), import, downloads, discard manager. Strip the 3 Bonsplit imports. The CEF engine is new alongside it. |
| CmuxCloud | 23,602 | indirect | KEEP-AS-LIBRARY | `VMClient` (3,158), tunnel, WireGuard hub, auth env. The UI parts get rewritten. |
| CmuxFoundation | 20,139 | – | KEEP (prune) | Generated config schema, process exec. Delete `SidebarDrop/` (1,106) and the SSH retry policy (2,703) once cmux-remote owns SSH. |
| CmuxSettingsUI | 19,244 | – | DELETE → REWRITE | Settings window rebuilt in the new style. |
| CMUXAgentLaunch | 18,631 | – | KEEP-AS-LIBRARY (for now) | Resume argv, restore planner, launch sanitizers. Candidate to move into cmux-tui. **Decision D2.** |
| CmuxTerminal | 17,314 | 1 file | DELETE | Surface lifecycle, portal lease, font lineage, surface registry. cmux-tui owns the PTY. The new view is a small attachment renderer. |
| CmuxSettings | 15,749 | – | KEEP-AS-LIBRARY | JSONC editor, config store, shortcut `when` clauses, socket settings, allowlists. |
| CmuxRemoteSession | 11,462 | tests | DELETE | Remote tmux mirror and bootstrap. Replaced by cmux-tui cmux-remote. |
| CmuxGit | 11,459 | – | KEEP-AS-LIBRARY | Git metadata and refs parsing. |
| CmuxTerminalCore | 10,742 | – | SPLIT | KEEP `Config/` + `ConfigDiscovery/` (Ghostty config), prompt detection. DELETE surface callbacks. Copy mode moved to `CmuxNextCopyMode` (key table) and `TerminalSurfaceView+CopyMode` (Ghostty keyboard-copy API); cmux-tui has none. |
| CmuxWorkspaces | 8,895 | 1 file | DELETE | Workspace model, reorder, groups, focus history, `SessionSnapshotRepository`. All of it is cmux-tui state now. |
| CmuxSudoBroker | 7,467 | – | KEEP-AS-LIBRARY | Self-contained. |
| CmuxRemoteWorkspace | 6,719 | – | DELETE | Proxy tunnel, PTY bridge, CLI relay. Replaced by cmux-remote. |
| CmuxAppKitSupportUI | 5,497 | indirect | DELETE → REWRITE | Glass, titlebar, popovers. Depends on CmuxWorkspaces. Mine the glass/titlebar code for ideas only. |
| CmuxSurfaceCatalogModel | 5,005 | – | DELETE | Includes a hand-written `CmuxTuiSnapshotParser` (1,947). Replace with a typed Swift client generated from `cmux-tui/bindings/codegen`. |
| CmuxUpdater | 4,729 | – | KEEP-AS-LIBRARY | Sparkle driver. Add the cmux-tui binary lockstep. |
| CmuxSwiftRenderUI | 4,418 | – | DELETE | Custom-sidebar interpreter UI. **Decision D4.** |
| CmuxMobileHost | 4,326 | – | KEEP-AS-LIBRARY | Re-back `terminal.*` onto cmux-tui. |
| CmuxComputerUse | 4,000 | – | KEEP-AS-LIBRARY | Runtime service and helper staging. The UI is deferred. |
| CmuxCommandPalette | 3,947 | – | SPLIT | KEEP `Search/` (fuzzy matcher 1,087, Nucleo FFI). DELETE `State/`, `Orchestration/` and the UI. |
| CmuxNotifications | 3,939 | – | KEEP-AS-LIBRARY | Delivery, UN center, dismissal, navigation. Re-key ids. |
| CmuxCanvasUI | 3,559 | – | DELETE | niri columns replace the canvas. **Decision D3.** |
| CmuxSidebar | 3,200 | – | DELETE → REWRITE | Drag state, metadata models. New sidebar. |
| CmuxSidebarGit | 2,973 | – | KEEP-AS-LIBRARY | Git metadata watchers and PR polling for sidebar rows. |
| CmuxSidebarInterpreterService | 2,959 | – | DELETE | Out-of-process sidebar render worker. **D4.** |
| CmuxTerminalImport | 2,578 | – | KEEP-AS-LIBRARY | iTerm2/Kitty/etc. config import. |
| CmuxCore | 2,437 | – | KEEP (prune) | Remote config, port scan reconciler. Delete `DeviceWorkspaceLayoutNode*`. |
| CmuxAgentJournal | 2,397 | – | DELETE | cmux-tui journal owns agent lifecycle events. |
| CmuxCloudTui | 2,361 | indirect | DELETE | Manual-IO mirror of cloud cmux-tui. The new app talks to cmux-tui natively. |
| CmuxRemoteDaemon | 2,347 | – | DELETE | Client for the Go `daemon/remote` (29,759 lines). Replaced by cmux-remote. **D5.** |
| CmuxSwiftRender | 1,971 | – | DELETE | **D4.** |
| CMUXProjectModel | 1,808 | – | KEEP-AS-LIBRARY | Xcode project parsing (project panel). |
| CmuxFeedback | 1,688 | – | KEEP-AS-LIBRARY | Composer client and sink. The sheet gets restyled. |
| CmuxPanes | 1,626 | 11 files | DELETE | The Bonsplit adapter. |
| CmuxUpdaterUI | 1,513 | – | REWRITE | Update pill and popover in the new style. |
| CmuxCanvas | 1,448 | – | DELETE | **D3.** |
| CmuxExtensionKit | 1,431 | – | DELETE | Sidebar extension host. **D4** (third-party API?). |
| CmuxCloudMachines | 1,372 | – | KEEP-AS-LIBRARY | Create, delete, pin coordinators. |
| CmuxLiveEval | 1,160 | – | DELETE | Experiment. |
| CmuxWindowing | 1,133 | – | KEEP-AS-LIBRARY | Visible-frame fit, multi-window router. |
| CmuxPhonePush | 972 | – | KEEP-AS-LIBRARY | |
| CmuxFilePreviewCore | 799 | – | KEEP-AS-LIBRARY | |
| CmuxSudoBrokerUI | 758 | – | KEEP-AS-LIBRARY | |
| CmuxSidebarProviderKit | 709 | – | DELETE | **D4.** |
| CMUXDebugLog | 509 | – | KEEP-AS-LIBRARY | |
| CmuxAgentSessionStore | 431 | – | KEEP-AS-LIBRARY | Amp hook sessions. |
| CmuxHive | 418 | – | KEEP-AS-LIBRARY | |
| CmuxCloudImagePaste / TunnelCore / BannerCore | 359 / 324 / 137 | – | KEEP-AS-LIBRARY | |
| CmuxTestSupport | 165 | – | DELETE | |
| CmuxDiffComments | 137 | – | KEEP-AS-LIBRARY | |

Package totals: DELETE ≈ 138k (incl. CmuxSimulator 34k), REWRITE ≈ 56k (ControlSocket, SettingsUI, AppKitSupportUI, Sidebar, UpdaterUI), KEEP ≈ 149k (of which Browser + Cloud + Foundation + AgentLaunch + Settings ≈ 102k).

### 3.2 Packages/Shared (89,901 lines, used by iOS)

All KEEP-AS-LIBRARY, since iOS links them: CmuxIrohTransport 30,371, CMUXMobileCore 19,942, CmuxIrxTransport 13,648, CmuxAgentChat 9,167, CmuxAuthRuntime 7,843, CmuxSimulatorStreamKit 1,970, CmuxSentryTelemetry 1,719, CmuxSyncStore 1,696, CmuxTerminalPrediction 1,034, CmuxSyntaxHighlighting 761, CMUXAuthCore 543, CmuxWorkspacePresence 531, CmuxClientConfig 443, CmuxAPIClient 208, CmuxGhosttyKit 25 (needed if the new renderer still draws through Ghostty; see D6).

### 3.3 Sources/ (546,344 lines)

| Area | Lines | Verdict | Notes |
|---|---|---|---|
| `Terminal*` root (231 files) | 65,745 | DELETE | `TerminalController.swift` 16,396 (socket dispatch), `TerminalWindowPortal` 3,450, `TerminalNotificationStore` 2,954 (keep logic → CmuxNotifications), SSH detector. |
| `Workspace*` root (152) | 35,445 | DELETE | `Workspace.swift` 15,074, the main `BonsplitDelegate` (492 Bonsplit refs). |
| `App*` root + `AppDelegate*` (55 root) | 31,078 | DELETE → REWRITE | `AppDelegate.swift` 20,531. The new AppDelegate is small. |
| `Ghostty*` (63) | 21,350 | DELETE | `GhosttyTerminalView.swift` 14,536. Replaced by a cmux-tui attachment view (D6). |
| `ContentView*` (18) | 21,062 | DELETE | `ContentView.swift` 18,181, includes palette command registrations (mined for section 1). |
| `Remote*` + `Tmux*` (97) | 16,065 | DELETE | Remote tmux mirror, SSH bootstrap. cmux-remote. |
| `Cmux*` root (79) | 14,500 | SPLIT | KEEP `CmuxConfig*` (5,245) and `CmuxSSHURLRequest`. DELETE `CmuxEventBus`, `CmuxTopSnapshot`. |
| `Session*` (66) + `SessionPersistence` | 14,340 | DELETE | Session restore is cmux-tui's journal. `SessionIndex*` (vault) → see Vault. |
| `Text*` (TextBox, 44) | 10,548 | REWRITE (later) | TextBox input. Nice-to-have after v1. |
| `Dock*` (44) | 10,174 | DELETE | `DockSplitStore` is the second Bonsplit owner. The dock concept becomes a cmux-tui screen or column. |
| `Tab*` (27) | 9,479 | DELETE | `TabManager.swift` 7,245. |
| `File*` (36) | 7,989 | REWRITE | File explorer and drop overlays. |
| `Keyboard*` (20) | 7,624 | SPLIT | KEEP the id list and file store format (`KeyboardShortcutSettingsFileStore` 2,006, since users' `shortcuts` depend on it). REWRITE the `KeyboardShortcutSettings.swift` enum as the action registry. |
| `Agent*` root (52) | 7,209 | DELETE mostly | Fork/restore/hook delivery. Moves into cmux-tui hooks + CMUXAgentLaunch. |
| `Browser*` root (18) | 6,025 | REWRITE | Browser pane glue. |
| `Sidebar*` root + `Sources/Sidebar` | 5,692 + 16,800 | DELETE → REWRITE | AppKit list, 12,330. |
| `Vault*` (24) + `SessionIndex*` | 5,382 + ~6k | DEFER | Agent session browser. Keep as a later feature. |
| `Notification*` (34) | 5,241 | SPLIT | Policy logic → CmuxNotifications. UI rewritten. |
| `Restorable*`, `Sleepy*`, `SharedLiveAgentIndex` | 4,144 + 1,570 + 2,547 | DELETE | Agent restore (cmux-tui) and Sleepy mode (drop). |
| `Window*` (20) | 3,640 | REWRITE | |
| `Automation*` (13) | 2,537 | KEEP-AS-LIBRARY | Automation engine. Actions retarget the new registry. |
| `Right*` (right sidebar, 12) | 2,433 | REWRITE | |
| `Sources/Panels` | 62,216 | SPLIT | Browser panel 34,897 → REWRITE on CmuxBrowser/CEF. FilePreview 8,940 and Markdown 3,340 → REWRITE later. AgentSession 2,507, TerminalPanel 1,776 → DELETE. |
| `Sources/App` | 24,220 | SPLIT | ComputerUse 6,410 and AgentHibernation 4,591 → DELETE (hibernation is a cmux-tui idle policy). MemoryPressure 1,139 → DELETE. MenuBar profiling 1,891 → DELETE. |
| `Sources/Cloud` | 20,798 | REWRITE | `CloudTree*` (57 files) UI on top of the kept CmuxCloud library. |
| `Sources/Mobile` | 17,092 | KEEP (re-back) | MobileHost glue. Re-back terminals onto cmux-tui. |
| `Sources/Surfaces` | 16,150 | DELETE | Includes the current cmux-tui bridge `CmuxTuiSurfaceProvider*` (5,029, 30 files). Useful reference for protocol quirks, then delete. |
| `Sources/Feed` | 9,445 | REWRITE | Agent feed (permission, question, exit-plan replies). The contract stays. |
| `Sources/Devices` | 5,596 | DELETE | Device-link workspaces over irx. cmux-tui remote mounts replace them. |
| `Sources/Update` | 4,358 | REWRITE | Mostly notification-popover UI despite the name. |
| `Sources/Auth` | 2,792 | REWRITE UI | Sign-in panel. Core stays in Shared. |
| `Sources/Debug` | 2,335 | DELETE | |
| `Sources/Search` + `Find` | 2,098 + 1,340 | REWRITE | Global search. Find is terminal find via cmux-tui plus browser find. |
| `Sources/CommandPalette` | 1,281 | DELETE → REWRITE | |
| `Sources/Canvas` | 1,165 | DELETE | D3 |
| `Sources/RemoteTui` | 1,025 | DELETE | |
| `Sources/Settings` | 993 | REWRITE | |
| `Sources/Hive`, `AgentHibernation`, `Windowing` | 387 / 202 / 142 | KEEP / DELETE / KEEP | |

Rough Sources total: DELETE ≈ 330k, REWRITE-from-scratch surface ≈ 150k of old code (new code expected far smaller), KEEP ≈ 30k (config, automation, mobile glue, shortcut file store).

### 3.4 Other trees

| Tree | Lines | Verdict |
|---|---|---|
| `CLI/` | 102,404 | KEEP binary. Delete forwarded verb implementations; hooks ~8.3k REWRITE. |
| `daemon/remote` (Go) | 29,759 | DELETE if cmux-remote covers SSH and cloud (D5). |
| `Native/` (Nucleo FFI, DiffSidecar) | 4,599 | KEEP |
| `TunnelExtension` | 167 | KEEP |
| `webviews/` (TS) | 14,782 | KEEP what the kept panels use. |
| `cmuxTests` | 494,631 | DELETE with the code. 91 files import Bonsplit. Keep tests for kept libraries. |
| `cmuxUITests` | 27,260 | DELETE, then rewrite per feature. |
| `tests_v2` (Python, 128 files) | 30,308 | KEEP the forwarded namespaces as a contract suite against the new app (43 workspace + 37 surface + 13 pane files). Drop the 24 `debug.*` files. |
| `cmux-tui/apps/macos/TerminalBytesDemo` | 3,480 | Existing Swift demo client of cmux-tui. Seed for the attachment renderer. |

---

## 4. Bonsplit

`vendor/bonsplit` → `manaflow-ai/bonsplit`, pin `c5cb292`, uninitialized in this worktree. 24,804 lines (Sources 14,696 in 40 files, tests 9,463). Largest files: TabBarView 3,355, TabItemView 1,848, SplitContainerView 1,527, BonsplitController 1,311. 47 public types; the tree is exposed as `ExternalTreeNode/SplitNode/PaneNode`, `SplitNode` itself is internal.

### 4.1 Linkage

| Where | Detail |
|---|---|
| xcodeproj | `XCLocalSwiftPackageReference "bonsplit"` (A5001260), products for `cmux` (A5001261) and `cmuxTests` (A5001262). 57 pbxproj lines; 13 app files named `*Bonsplit*`. |
| Package.swift deps | CmuxPanes (11 src / 6 test files), CmuxBrowser (3 src), CmuxTerminal (1 src, `TerminalSurface+PortalLease`), CmuxWorkspaces (1 src, `TmuxPaneOverlayGeometry`), CmuxRemoteSession (test only). No iOS or Shared package. |
| Transitive | CmuxTerminal → CmuxCloudTui → CmuxCloud. CmuxWorkspaces → CmuxAppKitSupportUI. |

### 4.2 Importers

301 files: 283 `import`, 14 `public import`, 4 `@testable`. Sources root 141, cmuxTests 91, Sources/Surfaces 12, CmuxPanes 11+6, Sources/Panels 10, Sources/Cloud 6, Sidebar 4, Canvas 3, CmuxBrowser 3, Find/Feed 2 each, Update/Mobile/Devices/Auth/App 1 each. 43 more files use `bonsplitController` without importing. The `bonsplitController` identifier appears 2,187 times in 273 files.

Symbol totals: PaneID 410, TabID 208, BonsplitController 128, ExternalTreeNode 77, SplitOrientation 70, TabDragTransferRegistry 65, DropZone 55, BonsplitConfiguration 47, PixelRect 38, LayoutSnapshot 33.

### 4.3 Owners

| Role | Sites |
|---|---|
| `BonsplitDelegate` | `Workspace` (Workspace.swift:13439), `DockSplitStore` (DockSplitStore.swift:20), `RemoteTmuxWindowMirror` (+Bonsplit.swift:565) |
| `BonsplitController(` | Workspace.swift:4087, DockSplitStore.swift:354, RemoteTmuxWindowMirror+Bonsplit.swift:11, cmuxApp.swift:4337 (settings preview) |
| `BonsplitView(` | WorkspaceContentView.swift:220, DockSplitContentView.swift:18, RemoteTmuxWindowMirrorSplitView.swift:74, cmuxApp.swift:4258 |
| Adapter | CmuxPanes: `PaneLayoutService`, `PaneTreeModel`, `SplitLayoutModel`, `SessionSplitContainerLayoutCodec` (saved session format keyed by PaneID) |
| Persistence | `SessionPersistence.swift` aliases the CmuxPanes session types (lines 1686-1690) |

### 4.4 Top files by Bonsplit refs

Workspace.swift 492, RemoteTmuxWindowMirror+Bonsplit 60, DockSplitStore+PaneFocus 59, DockSplitStore 51, PaneDropContainer 50, Workspace+SurfaceNavigation 44, AppDelegate 42, TabManager 41, DockSplitStore+ShortcutCommands 39, TerminalController 38, DockSplitStore+TabContextActions 35, +ClosedItemHistory 32, +PortalDrop 30, WorkspaceContentView 29, TmuxPaneOverlayGeometryTests 25, SessionSplitContainerLayoutCodec 25, Workspace+CloudManualMirror 23, TerminalController+ControlPaneContext 21, DockSplitStore+SessionRestore 20, ContentView 20.

Every one of these files is already DELETE in section 3. Removing Bonsplit therefore needs no migration code: delete the owners, drop the xcodeproj reference and the submodule.

### 4.5 CI and scripts to clean

`scripts/ci/package-test-lane.sh` (bonsplit phase), `detect_ci_change_areas.py:836`, `ui_tests_dispatch.py:65`, `detect_linux_guard_changes.py:100`, `swiftpm-manifest-cache.sh:51`, `lint-stored-dispatch-work-items.py` (fails if dir missing), `verify-cmd-click-file-previews.sh` (uses a bonsplit fixture video), `localization-allowed-omissions.json`. Workflows: `ci-guards.yml:1169`, `seed-swiftpm-manifests.yml:67`, `app-host-test-rerun.yml:172`, `ci-macos.yml:3320`, `nightly.yml:1362`, `.github/swift-warning-budget.tsv:105-117` (13 budgeted warnings). Tests: 91 cmuxTests files, `BonsplitTabDragUITests`, and Python `test_split_flash_and_layout`, `test_close_surface_selection`, `test_terminal_focus_routing`, `test_multi_workspace_focus`.

---

## 5. Decisions for the user

| # | Decision | Default taken in this doc |
|---|---|---|
| D1 | Drop the iOS Simulator pane (34k) from v1? | DELETE; re-add later as a pane provider |
| D2 | Move agent resume/restore (CMUXAgentLaunch, 18.6k) into cmux-tui? | Keep as a Swift library for v1 |
| D3 | Canvas layout (CmuxCanvas + UI + socket `canvas.*`, ~6k): delete, since niri columns replace it? | DELETE; the `canvas` config key becomes a deprecation diagnostic |
| D4 | Custom sidebars / sidebar extensions (SwiftRender, interpreter service, ExtensionKit, ProviderKit, LiveEval, ~13k). Is `CMUXSidebarExtension` a public third-party API we must honor? | DELETE; point `customSidebars` at cmux-tui `sidebar-plugin` |
| D5 | Delete the Go remote daemon (29.8k) and CmuxRemote* (20.5k) in favor of cmux-tui cmux-remote? Needs parity for SSH, relay, port forward, cloud attach. | DELETE, gated on the parity check |
| D6 | Terminal rendering: does the Swift app render cmux-tui attachments through libghostty (keep CmuxGhosttyKit + Ghostty config parsing) or through cmux-tui `vt-state` cells? | Keep libghostty as renderer fed by the attachment stream; to be confirmed by the design wave |
| D7 | Keep `tests_v2` forwarded namespaces as the contract suite? | Yes |
