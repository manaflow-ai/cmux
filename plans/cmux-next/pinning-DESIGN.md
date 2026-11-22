# Pinning everywhere (2026-10-20)

Ask (Lawrence): "make sure pinning workspaces, pinning groups, pinning tabs, everything about pinning
that can be pinned, like pinning workspaces in groups, works, and is accessible from right click/cmd
shift p/mcp etc".

Builds on a219's pinned groups (`sidebar-ordering-DESIGN.md`, landed 8414192fcf8..304de7d49e4): a
pinned group is in the Pinned band, shows its pin, and its menu reads Unpin Group.

## Rules

1. **One action per pinnable object.** The right-click menu, Cmd-Shift-P, the `cmux` CLI and MCP run
   the same catalog action (`PinningSurfacesTests`). Its title reads Pin … or Unpin … for the target.
2. **Pinned first, in the person's order.** A pin goes last among the pins of its container. Pins
   keep their order until the person moves them.
3. **One pin (Leo, 2026-11-22: "well fucking do the pin properly").** The row's hover Pin, the
   menu, Cmd-Shift-P, the CLI, MCP and a drag into Pinned are the same pin: the item moves into the
   Pinned band, with the same state, persistence and undo. Pin puts it last among the pins; a drag
   puts it where it is dropped. A workspace or nested group inside a group pins the same way: it
   leaves its group for the band, and Unpin puts it back in that group. (Before, Pin kept a group
   member in its group, first, marked `extra.pinned`, while a drag put it in the band: two pins.
   Leo, 2026-11-22: "the drag to top pin is a different kind of pin or perhaps the right pin
   behaviour".)
4. **Older in-group pins still read.** A member an older app pinned inside its group
   (`extra.pinned`) reads pinned and lists first in its group; a move keeps it on that side. Pin
   moves it to the band; Unpin puts it right under the group's other pinned members; a drag out of
   its group clears the mark.
5. **Unpin goes to a sensible place.**
   - Anything in the Pinned band: back where it was pinned from (its section and, for a group
     member, its group), after the neighbor it sat after, while that group and neighbor are still
     there. Otherwise the top of its machine section (Chief's default, 2026-10-20: as Move to Top).
     The old rule was the end of the section.
   - A member of a pinned tree: it sits in Pinned, so it reads pinned; Unpin takes it out of the
     tree to the top of its machine section, as dragging it out of Pinned does.
6. **Nested groups (a283, remote groups slice 1).** A group pins and unpins with its whole tree,
   a nested one too (it leaves its parent for the band and goes back into it). Pin on a member of a
   pinned tree does nothing (it is pinned). Pinned keeps closed workspaces and the groups that hold
   them. When Unpin moves a tree back into its machine section, the daemon closes the workspaces
   that are not open, and the groups that this empties go, as when the last workspace closes there.
7. **Pins survive restart.** Sidebar pins are rows of the daemon's sidebar document (`extra.pinned`,
   `extra.unpin_to` on the item: section, group, the neighbor before it). Tab, screen and tab-group pins are daemon state. Home conversation
   pins are stored with the conversation's owner, or for this account on this Mac. Extension pins
   are Chromium profile state.
8. **Undo.** A user's pin is one undo step (Edit > Undo). The document's inverse is the item's old
   row, so undo restores the pin mark and the order together.

The reducer (`cmux-layout-reducer/src/sidebar_doc/reduce.rs`: `pin`, `unpin`, `place`) is the only
judge. The app's mirror runs the same reducer, so the row the app draws at once is the row the daemon
stores. Tests: `sidebar_doc::pin_tests` (Rust), `SidebarDocPinInGroupTests` (the client reads the mark).

### Not pinnable

- **Panes.** A pane has no pin. Dock Column (`column.dock*`) keeps a column on one side; it is the
  nearest equivalent.
- **Sidebar link, tab and app rows.** "Add to Top" (`workspace.toggleTop`) and the Pinned band hold
  them; they have no separate pin toggle.
- **Rooms and git checkpoints** pin only through the daemon's own MCP tools (`room_pin`,
  `git_checkpoint_pin`); they have no app surface and were not checked here.

## Matrix

