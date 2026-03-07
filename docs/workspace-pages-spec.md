# Workspace Pages Spec

Last updated: March 7, 2026  
Related issue: https://github.com/manaflow-ai/cmux/issues/569

## Problem

Today a workspace owns exactly one Bonsplit layout. That forces users to either:

1. Keep editor or database panes full-width in a separate workspace.
2. Keep everything in one workspace and accept squeezed layouts.

The requested hierarchy is:

1. `workspace`
2. `page`
3. `pane`
4. `surface`

A workspace stays "one project or repo". Pages let that project hold multiple full-layout views in the same workspace.

## Naming

Recommended public name: `page`

Canonical terms:

1. `workspace`: the vertical sidebar item for a project/task.
2. `page`: a titlebar-level layout inside a workspace.
3. `pane`: a split region inside a page.
4. `surface`: a tab inside a pane.

Why `page`:

1. `tab` is already overloaded in cmux for workspaces, Bonsplit tabs, and browser tabs.
2. `layout` sounds static, but this object is navigated, renamed, closed, and reordered.
3. `scene` is distinctive but reads too novel for a terminal app.
4. `page` is short, works in menus and shortcuts, and fits the titlebar text-strip UI.

Rejected names for now:

1. `workspace tab`
2. `top-level tab`
3. `scene`
4. `layout`

## Product Shape

Each workspace owns an ordered list of pages. Each page owns one full Bonsplit tree plus its page-local focus state.

The active page is shown in a horizontal titlebar strip. Switching pages swaps the active Bonsplit layout without changing the selected workspace.

The sidebar continues to represent workspaces only. V1 does not add a second sidebar layer.

## Implementation Status

Implemented on this branch:

1. `Workspace` now owns an ordered `pages` list plus an active page selection.
2. Page order, titles, active selection, and page-local layouts persist through session restore.
3. The fake titlebar now shows a horizontal page strip instead of the folder icon.
4. The page `+` is hover-only, pinned on the far right, and does not steal drag space while hidden.
5. Page close-button visibility follows the active/hover rules in the titlebar strip.
6. Page context menus support create, duplicate, rename, close, close others, move left, and move right.
7. Page switching detaches inactive Ghostty and WKWebView-backed panels from the live hierarchy instead of killing PTYs or browser state.
8. Holding the direct-select shortcut modifiers, `Command+Option` by default, reveals page shortcut badges in the titlebar strip, using the existing shortcut-hint pattern.
9. Customizable page shortcuts exist in `KeyboardShortcutSettings`, and the default bindings are wired through app-level shortcut handling.
10. `Cmd+Shift+P` exposes page create, duplicate, rename, close, close others, next/previous, move left/right, and direct page selection commands.
11. The app menu exposes page create, duplicate, rename, close, close others, move left/right, next/previous, and direct page selection actions.
12. The page strip supports drag-and-drop reordering with horizontal auto-scroll.
13. Socket v2 page APIs exist for list/current/create/duplicate/select/rename/close/reorder/next/previous/last.
14. CLI page commands exist for `list-pages`, `new-page`, `duplicate-page`, `current-page`, `select-page`, `rename-page`, `close-page`, `reorder-page`, `next-page`, `previous-page`, and `last-page`.
15. `system.identify` now includes focused page identity via `page_id`, `page_ref`, `page_index`, and `page_title`.
16. `system.tree` and `cmux tree` now render `workspace -> page -> pane -> surface`, while keeping the selected page mirrored into the legacy workspace-level `panes` field for older consumers.
17. Unit coverage now exists for page drag-drop planner behavior, page-strip autoscroll planning, page persistence round-trips, shortcut routing, duplicate-page structure preservation, active-page close-neighbor selection, runtime page detach/reattach identity across switches, and the v2 JSON page/tree path for `page.list`, `page.select`, `page.current`, and `system.tree`.
18. Dedicated UI automation now exists for the titlebar page strip create/select/close and shortcut-hint flow.
19. A `tests_v2` regression now exists for external CLI and socket page parity across create, select, reorder, current, last, and close flows.

Not implemented yet:

1. The deeper model refactor where each page owns its own `bonsplitController` and live panel map directly.
2. CI execution and stabilization for the new page UI automation and `tests_v2` external page API regressions still needs to be wired and kept green on this branch.

## Titlebar UX

Replace the current folder icon and single titlebar label area with a text-only page strip.

V1 strip rules:

