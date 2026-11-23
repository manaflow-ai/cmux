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
agent runs `cmux ext dev --once --json` after each edit and reads its exit code,
errors and `scene` (an outline of what rendered). Before saying it is done, it runs
`cmux ext shot --json` and looks at `shot.path`, a picture of the cmux window that
shows the extension ([docs/cmux-next/extensions/dev-loop.md](../../../docs/cmux-next/extensions/dev-loop.md)).
The same output's `design` list is the design check: fix every entry before calling a view done,
from the type roles, `SPACE` and components in [extension-design.md](extension-design.md).
To share one, `cmux ext share` prints the link; `cmux ext add LINK` (or `OWNER/NAME`, a git URL,
a folder) installs someone else's, and `cmux ext search` lists the ones tagged `cmux-extension`
on GitHub. To find what a person wants, search before building it.

To share it from a git repository, scaffold with `cmux ext new NAME --repo OWNER/REPO`
(or inside a clone of the person's empty GitHub repository, whose `origin` names it): the
id becomes `owner/NAME`, the manifest gets `repository`, and the README carries the
"Get it on cmux" badge and the install line `cmux apps install github.com/OWNER/REPO`.
`cmux ext dev` still loads it as `local/NAME`. `cmux ext publish --json` (no network
writes) checks it is ready to list (manifest, id, badge, repository, an icon or
screenshot; `--write-badge` adds the badge) and prints the steps: push, `cmux ext pack`
and a release tagged with the manifest's version carrying its two files, and a pull
request to manaflow-ai/cmux-extensions adding the entry it prints. Pushing, releasing and
the registry PR are the person's to do; ask before running them.

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
| `media-player` | A radio player: SomaFM's stations (no key) with the song on now, read every 30 s; a Now playing card with previous, play and next; favorites first, with a Favorites only switch. Play opens the stream in one cmux browser tab, whose speaker button mutes it and whose close stops it; previous and next move that tab instead of opening a second stream. | `net:somafm.com` (the stations), `actions:run` (play), `browser:read` (is the stream tab open), `browser:write` (switch stations in that tab), `storage:local` (your station and favorites) |
| `start-page` | A start page of your own, as a pane: a greeting and the time, New chat, Terminal and Browser buttons (the actions cmux's New Tab page runs), your workspaces (`cmux.watch("workspace.list")`) and your PRs (`cmux.watch("github.pulls")`), plus a Start row in the sidebar that opens it. Cmd-T still opens cmux's own New Tab page. | `workspace:read` and `integration:github:read` (granted at install), `actions:run` (the buttons, a PR, the sidebar row), `workspace:write` (show a workspace) |
| `newtab-cards`, `newtab-calm`, `newtab-threads`, `newtab-console` | Whole New Tab pages (`cmux.newtab/1`): the Cards, Default (Calm), Threads and Console layouts cmux no longer ships as templates, now yours to edit. Each has a field that starts a chat (`newTab.submit`) and your chats from `agent_chat.list`: three as cards; the chats that need you over a few recent ones with the field at the foot; every chat as a list; every chat as monospace lines after a `>` prompt. Copy one to `~/.config/cmux/customize`, then `cmux settings set tabs.newTabApp local/customize`. | `agent_chat:read`, `actions:run` (start or open a chat), `workspace:write` (show a chat's workspace) |
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
| Decorate workspace rows | `implements["cmux.sidebar.rows/1"]` (customize app only) | none |
| A pane (a tab) | `implements["cmux.pane/1"]`, opened as above | none |
| A whole New Tab page | `implements["cmux.newtab/1"]`; shows only once the person runs `cmux settings set tabs.newTabApp <app id>` (unset: cmux's own page; a missing, hidden or failing app: cmux's own page); render gets `{ surface: "newTab", cwd? }`. The web page only, not `tabs.nativeNewTabPage`. | none |
| cmux's own New Tab composer in your New Tab page | `Composer()` (cmux-extension-sdk) where the field goes: the field, its project and agent chips, attachments, slash commands and the start flow, as cmux's Minimal page draws them. `Composer({ prompt: true })` puts the Console's `>` before a monospace field; `Composer({ cwd })` moves the folder the next chat starts in (an environment row's tap sets a signal). One per page; it takes the keys typed after Cmd-T. Elsewhere it draws nothing. | none |
| Open a chat or reopen a closed item in the New Tab's own tab | `.opens({ chat: key })` (a `chat.list` key) or `.opens({ closed: id })` on a Row, Button or stack: cmux opens it as the person's click, the way its own page's cards and Recently Closed rows do. Where there is no such path the node's `onTap` runs. | none |
| An agent's own mark | `Icon("harness:claude")`, `Row({ symbol: "harness:codex" })`: the mark cmux's chat cards draw | none |
| A New Tab page's recent chats, waiting-on-you chats, All chats | `recentChats({ limit: 3 })`, `recentChats({ limit: 5, state: "input" })`, a page of All chats with `after` the last chat of the page before (cmux-extension-sdk; `agent_chat.list` / `chat.list` with `limit`, `state`, `before_ms` + `before_id` + `before_machine`). Newest first, read from cmux's ordered chat index: never list every chat and sort it in the app. Each row's `preview` is its last reply (a card's message). | `agent_chat:read` |
| Recently Closed | `cmux.closed.list({ limit: 5 })` (newest first) and `cmux.closed.reopen({ closed: item.id })` | `closed:read`, `closed:write` |
| A widget (New Tab grid, sidebar) | `implements["cmux.widget/1"]` with `options.sizes` (`small`, `medium`, `large`), `refresh.everySeconds` (at least 60) and `places` (`newtab`, `sidebar`; missing means both); the person adds it from Edit Widgets > Add Widget; render gets `{ surface: "widget", place, size, instance, settings, refresh, now() }`. Scaffold: `cmux ext new NAME --kind widget`; layout helpers `WidgetFrame`, `BigNumber`, `RowList`, type roles (`Headline`, `Body`, `Caption`, `TextIn(role, ...)`) and `SPACE` in cmux-extension-sdk; fix every `design` warning from `cmux ext shot --json` before calling it done ([extension-design.md](extension-design.md)) | none |
| Look like cmux | `Panel`, `Row`, `Button`, `Menu`, `Toggle`, `Slider`, `TextField`, `Badge`, `EmptyState`, `ProgressView`, `cmux.theme` tones, `cmux.toast` ([the kit](local-app-views.md#matching-the-app)) | none |
| Run my own command | `cmux.actions.run("cmuxConfig.<name>")` from a click | `actions:run` |
| Run a built-in action | `cmux.actions.run(id, args)` from a click; ids from `cmux.actions.list()`. Actions that sign in, quit, change the system or act on live input are refused | `actions:run` |
| Read the current workspace, pane, tab | `cmux.workspace.list()`, `cmux.pane.list({ workspace })`, `cmux.tab.list({ workspace })`; each row has `focused` | `workspace:read` |
| Follow changes | `cmux.events.on("workspace.changed" \| "pane.changed" \| "tab.changed" \| "terminal.changed", fn)`; `cmux.live(op)` re-reads on `<family>.changed` | the op's read scope |
| Show live data | `cmux.watch(name, params)` reads a signal source (`github.pulls`, `workspace.list`, `agent.list`, `http.json` for JSON at a URL: one cached request per URL for every extension, needs `net:<host>`; the list is `CmuxSignalMap` in `generated/cmux-app.d.ts`): one read per (name, params) for every section, re-read on push, polled behind the signal only when nothing pushes, the last value kept while it re-reads. Use it instead of `cmux.timer.every` polling. Recipe: `examples/extensions/pr-list` | the source's scopes |
| Focus, rename, split | `cmux.tab.focus`, `cmux.workspace.rename`, `cmux.pane.split`, ... | `workspace:write` |
| Run a shell command in a new terminal | `cmux.pane.run({ pane, argv })`, `cmux.workspace.run({ workspace, argv })` | `workspace:execute` |
| Type into a terminal | `cmux.terminal.input.write` | `terminal:execute` |
| Agents, git, GitHub, notes, the feed | `cmux.agent.list`, `cmux.git.*`, `cmux.integrations.github.request`, `cmux.notes.*`, `cmux.feed.*` | each family's read or write scope |
| Keep state, call a server | `cmux.storage.*`, `cmux.net.fetch`, `cmux.timer.*`, `cmux.clipboard` | `storage:local`, `net:<host>`, none, `clipboard:write` |
| Read a browser page (reader mode) | `cmux.page.read({ tab? })`: the page's url and title, its main text as blocks (heading, paragraph, list_item, quote, code, image) with title, byline and site, and its links. No `tab`: the focused browser tab | `page:read` (highlighted on the consent sheet) |
| Link hints on a browser page | `cmux.page.hints({ action: "show" \| "clear", tab? })` draws the built-in `f` labels and answers `{tab, hints: [{label, text, href}]}`; `cmux.page.follow({ label, new_split?, tab? })` clicks the hint's element, or opens its link in a new split (`F`). Both need a gesture (a key or a click) | `page:write` |
| Errors | `cmux raw command --request-json '{"cmd":"apps-logs","app":"local/customize"}'` | |

The whole op list with scopes is `cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts`
(`cmux script types` prints it).

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
