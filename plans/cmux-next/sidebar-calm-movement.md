# Sidebar: calm movement

Lawrence, 2026-10-20 (voice note on a screen capture of the sidebar):
"I think my sidebar is moving too much and it shows me the animation when
it moves. It distracts me." "fix animation".

## What moved

In the capture (cmux NIGHTLY, one-line rows, about 60 workspaces in four
groups) the "Agents & routing" and "Browser & parity" groups were missing for
a moment, then came back: the whole "cmux-next app" block slid about 370 pt
down over the returning rows, and the rows below opened and closed on the
spring. Nobody in the window asked for any of it.

Causes, in the code on feat-cmux-next before this change:

1. Every structural change of the model reloaded the list with motion
   (`SidebarView.render`, `list.reload(animated: true)`): a reorder, a new
   or closed workspace, a group an agent filled or emptied, a change from the
   CLI, MCP or another client. Rows slid, opened and closed, and the selected
   block passed over the others.
2. A row whose new content changed its height (a status line, progress, a
   badge row) reloaded the list with motion too (`SidebarListView.patchRows`),
   so every row below it slid.
3. Both ran while the pointer was over the rows and while the user scrolled:
   rows moved under the pointer.
4. A group header in such a reload configured with motion (its count and
   chips changed on a spring).

Not this change: spinners out of step (a263), the talk icon (a271), the
timestamps (a194). The groups that vanished for a moment are a separate
question (a daemon or layout update that briefly left them out); with this
change their return no longer moves, but why they left is not proven.

## Rule

- A change this app's user asked for (a click, a drag, a row menu, the
  palette, a menu item, a shortcut) still moves on the spring, through the
  shared `Motion` gate (Reduce Motion and the global animation switch apply).
  `SidebarModel.noteUserIntent()` marks it; a change that arrives within
  `SidebarModel.userIntentWindow` (2 s, a daemon round trip under load) is
  the user's. In-app action runs mark it (`ActionRegistry.willRunObservers`,
  origin `user` only: never CLI, MCP, scripts, pages or other clients), and
  so does any animated reload from the list's own gestures.
- Any other change takes its place in one step: no slide, no open, no close.
- While the pointer is over the visible rows (cmux active) such a change waits
  (`SidebarListView.showModelChange`), and shows, still in one step, when the
  pointer leaves the list or with the next reload of any kind. A selection
  change never waits.
- The viewport stays anchored as before (`applyKeepingViewport`): rows added
  or removed above the view do not move the rows on screen.

Tests: `SidebarBackgroundChangeCalmTests`.
