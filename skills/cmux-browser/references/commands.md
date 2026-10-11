# Command Reference (cmux Browser)

Run `cmux browser --help` against the installed binary before relying on exact
syntax. `TAB` below is a `tab_…` id (or a unique prefix) from `cmux tab list`
or `cmux tab create browser`; `page` means the focused browser tab. See
[surface-discovery.md](surface-discovery.md) before targeting a tab in another
workspace.

## Creation and discovery

```bash
cmux --json tab create browser --url https://example.com
cmux --json tab create browser --url https://example.com --name docs --workspace ws_… --screen current --pane current
cmux --json tab list
cmux tab tab_… show
cmux browser list
```

`tab create browser` needs `--url`. `--workspace`, `--screen` and `--pane`
place the tab; without them it goes to the caller's pane. UI actions
`cmux tab new-browser`, `cmux browser split-right` and
`cmux browser split-down` open a browser in the focused place; read their
arguments with `cmux action describe "browser split-right"`.

## Page commands for app tabs (`tab_…` or `page`)

```bash
cmux browser "$TAB" navigate https://example.com
cmux browser "$TAB" back
cmux browser "$TAB" forward
cmux browser "$TAB" reload
cmux browser "$TAB" state
cmux browser "$TAB" eval 'document.title'
cmux browser "$TAB" snapshot
cmux browser "$TAB" snapshot --interactive
cmux browser "$TAB" snapshot --selector "form#checkout" --max-depth 3 --interactive
cmux browser "$TAB" click e2
cmux browser "$TAB" focus "#email"
cmux browser "$TAB" text body
cmux browser "$TAB" value "#email"
cmux browser "$TAB" fill "#email" "$APP_USERNAME"
cmux browser "$TAB" type "#search" "query"
```

`goto` and `open` are accepted for `navigate`; `url` and `title` are accepted
for `state`. `fill` replaces the field's value; `type` types into it.
Selectors are CSS selectors or snapshot refs (`e3`, `@e3`). Add `--json` before
the scope for machine-readable output (`cmux --json browser "$TAB" state`).

## Daemon browsers (`browser_…`)

A browser the cmux-tui daemon owns has its own verbs:

```bash
cmux browser browser_… show
cmux browser browser_… navigate --url https://example.com
cmux browser browser_… back|forward|reload|activate
cmux browser browser_… key --key Enter
cmux browser browser_… text --text "hello"
cmux browser browser_… close
```

`key` also takes `--kind down|up|press` and `--modifiers shift,control,alt,meta`.

## UI actions on the focused browser

These run the same action as the menu or palette and return no page data:
`browser screenshot-page`, `browser screenshot-section`,
`browser toggle-developer-tools`, `browser show-javascript-console`,
`browser delete-site-data`, `browser new-profile`,
`browser toggle-design-mode`, `browser toggle-focus-mode`,
`browser toggle-react-grab`. Page zoom is `cmux tab <tab_…> zoom in|out|reset`
(the app's Zoom In, Zoom Out and Actual Size on the tab's pane).

```bash
cmux action list --noun browser
cmux action describe "browser screenshot-page"
cmux browser screenshot-page
```

## Not in the per-tab CLI (use the REPL)

The old CLI's `wait`, `cookies`, `storage`, `state save|load`, `console`,
`errors`, `highlight`, `screenshot` (to stdout or a file), `download`,
`dialog`, `frame`, `network`, `trace`, `screencast`, `geolocation`,
`offline`, `viewport`, `hover`, `dblclick`, `check`, `uncheck`, `select`,
`scroll`, `scroll-into-view`, `press`, `keydown`, `keyup`, `get attr|count|box|styles|html`,
`tab list|new|switch|close` inside a browser, `identify`, `profile`,
`design-mode status` and `--snapshot-after` have no per-tab command. Waits,
cookies, storage, saved state, console, dialogs, downloads, screenshots, hover
and scroll are in the browser REPL ([repl-guide.md](repl-guide.md)); do not
poll with `eval`. For a one-shot read that
`text` and `value` do not cover, `eval` returns the script's value.

See also [snapshot-refs.md](snapshot-refs.md) and
[authentication.md](authentication.md).
