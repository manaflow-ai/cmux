# Command Reference (cmuxterm Browser)

This maps common `agent-browser` usage to `cmuxterm browser` usage.

## Direct Equivalents

- `agent-browser open <url>` -> `cmuxterm browser open <url>`
- `agent-browser goto|navigate <url>` -> `cmuxterm browser <surface> goto|navigate <url>`
- `agent-browser snapshot -i` -> `cmuxterm browser <surface> snapshot --interactive`
- `agent-browser click <ref>` -> `cmuxterm browser <surface> click <ref>`
- `agent-browser fill <ref> <text>` -> `cmuxterm browser <surface> fill <ref> <text>`
- `agent-browser type <ref> <text>` -> `cmuxterm browser <surface> type <ref> <text>`
- `agent-browser select <ref> <value>` -> `cmuxterm browser <surface> select <ref> <value>`
- `agent-browser get text <ref>` -> `cmuxterm browser <surface> get text <ref>`
- `agent-browser get url` -> `cmuxterm browser <surface> get url`
- `agent-browser get title` -> `cmuxterm browser <surface> get title`

## Core Command Groups

### Navigation

```bash
cmuxterm browser open <url>
cmuxterm browser <surface> goto <url>
cmuxterm browser <surface> back|forward|reload
cmuxterm browser <surface> get url|title
```

### Snapshot and Inspection

```bash
cmuxterm browser <surface> snapshot --interactive
cmuxterm browser <surface> snapshot --interactive --compact --max-depth 3
cmuxterm browser <surface> get text|html|value|attr|count|box|styles ...
cmuxterm browser <surface> eval '<js>'
```

### Interaction

```bash
cmuxterm browser <surface> click|dblclick|hover|focus <selector-or-ref>
cmuxterm browser <surface> fill <selector-or-ref> [text]   # empty text clears
cmuxterm browser <surface> type <selector-or-ref> <text>
cmuxterm browser <surface> press|keydown|keyup <key>
cmuxterm browser <surface> select <selector-or-ref> <value>
cmuxterm browser <surface> check|uncheck <selector-or-ref>
cmuxterm browser <surface> scroll [--selector <css>] [--dx <n>] [--dy <n>]
```

### Wait

```bash
cmuxterm browser <surface> wait --selector "#ready" --timeout-ms 10000
cmuxterm browser <surface> wait --text "Done" --timeout-ms 10000
cmuxterm browser <surface> wait --url-contains "/dashboard" --timeout-ms 10000
cmuxterm browser <surface> wait --load-state complete --timeout-ms 15000
cmuxterm browser <surface> wait --function "document.readyState === 'complete'" --timeout-ms 10000
```

### Session/State

```bash
cmuxterm browser <surface> cookies get|set|clear ...
cmuxterm browser <surface> storage local|session get|set|clear ...
cmuxterm browser <surface> tab list|new|switch|close ...
cmuxterm browser <surface> state save|load <path>
```

### Diagnostics

```bash
cmuxterm browser <surface> console list|clear
cmuxterm browser <surface> errors list|clear
cmuxterm browser <surface> highlight <selector>
cmuxterm browser <surface> screenshot
cmuxterm browser <surface> download wait --timeout-ms 10000
```

## Agent Reliability Tips

- Use `--snapshot-after` on mutating actions to return a fresh post-action snapshot.
- Re-snapshot after navigation, modal open/close, or major DOM changes.
- Prefer short handles in outputs by default (`surface:N`, `pane:N`, `workspace:N`, `window:N`).
- Use `--id-format both` only when a UUID must be logged/exported.

## Known WKWebView Gaps (`not_supported`)

- `browser.viewport.set`
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
