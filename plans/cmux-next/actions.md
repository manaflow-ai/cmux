# Action surfaces

User rule (2026-10-01): every action is supported from the CLI, a right-click menu and the command palette where that makes sense, and this is checked mechanically.

## Data structure

Each `ActionDescriptor` carries `surfacePlan: ActionSurfacePlan` (`Sources/CmuxNextActions/ActionSurfacePlan.swift`):

| Surface | Declaration | Generated where |
| --- | --- | --- |
| Palette | `palette: SurfaceDecision` (offered, or `paletteInternal` for actions that require the palette open) | `RegistryPaletteProvider` lists `isPaletteVisible` |
| CLI | `cli: SurfaceDecision` (offered = the `cmux <noun> <verb>` verb `cliName`; exempt = only `cmux action run <id>`) | `action.list` `surfaces.cli`; the Rust CLI routes offered verbs to the app |
| Right-click | `contextMenus: [ContextMenuPlacement]` (menu, `MenuGroup`, rank, style item/choices/submenu, parent) or `contextMenuExemption` | `ContextMenuCatalog` builds every menu from placements: groups in `MenuGroup` order, separators between groups and between rank hundreds |
| MCP | follows the CLI; `mcpExemption` (credentials, endsApp, systemChange) removes a verb from `cmux mcp serve` | `action.list` `surfaces.mcp` |
| Keyboard | every action binds by `id` (`cmux.json` `shortcuts.<id>`, Settings shortcut editor lists the registry); defaults stay optional | `ActionRegistry` shortcut index |
| Main menu | optional `mainMenu` (not every action belongs in the menu bar) | `makeMainMenuItems` |

Every exemption names a `SurfaceExemption` reason. A descriptor may declare `surfacePlan:` inline; otherwise `ActionSurfaceCatalog` (`ActionSurfaceCatalog+Menus.swift`, `ActionSurfaceCatalog+Exemptions.swift`) fills it after the domain catalogs build, keyed by action id. Every surface calls `ActionRegistry.perform` with the caller's origin: menus and palette `user`, the control socket the request's `origin` (`cli`, `script`, `mcp`).

## Verification

`scripts/cmux-next/check-action-surfaces.sh` runs `ActionSurfaceParityTests`, `ActionContractTests` and `CLISurfaceParityTests`. Over the whole finite catalog they check: every surface declared; placements and exemptions consistent (no placed-and-exempt, `devOnly` only on debug-only actions, MCP exemptions only on CLI verbs, choices only with menu choices, submenu parents exist); each target kind's menu shows every action on that kind (directly, through containment: a tab menu reaches its pane, or in an object-less menu); each generated menu shows exactly its placements; unique CLI names and default shortcuts; every menu item runs its own action through the registry with the item's target and the user origin; every CLI verb runs its own handler by CLI name with the caller's origin; `action.list` reports every surface; `plans/cmux-next/action-surfaces.json` (the export the Rust CLI and MCP parity tests read) is fresh. Rewrite the export with `CMUX_UPDATE_ACTION_SURFACES=1 swift test --filter ActionSurfaceParityTests`.

## Adding an action

Declare its placements (menu, group, rank) and whether the CLI offers it, or name the exemption. `check-action-surfaces.sh` fails until you do.

## Counts (674 actions)

Palette 672, CLI verbs 391, right-click 391, MCP tools 374.

Right-click rows per menu: bookmark 11, bookmarksBar 5, browserPage 30, browserProfile 11, cloudMachine 16, column 16, link 4, newTab 10, notification 4, pane 37, profile 25, screen 31, screenBar 3, screenGroup 22, sidebarBackground 18, sshMachine 5, tab 48, tabGroup 26, terminalSelection 20, workspaceGroup 28, workspaceRow 60.

## Exemptions: Palette

**paletteInternal** (2): operates the palette itself.

`commandPaletteNext`, `commandPalettePrevious`

## Exemptions: CLI (no named verb; `cmux action run <id>` still runs them)

