# Command Reference (cmux Browser)

## Surface contract

Run `cmux browser --help` against the installed binary before relying on exact
syntax. Creation verbs (`open`, `open-split`, `new`) and the explicitly global
browser verbs listed in `SKILL.md` may omit a surface. Every surface-bound
command that reads or mutates an existing browser must include one:

```bash
cmux browser --surface <surface> get url
cmux browser --surface <surface> snapshot --interactive
cmux browser --surface <surface> tab list
cmux browser --surface <surface> click <selector-or-ref>
```

`cmux browser <surface> <verb> ...` is the equivalent positional form. See
[surface-discovery.md](surface-discovery.md) before targeting an existing
authenticated browser or a browser in another workspace.

## Accepted aliases

Use the preferred column in new docs/scripts; every alias still requires the
same explicit surface.

| Purpose | Preferred | Accepted alias |
| --- | --- | --- |
| Read URL | `cmux browser --surface <surface> get url` | `cmux browser --surface <surface> url` or `get-url` |
| Navigate | `cmux browser --surface <surface> goto <url>` | `navigate` |
| Interactive snapshot | `cmux browser --surface <surface> snapshot --interactive` | `-i` |
| Press a key | `cmux browser --surface <surface> press <key>` | `key` |

The upstream `agent-browser` command's implicit page context maps to an
explicit cmux surface. Its interactive snapshot maps to `snapshot
--interactive`; its `open` command maps to `cmux browser open` because creation
returns a new surface.

## Discovery and creation

```bash
cmux identify --json
cmux tree --all --json
cmux browser --surface <surface> identify --json

cmux --json browser open <url> --focus false
cmux --json browser open <url> --workspace <workspace> --window <window> --focus false
cmux --json browser open-split <url> --workspace <workspace> --focus false
```

Creation defaults to the caller's `CMUX_WORKSPACE_ID` when neither
`--workspace` nor `--window` is supplied, and `--focus` defaults to false. An
explicit `--workspace` lets an agent create in another workspace without
selecting it.

## Navigation

```bash
cmux browser --surface <surface> goto <url>
cmux browser --surface <surface> back|forward|reload
cmux browser --surface <surface> get url|title
```

## Snapshot and inspection

```bash
cmux browser --surface <surface> snapshot --interactive
cmux browser --surface <surface> snapshot --interactive --compact --max-depth 3
cmux browser --surface <surface> get text body
cmux browser --surface <surface> get html body
cmux browser --surface <surface> get value "#email"
cmux browser --surface <surface> get attr "#email" --attr placeholder
cmux browser --surface <surface> get count ".row"
cmux browser --surface <surface> get box "#submit"
cmux browser --surface <surface> get styles "#submit" --property color
cmux browser --surface <surface> eval '<js>'
```

## Interaction

```bash
cmux browser --surface <surface> click|dblclick|hover|focus <selector-or-ref>
cmux browser --surface <surface> fill <selector-or-ref> [text]
cmux browser --surface <surface> type <selector-or-ref> <text>
cmux browser --surface <surface> press|key|keydown|keyup [--key <key> | <key>]
cmux browser --surface <surface> select <selector-or-ref> <value>
cmux browser --surface <surface> check|uncheck <selector-or-ref>
cmux browser --surface <surface> scroll [--selector <css>] [--dx <n>] [--dy <n>]
```

Empty `fill` text clears the field. Keyboard names follow Playwright/W3C
conventions (`Enter`, `Tab`, `Escape`, `ArrowLeft`, `Space`). `Space`,
`Spacebar`, and `space` emit DOM key `" "` with code `"Space"`; use `--key ' '`
to pass the raw DOM key.

## Wait

```bash
cmux browser --surface <surface> wait --selector "#ready" --timeout-ms 10000
cmux browser --surface <surface> wait --text "Done" --timeout-ms 10000
cmux browser --surface <surface> wait --url-contains "/dashboard" --timeout-ms 10000
cmux browser --surface <surface> wait --load-state complete --timeout-ms 15000
cmux browser --surface <surface> wait --function "document.readyState === 'complete'" --timeout-ms 10000
```

## Design mode

```bash
cmux browser --surface <surface> design-mode enable|status|disable --json
```

Design mode lets a user select page elements and copy their DOM, style, URL,
and screenshot context for pasting into an agent. CLI enable/disable never
moves application focus or copies context automatically.

## Session, state, and diagnostics

```bash
cmux browser --surface <surface> cookies get|set|clear ...
cmux browser --surface <surface> cookies clear --url https://app.example.com/
cmux browser --surface <surface> cookies clear --domain app.example.com
cmux browser --surface <surface> cookies clear --all
cmux browser --surface <surface> storage local|session get|set|clear ...
cmux browser --surface <surface> tab list|new|switch|close ...
cmux browser --surface <surface> state save|load <path>
cmux browser --surface <surface> console list|clear
cmux browser --surface <surface> errors list|clear
cmux browser --surface <surface> highlight <selector>
cmux browser --surface <surface> screenshot
cmux browser --surface <surface> download wait --timeout-ms 10000
```

`cookies clear` requires an explicit scope (`--url`, `--domain`, `--name`,
`--path`, another cookie filter, or `--all`). URL scope follows cookie
domain/path, secure, and expiration matching for the requested URL. JSON
responses include the number of removed cookies as `cleared`.

## Agent reliability

Use `--snapshot-after` on mutating actions to get a fresh post-action snapshot.
Re-snapshot after navigation, modal open/close, or major DOM changes. Prefer
short handles in output; use `--id-format both` only when a UUID must be logged
or exported. If the handle is stale, rediscover it; never silently retarget the
focused browser.

## Viewport emulation

```bash
cmux browser --surface <surface> viewport 1280 720
cmux browser --surface <surface> screenshot --out /tmp/desktop.png
cmux browser --surface <surface> viewport reset
```

Dimensions are limited to 1..4096 CSS pixels. cmux changes
`window.innerWidth`/`window.innerHeight` and aspect-fits the page inside the
existing pane; it does not resize the pane, move other surfaces, or change
focus. Screenshot PNG dimensions are exact CSS pixels on Retina and non-Retina
displays.

An unsupported viewport/page-zoom combination leaves the viewport unchanged
and returns `invalid_params` with reason
`viewport_zoom_render_geometry_too_large` plus `maximum_page_zoom`. An attached
browser inspector returns `invalid_state` with reason
`attached_browser_inspector`; close or detach it first. Opening or redocking an
attached inspector while emulation is active resets the viewport to native
sizing.

## Known WKWebView gaps (`not_supported`)

`browser.geolocation.set`, `browser.offline.set`, `browser.trace.start|stop`,
`browser.network.route|unroute|requests`, `browser.screencast.start|stop`, and
`browser.input_mouse|input_keyboard|input_touch` are not supported by the
WKWebView engine.

See also [snapshot-refs.md](snapshot-refs.md),
[authentication.md](authentication.md), and
[session-management.md](session-management.md).
