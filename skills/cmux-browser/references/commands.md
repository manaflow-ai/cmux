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
cmux browser "$TAB" wait "#results"
cmux browser "$TAB" wait --url-contains /dashboard --timeout-ms 15000
cmux browser "$TAB" wait --text "Saved"
cmux browser "$TAB" wait --load-state complete
cmux browser "$TAB" wait --function 'window.appReady === true'
cmux browser "$TAB" screenshot --out page.png
cmux browser "$TAB" screenshot --selector "#chart" --out chart.png
cmux browser "$TAB" screenshot --full-page --out full.png
cmux browser "$TAB" screenshot --out - > page.png
cmux browser "$TAB" cookies get --name session_id
cmux browser "$TAB" cookies set session_id abc123 --domain .example.com --secure
cmux browser "$TAB" cookies clear --domain example.com
cmux browser "$TAB" storage local get
cmux browser "$TAB" storage local set theme dark
cmux browser "$TAB" storage session get draft
cmux browser "$TAB" storage session clear
cmux browser "$TAB" press Enter
cmux browser "$TAB" press Tab --selector "#email"
cmux browser "$TAB" hover "#menu"
cmux browser "$TAB" select "#size" m
cmux browser "$TAB" check "#terms"
cmux browser "$TAB" uncheck "#newsletter"
cmux browser "$TAB" scroll --dy 600
cmux browser "$TAB" scroll "#results" --dy 300
cmux browser "$TAB" scroll-into-view "#footer"
cmux browser "$TAB" tabs
cmux browser page tabs --all
cmux browser "$TAB" new-tab https://example.com
cmux browser "$TAB" switch
cmux browser "$TAB" close
```

`goto` and `open` are accepted for `navigate`; `url` and `title` are accepted
for `state`. `fill` replaces the field's value; `type` types into it.
Selectors are CSS selectors or snapshot refs (`e3`, `@e3`). Add `--json` before
the scope for machine-readable output (`cmux --json browser "$TAB" state`).

`wait` takes one condition: a selector (positional or `--selector`), else
`--url-contains`, `--text`, `--load-state interactive|complete`, or
`--function` (a JavaScript expression), in that order. With none it waits for
the page to finish loading. The default timeout is 5000 ms (`--timeout-ms`, at
most 120000, or `--timeout` in seconds); it exits 1 with `timeout` when the
condition does not hold in time, and keeps waiting across a navigation.

`screenshot` captures the visible viewport as a PNG. `--selector` captures one
element (scrolled into view, clipped to the viewport); `--full-page` captures
the whole document (at most 25 million CSS pixels and 48 viewport tiles;
fixed headers repeat in WebKit tabs). Without `--out` the PNG is a new file in
the temporary directory (kept for an hour, newest 32); `--out PATH` copies it there. It prints the path
(`--json`: the tab, path, width and height). `--out -` writes only the PNG to
stdout.

`cookies` reads and changes the tab profile's cookies (fields `name`, `value`,
`domain`, `path`, `expires`, `secure`, `httpOnly`, `hostOnly`, `session_only`).
`get` filters by `--name` (exact), `--domain` (substring) and `--path`.
`set NAME VALUE` takes the domain from `--domain` (a leading dot covers
subdomains), else `--url`'s host, else the tab's page; `--path` defaults to `/`, and `--expires` takes Unix
seconds. `clear` takes a scope: `--name`, `--url` (the cookies a
request there would send), `--domain` (that domain and its subdomains),
`--path`; it reports how many it cleared. `--all` is refused: it would empty
the profile's cookies with no undo.

`storage local|session` (default `local`) reads one key or every key with
`get`, writes with `set KEY VALUE` and empties the area with `clear`, in the
page's origin.

`press KEY` (temporary: it moves to trusted key input) sends a key to the focused element (or `--selector`'s element,
focused first). Keys are W3C key or code names (`Enter`, `Tab`, `Escape`,
`ArrowDown`, `PageDown`, `F5`, `Space`, `Shift`, `KeyA`, `Slash`, `Numpad1`) or
one character; any other name is sent as is, so `Control+a` is one opaque key,
not a combination. The events are page-level (untrusted): Space activates
buttons and checkboxes and Enter submits a single-line form field, but browser
defaults such as Tab moving focus do not run. `hover` sends pointer and mouse
over, enter and move events. `select SELECTOR VALUE` picks an option by its
value. `check` and `uncheck` click only when the state differs and fail with
`not_checkable`, `disabled` or `not_changed`. `scroll` scrolls the page, or
one element, by `--dx`/`--dy` CSS pixels (`scroll 400` is `--dy 400`) and
prints the new position. The old flag forms (`--selector`, `--value`, `--key`)
and verb aliases (`key`, `scrollintoview`) still work.
These act once and do not retry for an element that is still loading.

`tabs` lists the browser tabs of the tab's workspace (`page tabs`: the focused
workspace; `--all`: every workspace) with id, title, URL, pane and whether each
is selected or focused. `new-tab [URL]` opens a browser tab in the same pane
and prints its id under `created`; `switch` shows and focuses the
tab (`select` is the form verb above); `close` closes it. They run the same actions as the tab strip, wait for
them unless `--no-wait`, and refuse a tab that is not an app browser tab. They
act on the tab you name; the old `tab switch|close <index>` has no equivalent.

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

The old CLI's `state save|load`, `console`,
`errors`, `highlight`, `download`,
`dialog`, `frame`, `network`, `trace`, `screencast`, `geolocation`,
`offline`, `viewport`, `dblclick`, `keydown`, `keyup`, `get attr|count|box|styles|html`,
`identify`, `profile`,
`design-mode status` and `--snapshot-after` have no per-tab command.
Saved state, console, dialogs and downloads are in the
browser REPL ([repl-guide.md](repl-guide.md)). Do not poll with
`eval`; use `wait`. For a one-shot read that
`text` and `value` do not cover, `eval` returns the script's value.

See also [snapshot-refs.md](snapshot-refs.md) and
[authentication.md](authentication.md).
