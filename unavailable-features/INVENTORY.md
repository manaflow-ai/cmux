# cmux-next unavailable features inventory

Source: `origin/feat-cmux-next` at 128c0a6240c (2026-10-19). Owner: a165 unless noted.

Method: every `registry.bindUnavailable(...)` call (an action that is greyed out with a reason in
the palette, menus, CLI `action run` and MCP), plus handler refusals that say "not available yet".
Conditional bindings (`bind(_:requires:)`, `bind(_:unavailable:)`) that grey out only while a
daemon or sign-in is missing are not listed: they work when their capability is present.

Size: **S** under a day (app only), **M** app + small daemon change or new UI, **L** new subsystem.

Status column: `todo`, `done <sha>`, `skip (<owner>)`.

## Owned by other agents (skipped)

| Item | Action IDs | Reason shown | File | Owner |
|---|---|---|---|---|
| Open Cloud as Pane | `palette.openCloudPane` | needs the Cloud panel as a pane | Handlers/PaneHandlers+Verbs.swift | a166 |
| Open Mobile Pairing | `palette.mobileConnect` (+ control `mobile.*` routes) | arrives with the iOS phase | Handlers/CloudHandlers.swift, Control/AppControl+Mobile.swift | a167 |
| Simulator panes (6) | `palette.newSimulatorPane`, `simulatorHome`, `simulatorRotateLeft`, `simulatorRotateRight`, `simulatorToggleAppearance`, `simulatorToggleSoftwareKeyboard` | needs simulator panes | Handlers/PaneHandlers+Verbs.swift | a160 (vphone-cli: Simulator mode) |
| Files as pane, file explorer, right sidebar Files/Find (11) | `palette.openFilesPane`, `palette.openFindPane`, `fileExplorerOpenSelection`, `fileExplorerOpenSelectionFinderAlias`, `fileExplorerOpenInCmux`, `fileExplorerReveal`, `fileExplorerCopyPath`, `fileExplorerCopyRelativePath`, `fileExplorerOpenWith`, `switchRightSidebarToFiles`, `switchRightSidebarToFind` | needs the Files/Find panel as a pane; needs app capability `file-explorer` | Handlers/PaneHandlers+Verbs.swift, Handlers/SidebarHandlers.swift | a123 (Finder parity) |
| Computer Use (3) | `computerUseFocus`, `computerUseFocusCallingTerminal`, `computerUseStop` | Computer Use integration is not ported | Handlers/AgentHandlers.swift | a144 (CLI/computer-use interop) |
| Cloud catalog rows without handler | `registry.unboundActionIDs(in: [.cloud])` (dynamic) | Cloud actions arrive with the Cloud wave | Handlers/CloudHandlers.swift | a166 |

## To implement (smallest first)