1. Page items render as text only.
2. The active page is visually distinct and keeps its close button visible.
3. Inactive pages reveal their close button on hover.
4. When a workspace has only one page, the active page still reserves the close slot, but the close button is disabled so a workspace never reaches zero pages.
5. A page `+` control sits at the far right of the fake titlebar lane, outside the scrollable page list.
6. Right click on a page opens its context menu.
7. Empty titlebar space remains draggable.
8. Holding the direct-select shortcut modifiers, `Command+Option` by default, should reveal the shortcut labels for visible pages instead of adding permanent chrome.
9. The page `+` control is only visible while hovering the fake titlebar.

The current titlebar folder icon goes away in V1. `Open Folder` remains available through existing menu, command palette, and shortcut paths.

## Page UI Detail

The page strip should feel like part of the macOS titlebar, not like a second toolbar.

Visual direction:

1. Text-first, not boxed tabs.
2. No persistent pill backgrounds, segmented control borders, or folder/file chrome.
3. Typography should be close to the current titlebar label treatment, with the active page using stronger weight and opacity.
4. Hover can add a very light background wash, but the default state should read as text in the titlebar.

Titlebar layout:

1. Traffic lights stay where they are now.
2. The page strip replaces the current folder-icon-plus-title area.
3. Existing titlebar controls on the trailing side stay separate from the page strip.
4. The strip should consume available width before squeezing the trailing controls.
5. Any leftover titlebar gap outside page hit targets remains window-drag space.
6. The page list itself is a scrollable lane.
7. The page `+` control is pinned to the far right of the fake titlebar lane and is not part of the scrolling content.

Page item anatomy:

1. Page title text.
2. Reserved close-button slot on the trailing edge of the item.
3. Hover/active hit area large enough to be easy to target in the titlebar.

Page item state rules:

1. Active page:
   - stronger text weight
   - higher contrast
   - close button always visible
2. Inactive page:
   - lighter text treatment
   - close button hidden until hover
3. Hovered page:
   - subtle background wash is allowed
   - close button becomes visible
4. Pressed page:
   - same layout, just a stronger hover/pressed wash
5. Single remaining page:
   - keeps the close slot visible for layout stability
   - close button is disabled

Close-button behavior:

1. Use an `x` or close glyph sized for titlebar density, not a large filled control.
2. The close button must not shift page text when it appears.
3. Clicking the close button closes only that page.
4. Closing the active page selects the nearest surviving neighbor, preferring the page to the right.

Sizing and truncation:

1. Single-line titles only.
2. Tail truncation when a title is too long.
3. Each page item keeps a stable minimum clickable width even for short names.
4. The active page gets slightly higher layout priority before truncation.

Overflow behavior:

1. The strip stays single-row and never wraps.
2. When pages exceed available width, the strip becomes horizontally scrollable.
3. Selecting, creating, or moving to a page should auto-scroll it into view.
4. The pinned page `+` control stays visible on the far right while the page list scrolls underneath its own lane.
5. Leading and trailing fade hints are acceptable if needed, but V1 should avoid adding heavy chrome.

Interaction details:

1. Left click selects the page.
2. Right click opens the page context menu for the clicked page.
3. Right click should not require activating the page first.
4. Double click rename can wait until later; V1 can use menu, command palette, and shortcut-driven rename only.
5. The context menu and close button must not break titlebar drag behavior outside their hit regions.
6. The fake titlebar should still drag the window anywhere that is not an actual page hit target or the visible page `+` hit target.

Creation affordance:

1. The page `+` control is pinned to the far right of the fake titlebar lane.
2. It should visually match the text-first style instead of looking like a toolbar button.
3. It is hidden by default.
4. It fades in only while hovering the fake titlebar region.
5. When hidden, that area should behave like normal titlebar drag space rather than a dead zone.
6. Only the visible glyph and its small padded hit target become clickable.
7. It should stay easy to hit without competing with the existing `New Workspace` titlebar control.

Tooltips and hints:

1. Hovering a page should show the full page title when truncated.
2. Hovering the `+` affordance should show `New Page` plus its effective shortcut.
3. Holding the direct-select shortcut modifiers should show page-index shortcut hints in the strip, following the same “hold modifier to reveal hints” idea already used elsewhere in cmux.

## Page Behavior

Each page preserves its own:

1. Split topology.
2. Surface order inside each pane.
3. Focused pane.
4. Selected surface per pane.
5. Scrollback and restore state already tracked by the current workspace/session model.

Workspace-level state remains shared:

1. Sidebar row identity and ordering.
2. Workspace name and color.
3. Notification aggregation and unread state.
4. Workspace-level commands such as rename, move, and close workspace.

