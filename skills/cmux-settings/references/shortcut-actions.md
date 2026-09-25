# Keyboard shortcut action ids

Every action id in `web/data/cmux.schema.json`
(`shortcuts.bindings.propertyNames.enum`). `tests/test_cmux_settings_supported_paths.py`
fails if this list and the schema disagree, so an id missing here is a bug in this file.

Values for `shortcuts.bindings.<action>`:

- A string like `"cmd+b"` for a single shortcut.
- A two-element array like `["ctrl+b","c"]` for a chord.
- `null` or an empty string (`""`, `"none"`, `"clear"`, `"unbound"`, `"disabled"`) to unbind.

## App

- `shortcuts.bindings.closeWindow`
- `shortcuts.bindings.globalSearch`
- `shortcuts.bindings.newWindow`
- `shortcuts.bindings.openFolder`
- `shortcuts.bindings.openSettings`
- `shortcuts.bindings.openTeamPicker`
- `shortcuts.bindings.quit`
- `shortcuts.bindings.reloadConfiguration`
- `shortcuts.bindings.sendFeedback`
- `shortcuts.bindings.showHideAllWindows`
- `shortcuts.bindings.toggleFullScreen`

## Tabs

- `shortcuts.bindings.closeOtherTabsInPane`
- `shortcuts.bindings.closeTab`
- `shortcuts.bindings.newBrowserWorkspace`
- `shortcuts.bindings.newTab`
- `shortcuts.bindings.renameTab`
- `shortcuts.bindings.reopenPreviousSession`

## Workspace

- `shortcuts.bindings.closeWorkspace`
- `shortcuts.bindings.cycleWorkspaceStatus`
- `shortcuts.bindings.editWorkspaceDescription`
- `shortcuts.bindings.goToWorkspace`
- `shortcuts.bindings.groupSelectedWorkspaces`
- `shortcuts.bindings.markWorkspaceDone`
- `shortcuts.bindings.moveWorkspaceDown`
- `shortcuts.bindings.moveWorkspaceUp`
- `shortcuts.bindings.newCloudMachine`
- `shortcuts.bindings.newCloudWorkspace`
- `shortcuts.bindings.newWorkspaceGroup`
- `shortcuts.bindings.renameWorkspace`
- `shortcuts.bindings.reopenClosedBrowserPanel`
- `shortcuts.bindings.reopenClosedWorkspace`
- `shortcuts.bindings.selectWorkspaceByNumber`
- `shortcuts.bindings.toggleFocusedWorkspaceGroupCollapsed`

## Panes and surfaces

- `shortcuts.bindings.attachTextBoxFile`
- `shortcuts.bindings.clearScreenKeepScrollback`
- `shortcuts.bindings.cycleTextBoxSubmitAction`
- `shortcuts.bindings.decreaseWorkspaceTerminalFontSize`
- `shortcuts.bindings.equalizeSplits`
- `shortcuts.bindings.focusDown`
- `shortcuts.bindings.focusHistoryBack`
- `shortcuts.bindings.focusHistoryForward`
- `shortcuts.bindings.focusLeft`
- `shortcuts.bindings.focusNextPane`
- `shortcuts.bindings.focusPreviousPane`
- `shortcuts.bindings.focusRight`
- `shortcuts.bindings.focusTextBoxInput`
- `shortcuts.bindings.focusUp`
- `shortcuts.bindings.increaseWorkspaceTerminalFontSize`
- `shortcuts.bindings.moveSurfaceLeft`
- `shortcuts.bindings.moveSurfaceRight`
- `shortcuts.bindings.moveSurfaceToNextPane`
- `shortcuts.bindings.moveSurfaceToPaneDown`
- `shortcuts.bindings.moveSurfaceToPaneLeft`
- `shortcuts.bindings.moveSurfaceToPaneRight`
- `shortcuts.bindings.moveSurfaceToPaneUp`
- `shortcuts.bindings.moveSurfaceToPreviousPane`
- `shortcuts.bindings.newSurface`
- `shortcuts.bindings.nextSurface`
- `shortcuts.bindings.prevSurface`
- `shortcuts.bindings.resetWorkspaceTerminalFontSize`
- `shortcuts.bindings.resize-pane-down`
- `shortcuts.bindings.resize-pane-left`
- `shortcuts.bindings.resize-pane-right`
- `shortcuts.bindings.resize-pane-up`
- `shortcuts.bindings.selectSurfaceByNumber`
- `shortcuts.bindings.simulatorHome`
- `shortcuts.bindings.simulatorRotateLeft`
- `shortcuts.bindings.simulatorRotateRight`
- `shortcuts.bindings.simulatorToggleAppearance`
- `shortcuts.bindings.simulatorToggleSoftwareKeyboard`
- `shortcuts.bindings.splitDown`
- `shortcuts.bindings.splitRight`
- `shortcuts.bindings.toggleSplitZoom`
- `shortcuts.bindings.toggleTerminalCopyMode`