**guiOnly** (77): opens, shows or toggles app UI; nothing to script.

`openSettings`, `minimizeWindow`, `toggleFullScreen`, `globalSearch`, `commandPalette`, `palette.openTaskManager`, `palette.sleepyMode`, `about`, `palette.workspaceCustomColor`, `revealWorkspaceInFinder`, `workspaceGroup.editConfig`, `manageLayouts`, `palette.openWorkspacePullRequests`, `palette.findWork`, `toggleSplitZoom`, `canvasOverview`, `palette.toggleFullWidthTab`, `tab.showResources`, `workspace.showResources`, `toggleBrowserDeveloperTools`, `showBrowserJavaScriptConsole`, `inspectBrowserElement`, `toggleBrowserFocusMode`, `toggleBrowserDesignMode`, `toggleReactGrab`, `palette.browserToggleOmnibar`, `importFromBrowser`, `openLinkInDefaultBrowser`, `filePreviewOpenWith`, `filePreviewOpenExternally`, `filePreviewRevealInFinder`, `palette.vscodeServeWebStop`, `palette.vscodeServeWebRestart`, `browser.pageInfo`, `browser.pageInfo.connection`, `browser.pageInfo.certificate`, `browser.pageInfo.cookies`, `browser.pageInfo.manageSiteData`, `browser.pageInfo.siteSettings`, `browser.pageInfo.aboutThisPage`, `browser.extensions.menu`, `browser.extensions.manage`, `browser.extensions.webStore`, `browser.extension.options`, `browserProfile.manageExtensions`, `toggleSidebar`, `toggleRightSidebar`, `switchRightSidebarToFiles`, `switchRightSidebarToFind`, `switchRightSidebarToSessions`, `switchRightSidebarToFeed`, `switchRightSidebarToDock`, `switchRightSidebarToMachines`, `showNotifications`, `palette.openTerminalChatView`, `palette.computerUse.setup`, `palette.computerUse.accessibility`, `palette.computerUse.screenRecording`, `palette.cloud.tools`, `cloudOpenMachine`, `openTeamPicker`, `palette.mobileConnect`, `palette.openCmuxSettingsFile`, `palette.openGhosttySettings`, `palette.searchShortcuts`, `palette.pro.upgrade`, `palette.welcomeChecklist`, `sendFeedback`, `help.featureFlags`, `help.documentation`, `recentlyFocused`, `recentlyClosed`, `history.commands`, `browserShowHistory`, `history.search`, `bookmark.toggleBar`, `bookmark.manager`

**liveInput** (67): acts on live input focus: text field, selection, find bar, copy mode, text box, or a selected panel row.

`taskManager.killProcess`, `toggleChecklistItemComplete`, `groupSelectedWorkspaces`, `canvasAlignLeft`, `canvasAlignRight`, `canvasAlignTop`, `canvasAlignBottom`, `canvasEqualizeWidths`, `canvasEqualizeHeights`, `canvasDistributeHorizontally`, `canvasDistributeVertically`, `simulatorHome`, `simulatorRotateLeft`, `simulatorRotateRight`, `simulatorToggleAppearance`, `simulatorToggleSoftwareKeyboard`, `toggleTerminalCopyMode`, `palette.terminalToggleTextBoxInput`, `cycleTextBoxSubmitAction`, `attachTextBoxFile`, `sendCtrlFToTerminal`, `pasteLastScreenshot`, `find`, `findInDirectory`, `findNext`, `findPrevious`, `hideFind`, `useSelectionForFind`, `terminalCopy`, `terminalPaste`, `openLinkInNewTab`, `browserScreenshotSection`, `saveFilePreview`, `toggleFileEditorWordWrap`, `diffViewerNextLine`, `diffViewerPreviousLine`, `diffViewerHalfPageDown`, `diffViewerHalfPageUp`, `diffViewerNextHunk`, `diffViewerPreviousHunk`, `diffViewerGoToBottom`, `diffViewerGoToTop`, `diffViewerSearch`, `diffViewerNextFile`, `diffViewerPreviousFile`, `fileExplorerOpenSelection`, `fileExplorerOpenSelectionFinderAlias`, `fileExplorerOpenInCmux`, `fileExplorerReveal`, `fileExplorerCopyPath`, `fileExplorerCopyRelativePath`, `fileExplorerOpenWith`, `vaultOpenSession`, `vaultResumeInNewWorkspace`, `vaultCopyResumeCommand`, `vaultOpenPullRequest`, `checklistEditItem`, `checklistMarkInProgress`, `checklistCompleteItem`, `checklistRemoveItem`, `checklistOpenAsPane`, `checklistAttachImages`, `toggleUnread`, `notificationCopy`, `notificationToggleRead`, `notificationDismiss`, `terminal.selectAll`

