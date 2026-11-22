# Reference sidebar

A wide, calm chat sidebar after a desktop coding agent app, as one applyable unit. It maps the
reference app's sidebar: 340 pt wide, 36 pt rows with 10 pt corners, 14 pt text, a status mark at the
left (a spinner while a chat works, a dot when it has something unread), the age at the right,
a Pinned section, chats by project or in one list, a sort, and archiving.

Screenshots come from CI and the NIGHTLY build (see `screenshots/README.md`).

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/codex/sidebar@feat-cmux-next
cmux setup remove manaflow-ai/codex-sidebar
```

## What it maps

| Reference behavior | Where here |
| --- | --- |
| Width 340 pt, 36 pt rows, 14 pt text | `appearance.metrics.sidebarWidth`, `sidebarRowHeight`, `chromeFontSize` in `cmux-setup.json` |
| One line per chat, age at the right, spinner or unread dot | `sidebar.showTimestamps`, `sidebar.detailedStatusIcons: false`, `appearance.statusIndicator.style: "arc"`; the Chats section draws it itself |
| Row radius 10, inset 6, 10 inside | The Chats section in `customize/main.js` draws its rows at those numbers |
| New chat row, search | First row of the Chats section (starts a chat; search opens the chat search) |
| Pinned section | Chats section: Pin chat and Unpin chat in a row's menu, through the host's `chat.pin`, so the pin is the chat's own |
| Organize: By project, In one list | The section's Organize menu (the choice is kept in this app's storage) |
| Sort chats by: Created, Last updated | The same menu |
| Show more, Show less after 10 chats | Chats section |
| Archive | A row's menu: Archive chat, through the host's `chat.archive`, with a toast |
| A failed or lost chat | A warning mark in the status slot; the hover text shows the error |
| Settling finished chats | `sidebar.settleFinished: true` (cmux's own Settled fold) |
| Thread hover card | `cmux.hovercard/1`: title and age, then machine, folder, branch lines |

Archive needs a build with the chat archive operation (`chat.archive`, with `archived` rows from
`chat.list`), as [Session Recents](../../claude-code/session-recents) does. On a build without it,
Archive shows a warning toast and nothing is hidden. Pin works on today's builds.

## Gaps

| Reference behavior | What is missing |
| --- | --- |
| Sidebar min 240 and max 520, never wider than the window minus 240 | Settings for the width limits (`appearance.metrics.sidebarWidthMin` and `Max`, commented as Pending) |
| Row radius 10, inset 6, cell padding 10 on the native rows | `appearance.metrics.sidebarRowCornerRadius`, `sidebarRowInset`, `sidebarRowPadding` (commented as Pending) |
| The status mark swapping to an Archive button under the pointer | No hover-conditional node in the scene ABI (only `hoverBackground`), and no per-row hover action setting; archive lives in the row menu |
| Sort for the native list | No `sidebar.sortBy`; only the Chats section sorts |
| Archive view in this unit | Archived chats are hidden here; the `threads/` unit has the Archive view and Unarchive |
| Ctrl or shift click to select, bulk archive, drag to reorder, custom sections | No selection or drag-reorder in `cmux.section` rows |
| Inline Confirm on archive | No confirm node; archive is immediate with a toast |

The section reads the live `chat.list` signal, so a pin or archive from anywhere shows up at once.
Pinning and archiving need the `chat:write` scope; if the host refuses, a warning toast says why.

The native chat rows stay on screen next to the Chats section; hide them with the sidebar's own
options if you want only the section. Installing this unit and `threads/` together: one customize
app has one sidebar section, so the later install replaces the earlier. To have both, copy the
`renderThreads` view into this app's `main.js` as a second group (see
docs/cmux-next/customize-recipes.md, "Adding a view").
