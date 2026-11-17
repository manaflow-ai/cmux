# Spaces overhaul (2026-10-27)

Ask: Lawrence "build it" (Chief message 14223, a talk with Austin): pinned workspaces per space,
incognito spaces, a new window is a new space, open a space in a new window, a Home per space, two
windows on one space, and every space action on every surface. Follow-ups: space keys that clash
with nothing (macOS or cmux), and "every spaces feature and shortcut must have a Cmd+Shift+P entry,
a CLI command and an MCP action, with no exceptions".

Builds on data-model.md 3 (membership: follows and pins) and 4 (windows), pinning-DESIGN.md and
sidebar-owner.md. The reorder-to-first bug belongs to another agent and is not touched here.

## Rules

1. **A pinned workspace shows only in its own space.** The pinned band (and every band section) is
   one document per home session, shared by all spaces. A window draws a band workspace item only
   when the window's current space shows that workspace (`RoomMembership.contains`), the same rule
   the workspace list uses. No new stored state: the space is derived from membership, so Move
   Workspace to Space moves its pin with it. A closed workspace (no live session answers its ref)
   cannot be placed in a space and draws as before (dimmed, every space).
   Consequence: a click on a pinned row selects a workspace of the current space, so it can never
   switch the window's space (Austin's bug: a pin from space B, drawn in space A, switched to B).
   Cmd-1…9 and Ctrl-Cmd-[ / ] walk the same filtered band.
