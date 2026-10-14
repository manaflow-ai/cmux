# Workspaces list and Mac filter: verification

Branch `feat-cnx-ios-wslist`, 2026-10-13. Evidence is git-ignored, in
`verify/evidence/2026-10-13/wslist/`.

User feedback: "redo the per MacBook workspaces list UX. the folder icon is
unnecessary, there should be a way to select a specific device to only see
that device's workspaces."

## What changed

### Choosing a Mac: the title menu

The navigation title is the filter: "All Macs ⌄" or the chosen Mac's name.
The subtitle says "3 of 5 Macs online", or the chosen Mac's "Online" /
"Last seen 2h ago". Tapping the title opens the menu:

- All Macs, with the workspace count
- Macs: each Mac with a filled dot (online) or a hollow one (offline) and a
  subtitle ("Online · 2 workspaces", "Last seen 3d ago"). Online Macs come
  first, as in the list.

Patterns considered:

| Pattern | Precedent | Verdict |
| --- | --- | --- |
| Title menu | Mail's mailbox title ("All Inboxes"), the Codex title menu (`chatgpt-07-codex-title-menu`), Notes and Files folder titles | **Chosen.** The title already names what the list shows, so naming the Mac there answers "whose workspaces are these?" at a glance. It is the system `toolbarTitleMenu`, so the chevron, glass menu, VoiceOver and Dynamic Type are native. It costs no vertical space and adds no toolbar button next to New Workspace and More |
| Toolbar filter `Menu` | ChatGPT Scheduled (`chatgpt-31-filter-menu`), Mail's filter button | Less discoverable for a scope that changes the whole list. A third trailing button crowds the capsule, and the current Mac stays hidden until the menu opens |
| Horizontal chip row | ChatGPT Library, Photos collections | Takes about 44 pt above the list on every scroll. It does not scale to a team of 8 to 10 minis (the Build Fleet mock), and chips cannot show presence and last seen without truncating |

The choice is remembered per team (`MacFilter`, key
`cnx.workspaces.macFilter.<team>`). It is an account preference, so it is
cleared on sign-out. A Mac that leaves the team reads as All Macs.

### Layout per filter

- **All Macs**: one section per Mac under a pinned header: dot, name,
  presence and workspace count, with Reconnect (live only) and the live link
  line as before. The header is opaque, so pinned headers no longer show rows
  through them. Online Macs come first. Show Offline Macs (More menu) still
  applies.
- **One Mac**: a flat list with no header. An offline Mac adds a line above
  the rows: "Offline. Workspaces open when <Mac> is back." In live mode, an
  online Mac shows the link line there, and Reconnect moves into the More
  menu.
- **Offline Macs' workspaces** are greyed, show "Unavailable while offline",
  and are not links (VoiceOver reads them as static text).

### Rows (no icon)

The 36 pt folder or glyph square is gone. Rows follow Mail and Messages:

1. An unread dot in a 16 pt leading gutter, the title (`body` semibold) and
   the relative time (`meta`).
2. The branch in mono after `arrow.triangle.branch`, or the directory after
   `folder` when there is no branch. Then the tab kinds as glyphs with
   counts: agent `sparkle`, terminal `apple.terminal`, browser `globe`.
3. Activity (`subheadline`):
   - "**Needs you** · Claude: Refactor transport layer", after a `warning` dot
   - "Codex is working · Fix pricing page", after an animated `ellipsis`
     (variable color; static with Reduce Motion)
   - otherwise the agent's or first tab's subtitle, unless it repeats line 2
   - "Creating…" with a spinner for an optimistic row

VoiceOver reads one sentence per row, for example "cmux, Unread,
feat-cnx-ios, 1 agent, 1 terminal, 1 browser tab, Needs you · Claude:
Refactor transport layer, 1m".

### Empty states per filter

| Filter | Shows |
| --- | --- |
| One online Mac, no workspaces | "No workspaces on <Mac>", "New workspaces open right away.", **New Workspace** (creates on that Mac and pushes), Show All Macs |
| One online Mac the backend cannot create on | The same title with "can't take new workspaces from this iPhone yet", no create button |
| One offline Mac, no workspaces | "<Mac> is offline", "Last seen 3d ago. Open cmux on it to see its workspaces.", Show All Macs |
| All Macs, an online Mac with none | An inline row: "No workspaces", **+ New Workspace** (that Mac). It stacks at accessibility sizes |
| All Macs, nothing anywhere | "No workspaces yet" with New Workspace on the target Mac |
| All Macs, all offline, offline hidden | Unchanged ("Your Macs are asleep") |
| No Macs | Unchanged (Connect your Mac) |

### New Workspace follows the filter

- With one Mac chosen, a tap creates on that Mac. A hold opens the menu
  headed "On <Mac>", without the Mac picker; the title menu is where the
  Mac changes.
- With an offline Mac chosen, the button is disabled rather than silently
  creating on another Mac.