For single-value sidebar metadata in V1, use the active page as the source of truth. We can revisit cross-page aggregation later if this feels misleading.

## Efficiency And Lifecycle

Pages should not behave like multiple fully mounted workspaces stacked on top of each other.

Lifecycle policy:

1. Only the active page in the selected workspace keeps its Ghostty terminal views and WKWebViews mounted in the live window hierarchy.
2. When a page becomes inactive, its terminal portal views and browser portal views should be hidden or detached through the same kind of unmount path cmux already uses for workspace switches.
3. Switching pages must not kill PTYs, throw away scrollback, or reload browser state just because the page is inactive.
4. Re-activating a page should reattach its existing panels instead of reconstructing the whole layout from scratch.
5. Hidden pages should not keep participating in hit testing, layout, or display-driven redraw work.
6. Rapid workspace switching must also hide portal-hosted views for superseded retiring workspaces immediately, so deferred handoff cleanup cannot leave stale terminal or browser portals alive after churn.

Performance rule:

1. There should never be more than one visible page worth of portal-hosted Ghostty surfaces or WKWebViews for a workspace at once.
2. The selected page should remount fast enough that page switches feel like view changes, not restore flows.
3. If later measurement shows browser-heavy workspaces still consume too much memory, add a follow-on cold-parking policy for long-idle pages instead of forcing that complexity into the first implementation.

## Commands And Shortcuts

Required page actions:

1. `New Page`
2. `Rename Page`
3. `Close Page`
4. `Close Other Pages`
5. `Next Page`
6. `Previous Page`
7. `Select Page 1` through `Select Page 8`
8. `Select Last Page`
9. `Duplicate Page`
10. `Move Page Left`
11. `Move Page Right`

Default shortcuts:

1. `Command+Option+N`: new page.
2. `Command+Option+R`: rename page.
3. `Command+Option+W`: close page.
4. `Command+Option+1` through `Command+Option+8`: select page by index.
5. `Command+Option+9`: select the last page.
6. `Command+Option+]`: next page.
7. `Command+Option+[`: previous page.

All page shortcuts must be first-class `KeyboardShortcutSettings` actions so they appear in Settings and can be customized.

The same actions should also appear in the command palette and the app menu.

Implementation note:

Direct page selection should route by physical digit intent, not by text produced after Option modifies the character, so `Command+Option+digit` keeps working across keyboard layouts.

## Cmd+Shift+P Commands

`Cmd+Shift+P` should expose page actions as first-class commands, not as hidden side effects.

Required command-palette entries:

1. `New Page`
2. `Duplicate Page`
3. `Rename Page…`
4. `Close Page`
5. `Close Other Pages`
6. `Next Page`
7. `Previous Page`
8. `Move Page Left`
9. `Move Page Right`
10. `Select Page <title>`

Command-palette behavior:

1. `Rename Page…` should use the same inline rename flow style already used for rename-oriented palette actions.
2. Page commands should resolve against the active window, active workspace, and selected page unless the command explicitly targets another page.
3. Palette results should show current shortcut hints where they exist.
4. Dynamic `Select Page <title>` results should make it easy to jump directly to any page even when there are more than nine.

## Context Menu

Right-clicking a page should expose:

1. `New Page`
2. `Duplicate Page`
3. `Rename Page…`
4. `Move Left`
5. `Move Right`
6. `Close Page`
7. `Close Other Pages`

Current branch status:

1. Implemented.

## Drag And Drop Reordering

The page strip should support drag-and-drop reordering, not just menu-based movement.

Required behavior:

1. Dragging starts from the page item, not from its close button.
2. The reorder indicator should be a single insertion gap, similar to the sidebar workspace reordering model.
3. If the strip is horizontally scrolled, dragging near the left or right edge should auto-scroll it.
4. Dragging a page must never drag the window.
5. Reordering stays within the current workspace in V1.
6. Context-menu move actions remain as keyboard and accessibility fallback.

Current branch status:

1. Implemented.

## Page Naming

V1 default names:

1. `Page 1`
2. `Page 2`
3. `Page 3`

User rename is the primary naming path. Automatic labels based on the active process or focused surface can be added later if the default names feel too generic.

## Model Direction

The current `Workspace` object in `Sources/Workspace.swift` still mixes project-level identity with page-level layout state.

Long-term direction:

1. Keep `Workspace` as the sidebar/project container.
2. Add a `WorkspacePage` model under `Workspace`.
3. Move `bonsplitController` into `WorkspacePage`.
4. Move page-local `panels` into `WorkspacePage`.
5. Move page-local focus and selected-surface state into `WorkspacePage`.
6. Move page-local session snapshot data into `WorkspacePage`.
7. Keep workspace-level sidebar and metadata state on `Workspace`.

