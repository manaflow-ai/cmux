# AppKit Workspace Behavior Spec

This document defines the required behavior for the workspace split, pane, and tab system that replaces Bonsplit.

This document is intentionally about `what` the system must do. It does not define classes, views, frameworks, ownership patterns, or any other implementation detail.

## Scope

The replacement owns all behavior inside a workspace content area:

- Split tree structure
- Pane chrome and tab chrome
- Tab ordering, selection, and close behavior
- Split creation, resize, close, and zoom behavior
- Drag and drop within a workspace and across workspaces
- Focus and first-responder convergence
- Geometry snapshots for automation and persistence
- Session restore of layout and panel state
- Hosting behavior for terminal, browser, and markdown panels

## Core Terms

- Workspace: one top-level document-like container with its own split tree and panel set.
- Pane: one leaf in the split tree.
- Panel: one live content surface, such as terminal, browser, or markdown.
- Tab: one visible tab-strip entry that maps to exactly one live panel.
- Selected tab: the active tab inside a pane.
- Focused pane: the pane that owns keyboard navigation context.
- Focused panel: the panel that should receive keyboard input.
- Split zoom: a state where one pane temporarily occupies the full workspace area without destroying the underlying split tree.

## Structural Contract

- A workspace is always a recursive binary split tree with one or more leaf panes.
- Every pane has a stable opaque pane ID.
- Every tab has a stable opaque tab ID.
- Every visible tab maps to exactly one live panel.
- Placeholder tabs are not allowed in the final system.
- A non-empty pane always has exactly one selected tab.
- The last remaining pane may not be closed by normal pane-close behavior.
- Closing the last tab in a non-last pane closes that pane.
- Closing the last tab in the last remaining pane closes the workspace only when the higher-level app policy explicitly allows it.

## Visual Contract

- The replacement must look materially identical to the current workspace UI.
- Pane chrome background follows Ghostty's resolved runtime background color and runtime background opacity.
- When no explicit border color is provided, separators and dividers derive from the current chrome background.
- Focused and unfocused panes preserve the current saturation, tint, and contrast behavior.
- Tab bar height is `30`.
- Tab height is `30`.
- Tab minimum width is `48`.
- Tab maximum width is `220`.
- Tab horizontal padding is `6`.
- Tab spacing is `0`.
- Tab corner radius is `0`.
- Active tab indicator height is `2`.
- Icon size is `14`.
- Title font size is `11`.
- Close button size is `16`.
- Close icon size is `9`.
- Dirty-indicator size is `8`.
- Notification-badge size is `6`.
- Content spacing inside a tab is `6`.
- Drop-indicator width is `2`.
- Drop-indicator height is `20`.
- Divider thickness is `1`.
- Minimum pane width is `100`.
- Minimum pane height is `100`.
- Split-action buttons remain in the pane chrome and preserve current iconography, hover states, pressed states, tooltips, and visibility rules.
- Minimal-mode behavior remains unchanged, including the 30-point top interaction strip and hover-driven action visibility.

## Color Contract

- With no custom chrome background, chrome colors match the current native system color behavior.
- With a custom chrome background, text color flips between dark and light treatment based on background luminance.
- Active text uses alpha `0.82`.
- Secondary or inactive text uses alpha `0.62` on dark-text treatment and `0.68` on light-text treatment.
- Active tab background is the chrome background darkened by `0.065` for light chrome or lightened by `0.12` for dark chrome.
- Hovered tab background is the chrome background darkened by `0.03` for light chrome or lightened by `0.07` for dark chrome, then shown with alpha `0.78`.
- Derived separator color uses alpha `0.26` for light chrome or `0.36` for dark chrome.
- Dirty indicators use the active text color at alpha `0.72` when custom chrome is active.
- Notification badges use the current blue accent treatment.
- Drop indicators use the current accent-color treatment.

## Tab Behavior