**familyMember** (51): a value of a family another action offers (colors, collapse/expand, engine entries, cycles).

`cycleWorkspaceStatus`, `toggleFocusedWorkspaceGroupCollapsed`, `workspaceGroup.color.grey`, `workspaceGroup.color.blue`, `workspaceGroup.color.red`, `workspaceGroup.color.yellow`, `workspaceGroup.color.green`, `workspaceGroup.color.pink`, `workspaceGroup.color.purple`, `workspaceGroup.color.cyan`, `workspaceGroup.color.orange`, `room.color.grey`, `room.color.blue`, `room.color.red`, `room.color.yellow`, `room.color.green`, `room.color.pink`, `room.color.purple`, `room.color.cyan`, `room.color.orange`, `tabGroup.toggleCollapsed`, `tabGroup.color.grey`, `tabGroup.color.blue`, `tabGroup.color.red`, `tabGroup.color.yellow`, `tabGroup.color.green`, `tabGroup.color.pink`, `tabGroup.color.purple`, `tabGroup.color.cyan`, `tabGroup.color.orange`, `screen.color.grey`, `screen.color.blue`, `screen.color.red`, `screen.color.yellow`, `screen.color.green`, `screen.color.pink`, `screen.color.purple`, `screen.color.cyan`, `screen.color.orange`, `screenGroup.toggleCollapsed`, `screenGroup.color.grey`, `screenGroup.color.blue`, `screenGroup.color.red`, `screenGroup.color.yellow`, `screenGroup.color.green`, `screenGroup.color.pink`, `screenGroup.color.purple`, `screenGroup.color.cyan`, `screenGroup.color.orange`, `resumeCommandEdit`, `palette.attemptUpdate`

**focusMove** (43): moves focus or selection, or shows an object; the click is the gesture and view state belongs to each client.

`showHideAllWindows`, `goToWorkspace`, `showMainWindow`, `nextSidebarTab`, `prevSidebarTab`, `nextSidebarTabInGroup`, `prevSidebarTabInGroup`, `selectWorkspaceByNumber`, `workspace.selectFirst`, `workspace.selectLast`, `workspace.selectLastUsed`, `room.next`, `room.previous`, `room.selectByNumber`, `focusLeft`, `focusRight`, `focusUp`, `focusDown`, `focusPreviousPane`, `focusNextPane`, `canvasRevealFocusedPane`, `nextSurface`, `prevSurface`, `selectSurfaceByNumber`, `palette.goToTab`, `screen.next`, `screen.previous`, `screen.select`, `screen.selectLast`, `focusTextBoxInput`, `focusBrowserAddressBar`, `focusRightSidebar`, `vaultFocusSession`, `jumpToUnread`, `markOldestUnreadAndJumpNext`, `notificationOpen`, `computerUseFocus`, `computerUseFocusCallingTerminal`, `column.focusLeft`, `column.focusRight`, `focusHistoryBack`, `focusHistoryForward`, `focusHistoryLast`

**stepAdjust** (28): one step of a repeated adjustment (zoom, font size, resize, scroll).