This is the cleanest long-term shape for `workspace -> page -> pane -> surface`.

Current branch status:

1. Only the first two steps are implemented.
2. The branch intentionally keeps the existing single `bonsplitController` on `Workspace` and swaps page state in and out around it.

## Persistence

Session restore should persist:

1. page order
2. selected page per workspace
3. each page's Bonsplit snapshot
4. page custom titles

Workspace restore should reopen the last selected page, then restore page-local focus within that page.

Current branch status:

1. Implemented.

## Socket And CLI APIs

Pages need first-class API support because cmux is scriptable and page state will sit between workspace and pane.

Implemented v2 API surface:

1. `page.list`
2. `page.current`
3. `page.create`
4. `page.duplicate`
5. `page.select`
6. `page.rename`
7. `page.close`
8. `page.reorder`
9. `page.next`
10. `page.previous`
11. `page.last`

Identity and targeting:

1. `system.identify` includes `page_id`, `page_ref`, `page_index`, and `page_title` inside the `focused` payload.
2. Short refs support `page:<n>`.
3. Commands that target panes or surfaces without an explicit page should resolve against the currently selected page in the targeted workspace.
4. Socket clients must pass `force=true` to `page.close` because the transport cannot show confirmation UI. The CLI `close-page` command supplies that automatically.

Implemented CLI surface:

1. `list-pages [--workspace <id|ref>]`
2. `current-page [--workspace <id|ref>]`
3. `new-page [--workspace <id|ref>] [--title <text>]`
4. `duplicate-page [--workspace <id|ref>] [--page <id|ref>] [--title <text>]`
5. `select-page --page <id|ref|index> [--workspace <id|ref>]`
6. `rename-page [--workspace <id|ref>] [--page <id|ref>] <title>`
7. `close-page [--page <id|ref>] [--workspace <id|ref>]`
8. `reorder-page --page <id|ref|index> (--index <n> | --before <id|ref|index> | --after <id|ref|index>) [--workspace <id|ref>]`
9. `next-page [--workspace <id|ref>]`
10. `previous-page [--workspace <id|ref>]`
11. `last-page [--workspace <id|ref>]`

## Non-Goals For V1

1. Page-level badges, git metadata, or notification chips in the titlebar strip.
2. Cross-workspace page moves.
3. Nested page groups.
4. Aggressively destroying inactive PTYs or browser sessions on every page switch.

## Acceptance Criteria

The first implementation should feel complete if all of this is true:

1. A workspace can hold multiple pages with independent pane/tab layouts.
2. The titlebar strip replaces the folder icon area and is usable with mouse only.
3. `Command+Option+1..9` works by default and is customizable in Settings.
4. Right click works on page items without breaking window dragging or terminal focus.
5. Active-page close button visibility matches the rules above.
6. Inactive pages unmount from the live UI so only the active page's terminal and browser views stay mounted.
7. Drag-and-drop page reordering works, including edge auto-scroll for overflowed strips.
8. `Cmd+Shift+P` exposes page commands and inline rename behavior.
9. Socket and CLI page APIs exist, including `system.identify` page context.
10. App relaunch restores page order, selection, and layout.
11. Existing workspace and pane navigation continue to behave as before.

Current branch status:

1. The V1 acceptance list is implemented.
2. Dedicated UI automation and the `tests_v2` page parity regression exist, but CI stabilization still needs follow-up alongside the deeper per-page controller refactor described above.

## Test Expectations

Once implementation starts, add coverage for:

1. titlebar hit testing, page item interaction, and empty-space drag behavior
2. page switching preserving per-page Bonsplit state
3. `Command+Option+1..9` routing, including `9 -> last`
4. custom shortcut overrides for page actions
5. `Cmd+Shift+P` page commands and rename flow
6. page context menu actions
7. inactive-page terminal and browser unmount behavior
8. page drag reordering, including overflow auto-scroll
9. session restore of page order and selected page
10. socket and CLI page commands, including `system.identify` page fields

Current branch status:

1. Unit coverage now exists for page persistence round-trips and page shortcut routing, including `Command+Option+9 -> last page`, `Command+Option+]`, `Command+Option+N`, and symbol-first layout fallback for page shortcuts.
2. Unit coverage also exists for duplicate-page structure preservation and active-page close-neighbor selection.
3. Dedicated UI automation and `tests_v2` parity coverage now exist for titlebar interaction and external page commands, but CI stabilization still needs follow-up.