- Tabs inside a pane are ordered and stable.
- Pinned tabs always occupy a contiguous block at the front of the pane.
- Unpinned tabs always appear after the pinned block.
- Reordering must preserve the pinned and unpinned partition.
- Creating a pinned tab inserts it at the end of the pinned block.
- Creating an unpinned tab inserts it after the currently selected tab when the current new-tab policy applies, otherwise at the end of the unpinned block.
- Selecting a tab selects it in its pane and focuses that pane.
- Programmatic selection and user-driven selection must produce the same final state.
- Closing the selected tab picks the tab that moves into the same slot when possible, otherwise the previous tab if the closed tab was last.
- Tab metadata includes title, custom-title state, icon or icon image, kind, dirty state, unread state, loading state, and pinned state.
- Tab switching must preserve underlying panel state, including terminal state, browser state, markdown scroll state, find state, and developer-tools state.
- Only the selected tab in a pane may be visible and interactive.
- Non-selected content may not remain visually visible above the selected content.
- Non-selected content may not intercept drag, drop, hit-testing, or keyboard focus meant for the selected content.

## Tab Context Menu Contract

- The tab context menu supports rename.
- The tab context menu supports clearing a custom name.
- The tab context menu supports close to left.
- The tab context menu supports close to right.
- The tab context menu supports close others.
- The tab context menu supports move.
- The tab context menu supports move to left pane when such a destination exists.
- The tab context menu supports move to right pane when such a destination exists.
- The tab context menu supports creating a new terminal to the right.
- The tab context menu supports creating a new browser to the right.
- Browser tabs expose reload.
- Browser tabs expose duplicate.
- Tabs expose toggle pin.
- Tabs expose mark as read and mark as unread, gated by current unread state.
- Tabs expose toggle split zoom when the workspace has more than one pane.
- Context-menu shortcut hints remain synchronized with customizable keyboard shortcuts.

## Pane Behavior

- A pane shows its tab strip, its selected content, and any pane-local overlays.
- Clicking content inside a pane makes that pane the focused pane.
- A focused pane visually matches the current focused-pane treatment.
- An unfocused pane visually matches the current unfocused-pane treatment.
- Pane-local unread rings and attention flash effects preserve current behavior.
- Empty panes remain user-visible and actionable.
- An empty pane offers the same entry actions as today, including creating a terminal or browser in that pane.

## Split Behavior

- A split is always either horizontal or vertical.
- Horizontal means side-by-side, first pane on the left and second pane on the right.
- Vertical means stacked, first pane on top and second pane on bottom.
- New user-created splits begin at a `0.5` divider ratio.
- Programmatic divider updates clamp by both ratio and absolute pane minimum.
- Ratio clamp remains `0.1...0.9`.
- Absolute clamp enforces the current pane minimum width and height of `100` points.
- Effective divider bounds are `max(0.1, 100 / axisLength)...min(0.9, 1 - 100 / axisLength)` when axis length permits.
- If axis length cannot satisfy two 100-point panes, the divider clamps to the closest valid value and pane minimum wins over ratio.
- Divider movement updates geometry snapshots and layout persistence.
- Closing a pane collapses the tree by promoting its sibling.
- After pane close, focus moves to the surviving sibling when possible, otherwise the first remaining pane.
- Split creation from pane chrome preserves the current behavior of seeding a terminal in the new pane.
- Split creation by moving an existing tab preserves that tab's metadata, panel identity, and panel state.
- Dragging the only tab from a pane to create a split must not leave behind a placeholder tab or a pane with no real panel mapping.
- Adjacent-pane navigation remains geometry-driven.
- If no pane exists in the requested direction, pane navigation is a no-op.
- When more than one candidate exists in a direction, the chosen pane is the one with the strongest perpendicular overlap, then the shortest distance.

## Split Zoom Behavior

