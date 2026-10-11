# Search (`cmux/search`)

One place to find anything in cmux and open it: workspaces, terminals (titles, working directories and their text), browser tabs and history, items from other apps (notes, inbox), and files in the folders your terminals work in. Results are grouped by source and ranked by match quality and recency. Opening a result focuses that thing. Agents get the same search as a command and MCP tool that returns JSON.

Prototype on the cmux app platform. It uses only the public app API (`cmux` global and view builders). Data the API does not offer yet is requested through proposed operations (below); until a host implements them, the app says which source it could not search and why.

## Contributions

| Kind | Id | Export | What |
| --- | --- | --- | --- |
| sidebar section | `sidebar` | `renderSection` | query field, scope toggle, grouped results, recent searches |
| pane kind | `pane` | `renderPane` | the same search with more room (the platform does not mount pane kinds yet; the preview harness renders it) |
| command | `search` | `search` | palette, keybinding, `cmux apps run cmux/search#search`, MCP tool. Arguments `{query, sources?, limit?, scope?, regex?}`; returns JSON. Never moves focus |
| command | `clearRecent` | `clearRecent` | forget recent searches and the "opened" ranking signal |
| command | `cycleVariant` | `cycleVariant` | "Next Search Variant" (DEV/NIGHTLY) |
| MCP server | `tools` | commands | exposes `search` to agents (scope `mcp:expose`) |

Settings: `variant` (`grouped` default, `preview`, `palette`; `x-cmux-devOnly`), `defaultScope` (`all` or `workspace`), `rememberRecent` (true), `sources` (all five). `test/settings.test.ts` checks the code defaults equal the manifest defaults.

## Scopes