| # | Item | Action IDs | Reason shown | File | Size | Status |
|---|---|---|---|---|---|---|
| 1 | Clear Browser History | `palette.browserClearHistory` | cmux-next keeps no browser history store yet (stale: `HistoryService.clearPages` exists) | Handlers/BrowserHandlers.swift | S | done fe011be9836 |
| 2 | Restart CLI Listener | `palette.restartSocketListener` | needs app capability `control-socket-restart` | Handlers/SettingsHandlers.swift | S | done e1994e62187 |
| 3 | Open All Workspace PR Links | `palette.openWorkspacePullRequests` | needs app capability `github-integration` | Handlers/WorkspaceHandlers.swift | S | done 05fea21b22c |
| 4 | Move whole column (multi-pane) | `moveColumnLeft/Right` refusal | Moving a whole column is not available yet | Handlers/ColumnHandlers.swift | S | done 31c23ce112e |
| 5 | Toggle Match Terminal Background | `palette.toggleMatchTerminalBackground` | needs app capability `match-terminal-background` | Handlers/SidebarHandlers.swift | S | done 18a2e35fe98 |
| 6 | Enable/Disable cmux Browser | `palette.enableBrowser`, `palette.disableBrowser` | the cmux browser is always on | Handlers/BrowserHandlers.swift | S | done 60440702d7a |
| 7 | Toggle Omnibar | `palette.browserToggleOmnibar` | The address bar cannot be hidden yet | Handlers/BrowserHandlers.swift | S | done fb4220947fd + dc42d6f4d4f |
| 8 | Feature Flags | `help.featureFlags` | needs app capability `feature-flags` | Handlers/SettingsHandlers.swift | S | done cd01ce83231 (opens Settings > Advanced > Labs) |
| 9 | Mark agent chat unread | `palette.toggleTabUnread` on a read agent chat | Marking as unread is not available yet | Handlers/TabHandlers+More.swift | S | done 148d6a5e5d2 (an acpmux that refuses falls back to the daemon unread mark) |
| 10 | Restore Previous App Launch | `reopenPreviousSession` | needs daemon capability `closed-history-v1` | Handlers/WorkspaceHandlers.swift | M | done 9ed6bc901ed |
| 11 | Toggle Full Width Tab | `palette.toggleFullWidthTab` | needs full-width tab support in the tab strip | Handlers/TabHandlers+More.swift | M | done 034aa40ca6f |
| 12 | Sleepy Mode | `palette.sleepyMode` | needs app capability `sleepy-mode` | Handlers/WindowHandlers.swift | M | done f7ac14bca75 (left: classic theme/mascot/colors settings section, Low Power toggle, pets) |
| 13 | Task Manager (2) | `palette.openTaskManager`, `taskManager.killProcess` | needs app capability `task-manager` | Handlers/WindowHandlers.swift | M | done f4c2e82984 (test) + next commit (fix); Kill Process ends local processes only, a remote machine's processes are refused |
| 14 | Workspace description (2) | `editWorkspaceDescription`, `palette.clearWorkspaceDescription` | needs daemon capability `workspace-description-v1` | Handlers/WorkspaceMetadataHandlers.swift | M (Rust + app) | done 4656386e677 |
| 15 | Workspace status (3) | `markWorkspaceDone`, `cycleWorkspaceStatus`, `palette.workspaceStatus` | needs daemon capability `workspace-status-v1` | Handlers/WorkspaceMetadataHandlers.swift | M (Rust + app) | done 4656386e677 |
| 16 | Resume command (3) | `resumeCommandSet`, `resumeCommandEdit`, `resumeCommandClear` | needs daemon capability `resume-command` | Handlers/TerminalHandlers.swift | M (Rust + app) | done in 56971275af5 (the respawn types the line without Return) |
| 17 | Disconnect SSH Tab | `disconnectRemoteTab` | needs daemon capability `remote-ssh-tabs` | Handlers/TabHandlers+More.swift | M | done in bc6e8ddf2d4 + d6cc046b3f6 (disconnects the tab's SSH machine, as classic did) |
| 18 | Remote workspaces (3) | `reconnectWorkspace`, `disconnectWorkspace`, `copyWorkspaceSSHError` | needs daemon capability `remote-workspaces-v1` | Handlers/WorkspaceHandlers.swift | M | done in bc6e8ddf2d4 (acts on the workspace's SSH machine) |
| 19 | Find Work | `palette.findWork` | needs app capability `github-integration` | Handlers/WorkspaceHandlers.swift | M | done fa216b5093a |
| 20 | Screenshot Section | `browserScreenshotSection` | needs a selection overlay | Handlers/BrowserHandlers.swift | M | done b8230d79c38 |
| 21 | Layout templates (3) | `saveLayoutTemplate`, `palette.layout.open`, `manageLayouts` | needs daemon capability `layout-templates-v1` | Handlers/WorkspaceHandlers.swift | M | done 7a88d4bf7f2 (app-side templates, no daemon capability) |
| 22 | Workspace checklist (9) | `palette.addWorkspaceChecklistItem`, `toggleChecklistItemComplete`, `palette.openWorkspaceTodoPane`, `checklistEditItem`, `checklistMarkInProgress`, `checklistCompleteItem`, `checklistRemoveItem`, `checklistOpenAsPane`, `checklistAttachImages` | needs daemon capability `workspace-checklist-v1` | Handlers/WorkspaceMetadataHandlers.swift, Handlers/SidebarHandlers.swift | L (Rust + app + pane) | done a7a60a35dbb |
| 23 | TextBox composer (4) | `focusTextBoxInput`, `palette.terminalToggleTextBoxInput`, `cycleTextBoxSubmitAction`, `attachTextBoxFile` | needs the TextBox composer | Handlers/TerminalHandlers.swift | L | done 0295a5ca25a (slice: no image previews, diff comments, Claude ctrl+enter, cmux.json submit actions, show-on-new-terminals setting) |
| 24 | Right sidebar (6) | `toggleRightSidebar`, `focusRightSidebar`, `switchRightSidebarToSessions`, `switchRightSidebarToFeed`, `switchRightSidebarToDock`, `switchRightSidebarToMachines` | needs app capability `right-sidebar` | Handlers/SidebarHandlers.swift | L | done 7ac69b58e79 (no resize handle yet; Files and Find left to the file explorer owner) |
| 25 | Session vault (6) | `palette.openVaultPane`, `vaultFocusSession`, `vaultOpenSession`, `vaultResumeInNewWorkspace`, `vaultCopyResumeCommand`, `vaultOpenPullRequest` | needs the Vault panel / `session-vault` | Handlers/PaneHandlers+Verbs.swift, Handlers/SidebarHandlers.swift | L | done 380cd3c154e |
| 26 | Open Terminal as Chat | `palette.openTerminalChatView` | Agent chat views are not ported | Handlers/AgentHandlers.swift | L | done 0e035c2a1c5 |
| 27 | Claude/Codex Teams (2) | `palette.launchClaudeTeams`, `palette.launchCodexTeams` | Teams launcher is not ported | Handlers/AgentHandlers.swift | M | done dcfa67e721a (first slice: one terminal tab runs the agent in team mode; classic tmux-shim splits for Claude teammates and the Codex subagent split watcher are left) |
| 28 | React Grab | `toggleReactGrab` | React Grab injection is not ported | Handlers/BrowserHandlers.swift | M | done 2bdb267f752 |
| 29 | VS Code inline (3) | `palette.openFolderInVSCodeInline`, `palette.vscodeServeWebStop`, `palette.vscodeServeWebRestart` | inline VS Code server is not ported | Handlers/WorkspaceHandlers.swift, Handlers/BrowserHandlers.swift | L | done b3e95eba7ab |
| 30 | Upgrade to cmux Pro | `palette.pro.upgrade` | needs app capability `account-billing` | Handlers/SettingsHandlers.swift | M (billing: open the web billing page only, no money flow) | done 42084679509 (opens the web pricing page; no payment in the app) |
| 31 | Canvas layout (15) | `toggleCanvasLayout`, `canvasOverview`, `canvasTidy`, `canvasRevealFocusedPane`, `canvasZoomIn/Out/Reset`, `canvasAlign{Left,Right,Top,Bottom}`, `canvasEqualize{Widths,Heights}`, `canvasDistribute{Horizontally,Vertically}` | needs canvas layout | Handlers/PaneHandlers+Verbs.swift | L (new layout engine) | done 37e5e83a42a |

Not counted as unavailable: `hibernateUnsupported` (a real per-page condition: a page that cannot
keep its history refuses to hibernate), and per-invocation refusals with a target (no pane to the
right, nothing closed, etc.).

## Totals

- Action IDs greyed out with a reason: 100 (+2 refusals: column move, agent-chat mark unread).
- Owned by other agents: 22 IDs (a166, a167, a160, a123, a144).
- To implement here: 78 IDs + 2 refusals, in 31 rows.
