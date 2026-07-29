# Command Reference (cmux Browser)

## agent-browser equivalents

`agent-browser <verb>` maps to `cmux browser <surface> <verb>` for `goto`/`navigate`, `click`, `fill`, `type`, `select`, `get text`, `get url`, `get title`. `agent-browser snapshot -i` is `cmux browser <surface> snapshot --interactive`. `agent-browser open <url>` is `cmux browser open <url>` (no surface, since it creates one).

## Navigation

```bash
cmux browser open <url>                        # caller's workspace, via CMUX_WORKSPACE_ID
cmux browser open <url> --workspace <id|ref>
cmux browser <surface> goto <url>
cmux browser <surface> back|forward|reload
cmux browser <surface> get url|title
```

## Snapshot and inspection

```bash
cmux browser <surface> snapshot --interactive
cmux browser <surface> snapshot --interactive --compact --max-depth 3
cmux browser <surface> get text body
cmux browser <surface> get html body
cmux browser <surface> get value "#email"
cmux browser <surface> get attr "#email" --attr placeholder
cmux browser <surface> get count ".row"
cmux browser <surface> get box "#submit"
cmux browser <surface> get styles "#submit" --property color
cmux browser <surface> eval '<js>'
```

## Interaction

```bash
cmux browser <surface> click|dblclick|hover|focus <selector-or-ref>
cmux browser <surface> fill <selector-or-ref> [text]   # empty text clears
cmux browser <surface> type <selector-or-ref> <text>
cmux browser <surface> press|key|keydown|keyup [--key <key> | <key>]
cmux browser <surface> select <selector-or-ref> <value>
cmux browser <surface> check|uncheck <selector-or-ref>
cmux browser <surface> scroll [--selector <css>] [--dx <n>] [--dy <n>]
```

Keyboard names follow Playwright/W3C conventions (`Enter`, `Tab`, `Escape`, `ArrowLeft`, `Space`). `Space`, `Spacebar`, and `space` all emit DOM key `" "` with code `"Space"`; use `--key ' '` to pass the raw DOM key.

## Wait

```bash
cmux browser <surface> wait --selector "#ready" --timeout-ms 10000
cmux browser <surface> wait --text "Done" --timeout-ms 10000
cmux browser <surface> wait --url-contains "/dashboard" --timeout-ms 10000
cmux browser <surface> wait --load-state complete --timeout-ms 15000
cmux browser <surface> wait --function "document.readyState === 'complete'" --timeout-ms 10000
```

## Design mode

```bash
cmux browser design-mode enable|status|disable --surface <surface> [--json]
```

Design mode lets a user select page elements and copy their DOM, style, URL, and screenshot context for pasting into an agent. CLI enable/disable never moves application focus or copies context automatically.

## Session, state, diagnostics

```bash
cmux browser <surface> cookies get|set|clear ...
cmux browser <surface> storage local|session get|set|clear ...
cmux browser <surface> tab list|new|switch|close ...
cmux browser <surface> state save|load <path>
cmux browser <surface> console list|clear
cmux browser <surface> errors list|clear
cmux browser <surface> highlight <selector>
cmux browser <surface> screenshot
cmux browser <surface> download wait --timeout-ms 10000
```

## Agent reliability

Use `--snapshot-after` on mutating actions to get a fresh post-action snapshot. Re-snapshot after navigation, modal open/close, or major DOM changes. Prefer short handles in output; use `--id-format both` only when a UUID must be logged or exported.

## Viewport emulation

```bash
cmux browser surface:7 viewport 1280 720
cmux browser surface:7 screenshot --out /tmp/desktop.png
cmux browser surface:7 viewport reset
```

Dimensions are limited to 1..4096 CSS pixels. cmux changes `window.innerWidth`/`window.innerHeight` and aspect-fits the page inside the existing pane; it does not resize the pane, move other surfaces, or change focus. The JSON result includes logical and displayed dimensions, scale, presentation mode, and whether the pane was resized. Screenshot PNG dimensions are exact CSS pixels on Retina and non-Retina displays.

Error cases: an unsupported viewport/page-zoom combination leaves the viewport unchanged and returns `invalid_params` with `reason: viewport_zoom_render_geometry_too_large` plus `maximum_page_zoom`. An attached browser inspector returns `invalid_state` with `reason: attached_browser_inspector`; close or detach it first. Opening or redocking an attached inspector while emulation is active resets the viewport to native sizing.

## Known WKWebView gaps (`not_supported`)

`browser.geolocation.set`, `browser.offline.set`, `browser.trace.start|stop`, `browser.network.route|unroute|requests`, `browser.screencast.start|stop`, `browser.input_mouse|input_keyboard|input_touch`.

See also [snapshot-refs.md](snapshot-refs.md), [authentication.md](authentication.md), [session-management.md](session-management.md).