Surfaces: right-click menu, Cmd-Shift-P, `cmux` CLI, MCP, a keyboard shortcut (bindable in Settings
and cmux.json; "default" names a preset key), drag. The state comes from the code, the catalog and the
tests. Nothing in this matrix was tried in the running app.

| Item | Right-click | Cmd-Shift-P | CLI | MCP | Shortcut | Drag | Before | After |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Workspace, top level (`palette.toggleWorkspacePin`) | works | works | `workspace pin-unpin` works | `app_workspace_pin_unpin` works | **missing** (not bindable) → bindable, no default | drop on Pinned works | Unpin sent it to the end of its section | Unpin puts it back where it was, else first |
| Workspace in a group (same action) | **broken**: Pin took it out of the group | **broken** | **broken** | **broken** | as above | in-group order not kept | pinned meant "leave the group" | stays in its group, first; Unpin keeps it in the group; menu reads Unpin |
| Workspace in a pinned group | **broken**: Pin took it out of the group, to the band's top level | **broken** | **broken** | **broken** | as above | n/a | pinning left the group | pins inside that group; reads Pin until then |
| Workspace group (`workspaceGroup.togglePin`) | works (a219) | **missing** before a219 → works (a219, 8414192fcf8) | `workspace-group toggle-pin` works | `app_workspace_group_toggle_pin` works | not bindable (unchanged) | drop on Pinned works | Unpin sent it to the end | back where it was, else first |
| Workspace group, daemon without the sidebar document | works (keeps the group) | works (a219) | works | works | not bindable | n/a | **broken**: did not list first | lists first in its section |
| Workspace in another session (the Chief's `cmux-chief-*` session, SSH, Cloud) | **broken**: the document pinned it, its daemon's `pinned` flag stayed false (a316) | **broken** | **broken** | **broken** | as above | **broken** | the TUI, iOS and `workspace list` did not show it pinned | its own daemon's flag follows each pin and unpin |
| Workspace the document does not place yet | Pin works (adopt then pin) | works | works | works | n/a | works | **broken**: Move to Top could not lift it when its machine had no section here | adopt makes the section, then it moves |
| Pane tab, terminal or agent (`palette.toggleTabPin`) | works | works | `tab pin-unpin` works | `app_tab_pin_unpin`, `tab_pin`, `tab_unpin` work | default Opt-Cmd-P | stays in the pinned run | works | unchanged |
| Browser tab (same action, plus `browser.resetPinnedTab`) | works, plus Back to Pinned Page | works | `tab pin-unpin`, `browser back-to-pinned-page` work | works | default Opt-Cmd-P | stays in the pinned run | works | unchanged |
| Tab group in a pane (`tabGroup.save` / `tabGroup.unsave`, Chrome's pin = save) | works (one of the two rows) | works | `tab-group save` / `unsave` work | `app_tab_group_save` / `unsave` work | not bindable (unchanged) | n/a | works | unchanged |
| Screen (`screen.togglePin`) | works | works | `screen toggle-pin` works | `app_screen_toggle_pin` works | not bindable (unchanged) | n/a | works | unchanged |
| Browser extension (`browser.extension.pin` / `unpin`, `move`) | Extensions menu pin works | works | `extension pin` / `unpin` / `move` work | `app_extension_pin` / `unpin` / `move` work | bindable, no default | reorder pinned works | works | unchanged |
| Home conversation: Chief, DM, group (`home.togglePin`, new) | Pin row works | **missing** → works | **missing** → `home pin-unpin [--conversation ID] [--pinned true\|false]` | **missing** → `app_home_pin_unpin` | **missing** → bindable, no default | drag into the grid works | right-click and drag only | one action; the row's Pin and a tile dragged out run it |

## Open after this change

- The TUI and iOS read the legacy `pinned` flag. The app now sets it on the workspace's own daemon with
  every pin (`WorkspacePinFlags`), so they show a pin made in the app; they do not know a pin inside a
  group from one in the Pinned band. A legacy pin of a grouped workspace now pins inside the group.
- Group, tab-group and screen pins cannot take a shortcut yet. They were left unchanged to keep this
  change small.
- Pin/Unpin Workspace reads the confirmed document. Between a click and the daemon's echo (one round
  trip), the menu title can still read the old state.