- Under All Macs it behaves as before: the preferred Mac, with the picker.

### Other files

- `Screens.swift`: the Workspaces stack no longer adds the principal
  "Workspaces" title; `WorkspacesList` owns the title.
- `MockData.swift`: Manaflow gains "MacBook Air" (online, no workspaces) and
  "Office mini" (offline 3 days, no workspaces), for the empty states.
- `Discovery.swift`: the filter key is an account preference.

## How it was verified

- **Unit tests** (Swift Testing, `swift test --filter
  'CnxWorkspacesTests|CnxModelTests|CnxLiveTests'` on macOS; `nx-remote`
  could not resolve `cmux-lawrence-2`): 14, 35 and 40 passed, before and
  after merging `origin/feat-cnx-ios`. New in `MacFilterTests.swift`:
  - `MacFilter`: All Macs by default, the Mac remembered per team across a
    relaunch, a departed or foreign Mac reads as All Macs, the key is cleared
    on sign-out
  - `WorkspaceListLayout`: online-first grouping with per-Mac sorting,
    Show Offline Macs, one Mac flat and shown even when offline Macs are
    hidden, an empty Mac, a missing Mac
  - the title, and the New Workspace target (the filtered Mac wins; an
    offline filtered Mac gives none)
  - `TabKindSummary` order, counts and spoken form; `WorkspaceActivity`
- **Simulators**: `cnx-wsl-ios26` (iOS 26.5) and `cnx-wsl-ios27`
  (iOS 27.0), iPhone 17 Pro, headless (Simulator.app never opened),
  `CNX_MOCK_AUTH=1`, Debug build from `verify/build.sh`.
- **Real touches**: `verify/record-wslist.sh <udid> <dir> [dark|light]
  [content-size]` drives HID taps and an edge drag with `axe` while
  `simctl io recordVideo` records. The steps:
  1. All Macs, then open the title menu
  2. Pick Aziz's Mac Studio, MacBook Pro (offline with a workspace), Office
     mini (offline, empty), then MacBook Air (online, empty)
  3. Tap the empty state's New Workspace; an edge swipe goes back
  4. Relaunch; the menu goes back to All Macs

  It saved a screenshot per step and 2 fps frames.

| Check | iOS 26 | iOS 27 | Evidence |
| --- | --- | --- | --- |
| All Macs grouped, pinned opaque headers, no icons | Yes | Yes | `*-dark/01-all.png`, `large/*scrolled.png` |
| Title menu: dots, subtitles, Macs section, checkmark | Yes | Yes | `*/02-menu.png` |
| One Mac: flat list, title and presence subtitle | Yes | Yes | `*/03-studio.png` |
| Offline Mac: greyed rows, note, New Workspace disabled | Yes | Yes | `*/04-offline-with-workspaces.png` |
| Offline empty and online empty states | Yes | Yes | `*/05-*.png`, `*/06-*.png` |
| Empty-state New Workspace creates on MacBook Air and pushes; back shows the row under MacBook Air | Yes | Yes | `*/07-*.png`, `*/08-*.png`, `walk.mp4`, `frames/` |
| Filter survives a relaunch | Yes | Yes | `*/09-relaunched.png` |
| Hold on New Workspace: "On <filtered Mac>", no Mac picker | Yes (MacBook Air) | Yes (cmux mini 2) | `hold/sheet.png` |
| Light mode | Yes | Yes | `*-light/`, `light.png` |
| Large Dynamic Type (`accessibility-large`): rows wrap cleanly, headers truncate the name, the inline empty row stacks | Yes | Yes | `large/sheet.png` |
| After merging `origin/feat-cnx-ios` | Yes | Yes | `ios27-dark-merged/sheet.png` |

Reference comparison:

- The title menu matches the Codex title menu (`chatgpt-07`): a chevron
  title, a glass menu dropping from the title, and a leading checkmark.
- The rows match Mail's density: a bold first line with a trailing time, a
  secondary line, a one-line preview, an unread dot in the gutter, and a
  disclosure chevron.

Review fixes found during the runs:

- Menu rows dropped their subtitle, colored dot and section with `Picker` +
  `Label`, so the menu uses `Toggle` with plain `Text`s.
- "0 workspaces" now reads "No workspaces".
- Pinned headers were transparent.
- The inline New Workspace wrapped at accessibility sizes.
- A new terminal workspace repeated "~" on line 3.

## Known gaps

- Menu icons render monochrome, so online and offline read from filled and
  hollow dots plus the subtitle, not the green color. iOS menus ignore the
  tint.
- Live mode: the menu lists the team's Macs from presence, but creating on a
  Mac other than the linked one still needs the link to switch (as in
  `verify/workspace-create.md`). The New Workspace button is disabled for
  such a Mac rather than retargeted.
- iOS 26 centers or leads a long title depending on the trailing capsule
  width ("Aziz's Mac Studio" sits leading). This is system behavior.
