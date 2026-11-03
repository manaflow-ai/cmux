# Command palette audit (2026-10-20)

Every action the command palette offered on feat-cmux-next 55a6a413c5c8, with the class the audit gave it. Nothing is removed: every row stays a search result, a CLI verb and an MCP tool. The source of truth is `Packages/macOS/CmuxNext/Sources/CmuxNextActions/ActionDescriptor+PaletteRank.swift`; the rules are in [palette-ranking.md](palette-ranking.md) 5.4. This table is a snapshot of that file at the audit, not a second source.

- a. daily: first in its section, +120 inside a match class while typing.
- b. standard: unchanged.
- c. niche, family member or duplicate: last in its section or folded into one row on the empty query, −120 while typing. A row the focused pane cannot run stays listed, last in its section, dimmed with the reason.

## Summary

| Class | Rows | Empty query | Typing |
|---|---|---|---|
| a. daily | 43 | first in its section | +120 within a match tier |
| b. standard | 604 | its section, catalog order | unchanged |
| c. niche | 73 | last in its section | −120 within a match tier |
| c. family member | 359 | folded into its family row | matches, −120 |
| c. duplicate | 3 | folded into the row people know, same name | matches, −120 |
| total | 1082 | | |

Daily: Change Background…, Check for Updates…, Close Pane, Close Tab, Close Workspace, Connect to Machine…, Customize Appearance…, Decrease Font Size, Equalize Splits, Find in Directory…, Find…, Go to Workspace…, Increase Font Size, Jump to Latest Unread, New Agent Chat, New Browser Tab, New Cloud Workspace, New Tab, New Window, New Workspace, New Workspace on Machine…, Open Diff Viewer, Open File…, Open Folder…, Open Keyboard Shortcuts, Recently Closed…, Reload Configuration, Rename Tab…, Rename Workspace…, Reopen Closed Workspace, Reopen Last Closed Tab, Search All Windows…, Search Everything…, Search Tabs…, Set Terminal Theme…, Settings…, Split Down, Split Right, Start Agent…, Toggle Left Sidebar, Toggle Pane Zoom, Toggle Right Sidebar, Toggle Setting…

| Family row | Opens | Members |
|---|---|---|
| Workspace: Move… | its own page | 10: Move Workspace Up, Move Workspace Down, Move Workspace to Top, Move Workspace to Bottom… |
| Workspace: New or Duplicate… | its own page | 9: New Workspace Above, New Workspace Below, New Workspace at Top, New Workspace at Bottom… |
| Workspace: Close Several… | its own page | 6: Close Other Workspaces, Close Workspaces Above, Close Workspaces Below, Close All Workspaces… |
| Workspace: Sort… | its own page | 3: Sort Workspaces by Directory, Sort Workspaces by Last Used, Sort Workspaces by Name |
| Workspace Group: Move… | its own page | 7: Move Workspace Group Up, Move Workspace Group Down, Move Workspace Group to Top, Move Workspace Group to Bottom… |
| Workspace Group: Sort… | its own page | 3: Sort Group by Directory, Sort Group by Last Used, Sort Group by Name |
| Tab: Move… | its own page | 14: Move Tab Left, Move Tab Right, Move Tab to Next Pane, Move Tab to Previous Pane… |
| Tab: New in Position… | its own page | 6: New Tab After Current Tab, New Tab at End, New Tab at Start, New Tab to the Right… |
| Tab: Close Several… | its own page | 3: Close Other Tabs, Close Tabs to the Left, Close Tabs to the Right |
| Tab Group: Move… | its own page | 7: Move Tab Group Left, Move Tab Group Right, Move Tab Group to New Column, Move Tab Group to New Split… |
| Screen: Move… | its own page | 5: Move Screen Left, Move Screen Right, Move Screen to New Window, Move Screen to New Workspace… |
| Screen: Close Several… | its own page | 3: Close Other Screens, Close Screens to the Left, Close Screens to the Right |
| Screen Group: Move… | its own page | 5: Move Screen Group Left, Move Screen Group Right, Move Screen Group to New Window, Move Screen Group to New Workspace… |
| Pane: Swap… | its own page | 5: Swap Pane Left, Swap Pane Right, Swap Pane Up, Swap Pane Down… |
| Pane: Resize… | its own page | 4: Resize Pane Left, Resize Pane Right, Resize Pane Up, Resize Pane Down |
| Column: Width… | its own page | 6: Column Width: One Third, Column Width: Half, Column Width: Two Thirds, Column Width: Full… |
| Column: Dock or Float… | its own page | 7: Dock Column, Dock Column Left, Dock Column Right, Dock Column Top… |
| Canvas: Align and Distribute… | its own page | 8: Align Panes Left, Align Panes Right, Align Panes Top, Align Panes Bottom… |
| Phone: All Commands… | its own page | 21: Boot Phone, Shut Down Phone, List Phones, Take Phone Screenshot… |
| Cloud Machine: Files and Network… | its own page | 13: List Cloud Files…, Read Cloud File…, Write Cloud File…, Cloud File Details…… |
| Bookmarks: All Commands… | its own page | 15: Add Bookmark…, Bookmark All Tabs…, New Bookmark Folder…, Open Bookmark in New Tab… |
| Browser Profile: All Commands… | its own page | 19: New Browser Profile…, Rename Browser Profile…, Delete Browser Profile and Its Data…, Set Browser Profile Color…… |
| Animations… | its own page | 18: Toggle All Animations, Turn Off Animations, Use Normal Animations, Use Fast Animations… |
| Window Style… | its own page | 9: Window Style: Default, Window Style: Bare, Window Style: Card, Window Style: Card with Outlines… |
| Pane Borders and Focus Ring… | its own page | 9: Toggle Pane Borders, Toggle Thick Pane Borders, Use Theme Color for Pane Borders, Toggle Rounded Pane Corners… |
| Tab Hibernation… | its own page | 7: Turn Off Tab Hibernation, Hibernate Hidden Tabs After 1 Hour, Hibernate Hidden Tabs After 10 Minutes, Don't Keep Neighbor Tabs Awake… |
| Notifications: When to Clear… | its own page | 6: Clear Notifications on Click, Clear Notifications Only When Opened, Clear Notifications on Focus, Clear Notifications When Typing… |
| Fork Conversation… | its own page | 6: Fork Conversation to the Right, Fork Conversation to the Left, Fork Conversation Above, Fork Conversation Below… |
| Sidebar Section: Layout… | its own page | 14: Show as List, Show as Grid, Show on One Line, Set Section Alignment…… |
| Set Space Color… | existing action | 9: Space Color: Grey, Space Color: Red, Space Color: Orange, Space Color: Yellow… |
| Set Workspace Group Color… | existing action | 9: Workspace Group Color: Grey, Workspace Group Color: Red, Workspace Group Color: Orange, Workspace Group Color: Yellow… |
| Set Screen Color… | existing action | 9: Screen Color: Grey, Screen Color: Red, Screen Color: Orange, Screen Color: Yellow… |
| Set Screen Group Color… | existing action | 9: Screen Group Color: Grey, Screen Group Color: Red, Screen Group Color: Orange, Screen Group Color: Yellow… |
| Set Tab Group Color… | existing action | 9: Tab Group Color: Grey, Tab Group Color: Red, Tab Group Color: Orange, Tab Group Color: Yellow… |
| Set Density… | existing action | 5: Density: Ultra-compact, Density: Compact, Density: Cozy, Density: Comfortable… |
| Toggle Developer Tools | existing action | 41: Developer Tools: Open Docked, Developer Tools: Dock to Right, Developer Tools: Open in Separate Window, Developer Tools: Close… |
| Extensions… | existing action | 10: Run Extension Shortcut, Disable Extension, Enable Extension, Move Pinned Extension… |
| View Site Information | existing action | 10: About This Page, Show Certificate, Show Connection Details, Show Cookies and Site Data… |

| Duplicate | Folded into |
|---|---|
| New Workspace on Machine (`remote.newWorkspace`) | New Workspace on Machine… (`workspace.newOnMachine`) |
| Copy SSH Error (`remote.copyError`) | Copy SSH Error (`copyWorkspaceSSHError`) |
| Hide App (`sidebar.item.hideApp`) | Hide App… (`app.hide`) |

Niche: Allow Site Request, Always Center Focused Column, Attempt Update, Base Keymap…, Block Site Request, Center Focused Column on Overflow, Copy Agent Identifier, Copy Identifiers, Copy Machine ID, Copy Pane ID, Copy Tab ID, Copy Workspace Group ID, Copy Workspace ID, Copy Workspace ID and Ref, Decrease Workspace Font Size, Disable cmux Browser, Enable cmux Browser, Feature Flags, Go Back from Certificate Warning, Grant Accessibility Access, Grant Screen Recording Access, Hide Announcements, Hide Media Card Until Relaunch, Hide Profile Button, Import Workspaces from Classic cmux, Increase Workspace Font Size, Install cmux CLI in PATH, Kill Process…, Links: Open in Default Browser, Links: Open in cmux Browser, List Cloud Domains, List Cloud Networks, List Cloud Publications, Make This Mac a Server, Make cmux the Default Browser, Make cmux the Default Terminal, Never Show Media Card, Open Debug Settings, Open Site Settings of Blocked Download, Prepare Cloud File Transfer…, Proceed Past Certificate Warning (Unsafe), Promote Machine to Template, Quit and End Everything, Quit and End Sessions, Keep Layout, Quit and Keep Sessions, Reset Workspace Font Size, Restart CLI Listener, Restart VS Code Inline Server, Restart cmux-tui…, Roll Back to Previous Version…, Save Last 10 Seconds, Scroll Columns Minimally, Send Ctrl-F to Terminal, Show Announcements, Show Crash Logs, Show Ghostty Config Diagnostics, Show Media Card, Show Profile Button, Stop Serving, Stop VS Code Inline Server, Switch Update Channel…, Tabs: Use Scrolling Tabs, Tabs: Use Shrinking Tabs, Toggle Column Scroll Bar, Toggle React Grab, Uninstall cmux CLI from PATH, Use Chromium for New Browser Tabs, Use Minimal Titlebar, Use Standard Titlebar, Use WebKit for New Browser Tabs

## Every action

