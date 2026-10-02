# Palette scopes and palette extensions

Status: proposal 1, lane 11 lead (scoped palette and palette extensions), 2026-10-02. Spec proposal: palette-scopes (decisions PA2, PA3). Binding inputs: OWNERSHIP-PRINCIPLES.md, architecture.md section 5a, actions.md, app-platform.md, skills/cmux-next-feature, cmux-next-spec `spec/app-platform.md`, `spec/operation-catalog.md`, `spec/identity-and-permissions.md`, decisions PA1 to PA3, D40 to D52, N13, and the coordinator's app `server` block (first-party-apps.md section 10). Only the coordinator writes the spec; this file is the lane 11 proposal.

## 1. Summary for agents

- One abstraction, the **scope**: a typed, searchable list in the palette (tabs, workspaces, browser history, commands, files, apps, feed items, settings, an item's actions, an app's notes). Every palette page becomes a scope. Search Tabs (PA1) is the first ported scope.
- The scope is always visible as a **chip** at the start of the search field (icon and title). Backspace on an empty query removes the chip and returns to the parent scope with its query and selection as they were. Cmd-Shift-A, then Backspace, shows the full palette.
- Enter a scope four ways: its shortcut or menu item (Cmd-Shift-A), a one-character **prefix** typed into an empty query (`@` tabs), its **keyword** plus Tab (`tabs` Tab), or its row in the **scope list** (empty root query, and `?`). Tab on a result row **drills** into that item's scope (its actions, a workspace's tabs).
- Scopes nest up to 8 levels. A pure reducer (`PaletteNavReducer`) owns the stack, the query per level, the selection memory and the result generations; property tests prove its invariants (section 4).
- Every scope is a catalog entry: an action opens it (shortcut, menu, palette, `cmux palette open <scope>`), and a read op queries it without UI (`cmux palette query <scope> <text> --json`, MCP `palette_query`). Agents get every scope, including app scopes.
- Apps contribute scopes, commands and views in `contributes.paletteScopes` and `contributes.commands` (section 6). Items carry typed catalog actions, never closures. Snapshot scopes are ranked by the host with no app code per keystroke; query scopes stream batches. The host paints from the last snapshot in the first frame, so a scope opens in under 16 ms even when the app VM is cold or offline.

## 2. Terms

| Term | Meaning |
| --- | --- |
| scope | a descriptor (`PaletteScopeDescriptor`) plus a source of items; a catalog entry |
| root scope | the full palette: commands, then workspaces, tabs, directories, settings and federated scope results once the user types |
| level | one entry on the palette's stack: a scope with its own query, rows, selection and generation |
| chip | the visible token for the top level at the start of the search field; a breadcrumb of the levels below it |
| entry | how a level was entered: `root`, `opened` (shortcut, menu, CLI), `prefix`, `keyword`, `row` (scope list row), `drill` (Tab on an item) |
| source | where items come from: `snapshot` (whole candidate set once, host ranks), `query` (per query, streamed), `op` (a catalog read op, zero app code) |
| federation | a scope's top matches also appear in root search under the scope's section title |

Name note: the app platform already uses "scope" for permissions (`workspace:read`). Code and docs say **palette scope**; the manifest key is `contributes.paletteScopes`. DECISION D-PS1 below.

## 3. The scope protocol

### 3.1 Descriptor (pure data, the catalog entry)

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | `PaletteScopeID` | stable public id: `tabs`, `workspaces`, `history`, `commands`; app scopes `app:<appId>#<scope>`; drill scopes `actions` |
| `title` | localized string | chip text ("Tabs") and scope row title |
| `symbol` | SF Symbol | chip icon and scope row icon |
| `placeholder` | localized string | field placeholder ("Search tabs…") |
| `prefix` | one punctuation character or nil | `@`; unique among the scopes that can be entered from the same parent; letters, digits and spaces are refused so typing a word never enters a scope |
| `keywords` | localized strings | `tabs`, `tab`: an exact keyword plus Tab enters the scope |
| `parents` | `root`, `anywhere`, or a set of scope ids | where the prefix, keyword and scope row work |
| `openAction` | `ActionID` or nil | the catalog action that opens it (`tab.search`, Cmd-Shift-A) |
| `layout` | `list`, `listWithDetail`, `grid(columns)` | how rows render |
| `ranking` | `fuzzy` (palette ranker plus frecency), `recency`, `source` | `source` keeps the source order (server relevance) |
| `emptyQuery` | `all`, `recent(n)`, `hint` | what an empty query shows |
| `emptyQuerySelection` | row index, clamped | 1 makes Return switch back (Search Tabs) |
| `federates` | bool | top results join root search |
| `owner` | `client` or `app:<id>` | who supplies items; app scopes are checked against the app's grants |