- Split zoom is unavailable when the workspace has only one pane.
- Toggling split zoom on a pane shows only that pane in the workspace content area.
- Toggling split zoom again restores the prior split tree and divider ratios.
- Split zoom does not destroy panel state.
- Split zoom does not change tab ordering.
- Split zoom does not leave stale content, stale portal layers, or stale pane chrome visible after entering or exiting zoom.
- The selected tab in the zoomed pane shows the current zoom indicator treatment.

## Drag and Drop Contract

- Tabs can be reordered within a pane.
- Tabs can move across panes inside the same workspace.
- Tabs can move across workspaces and windows.
- Dropping on a pane center inserts into that pane.
- Dropping on a pane edge creates a split on that edge and places the tab in the new pane on the correct side.
- Dropping after the last tab in a tab strip inserts after the last tab.
- Dragging a tab over trailing empty space in a short tab strip still permits an after-last insertion.
- Inactive workspaces may remain mounted for state preservation, but they must not accept or steal drag interactions.
- File drops from outside the app onto a pane's content area target the currently selected terminal panel in that pane.
- Tab drags and sidebar reordering drags remain distinct and may not be confused with each other.
- Drag and drop may not violate pinned-tab ordering rules.

## Focus Contract

- Focused pane state, selected tab state, and AppKit first responder must converge.
- Visual selection may not drift away from actual keyboard target.
- Explicit pane focus changes focus the selected tab's panel in that pane.
- Explicit tab selection focuses that tab's pane and panel.
- Focus changes caused by socket or automation commands may only change in-app focus for commands that are explicitly focus-intent commands.
- Non-focus automation commands may not steal macOS app activation or window activation.
- Terminal focus, browser focus, omnibar focus, browser find focus, and terminal find focus must preserve their current behavior.
- Switching away from a browser tab must hide its visible browser surface.
- Switching away from a terminal tab must prevent stale terminal focus from stealing first responder back.

## Panel-Specific Contract

- Terminal panels preserve terminal process state, scrollback state, selection state, find state, and runtime font zoom state across tab switches, splits, zoom, and pane resizes.
- Terminal overlays, including find UI and unread or flash effects, remain correctly layered during split churn.
- Browser panels preserve URL, history stacks, profile, page zoom, developer-tools visibility intent, inline focus state, and current web content across tab switches, splits, zoom, and pane resizes.
- Browser panels may not remain visible when deselected.
- Markdown panels preserve their file-backed content and current viewing state across tab switches, splits, zoom, and pane resizes.

## Persistence Contract

- Session snapshots preserve workspace title, custom title, custom color, pinned state, current directory, focused panel, split tree, divider positions, pane membership, selected panel per pane, panel metadata, status entries, log entries, progress, and git-branch state.
- Session snapshots preserve workspace ID so automation references and restore mapping remain stable.
- Terminal panel snapshots preserve working directory and eligible scrollback.
- Browser panel snapshots preserve URL, profile, page zoom, developer-tools visibility, render intent, and back and forward history.
- Markdown panel snapshots preserve file path.
- Session restore rebuilds the same pane tree, same divider ratios, same tab ordering, same selected tab per pane, same focused panel when available, and same panel metadata.
- Session restore skips automatic restore in the same cases as today, including explicit launch arguments and automated-test launches.

## Automation Contract

- The workspace exposes a layout snapshot containing container frame, pane frames, selected tab per pane, tab IDs per pane, focused pane ID, and timestamp.
- The workspace exposes a tree snapshot containing the recursive split tree, split orientations, divider ratios, pane frames, tab titles, tab IDs, and selected tab ID.
- Pane and tab IDs stay stable enough for the current automation and persistence layers to address them within a session.

## Rewrite Guardrails

- The replacement must preserve current user-visible behavior before it introduces any new behavior.
- The replacement may not rely on placeholder tabs as a steady-state concept.
- The replacement may not regress focus correctness, drag correctness, resize correctness, or session restore correctness.
- The replacement may choose any implementation strategy as long as every behavior above remains true.