| Section | Action | Title | Default key | Class | Where it shows |
|---|---|---|---|---|---|
| Window | `about` | About cmux |  | b. standard | its section, catalog order |
| Window | `agentHistory.show` | Show Agent History |  | b. standard | its section, catalog order |
| Window | `closeAllWindows` | Close All Windows |  | b. standard | its section, catalog order |
| Window | `closeWindow` | Close Window | ⌃⌘W | b. standard | its section, catalog order |
| Window | `commandPalette` | Command Palette… | ⇧⌘P | b. standard | its section, catalog order |
| Window | `focusHistoryBack` | Go Back | ⌃- | b. standard | its section, catalog order |
| Window | `focusHistoryForward` | Go Forward | ⌃⇧- | b. standard | its section, catalog order |
| Window | `focusHistoryLast` | Go to Last Location |  | b. standard | its section, catalog order |
| Window | `globalSearch` | Search All Windows… | ⌥⌘F | a. daily | first in its section, +120 while typing |
| Window | `goToWorkspace` | Go to Workspace… | ⌘P | a. daily | first in its section, +120 while typing |
| Window | `hints.show` | Click by Hint |  | b. standard | its section, catalog order |
| Window | `history.clear` | Clear History… |  | b. standard | its section, catalog order |
| Window | `history.commands` | Command History… |  | b. standard | its section, catalog order |
| Window | `history.open` | Open History Entry… |  | b. standard | its section, catalog order |
| Window | `history.reopen` | Reopen Last Closed Item |  | b. standard | its section, catalog order |
| Window | `history.search` | Search History… |  | b. standard | its section, catalog order |
| Window | `history.show` | Show History |  | b. standard | its section, catalog order |
| Window | `home.addMembers` | Add People to Group… |  | b. standard | its section, catalog order |
| Window | `home.attachFiles` | Attach Files… |  | b. standard | its section, catalog order |
| Window | `home.channels` | Open Channels |  | b. standard | its section, catalog order |
| Window | `home.conversationInfo` | Conversation Info… |  | b. standard | its section, catalog order |
| Window | `home.createGroup` | New Group Chat… |  | b. standard | its section, catalog order |
| Window | `home.disableChannels` | Disable Channels |  | b. standard | its section, catalog order |
| Window | `home.enableChannels` | Enable Channels |  | b. standard | its section, catalog order |
| Window | `home.invite` | Invite to cmux-next… |  | b. standard | its section, catalog order |
| Window | `home.leaveConversation` | Leave Group… |  | b. standard | its section, catalog order |
| Window | `home.messageChiefPet` | Message the Chief |  | b. standard | its section, catalog order |
| Window | `home.messageTo` | Send Message To… |  | b. standard | its section, catalog order |
| Window | `home.muteConversation` | Hide Alerts |  | b. standard | its section, catalog order |
| Window | `home.newChief` | New Chief… |  | b. standard | its section, catalog order |
| Window | `home.newMessage` | New Message… |  | b. standard | its section, catalog order |
| Window | `home.nextConversation` | Next Conversation |  | b. standard | its section, catalog order |
| Window | `home.previousConversation` | Previous Conversation |  | b. standard | its section, catalog order |
| Window | `home.removeMember` | Remove from Group… |  | b. standard | its section, catalog order |
| Window | `home.renameConversation` | Rename Group Chat… |  | b. standard | its section, catalog order |
| Window | `home.replyToSelection` | Reply to Selection |  | b. standard | its section, catalog order |
| Window | `home.saveFlightRecording` | Save Last 10 Seconds |  | c. niche | last in its section, −120 while typing |
| Window | `home.sendMessage` | Send Message… |  | b. standard | its section, catalog order |
| Window | `home.setChiefReplies` | Set When Chiefs Reply… |  | b. standard | its section, catalog order |
| Window | `home.show` | Go to Home |  | b. standard | its section, catalog order |
| Window | `home.switchView` | Switch Home View |  | b. standard | its section, catalog order |
| Window | `home.tab` | Open Home in Tab |  | b. standard | its section, catalog order |
| Window | `home.toggleChiefPet` | Show Chief Pet |  | b. standard | its section, catalog order |
| Window | `home.togglePin` | Pin/Unpin Conversation |  | b. standard | its section, catalog order |
| Window | `home.unmuteConversation` | Show Alerts |  | b. standard | its section, catalog order |
| Window | `keepMacAwake` | Keep Mac Awake |  | b. standard | its section, catalog order |
| Window | `link.open` | Open Link… |  | b. standard | its section, catalog order |
| Window | `minimizeWindow` | Minimize |  | b. standard | its section, catalog order |
| Window | `music.open` | Play Music… |  | b. standard | its section, catalog order |
| Window | `music.stop` | Stop Music |  | b. standard | its section, catalog order |
| Window | `newIncognitoWindow` | New Incognito Window | ⌥⇧⌘N | b. standard | its section, catalog order |
| Window | `newWindow` | New Window | ⇧⌘N | a. daily | first in its section, +120 while typing |
| Window | `nowPlaying.hideCard` | Hide Media Card |  | b. standard | its section, catalog order |
| Window | `nowPlaying.hideCardUntilRelaunch` | Hide Media Card Until Relaunch |  | c. niche | last in its section, −120 while typing |
| Window | `nowPlaying.playPause` | Play/Pause Media |  | b. standard | its section, catalog order |
| Window | `openSettings` | Settings… | ⌘, | a. daily | first in its section, +120 while typing |
| Window | `palette.open` | Open Palette Scope… |  | b. standard | its section, catalog order |
| Window | `palette.openTaskManager` | Task Manager |  | b. standard | its section, catalog order |
| Window | `palette.sleepyMode` | Sleepy Mode |  | b. standard | its section, catalog order |
| Window | `quit` | Quit cmux | ⌘Q | b. standard | its section, catalog order |
| Window | `quitEndEverything` | Quit and End Everything |  | c. niche | last in its section, −120 while typing |
| Window | `quitEndSessions` | Quit and End Sessions, Keep Layout |  | c. niche | last in its section, −120 while typing |
| Window | `quitKeepSessions` | Quit and Keep Sessions |  | c. niche | last in its section, −120 while typing |
| Window | `recentlyClosed` | Recently Closed… |  | a. daily | first in its section, +120 while typing |
| Window | `recentlyFocused` | Location History… |  | b. standard | its section, catalog order |
| Window | `search.chats` | Search Everything… | ⇧⌘A | a. daily | first in its section, +120 while typing |
| Window | `selectNextWindow` | Select Next Window |  | b. standard | its section, catalog order |
| Window | `selectPreviousWindow` | Select Previous Window |  | b. standard | its section, catalog order |
| Window | `showHideAllWindows` | Show/Hide All Windows | ⌃⌥⌘. | b. standard | its section, catalog order |
| Window | `showMainWindow` | Show cmux |  | b. standard | its section, catalog order |
| Window | `taskManager.killProcess` | Kill Process… |  | c. niche | last in its section, −120 while typing |
| Window | `toggleFullScreen` | Toggle Full Screen | ⌃⌘F | b. standard | its section, catalog order |
| Window | `window.closeOthers` | Close Other Windows |  | b. standard | its section, catalog order |
| Window | `window.screenshot` | Screenshot Window |  | b. standard | its section, catalog order |
| Window | `zoomWindow` | Zoom |  | b. standard | its section, catalog order |
| Workspace | `clearWorkspaceNotifications` | Clear Workspace Notifications |  | b. standard | its section, catalog order |
| Workspace | `closeWorkspace` | Close Workspace | ⇧⌘W | a. daily | first in its section, +120 while typing |
| Workspace | `copyWorkspaceSSHError` | Copy SSH Error |  | b. standard | its section, catalog order |
| Workspace | `cycleWorkspaceStatus` | Cycle Workspace Status | ⇧⌘; | b. standard | its section, catalog order |
| Workspace | `disconnectWorkspace` | Disconnect Workspace |  | b. standard | its section, catalog order |
| Workspace | `editWorkspaceDescription` | Edit Workspace Description… | ⌥⌘E | b. standard | its section, catalog order |
| Workspace | `groupSelectedWorkspaces` | Group Selected Workspaces | ⇧⌘G | b. standard | its section, catalog order |
| Workspace | `manageLayouts` | Manage Layout Templates… |  | b. standard | its section, catalog order |
| Workspace | `markWorkspaceDone` | Mark Workspace as Done | ⌘; | b. standard | its section, catalog order |
| Workspace | `moveWorkspaceDown` | Move Workspace Down | ⌃⌥⌘] | c. family member | folded into Workspace: Move… |
| Workspace | `moveWorkspaceToGroup` | Move Workspace to Group… |  | c. family member | folded into Workspace: Move… |
| Workspace | `moveWorkspaceToNewWindow` | Move Workspace to New Window |  | c. family member | folded into Workspace: Move… |
| Workspace | `moveWorkspaceToWindow` | Move Workspace to Window… |  | c. family member | folded into Workspace: Move… |
| Workspace | `moveWorkspaceUp` | Move Workspace Up | ⌃⌥⌘[ | c. family member | folded into Workspace: Move… |
| Workspace | `newBrowserWorkspace` | New Browser Workspace | ⌥⌘N | b. standard | its section, catalog order |
| Workspace | `newTab` | New Workspace | ⌘N | a. daily | first in its section, +120 while typing |
| Workspace | `newWorkspaceGroup` | New Workspace Group | ⌃⌘G | b. standard | its section, catalog order |
| Workspace | `nextSidebarTab` | Next Sidebar Item | ⌃⌘] | b. standard | its section, catalog order |
| Workspace | `nextSidebarTabInGroup` | Next Workspace in Group |  | b. standard | its section, catalog order |
| Workspace | `nextWorkspaceGroup` | Next Workspace Group | ⌃⌥⇧⌘] | b. standard | its section, catalog order |
| Workspace | `openFolder` | Open Folder… | ⌘O | a. daily | first in its section, +120 while typing |
| Workspace | `palette.addWorkspaceChecklistItem` | Add Checklist Item… |  | b. standard | its section, catalog order |
| Workspace | `palette.clearWorkspaceDescription` | Clear Workspace Description |  | b. standard | its section, catalog order |
| Workspace | `palette.clearWorkspaceName` | Clear Workspace Name |  | b. standard | its section, catalog order |
| Workspace | `palette.closeOtherWorkspaces` | Close Other Workspaces |  | c. family member | folded into Workspace: Close Several… |
| Workspace | `palette.closeWorkspacesAbove` | Close Workspaces Above |  | c. family member | folded into Workspace: Close Several… |
| Workspace | `palette.closeWorkspacesBelow` | Close Workspaces Below |  | c. family member | folded into Workspace: Close Several… |
| Workspace | `palette.copyWorkspaceID` | Copy Workspace ID |  | c. niche | last in its section, −120 while typing |
| Workspace | `palette.copyWorkspaceIDAndRef` | Copy Workspace ID and Ref |  | c. niche | last in its section, −120 while typing |
| Workspace | `palette.copyWorkspaceLink` | Copy Workspace Link |  | b. standard | its section, catalog order |
| Workspace | `palette.findWork` | Find Work |  | b. standard | its section, catalog order |
| Workspace | `palette.layout.open` | New Workspace from Template… |  | b. standard | its section, catalog order |
| Workspace | `palette.markWorkspaceRead` | Mark Workspace as Read |  | b. standard | its section, catalog order |
| Workspace | `palette.markWorkspaceUnread` | Mark Workspace as Unread |  | b. standard | its section, catalog order |
| Workspace | `palette.moveWorkspaceToTop` | Move Workspace to Top |  | c. family member | folded into Workspace: Move… |
| Workspace | `palette.openFolderInVSCodeInline` | Open Folder in VS Code (Inline)… |  | b. standard | its section, catalog order |
| Workspace | `palette.openWorkspacePullRequests` | Open All Workspace PR Links |  | b. standard | its section, catalog order |
| Workspace | `palette.openWorkspaceTodoPane` | Open Todo Pane |  | b. standard | its section, catalog order |
| Workspace | `palette.resetWorkspaceColor` | Reset Workspace Color |  | b. standard | its section, catalog order |
| Workspace | `palette.toggleWorkspacePin` | Pin/Unpin Workspace |  | b. standard | its section, catalog order |
| Workspace | `palette.workspaceColor` | Set Workspace Color… |  | b. standard | its section, catalog order |
| Workspace | `palette.workspaceStatus` | Set Workspace Status… |  | b. standard | its section, catalog order |
| Workspace | `prevSidebarTab` | Previous Sidebar Item | ⌃⌘[ | b. standard | its section, catalog order |
| Workspace | `prevSidebarTabInGroup` | Previous Workspace in Group |  | b. standard | its section, catalog order |
| Workspace | `prevWorkspaceGroup` | Previous Workspace Group | ⌃⌥⇧⌘[ | b. standard | its section, catalog order |
| Workspace | `reconnectWorkspace` | Reconnect Workspace |  | b. standard | its section, catalog order |
| Workspace | `removeWorkspaceFromGroup` | Remove Workspace from Group |  | c. family member | folded into Workspace: Move… |
| Workspace | `renameWorkspace` | Rename Workspace… | ⇧⌘R | a. daily | first in its section, +120 while typing |
| Workspace | `reopenClosedWorkspace` | Reopen Closed Workspace |  | a. daily | first in its section, +120 while typing |
| Workspace | `reopenPreviousSession` | Restore Previous App Launch | ⇧⌘O | b. standard | its section, catalog order |
| Workspace | `revealWorkspaceInFinder` | Show Workspace in Finder |  | b. standard | its section, catalog order |
| Workspace | `saveLayoutTemplate` | Save Layout as Template… | ⌃⌘S | b. standard | its section, catalog order |
| Workspace | `selectWorkspaceByNumber` | Select Workspace 1…9 | ⌘1 | b. standard | its section, catalog order |
| Workspace | `space.clearColor` | Remove Space Color |  | b. standard | its section, catalog order |
| Workspace | `space.clearIcon` | Remove Space Icon |  | b. standard | its section, catalog order |
| Workspace | `space.clearTheme` | Reset Space Theme |  | b. standard | its section, catalog order |
| Workspace | `space.color.blue` | Space Color: Blue |  | c. family member | folded into Set Space Color… |
| Workspace | `space.color.cyan` | Space Color: Cyan |  | c. family member | folded into Set Space Color… |
| Workspace | `space.color.green` | Space Color: Green |  | c. family member | folded into Set Space Color… |
| Workspace | `space.color.grey` | Space Color: Grey |  | c. family member | folded into Set Space Color… |
| Workspace | `space.color.orange` | Space Color: Orange |  | c. family member | folded into Set Space Color… |
| Workspace | `space.color.pink` | Space Color: Pink |  | c. family member | folded into Set Space Color… |
| Workspace | `space.color.purple` | Space Color: Purple |  | c. family member | folded into Set Space Color… |
| Workspace | `space.color.red` | Space Color: Red |  | c. family member | folded into Set Space Color… |
| Workspace | `space.color.yellow` | Space Color: Yellow |  | c. family member | folded into Set Space Color… |
| Workspace | `space.delete` | Delete Space… |  | b. standard | its section, catalog order |
| Workspace | `space.move` | Move Space to Position… |  | b. standard | its section, catalog order |
| Workspace | `space.moveLeft` | Move Space Left |  | b. standard | its section, catalog order |
| Workspace | `space.moveRight` | Move Space Right |  | b. standard | its section, catalog order |
| Workspace | `space.new` | New Space |  | b. standard | its section, catalog order |
| Workspace | `space.newGroup` | New Group in Space |  | b. standard | its section, catalog order |
| Workspace | `space.newWindow` | New Window in Space… |  | b. standard | its section, catalog order |
| Workspace | `space.newWorkspace` | New Workspace in Space… |  | b. standard | its section, catalog order |
| Workspace | `space.next` | Next Space | ⌥⌘] | b. standard | its section, catalog order |
| Workspace | `space.previous` | Previous Space | ⌥⌘[ | b. standard | its section, catalog order |
| Workspace | `space.rename` | Rename Space… |  | b. standard | its section, catalog order |
| Workspace | `space.selectByNumber` | Select Space 1…9 | ⌃⌥1 | b. standard | its section, catalog order |
| Workspace | `space.setColor` | Set Space Color… |  | b. standard | its section, catalog order |
| Workspace | `space.setDefaults` | Set Space Terminal Defaults… |  | b. standard | its section, catalog order |
| Workspace | `space.setIcon` | Set Space Icon… |  | b. standard | its section, catalog order |
| Workspace | `space.setTheme` | Set Space Theme… |  | b. standard | its section, catalog order |
| Workspace | `space.switch` | Switch to Space… |  | b. standard | its section, catalog order |
| Workspace | `toggleChecklistItemComplete` | Toggle Checklist Item Complete | ⌘
 | b. standard | its section, catalog order |
| Workspace | `toggleFocusedWorkspaceGroupCollapsed` | Collapse/Expand Workspace Group | ⌃⌘. | b. standard | its section, catalog order |
| Workspace | `workspace.clearIcon` | Remove Workspace Icon |  | b. standard | its section, catalog order |
| Workspace | `workspace.clearTheme` | Reset Workspace Theme |  | b. standard | its section, catalog order |
| Workspace | `workspace.closeAll` | Close All Workspaces |  | c. family member | folded into Workspace: Close Several… |
| Workspace | `workspace.closeAllInAllWindows` | Close All Workspaces in All Windows |  | c. family member | folded into Workspace: Close Several… |
| Workspace | `workspace.closeOthersInGroup` | Close Other Workspaces in Group |  | c. family member | folded into Workspace: Close Several… |
| Workspace | `workspace.copyPath` | Copy Workspace Path |  | b. standard | its section, catalog order |
| Workspace | `workspace.duplicate` | Duplicate Workspace |  | c. family member | folded into Workspace: New or Duplicate… |
| Workspace | `workspace.duplicateTerminalsOnly` | Duplicate Workspace Without Browser Tabs |  | c. family member | folded into Workspace: New or Duplicate… |
| Workspace | `workspace.duplicateToSpace` | Duplicate Workspace into Space… |  | c. family member | folded into Workspace: New or Duplicate… |
| Workspace | `workspace.importClassic` | Import Workspaces from Classic cmux |  | c. niche | last in its section, −120 while typing |
| Workspace | `workspace.mergeInto` | Merge Workspace Into… |  | b. standard | its section, catalog order |
| Workspace | `workspace.moveToBottom` | Move Workspace to Bottom |  | c. family member | folded into Workspace: Move… |
| Workspace | `workspace.moveToNewGroup` | Move Workspace to New Group |  | c. family member | folded into Workspace: Move… |
| Workspace | `workspace.moveToSpace` | Move Workspace to Space… |  | c. family member | folded into Workspace: Move… |
| Workspace | `workspace.newAbove` | New Workspace Above |  | c. family member | folded into Workspace: New or Duplicate… |
| Workspace | `workspace.newAtBottom` | New Workspace at Bottom |  | c. family member | folded into Workspace: New or Duplicate… |
| Workspace | `workspace.newAtTop` | New Workspace at Top |  | c. family member | folded into Workspace: New or Duplicate… |
| Workspace | `workspace.newBelow` | New Workspace Below |  | c. family member | folded into Workspace: New or Duplicate… |
| Workspace | `workspace.newInNewGroup` | New Workspace in New Group |  | c. family member | folded into Workspace: New or Duplicate… |
| Workspace | `workspace.newLikeThis` | New Workspace Like This |  | c. family member | folded into Workspace: New or Duplicate… |
| Workspace | `workspace.newOnMachine` | New Workspace on Machine… |  | a. daily | first in its section, +120 while typing |
| Workspace | `workspace.selectFirst` | Select First Workspace |  | b. standard | its section, catalog order |
| Workspace | `workspace.selectLast` | Select Last Workspace |  | b. standard | its section, catalog order |
| Workspace | `workspace.selectLastUsed` | Switch to Last Used Workspace | ⌃⌘` | b. standard | its section, catalog order |
| Workspace | `workspace.setIcon` | Set Workspace Icon… |  | b. standard | its section, catalog order |
| Workspace | `workspace.setTheme` | Set Workspace Theme… |  | b. standard | its section, catalog order |
| Workspace | `workspace.setTint` | Set Workspace Tint… |  | b. standard | its section, catalog order |
| Workspace | `workspace.showResources` | Show Workspace Resource Usage |  | b. standard | its section, catalog order |
| Workspace | `workspace.sortByDirectory` | Sort Workspaces by Directory |  | c. family member | folded into Workspace: Sort… |
| Workspace | `workspace.sortByLastUsed` | Sort Workspaces by Last Used |  | c. family member | folded into Workspace: Sort… |
| Workspace | `workspace.sortByName` | Sort Workspaces by Name |  | c. family member | folded into Workspace: Sort… |
| Workspace | `workspace.toggleAudioMute` | Mute/Unmute Workspace Tabs |  | b. standard | its section, catalog order |
| Workspace | `workspace.toggleTop` | Add Workspace to Top/Remove from Top |  | b. standard | its section, catalog order |
| Workspace | `workspaceGroup.addToSection` | Add Group to Section… |  | b. standard | its section, catalog order |
| Workspace | `workspaceGroup.clearIcon` | Remove Workspace Group Icon |  | b. standard | its section, catalog order |
| Workspace | `workspaceGroup.clearNotifications` | Clear Group Notifications |  | b. standard | its section, catalog order |
| Workspace | `workspaceGroup.closeOthers` | Close Other Groups |  | b. standard | its section, catalog order |
| Workspace | `workspaceGroup.closeWorkspaces` | Close All Workspaces in Group |  | b. standard | its section, catalog order |
| Workspace | `workspaceGroup.collapse` | Collapse Workspace Group |  | b. standard | its section, catalog order |
| Workspace | `workspaceGroup.collapseAll` | Collapse All Groups |  | b. standard | its section, catalog order |
| Workspace | `workspaceGroup.collapseOthers` | Collapse Other Groups |  | b. standard | its section, catalog order |
| Workspace | `workspaceGroup.color.blue` | Workspace Group Color: Blue |  | c. family member | folded into Set Workspace Group Color… |
| Workspace | `workspaceGroup.color.cyan` | Workspace Group Color: Cyan |  | c. family member | folded into Set Workspace Group Color… |
| Workspace | `workspaceGroup.color.green` | Workspace Group Color: Green |  | c. family member | folded into Set Workspace Group Color… |
| Workspace | `workspaceGroup.color.grey` | Workspace Group Color: Grey |  | c. family member | folded into Set Workspace Group Color… |
| Workspace | `workspaceGroup.color.orange` | Workspace Group Color: Orange |  | c. family member | folded into Set Workspace Group Color… |
| Workspace | `workspaceGroup.color.pink` | Workspace Group Color: Pink |  | c. family member | folded into Set Workspace Group Color… |
| Workspace | `workspaceGroup.color.purple` | Workspace Group Color: Purple |  | c. family member | folded into Set Workspace Group Color… |
| Workspace | `workspaceGroup.color.red` | Workspace Group Color: Red |  | c. family member | folded into Set Workspace Group Color… |
| Workspace | `workspaceGroup.color.yellow` | Workspace Group Color: Yellow |  | c. family member | folded into Set Workspace Group Color… |
| Workspace | `workspaceGroup.copyID` | Copy Workspace Group ID |  | c. niche | last in its section, −120 while typing |
| Workspace | `workspaceGroup.delete` | Delete Group |  | b. standard | its section, catalog order |
| Workspace | `workspaceGroup.duplicate` | Duplicate Workspace Group |  | b. standard | its section, catalog order |
| Workspace | `workspaceGroup.editConfig` | Edit Group Config |  | b. standard | its section, catalog order |
| Workspace | `workspaceGroup.expand` | Expand Workspace Group |  | b. standard | its section, catalog order |
| Workspace | `workspaceGroup.expandAll` | Expand All Groups |  | b. standard | its section, catalog order |
| Workspace | `workspaceGroup.markRead` | Mark Group as Read |  | b. standard | its section, catalog order |
| Workspace | `workspaceGroup.markUnread` | Mark Group as Unread |  | b. standard | its section, catalog order |
| Workspace | `workspaceGroup.moveDown` | Move Workspace Group Down |  | c. family member | folded into Workspace Group: Move… |
| Workspace | `workspaceGroup.moveToBottom` | Move Workspace Group to Bottom |  | c. family member | folded into Workspace Group: Move… |
| Workspace | `workspaceGroup.moveToNewWindow` | Move Workspace Group to New Window |  | c. family member | folded into Workspace Group: Move… |
| Workspace | `workspaceGroup.moveToSpace` | Move Workspace Group to Space… |  | c. family member | folded into Workspace Group: Move… |
| Workspace | `workspaceGroup.moveToTop` | Move Workspace Group to Top |  | c. family member | folded into Workspace Group: Move… |
| Workspace | `workspaceGroup.moveToWindow` | Move Workspace Group to Window… |  | c. family member | folded into Workspace Group: Move… |
| Workspace | `workspaceGroup.moveUp` | Move Workspace Group Up |  | c. family member | folded into Workspace Group: Move… |
| Workspace | `workspaceGroup.newSubgroup` | New Subgroup |  | b. standard | its section, catalog order |
| Workspace | `workspaceGroup.newWorkspace` | New Workspace in Group |  | b. standard | its section, catalog order |
| Workspace | `workspaceGroup.rename` | Rename Group… |  | b. standard | its section, catalog order |
| Workspace | `workspaceGroup.setColor` | Set Workspace Group Color… |  | b. standard | its section, catalog order |
| Workspace | `workspaceGroup.setIcon` | Set Workspace Group Icon… |  | b. standard | its section, catalog order |
| Workspace | `workspaceGroup.sortByDirectory` | Sort Group by Directory |  | c. family member | folded into Workspace Group: Sort… |
| Workspace | `workspaceGroup.sortByLastUsed` | Sort Group by Last Used |  | c. family member | folded into Workspace Group: Sort… |
| Workspace | `workspaceGroup.sortByName` | Sort Group by Name |  | c. family member | folded into Workspace Group: Sort… |
| Workspace | `workspaceGroup.togglePin` | Pin/Unpin Group |  | b. standard | its section, catalog order |
| Workspace | `workspaceGroup.ungroup` | Ungroup Workspaces |  | b. standard | its section, catalog order |
| Panes | `canvasAlignBottom` | Align Panes Bottom |  | c. family member | folded into Canvas: Align and Distribute… |
| Panes | `canvasAlignLeft` | Align Panes Left |  | c. family member | folded into Canvas: Align and Distribute… |
| Panes | `canvasAlignRight` | Align Panes Right |  | c. family member | folded into Canvas: Align and Distribute… |
| Panes | `canvasAlignTop` | Align Panes Top |  | c. family member | folded into Canvas: Align and Distribute… |
| Panes | `canvasDistributeHorizontally` | Distribute Panes Horizontally |  | c. family member | folded into Canvas: Align and Distribute… |
| Panes | `canvasDistributeVertically` | Distribute Panes Vertically |  | c. family member | folded into Canvas: Align and Distribute… |
| Panes | `canvasEqualizeHeights` | Equalize Pane Heights |  | c. family member | folded into Canvas: Align and Distribute… |
| Panes | `canvasEqualizeWidths` | Equalize Pane Widths |  | c. family member | folded into Canvas: Align and Distribute… |
| Panes | `canvasOverview` | Canvas Overview | ⌃⌘O | b. standard | its section, catalog order |
| Panes | `canvasRevealFocusedPane` | Reveal Focused Pane on Canvas | ⌃⌘R | b. standard | its section, catalog order |
| Panes | `canvasTidy` | Tidy Canvas | ⌃⌘T | b. standard | its section, catalog order |
| Panes | `canvasZoomIn` | Canvas Zoom In | ⌥⌘= | b. standard | its section, catalog order |
| Panes | `canvasZoomOut` | Canvas Zoom Out | ⌥⌘- | b. standard | its section, catalog order |
| Panes | `canvasZoomReset` | Canvas Actual Size | ⌘0 | b. standard | its section, catalog order |
| Panes | `closePane` | Close Pane |  | a. daily | first in its section, +120 while typing |
| Panes | `column.center` | Center Column |  | b. standard | its section, catalog order |
| Panes | `column.cycleWidth` | Cycle Column Width |  | c. family member | folded into Column: Width… |
| Panes | `column.cycleWidthBack` | Cycle Column Width Backward |  | c. family member | folded into Column: Width… |
| Panes | `column.dock` | Dock Column | ⌃⌘P | c. family member | folded into Column: Dock or Float… |
| Panes | `column.dockBottom` | Dock Column Bottom |  | c. family member | folded into Column: Dock or Float… |
| Panes | `column.dockLeft` | Dock Column Left |  | c. family member | folded into Column: Dock or Float… |
| Panes | `column.dockRight` | Dock Column Right |  | c. family member | folded into Column: Dock or Float… |
| Panes | `column.dockTop` | Dock Column Top |  | c. family member | folded into Column: Dock or Float… |
| Panes | `column.float` | Float Column |  | c. family member | folded into Column: Dock or Float… |
| Panes | `column.focusLeft` | Focus Column Left |  | b. standard | its section, catalog order |
| Panes | `column.focusRight` | Focus Column Right |  | b. standard | its section, catalog order |
| Panes | `column.moveLeft` | Move Column Left |  | b. standard | its section, catalog order |
| Panes | `column.moveRight` | Move Column Right |  | b. standard | its section, catalog order |
| Panes | `column.undock` | Undock Column |  | c. family member | folded into Column: Dock or Float… |
| Panes | `column.widthFull` | Column Width: Full |  | c. family member | folded into Column: Width… |
| Panes | `column.widthHalf` | Column Width: Half |  | c. family member | folded into Column: Width… |
| Panes | `column.widthOneThird` | Column Width: One Third |  | c. family member | folded into Column: Width… |
| Panes | `column.widthTwoThirds` | Column Width: Two Thirds |  | c. family member | folded into Column: Width… |
| Panes | `decreaseWorkspaceTerminalFontSize` | Decrease Workspace Font Size | ⌘- | c. niche | last in its section, −120 while typing |
| Panes | `equalizeSplits` | Equalize Splits | ⌃⌘= | a. daily | first in its section, +120 while typing |
| Panes | `file.open` | Open File… |  | a. daily | first in its section, +120 while typing |
| Panes | `files.open` | Open Files |  | b. standard | its section, catalog order |
| Panes | `focusDown` | Focus Pane Below | ⌥⌘ | b. standard | its section, catalog order |
| Panes | `focusLeft` | Focus Pane Left | ⌥⌘ | b. standard | its section, catalog order |
| Panes | `focusNextPane` | Focus Next Pane |  | b. standard | its section, catalog order |
| Panes | `focusPaneByNumber` | Focus Pane 1…9 | ⌃⌘1 | b. standard | its section, catalog order |
| Panes | `focusPreviousPane` | Focus Previous Pane |  | b. standard | its section, catalog order |
| Panes | `focusRight` | Focus Pane Right | ⌥⌘ | b. standard | its section, catalog order |
| Panes | `focusUp` | Focus Pane Above | ⌥⌘ | b. standard | its section, catalog order |
| Panes | `increaseWorkspaceTerminalFontSize` | Increase Workspace Font Size | ⌘= | c. niche | last in its section, −120 while typing |
| Panes | `layout.undo` | Undo Layout Change |  | b. standard | its section, catalog order |
| Panes | `newColumn` | New Column | ⌃⌘X | b. standard | its section, catalog order |
| Panes | `newPaneAutoLayout` | New Pane (Auto Layout) | ⌃⌘N | b. standard | its section, catalog order |
| Panes | `newRow` | New Row | ⌃⇧⌘X | b. standard | its section, catalog order |
| Panes | `palette.newSimulatorPane` | New Simulator Pane |  | b. standard | its section, catalog order |
| Panes | `palette.openCloudPane` | Open Cloud as Pane |  | b. standard | its section, catalog order |
| Panes | `palette.openFilesPane` | Open Files as Pane |  | b. standard | its section, catalog order |
| Panes | `palette.openFindPane` | Open Find as Pane |  | b. standard | its section, catalog order |
| Panes | `palette.openVaultPane` | Open Vault as Pane |  | b. standard | its section, catalog order |
| Panes | `palette.swapWithSession` | Swap with Session… |  | c. family member | folded into Pane: Swap… |
| Panes | `pane.clearBackground` | Reset Pane Background |  | b. standard | its section, catalog order |
| Panes | `pane.closeOthers` | Close Other Panes |  | b. standard | its section, catalog order |
| Panes | `pane.focus` | Show Pane |  | b. standard | its section, catalog order |
| Panes | `pane.moveToNewWindow` | Move Pane to New Window |  | b. standard | its section, catalog order |
| Panes | `pane.moveToNewWorkspace` | Move Pane to New Workspace |  | b. standard | its section, catalog order |
| Panes | `pane.screenshot` | Screenshot Pane |  | b. standard | its section, catalog order |
| Panes | `pane.setBackground` | Set Pane Background… |  | b. standard | its section, catalog order |
| Panes | `pane.setTint` | Set Pane Tint… |  | b. standard | its section, catalog order |
| Panes | `pane.toggleTabBar` | Show Tab Bar |  | b. standard | its section, catalog order |
| Panes | `renamePane` | Rename Pane… |  | b. standard | its section, catalog order |
| Panes | `resetWorkspaceTerminalFontSize` | Reset Workspace Font Size | ⌘0 | c. niche | last in its section, −120 while typing |
| Panes | `resizePaneDown` | Resize Pane Down | ⌃⇧J | c. family member | folded into Pane: Resize… |
| Panes | `resizePaneLeft` | Resize Pane Left | ⌃⇧H | c. family member | folded into Pane: Resize… |
| Panes | `resizePaneRight` | Resize Pane Right | ⌃⇧L | c. family member | folded into Pane: Resize… |
| Panes | `resizePaneUp` | Resize Pane Up | ⌃⇧K | c. family member | folded into Pane: Resize… |
| Panes | `simulatorHome` | Simulator: Home | ⇧⌘H | b. standard | its section, catalog order |
| Panes | `simulatorRotateLeft` | Simulator: Rotate Left | ⌘ | b. standard | its section, catalog order |
| Panes | `simulatorRotateRight` | Simulator: Rotate Right | ⌘ | b. standard | its section, catalog order |
| Panes | `simulatorToggleAppearance` | Simulator: Toggle Appearance | ⇧⌘A | b. standard | its section, catalog order |
| Panes | `simulatorToggleSoftwareKeyboard` | Simulator: Toggle Software Keyboard | ⇧⌘K | b. standard | its section, catalog order |
| Panes | `splitDown` | Split Down | ⇧⌘D | a. daily | first in its section, +120 while typing |
| Panes | `splitLeft` | Split Left |  | b. standard | its section, catalog order |
| Panes | `splitRight` | Split Right | ⌘D | a. daily | first in its section, +120 while typing |
| Panes | `splitUp` | Split Up |  | b. standard | its section, catalog order |
| Panes | `swapPaneDown` | Swap Pane Down |  | c. family member | folded into Pane: Swap… |
| Panes | `swapPaneLeft` | Swap Pane Left |  | c. family member | folded into Pane: Swap… |
| Panes | `swapPaneRight` | Swap Pane Right |  | c. family member | folded into Pane: Swap… |
| Panes | `swapPaneUp` | Swap Pane Up |  | c. family member | folded into Pane: Swap… |
| Panes | `toggleCanvasLayout` | Toggle Canvas Layout | ⌃⌘C | b. standard | its section, catalog order |
| Panes | `toggleSplitZoom` | Toggle Pane Zoom | ⇧⌘
 | a. daily | first in its section, +120 while typing |
| Panes | `triggerFlash` | Flash Focused Pane | ⇧⌘H | b. standard | its section, catalog order |
| Screens | `screen.clearColor` | Remove Screen Color |  | b. standard | its section, catalog order |
| Screens | `screen.clearIcon` | Remove Screen Icon |  | b. standard | its section, catalog order |
| Screens | `screen.clearName` | Clear Screen Name |  | b. standard | its section, catalog order |
| Screens | `screen.close` | Close Screen |  | b. standard | its section, catalog order |
| Screens | `screen.closeOthers` | Close Other Screens |  | c. family member | folded into Screen: Close Several… |
| Screens | `screen.closeToLeft` | Close Screens to the Left |  | c. family member | folded into Screen: Close Several… |
| Screens | `screen.closeToRight` | Close Screens to the Right |  | c. family member | folded into Screen: Close Several… |
| Screens | `screen.color.blue` | Screen Color: Blue |  | c. family member | folded into Set Screen Color… |
| Screens | `screen.color.cyan` | Screen Color: Cyan |  | c. family member | folded into Set Screen Color… |
| Screens | `screen.color.green` | Screen Color: Green |  | c. family member | folded into Set Screen Color… |
| Screens | `screen.color.grey` | Screen Color: Grey |  | c. family member | folded into Set Screen Color… |
| Screens | `screen.color.orange` | Screen Color: Orange |  | c. family member | folded into Set Screen Color… |
| Screens | `screen.color.pink` | Screen Color: Pink |  | c. family member | folded into Set Screen Color… |
| Screens | `screen.color.purple` | Screen Color: Purple |  | c. family member | folded into Set Screen Color… |
| Screens | `screen.color.red` | Screen Color: Red |  | c. family member | folded into Set Screen Color… |
| Screens | `screen.color.yellow` | Screen Color: Yellow |  | c. family member | folded into Set Screen Color… |
| Screens | `screen.duplicate` | Duplicate Screen |  | b. standard | its section, catalog order |
| Screens | `screen.focus` | Show Screen |  | b. standard | its section, catalog order |
| Screens | `screen.moveLeft` | Move Screen Left |  | c. family member | folded into Screen: Move… |
| Screens | `screen.moveRight` | Move Screen Right |  | c. family member | folded into Screen: Move… |
| Screens | `screen.moveToNewWindow` | Move Screen to New Window |  | c. family member | folded into Screen: Move… |
| Screens | `screen.moveToNewWorkspace` | Move Screen to New Workspace |  | c. family member | folded into Screen: Move… |
| Screens | `screen.moveToWorkspace` | Move Screen to Workspace… |  | c. family member | folded into Screen: Move… |
| Screens | `screen.new` | New Screen |  | b. standard | its section, catalog order |
| Screens | `screen.newWith` | New Screen With… |  | b. standard | its section, catalog order |
| Screens | `screen.next` | Next Screen |  | b. standard | its section, catalog order |
| Screens | `screen.previous` | Previous Screen |  | b. standard | its section, catalog order |
| Screens | `screen.rename` | Rename Screen… |  | b. standard | its section, catalog order |
| Screens | `screen.reopenClosed` | Reopen Closed Screen |  | b. standard | its section, catalog order |
| Screens | `screen.select` | Select Screen 1…9 |  | b. standard | its section, catalog order |
| Screens | `screen.selectLast` | Select Last Screen |  | b. standard | its section, catalog order |
| Screens | `screen.setColor` | Set Screen Color… |  | b. standard | its section, catalog order |
| Screens | `screen.setIcon` | Set Screen Icon… |  | b. standard | its section, catalog order |
| Screens | `screen.togglePin` | Pin/Unpin Screen |  | b. standard | its section, catalog order |
| Screens | `screenGroup.addScreen` | Add Screen to Group… |  | b. standard | its section, catalog order |
| Screens | `screenGroup.clearIcon` | Remove Screen Group Icon |  | b. standard | its section, catalog order |
| Screens | `screenGroup.close` | Close Screen Group |  | b. standard | its section, catalog order |
| Screens | `screenGroup.collapse` | Collapse Screen Group |  | b. standard | its section, catalog order |
| Screens | `screenGroup.color.blue` | Screen Group Color: Blue |  | c. family member | folded into Set Screen Group Color… |
| Screens | `screenGroup.color.cyan` | Screen Group Color: Cyan |  | c. family member | folded into Set Screen Group Color… |
| Screens | `screenGroup.color.green` | Screen Group Color: Green |  | c. family member | folded into Set Screen Group Color… |
| Screens | `screenGroup.color.grey` | Screen Group Color: Grey |  | c. family member | folded into Set Screen Group Color… |
| Screens | `screenGroup.color.orange` | Screen Group Color: Orange |  | c. family member | folded into Set Screen Group Color… |
| Screens | `screenGroup.color.pink` | Screen Group Color: Pink |  | c. family member | folded into Set Screen Group Color… |
| Screens | `screenGroup.color.purple` | Screen Group Color: Purple |  | c. family member | folded into Set Screen Group Color… |
| Screens | `screenGroup.color.red` | Screen Group Color: Red |  | c. family member | folded into Set Screen Group Color… |
| Screens | `screenGroup.color.yellow` | Screen Group Color: Yellow |  | c. family member | folded into Set Screen Group Color… |
| Screens | `screenGroup.create` | Add Screen to New Group |  | b. standard | its section, catalog order |
| Screens | `screenGroup.deleteSaved` | Delete Saved Screen Group… |  | b. standard | its section, catalog order |
| Screens | `screenGroup.expand` | Expand Screen Group |  | b. standard | its section, catalog order |
| Screens | `screenGroup.moveLeft` | Move Screen Group Left |  | c. family member | folded into Screen Group: Move… |
| Screens | `screenGroup.moveRight` | Move Screen Group Right |  | c. family member | folded into Screen Group: Move… |
| Screens | `screenGroup.moveToNewWindow` | Move Screen Group to New Window |  | c. family member | folded into Screen Group: Move… |
| Screens | `screenGroup.moveToNewWorkspace` | Move Screen Group to New Workspace |  | c. family member | folded into Screen Group: Move… |
| Screens | `screenGroup.moveToWorkspace` | Move Screen Group to Workspace… |  | c. family member | folded into Screen Group: Move… |
| Screens | `screenGroup.newScreen` | New Screen in Group |  | b. standard | its section, catalog order |
| Screens | `screenGroup.removeScreen` | Remove Screen from Group |  | b. standard | its section, catalog order |
| Screens | `screenGroup.rename` | Rename Screen Group… |  | b. standard | its section, catalog order |
| Screens | `screenGroup.reopenSaved` | Reopen Saved Screen Group… |  | b. standard | its section, catalog order |
| Screens | `screenGroup.save` | Save Screen Group |  | b. standard | its section, catalog order |
| Screens | `screenGroup.setColor` | Set Screen Group Color… |  | b. standard | its section, catalog order |
| Screens | `screenGroup.setIcon` | Set Screen Group Icon… |  | b. standard | its section, catalog order |
| Screens | `screenGroup.toggleCollapsed` | Collapse/Expand Screen Group |  | b. standard | its section, catalog order |
| Screens | `screenGroup.ungroup` | Ungroup Screens |  | b. standard | its section, catalog order |
| Screens | `screenGroup.unsave` | Unsave Screen Group |  | b. standard | its section, catalog order |
| Tabs | `closeOtherTabsInPane` | Close Other Tabs | ⌥⌘T | c. family member | folded into Tab: Close Several… |
| Tabs | `closeTab` | Close Tab | ⌘W | a. daily | first in its section, +120 while typing |
| Tabs | `closeTabsToLeft` | Close Tabs to the Left |  | c. family member | folded into Tab: Close Several… |
| Tabs | `closeTabsToRight` | Close Tabs to the Right |  | c. family member | folded into Tab: Close Several… |
| Tabs | `disconnectRemoteTab` | Disconnect SSH Tab |  | b. standard | its section, catalog order |
| Tabs | `duplicateTab` | Duplicate Tab |  | b. standard | its section, catalog order |
| Tabs | `focusLocation` | Focus Location Bar | ⌘L | b. standard | its section, catalog order |
| Tabs | `hibernateTab` | Hibernate Tab |  | b. standard | its section, catalog order |
| Tabs | `moveSurfaceLeft` | Move Tab Left | ⌥⇧⌘[ | c. family member | folded into Tab: Move… |
| Tabs | `moveSurfaceRight` | Move Tab Right | ⌥⇧⌘] | c. family member | folded into Tab: Move… |
| Tabs | `moveSurfaceToNextPane` | Move Tab to Next Pane | ⌃⇧⌘] | c. family member | folded into Tab: Move… |
| Tabs | `moveSurfaceToPaneDown` | Move Tab to Pane Below | ⌥⇧⌘ | c. family member | folded into Tab: Move… |
| Tabs | `moveSurfaceToPaneLeft` | Move Tab to Pane Left | ⌥⇧⌘ | c. family member | folded into Tab: Move… |
| Tabs | `moveSurfaceToPaneRight` | Move Tab to Pane Right | ⌥⇧⌘ | c. family member | folded into Tab: Move… |
| Tabs | `moveSurfaceToPaneUp` | Move Tab to Pane Above | ⌥⇧⌘ | c. family member | folded into Tab: Move… |
| Tabs | `moveSurfaceToPreviousPane` | Move Tab to Previous Pane | ⌃⇧⌘[ | c. family member | folded into Tab: Move… |
| Tabs | `navigate.next` | Next Tab or Workspace |  | b. standard | its section, catalog order |
| Tabs | `navigate.previous` | Previous Tab or Workspace |  | b. standard | its section, catalog order |
| Tabs | `newSurface` | New Terminal Tab | ⌃` | b. standard | its section, catalog order |
| Tabs | `newTab.afterCurrent` | New Tab After Current Tab |  | c. family member | folded into Tab: New in Position… |
| Tabs | `newTab.atEnd` | New Tab at End |  | c. family member | folded into Tab: New in Position… |
| Tabs | `newTab.atStart` | New Tab at Start |  | c. family member | folded into Tab: New in Position… |
| Tabs | `newTab.default` | New Tab | ⌘T | a. daily | first in its section, +120 while typing |
| Tabs | `newTab.horizontal` | New Horizontal Tab |  | c. family member | folded into Tab: New in Position… |
| Tabs | `newTab.ofKind` | New Tab of the Same Kind |  | c. family member | folded into Tab: New in Position… |
| Tabs | `newTab.page` | New Tab Page |  | b. standard | its section, catalog order |
| Tabs | `newTab.submit` | New Tab from Text |  | b. standard | its section, catalog order |
| Tabs | `newTab.toRight` | New Tab to the Right |  | c. family member | folded into Tab: New in Position… |
| Tabs | `nextSurface` | Next Tab in Pane | ⌃	 | b. standard | its section, catalog order |
| Tabs | `openBrowser` | New Browser Tab | ⇧⌘L | a. daily | first in its section, +120 while typing |
| Tabs | `openBrowser.webkit` | New WebKit Tab |  | b. standard | its section, catalog order |
| Tabs | `palette.clearTabName` | Clear Tab Name |  | b. standard | its section, catalog order |
| Tabs | `palette.copyIdentifiers` | Copy Identifiers |  | c. niche | last in its section, −120 while typing |
| Tabs | `palette.copyPaneID` | Copy Pane ID |  | c. niche | last in its section, −120 while typing |
| Tabs | `palette.copyPaneLink` | Copy Pane Link |  | b. standard | its section, catalog order |
| Tabs | `palette.copySurfaceID` | Copy Tab ID |  | c. niche | last in its section, −120 while typing |
| Tabs | `palette.copySurfaceLink` | Copy Tab Link |  | b. standard | its section, catalog order |
| Tabs | `palette.moveTabToNewWorkspace` | Move Tab to New Workspace |  | c. family member | folded into Tab: Move… |
| Tabs | `palette.toggleFullWidthTab` | Toggle Full Width Tab |  | b. standard | its section, catalog order |
| Tabs | `palette.toggleTabPin` | Pin/Unpin Tab | ⌥⌘P | b. standard | its section, catalog order |
| Tabs | `palette.toggleTabUnread` | Mark Tab Unread |  | b. standard | its section, catalog order |
| Tabs | `prevSurface` | Previous Tab in Pane | ⌃⇧	 | b. standard | its section, catalog order |
| Tabs | `reloadTab` | Reload Tab |  | b. standard | its section, catalog order |
| Tabs | `renameTab` | Rename Tab… | ⌘R | a. daily | first in its section, +120 while typing |
| Tabs | `reopenClosedBrowserPanel` | Reopen Last Closed Tab | ⇧⌘T | a. daily | first in its section, +120 while typing |
| Tabs | `selectSurfaceByNumber` | Select Tab 1…9 | ⌃1 | b. standard | its section, catalog order |
| Tabs | `tab.clearIcon` | Remove Tab Icon |  | b. standard | its section, catalog order |
| Tabs | `tab.focus` | Show Tab |  | b. standard | its section, catalog order |
| Tabs | `tab.moveToNewColumn` | Move Tab to New Column |  | c. family member | folded into Tab: Move… |
| Tabs | `tab.moveToNewDockColumn` | Move Tab to New Dock Column |  | c. family member | folded into Tab: Move… |
| Tabs | `tab.moveToNewSplit` | Move Tab to New Split |  | c. family member | folded into Tab: Move… |
| Tabs | `tab.moveToNewWindow` | Move Tab to New Window |  | c. family member | folded into Tab: Move… |
| Tabs | `tab.moveToWorkspace` | Move Tab to Workspace… |  | c. family member | folded into Tab: Move… |
| Tabs | `tab.muteAudio` | Mute Tab |  | b. standard | its section, catalog order |
| Tabs | `tab.muteOtherAudio` | Mute Other Tabs |  | b. standard | its section, catalog order |
| Tabs | `tab.restart` | Restart Shell Here |  | b. standard | its section, catalog order |
| Tabs | `tab.screenshot` | Screenshot Tab |  | b. standard | its section, catalog order |
| Tabs | `tab.search` | Search Tabs… |  | a. daily | first in its section, +120 while typing |
| Tabs | `tab.setIcon` | Set Tab Icon… |  | b. standard | its section, catalog order |
| Tabs | `tab.showResources` | Show Tab Resource Usage |  | b. standard | its section, catalog order |
| Tabs | `tab.unmuteAudio` | Unmute Tab |  | b. standard | its section, catalog order |
| Tabs | `tabGroup.addTab` | Add Tab to Group… |  | b. standard | its section, catalog order |
| Tabs | `tabGroup.clearIcon` | Remove Tab Group Icon |  | b. standard | its section, catalog order |
| Tabs | `tabGroup.close` | Close Tab Group |  | b. standard | its section, catalog order |
| Tabs | `tabGroup.collapse` | Collapse Tab Group |  | b. standard | its section, catalog order |
| Tabs | `tabGroup.color.blue` | Tab Group Color: Blue |  | c. family member | folded into Set Tab Group Color… |
| Tabs | `tabGroup.color.cyan` | Tab Group Color: Cyan |  | c. family member | folded into Set Tab Group Color… |
| Tabs | `tabGroup.color.green` | Tab Group Color: Green |  | c. family member | folded into Set Tab Group Color… |
| Tabs | `tabGroup.color.grey` | Tab Group Color: Grey |  | c. family member | folded into Set Tab Group Color… |
| Tabs | `tabGroup.color.orange` | Tab Group Color: Orange |  | c. family member | folded into Set Tab Group Color… |
| Tabs | `tabGroup.color.pink` | Tab Group Color: Pink |  | c. family member | folded into Set Tab Group Color… |
| Tabs | `tabGroup.color.purple` | Tab Group Color: Purple |  | c. family member | folded into Set Tab Group Color… |
| Tabs | `tabGroup.color.red` | Tab Group Color: Red |  | c. family member | folded into Set Tab Group Color… |
| Tabs | `tabGroup.color.yellow` | Tab Group Color: Yellow |  | c. family member | folded into Set Tab Group Color… |
| Tabs | `tabGroup.create` | New Tab Group |  | b. standard | its section, catalog order |
| Tabs | `tabGroup.deleteSaved` | Delete Saved Tab Group… |  | b. standard | its section, catalog order |
| Tabs | `tabGroup.expand` | Expand Tab Group |  | b. standard | its section, catalog order |
| Tabs | `tabGroup.moveLeft` | Move Tab Group Left |  | c. family member | folded into Tab Group: Move… |
| Tabs | `tabGroup.moveRight` | Move Tab Group Right |  | c. family member | folded into Tab Group: Move… |
| Tabs | `tabGroup.moveToNewColumn` | Move Tab Group to New Column |  | c. family member | folded into Tab Group: Move… |
| Tabs | `tabGroup.moveToNewSplit` | Move Tab Group to New Split |  | c. family member | folded into Tab Group: Move… |
| Tabs | `tabGroup.moveToNewWindow` | Move Tab Group to New Window |  | c. family member | folded into Tab Group: Move… |
| Tabs | `tabGroup.moveToNewWorkspace` | Move Tab Group to New Workspace |  | c. family member | folded into Tab Group: Move… |
| Tabs | `tabGroup.moveToWorkspace` | Move Tab Group to Workspace… |  | c. family member | folded into Tab Group: Move… |
| Tabs | `tabGroup.newTab` | New Tab in Group |  | b. standard | its section, catalog order |
| Tabs | `tabGroup.removeTab` | Remove Tab from Group |  | b. standard | its section, catalog order |
| Tabs | `tabGroup.rename` | Rename Tab Group… |  | b. standard | its section, catalog order |
| Tabs | `tabGroup.reopenSaved` | Reopen Saved Tab Group… |  | b. standard | its section, catalog order |
| Tabs | `tabGroup.save` | Pin Group |  | b. standard | its section, catalog order |
| Tabs | `tabGroup.setColor` | Set Tab Group Color… |  | b. standard | its section, catalog order |
| Tabs | `tabGroup.setIcon` | Set Tab Group Icon… |  | b. standard | its section, catalog order |
| Tabs | `tabGroup.toggleCollapsed` | Collapse/Expand Tab Group |  | b. standard | its section, catalog order |
| Tabs | `tabGroup.ungroup` | Ungroup Tabs |  | b. standard | its section, catalog order |
| Tabs | `tabGroup.unsave` | Unpin Group |  | b. standard | its section, catalog order |
| Tabs | `wakeTab` | Wake Tab |  | b. standard | its section, catalog order |
| Terminal | `attachTextBoxFile` | Attach File to TextBox | ⌥⇧⌘A | b. standard | its section, catalog order |
| Terminal | `clearScreenKeepScrollback` | Clear Screen (Keep Scrollback) | ⇧⌘K | b. standard | its section, catalog order |
| Terminal | `cycleTextBoxSubmitAction` | Cycle TextBox Submit Action | ⇧	 | b. standard | its section, catalog order |
| Terminal | `find` | Find… | ⌘F | a. daily | first in its section, +120 while typing |
| Terminal | `findInDirectory` | Find in Directory… | ⇧⌘F | a. daily | first in its section, +120 while typing |
| Terminal | `findNext` | Find Next | ⌘G | b. standard | its section, catalog order |
| Terminal | `findPrevious` | Find Previous | ⌥⌘G | b. standard | its section, catalog order |
| Terminal | `focusTextBoxInput` | Focus TextBox | ⌥⌘A | b. standard | its section, catalog order |
| Terminal | `hideFind` | Hide Find Bar | ⌥⇧⌘F | b. standard | its section, catalog order |
| Terminal | `palette.terminalOpenDirectory` | Open Current Directory In… |  | b. standard | its section, catalog order |
| Terminal | `palette.terminalToggleTextBoxInput` | Toggle TextBox |  | b. standard | its section, catalog order |
| Terminal | `pasteLastScreenshot` | Paste Last Screenshot |  | b. standard | its section, catalog order |
| Terminal | `reconnectPane` | Reconnect Pane |  | b. standard | its section, catalog order |
| Terminal | `resetTerminal` | Reset Terminal |  | b. standard | its section, catalog order |
| Terminal | `resumeCommandClear` | Clear Resume Command |  | b. standard | its section, catalog order |
| Terminal | `resumeCommandEdit` | Edit Resume Command… |  | b. standard | its section, catalog order |
| Terminal | `resumeCommandSet` | Set Resume Command… |  | b. standard | its section, catalog order |
| Terminal | `sendCtrlFToTerminal` | Send Ctrl-F to Terminal |  | c. niche | last in its section, −120 while typing |
| Terminal | `tab.setTint` | Set Tab Tint… |  | b. standard | its section, catalog order |
| Terminal | `terminal.clear` | Clear Screen and Scrollback | ⌘K | b. standard | its section, catalog order |
| Terminal | `terminal.clearTheme` | Reset Terminal Theme |  | b. standard | its section, catalog order |
| Terminal | `terminal.decreaseFontSize` | Decrease Font Size | ⌘- | a. daily | first in its section, +120 while typing |
| Terminal | `terminal.increaseFontSize` | Increase Font Size | ⌘= | a. daily | first in its section, +120 while typing |
| Terminal | `terminal.keep` | Keep Terminal Running After Close |  | b. standard | its section, catalog order |
| Terminal | `terminal.resetFontSize` | Reset Font Size | ⌘0 | b. standard | its section, catalog order |
| Terminal | `terminal.scrollPageDown` | Scroll Page Down |  | b. standard | its section, catalog order |
| Terminal | `terminal.scrollPageUp` | Scroll Page Up |  | b. standard | its section, catalog order |
| Terminal | `terminal.scrollToBottom` | Scroll to Bottom |  | b. standard | its section, catalog order |
| Terminal | `terminal.scrollToSelection` | Scroll to Selection |  | b. standard | its section, catalog order |
| Terminal | `terminal.scrollToTop` | Scroll to Top |  | b. standard | its section, catalog order |
| Terminal | `terminal.selectAll` | Select All |  | b. standard | its section, catalog order |
| Terminal | `terminal.sendText` | Send Text… |  | b. standard | its section, catalog order |
| Terminal | `terminal.setTheme` | Set Terminal Theme… |  | a. daily | first in its section, +120 while typing |
| Terminal | `terminalCopy` | Copy | ⌘C | b. standard | its section, catalog order |
| Terminal | `terminalPaste` | Paste | ⌘V | b. standard | its section, catalog order |
| Terminal | `toggleTerminalCopyMode` | Toggle Copy Mode | ⇧⌘M | b. standard | its section, catalog order |
| Terminal | `useSelectionForFind` | Use Selection for Find | ⌘E | b. standard | its section, catalog order |
| Browser and Viewers | `bookmark.add` | Add Bookmark… |  | c. family member | folded into Bookmarks: All Commands… |
| Browser and Viewers | `bookmark.addAllTabs` | Bookmark All Tabs… |  | c. family member | folded into Bookmarks: All Commands… |
| Browser and Viewers | `bookmark.addPage` | Bookmark This Page |  | b. standard | its section, catalog order |
| Browser and Viewers | `bookmark.clearIcon` | Remove Bookmark Folder Icon |  | c. family member | folded into Bookmarks: All Commands… |
| Browser and Viewers | `bookmark.copyLink` | Copy Bookmark Link |  | c. family member | folded into Bookmarks: All Commands… |
| Browser and Viewers | `bookmark.edit` | Edit Bookmark… |  | c. family member | folded into Bookmarks: All Commands… |
| Browser and Viewers | `bookmark.export` | Export Bookmarks… |  | c. family member | folded into Bookmarks: All Commands… |
| Browser and Viewers | `bookmark.import` | Import Bookmarks… |  | c. family member | folded into Bookmarks: All Commands… |
| Browser and Viewers | `bookmark.importFromBrowser` | Import Bookmarks from Browser… |  | c. family member | folded into Bookmarks: All Commands… |
| Browser and Viewers | `bookmark.manager` | Bookmark Manager |  | b. standard | its section, catalog order |
| Browser and Viewers | `bookmark.move` | Move Bookmark… |  | c. family member | folded into Bookmarks: All Commands… |
| Browser and Viewers | `bookmark.newFolder` | New Bookmark Folder… |  | c. family member | folded into Bookmarks: All Commands… |
| Browser and Viewers | `bookmark.open` | Open Bookmark… |  | b. standard | its section, catalog order |
| Browser and Viewers | `bookmark.openAll` | Open All Bookmarks in Folder |  | c. family member | folded into Bookmarks: All Commands… |
| Browser and Viewers | `bookmark.openInBackgroundTab` | Open Bookmark in Background Tab |  | c. family member | folded into Bookmarks: All Commands… |
| Browser and Viewers | `bookmark.openInNewTab` | Open Bookmark in New Tab |  | c. family member | folded into Bookmarks: All Commands… |
| Browser and Viewers | `bookmark.remove` | Delete Bookmark |  | c. family member | folded into Bookmarks: All Commands… |
| Browser and Viewers | `bookmark.setIcon` | Set Bookmark Folder Icon… |  | c. family member | folded into Bookmarks: All Commands… |
| Browser and Viewers | `bookmark.toggleBar` | Show Bookmarks Bar | ⇧⌘B | b. standard | its section, catalog order |
| Browser and Viewers | `browser.allowAgentWithExtensions` | Allow Agents in This Tab… |  | b. standard | its section, catalog order |
| Browser and Viewers | `browser.certificateWarning.goBack` | Go Back from Certificate Warning |  | c. niche | last in its section, −120 while typing |
| Browser and Viewers | `browser.certificateWarning.proceed` | Proceed Past Certificate Warning (Unsafe) |  | c. niche | last in its section, −120 while typing |
| Browser and Viewers | `browser.copyURL` | Copy Page URL | ⇧⌘C | b. standard | its section, catalog order |
| Browser and Viewers | `browser.download.openBlockedSiteSettings` | Open Site Settings of Blocked Download |  | c. niche | last in its section, −120 while typing |
| Browser and Viewers | `browser.downloads.show` | Show Downloads… |  | b. standard | its section, catalog order |
| Browser and Viewers | `browser.downloads.showFolder` | Open Downloads Folder |  | b. standard | its section, catalog order |
| Browser and Viewers | `browser.extension.command` | Run Extension Shortcut |  | c. family member | folded into Extensions… |
| Browser and Viewers | `browser.extension.disable` | Disable Extension |  | c. family member | folded into Extensions… |
| Browser and Viewers | `browser.extension.enable` | Enable Extension |  | c. family member | folded into Extensions… |
| Browser and Viewers | `browser.extension.move` | Move Pinned Extension |  | c. family member | folded into Extensions… |
| Browser and Viewers | `browser.extension.options` | Extension Options |  | c. family member | folded into Extensions… |
| Browser and Viewers | `browser.extension.pin` | Pin Extension to Toolbar |  | c. family member | folded into Extensions… |
| Browser and Viewers | `browser.extension.reload` | Reload Extension |  | c. family member | folded into Extensions… |
| Browser and Viewers | `browser.extension.remove` | Remove Extension |  | c. family member | folded into Extensions… |
| Browser and Viewers | `browser.extension.run` | Run Extension |  | c. family member | folded into Extensions… |
| Browser and Viewers | `browser.extension.unpin` | Unpin Extension from Toolbar |  | c. family member | folded into Extensions… |
| Browser and Viewers | `browser.extensions.loadUnpacked` | Load Unpacked Extension… |  | b. standard | its section, catalog order |
| Browser and Viewers | `browser.extensions.manage` | Manage Extensions |  | b. standard | its section, catalog order |
| Browser and Viewers | `browser.extensions.menu` | Extensions… |  | b. standard | its section, catalog order |
| Browser and Viewers | `browser.extensions.webStore` | Open Chrome Web Store |  | b. standard | its section, catalog order |
| Browser and Viewers | `browser.focusSearch` | Search the Web |  | b. standard | its section, catalog order |
| Browser and Viewers | `browser.image.openInNewTab` | Open Image in New Tab |  | b. standard | its section, catalog order |
| Browser and Viewers | `browser.importCookies` | Import Cookies from Browser… |  | b. standard | its section, catalog order |
| Browser and Viewers | `browser.importFromFiles` | Import from Another Browser… |  | b. standard | its section, catalog order |
| Browser and Viewers | `browser.link.openInIncognitoWindow` | Open Link in Incognito Window |  | b. standard | its section, catalog order |
| Browser and Viewers | `browser.link.openInNewSpace` | Open Link in New Space |  | b. standard | its section, catalog order |
| Browser and Viewers | `browser.link.openInNewTab` | Open Link in New Tab |  | b. standard | its section, catalog order |
| Browser and Viewers | `browser.link.openInNewWindow` | Open Link in New Window |  | b. standard | its section, catalog order |
| Browser and Viewers | `browser.link.openInNewWorkspace` | Open Link in New Workspace |  | b. standard | its section, catalog order |
| Browser and Viewers | `browser.link.openInSplit` | Open Link in Split Right |  | b. standard | its section, catalog order |
| Browser and Viewers | `browser.media.show` | Show Media Controls… |  | b. standard | its section, catalog order |
| Browser and Viewers | `browser.openInChromium` | Open in Chromium |  | b. standard | its section, catalog order |
| Browser and Viewers | `browser.openInWebKit` | Open in WebKit |  | b. standard | its section, catalog order |
| Browser and Viewers | `browser.openLocally` | Open Locally Instead |  | b. standard | its section, catalog order |
| Browser and Viewers | `browser.openOnMachine` | Open on Machine |  | b. standard | its section, catalog order |
| Browser and Viewers | `browser.overflow.menu` | More Browser Actions… |  | b. standard | its section, catalog order |
| Browser and Viewers | `browser.pageInfo` | View Site Information | ⌃⌘I | b. standard | its section, catalog order |
| Browser and Viewers | `browser.pageInfo.aboutThisPage` | About This Page |  | c. family member | folded into View Site Information |
| Browser and Viewers | `browser.pageInfo.certificate` | Show Certificate |  | c. family member | folded into View Site Information |
| Browser and Viewers | `browser.pageInfo.connection` | Show Connection Details |  | c. family member | folded into View Site Information |
| Browser and Viewers | `browser.pageInfo.cookies` | Show Cookies and Site Data |  | c. family member | folded into View Site Information |
| Browser and Viewers | `browser.pageInfo.deleteSiteData` | Delete Site Data |  | c. family member | folded into View Site Information |
| Browser and Viewers | `browser.pageInfo.manageSiteData` | Manage On-Device Site Data |  | c. family member | folded into View Site Information |
| Browser and Viewers | `browser.pageInfo.reenableCertificateWarnings` | Turn On Certificate Warnings Again |  | c. family member | folded into View Site Information |
| Browser and Viewers | `browser.pageInfo.resetPermissions` | Reset Site Permissions |  | c. family member | folded into View Site Information |
| Browser and Viewers | `browser.pageInfo.setPermission` | Set Site Permission… |  | c. family member | folded into View Site Information |
| Browser and Viewers | `browser.pageInfo.siteSettings` | Site Settings |  | c. family member | folded into View Site Information |
| Browser and Viewers | `browser.profile.choose` | Choose Browser Profile… |  | b. standard | its section, catalog order |
| Browser and Viewers | `browser.prompt.allow` | Allow Site Request |  | c. niche | last in its section, −120 while typing |
| Browser and Viewers | `browser.prompt.block` | Block Site Request |  | c. niche | last in its section, −120 while typing |
| Browser and Viewers | `browser.resetPinnedTab` | Back to Pinned Page |  | b. standard | its section, catalog order |
| Browser and Viewers | `browser.selection.search` | Search the Web for Selection |  | b. standard | its section, catalog order |
| Browser and Viewers | `browserBack` | Back | ⌘[ | b. standard | its section, catalog order |
| Browser and Viewers | `browserDevice` | Emulate Device… |  | b. standard | its section, catalog order |
| Browser and Viewers | `browserFit` | Fit as Desktop… |  | b. standard | its section, catalog order |
| Browser and Viewers | `browserFitDesktop` | Fit as 16:9 Desktop |  | b. standard | its section, catalog order |
| Browser and Viewers | `browserFitDesktop1280` | Fit as Desktop (1280) |  | b. standard | its section, catalog order |
| Browser and Viewers | `browserForward` | Forward | ⌘] | b. standard | its section, catalog order |
| Browser and Viewers | `browserHardReload` | Hard Reload Page | ⇧⌘R | b. standard | its section, catalog order |
| Browser and Viewers | `browserLinkHints` | Open Link by Hint | F | b. standard | its section, catalog order |
| Browser and Viewers | `browserLinkHintsNewSplit` | Open Link by Hint in New Split | ⇧F | b. standard | its section, catalog order |
| Browser and Viewers | `browserPrint` | Print… |  | b. standard | its section, catalog order |
| Browser and Viewers | `browserProfile.clearBrowsingData` | Clear Browsing Data… |  | c. family member | folded into Browser Profile: All Commands… |
| Browser and Viewers | `browserProfile.clearColor` | Remove Browser Profile Color |  | c. family member | folded into Browser Profile: All Commands… |
| Browser and Viewers | `browserProfile.clearIcon` | Remove Browser Profile Icon |  | c. family member | folded into Browser Profile: All Commands… |
| Browser and Viewers | `browserProfile.clearSpaceDefault` | Clear Space Browser Profile |  | c. family member | folded into Browser Profile: All Commands… |
| Browser and Viewers | `browserProfile.clearWorkspaceDefault` | Clear Workspace Browser Profile |  | c. family member | folded into Browser Profile: All Commands… |
| Browser and Viewers | `browserProfile.delete` | Delete Browser Profile and Its Data… |  | c. family member | folded into Browser Profile: All Commands… |
| Browser and Viewers | `browserProfile.duplicateTab` | Duplicate Tab into Browser Profile… |  | c. family member | folded into Browser Profile: All Commands… |
| Browser and Viewers | `browserProfile.manageExtensions` | Manage Extensions in Browser Profile… |  | c. family member | folded into Browser Profile: All Commands… |
| Browser and Viewers | `browserProfile.moveTab` | Move Tab to Browser Profile… |  | c. family member | folded into Browser Profile: All Commands… |
| Browser and Viewers | `browserProfile.new` | New Browser Profile… |  | c. family member | folded into Browser Profile: All Commands… |
| Browser and Viewers | `browserProfile.newTab` | New Tab with Browser Profile… |  | c. family member | folded into Browser Profile: All Commands… |
| Browser and Viewers | `browserProfile.newWindow` | New Window with Browser Profile… |  | c. family member | folded into Browser Profile: All Commands… |
| Browser and Viewers | `browserProfile.newWorkspace` | New Workspace with Browser Profile… |  | c. family member | folded into Browser Profile: All Commands… |
| Browser and Viewers | `browserProfile.openLink` | Open Link in Browser Profile… |  | c. family member | folded into Browser Profile: All Commands… |
| Browser and Viewers | `browserProfile.rename` | Rename Browser Profile… |  | c. family member | folded into Browser Profile: All Commands… |
| Browser and Viewers | `browserProfile.setColor` | Set Browser Profile Color… |  | c. family member | folded into Browser Profile: All Commands… |
| Browser and Viewers | `browserProfile.setIcon` | Set Browser Profile Icon… |  | c. family member | folded into Browser Profile: All Commands… |
| Browser and Viewers | `browserProfile.setSpaceDefault` | Set Space Browser Profile… |  | c. family member | folded into Browser Profile: All Commands… |
| Browser and Viewers | `browserProfile.setWorkspaceDefault` | Set Workspace Browser Profile… |  | c. family member | folded into Browser Profile: All Commands… |
| Browser and Viewers | `browserReload` | Reload Page | ⌘R | b. standard | its section, catalog order |
| Browser and Viewers | `browserScreenshotPage` | Screenshot Page |  | b. standard | its section, catalog order |
| Browser and Viewers | `browserScreenshotSection` | Screenshot Section |  | b. standard | its section, catalog order |
| Browser and Viewers | `browserShowHistory` | Show Browser History | ⌘Y | b. standard | its section, catalog order |
| Browser and Viewers | `browserStop` | Stop Loading | ⌘. | b. standard | its section, catalog order |
| Browser and Viewers | `browserTheme` | Browser Theme… |  | b. standard | its section, catalog order |
| Browser and Viewers | `browserZoomIn` | Zoom In | ⌘= | b. standard | its section, catalog order |
| Browser and Viewers | `browserZoomOut` | Zoom Out | ⌘- | b. standard | its section, catalog order |
| Browser and Viewers | `browserZoomReset` | Actual Size | ⌘0 | b. standard | its section, catalog order |
| Browser and Viewers | `devtools.captureFullPageScreenshot` | Developer Tools: Capture Full Size Screenshot |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.captureNodeScreenshot` | Developer Tools: Capture Node Screenshot |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.captureScreenshot` | Developer Tools: Capture Screenshot |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.clearConsole` | Developer Tools: Clear Console |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.clearSiteData` | Developer Tools: Clear Site Data and Cookies |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.close` | Developer Tools: Close |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.copyConsoleLog` | Developer Tools: Copy Console Log |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.emptyCacheAndHardReload` | Developer Tools: Empty Cache and Hard Reload |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.openDocked` | Developer Tools: Open Docked |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.openDockedRight` | Developer Tools: Dock to Right |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.openInWindow` | Developer Tools: Open in Separate Window |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.pauseScript` | Developer Tools: Pause Script Execution |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.resumeScript` | Developer Tools: Resume Script Execution |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.showAnimations` | Developer Tools: Show Animations |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.showApplication` | Developer Tools: Show Application |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.showElements` | Developer Tools: Show Elements |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.showLayers` | Developer Tools: Show Layers |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.showLighthouse` | Developer Tools: Show Lighthouse |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.showMemory` | Developer Tools: Show Memory |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.showNetwork` | Developer Tools: Show Network |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.showPerformance` | Developer Tools: Show Performance |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.showRendering` | Developer Tools: Show Rendering |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.showSecurity` | Developer Tools: Show Security |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.showSensors` | Developer Tools: Show Sensors |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.showSources` | Developer Tools: Show Sources |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.takeHeapSnapshot` | Developer Tools: Take Heap Snapshot |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.throttleFast3G` | Network: Throttle to Fast 3G |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.throttleOff` | Network: No Throttling |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.throttleOffline` | Network: Go Offline |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.throttleSlow3G` | Network: Throttle to Slow 3G |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.toggleCSS` | Developer Tools: Disable CSS |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.toggleCache` | Developer Tools: Disable Cache |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.toggleFPSMeter` | Rendering: Show Frame Rendering Stats |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.toggleFocusEmulation` | Rendering: Emulate a Focused Page |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.toggleJavaScript` | Developer Tools: Disable JavaScript |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.toggleLayerBorders` | Rendering: Show Layer Borders |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.toggleLayoutShiftRegions` | Rendering: Show Layout Shift Regions |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.togglePaintFlashing` | Rendering: Show Paint Flashing |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.togglePerformanceRecording` | Developer Tools: Start or Stop Performance Recording |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.toggleReducedMotion` | Rendering: Emulate Reduced Motion |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `devtools.viewPageSource` | Developer Tools: View Page Source |  | c. family member | folded into Toggle Developer Tools |
| Browser and Viewers | `diffViewerGoToBottom` | Diff: Go to Bottom | ⇧G | b. standard | its section, catalog order |
| Browser and Viewers | `diffViewerGoToTop` | Diff: Go to Top |  | b. standard | its section, catalog order |
| Browser and Viewers | `diffViewerHalfPageDown` | Diff: Half Page Down | ⌃D | b. standard | its section, catalog order |
| Browser and Viewers | `diffViewerHalfPageUp` | Diff: Half Page Up | ⌃U | b. standard | its section, catalog order |
| Browser and Viewers | `diffViewerNextFile` | Diff: Next File |  | b. standard | its section, catalog order |
| Browser and Viewers | `diffViewerNextHunk` | Diff: Next Hunk | ⌃N | b. standard | its section, catalog order |
| Browser and Viewers | `diffViewerNextLine` | Diff: Next Line | J | b. standard | its section, catalog order |
| Browser and Viewers | `diffViewerPreviousFile` | Diff: Previous File |  | b. standard | its section, catalog order |
| Browser and Viewers | `diffViewerPreviousHunk` | Diff: Previous Hunk | ⌃P | b. standard | its section, catalog order |
| Browser and Viewers | `diffViewerPreviousLine` | Diff: Previous Line | K | b. standard | its section, catalog order |
| Browser and Viewers | `diffViewerSearch` | Diff: Search | / | b. standard | its section, catalog order |
| Browser and Viewers | `fileEditorAction` | Editor: Run Editor Action |  | b. standard | its section, catalog order |
| Browser and Viewers | `fileEditorGotoLine` | Editor: Go to Line… | ⌃G | b. standard | its section, catalog order |
| Browser and Viewers | `fileEditorReplace` | Editor: Replace… |  | b. standard | its section, catalog order |
| Browser and Viewers | `fileEditorZoomIn` | Editor: Zoom In | ⌘= | b. standard | its section, catalog order |
| Browser and Viewers | `fileEditorZoomOut` | Editor: Zoom Out | ⌘- | b. standard | its section, catalog order |
| Browser and Viewers | `fileEditorZoomReset` | Editor: Actual Size | ⌘0 | b. standard | its section, catalog order |
| Browser and Viewers | `filePreviewOpenExternally` | Open File Externally |  | b. standard | its section, catalog order |
| Browser and Viewers | `filePreviewOpenWith` | Open File With… |  | b. standard | its section, catalog order |
| Browser and Viewers | `filePreviewRevealInFiles` | Reveal File in cmux Files |  | b. standard | its section, catalog order |
| Browser and Viewers | `filePreviewRevealInFinder` | Reveal File in Finder |  | b. standard | its section, catalog order |
| Browser and Viewers | `focusBrowserAddressBar` | Focus Address Bar |  | b. standard | its section, catalog order |
| Browser and Viewers | `importFromBrowser` | Import from Browser… |  | b. standard | its section, catalog order |
| Browser and Viewers | `inspectBrowserElement` | Inspect Element | ⌥⌘C | b. standard | its section, catalog order |
| Browser and Viewers | `markdownBack` | Markdown: Back | ⌘[ | b. standard | its section, catalog order |
| Browser and Viewers | `markdownForward` | Markdown: Forward | ⌘] | b. standard | its section, catalog order |
| Browser and Viewers | `markdownLink` | Markdown: Insert Link | ⇧⌘K | b. standard | its section, catalog order |
| Browser and Viewers | `markdownResetTableWidths` | Markdown: Reset Table Column Widths |  | b. standard | its section, catalog order |
| Browser and Viewers | `markdownSave` | Markdown: Save | ⌘S | b. standard | its section, catalog order |
| Browser and Viewers | `markdownZoomIn` | Markdown: Zoom In | ⌘= | b. standard | its section, catalog order |
| Browser and Viewers | `markdownZoomOut` | Markdown: Zoom Out | ⌘- | b. standard | its section, catalog order |
| Browser and Viewers | `markdownZoomReset` | Markdown: Actual Size | ⌘0 | b. standard | its section, catalog order |
| Browser and Viewers | `openDiffViewer` | Open Diff Viewer | ⌃⇧⌘G | a. daily | first in its section, +120 while typing |
| Browser and Viewers | `openLinkInDefaultBrowser` | Open Link in Default Browser |  | b. standard | its section, catalog order |
| Browser and Viewers | `openMarkdownFile` | Open Markdown File… |  | b. standard | its section, catalog order |
| Browser and Viewers | `palette.browserClearHistory` | Clear Browser History… |  | b. standard | its section, catalog order |
| Browser and Viewers | `palette.browserOpenDefault` | Open in Default Browser |  | b. standard | its section, catalog order |
| Browser and Viewers | `palette.browserToggleOmnibar` | Toggle Omnibar |  | b. standard | its section, catalog order |
| Browser and Viewers | `palette.disableBrowser` | Disable cmux Browser |  | c. niche | last in its section, −120 while typing |
| Browser and Viewers | `palette.enableBrowser` | Enable cmux Browser |  | c. niche | last in its section, −120 while typing |
| Browser and Viewers | `palette.openDirectoryDiffViewer` | Open Diff Viewer in Folder… |  | b. standard | its section, catalog order |
| Browser and Viewers | `palette.vscodeServeWebRestart` | Restart VS Code Inline Server |  | c. niche | last in its section, −120 while typing |
| Browser and Viewers | `palette.vscodeServeWebStop` | Stop VS Code Inline Server |  | c. niche | last in its section, −120 while typing |
| Browser and Viewers | `password.importCSV` | Import Passwords from CSV… |  | b. standard | its section, catalog order |
| Browser and Viewers | `passwords.open` | Passwords |  | b. standard | its section, catalog order |
| Browser and Viewers | `phone.appearance` | Set Phone Appearance |  | c. family member | folded into Phone: All Commands… |
| Browser and Viewers | `phone.boot` | Boot Phone |  | c. family member | folded into Phone: All Commands… |
| Browser and Viewers | `phone.button` | Press Phone Button |  | c. family member | folded into Phone: All Commands… |
| Browser and Viewers | `phone.install` | Install App on Phone |  | c. family member | folded into Phone: All Commands… |
| Browser and Viewers | `phone.launch` | Launch App on Phone |  | c. family member | folded into Phone: All Commands… |
| Browser and Viewers | `phone.list` | List Phones |  | c. family member | folded into Phone: All Commands… |
| Browser and Viewers | `phone.locale` | Set Phone Language |  | c. family member | folded into Phone: All Commands… |
| Browser and Viewers | `phone.location` | Set Phone Location |  | c. family member | folded into Phone: All Commands… |
| Browser and Viewers | `phone.logs` | Show Phone Logs |  | c. family member | folded into Phone: All Commands… |
| Browser and Viewers | `phone.openURL` | Open URL on Phone |  | c. family member | folded into Phone: All Commands… |
| Browser and Viewers | `phone.paste` | Copy Text to Phone |  | c. family member | folded into Phone: All Commands… |
| Browser and Viewers | `phone.recordStart` | Record Phone |  | c. family member | folded into Phone: All Commands… |
| Browser and Viewers | `phone.recordStop` | Stop Phone Recording |  | c. family member | folded into Phone: All Commands… |
| Browser and Viewers | `phone.rotate` | Rotate Phone |  | c. family member | folded into Phone: All Commands… |
| Browser and Viewers | `phone.screenshot` | Take Phone Screenshot |  | c. family member | folded into Phone: All Commands… |
| Browser and Viewers | `phone.sendFeedback` | Send Phone Recording to Chief |  | c. family member | folded into Phone: All Commands… |
| Browser and Viewers | `phone.show` | Open Phone |  | b. standard | its section, catalog order |
| Browser and Viewers | `phone.shutdown` | Shut Down Phone |  | c. family member | folded into Phone: All Commands… |
| Browser and Viewers | `phone.swipe` | Swipe on Phone |  | c. family member | folded into Phone: All Commands… |
| Browser and Viewers | `phone.tap` | Tap Phone Screen |  | c. family member | folded into Phone: All Commands… |
| Browser and Viewers | `phone.type` | Type on Phone |  | c. family member | folded into Phone: All Commands… |
| Browser and Viewers | `phone.ui` | Read Phone Screen Elements |  | c. family member | folded into Phone: All Commands… |
| Browser and Viewers | `saveFilePreview` | Save File | ⌘S | b. standard | its section, catalog order |
| Browser and Viewers | `screenshots.open` | Screenshots |  | b. standard | its section, catalog order |
| Browser and Viewers | `showBrowserJavaScriptConsole` | Show JavaScript Console | ⌥⌘J | b. standard | its section, catalog order |
| Browser and Viewers | `splitBrowserDown` | Split Browser Down | ⌥⇧⌘X | b. standard | its section, catalog order |
| Browser and Viewers | `splitBrowserRight` | Split Browser Right | ⌥⌘X | b. standard | its section, catalog order |
| Browser and Viewers | `toggleBrowserDesignMode` | Toggle Browser Design Mode | ⌃⌥⌘D | b. standard | its section, catalog order |
| Browser and Viewers | `toggleBrowserDeveloperTools` | Toggle Developer Tools | ⌥⌘I | b. standard | its section, catalog order |
| Browser and Viewers | `toggleBrowserFocusMode` | Toggle Browser Focus Mode | ⌥⌘
 | b. standard | its section, catalog order |
| Browser and Viewers | `toggleFileEditorWordWrap` | Toggle Word Wrap | ⌥Z | b. standard | its section, catalog order |
| Browser and Viewers | `toggleReactGrab` | Toggle React Grab |  | c. niche | last in its section, −120 while typing |
| Sidebar | `checklistAttachImages` | Attach Images to Checklist Item… |  | b. standard | its section, catalog order |
| Sidebar | `checklistCompleteItem` | Complete Checklist Item |  | b. standard | its section, catalog order |
| Sidebar | `checklistEditItem` | Edit Checklist Item… |  | b. standard | its section, catalog order |
| Sidebar | `checklistMarkInProgress` | Mark Checklist Item In Progress |  | b. standard | its section, catalog order |
| Sidebar | `checklistOpenAsPane` | Open Checklist as Pane |  | b. standard | its section, catalog order |
| Sidebar | `checklistRemoveItem` | Remove Checklist Item |  | b. standard | its section, catalog order |
| Sidebar | `fileExplorerCopyPath` | Copy Path |  | b. standard | its section, catalog order |
| Sidebar | `fileExplorerCopyRelativePath` | Copy Relative Path |  | b. standard | its section, catalog order |
| Sidebar | `fileExplorerOpenInCmux` | Open in cmux |  | b. standard | its section, catalog order |
| Sidebar | `fileExplorerOpenSelection` | Open Selection | 
 | b. standard | its section, catalog order |
| Sidebar | `fileExplorerOpenSelectionFinderAlias` | Open Selection (Finder Style) | ⌘ | b. standard | its section, catalog order |
| Sidebar | `fileExplorerOpenWith` | Open With… |  | b. standard | its section, catalog order |
| Sidebar | `fileExplorerReveal` | Reveal in Finder |  | b. standard | its section, catalog order |
| Sidebar | `focusRightSidebar` | Focus Right Sidebar | ⇧⌘E | b. standard | its section, catalog order |
| Sidebar | `focusSidebar` | Focus Sidebar | ⌃⌘E | b. standard | its section, catalog order |
| Sidebar | `machine.clearIcon` | Remove Machine Icon |  | b. standard | its section, catalog order |
| Sidebar | `machine.setIcon` | Set Machine Icon… |  | b. standard | its section, catalog order |
| Sidebar | `palette.disableMinimalMode` | Disable Minimal Mode |  | b. standard | its section, catalog order |
| Sidebar | `palette.enableMinimalMode` | Enable Minimal Mode |  | b. standard | its section, catalog order |
| Sidebar | `palette.toggleMatchTerminalBackground` | Toggle Match Terminal Background |  | b. standard | its section, catalog order |
| Sidebar | `sidebar.density.expanded` | Sidebar Density: Expanded |  | b. standard | its section, catalog order |
| Sidebar | `sidebar.groupBy.folder` | Group by Folder |  | b. standard | its section, catalog order |
| Sidebar | `sidebar.groupBy.none` | Group by None |  | b. standard | its section, catalog order |
| Sidebar | `sidebar.home.add` | Add Home to Sidebar |  | b. standard | its section, catalog order |
| Sidebar | `sidebar.home.remove` | Remove Home from Sidebar |  | b. standard | its section, catalog order |
| Sidebar | `sidebar.item.add` | Add to Sidebar… |  | b. standard | its section, catalog order |
| Sidebar | `sidebar.item.hideApp` | Hide App |  | c. duplicate | folded into Hide App… (`app.hide`) |
| Sidebar | `sidebar.item.remove` | Remove from Section |  | b. standard | its section, catalog order |
| Sidebar | `sidebar.item.removeEverywhere` | Remove from Sidebar |  | b. standard | its section, catalog order |
| Sidebar | `sidebar.item.toggleLabel` | Show/Hide Label |  | b. standard | its section, catalog order |
| Sidebar | `sidebar.layout.reset` | Reset Sidebar Layout |  | b. standard | its section, catalog order |
| Sidebar | `sidebar.profileControl.hide` | Hide Profile Button |  | c. niche | last in its section, −120 while typing |
| Sidebar | `sidebar.profileControl.show` | Show Profile Button |  | c. niche | last in its section, −120 while typing |
| Sidebar | `sidebar.profileMenu` | Show Profile Menu |  | b. standard | its section, catalog order |
| Sidebar | `sidebar.projects.hide` | Hide Projects |  | b. standard | its section, catalog order |
| Sidebar | `sidebar.section.add` | New Section… |  | b. standard | its section, catalog order |
| Sidebar | `sidebar.section.closeWorkspaces` | Close All Workspaces in Section |  | b. standard | its section, catalog order |
| Sidebar | `sidebar.section.hide` | Hide Section |  | b. standard | its section, catalog order |
| Sidebar | `sidebar.section.layoutGrid` | Show as Grid |  | c. family member | folded into Sidebar Section: Layout… |
| Sidebar | `sidebar.section.layoutInline` | Show on One Line |  | c. family member | folded into Sidebar Section: Layout… |
| Sidebar | `sidebar.section.layoutList` | Show as List |  | c. family member | folded into Sidebar Section: Layout… |
| Sidebar | `sidebar.section.moveToBottom` | Move Section to Bottom |  | c. family member | folded into Sidebar Section: Layout… |
| Sidebar | `sidebar.section.moveToScrolling` | Move Section to Scrolling Area |  | c. family member | folded into Sidebar Section: Layout… |
| Sidebar | `sidebar.section.moveToTop` | Move Section to Top |  | c. family member | folded into Sidebar Section: Layout… |
| Sidebar | `sidebar.section.newWorkspace` | New Workspace in Section |  | b. standard | its section, catalog order |
| Sidebar | `sidebar.section.remove` | Remove Section |  | b. standard | its section, catalog order |
| Sidebar | `sidebar.section.rename` | Rename Section… |  | b. standard | its section, catalog order |
| Sidebar | `sidebar.section.setAlignment` | Set Section Alignment… |  | c. family member | folded into Sidebar Section: Layout… |
| Sidebar | `sidebar.section.setColumns` | Set Grid Columns… |  | c. family member | folded into Sidebar Section: Layout… |
| Sidebar | `sidebar.section.setGap` | Set Section Spacing… |  | c. family member | folded into Sidebar Section: Layout… |
| Sidebar | `sidebar.section.setMaxRows` | Set Section Height… |  | c. family member | folded into Sidebar Section: Layout… |
| Sidebar | `sidebar.section.toggleCollapsed` | Collapse/Expand Section |  | b. standard | its section, catalog order |
| Sidebar | `sidebar.section.toggleSpaceScope` | Show Only in This Space |  | c. family member | folded into Sidebar Section: Layout… |
| Sidebar | `sidebar.section.toggleTitle` | Show/Hide Section Title |  | c. family member | folded into Sidebar Section: Layout… |
| Sidebar | `sidebar.section.useBuiltInLook` | Built-in Look |  | c. family member | folded into Sidebar Section: Layout… |
| Sidebar | `sidebar.section.useListLook` | List Look |  | c. family member | folded into Sidebar Section: Layout… |
| Sidebar | `sidebar.sections.showHidden` | Show Hidden Sections |  | b. standard | its section, catalog order |
| Sidebar | `sidebar.spaces.hide` | Hide Spaces |  | b. standard | its section, catalog order |
| Sidebar | `sidebar.spaces.show` | Show Spaces |  | b. standard | its section, catalog order |
| Sidebar | `switchRightSidebarToDock` | Show Dock |  | b. standard | its section, catalog order |
| Sidebar | `switchRightSidebarToFeed` | Show Feed in Right Sidebar |  | b. standard | its section, catalog order |
| Sidebar | `switchRightSidebarToFiles` | Show Files |  | b. standard | its section, catalog order |
| Sidebar | `switchRightSidebarToFind` | Show Find |  | b. standard | its section, catalog order |
| Sidebar | `switchRightSidebarToMachines` | Show Cloud |  | b. standard | its section, catalog order |
| Sidebar | `switchRightSidebarToSessions` | Show Vault |  | b. standard | its section, catalog order |
| Sidebar | `toggleRightSidebar` | Toggle Right Sidebar | ⌥⌘B | a. daily | first in its section, +120 while typing |
| Sidebar | `toggleSidebar` | Toggle Left Sidebar | ⌘B | a. daily | first in its section, +120 while typing |
| Sidebar | `vaultCopyResumeCommand` | Copy Resume Command |  | b. standard | its section, catalog order |
| Sidebar | `vaultFocusSession` | Focus Session |  | b. standard | its section, catalog order |
| Sidebar | `vaultOpenPullRequest` | Open Session Pull Request |  | b. standard | its section, catalog order |
| Sidebar | `vaultOpenSession` | Open Session |  | b. standard | its section, catalog order |
| Sidebar | `vaultResumeInNewWorkspace` | Resume Session in New Workspace |  | b. standard | its section, catalog order |
| Notifications | `clearAllNotifications` | Clear All Notifications |  | b. standard | its section, catalog order |
| Notifications | `feed.show` | Show Feed | ⇧⌘I | b. standard | its section, catalog order |
| Notifications | `jumpToLastPrompt` | Jump to Last Prompt | ⌃⌘B | b. standard | its section, catalog order |
| Notifications | `jumpToUnread` | Jump to Latest Unread | ⇧⌘U | a. daily | first in its section, +120 while typing |
| Notifications | `markAllNotificationsRead` | Mark All Notifications as Read |  | b. standard | its section, catalog order |
| Notifications | `markOldestUnreadAndJumpNext` | Mark Oldest Unread and Jump Next | ⌃⌘U | b. standard | its section, catalog order |
| Notifications | `notificationCopy` | Copy Notification |  | b. standard | its section, catalog order |
| Notifications | `notificationDismiss` | Dismiss Notification |  | b. standard | its section, catalog order |
| Notifications | `notificationOpen` | Open Notification |  | b. standard | its section, catalog order |
| Notifications | `notificationToggleRead` | Mark Notification Read/Unread |  | b. standard | its section, catalog order |
| Notifications | `notifications.dismissHighlight` | Dismiss Highlight |  | b. standard | its section, catalog order |
| Notifications | `notifications.dismissal.click` | Clear Notifications on Click |  | c. family member | folded into Notifications: When to Clear… |
| Notifications | `notifications.dismissal.explicit` | Clear Notifications Only When Opened |  | c. family member | folded into Notifications: When to Clear… |
| Notifications | `notifications.dismissal.focus` | Clear Notifications on Focus |  | c. family member | folded into Notifications: When to Clear… |
| Notifications | `notifications.dismissal.keystroke` | Clear Notifications When Typing |  | c. family member | folded into Notifications: When to Clear… |
| Notifications | `notifications.dismissal.never` | Never Clear Notifications Automatically |  | c. family member | folded into Notifications: When to Clear… |
| Notifications | `notifications.dismissal.timeout` | Clear Notifications After a Timeout |  | c. family member | folded into Notifications: When to Clear… |
| Notifications | `notifications.toggleBanners` | Toggle Notification Banners |  | b. standard | its section, catalog order |
| Notifications | `notifications.toggleWorkspaceMute` | Mute/Unmute Workspace Notifications |  | b. standard | its section, catalog order |
| Notifications | `showNotifications` | Show Notifications |  | b. standard | its section, catalog order |
| Notifications | `toggleUnread` | Toggle Tab Unread | ⌥⌘U | b. standard | its section, catalog order |
| Agents | `agent.harness.add` | Add ACP Agent… |  | b. standard | its section, catalog order |
| Agents | `agent.harness.addFromRegistry` | Add Agent from ACP Registry… |  | b. standard | its section, catalog order |
| Agents | `agent.harness.doctor` | Check Agent… |  | b. standard | its section, catalog order |
| Agents | `agent.harness.remove` | Remove Agent… |  | b. standard | its section, catalog order |
| Agents | `agent.harness.restore` | Restore Removed Agent |  | b. standard | its section, catalog order |
| Agents | `agent.harness.updateAll` | Update Agent CLIs |  | b. standard | its section, catalog order |
| Agents | `agentActivity.open` | Agent Activity |  | b. standard | its section, catalog order |
| Agents | `agentChat.copyIdentifier` | Copy Agent Identifier |  | c. niche | last in its section, −120 while typing |
| Agents | `agentChat.toggleNotificationMute` | Mute/Unmute Chat Notifications |  | b. standard | its section, catalog order |
| Agents | `agentPane.archiveChat` | Archive Chat | ⌃⌘A | b. standard | its section, catalog order |
| Agents | `agentPane.continueIn` | Continue In… |  | b. standard | its section, catalog order |
| Agents | `agentPane.copyLastCodeBlock` | Copy Last Code Block | ⌥⌘; | b. standard | its section, catalog order |
| Agents | `agentPane.createCheckpoint` | Create Checkpoint |  | b. standard | its section, catalog order |
| Agents | `agentPane.git.commit` | Commit Changes… |  | b. standard | its section, catalog order |
| Agents | `agentPane.git.push` | Push Branch |  | b. standard | its section, catalog order |
| Agents | `agentPane.nextBookmarkedPrompt` | Next Bookmarked Prompt |  | b. standard | its section, catalog order |
| Agents | `agentPane.nextTurn` | Next Turn | ⌃⌥ | b. standard | its section, catalog order |
| Agents | `agentPane.permission.allowChat` | Allow for This Chat | ⌥⌘2 | b. standard | its section, catalog order |
| Agents | `agentPane.permission.allowOnce` | Allow Once | ⌥⌘1 | b. standard | its section, catalog order |
| Agents | `agentPane.permission.deny` | Deny | ⌥⌘3 | b. standard | its section, catalog order |
| Agents | `agentPane.permission.expand` | Expand Permission Details | ⌥⌘4 | b. standard | its section, catalog order |
| Agents | `agentPane.permission.refresh` | Refresh Permissions |  | b. standard | its section, catalog order |
| Agents | `agentPane.permission.retry` | Check and Retry Permission |  | b. standard | its section, catalog order |
| Agents | `agentPane.permission.revoke` | Revoke Chat Permission |  | b. standard | its section, catalog order |
| Agents | `agentPane.previousBookmarkedPrompt` | Previous Bookmarked Prompt |  | b. standard | its section, catalog order |
| Agents | `agentPane.previousTurn` | Previous Turn | ⌃⌥ | b. standard | its section, catalog order |
| Agents | `agentPane.searchChats` | Search Agent Chats |  | b. standard | its section, catalog order |
| Agents | `agentPane.searchFiles` | Search Files… |  | b. standard | its section, catalog order |
| Agents | `agentPane.switchModel` | Switch Model… | ⌃⌘M | b. standard | its section, catalog order |
| Agents | `agentPane.toggleInspector` | Show ACP Inspector |  | b. standard | its section, catalog order |
| Agents | `agentPaneZoomIn` | Agent Chat: Zoom In | ⌘= | b. standard | its section, catalog order |
| Agents | `agentPaneZoomOut` | Agent Chat: Zoom Out | ⌘- | b. standard | its section, catalog order |
| Agents | `agentPaneZoomReset` | Agent Chat: Actual Size | ⌘0 | b. standard | its section, catalog order |
| Agents | `chief.moveTo` | Move Chief To… |  | b. standard | its section, catalog order |
| Agents | `chief.openMemoryInspector` | Chief: Open Memory Inspector |  | b. standard | its section, catalog order |
| Agents | `chief.openUsage` | Chief Usage |  | b. standard | its section, catalog order |
| Agents | `computerUseFocus` | Focus Computer Use |  | b. standard | its section, catalog order |
| Agents | `computerUseFocusCallingTerminal` | Focus Calling Terminal |  | b. standard | its section, catalog order |
| Agents | `computerUseStop` | Stop Computer Use |  | b. standard | its section, catalog order |
| Agents | `history.resumeAgentSession` | Resume Agent Session… |  | b. standard | its section, catalog order |
| Agents | `home.stopChief` | Stop the Chief |  | b. standard | its section, catalog order |
| Agents | `home.toggleChiefSettings` | Toggle Chief Settings |  | b. standard | its section, catalog order |
| Agents | `palette.addHarness` | Integrate a Harness with an Agent… |  | b. standard | its section, catalog order |
| Agents | `palette.computerUse.accessibility` | Grant Accessibility Access |  | c. niche | last in its section, −120 while typing |
| Agents | `palette.computerUse.screenRecording` | Grant Screen Recording Access |  | c. niche | last in its section, −120 while typing |
| Agents | `palette.computerUse.setup` | Computer Use Setup |  | b. standard | its section, catalog order |
| Agents | `palette.forkAgentConversationBottom` | Fork Conversation Below |  | c. family member | folded into Fork Conversation… |
| Agents | `palette.forkAgentConversationLeft` | Fork Conversation to the Left |  | c. family member | folded into Fork Conversation… |
| Agents | `palette.forkAgentConversationNewTab` | Fork Conversation to New Tab |  | c. family member | folded into Fork Conversation… |
| Agents | `palette.forkAgentConversationNewWorkspace` | Fork Conversation to New Workspace |  | c. family member | folded into Fork Conversation… |
| Agents | `palette.forkAgentConversationRight` | Fork Conversation to the Right |  | c. family member | folded into Fork Conversation… |
| Agents | `palette.forkAgentConversationTop` | Fork Conversation Above |  | c. family member | folded into Fork Conversation… |
| Agents | `palette.launchClaudeTeams` | Launch Claude Teams |  | b. standard | its section, catalog order |
| Agents | `palette.launchCodexTeams` | Launch Codex Teams |  | b. standard | its section, catalog order |
| Agents | `palette.newAgentChat` | New Agent Chat | ⌘I | a. daily | first in its section, +120 while typing |
| Agents | `palette.openTerminalChatView` | Open Terminal as Chat |  | b. standard | its section, catalog order |
| Agents | `palette.quickAgentChat` | Start Agent… | ⌃⌘
 | a. daily | first in its section, +120 while typing |
| Agents | `palette.toggleDictation` | Toggle Dictation | ⌃⌘V | b. standard | its section, catalog order |
| Agents | `stats.show` | Show Agent Stats |  | b. standard | its section, catalog order |
| Agents | `tasks.new` | New Task |  | b. standard | its section, catalog order |
| Agents | `tasks.show` | Open Tasks |  | b. standard | its section, catalog order |
| Agents | `tasks.showMine` | My Tasks |  | b. standard | its section, catalog order |
| Cloud and Account | `accounts.connect` | Connect Account to CodeRouter… |  | b. standard | its section, catalog order |
| Cloud and Account | `accounts.reauthenticate` | Re-authenticate Provider… |  | b. standard | its section, catalog order |
| Cloud and Account | `accounts.refresh` | Refresh Accounts |  | b. standard | its section, catalog order |
| Cloud and Account | `accounts.remove` | Remove Account from CodeRouter |  | b. standard | its section, catalog order |
| Cloud and Account | `accounts.show` | Accounts… |  | b. standard | its section, catalog order |
| Cloud and Account | `cloudBringBack` | Bring Back Local |  | b. standard | its section, catalog order |
| Cloud and Account | `cloudCopyLink` | Copy Machine Link |  | b. standard | its section, catalog order |
| Cloud and Account | `cloudCopyMachineID` | Copy Machine ID |  | c. niche | last in its section, −120 while typing |
| Cloud and Account | `cloudCopyPort` | Copy Machine Port |  | b. standard | its section, catalog order |
| Cloud and Account | `cloudDiagnostics` | Cloud Diagnostics |  | b. standard | its section, catalog order |
| Cloud and Account | `cloudDomainList` | List Cloud Domains |  | c. niche | last in its section, −120 while typing |
| Cloud and Account | `cloudExec` | Run Command on Cloud Machine… |  | b. standard | its section, catalog order |
| Cloud and Account | `cloudFileMkdir` | Create Cloud Directory… |  | c. family member | folded into Cloud Machine: Files and Network… |
| Cloud and Account | `cloudFileRead` | Read Cloud File… |  | c. family member | folded into Cloud Machine: Files and Network… |
| Cloud and Account | `cloudFileRemove` | Remove Cloud File… |  | c. family member | folded into Cloud Machine: Files and Network… |
| Cloud and Account | `cloudFileStat` | Cloud File Details… |  | c. family member | folded into Cloud Machine: Files and Network… |
| Cloud and Account | `cloudFileWrite` | Write Cloud File… |  | c. family member | folded into Cloud Machine: Files and Network… |
| Cloud and Account | `cloudFilesList` | List Cloud Files… |  | c. family member | folded into Cloud Machine: Files and Network… |
| Cloud and Account | `cloudFirewallCreate` | Create Cloud Firewall Rule |  | c. family member | folded into Cloud Machine: Files and Network… |
| Cloud and Account | `cloudFirewallDelete` | Delete Cloud Firewall Rule |  | c. family member | folded into Cloud Machine: Files and Network… |
| Cloud and Account | `cloudFirewallGet` | Get Cloud Firewall Rule |  | c. family member | folded into Cloud Machine: Files and Network… |
| Cloud and Account | `cloudFirewallList` | List Cloud Firewall Rules |  | c. family member | folded into Cloud Machine: Files and Network… |
| Cloud and Account | `cloudKillMachine` | Kill Machine |  | b. standard | its section, catalog order |
| Cloud and Account | `cloudMove` | Move to Cloud |  | b. standard | its section, catalog order |
| Cloud and Account | `cloudNetworkList` | List Cloud Networks |  | c. niche | last in its section, −120 while typing |
| Cloud and Account | `cloudNewTerminal` | New Terminal on Machine |  | b. standard | its section, catalog order |
| Cloud and Account | `cloudOpenMachine` | Open Machine |  | b. standard | its section, catalog order |
| Cloud and Account | `cloudPauseMachine` | Pause Machine |  | b. standard | its section, catalog order |
| Cloud and Account | `cloudPrepareSCP` | Prepare Cloud File Transfer… |  | c. niche | last in its section, −120 while typing |
| Cloud and Account | `cloudPublicationList` | List Cloud Publications |  | c. niche | last in its section, −120 while typing |
| Cloud and Account | `cloudRenameMachine` | Rename Machine… |  | b. standard | its section, catalog order |
| Cloud and Account | `cloudResizeMachine` | Resize Machine… |  | b. standard | its section, catalog order |
| Cloud and Account | `cloudResumeMachine` | Resume Machine |  | b. standard | its section, catalog order |
| Cloud and Account | `cloudSSH` | Open Cloud SSH Terminal |  | b. standard | its section, catalog order |
| Cloud and Account | `cloudTunnelAttach` | Attach Cloud Tunnel Network |  | c. family member | folded into Cloud Machine: Files and Network… |
| Cloud and Account | `cloudTunnelDetach` | Detach Cloud Tunnel Network |  | c. family member | folded into Cloud Machine: Files and Network… |
| Cloud and Account | `cloudTunnelRotateKey` | Rotate Cloud Tunnel Key |  | c. family member | folded into Cloud Machine: Files and Network… |
| Cloud and Account | `newCloudMachine` | New Cloud Machine… |  | b. standard | its section, catalog order |
| Cloud and Account | `newCloudWorkspace` | New Cloud Workspace | ⇧⌘Y | a. daily | first in its section, +120 while typing |
| Cloud and Account | `openTeamPicker` | Team Picker… | ⌥⇧⌘T | b. standard | its section, catalog order |
| Cloud and Account | `palette.auth.signIn` | Sign In |  | b. standard | its section, catalog order |
| Cloud and Account | `palette.auth.signOut` | Sign Out |  | b. standard | its section, catalog order |
| Cloud and Account | `palette.cloud.deleteSnapshot` | Delete Cloud Snapshot… |  | b. standard | its section, catalog order |
| Cloud and Account | `palette.cloud.fork` | Fork Cloud Machine |  | b. standard | its section, catalog order |
| Cloud and Account | `palette.cloud.handoff` | Hand Off Cloud Machine |  | b. standard | its section, catalog order |
| Cloud and Account | `palette.cloud.ports` | Cloud Machine Ports |  | b. standard | its section, catalog order |
| Cloud and Account | `palette.cloud.promoteTemplate` | Promote Machine to Template |  | c. niche | last in its section, −120 while typing |
| Cloud and Account | `palette.cloud.restore` | Restore Cloud Machine… |  | b. standard | its section, catalog order |
| Cloud and Account | `palette.cloud.snapshot` | Snapshot Cloud Machine |  | b. standard | its section, catalog order |
| Cloud and Account | `palette.cloud.status` | Cloud Machine Status |  | b. standard | its section, catalog order |
| Cloud and Account | `palette.cloud.tools` | Cloud Machine Tools |  | b. standard | its section, catalog order |
| Cloud and Account | `palette.mobileConnect` | Open Mobile Pairing |  | b. standard | its section, catalog order |
| Remote Machines | `machine.reconnect` | Reconnect |  | b. standard | its section, catalog order |
| Remote Machines | `remote.connect` | Connect to Machine… |  | a. daily | first in its section, +120 while typing |
| Remote Machines | `remote.copyError` | Copy SSH Error |  | c. duplicate | folded into Copy SSH Error |
| Remote Machines | `remote.disconnect` | Disconnect Machine |  | b. standard | its section, catalog order |
| Remote Machines | `remote.forget` | Forget Machine… |  | b. standard | its section, catalog order |
| Remote Machines | `remote.install` | Install cmux-tui on Machine… |  | b. standard | its section, catalog order |
| Remote Machines | `remote.newGroup` | New Remote Group… |  | b. standard | its section, catalog order |
| Remote Machines | `remote.newWorkspace` | New Workspace on Machine |  | c. duplicate | folded into New Workspace on Machine… |
| Remote Machines | `remote.openBrowserTab` | Open Remote Browser Tab… |  | b. standard | its section, catalog order |
| Remote Machines | `remote.openLocalBrowserTab` | Open Remote Browser Tab (Local Host) |  | b. standard | its section, catalog order |
| Remote Machines | `remote.openTerminalHere` | Open Terminal on Machine Here… |  | b. standard | its section, catalog order |
| Remote Machines | `remote.reconnect` | Reconnect Machine |  | b. standard | its section, catalog order |
| Remote Machines | `remote.removeGroup` | Remove Remote Group |  | b. standard | its section, catalog order |
| Remote Machines | `workspace.setRemoteLocalhost` | Set Workspace Localhost… |  | b. standard | its section, catalog order |
| Settings and Help | `announcements.hide` | Hide Announcements |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `announcements.show` | Show Announcements |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `app.command.run` | Run App Command… |  | b. standard | its section, catalog order |
| Settings and Help | `app.hide` | Hide App… |  | b. standard | its section, catalog order |
| Settings and Help | `app.open` | Open App… |  | b. standard | its section, catalog order |
| Settings and Help | `app.shareCmux` | Share cmux… |  | b. standard | its section, catalog order |
| Settings and Help | `app.unhide` | Show Hidden App… |  | b. standard | its section, catalog order |
| Settings and Help | `appStore.show` | App Store |  | b. standard | its section, catalog order |
| Settings and Help | `appStore.showInstalled` | Installed Apps |  | b. standard | its section, catalog order |
| Settings and Help | `appearance.animationSpeed.fast` | Use Fast Animations |  | c. family member | folded into Animations… |
| Settings and Help | `appearance.animationSpeed.normal` | Use Normal Animations |  | c. family member | folded into Animations… |
| Settings and Help | `appearance.animationSpeed.off` | Turn Off Animations |  | c. family member | folded into Animations… |
| Settings and Help | `appearance.animations.bounce.none` | Use Animations Without Bounce |  | c. family member | folded into Animations… |
| Settings and Help | `appearance.animations.bounce.subtle` | Use Bouncy Animations |  | c. family member | folded into Animations… |
| Settings and Help | `appearance.animations.cursor.toggle` | Toggle Agent Cursor Animations |  | c. family member | folded into Animations… |
| Settings and Help | `appearance.animations.feedback.toggle` | Toggle Highlight and Color Animations |  | c. family member | folded into Animations… |
| Settings and Help | `appearance.animations.home.toggle` | Toggle Home and Chat Animations |  | c. family member | folded into Animations… |
| Settings and Help | `appearance.animations.hoverCards.toggle` | Toggle Hover Card Animations |  | c. family member | folded into Animations… |
| Settings and Help | `appearance.animations.indicators.toggle` | Toggle Spinner and Progress Animations |  | c. family member | folded into Animations… |
| Settings and Help | `appearance.animations.newTab.toggle` | Toggle New Tab Animations |  | c. family member | folded into Animations… |
| Settings and Help | `appearance.animations.newWorkspace.toggle` | Toggle New Workspace Animations |  | c. family member | folded into Animations… |
| Settings and Help | `appearance.animations.overlays.toggle` | Toggle Menu and Card Animations |  | c. family member | folded into Animations… |
| Settings and Help | `appearance.animations.panes.toggle` | Toggle Pane and Window Animations |  | c. family member | folded into Animations… |
| Settings and Help | `appearance.animations.sidebar.toggle` | Toggle Sidebar Animations |  | c. family member | folded into Animations… |
| Settings and Help | `appearance.animations.tabs.toggle` | Toggle Tab Animations |  | c. family member | folded into Animations… |
| Settings and Help | `appearance.animations.toggle` | Toggle All Animations |  | c. family member | folded into Animations… |
| Settings and Help | `appearance.animations.web.toggle` | Toggle Web Page Animations |  | c. family member | folded into Animations… |
| Settings and Help | `appearance.changeBackground` | Change Background… |  | a. daily | first in its section, +120 while typing |
| Settings and Help | `appearance.chromeStyle.bare` | Window Style: Bare |  | c. family member | folded into Window Style… |
| Settings and Help | `appearance.chromeStyle.card` | Window Style: Card |  | c. family member | folded into Window Style… |
| Settings and Help | `appearance.chromeStyle.cardOutlined` | Window Style: Card with Outlines |  | c. family member | folded into Window Style… |
| Settings and Help | `appearance.chromeStyle.default` | Window Style: Default |  | c. family member | folded into Window Style… |
| Settings and Help | `appearance.chromeStyle.flat` | Window Style: Flat |  | c. family member | folded into Window Style… |
| Settings and Help | `appearance.chromeStyle.flatSidebarLine` | Window Style: Flat with Sidebar Line |  | c. family member | folded into Window Style… |
| Settings and Help | `appearance.chromeStyle.floating` | Window Style: Floating Panes |  | c. family member | folded into Window Style… |
| Settings and Help | `appearance.chromeStyle.panes` | Window Style: Panes |  | c. family member | folded into Window Style… |
| Settings and Help | `appearance.chromeStyle.twoTone` | Window Style: Two-Tone |  | c. family member | folded into Window Style… |
| Settings and Help | `appearance.customize` | Customize Appearance… |  | a. daily | first in its section, +120 while typing |
| Settings and Help | `appearance.density.comfortable` | Density: Comfortable |  | c. family member | folded into Set Density… |
| Settings and Help | `appearance.density.compact` | Density: Compact |  | c. family member | folded into Set Density… |
| Settings and Help | `appearance.density.cozy` | Density: Cozy |  | c. family member | folded into Set Density… |
| Settings and Help | `appearance.density.create` | New Custom Density… |  | b. standard | its section, catalog order |
| Settings and Help | `appearance.density.set` | Set Density… |  | b. standard | its section, catalog order |
| Settings and Help | `appearance.density.spacious` | Density: Spacious |  | c. family member | folded into Set Density… |
| Settings and Help | `appearance.density.ultraCompact` | Density: Ultra-compact |  | c. family member | folded into Set Density… |
| Settings and Help | `appearance.interfaceSize.decrease` | Decrease Interface Size |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `appearance.interfaceSize.increase` | Increase Interface Size |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `appearance.interfaceSize.reset` | Reset Interface Size |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `appearance.paneBorder.toggle` | Toggle Pane Borders |  | c. family member | folded into Pane Borders and Focus Ring… |
| Settings and Help | `appearance.paneBorderColor.reset` | Use Theme Color for Pane Borders |  | c. family member | folded into Pane Borders and Focus Ring… |
| Settings and Help | `appearance.paneBorderWidth.toggle` | Toggle Thick Pane Borders |  | c. family member | folded into Pane Borders and Focus Ring… |
| Settings and Help | `appearance.paneCorners.toggle` | Toggle Rounded Pane Corners |  | c. family member | folded into Pane Borders and Focus Ring… |
| Settings and Help | `appearance.panePadding.toggle` | Toggle Pane Padding |  | c. family member | folded into Pane Borders and Focus Ring… |
| Settings and Help | `appearance.reset` | Reset Appearance to Inherited |  | b. standard | its section, catalog order |
| Settings and Help | `appearance.set` | Set Appearance… |  | b. standard | its section, catalog order |
| Settings and Help | `appearance.titlebar.minimal` | Use Minimal Titlebar |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `appearance.titlebar.standard` | Use Standard Titlebar |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `appearance.uiScale.decrease` | Decrease Interface Scale | ⌃⇧⌘- | b. standard | its section, catalog order |
| Settings and Help | `appearance.uiScale.increase` | Increase Interface Scale | ⌃⇧⌘= | b. standard | its section, catalog order |
| Settings and Help | `appearance.uiScale.reset` | Reset Interface Scale | ⌃⇧⌘0 | b. standard | its section, catalog order |
| Settings and Help | `browser.defaultEngine.chromium` | Use Chromium for New Browser Tabs |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `browser.defaultEngine.webkit` | Use WebKit for New Browser Tabs |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `browser.hibernation.aggressive` | Hibernate Hidden Tabs After 10 Minutes |  | c. family member | folded into Tab Hibernation… |
| Settings and Help | `browser.hibernation.moderate` | Hibernate Hidden Tabs After 1 Hour |  | c. family member | folded into Tab Hibernation… |
| Settings and Help | `browser.hibernation.off` | Turn Off Tab Hibernation |  | c. family member | folded into Tab Hibernation… |
| Settings and Help | `browser.keepNeighborTabsAwake.0` | Don't Keep Neighbor Tabs Awake |  | c. family member | folded into Tab Hibernation… |
| Settings and Help | `browser.keepNeighborTabsAwake.1` | Keep 1 Neighbor Tab Awake on Each Side |  | c. family member | folded into Tab Hibernation… |
| Settings and Help | `browser.keepNeighborTabsAwake.2` | Keep 2 Neighbor Tabs Awake on Each Side |  | c. family member | folded into Tab Hibernation… |
| Settings and Help | `browser.keepNeighborTabsAwake.3` | Keep 3 Neighbor Tabs Awake on Each Side |  | c. family member | folded into Tab Hibernation… |
| Settings and Help | `fileEditor.importEditorSettings` | Copy Settings from VS Code or Zed |  | b. standard | its section, catalog order |
| Settings and Help | `focusRing.singlePane.toggle` | Toggle Focus Ring for a Single Pane |  | c. family member | folded into Pane Borders and Focus Ring… |
| Settings and Help | `focusRing.style.glow` | Use Glow Focus Style |  | c. family member | folded into Pane Borders and Focus Ring… |
| Settings and Help | `focusRing.style.ring` | Use Ring Focus Style |  | c. family member | folded into Pane Borders and Focus Ring… |
| Settings and Help | `focusRing.toggle` | Toggle Focus Ring |  | c. family member | folded into Pane Borders and Focus Ring… |
| Settings and Help | `ghostty.showDiagnostics` | Show Ghostty Config Diagnostics |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `help.documentation` | cmux Documentation… |  | b. standard | its section, catalog order |
| Settings and Help | `help.featureFlags` | Feature Flags |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `help.showCrashLogs` | Show Crash Logs |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `keybindings.open` | Open Keyboard Shortcuts |  | a. daily | first in its section, +120 while typing |
| Settings and Help | `layout.centerFocusedColumn.always` | Always Center Focused Column |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `layout.centerFocusedColumn.never` | Scroll Columns Minimally |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `layout.centerFocusedColumn.onOverflow` | Center Focused Column on Overflow |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `layout.toggleStripScrollbar` | Toggle Column Scroll Bar |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `links.openInCmuxBrowser` | Links: Open in cmux Browser |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `links.openInDefaultBrowser` | Links: Open in Default Browser |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `nowPlaying.disableCard` | Never Show Media Card |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `nowPlaying.showCard` | Show Media Card |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `openDebugSettings` | Open Debug Settings |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `palette.applyUpdateIfAvailable` | Install Available Update |  | b. standard | its section, catalog order |
| Settings and Help | `palette.attemptUpdate` | Attempt Update |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `palette.checkForUpdates` | Check for Updates… |  | a. daily | first in its section, +120 while typing |
| Settings and Help | `palette.installCLI` | Install cmux CLI in PATH |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `palette.makeDefaultBrowser` | Make cmux the Default Browser |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `palette.makeDefaultTerminal` | Make cmux the Default Terminal |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `palette.openCmuxSettingsFile` | Open cmux-next.json |  | b. standard | its section, catalog order |
| Settings and Help | `palette.openGhosttySettings` | Open Ghostty Config |  | b. standard | its section, catalog order |
| Settings and Help | `palette.pro.upgrade` | Upgrade to cmux Pro |  | b. standard | its section, catalog order |
| Settings and Help | `palette.restartServer` | Restart cmux-tui… |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `palette.restartSocketListener` | Restart CLI Listener |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `palette.searchShortcuts` | Search Keyboard Shortcuts… |  | b. standard | its section, catalog order |
| Settings and Help | `palette.shortcutKeymap` | Base Keymap… |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `palette.switchAppChannel` | Switch Update Channel… |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `palette.toggleSetting` | Toggle Setting… |  | a. daily | first in its section, +120 while typing |
| Settings and Help | `palette.uninstallCLI` | Uninstall cmux CLI from PATH |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `reloadConfiguration` | Reload Configuration | ⇧⌘, | a. daily | first in its section, +120 while typing |
| Settings and Help | `sendFeedback` | Send Feedback |  | b. standard | its section, catalog order |
| Settings and Help | `server.addServer` | Add Server… |  | b. standard | its section, catalog order |
| Settings and Help | `server.makeThisMacAServer` | Make This Mac a Server |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `server.showHealth` | Server Health |  | b. standard | its section, catalog order |
| Settings and Help | `server.showPanel` | Server Status |  | b. standard | its section, catalog order |
| Settings and Help | `server.stopServing` | Stop Serving |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `tabs.overflow.scroll` | Tabs: Use Scrolling Tabs |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `tabs.overflow.shrink` | Tabs: Use Shrinking Tabs |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `updates.rollback` | Roll Back to Previous Version… |  | c. niche | last in its section, −120 while typing |
| Settings and Help | `updates.whatsNew` | What's New in cmux |  | b. standard | its section, catalog order |