### 3.2 Source (behavior)

```swift
public protocol PaletteScopeSource: AnyObject {
    /// Items for the first frame: the last snapshot (cache) or nil.
    var cachedSnapshot: [PaletteItem]? { get }
    /// Streams batches for `query` until final. A new query cancels the
    /// previous stream (generation). Snapshot sources ignore `query` and
    /// yield the whole candidate set once, then again on change.
    func batches(query: String, context: PaletteScopeContext) -> AsyncStream<PaletteScopeBatch>
    /// Detail for the highlighted row (listWithDetail), loaded lazily.
    func detail(for itemID: String) async -> PaletteDetail?
}
```

`PaletteScopeBatch {items, replace: Bool, isFinal: Bool}`. The model tags each batch with the level and generation and sends it to the reducer as `.results`; a batch of an older generation is dropped there.

### 3.3 Items, actions and detail

Items stay `PaletteItem` with three additions: `drill: PaletteScopeID?` (Tab enters that scope with this item as context; the default drill is `actions`), `enters: PaletteScopeID?` (a scope row: Return or Tab enters the scope), and `actionRefs: [ActionRef]` (typed catalog actions with arguments: `ActionRef(id: "tab.close", args: ["tab": "tab_…"])`). The palette renders an `ActionRef`'s title, symbol, shortcut and destructive style from the catalog. Return runs the first, Cmd-Return the second, Cmd-K lists all; each keeps its own shortcut. Built-in items may still carry closures while they migrate; app items carry only `ActionRef`s.

The `actions` scope is the drill target for any item: its rows are the item's commands, so "drill into an item's actions" is the same mechanism as every other scope (chip "Actions · Tab title", Backspace returns to the row). Cmd-K keeps the floating Actions menu (prototype switch `palette.itemActions` = `menu | scope`).

Detail: `PaletteDetail {markdown subset, metadata rows (label, value, symbol), actions}`. It renders natively at the right of the list in `listWithDetail` and loads only for the highlighted row.

### 3.4 Empty state

`PaletteEmptyState {title, message, symbol, action: ActionRef?}`, per scope and per reason (`noResults`, `notConnected`, `needsSetup`, `offline`). Example: an app scope that needs a GitHub connection shows "Connect GitHub" with the integration connect action.

### 3.5 Built-in scopes

| id | Title | Prefix | Keywords | Open action (shortcut) | Source | Wave |
| --- | --- | --- | --- | --- | --- | --- |
| `commands` | Commands | `>` | commands, actions | `palette.commands` | catalog | 1 |
| `tabs` | Tabs | `@` | tabs, tab | `tab.search` (Cmd-Shift-A); "Go to Tab…" opens it (PA1) | Search Tabs (lane 2) | 1 |
| `workspaces` | Workspaces | `#` | workspaces | `goToWorkspace` | mirror | 1 |
| `settings` | Settings | `,` | settings | `palette.toggleSetting` | config layer | 1 |
| `shortcuts` | Keyboard Shortcuts | none | shortcuts, keys | `palette.searchShortcuts` | registry | 1 |
| `scopes` | Scopes | `?` | none | none | the scope graph | 1 |
| `actions` | Actions | none (drill only) | none | Tab on a row | the row's commands | 1 |
| `history` | Browser History | `;` | history | history page action | CmuxNextHistory | 2 |
| `files` | Files | `/` | files | `palette.files` | daemon file index (roots the user opened) | 3 |
| `feed` | Feed | `!` | feed, inbox | `feed.search` | feed owner (N10) | 3 |
| `apps` | Apps | none | apps | `appStore.show` | installed apps and their commands | 2 |
| `app:<id>#<scope>` | from the manifest | none by default (user may assign) | from the manifest | generated `app:<id>#scope.<scope>` | the app | 3 |

