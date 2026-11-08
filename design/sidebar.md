# Sidebar: workspace rows

The native sidebar's rows: `Packages/macOS/CmuxNext/Sources/CmuxNextSidebar` (`SidebarListView`,
`WorkspaceRowView`). Owner notes and the history of each rule are in
`plans/cmux-next/sidebar-owner.md`; this page says how a row looks and moves now.

## Workspace titles (Leo 2026-11-08)

> "i feel like when workspaces get renamed (esp by agents) it should have that same fade in
> animation that the tool call situation has..."

- **A rename swaps the words** as the agent chat's live line swaps a tool call: one shared text
  swap, `useTextSwap` on the web and `MotionGate.swapText` in the app, with one set of numbers
  from `schemas/motion-scale/motion-scale.json` (`textSwap`; generated as `MOTION_TEXT_SWAP` and
  `MotionScale.textSwap*`):
  - the old words rise `textSwapRise` (5 pt) and fade out, gone at `textSwapGoneAt` (50%) of
    `--cmux-motion-micro` / `MotionScale.micro` (120 ms);
  - the new words rise in from 5 pt below over `--cmux-motion-standard` / `MotionScale.standard`
    (180 ms), unseen until `textSwapShowFrom` (35%) of it, so no two names read over each other;
  - both on `--cmux-ease-out` / `MotionScale.easeOut`;
  - Reduce Motion: a short crossfade, nothing moves. Animations off: the name changes in one frame.
- **Only a real rename moves.** The same row, showing the same workspace, had its old name on
  screen, and the workspace's name changed (an agent's, another device's, a chat it inherits).
  First paint, a restore, a reload and a row scrolled into view show the name at once; so do a
  `sidebar.rowTitle` mode change and a new focused tab in a breadcrumb. Leo 2026-10-31: "WE DON'T
  NEED A FADE IN ANIMATION UNLESS IT'S THE WORST CASE".
- A placeholder's first name (the loading bar becoming a title) shows at once: nothing was read yet.
- **The width is fixed.** The trailing marks are laid out before the title, so the title's slot
  never depends on its text; a longer name fades out at the slot's end as before.
- **No other row moves**, and neither does the renamed row: the swap animates only the title's
  opacity and transform, never a frame.

## Gallery

`AATitleTextSwapGalleryTests` (`title-text-swap-gallery.tar`): film strips of a rename at 0, 30, 60,
90, 120 and 180 ms between two rows above and two below, dark and light: the shared swap (picked),
the same timings with no rise, and the old crossfade.