`resizePaneLeft`, `resizePaneRight`, `resizePaneUp`, `resizePaneDown`, `increaseWorkspaceTerminalFontSize`, `decreaseWorkspaceTerminalFontSize`, `resetWorkspaceTerminalFontSize`, `canvasZoomIn`, `canvasZoomOut`, `canvasZoomReset`, `browserZoomIn`, `browserZoomOut`, `browserZoomReset`, `markdownZoomIn`, `markdownZoomOut`, `markdownZoomReset`, `appearance.interfaceSize.increase`, `appearance.interfaceSize.decrease`, `appearance.interfaceSize.reset`, `column.cycleWidth`, `column.cycleWidthBack`, `terminal.increaseFontSize`, `terminal.decreaseFontSize`, `terminal.resetFontSize`, `terminal.scrollPageUp`, `terminal.scrollPageDown`, `terminal.scrollToTop`, `terminal.scrollToBottom`

**clipboard** (13): copies to the pasteboard; the CLI prints the same value.

`copyWorkspaceSSHError`, `palette.copyWorkspaceID`, `palette.copyWorkspaceIDAndRef`, `palette.copyWorkspaceLink`, `workspace.copyPath`, `palette.copyIdentifiers`, `palette.copyPaneID`, `palette.copyPaneLink`, `palette.copySurfaceID`, `palette.copySurfaceLink`, `cloudCopyLink`, `cloudCopyPort`, `cloudCopyMachineID`

**paletteInternal** (2): operates the palette itself.

`commandPaletteNext`, `commandPalettePrevious`

**devOnly** (2): debug builds only.

`openDebugSettings`, `palette.onboardingGallery`

## Exemptions: Right-click

**noObject** (118): app-wide; nothing to right-click.

`openSettings`, `newWindow`, `newIncognitoWindow`, `closeWindow`, `minimizeWindow`, `toggleFullScreen`, `quit`, `quitKeepSessions`, `quitEndSessions`, `quitEndEverything`, `globalSearch`, `commandPalette`, `palette.openTaskManager`, `palette.sleepyMode`, `keepMacAwake`, `about`, `manageLayouts`, `palette.findWork`, `reopenClosedBrowserPanel`, `palette.browserClearHistory`, `importFromBrowser`, `palette.enableBrowser`, `palette.disableBrowser`, `toggleRightSidebar`, `switchRightSidebarToFiles`, `switchRightSidebarToFind`, `switchRightSidebarToSessions`, `switchRightSidebarToFeed`, `switchRightSidebarToDock`, `switchRightSidebarToMachines`, `palette.toggleMatchTerminalBackground`, `palette.enableMinimalMode`, `palette.disableMinimalMode`, `showNotifications`, `markAllNotificationsRead`, `clearAllNotifications`, `notifications.toggleBanners`, `notifications.dismissal.keystroke`, `notifications.dismissal.focus`, `notifications.dismissal.click`, `notifications.dismissal.explicit`, `notifications.dismissal.timeout`, `notifications.dismissal.never`, `palette.openTerminalChatView`, `palette.launchClaudeTeams`, `palette.launchCodexTeams`, `palette.computerUse.setup`, `palette.computerUse.accessibility`, `palette.computerUse.screenRecording`, `computerUseStop`, `newCloudMachine`, `cloudDiagnostics`, `openTeamPicker`, `palette.auth.signIn`, `palette.auth.signOut`, `palette.mobileConnect`, `accounts.show`, `accounts.refresh`, `accounts.reauthenticate`, `accounts.connect`, `accounts.remove`, `reloadConfiguration`, `palette.openCmuxSettingsFile`, `palette.openGhosttySettings`, `palette.makeDefaultBrowser`, `palette.makeDefaultTerminal`, `palette.toggleSetting`, `palette.shortcutKeymap`, `palette.searchShortcuts`, `palette.installCLI`, `palette.uninstallCLI`, `palette.restartSocketListener`, `palette.checkForUpdates`, `palette.applyUpdateIfAvailable`, `palette.switchAppChannel`, `palette.pro.upgrade`, `palette.welcomeChecklist`, `sendFeedback`, `help.featureFlags`, `help.documentation`, `appearance.density.compact`, `appearance.density.comfortable`, `appearance.animationSpeed.fast`, `appearance.animationSpeed.normal`, `appearance.animationSpeed.off`, `browser.defaultEngine.chromium`, `browser.defaultEngine.webkit`, `appearance.paneBorder.toggle`, `appearance.panePadding.toggle`, `appearance.paneCorners.toggle`, `layout.centerFocusedColumn.never`, `layout.centerFocusedColumn.always`, `layout.centerFocusedColumn.onOverflow`, `focusRing.toggle`, `focusRing.style.ring`, `focusRing.style.glow`, `focusRing.singlePane.toggle`, `appearance.paneBorderWidth.toggle`, `appearance.paneBorderColor.reset`, `appearance.titlebar.minimal`, `appearance.titlebar.standard`, `browser.hibernation.off`, `browser.hibernation.moderate`, `browser.hibernation.aggressive`, `layout.toggleStripScrollbar`, `recentlyFocused`, `recentlyClosed`, `history.commands`, `history.show`, `browserShowHistory`, `history.search`, `history.resumeAgentSession`, `history.reopen`, `history.clear`, `layout.undo`, `bookmark.add`, `bookmark.import`, `bookmark.export`