Single-character prefixes are scarce; only built-in scopes get one by default. Users assign or change any prefix and keyword in `cmux.json` (`palette.scopes."<id>".prefix`, `.keywords`, `.hidden`, `.federates`) and in Settings > Palette. A collision is refused at load with a notice; the user's assignment wins over a default.

## 4. State machine

### 4.1 State

`PaletteNavState {isOpen, levels: [PaletteNavLevel], nextLevelID}`. `PaletteNavLevel {id, scope, entry, query, generation, rows: [PaletteNavRow], rowsGeneration, isLoading, selection, pendingReset, pendingSubmit}`. `PaletteNavRow {id, enters, drills, isEnabled}` is only what navigation needs; titles stay in the model.

This is client view state (OWNERSHIP-PRINCIPLES: the client owns the view). It never leaves the client and needs no op or idempotency key. Selection memory lives per level and dies with the palette; per-scope frecency stays in `FrecencyStore`.

### 4.2 Events and effects

Events: `open(scope?, query)`, `close`, `setQuery(text)`, `backspaceOnEmpty`, `tab`, `shiftTab`, `escape`, `popTo(index)`, `activate(rowID?)` (Return or click), `push(page, row, query)`, `move(delta)`, `select(rowID)`, `results(levelID, generation, rows, replace, isFinal, emptyQuerySelection?)`, `refresh` (the owner reported a change).

Effects: `load(levelID, scope, query, generation, context)`, `cancel(levelID)`, `run(levelID, rowID)`, `openActions(rowID)`, `dismiss`, `announce(entered | left)`, `refused(reason)`.

### 4.3 Rules

