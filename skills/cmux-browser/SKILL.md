---
name: cmux-browser
description: End-user browser automation with cmux. Use when you need to open sites, interact with pages, wait for state changes, and extract data from cmux browser surfaces.
---

# Browser Automation with cmux

Use this skill for browser tasks inside cmux webviews.

## Core Workflow

1. Open or target a browser surface.
2. Snapshot (`--interactive`) to get fresh element refs.
3. Act with refs (`click`, `fill`, `type`, `select`, `press`).
4. Wait for state changes.
5. Re-snapshot after DOM/navigation changes.

```bash
cmux browser open https://example.com --json
# use returned surface ref, for example: surface:7

cmux browser surface:7 snapshot --interactive
cmux browser surface:7 fill e1 "hello"
cmux browser surface:7 click e2 --snapshot-after --json
cmux browser surface:7 wait --load-state complete --timeout-ms 15000
cmux browser surface:7 snapshot --interactive
```

## Surface Targeting

```bash
# identify current context
cmux identify --json

# open routed to a specific topology target
cmux browser open https://example.com --workspace workspace:2 --window window:1 --json
```

Notes:
- CLI output defaults to short refs (`surface:N`, `pane:N`, `workspace:N`, `window:N`).
- UUIDs are still accepted on input; only request UUID output when needed (`--id-format uuids|both`).
- Keep using one `surface:N` per task unless you intentionally switch.

## Wait Support

cmux supports wait patterns similar to agent-browser:

```bash
cmux browser <surface> wait --selector "#ready" --timeout-ms 10000
cmux browser <surface> wait --text "Success" --timeout-ms 10000
cmux browser <surface> wait --url-contains "/dashboard" --timeout-ms 10000
cmux browser <surface> wait --load-state complete --timeout-ms 15000
cmux browser <surface> wait --function "document.readyState === 'complete'" --timeout-ms 10000
```

## Common Flows

### Form Submit

```bash
cmux browser open https://example.com/signup --json
cmux browser surface:7 snapshot --interactive
cmux browser surface:7 fill e1 "Jane Doe"
cmux browser surface:7 fill e2 "jane@example.com"
cmux browser surface:7 click e3 --snapshot-after --json
cmux browser surface:7 wait --url-contains "/welcome" --timeout-ms 15000
cmux browser surface:7 snapshot --interactive
```

### Clear an Input

```bash
cmux browser surface:7 fill e11 "" --snapshot-after --json
cmux browser surface:7 get value e11 --json
```

### Stable Agent Loop (Recommended)

```bash
# snapshot -> action -> wait -> snapshot
cmux browser surface:7 snapshot --interactive
cmux browser surface:7 click e5 --snapshot-after --json
cmux browser surface:7 wait --load-state complete --timeout-ms 15000
cmux browser surface:7 snapshot --interactive
```

## Deep-Dive References

| Reference | When to Use |
|-----------|-------------|
| [references/commands.md](references/commands.md) | Full browser command mapping and quick syntax |
| [references/snapshot-refs.md](references/snapshot-refs.md) | Ref lifecycle and stale-ref troubleshooting |
| [references/authentication.md](references/authentication.md) | Login/OAuth/2FA patterns and state save/load |
| [references/authentication.md#saving-authentication-state](references/authentication.md#saving-authentication-state) | Save authenticated state right after login |
| [references/session-management.md](references/session-management.md) | Multi-surface isolation and state persistence patterns |
| [references/video-recording.md](references/video-recording.md) | Current recording status and practical alternatives |
| [references/proxy-support.md](references/proxy-support.md) | Proxy behavior in WKWebView and workarounds |

## Ready-to-Use Templates

| Template | Description |
|----------|-------------|
| [templates/form-automation.sh](templates/form-automation.sh) | Snapshot/ref form fill loop |
| [templates/authenticated-session.sh](templates/authenticated-session.sh) | Login once, save/load state |
| [templates/capture-workflow.sh](templates/capture-workflow.sh) | Navigate + capture snapshots/screenshots |

## Limits (WKWebView)

These commands currently return `not_supported` because they rely on Chrome/CDP-only APIs not exposed by WKWebView:
- viewport emulation
- offline emulation
- trace/screencast recording
- network route interception/mocking
- low-level raw input injection

Use supported high-level commands (`click`, `fill`, `press`, `scroll`, `wait`, `snapshot`) instead.
