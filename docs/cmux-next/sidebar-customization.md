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
continues to own placement and persistence; \`cmux-next.json\` supplies bounded
user overrides that Rust validates before the Swift view applies them. The
projection is re-read on every settings watcher update, including an atomic
file replacement, so saving the file is the hot-reload action.

## Settings surface

The settings live under two keys:

\`\`\`json
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
\`\`\`

Section \`hidden\` accepts section ids or their stable keys. \`order\` ranks
sections within their existing \`top\`, \`middle\`, or \`bottom\` region; it never
crosses those fixed bands. Workspace entries can hide a row, assign it to a
same-section group by id or unambiguous display name, and rank it within its
current loose/group list. Unknown ids, malformed values, duplicate ids, and
oversized lists produce diagnostics and leave document placement intact.
The selected workspace always keeps its section and row visible.

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
temporary \`cmux-next.json\` through an atomic replacement and observes the new
projection without a restart.

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