1. **Open.** `open(nil)` makes `[root]`. `open(scope)` makes `[root, scope(entry: opened)]`, so Backspace on its empty query shows the root (Cmd-Shift-A, Backspace, full palette). Any page id opens this way (an argument picker from a shortcut); `palette.open` checks ids from outside against the graph. A command that pushes its own page (rename, picker) sends `push(page, row, query)` (entry `command`). Each new level emits `load`.
2. **Typing.** `setQuery` changes only the top level: new generation, `pendingReset`, `load`. Exception, **prefix entry**: when the top query was empty and the new text starts with a prefix that the graph allows from the top scope, push that scope with the rest of the text as its query; the parent's query stays empty.
3. **Backspace on an empty query** pops one level (cancel the child, refresh the parent, announce). At the root it does nothing and is consumed (no beep). Backspace with text is plain editing.
4. **Tab.** In order: the top query equals a child keyword → push that scope with an empty query and clear the parent query; the selected row has `enters` → push it; the selected row has `drills` → push it with the row as context (the parent keeps query and selection); otherwise `openActions` (today's Tab). Shift-Tab pops one level whatever the query.
5. **Escape** pops a level the user pushed inside this palette session (prefix, keyword, row, drill); at an `opened` level or the root it clears the query, then closes. Cmd-Shift-A then Esc closes, which is what a user who summoned Search Tabs expects; Backspace is the way to the root. Exception, **text steps**: a text-input level (a rename, an argument) holds an answer, not a search, so Escape there closes without clearing first; a step that opens on initial text (a rename's current name) selects it, and Return on that untouched text runs nothing (#16906).
6. **Return** on a scope row enters the scope; on any other row it runs the primary command. While the top level waits for its current generation, Return is held (`pendingSubmit`) and runs on the first batch, so it never runs a stale row.
7. **Results.** A batch is accepted only for the level's current generation. The first batch of a generation replaces the rows; later batches append (deduplicated by id). After a query change the selection goes to the default row (the first, or for an empty query the scope's `emptyQuerySelection` index, clamped). Otherwise the selection is kept by id, else the row at the same index, else the default.
8. **Pop restores.** The parent shows its query and cached rows at once, refreshes (data may have changed in the child), and keeps its selection by id.
9. **Breadcrumb click** (`popTo(i)`) pops every level above `i`.
10. **Depth** is at most 8; a push beyond it is refused with a notice.

### 4.4 Invariants (property-tested, `PaletteNavPropertyTests`)

- I1 Open means levels is not empty, level 0 is the root scope with entry `root`, and no other level has entry `root`; closed means no levels.
- I2 Depth is at most `maxDepth`; level ids are unique and increase.
- I3 A selection is nil or the id of a row of its level; a level whose rows are current and not empty has a selection.
- I4 `rowsGeneration <= generation` on every level.
- I5 Every level above the root is reachable: entry `opened` only at index 1; `prefix` and `keyword` scopes are allowed children of the level below; `row` and `drill` scopes exist in the graph (a scope row is an explicit link, so the scope list can enter any scope).
- I6 Every `load` effect names a live level and its current generation.
- P1 Round trip: from any open state with an empty top query, typing a child's prefix and then Backspace gives the same visible state (scopes, queries, selections) as before.
- P2 Drill round trip: Tab into a row's drill scope and Backspace restores the parent query and selection.
- P3 A batch of an older generation changes nothing and emits nothing.
- P4 From any state, at most depth + 2 Escapes close the palette; Backspace on empty never closes it.
- P5 Close, then open, gives the same state as a fresh open.
- P6 An edit changes only the top level.

The reducer is a pure value function with no AppKit, clock or I/O, so a TLA+ model adds nothing here; the seeded property tests run 500 random sequences of 60 events over a graph of 8 scopes with nesting and drill cycles.

### 4.5 Keyboard, focus and accessibility

| Key | Effect |
| --- | --- |
| type a prefix into an empty query | enter that scope |
| Tab | keyword entry, scope row, drill, else Actions menu |
| Shift-Tab | leave the scope (pop) |
| Backspace (empty query) | leave the scope |
| Esc | pop a pushed level, else clear, else close (a text step closes without clearing) |
| Return / Cmd-Return | enter a scope row / run primary / run alternate |
| Cmd-K | Actions menu (Cmd-K on an action edits its shortcut) |
| Up/Down, Page Up/Down, Cmd-Up/Down | move (selection memory per level) |
| Cmd-1 … Cmd-9 (prototype) | jump to the scope row with that number in the scope list |

- The search field keeps first responder for the palette's whole life; chips are not in the key loop (Tab is a palette command). A click on a chip pops to it; a click on the top chip's close mark pops one level.
- Automation never moves focus: `palette.open` from CLI or MCP needs `focus: true` and user consent like `tab.search` today; `palette.query` is read-only and never shows UI.
- Accessibility: the field's label is the scope ("Search Tabs"); each chip is a button ("Tabs scope, press Delete to leave"); entering and leaving post an announcement ("Tabs", "Commands"); rows keep their labels; the scope list rows name their prefix and keyword ("Tabs, prefix at sign, keyword tabs").
- Reduce Motion: the chip appears and leaves with a crossfade only; otherwise a short slide from the prefix's caret position (`Motion` tokens). No color carries meaning alone: the chip has an icon and a title, grays only (no blue).

## 5. Surfaces

| Action / op | Palette | CLI | Right-click | MCP | Notes |
| --- | --- | --- | --- | --- | --- |
| `palette.open {scope?, query?}` | via the scope rows | `cmux palette open [<scope>] [--query <q>]` | exempt `noObject` | exempt `guiOnly` (takes the keyboard; needs `focus: true`) | generic opener; each scope's `openAction` is an alias with its own shortcut |
| `palette.scopes` (read) | the `?` scope | `cmux palette scopes [--json]` | — | `palette_scopes` | every scope with id, title, prefix, keywords, owner, open action |
| `palette.query {scope, query, limit?, context?}` (read) | — | `cmux palette query <scope> [<query>] [--limit N] [--json]` | — | `palette_query` | headless results for any scope, ranked like the UI; app scopes need the app's `mcp:expose` and the caller's grant |
| `palette.run {scope, item, action?, args?}` | — | `cmux palette run <scope> <item> [--action <id>]` | — | follows the action's own MCP decision | runs a typed `ActionRef` of a result row; the same as `action.run` with the ref's args |
| `tab.search` | Search Tabs… | `cmux tab search` | — | `tab_search` | lane 2; becomes `openAction` of scope `tabs` |

CLI requests: `.cmux-scratch/nx-worker/cli-requests/palette-scopes.md` (Swift CLI freeze). The app side adds `palette.scopes`, `palette.query` and `palette.open` to the control socket (read-only methods answer off-main from `ControlSnapshot`, architecture.md 5a).

## 6. Palette extensions (apps)

Goal (PA3): apps contribute palette scopes, commands and views through the manifest, with a model better than the leading launcher-extension ecosystem (studied privately). Fits the app platform spec (D40 to D52) and the coordinator's `server` block.

### 6.1 Requirements and how the model meets them

| Requirement | How |
| --- | --- |
| Declarative native views | rows, grids, detail and forms are data rendered by the host (`PaletteItem`, `PaletteDetail`, scene nodes for custom detail); apps never draw |
| Typed actions | every action on an item is an `ActionRef` to a catalog entry (built-in op or the app's own `app:<id>#<cmd>`); no closures, so the palette, menus, shortcuts, CLI, MCP and the agent see the same action with the same argument schema |
| Async streaming results | query sources are async generators; each `yield` is a batch; a new query aborts the old generator (`AbortSignal`) |
| Offline-first | the app supervisor caches the last snapshot per scope (content-addressed, per machine); the host paints it first; `op` sources read the client mirror's last value |
| Sandboxed, scopes enforced | the app's permission scopes and grants apply to every op its source calls and to every `ActionRef` it returns (the owner checks on run); an item can only reference actions the app could call |
| Instant (<16 ms first paint) | the chip, the cached snapshot and the host ranker are on the first-paint path; app code never is; budget measured in the harness and in DEV `debug.timings` |
| Keyboard-first | the host owns every key (section 4.5); apps declare shortcuts per command (rebindable) |
| Agent-callable | every command is a CLI verb and MCP tool (`cmux apps run <id>#<cmd>`); every scope is queryable by `palette.query`; one declaration, no separate tool list |
| Testable | `@cmux/app-test` harness (6.6) |

### 6.2 Manifest

```jsonc
"contributes": {
  "paletteScopes": [{
    "id": "notes",
    "title": "Notes",                       // localizedText
    "symbol": "note.text",
    "placeholder": "Search notes…",
    "keywords": ["notes", "note"],
    "layout": "listWithDetail",             // list | listWithDetail | grid
    "ranking": "fuzzy",                     // fuzzy | recency | source
    "federates": true,                      // top 3 matches in root search
    "source": { "kind": "snapshot", "export": "noteCorpus", "invalidatedBy": ["note.changed"] },
    //   or { "kind": "query", "export": "searchNotes", "minQueryLength": 1 }
    //   or { "kind": "op", "op": "note.search", "item": { "id": "$.id", "title": "$.title", "subtitle": "$.folder" } }
    "primary": "note.open",                 // default ActionRef id for rows without actions
    "detail": { "export": "noteDetail" },   // optional
    "emptyState": { "title": "No notes yet", "action": "app:cmux/notes#new" },
    "filters": [{ "id": "pinned", "title": "Pinned" }]
  }],
  "commands": [{
    "id": "new", "title": "New Note", "run": "newNote",
    "mode": "run",                          // run | form | view
    "arguments": { "type": "object", "properties": { "title": { "type": "string" } } },
    "keywords": ["create"], "contexts": ["palette"]
  }]
}
```

- `kind: op` needs no app code at all: the palette calls a read op (owned by `app:<id>` on its server host, or any catalog read) and maps fields. It works with the VM stopped and with the `server` block's single host per team.
- `mode: form` renders the command's `arguments` schema as a native form inside the palette (one level, chip "New Note"); Return submits the typed args to the command. Forms come from the schema, so the CLI flags, the MCP input and the form never disagree.
- `mode: view` pushes a scope that the command returns (`return scope.list(...)`), for flows that build lists from arguments.
- `filters` render as a menu at the right of the field (the scope's facets); the chosen filter is part of the query sent to the source.
- Scopes and commands appear as rows in the root and in the `apps` scope under the app's name; the app's scopes join the scope graph with `parents: root`.

### 6.3 Runtime API (in the `cmux` global, `@cmux/app-types`)

```ts
import { palette, act } from "cmux"

export const noteCorpus = palette.snapshot(async (ctx) =>
  (await cmux.note.list({ limit: 5000 })).map(n => ({
    id: n.id, title: n.title, subtitle: n.folder, symbol: "note.text",
    keywords: n.tags, accessory: { date: n.updatedAt },
    actions: [act("note.open", { id: n.id }), act("note.pin", { id: n.id }), act("clipboard.write", { text: n.body }, { title: "Copy Body" })],
  })))

export const searchNotes = palette.query(async function* (q, { signal, filter }) {
  yield palette.cached()                               // offline: the last result for this query prefix
  for await (const page of cmux.note.search.stream({ q, filter }, { signal })) yield page.items.map(toItem)
})

export const noteDetail = palette.detail(async (id) => ({ markdown: (await cmux.note.get({ id })).body }))
```

- `act(op, args, overrides?)` builds an `ActionRef`; the runtime validates `args` against the op's schema at build time in development (`cmux apps dev`) and the host validates on run.
- Items are plain data (at most 2 KiB each, 10 000 per snapshot, 200 per batch); scene nodes are allowed only in `detail`.
- A snapshot export runs at most once per invalidation and never on keystrokes; the supervisor marks it dirty on an `invalidatedBy` event and reruns it on the next open, so an idle app costs nothing (no polling, idle-wakeups.md).

### 6.4 Capability map

| Launcher-extension feature | cmux mechanism |
| --- | --- |
| commands (view, no-view, menu bar) | `commands` (`mode: run | form | view`), `statusItems` (menu bar) |
| list, grid, detail views | scope `layout` + items + `detail` |
| forms | `mode: form` from the command's argument schema; drafts kept per level |
| action panel, per-action shortcuts | `ActionRef`s; Cmd-K; shortcuts from the catalog, rebindable |
| preferences | `contributes.settings` (Settings > Apps, `cmux.json`); a required setting pushes its form the first time the scope opens |
| OAuth | integration gateway (D39), scope `integration:<provider>`; the app never holds tokens; empty state `needsSetup` offers Connect |
| AI | every command and scope is an MCP tool for agents; apps call models through `cmux.ai` (coderouter, scope `ai:complete`), streamed |
| menu-bar items | `statusItems` with the same scene graph |
| background refresh | events (`invalidatedBy`, `cmux.live`) and the app server (N13) pushing `<family>.changed`; no intervals; external polling only on the app server, with backoff |
| deeplinks | `cmux://palette/<scope>?q=` opens a scope (`palette.open`, user origin); `cmux://app/<id>/<cmd>?args=` runs a command after the same consent as a third-party caller |
| quicklinks | built-in `quicklinks` scope over `cmux.json` templates (`{query}`, `{clipboard}`); apps contribute static templates (`contributes.quicklinks`, zero code) |
| snippets | built-in `snippets` scope over config data; inserting is the typed op `terminal.send` |
| store review | tiers D45/D51; the registry adds palette checks: prefix requests (only first-party), keyword collisions, item budgets, localized titles, a11y labels, `ActionRef` ops within the requested scopes |

### 6.5 Fit with the app manifest server block

- A scope whose items live in the app's server uses `source.kind = op` with an op owned by `app:<id>`; `owner_for` routes it to the one host per team that runs the server (single writer). The palette never talks to the server directly.
- `contributes.paneKinds[].renderer = native` stays first-party and Verified only; palette scopes never need it. A row may offer "Open in Pane" as an `ActionRef` to the app's pane kind.
- Origin: a row run from the palette is a user gesture; the action runs with origin `user` through `ActionRegistry.perform` (lane 3 gap B2 asks the same for app command chains).

### 6.6 Test harness (`@cmux/app-test`)

```ts
import { harness } from "@cmux/app-test"
const h = await harness.load(".", { grants: ["note:read"], fixtures: { "note.list": notes } })
const s = await h.palette.open("notes")              // first paint from the cached snapshot
expect(s.firstPaintMs).toBeLessThan(16)
await s.type("rea"); expect(s.rows.map(r => r.title)).toEqual(["Reading list"])
await s.tab(); expect(s.chips).toEqual(["Notes", "Actions"])
await s.press("Return"); expect(h.ops.calls).toContainEqual({ op: "note.open", args: { id: "n1" } })
await s.backspace(); expect(s.chips).toEqual(["Notes"])
```

The harness runs the same navigation rules from a shared JSON vector file (`palette-nav-vectors.json`, event sequence to expected chips, queries and selection) that the Swift reducer tests also run, so the two implementations cannot drift. It reports scope and grant violations (`scope.missing`) the way the host does, and an op that no owner implements as `operation.unsupported` (lane 3 found the runtime reports both as `scope.missing`; the harness keeps them apart so authors see which one they hit).

### 6.7 Lane 3 gaps this design closes

Lane 3 (first-party-apps.md section 3, PR 16786; search app PR 16792) found these palette-related gaps. This design closes them as follows.

| Gap | Closed by |
| --- | --- |
| S4: no search-provider contribution | `contributes.paletteScopes` with `federates: true`: one declaration feeds the root search (top matches under the app's section), the scope chip and `palette.query`. The host fans out to federating scopes with a per-scope deadline (first frame from snapshots; query scopes join when their first batch lands) and merges by the palette ranker. Apps never call each other. |
| No MCP or CLI tools for app commands | every `contributes.commands` entry registers catalog action `app:<id>#<cmd>` with CLI `cmux apps run <id>#<cmd>` and, when the app holds `mcp:expose` and the user granted it, MCP tool `app_<id>_<cmd>` with the command's `arguments` schema as input; every scope is queryable by `palette.query`. check-action-surfaces exempts the dynamic family with `appContribution`. |
| User origin ends at the first `await` (B2) | two parts. (1) A palette row's actions are `ActionRef`s that the host runs itself through `ActionRegistry.perform` with origin `user`; no app code runs, so nothing is lost across `await`. (2) For `run` commands, the host passes a gesture capability in the invocation: `ctx.gesture` (host-minted, bound to the app id and the invocation, valid until the command's promise settles or 2 s, whichever is first). Calls made through `ctx.cmux` (a per-invocation proxy of the global) carry it and run with origin `user`; calls through the global `cmux` stay `script`. It is passed explicitly, so it survives any `await` without async-context support in the engine, and the host checks it on every call (the VM is untrusted). |
| No list keyboard navigation in scene nodes | app lists in the palette are host rows, so they get the palette's keyboard model (section 4.5) for free. For sidebar sections and panes, a `List` scene node with host-owned selection (the same selection-memory rules as `PaletteNavReducer`: keep by id, else by index, else first) is proposed to the platform lead. |
| The search app's variants | become palette scope layouts: `palette` = federation into the root; `grouped` = scope `app:cmux/search#search` with sections per source; `preview` = the same scope with `layout: listWithDetail`. The app keeps its sidebar section and pane; the palette path needs no scene tree. |
| App localization API | scope titles, placeholders, keywords and empty states use the manifest's `localizedText`; runtime strings (item titles from data stay as data) need the platform's `cmux.l10n` (lane 3 gap, platform lead). |

Not closed here (platform lead): popovers, menu-bar status items (palette scopes do not need them), `x-cmux-devOnly`, and the scene node count bug in `materialize.ts`.

### 6.8 Documents, buffers and app composition

Lawrence wants a documents/buffers primitive and app composition (embedding) in the app platform (lane 3 critique, 2026-10-02). Palette scopes fit both by reference, never by shared code.

- **Documents are a scope source.** When the documents primitive lands (one owner per document, typed ops such as `document.search`, `document.open`), a built-in `documents` scope uses `source.kind = op` over `document.search`, and the `files` scope becomes one federating provider of it. Notes, buffers and files then share one chip, one ranker and one `palette.query`. A row's primary `ActionRef` is `document.open {id}`; the documents owner picks the pane kind (an app's editor or the built-in one), so the palette does not know which app edits what.
- **Drill into a document.** The default drill of a document row is a scope over its parts (buffers, headings, symbols) served by the document's owner op, with the row as context: Tab on a note, then type to jump to a heading.
- **Scopes compose across apps.** A scope may list another app's scope as a child (`contributes.paletteScopes[].children: ["app:cmux/notes#notes"]`), and a row may `enters` or `drills` into any registered scope with itself as context (a task row drills into the notes linked to it). The host composes: each scope runs with its own app's grants; the parent app never sees the child's items. Composition is by scope id and `ActionRef` through the catalog, so an agent can do the same with `palette.query`.
- **Embedding in detail.** A scope's detail may embed another app's view by reference (`{embed: {app, view, args}}` scene node, mounted by the host in its own sandbox with its own grants). Proposed to the platform lead as the general embedding node; the palette only reserves the slot.

## 7. Prototypes (DEV and NIGHTLY, Debug Settings > Palette)

| Tunable | Variants | What changes |
| --- | --- | --- |
| `palette.scopeChip` | `token` (default), `breadcrumb`, `header` | `token`: a gray capsule with icon and title inside the field before the caret, lower levels collapsed to "…"; `breadcrumb`: a thin row above the field ("Commands › Tabs"), field below; `header`: the scope icon and title replace the magnifier in semibold with a gray rule under the field |
| `palette.scopeEntry` | `all` (default), `prefix`, `keyword`, `list` | which entry gestures are on: prefix characters, keyword plus Tab ("Tab to search Tabs" hint at the right of the field), the scope list as the first section of the empty root |
| `palette.itemActions` | `menu` (default), `scope` | Cmd-K opens the floating menu, or pushes the `actions` scope with a chip |

Screenshots come from a throwaway demo executable that links `CmuxNextPalette` with mock sources (AGENT-BRIEF). Recommendation after screenshots: section 9.

## 8. Steps

| # | Step | State |
| --- | --- | --- |
| 1 | This proposal, the private research note | this PR |
| 2 | `CmuxNextPalette/Scopes/`: descriptor, graph, `PaletteNavReducer`, example and property tests | this PR |
| 3 | Palette UI on the reducer: chip variants, entry variants, scope list, `?` scope, Debug Settings tunables, screenshots | after lane 2's PR 16796 lands (it changes the same palette files) |
| 4 | Port Search Tabs to scope `tabs`; "Go to Tab…" and Cmd-Shift-A open it | after 16796 |
| 5 | Catalog `palette.open`, `palette.scopes`, `palette.query`, `palette.run`; control socket; CLI request | after 3 |
| 6 | Extension contribution: schema `contributes.paletteScopes`, runtime `palette.*`/`act`, Swift bridge from the app registry, sample app, harness with shared vectors | after 5, with the app platform lead |

## 9. Decisions

- DECISION D-PS1: name in the manifest. RECOMMEND `contributes.paletteScopes` (not `scopes`, which is the permission list), and fold lane 3's proposed `searchProviders` (gap S4) into it as `federates: true`, because one contribution then serves the root search, the scope chip and `palette.query`.
- DECISION D-PS2: Esc at a level opened by its shortcut. RECOMMEND close (clear the query first), with Backspace as the way to the root, because a user who pressed Cmd-Shift-A expects Esc to dismiss, and Backspace is the decided way back (PA2).
- DECISION D-PS3: Tab. RECOMMEND Tab enters (keyword, scope row, drill) and falls back to the Actions menu, because PA2 asks that Tab enters a scope and Cmd-K still opens the Actions menu.
- DECISION D-PS4: prefixes for app scopes. RECOMMEND none by default (keyword only; users can assign one), because one-character prefixes are scarce and a third-party app should not take one.
- DECISION D-PS5: item actions. RECOMMEND typed `ActionRef`s only for app items (no closures), because closures cannot be listed, bound, audited or called by agents.