2. **Incognito spaces** (`space.newIncognito`, New Incognito Space: palette, Window menu, the
   sidebar's New menu, CLI `space new-incognito`, MCP). A new space named Incognito with the
   eyeglasses icon, on the default browser profile, shown in a new incognito window (the
   off-the-record browser profile, no history or cookies kept, never restored, the incognito
   badge). Its workspace is pinned to the space. The space is deleted when its window is gone, at
   quit, and at the next launch after a crash (the incognito ledger lists the spaces). Another
   window switching to it shows the incognito window instead; the incognito window never switches
   to a normal space, so incognito and normal content never mix. Not yet: Home history in an
   incognito space (the Home chat is shared, rule 5).
3. **New Window is a new space** (Cmd-Shift-N, `newWindow`, also palette, CLI `app new-window`,
   MCP). The window opens on a new space with the next free color and its own first workspace (the
   same path as New Space, `RoomHandlers.create`). Default picked: a new space every time; the old
   behavior (a window on the current space) stays as "New Window in Space…" (`space.newWindow`).
4. **Open Space in New Window** (`space.openInNewWindow`): the space's right-click menu, palette,
   CLI `space open-in-new-window`, MCP. The new window shows the space; the original keeps it. A
   drag of a space dot out of the switcher and released outside every window runs the same action;
   a drop inside the switcher still reorders (the drag only turns into "open" once the pointer
   leaves the window). The new window lists the space's workspaces as rule 6 says: the ones no window
   owns become its own, the ones the original window owns show in both. Default picked: the drop must be outside the window (as a browser tab
   tears off), so a drop inside the window never opens one by accident.
5. **A Home per space.** The Home chat (Chief and DMs) is one, shared by every space. What a person
   builds around it (a split, a browser opened with Cmd-D in Home) belongs to the space's Home only:
   the Home workspace's panes beyond the chat dock are stored per space (the daemon's Home
   workspace keeps the chat tab; each space gets a `kind: home-space` companion workspace pinned to
   that space, which Home's content area shows beside the shared chat). Not built yet (Open).
6. **Two windows on one space.**
   - Terminals and the Home chat: the same daemon objects, so both windows draw the same state.
   - Browsers: a page has one live renderer. Default picked: only the focused window hosts the
     live page; the other window shows its last snapshot with a "Show here" button that moves the
     live page to that window. Two live copies would double memory and run page scripts twice.
   - Chat and diff views: decided, they may show twice. Both are read-only projections of one
     model (the transcript and the diff), so two views cost only their view memory and let a person
     read the top and bottom of a diff at once. Scroll position is per view.
   - Built 2026-11-15 (Lawrence: "if i switch to that space from original window, and view a
     terminal, that terminal must be shared"). A window is a view of a space. Each workspace keeps
     one owner window (it saves and restores it); every other open normal window on the same space
     lists it as a guest (`WindowRegistry.Window.guests`, set only by
     `WindowManager.shareSpaces` in each membership transition and each space a window enters). A
     window that goes to a space another window shows gets that space's workspaces, never a new
     workspace beside them.
   - A terminal in a guest window is a view of its own (own Ghostty surface, own attach,
     `TabContentCache.guestTerminal`): to the daemon it is one more participant, so the grid follows
     the daemon's size rule (the smaller view by default; the larger shows the "sized for another
     window" chip).
   - A tab with one view (browser, agent chat, page, conversation) stays in the window that showed
     it first. The other window shows "This tab is shown in another window" with Show Here
     (`TabShownElsewhereView`), which takes the view. No snapshot yet.
   - The default space is a space like every other: two windows on it list each other's workspaces, also for a
     person who made no space. Before, each such window listed only its own.
   - Not restored yet: a window that owns no workspace (it shows only guests) has no record, so a relaunch does not
     bring it back; a window that owns some comes back on the space of what it owns.
   - The owner's window closes: the first open window that lists the workspace as a guest owns it
     from then on (`WindowRegistry.close`), and the closed window's group keeps only what no window
     shows. An incognito window never shares (rule 2).
7. **Every space action on every surface.** Each `space.*` action, the space keys, Pin/Unpin
   Workspace, Move to Space, Hide / Show Spaces and New Window have a Cmd-Shift-P entry, a `cmux space …`
   CLI verb and an MCP tool. No exemption is allowed for them; `SpaceSurfacesTests` checks all
   three over every catalog action whose id starts with `space.` plus the named cross-domain ones.
   The color shortcuts (Space Color: Red, …) get their own verbs too.

## Keys

macOS uses Ctrl-arrows and Ctrl-digits for Mission Control. The asked keys clash inside cmux:

| Asked | Clash | Picked (nearest free) |
| --- | --- | --- |
| Ctrl-Cmd-Left / Right: previous / next space | Ghostty's pane resize `resize_split` (reserved, schemas/keybindings/ghostty-reserved-keys.json; changing it needs Lawrence's OK) | **Ctrl-Opt-Cmd-Left / Right** |
| Ctrl-Cmd-1…9: space N | Focus Pane by Number (`focusPaneByNumber`) | **Ctrl-Opt-Cmd-1…9** |

Nov 7 follow-up (Lawrence: "do ctrl option cmd hl for navigating spaces"): **Ctrl-Opt-Cmd-H / L** are now the
Previous / Next Space catalog keys; Ctrl-Opt-Cmd-Left / Right stay as aliases. No shipped cmux, Ghostty or
macOS default holds that chord.

Nov 15 (Lawrence: "sidebar needs keyboard shortcuts for making new spaces", and a space switch key that "doesn't
conflict with tmux"): **Ctrl-Opt-Cmd-N** is New Space's catalog key, in the same family. Every step and create key
holds Cmd, and a terminal never sends Cmd to its program, so tmux (prefix Ctrl-B), vim, emacs (C-M-digit) and
readline keep every key they have; no chord prefix is needed. No cmux, Ghostty, macOS or Chrome default holds
Ctrl-Opt-Cmd-N. New Incognito Space stays unbound: Ctrl-Opt-Shift-Cmd is the Hyper key that launchers bind
system-wide. Window managers (Rectangle, Magnet) bind Ctrl-Opt-Cmd-Left / Right system-wide for next display;
there the arrows never reach cmux, and H / L still work.

The old space keys keep working: Opt-Cmd-[ / ] stay as aliases of previous / next, and Ctrl-Opt-1…9
stays the digit scheme's space key (ShortcutDigitScheme, onboarding's Number Keys card). Each key
follows its action: rebinding or unbinding the action in Settings or `cmux.json`
(`shortcuts.bindings["space.next"]`) drops the default and its aliases. `KeyBindingCollisionTests`
checks the shipped table: no two default entries with the same keys and the same `when` run
different actions. `SpaceKeysTests` checks that the space keys win in a terminal, a page and an
agent chat, that the asked keys keep their pane meaning, and that no space key is Ctrl alone.

## The space menu

A space dot's right-click menu opens as the workspace group menu does (Leo 2026-11-11: "this colour selection for
spaces is wack"): the space's name in an editable field, then its colors as one row of swatches drawn in the colors
themselves, No Color first and the current one ringed (`MenuIdentityHeader`). Set Space Theme and Reset Space Theme
are rows of their own; no color pick opens into a theme list. A dot in the switcher draws its space's color exactly
as its swatch does, at full strength; the current space has its chip. Gallery: `AASpaceColorMenuGalleryTests`.

## Plan for the unbuilt rules

- **A Home per space (rule 5).** Needs the daemon: `ensure_home {profile}` returns a Home workspace
  per space (`kind: home`, pinned to the space); the chat dock column (`HomeDock`) holds the one
  shared Chief conversation tab in each, keyed so the store never duplicates a conversation.
  Splits and browsers made in Home land in that space's Home workspace. A daemon without the field
  keeps one Home for every space.
- **Two windows on one space (rule 6).** Built, less the browser snapshot: the window without the
  live page shows a notice and Show Here, not the page's last frame. Next: delete the owner window
  from the model (a workspace belongs to its space only, and a window record saves its space),
  which removes `guests` and the hand-over at close.

## Slices

1. This note.
2. Pinned per space (rule 1): failing test, then the window's band filter.
3. Keys and surfaces (rule 7, Keys): failing tests, then the catalog and exemption changes.
4. New Window is a new space; Open Space in New Window (menu, palette, CLI, MCP) (rules 3, 4).
5. Drag a space out of the switcher (rule 4).
6. Incognito spaces, a Home per space, two windows on one space (rules 2, 5, 6): need daemon
   fields and a second view of a workspace; later slices (plan above).

## Open

- Rule 5 is designed here and not built. Rule 6 is built (live check:
  `scripts/cmux-next/shared-space-windows-e2e.py`), less the browser snapshot.
- The drag-out gesture needs a running-app check on a GUI host.
