# Command Reference (cmux Browser)

This maps common `agent-browser` usage to `cmux browser` usage.

## Direct Equivalents

- `agent-browser open <url>` -> `cmux browser open <url>`
- `agent-browser goto|navigate <url>` -> `cmux browser <surface> goto|navigate <url>`
- `agent-browser snapshot -i` -> `cmux browser <surface> snapshot --interactive`
- `agent-browser click <ref>` -> `cmux browser <surface> click <ref>`
- `agent-browser fill <ref> <text>` -> `cmux browser <surface> fill <ref> <text>`
- `agent-browser type <ref> <text>` -> `cmux browser <surface> type <ref> <text>`
- `agent-browser select <ref> <value>` -> `cmux browser <surface> select <ref> <value>`
- `agent-browser get text <ref>` -> `cmux browser <surface> get text <ref-or-selector>`
- `agent-browser get url` -> `cmux browser <surface> get url`
- `agent-browser get title` -> `cmux browser <surface> get title`

## Core Command Groups

### Navigation

```bash
cmux browser open <url>                        # opens in caller's workspace (uses CMUX_WORKSPACE_ID)
cmux browser open <url> --workspace <id|ref>   # opens in a specific workspace
cmux browser <surface> goto <url>
cmux browser <surface> back|forward|reload
cmux browser <surface> get url|title
```

> **Workspace context:** `browser open` targets the workspace of the terminal where the command is run (via `CMUX_WORKSPACE_ID`), even if a different workspace is currently focused. Use `--workspace` to override.

### Snapshot and Inspection

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

### Interaction

```bash
cmux browser <surface> click|dblclick|hover|focus <selector-or-ref>
cmux browser <surface> fill <selector-or-ref> [text]   # empty text clears
cmux browser <surface> type <selector-or-ref> <text>
cmux browser <surface> press|key|keydown|keyup [--key <key> | <key>]
cmux browser <surface> select <selector-or-ref> <value>
cmux browser <surface> check|uncheck <selector-or-ref>
cmux browser <surface> scroll [--selector <css>] [--dx <n>] [--dy <n>]
```

### Design Mode

```bash
cmux browser design-mode enable --surface <surface>
cmux browser design-mode status --surface <surface> --json
cmux browser design-mode disable --surface <surface>
```

Design mode lets a user select page elements and copy their DOM, style, URL, and screenshot context for pasting into an agent. CLI enable/disable never moves application focus or copies context automatically.

Keyboard names follow Playwright/W3C conventions, including `Enter`, `Tab`,
`Escape`, `ArrowLeft`, and `Space`. `Space`, `Spacebar`, and `space` all emit
DOM key `" "` with code `"Space"`; use `--key ' '` to pass the raw DOM key.

### Wait

```bash
cmux browser <surface> wait --selector "#ready" --timeout-ms 10000
cmux browser <surface> wait --text "Done" --timeout-ms 10000
cmux browser <surface> wait --url-contains "/dashboard" --timeout-ms 10000
cmux browser <surface> wait --load-state complete --timeout-ms 15000
cmux browser <surface> wait --function "document.readyState === 'complete'" --timeout-ms 10000
```

### Session/State

```bash
cmux browser <surface> cookies get|set|clear ...
cmux browser <surface> storage local|session get|set|clear ...
cmux browser <surface> tab list|new|switch|close ...
cmux browser <surface> state save|load <path>
```

### Diagnostics

```bash
cmux browser <surface> console list|clear
cmux browser <surface> errors list|clear
cmux browser <surface> highlight <selector>
cmux browser <surface> screenshot
cmux browser <surface> download wait --timeout-ms 10000
```

## Agent Reliability Tips

- Use `--snapshot-after` on mutating actions to return a fresh post-action snapshot.
- Re-snapshot after navigation, modal open/close, or major DOM changes.
- Prefer short handles in outputs by default (`surface:N`, `pane:N`, `workspace:N`, `window:N`).
- Use `--id-format both` only when a UUID must be logged/exported.

## WKWebView Viewport Emulation

Set an exact logical viewport after opening a browser surface:

```bash
cmux browser surface:7 viewport 1280 720
cmux browser surface:7 screenshot --out /tmp/desktop.png
cmux browser surface:7 viewport reset
```

The requested dimensions are limited to 1...4096 CSS pixels. cmux changes
`window.innerWidth` and `window.innerHeight`, then aspect-fits the page inside
the existing pane. It does not resize the pane, move other surfaces, or change
focus. Visible-viewport screenshots use the emulated dimensions. The JSON result
includes the logical and displayed dimensions, scale, presentation mode, and
whether the pane was resized. Screenshot PNG dimensions are exact CSS pixels on
both Retina and non-Retina displays. Combined viewport/page-zoom geometry is
bounded; unsupported combinations leave the viewport unchanged and return
`invalid_params` with `reason: viewport_zoom_render_geometry_too_large` and
`maximum_page_zoom`. Close or detach an attached browser inspector before setting
or resetting the viewport; the command otherwise returns `invalid_state` with
`reason: attached_browser_inspector`. Opening or redocking an attached inspector
while emulation is active resets the viewport to native sizing.

## Known WKWebView Gaps (`not_supported`)

- `browser.geolocation.set`
- `browser.offline.set`
- `browser.trace.start|stop`
- `browser.network.route|unroute|requests`
- `browser.screencast.start|stop`
- `browser.input_mouse|input_keyboard|input_touch`

See also:
- [snapshot-refs.md](snapshot-refs.md)
- [authentication.md](authentication.md)
- [session-management.md](session-management.md)
