# Sidebar ordering: one model (Lawrence, 2026-10-20)

Ask: "Move to Top … is still behind the groups. Or maybe it's because some groups are pinned, but
then I also need to have the concept of pinned groups. … right now I need to right-click and then
go do more group actions … bring them into this normal UI."

## Root cause

1. **The groups above the moved workspace were pinned groups.** On the sidebar document
   (`sidebar-doc-v1`, the live path), Pin Group moves the group into the Pinned band
   (`SidebarDocStore+Intents`, `.setGroupPinned`). The band lists above every machine section, so
   Move to Top (slot 0 of the machine section) correctly lands under it.
2. **Nothing showed that those groups were pinned, and they could not be unpinned.**
   `SidebarDocSections.model` mapped every document group with `pinned: false`. So the header drew
   no pin, and `workspaceGroup.togglePin` (`!group.pinned`) always sent Pin. A group that had been
   pinned once stayed in the band.
3. The older cause (Move to Top landing right above the first group when the client had no
   document item for the loose rows) was fixed in 4beb5aa624e. The running nightly (fc1d07a)
   has that fix.

## The model

The sidebar is a list of bands, top to bottom:

1. **Pinned**: pinned workspaces (tiles) and pinned groups, in the order the person put them.
2. **Each machine section**: loose workspaces and unpinned groups, freely interleaved. A loose
   workspace may sit above a group.

The rules:

- **Pinned first.** A pinned group or workspace is in the Pinned band. Pin moves it there (last in the band); Unpin
  moves it back to the end of its machine section (the reducer's `unpin`). "Pinned groups sort first" is a fact of where
  the group lives, not a sort key, so the optimistic and authoritative orders cannot disagree.
- **Move to Top** puts the object first in its own container. A loose workspace goes first in its
  machine section, above every unpinned group. A grouped workspace goes first in its group. A
  group goes first in its band. Move to Top never crosses the pinned boundary: that is what Pin does.
- A pinned group's header shows its pin glyph, and its menu reads **Unpin Group**.

Not changed: on daemons without the sidebar document (the personal-order fallback), `pinned`
still means "saved group, kept when its workspaces close" and does not change the order.

## The group header menu

A right-click on a group header opens the group's one flat menu at once, as Finder and Safari
do. It no longer opens the editor bubble. A click on the name or on ··· still opens the editor
(name, color, common rows). The editor has no "More Group Actions…" row.

Top-level rows (at most 12, the menu rule of 2026-10-01): New Workspace in Group · Rename…,
Color ▸, Pin/Unpin Group, Options ▸ (Set Icon, Remove Icon, read state, Collapse All, Expand All,
Collapse Others, Edit Group Config, Duplicate, Copy Group ID) · Collapse/Expand Group · Move to Top, Move ▸ (Up,
Down, Bottom, Window, New Window, Space, Section, Sort by Name/Last Used/Directory) · Ungroup,
Close Group, Delete Group, Close Other Groups.

Every row is also a Cmd-Shift-P command (`WorkspaceGroupFlatMenuTests`).
