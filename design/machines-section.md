# Machines section: the right sidebar's machine list

The right sidebar's Machines section (the cloud icon in its bar): this Mac, the Cloud, SSH and
server machines the app connects to, and the person's machines joined through the hub. It is a
React page, `cmux-page://cmux.machines/` (`webviews/src/pages/machines/`), hosted in the section's slot by
`PageSectionHost` (CmuxNextPages, the generic sidebar page host) and served by
`MachineSectionPageProvider` (CmuxNextServer); `MachineSectionHostView` (CmuxNextApp) wires its actions.
The floating cards it opens (Add Device, Check Machine, Revoke's question) are their own surfaces.

Leo: "we ought to have a lot of that ui in react and not swift".

## References

- `claude/live/panel-environment`: plain rows with a small icon for the machine, no card chrome.
- `cursor/web/run-on-machine-picker`: This Mac first, then the remote machines as a plain list.

## Layout

- One icon column (16 px) at the section's inset (12 px), so every icon, name and header starts on
  the same lines; 8 px from the icon to the text. Rows are at least one control row (28 px).
- Group order: this Mac (no header), then Cloud, SSH, Servers and Joined under caption headers
  (16 px above a header, 4 px under it). A kind with no machine has no header.
- Inside a group, ready machines first, then connecting or resuming, then paused, then the rest
  (Leo, 2026-10-31: "ready machines first, then paused, then offline"), each rank in the
  registry's order.
- A name is shown whole: a name too long for its column wraps (at a hyphen where it can) and its
  row grows; the rows below move down with it in the same frame. A joined machine's name, over its
  caption, cuts at the end instead.
- Add Machine… ends the list, 12 px under the last group; only its icon and text take the click.
- Inks: names in primary (a machine that is not connected in secondary), headers, states, icons
  and actions in secondary, disabled glyphs in tertiary; a failed Revoke or Rotate caption in danger.

## Row states

| State | Start | End |
| --- | --- | --- |
| Connecting | a spinner at the trailing edge, no word (compact) | Connected: the spinner goes, the name takes primary ink |
| Link down | `Offline`, `Paused`, `Failed` or `Deleted` at the trailing edge | Connected: the word goes |
| Pointer, keyboard focus, or its menu open | New Workspace (and a joined machine's …) at opacity 0 | at opacity 1, the button's own hover fill only; back to 0 when all three end |
| Revoke or Rotate running | the … button | a spinner in its place until the list read after it lands |
| Remove (joined machine) | the remove button (revealed with the others) | a question inside the section: Cancel (Escape) or Remove (Return, danger ink). Remove takes the row out in the same frame, the rows below close up in that frame; the host revokes it if it still can join and records it in cmux-tui's devices state, so every machine list leaves it out. A refusal brings the row back with "Could not remove it" |
| Last check | nothing | a check (success) or a dot (warning, danger) after the name; its tooltip names the step |

The trailing controls keep their slot at opacity 0, so revealing them moves nothing.

## Variants (gallery `pages.machines`) and the pick

The three layouts of the `machines.section.style` tunable (Debug Settings > Server):

1. `compact`: grouped, one line per machine; the state shows only when the link is down.
2. `grouped`: the same groups, each machine's state on a second line.
3. `flat`: one list, state under the name (the layout before the groups).

Shipped: `compact`, which is already the default. It shows the most machines in a narrow sidebar,
and a connected machine needs no word: the state appears exactly when there is something to read.
`grouped` doubles each row's height for the same information, and `flat` loses the kind headers
that tell a Cloud machine from an SSH one. The gallery also shows joined rows (busy, failed, menu
open), the Remove question and a refused Remove, a long name, this Mac alone and 300 machines.

## Host and cost

- The page is made the first time the section shows (the right sidebar makes a section's view
  then) and fills the section; it scrolls inside it, so the section's frame never changes size
  with its content.
- While the section is hidden the provider sends the page no change; the newest snapshot arrives,
  once, when it shows again. The joined rows' 90 s aging deadline runs only while the section is
  on screen (#36852, #36870).
- Rows past the viewport skip layout and paint (`content-visibility: auto`), so a frame costs the
  visible rows whatever the number of machines.
- Menus (a row's New Workspace on This Machine, a joined machine's Check, Rotate Credential and
  Revoke…) are the action registry's native menus, shown at the click by the host.
