---
name: cmux-browser
description: End-user browser automation with cmux. Use when you need to open sites, interact with pages, wait for state changes, and extract data from cmux browser surfaces.
---

# Browser Automation with cmux

## Core workflow

Open or target a browser surface, verify navigation with `get url`, snapshot for fresh element refs, act on refs, wait for the state change, re-snapshot.

```bash
cmux --json browser open https://example.com     # returns a surface ref, e.g. surface:7
cmux browser surface:7 get url
cmux browser surface:7 wait --load-state complete --timeout-ms 15000
cmux browser surface:7 snapshot --interactive
cmux browser surface:7 fill e1 "hello"
cmux --json browser surface:7 click e2 --snapshot-after
cmux browser surface:7 snapshot --interactive
```

If `get url` is empty or `about:blank`, navigate first instead of waiting on load state. Re-snapshot after navigation, modal open/close, or major DOM changes; refs go stale.

## Surface targeting

`browser open` targets the workspace of the terminal running the command (`CMUX_WORKSPACE_ID`), even when another workspace is focused. Override with `--workspace` / `--window`:

```bash
cmux identify --json
cmux browser open https://example.com --workspace workspace:2 --window window:1 --json
```

Output defaults to short refs (`surface:N`, `pane:N`, `workspace:N`, `window:N`); UUIDs are accepted on input, and `--id-format uuids|both` requests them on output. Keep one `surface:N` per task.

## Wait

```bash
cmux browser <surface> wait --selector "#ready" --timeout-ms 10000
cmux browser <surface> wait --text "Success" --timeout-ms 10000
cmux browser <surface> wait --url-contains "/dashboard" --timeout-ms 10000
cmux browser <surface> wait --load-state complete --timeout-ms 15000
cmux browser <surface> wait --function "document.readyState === 'complete'" --timeout-ms 10000
```

## Viewport sizing (WKWebView)

`cmux browser <surface> viewport <width> <height>` sets an exact logical viewport from 1 to 4096 CSS pixels. The page is aspect-fitted inside its existing pane, so pane layout and focus stay unchanged, and screenshots use the requested logical dimensions. `viewport reset` returns to native pane sizing.

Close or detach the browser inspector first: its inspector-managed split layout cannot be combined with viewport emulation, and opening or redocking an attached inspector resets emulation to native sizing. Large viewport and page-zoom combinations are bounded; the command returns structured `maximum_page_zoom` details and leaves the viewport unchanged when the combination exceeds WKWebView render limits.

## Limits (WKWebView)

Offline emulation, trace/screencast recording, network route interception/mocking, and low-level raw input injection return `not_supported`; they depend on Chrome/CDP-only APIs. Use `click`, `fill`, `press`, `scroll`, `wait`, `snapshot` instead.

## Troubleshooting `js_error`

Some complex pages reject the JavaScript behind `snapshot --interactive` and `eval`. Recover by checking whether the page actually navigated, then falling back to raw text or HTML:

```bash
cmux browser surface:7 get url
cmux browser surface:7 get text body
cmux browser surface:7 get html body
```

If it still fails, navigate to a simpler intermediate page and retry from there.

## Deep-dive references

| Reference | When to Use |
|-----------|-------------|
| [references/commands.md](references/commands.md) | Full command mapping, `agent-browser` equivalents, viewport error codes |
| [references/snapshot-refs.md](references/snapshot-refs.md) | Ref lifecycle and stale-ref troubleshooting |
| [references/authentication.md](references/authentication.md) | Login/OAuth/2FA patterns and state save/load |
| [references/session-management.md](references/session-management.md) | Multi-surface isolation and state persistence |
| [references/video-recording.md](references/video-recording.md) | Recording status and practical alternatives |
| [references/proxy-support.md](references/proxy-support.md) | Proxy behavior in WKWebView and workarounds |

## Ready-to-use templates

| Template | Description |
|----------|-------------|
| [templates/form-automation.sh](templates/form-automation.sh) | Snapshot/ref form fill loop |
| [templates/authenticated-session.sh](templates/authenticated-session.sh) | Login once, save/load state |
| [templates/capture-workflow.sh](templates/capture-workflow.sh) | Navigate and capture snapshots/screenshots |
