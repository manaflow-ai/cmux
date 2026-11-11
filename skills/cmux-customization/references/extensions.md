# Extensions: change what cmux does, with no build

"Edit some functionality for myself" means the customize app
(`~/.config/cmux/customize`, id `local/customize`) plus the person's own actions
in `~/.config/cmux/cmux-next.json`. Both reload on save: no compile, no restart,
no install click. This page lists what an extension can call today, what is
still missing, and the copy-paste folders that work as written.

What people build, from a first widget to a pane of their own, and the gaps between
what they asked for and these primitives: [ideas.md](ideas.md).

An extension of its own (an id `local/NAME` beside the customize app, built from
TypeScript) starts with `cmux ext new NAME` and loads with `cmux ext dev`; an
agent runs `cmux ext dev --once --json` after each edit and reads its exit code
and errors ([docs/cmux-next/extensions/dev-loop.md](../../../docs/cmux-next/extensions/dev-loop.md)).

## Start from a template

Each folder in [`../templates/`](../templates/) is a complete customize app
(`cmux-app.json` and `main.js`). There is one customize app, so a template
replaces the folder; to keep an existing view, merge the new one into it
([adding a view](local-app-views.md#adding-a-view-to-an-existing-customize-app)).

```sh
test -d ~/.config/cmux/customize && cp -Rp ~/.config/cmux/customize ~/.config/cmux/customize.$(date +%Y%m%d-%H%M%S).bak
mkdir -p ~/.config/cmux/customize
cp templates/<name>/cmux-app.json templates/<name>/main.js ~/.config/cmux/customize/
```

| Template | What it shows | Scopes the person turns on |
|---|---|---|
| `starter` | One sidebar section: a `Panel`, a counter, a `Button` that toasts. The file to start "make me a ..." from. | none |
| `sidebar-section` | The focused workspace's name and its tabs, redrawn on every workspace or tab change; a click focuses the tab. | `workspace:write` (for the click; reading needs nothing) |
| `command-button` | Buttons that run the person's own `cmux-next.json` actions. | `actions:run` |
| `pane` | A checklist that opens as a tab, and a sidebar row that opens it. | `storage:local` (keep the list), `actions:run` (the row) |
| `clock-weather` | A widget: the time, the date and the weather for a city you type (Open-Meteo, no key). The clock ticks every 15 s, the weather every 15 min. | `net:geocoding-api.open-meteo.com` and `net:api.open-meteo.com` (the weather), `storage:local` (keep the city) |
| `my-prs` | Your open PRs and the reviews you owe, in the order you keep them (Move to top, up, down in a row's menu), read every minute and again when an agent chat changes. | `actions:run` (a click opens the PR), `storage:local` (keep the order), `net:api.github.com` (when GitHub is not connected) |
| `design-links` | Figma, FigJam, Linear, Notion and Docs links: paste one, its file name becomes the row, a click opens it in a cmux browser tab beside the code. | `storage:local` (keep the links), `actions:run` (open) |
| `threads` | Your agent chats as a thread list (`agent_chat.list`): cards with the folder, a status (Input, Failed, Done, Working with its duration) or the age, the title and what the chat does now; chats that need you first, running chats in a Working shelf and day-old chats in Earlier, both closed; a search field. Read again on `agent_chat.changed` (the app tells the daemon when a chat changes), not on a timer. | `workspace:write` (a click shows the chat's workspace), `actions:run` (a chat with no workspace opens in a tab) |

Read scopes (`workspace:read`, `integration:github:read`, ...) are granted at
install. Every other scope stays off until the person turns it on in
Settings > Apps > My views; an agent cannot. Each template still renders with
them off; `command-button` toasts which scope a click needs, `sidebar-section`
toasts that it cannot focus the tab, and the pane keeps its list only until the
app reloads or its last view closes when `storage:local` is off.

`skills/cmux-customization/templates` is validated as written:
`cmux-tui/crates/cmux-app-manifest/tests/customize_example.rs` checks each
folder is a valid package, and `cmux-tui/crates/cmux-app-host/js/test/kit.test.ts`
runs each `main.js` in the app runtime and clicks its buttons.

### The actions `command-button` runs

Add them to `actions` in `~/.config/cmux/cmux-next.json` (keep the rest of the
file). The key is the name the script uses after `cmuxConfig.`:

```json
{
  "actions": {
    "tests": { "type": "command", "command": "npm test", "title": "Run tests", "target": "newTabInCurrentPane" },
    "dev-server": { "type": "command", "command": "npm run dev", "title": "Start dev server", "target": "newTabInCurrentPane" },
    "git-status": { "type": "command", "command": "git status", "title": "Git status", "target": "currentTerminal" }
  }
}
```

Each one is also a Command Palette entry, can take a shortcut, and runs with
`cmux action run cmuxConfig.tests`. Only the customize app may run
`cmuxConfig.*` actions, and only from a click (a live gesture), never from a
timer or on load.

### Opening the pane

`cmux.pane/1` is the customize app's page. It opens as a tab with "Open My
views" in the Command Palette (no scope), `cmux action run app.open --app local/customize`, or
`cmux.actions.run("app.open", { app: "local/customize" })` from a click (needs
`actions:run`). One app has one pane kind.

## What an extension can call today

| Need | Primitive | Scope |
|---|---|---|
| A sidebar section | `implements["cmux.section/1"]`, region `top`, `middle` or `bottom`; `cmux apps place` | none |
| A Session Info section | `implements["cmux.session.info.section/1"]`; render gets `{ session_id, cwd, branch?, harness? }` | none |
| A New Tab widget | `implements["cmux.newtab.widget/1"]`, `options.size` `small` or `wide`; the person places it (Edit New Tab > Add Widgets); at most 64 nodes; mounted only when placed, from the page's open to its close, also while the page is hidden ([the clock recipe](../../../examples/extensions/clock/README.md)) | none |
| Decorate workspace rows | `implements["cmux.sidebar.rows/1"]` (customize app only) | none |
| A pane (a tab) | `implements["cmux.pane/1"]`, opened as above | none |
| Look like cmux | `Panel`, `Row`, `Button`, `Menu`, `Toggle`, `Slider`, `TextField`, `Badge`, `EmptyState`, `ProgressView`, `cmux.theme` tones, `cmux.toast` ([the kit](local-app-views.md#matching-the-app)) | none |
| Run my own command | `cmux.actions.run("cmuxConfig.<name>")` from a click | `actions:run` |
| Run a built-in action | `cmux.actions.run(id, args)` from a click; ids from `cmux.actions.list()`. Actions that sign in, quit, change the system or act on live input are refused | `actions:run` |
| Read the current workspace, pane, tab | `cmux.workspace.list()`, `cmux.pane.list({ workspace })`, `cmux.tab.list({ workspace })`; each row has `focused` | `workspace:read` |
| Follow changes | `cmux.events.on("workspace.changed" \| "pane.changed" \| "tab.changed" \| "terminal.changed", fn)`; `cmux.live(op)` re-reads on `<family>.changed` | the op's read scope |
| Show live data | `cmux.watch(name, params)` reads a signal source (`github.pulls`, `workspace.list`, `agent.list`; the list is `CmuxSignalMap` in `generated/cmux-app.d.ts`): one read per (name, params) for every section, re-read on push, polled behind the signal only when nothing pushes, the last value kept while it re-reads. Use it instead of `cmux.timer.every` polling. Recipe: `examples/extensions/pr-list` | the source's scopes |
| Focus, rename, split | `cmux.tab.focus`, `cmux.workspace.rename`, `cmux.pane.split`, ... | `workspace:write` |
| Run a shell command in a new terminal | `cmux.pane.run({ pane, argv })`, `cmux.workspace.run({ workspace, argv })` | `workspace:execute` |
| Type into a terminal | `cmux.terminal.input.write` | `terminal:execute` |
| Agents, git, GitHub, notes, the feed | `cmux.agent.list`, `cmux.git.*`, `cmux.integrations.github.request`, `cmux.notes.*`, `cmux.feed.*` | each family's read or write scope |
| Keep state, call a server | `cmux.storage.*`, `cmux.net.fetch`, `cmux.timer.*`, `cmux.clipboard` | `storage:local`, `net:<host>`, none, `clipboard:write` |
| Errors | `cmux raw command --request-json '{"cmd":"apps-logs","app":"local/customize"}'` | |

The whole op list with scopes is `cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts`
(`cmux script types` prints it).

## Chat widgets

An app can draw a card inside a Home chat (plans/cmux-next/chat-widgets-DESIGN.md).
It implements `cmux.chat.widget/1` with a render export; an agent sends a message
part naming the app:

```json
{"type": "widget", "app": "cmux/pr-card", "props": {"repo": "manaflow-ai/cmux", "number": 38629},
 "fallback": "PR #38629: Model picker finds any model", "url": "https://github.com/manaflow-ai/cmux/pull/38629"}
```

The Chief sends it with `send` `widget: {app, props, fallback, url?}`. The export gets
`ctx.props` and `ctx.widget.key` (`<message>#<part>`) and returns a view; cmux draws it
natively in the bubble (Text, Row, Button, a row of Buttons in an `HStack`, Badge,
Divider, EmptyState, Panel titles; at most 14 items). Page long lists yourself (a page
signal and Previous/Next), keep state that must outlive a relaunch in `cmux.storage`
under `ctx.widget.key`, and refresh with `cmux.timer.every`. Clients without the app
(the iPhone, a Mac without it) show `fallback`. Example: `samples/apps/pr-card`.

## Missing

- **A titlebar or toolbar button.** `cmux.status/1` (a titlebar, room bar,
  status strip or menu bar item) validates in a manifest, but the Mac app draws
  no status items yet, and the tab bar buttons (`ui.surfaceTabBar.buttons`) were
  removed. Put buttons in a sidebar section or the pane until then.
- **More than one section or pane.** One app implements each interface once; a
  second view goes inside the first one's render.
- **A pane with arguments.** The pane opens with no context (no file, no route),
  so it cannot be "this view for that workspace".
- **Web or TypeScript extensions without a build.** The customize app is a
  classic script drawing native scene nodes. A `web` pane, TypeScript or npm
  modules need `cmux app pack` and an app folder, and there is no Vite HMR for
  them.
- **The `text`, `workspaceCommand` and `workspace` action types** are still
  reported and skipped (see the SKILL), so an action cannot type text without
  Return or open a workspace layout.
- **Running a command on load or on a timer.** Every action needs a click.