**noTargetSurface** (57): its object (diff viewer, file preview, simulator, canvas, saved screen groups, file explorer, vault, checklist rows, task manager, resume command) has no right-click surface yet; a gap to close with that surface.

`taskManager.killProcess`, `toggleChecklistItemComplete`, `canvasOverview`, `canvasTidy`, `canvasAlignLeft`, `canvasAlignRight`, `canvasAlignTop`, `canvasAlignBottom`, `canvasEqualizeWidths`, `canvasEqualizeHeights`, `canvasDistributeHorizontally`, `canvasDistributeVertically`, `simulatorHome`, `simulatorRotateLeft`, `simulatorRotateRight`, `simulatorToggleAppearance`, `simulatorToggleSoftwareKeyboard`, `screenGroup.reopenSaved`, `screenGroup.deleteSaved`, `resumeCommandSet`, `resumeCommandEdit`, `resumeCommandClear`, `saveFilePreview`, `toggleFileEditorWordWrap`, `filePreviewOpenWith`, `filePreviewOpenExternally`, `filePreviewRevealInFinder`, `diffViewerNextLine`, `diffViewerPreviousLine`, `diffViewerHalfPageDown`, `diffViewerHalfPageUp`, `diffViewerNextHunk`, `diffViewerPreviousHunk`, `diffViewerGoToBottom`, `diffViewerGoToTop`, `diffViewerSearch`, `diffViewerNextFile`, `diffViewerPreviousFile`, `palette.vscodeServeWebStop`, `palette.vscodeServeWebRestart`, `fileExplorerOpenSelection`, `fileExplorerOpenSelectionFinderAlias`, `fileExplorerOpenInCmux`, `fileExplorerReveal`, `fileExplorerCopyPath`, `fileExplorerCopyRelativePath`, `fileExplorerOpenWith`, `vaultOpenSession`, `vaultResumeInNewWorkspace`, `vaultCopyResumeCommand`, `vaultOpenPullRequest`, `checklistEditItem`, `checklistMarkInProgress`, `checklistCompleteItem`, `checklistRemoveItem`, `checklistOpenAsPane`, `checklistAttachImages`

**focusMove** (43): moves focus or selection, or shows an object; the click is the gesture and view state belongs to each client.