## Canvas

- `shortcuts.bindings.canvasAlignBottom`
- `shortcuts.bindings.canvasAlignLeft`
- `shortcuts.bindings.canvasAlignRight`
- `shortcuts.bindings.canvasAlignTop`
- `shortcuts.bindings.canvasDistributeHorizontally`
- `shortcuts.bindings.canvasDistributeVertically`
- `shortcuts.bindings.canvasEqualizeHeights`
- `shortcuts.bindings.canvasEqualizeWidths`
- `shortcuts.bindings.canvasOverview`
- `shortcuts.bindings.canvasRevealFocusedPane`
- `shortcuts.bindings.canvasTidy`
- `shortcuts.bindings.canvasZoomIn`
- `shortcuts.bindings.canvasZoomOut`
- `shortcuts.bindings.canvasZoomReset`
- `shortcuts.bindings.toggleCanvasLayout`

## Command palette

- `shortcuts.bindings.commandPalette`
- `shortcuts.bindings.commandPaletteNext`
- `shortcuts.bindings.commandPalettePrevious`

## Notifications

- `shortcuts.bindings.clearAllNotifications`
- `shortcuts.bindings.jumpToUnread`
- `shortcuts.bindings.markAllNotificationsRead`
- `shortcuts.bindings.markOldestUnreadAndJumpNext`
- `shortcuts.bindings.showNotifications`
- `shortcuts.bindings.toggleUnread`
- `shortcuts.bindings.triggerFlash`

## Right sidebar

- `shortcuts.bindings.focusRightSidebar`
- `shortcuts.bindings.nextSidebarTab`
- `shortcuts.bindings.nextSidebarTabInGroup`
- `shortcuts.bindings.prevSidebarTab`
- `shortcuts.bindings.prevSidebarTabInGroup`
- `shortcuts.bindings.switchRightSidebarToDock`
- `shortcuts.bindings.switchRightSidebarToFeed`
- `shortcuts.bindings.switchRightSidebarToFiles`
- `shortcuts.bindings.switchRightSidebarToFind`
- `shortcuts.bindings.switchRightSidebarToMachines`
- `shortcuts.bindings.switchRightSidebarToSessions`
- `shortcuts.bindings.toggleSidebar`

## Browser

- `shortcuts.bindings.browserBack`
- `shortcuts.bindings.browserForward`
- `shortcuts.bindings.browserHardReload`
- `shortcuts.bindings.browserReload`
- `shortcuts.bindings.browserZoomIn`
- `shortcuts.bindings.browserZoomOut`
- `shortcuts.bindings.browserZoomReset`
- `shortcuts.bindings.focusBrowserAddressBar`
- `shortcuts.bindings.openBrowser`
- `shortcuts.bindings.showBrowserJavaScriptConsole`
- `shortcuts.bindings.splitBrowserDown`
- `shortcuts.bindings.splitBrowserRight`
- `shortcuts.bindings.toggleBrowserDesignMode`
- `shortcuts.bindings.toggleBrowserDeveloperTools`
- `shortcuts.bindings.toggleBrowserFocusMode`

## Find

- `shortcuts.bindings.find`
- `shortcuts.bindings.findInDirectory`
- `shortcuts.bindings.findNext`
- `shortcuts.bindings.findPrevious`
- `shortcuts.bindings.hideFind`
- `shortcuts.bindings.sendCtrlFToTerminal`
- `shortcuts.bindings.useSelectionForFind`

## Files and React Grab

- `shortcuts.bindings.fileExplorerOpenSelection`
- `shortcuts.bindings.fileExplorerOpenSelectionFinderAlias`
- `shortcuts.bindings.saveFilePreview`
- `shortcuts.bindings.toggleFileEditorWordWrap`
- `shortcuts.bindings.toggleFileExplorer`
- `shortcuts.bindings.toggleReactGrab`

## Markdown and diff viewer

- `shortcuts.bindings.diffViewerNextFile`
- `shortcuts.bindings.diffViewerOpenFileSearch`
- `shortcuts.bindings.diffViewerPreviousFile`
- `shortcuts.bindings.diffViewerScrollDown`
- `shortcuts.bindings.diffViewerScrollDownEmacs`
- `shortcuts.bindings.diffViewerScrollHalfPageDown`
- `shortcuts.bindings.diffViewerScrollHalfPageUp`
- `shortcuts.bindings.diffViewerScrollToBottom`
- `shortcuts.bindings.diffViewerScrollToTop`
- `shortcuts.bindings.diffViewerScrollUp`
- `shortcuts.bindings.diffViewerScrollUpEmacs`
- `shortcuts.bindings.markdownZoomIn`
- `shortcuts.bindings.markdownZoomOut`
- `shortcuts.bindings.markdownZoomReset`
- `shortcuts.bindings.openDiffViewer`
- `shortcuts.bindings.toggleChecklistItemComplete`
