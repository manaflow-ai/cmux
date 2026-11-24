# Sidebar section customization

## Prior art used for this slice

Leo's “BB and Herder” reference maps to [get-bb/bb](https://github.com/get-bb/bb)
and [Herdr](https://herdr.dev/). BB's public plugin model lets community code add
side-panel tabs, sidebar sections, footer content, settings, and renderers, with
live activation and rollback when a plugin fails. Its marketplace is an index of
pinned sources; it does not install code automatically. Herdr is an agent-aware
terminal multiplexer: its panes expose working, blocked, or idle state while the
session stays persistent and can be attached from another client. The workspace
research links [the Herdr/exe.dev field report](https://rares.blog/articles/stop-making-agents-commute-with-you)
and records the same pane-state model in `docs/live-migrate-terminal-processes.md`.

Those references led to this bounded native slice: users can shape the existing
sidebar document through settings, while the document remains the source of
placement truth and community widgets remain a later app-host primitive. A
settings reload is atomic and reversible, so a malformed customization falls
back to the native projection without affecting the session.

CMUX-383 adds a native projection layer for the sidebar document. The document
continues to own placement and persistence; `cmux-next.json` supplies bounded
user overrides that Rust validates before the Swift view applies them. The
projection is re-read on every settings watcher update, including an atomic
file replacement, so saving the file is the hot-reload action.

## Settings surface

The settings live under two keys:

```json
{
  "sidebar": {
    "sections": {
      "hidden": ["recents"],
      "order": ["projects", "pinned"]
    },
    "workspaces": {
      "workspace-id": {
        "hidden": false,
        "group": "group-id",
        "order": 20
      }
    }
  }
}
```

Section `hidden` accepts section ids or their stable keys. `order` ranks
sections within their existing `top`, `middle`, or `bottom` region; it never
crosses those fixed bands. Workspace entries can hide a row, assign it to a
same-section group by id or unambiguous display name, and rank it within its
current loose/group list. Unknown ids, malformed values, duplicate ids, and
oversized lists produce diagnostics and leave document placement intact.
The selected workspace always keeps its section and row visible.

`sidebar.sections.hidden` and `sidebar.sections.order` are settings rows, so
the Settings page (Sidebar, Sidebar Sections card), the command palette,
`cmux settings get|set`, the MCP `settings_set` tool and a look or customize
profile set them like any other key, for example
`"settings": {"sidebar.sections.hidden": ["recents"]}` in a profile. Each takes
at most 256 distinct ids of 1 to 128 characters; a profile with any other value
is refused. Both default to an empty list: nothing hidden, the default order.
`sidebar.workspaces` is not a row yet, so a profile cannot set it.

## Rows, sections, density, and scope

The native row content and density tokens remain the existing sidebar design.
Customization changes projection only: section visibility/order, workspace
visibility/order, and valid group membership. App sections, machine sections,
fixed bands, row icons, status lines, and density are not recreated by the
settings layer, so a reload cannot cause a layout jump or a second density
system.

The settings apply to the current profile's sidebar projection. The underlying
sidebar document remains shared and editable by its normal drag and section
operations. A later document update is projected through the current settings,
and a settings reload projects the latest unfiltered document so a previous
hide or move never becomes permanent state.

The gallery covers the default projection, hidden/reordered sections, and a
workspace moved and ranked within its section. The watcher test writes a
temporary `cmux-next.json` through an atomic replacement and observes the new
projection without a restart.

## A nav block of cmux actions: `sidebar.nav`

A look (or you) can put a column of plain rows at the very top of the sidebar, each running a cmux
action, as the Codex app's sidebar does with New chat, Search, Pull requests and Scheduled. Each entry
is an action id (`cmux action list` names them), optionally followed by a title and an SF Symbol:

```json
{
  "sidebar.nav": [
    "palette.newAgentChat | New chat | square.and.pencil",
    "search.chats | Search | magnifyingglass",
    "palette.openWorkspacePullRequests | Pull requests | arrow.triangle.pull",
    "automations.show | Scheduled | clock",
    "appStore.show | Plugins | puzzlepiece.extension"
  ]
}
```

The rows draw in the built-in look (an icon and a label, no fill at rest, the hover fill), above
Home, and follow `sidebar.sectionLook`. A row with no title or symbol takes the action's own. Rust
checks the list (`cmux-layout-reducer` `sidebar_nav.rs`): an unknown id, a debug-only or destructive
action, a duplicate, or more than 12 rows is dropped with a diagnostic, and the rest still draw. The
rows are never written to the sidebar document, so removing the key, or the look that set it, leaves
your sidebar as it was. Empty (the default) draws no block. Together with `sidebar.groupBy: recents`
(Projects and Recents headers) and Pinned, this gives a sidebar the shape of the Codex app's.

# Sidebar looks

`sidebar.look` draws the sidebar like another app's: `claude` (the Claude desktop app), `codex`
(the Codex app), `studio` (a coding studio: threads under a heading per project, status in words and icons),
`rex` (the Rex app: one flat list of sessions, the status first, then the name) or `cmux`, the default,
which is today's sidebar. Settings > Customize lists each look as one switch. The transcript (`agentPane.display.transcriptLook`)
and the composer (`agentPane.display.composerLook`) use the same names for `claude`, `codex` and
`studio`, so one word sets the whole window's look; `rex` is a sidebar look only.

```sh
cmux settings set sidebar.look claude
cmux settings reset sidebar.look      # back to cmux's own sidebar
```

Or in `~/.config/cmux/cmux-next.json`: `{ "sidebar": { "look": "studio" } }`. Saving the file is
the reload, as with every sidebar setting. A theme file may set `sidebar.look` too.

## A look is only public settings

Each look is a file of ordinary sidebar settings, shipped in `Resources/sidebar-looks/<look>.json`
and read by the app (`SidebarLookPreset`) and by the daemon and the CLI (cmux-config
`sidebar_look`). A look fills only the keys that cmux-next.json, the managed layers and the theme
file leave unset. Your own setting always wins, so you can take a look and change one thing:

```json
{ "sidebar": { "look": "codex", "showTimestamps": false } }
```

Or drop `sidebar.look` and copy a look's lines into your file to own every value. These are the
three looks written out, exactly as shipped:

**Claude**: sessions under a plain heading per project; a row is its title; a small dot for work.

```json
{
  "sidebar.groupBy": "folder",
  "sidebar.groupHeader.background": "sections",
  "sidebar.groupHeader.memberCount": false,
  "sidebar.groupHeader.unreadCount": false,
  "sidebar.sectionLook": "quiet",
  "sidebar.workspaceRow.icon": false,
  "sidebar.showColors": false,
  "sidebar.showTimestamps": false,
  "sidebar.detailedStatusIcons": false,
  "appearance.statusIndicator.style": "dot",
  "sidebar.showSpaces": false
}
```

**Codex**: threads under a plain heading per project folder; title and time on one line; a thin
ring for work.

```json
{
  "sidebar.groupBy": "folder",
  "sidebar.groupHeader.background": "sections",
  "sidebar.groupHeader.memberCount": false,
  "sidebar.groupHeader.unreadCount": false,
  "sidebar.sectionLook": "quiet",
  "sidebar.workspaceRow.icon": false,
  "sidebar.showColors": false,
  "sidebar.showTimestamps": true,
  "sidebar.detailedStatusIcons": false,
  "appearance.statusIndicator.style": "arc",
  "sidebar.showSpaces": false
}
```

**Studio**: threads under a plain heading per project; title and compact time; working, waiting,
error and done each have their own icon.

```json
{
  "sidebar.groupBy": "folder",
  "sidebar.groupHeader.background": "sections",
  "sidebar.groupHeader.memberCount": false,
  "sidebar.groupHeader.unreadCount": false,
  "sidebar.sectionLook": "quiet",
  "sidebar.workspaceRow.icon": false,
  "sidebar.showColors": false,
  "sidebar.showTimestamps": true,
  "sidebar.detailedStatusIcons": true,
  "appearance.statusIndicator.style": "arc",
  "sidebar.showSpaces": false
}
```

Colors are not part of a sidebar look: they belong to theme files. Pair a look with one, for
example `sidebar.look` `claude` with the shipped `claude-desktop` theme file
(`cmux settings set appearance.themeFile claude-desktop`). Past settings and theme files, the
`customize/main.js` row hook (`cmux.sidebar.rows/1`, below) adds icons, weight, an indicator or a
badge per row, and the hover card hook redraws the card. Every look here uses only those three
routes, so anything a shipped look does, you can do yourself without a build.

## No shift

A look never moves the pane or a row. It may set only the grid keys (cmux-config
`sidebar_look::GRID_KEYS`): grouping, headings, which marks a row draws and how status shows. It
never sets row height, sidebar width, the trailing column or motion (`sidebar.density`,
`sidebar.textSize`, `sidebar.style`, `appearance.metrics.*`, animation keys, or row elements that
add a line). Those stay on the shared grid, and they stay yours: a look keeps your density and
width.

Two detectors hold this:

- Rust (`cargo test -p cmux-config --lib sidebar_look`): every shipped look reads whole, sets only
  grid keys that are public settings, fills only unset keys, keeps the density, and `cmux` fills
  nothing.
- Swift (`AASidebarLookPresetGalleryTests`, CmuxNextAppTests): through the real sidebar list, for
  every look, a row changing state (working, busy, waiting, error, done, unread, idle) and a hot
  reload move no row's frame; switching looks keeps the list width and one workspace row height
  across every look; and switching away and back returns every row frame exactly. Its gallery
  (`CMUX_TEST_REQUIRE_GUI=1`) writes `sidebar-look-presets-gallery/`, one column per look, dark
  above light.

## How faithful, and what is not expressible yet

Each look was checked against captures of the real app's sidebar (dark mode; sizes in points).
The gallery (`AASidebarLookPresetGalleryTests.renderGallery`) draws every look at its reference's
width (`reference-width-<look>.png`) and writes `metrics.json` (width, row height and pitch, header
heights, title and detail type) so the two can be compared number by number.

| | Claude | Codex | Studio |
|---|---|---|---|
| Sidebar width | 288 (resizable) | about 300 (295 to 306) | 256 |
| Row pitch | 30 | 31 | 83: a three-line card, 78 tall |
| Title | 13 to 14, regular | 13, regular | 14, medium |
| Trailing text | none | time, 12 | time, 12 |
| Status | a 6 pt dot at the trailing edge | a thin ring of about 12 pt, leading | a word with an icon |
| List | by project | by project, or flat threads under Pinned | by project |
| Headings | plain, about 13, no count | plain, 12 to 13, no count | plain, no count |
| Selection | a fill, no ring | a fill, no ring, radius about 9 | a fill, radius about 8 |

What each look sets to match: Claude groups by project, hides the time, draws a dot; Codex groups by
project, shows the time and draws the thin ring (`arc`); Studio groups by project, shows the time and draws an
icon for each status. Rex lists every session flat (no folders, headings or counts), draws the
status first in the icon's place (it keeps that slot while idle, so the name never moves) and hides
the icon, color and time. Rex is not in the table: no capture of its sidebar has been measured yet,
so its gallery column draws at the default width.

Width and row pitch are not set by a look (No shift). To match a reference's numbers, set them
yourself: `appearance.metrics.sidebarWidth` (for example 256, 288 or 300) and `sidebar.density`.
Studio's three-line card is nearest to `sidebar.density` `expanded`.

What a look keeps of cmux's own, beyond the original:

- Live state on every row: working, waiting, error and done, as they happen.
- Status in words on hover cards, and unread counts.
- No shift: a row changing state, a reload or a look switch moves no row.

Not expressible as settings yet, so no look sets them:

- Claude's status dot at the row's trailing edge. cmux draws the status mark at the leading edge.
- Codex's pin and automation marks, and the archive button that replaces the time on hover.
- Studio's three-line card (project, title, branch) and its hover actions.

# Customizing the sidebar's hover card and rows

cmux-next lets you redraw a workspace row's hover card and decorate sidebar rows with a short
JavaScript file. It uses the same view language as the classic cmux JS sidebars (`VStack`,
`HStack`, `Text`, `Icon`, `Spacer`, `signal`, `computed`, `ForEach`), so a classic script ports with
small changes.

## Start

1. Copy the template folder [`sidebar-customization/`](sidebar-customization/) to
   `~/.config/cmux/customize/` (or `$XDG_CONFIG_HOME/cmux/customize/`; `CMUX_CUSTOMIZE_DIR`
   overrides both). It holds `cmux-app.json` and `main.js`.
2. That is all. cmux installs the folder's app (`local/customize`) by itself the first time it
   sees it, as any unverified app: sandboxed, with the read scopes its manifest asks for. More
   (for example network access) needs your grant in the App Store page.
3. Edit `main.js` and save. cmux reloads it at once: the next hover card and the rows use the new
   script. There is no command to run and no restart.

## How it runs

- The script runs in cmux's app host: a separate sandboxed process that the cmux daemon starts.
  It reads cmux data only through the scopes it holds (the template asks for `workspace:read`).
- Only this folder's app may redraw the hover card or decorate rows; another installed app
  cannot.
- A script that fails (a syntax error, an exception in a render) never takes cmux down. The
  built-in hover card stays and shows the error on its last line ("Custom card error: ...").
  Fix the file and save: the custom card comes back.
- The card's clock (`cmux.timer.every`) runs only while a card shows. Nothing runs while you do
  not hover.

## The hover card: `cmux.hovercard/1`

The manifest names the render function:

```json
"implements": { "cmux.hovercard/1": { "export": "renderCard" } }
```

`renderCard(ctx)` returns a view. `ctx.target` is the hovered row, `{kind: "workspace", id}`.
`ctx.card` is what the built-in card shows:

| Field | Meaning |
| --- | --- |
| `title` | The workspace's name |
| `status` | "Agent running", "Needs input", "Done" and so on; null while idle |
| `statusSinceMs` | When that status began (Unix ms): show how long it has held |
| `age` | How long ago the workspace was last active ("4w") |
| `facts` | `[{kind, text, sinceMs}]`, most useful first |

Fact kinds: `needsInput` (why it waits, in the program's words), `notification` (the unread
notification's text, which a row shows only with Latest Notification on), `unread` (how many items
are unread, when no notification text came), `agent` (agent and model),
`task` (the agent's prompt, or what a working program says it does), `lastReply`, `presence`
(what the agent edits or reads now), `command` (the running shell command; `sinceMs` is its
start), `folder`, `branch`, `pullRequest`, `machine`, `status` (a reported status entry), `more`.

### Reorder or hide fields

The template keeps a list. Change its order, or delete a name to hide that field:

```js
const FIELDS = ["task", "needsInput", "agent", "folder"]
```

### A different layout

```js
function renderCard(ctx) {
  const card = ctx.card
  const task = card.facts.find((f) => f.kind === "task")
  return VStack({ spacing: 4 }, [
    HStack([Text(card.title).bold(), Spacer(), Text(card.status ?? "idle").secondary()]),
    task ? Text(task.text).lineLimit(4) : Text("No task").secondary(),
  ])
}
```

### Glass

`.glass("chip")` (or `"chrome"`, `"popover"`, `"menu"`) puts the app's own glass under any piece of
the card, with no change to its layout: [glass.md](glass.md).

### Live data

`cmux.live(op, params)` reads cmux data and updates the view when it changes, for example
`cmux.live("agent.list", {})` (scope `agent:read`) or `cmux.live("workspace.get", {workspace})`.

## Row decorations: `cmux.sidebar.rows/1`

```json
"implements": { "cmux.sidebar.rows/1": { "export": "decorateRows" } }
```

`decorateRows()` returns a view whose `Group` nodes each decorate one row. A row is named by its
title (`title`) or its id (`row`). Props:

| Prop | Values |
| --- | --- |
| `icon` | An SF Symbol name (`"star.fill"`) or one emoji (`"🚀"`). A browser row keeps its favicon. |
| `weight` | `regular` (default), `medium`, `semibold`, `bold` |
| `indicator` | `default`, `none`, `arc`, `dot`, `braille`, `native`: the loading indicator's style. Waiting, error and done marks always show. |
| `badge` | Short text (40 characters at most), shown as the row's status line |

Rows without a decoration keep the defaults: no icon, regular weight.

```js
const RULES = [
  { match: /^api/i, icon: "🚀", weight: "semibold" },
  { match: /prod/i, icon: "exclamationmark.triangle", indicator: "dot" },
]
function decorateRows() {
  const workspaces = cmux.live("workspace.list", {})
  const rule = (name) => RULES.find((r) => r.match.test(name ?? "")) ?? {}
  return VStack([
    ForEach({ items: () => workspaces() ?? [], key: (w) => w.id }, (w) =>
      Group({ title: () => w().name, icon: () => rule(w().name).icon ?? null,
              weight: () => rule(w().name).weight ?? null }, []),
    ),
  ])
}
globalThis.__cmuxAppExports = { renderCard, decorateRows }
```

## Coming from classic cmux

| Classic | cmux-next |
| --- | --- |
| `~/.config/cmux/sidebars/<name>.js` replaces the whole sidebar | `~/.config/cmux/customize/main.js` redraws the hover card and decorates rows; the sidebar stays native |
| `sidebar(fn)` | `globalThis.__cmuxAppExports = { renderCard, decorateRows }` |
| `data.workspaces()` | `ctx.card` for the hovered row, `cmux.live("workspace.list", {})` for every row |
| `agents[i].sinceEpoch` (seconds) | `ctx.card.statusSinceMs` and `facts[i].sinceMs` (milliseconds) |
| `cmux(method, params)` | `cmux.<area>.<op>(params)` with the scopes the manifest names |
| Errors replace the sidebar | Errors show under the built-in card, which stays |