| Scope | Why |
| --- | --- |
| `session:read` | one `session.snapshot` gives workspaces, tabs, terminals and browser tabs, and maps every tab to its workspace |
| `terminal:read` | search terminal text (`terminal.search`, else `terminal.screen.read` of visible screens) |
| `workspace:write` | `workspace.focus` / `tab.focus` when you open a result (tap and Return handlers run with origin `user`) |
| `actions:run` | open a history page (`openBrowser`), a file (`file.open`), or an app item (`app.<id>#<command>`) |
| `mcp:expose` | offer `search` to agents |
| optional `browser_history:read` | proposed `browser.history.search` |
| optional `fs:read` | proposed `fs.search`, limited to roots the user grants |
| optional `search:read` | proposed `search.providers.query` (other apps' items) |

## Query syntax

Plain text matches names (fuzzy for short names) and text. Leading prefixes narrow sources and combine: `t:` terminals, `f:` files, `b:` browser, `w:` workspaces, `a:` app items (`t:f: config`). `in:here` / `in:all` set the scope for one search. `/pattern/` (or the `.*` chip) is a regular expression, `/pattern/i` forces case-insensitive. `"exact phrase"` turns off fuzzy matching. Case is smart: an uppercase letter makes the match case-sensitive. Return opens the highlighted result (or searches first when results are stale); Escape clears.

## Ranking

`score = quality + recency + here + opened`. Quality (0..100): exact 100, prefix 90, word start 80, substring 70, every word 60, regex 65, fuzzy 20..55, text matches 45..50; matches in a secondary field (cwd, URL) count 0.7. Recency adds 0..24 over the last 7 days. A hit in the current workspace adds 8 when searching everywhere. A hit you opened from search adds up to 16, fading over 30 days. Groups keep a fixed order (Workspaces, Terminals, Browser, Apps, Files) so keyboard and eye positions stay stable; the best hit overall is the highlighted one. Each group shows 4 (sidebar) or 8 (pane) rows, 40 when one source is selected, with a "N more" row that narrows to that source.

## Behavior notes

- Typing debounces 150 ms with one one-shot timer. Each run has a generation; an older answer never replaces a newer one. Each source gets a stable `search_id` per surface, so an owner can drop superseded work.
- Names show at once; slower owners fill in as they answer (partial results).
- `workspace.changed`, `tab.changed`, `terminal.changed` and `browser.changed` re-run a visible, non-empty search once (300 ms one-shot). No polling.
- Recent searches (8) are saved when you open a result, not per keystroke. Storage failures never break search.
- Without `terminal.search`, terminal text falls back to the visible screens of up to 12 running terminals, marked "visible screen only".
- File roots are the distinct working directories of terminals in scope (nested folders collapse, at most 8).

## Variants

| Variant | Design |
| --- | --- |
| `grouped` (recommended) | field + scope chip on one line; native `Row`s grouped by source with counts; "N more"; quiet footer lines for sources that could not be searched |
| `preview` | field, source chips, regex and scope chips; result list; preview of the selected result with the match highlighted and an Open button. Side by side in the pane, stacked in the sidebar. A tap selects, a second tap opens |
| `palette` | one ranked list without headers, drawn like a Cmd-Shift-P page: icon, highlighted text, source on the right. The page a `searchProviders` contribution would give the palette |

## Proposed operations

| Name | Params | Result | Owner | Risk | Scope | Invalidated by | Why existing ops do not suffice |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `terminal.search` | `{query, regex?, case_sensitive?, terminals?, include_closed?, limit?, per_terminal?, context_chars?, search_id?}` | `{matches: [{terminal, tab, title, closed, row, line_text, match_start, match_length, last_output_at_ms}], truncated}` | session host (keeps scrollback and transcripts) | read | `terminal:read` | `terminal.changed` (lifecycle) | `terminal.copy`/`history.read` would ship whole scrollbacks into the app VM (32 MiB cap) and cannot see closed terminals |
| `terminal.viewport.reveal` | `{terminal, row}` | empty | session host | mutate-own (viewport) | `terminal:write` | none | `terminal.viewport.scroll` takes a relative `delta_rows`, which races with output; reveal takes the absolute row from `terminal.search`. Accept only with origin `user` |
| `browser.history.search` | `{query, regex?, limit?, search_id?}` | `{entries: [{url, title, last_visit_ms, visit_count}], truncated}` | browser history store | read | `browser_history:read` (new family) | `browser_history.changed` | `browser.list` only lists open tabs; history is not exposed at all |
| `fs.search` | `{roots, query, mode?: name/content/both, regex?, case_sensitive?, include?, exclude?, limit?, search_id?}` | `{matches: [{root, path, relative, kind, line?, column?, line_text?, match_start, match_length, modified_ms}], truncated, denied_roots?}` | session host on the machine that has the files | read | `fs:read` with granted roots | none (on demand) | no file access exists for apps; the host must enforce roots, skip binary and large files, cap output |
| `search.providers.query` | `{query, providers?, limit_per_provider?, search_id?}` | `{providers: [{provider, title, items: [{id, title, subtitle?, line_text?, match_start?, match_length?, symbol?, updated_at_ms?, open: {command, args?}}], truncated, error?}]}` | app supervisor (fans out with a per-provider deadline; never app-to-app) | read | `search:read` | `<app>.changed` events of providers | apps cannot see each other; the supervisor runs each provider under its own grant |

Shared rules for the search ops: a newer call with the same `search_id` from the same app supersedes the older one (it ends with `request.superseded`); apps cannot call `request.cancel`, so supersede is the cancel. A cancelled search returns no partial matches. Owners cap results and set `truncated`. Offsets are UTF-16 code units into `line_text`. No op returns a secret.

Proposed contribution `searchProviders: [{id, title, symbol, run: "<export>", open: "<command>"}]`: the export gets `{query, limit}` and returns items in the shape above. The palette and this app query providers only through `search.providers.query`; a provider call cannot itself fan out (depth 1), and the calling app is excluded. This app would contribute one provider whose `run` is `search`, so the palette can show its results as a page (variant `palette`).

Proposed argument: `history.reopen` accepts `{terminal}` to reopen a closed terminal from a transcript match.

## Manifest v2

`cmux-app.v2.json` is the manifest v2 that the daemon's app supervisor loads; it passes the one validator (`cmux-tui/crates/cmux-app-manifest`). It declares the same app as `cmux-app.json`: `runtime.main` `dist/main.js`, `cmux.section/1` (`renderSection`, top) and `cmux.pane/1` (`renderPane`), and the catalog fragment `catalog/search-catalog.json`. Every v1 command is one catalog op of family `search_app` (owner `app:cmux/search`, `export` names the JS function, CLI `apps run cmux/search <verb>`, palette title only for palette commands, MCP as v1 exposed it). The DEV/NIGHTLY `variant` setting is the `variants` block. `cmux-app.json` stays for today's in-app runtime.

The v2 schema cannot hold these parts of the app, so the manifest leaves them out:

1. The family is `search_app`, not `search`: host search ops use `search.*`.
2. Search providers of other apps: the app calls the host's search ops directly, so it does not list `cmux.search.provider/1` in `consumes`.

## Platform gaps

1. Scene node count drift: removing a subtree (a dynamic child rebuild or a removed `ForEach` row) emits one `remove` op and decrements the mount's node count by 1, and the child node records stay in the handler map. A long-lived surface that re-renders lists hits `app.limit: more than 4096 scene nodes` after enough searches (a 9-node dynamic child rebuilt 600 times fails today). Found while building this app; the fix belongs in the runtime's `materialize.ts`.
2. No rich text: highlights are three `Text` nodes in an `HStack`, which cannot wrap and truncate per segment. Proposed: `Text.highlights: [{start, length}]` and `Row.subtitleHighlights`.
3. No key events on `TextField` beyond Return and Escape: no arrow-key selection, no Tab between chips. Proposed: `onKey {key, modifiers}` for `up down tab` on `TextField`, or a list selection primitive.
4. `contributes.searchProviders` is not in the manifest schema (top-level `contributes` rejects unknown keys), so the palette page cannot be declared yet.
5. Pane kinds are not mounted, and no op reveals or focuses an app's sidebar section; the `search` command from the palette can only return JSON, not show the UI.
6. Scopes take no parameters except `net:` and `integration:`; `fs:read` needs a root list chosen at consent.
7. `scopes.json` maps `app.storage.*` to `storage:local`, but the manifest scope pattern cannot declare it; hosts must treat it as implicit (the preview harness does).
8. No locale in the init or render context: the app reads `ctx.locale` or `navigator.language`, else English. No app i18n API (the app carries `src/l10n.ts`).
9. No op for an app to write its own setting: "Next Search Variant" stores a dev override in app storage instead of `apps."cmux/search".settings.variant`. `x-cmux-devOnly` is not honored yet.
10. No container width in the render context, and `HStack` has no alignment prop: the variant picks side-by-side vs stacked by contribution, and columns need trailing spacers to pin to the top.
11. `untrack` and `.peek()` exist at runtime but not in `cmux-app.d.ts`.
12. Workspaces have no folder of their own; file roots come from terminal working directories.
13. Recency signals are missing for workspaces, tabs and browser tabs (no `last_focused_at_ms`), so only search history ranks them by time.

## Develop

```bash
bun cmux-tui/crates/cmux-app-host/tools/pack.ts first-party-apps/search
bun cmux-tui/crates/cmux-app-host/tools/validate-manifest.ts first-party-apps/search
bun test first-party-apps/search/test
```

Preview fixtures (`preview/*.json`, neutral invented data): `full.json` answers every proposed op, `today.json` answers only existing ops (proposed ones are `operation.unsupported`), `recent.json` adds stored recent searches. Pick the variant with `--settings '{"variant":"..."}'`.
