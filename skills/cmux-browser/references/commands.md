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
cmux browser "$TAB" press Enter
cmux browser "$TAB" press Tab --selector "#email"
cmux browser "$TAB" hover "#menu"
cmux browser "$TAB" select "#size" m
cmux browser "$TAB" check "#terms"
cmux browser "$TAB" uncheck "#newsletter"
cmux browser "$TAB" scroll --dy 600
cmux browser "$TAB" scroll "#results" --dy 300
cmux browser "$TAB" scroll-into-view "#footer"
```

`goto` and `open` are accepted for `navigate`; `url` and `title` are accepted
for `state`. `fill` replaces the field's value; `type` types into it.
Selectors are CSS selectors or snapshot refs (`e3`, `@e3`). Add `--json` before
the scope for machine-readable output (`cmux --json browser "$TAB" state`).

`press KEY` sends a key to the focused element (or `--selector`'s element,
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

The old CLI's `wait`, `cookies`, `storage`, `state save|load`, `console`,
`errors`, `highlight`, `screenshot` (to stdout or a file), `download`,
`dialog`, `frame`, `network`, `trace`, `screencast`, `geolocation`,
`offline`, `viewport`, `dblclick`, `keydown`, `keyup`, `get attr|count|box|styles|html`,
`tab list|new|switch|close` inside a browser, `identify`, `profile`,
`design-mode status` and `--snapshot-after` have no command in the new CLI.
Waits are not supported yet; do not poll with `eval`. For a one-shot read that
`text` and `value` do not cover, `eval` returns the script's value.

See also [snapshot-refs.md](snapshot-refs.md) and
[authentication.md](authentication.md).
