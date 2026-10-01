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
cmux browser "$TAB" cookies get --name session_id
cmux browser "$TAB" cookies set session_id abc123 --domain .example.com --secure
cmux browser "$TAB" cookies clear --domain example.com
cmux browser "$TAB" cookies clear --all
cmux browser "$TAB" storage local get
cmux browser "$TAB" storage local set theme dark
cmux browser "$TAB" storage session get draft
cmux browser "$TAB" storage session clear
```

`goto` and `open` are accepted for `navigate`; `url` and `title` are accepted
for `state`. `fill` replaces the field's value; `type` types into it.
Selectors are CSS selectors or snapshot refs (`e3`, `@e3`). Add `--json` before
the scope for machine-readable output (`cmux --json browser "$TAB" state`).

`cookies` reads and changes the tab profile's cookies (fields `name`, `value`,
`domain`, `path`, `expires`, `secure`, `httpOnly`, `hostOnly`, `session_only`).
`get` filters by `--name` (exact), `--domain` (substring) and `--path`.
`set NAME VALUE` takes the domain from `--domain` (a leading dot covers
subdomains), else `--url`'s host, else the tab's page; `--path` defaults to `/`, and `--expires` takes Unix
seconds. `clear` takes `--all` or a scope: `--name`, `--url` (the cookies a
request there would send), `--domain` (that domain and its subdomains),
`--path`; it reports how many it cleared.

`storage local|session` (default `local`) reads one key or every key with
`get`, writes with `set KEY VALUE` and empties the area with `clear`, in the
page's origin.

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
`browser delete-site-data`, `browser import-data`, `browser new-profile`,
`browser zoom-in`, `browser zoom-out`, `browser toggle-design-mode`,
`browser toggle-focus-mode`, `browser toggle-react-grab`.

```bash
cmux action list --noun browser
cmux action describe "browser screenshot-page"
cmux browser screenshot-page
```

## Removed, no replacement yet

The old CLI's `wait`, `state save|load`, `console`,
`errors`, `highlight`, `screenshot` (to stdout or a file), `download`,
`dialog`, `frame`, `network`, `trace`, `screencast`, `geolocation`,
`offline`, `viewport`, `hover`, `dblclick`, `check`, `uncheck`, `select`,
`scroll`, `scroll-into-view`, `press`, `keydown`, `keyup`, `get attr|count|box|styles|html`,
`tab list|new|switch|close` inside a browser, `identify`, `profile`,
`design-mode status` and `--snapshot-after` have no command in the new CLI.
Waits are not supported yet; do not poll with `eval`. For a one-shot read that
`text` and `value` do not cover, `eval` returns the script's value.

See also [snapshot-refs.md](snapshot-refs.md) and
[authentication.md](authentication.md).