`showHideAllWindows`, `goToWorkspace`, `showMainWindow`, `nextSidebarTab`, `prevSidebarTab`, `nextSidebarTabInGroup`, `prevSidebarTabInGroup`, `selectWorkspaceByNumber`, `workspace.selectFirst`, `workspace.selectLast`, `workspace.selectLastUsed`, `room.next`, `room.previous`, `room.selectByNumber`, `room.switch`, `focusLeft`, `focusRight`, `focusUp`, `focusDown`, `focusPreviousPane`, `focusNextPane`, `canvasRevealFocusedPane`, `nextSurface`, `prevSurface`, `selectSurfaceByNumber`, `palette.goToTab`, `screen.next`, `screen.previous`, `screen.select`, `screen.selectLast`, `focusTextBoxInput`, `focusBrowserAddressBar`, `focusRightSidebar`, `vaultFocusSession`, `jumpToUnread`, `markOldestUnreadAndJumpNext`, `computerUseFocus`, `computerUseFocusCallingTerminal`, `column.focusLeft`, `column.focusRight`, `focusHistoryBack`, `focusHistoryForward`, `focusHistoryLast`

**stepAdjust** (28): one step of a repeated adjustment (zoom, font size, resize, scroll).

`resizePaneLeft`, `resizePaneRight`, `resizePaneUp`, `resizePaneDown`, `increaseWorkspaceTerminalFontSize`, `decreaseWorkspaceTerminalFontSize`, `resetWorkspaceTerminalFontSize`, `canvasZoomIn`, `canvasZoomOut`, `canvasZoomReset`, `browserZoomIn`, `browserZoomOut`, `browserZoomReset`, `markdownZoomIn`, `markdownZoomOut`, `markdownZoomReset`, `appearance.interfaceSize.increase`, `appearance.interfaceSize.decrease`, `appearance.interfaceSize.reset`, `column.cycleWidth`, `column.cycleWidthBack`, `terminal.increaseFontSize`, `terminal.decreaseFontSize`, `terminal.resetFontSize`, `terminal.scrollPageUp`, `terminal.scrollPageDown`, `terminal.scrollToTop`, `terminal.scrollToBottom`

**familyMember** (18): a value of a family another action offers (colors, collapse/expand, engine entries, cycles).

`cycleWorkspaceStatus`, `workspaceGroup.collapse`, `workspaceGroup.expand`, `openBrowser`, `tabGroup.collapse`, `tabGroup.expand`, `screenGroup.collapse`, `screenGroup.expand`, `browser.extension.run`, `browser.extension.options`, `browser.extension.pin`, `browser.extension.unpin`, `browser.extension.enable`, `browser.extension.disable`, `browser.extension.reload`, `browser.extension.remove`, `browser.extension.command`, `palette.attemptUpdate`

**liveInput** (12): acts on live input focus: text field, selection, find bar, copy mode, text box, or a selected panel row.

`toggleTerminalCopyMode`, `palette.terminalToggleTextBoxInput`, `cycleTextBoxSubmitAction`, `attachTextBoxFile`, `sendCtrlFToTerminal`, `pasteLastScreenshot`, `find`, `findInDirectory`, `findNext`, `findPrevious`, `hideFind`, `toggleUnread`

**dragGesture** (3): the gesture is a drag to an index; the menu offers the discrete moves.

`room.move`, `browser.extension.move`, `bookmark.move`

**paletteInternal** (2): operates the palette itself.

`commandPaletteNext`, `commandPalettePrevious`

**devOnly** (2): debug builds only.

`openDebugSettings`, `palette.onboardingGallery`

## Exemptions: MCP

**systemChange** (8): changes preferences, the system or the running app outside the user's work.

`palette.makeDefaultBrowser`, `palette.makeDefaultTerminal`, `palette.toggleSetting`, `palette.installCLI`, `palette.uninstallCLI`, `palette.restartSocketListener`, `palette.applyUpdateIfAvailable`, `palette.switchAppChannel`

**credentials** (5): sign-in, accounts, secrets: a person does it.

`palette.auth.signIn`, `palette.auth.signOut`, `accounts.reauthenticate`, `accounts.connect`, `accounts.remove`

**endsApp** (4): quits the app the user works in.

`quit`, `quitKeepSessions`, `quitEndSessions`, `quitEndEverything`

Every action without a CLI verb is also not an MCP tool, with the CLI reason.
