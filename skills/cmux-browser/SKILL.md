---
name: cmux-browser
description: End-user browser automation with cmux. Use when you need to open sites, interact with pages, wait for state changes, and extract data from cmux browser surfaces — including single-page apps (SPAs) that hydrate the DOM client-side.
---

# Browser Automation with cmux

Use this skill for browser tasks inside cmux webviews.

## Core Workflow

1. Open or target a browser surface.
2. Verify navigation with `get url` before waiting or snapshotting.
3. **For SPAs: run the hydration wait before the first snapshot** (see below).
4. Snapshot (`--interactive`) to get fresh element refs.
5. Act with refs (`click`, `fill`, `type`, `select`, `press`).
6. Wait for state changes.
7. Re-snapshot after DOM/navigation changes.

```bash
cmux --json browser open https://example.com
# use returned surface ref, for example: surface:7

cmux browser surface:7 get url
cmux browser surface:7 wait --load-state complete --timeout-ms 15000
cmux browser surface:7 snapshot --interactive
cmux browser surface:7 fill e1 "hello"
cmux --json browser surface:7 click e2 --snapshot-after
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
cmux browser surface:7 wait --selector "#ready" --timeout-ms 10000
cmux browser surface:7 wait --text "Success" --timeout-ms 10000
cmux browser surface:7 wait --url-contains "/dashboard" --timeout-ms 10000
cmux browser surface:7 wait --load-state complete --timeout-ms 15000
cmux browser surface:7 wait --function "document.readyState === 'complete'" --timeout-ms 10000
```

## SPA Hydration — Wait for Client-Side Render Before Snapshotting

> **Iron law:** for single-page apps, run the hydration wait once before
> `snapshot --interactive` or any DOM-dependent action (`click`/`fill`/`is`/`get`).
> `wait --load-state complete` alone is NOT sufficient for SPAs.

`wait --load-state complete` only guarantees network-level load (HTML, CSS, scripts).
React/Vue/Next/Nuxt/SvelteKit/Angular render the actual DOM client-side *after* that
point. A snapshot taken before hydration finishes returns only the empty shell/skeleton
tree — the pre-hydration state — and every downstream selector then misses.

Minimal, framework-agnostic hydration gate (works for both sparse login pages and dense
dashboards):

```bash
cmux browser surface:7 wait --load-state complete --timeout-ms 15000
cmux browser surface:7 wait \
  --function 'document.readyState==="complete" && !document.querySelector("[aria-busy=true],[data-loading=true]") && document.body.innerText.length>30' \
  --timeout-ms 10000
cmux browser surface:7 snapshot --interactive
```

Validate the snapshot actually hydrated — a 2-node skeleton means retry:

```bash
NODE_COUNT=$(cmux browser surface:7 eval 'document.querySelectorAll("a[href],h1,h2,h3,button,nav,article").length' | tr -d ' \n')
# < 3  -> empty shell, re-run the hydration wait (longer timeout) then re-snapshot
# >= 3 -> hydrated (sparse pages such as login/OTP are valid at 3-8 elements)
```

Full protocol — framework auto-detect, content-density tuning, and explicit-selector
control — lives in [references/spa-hydration.md](references/spa-hydration.md).

## CSP Pre-check (eval-dependent commands)

`snapshot --interactive` and `eval` execute JavaScript in the page. A page whose
Content-Security-Policy omits `unsafe-eval` can reject page-world eval. Note that
`eval "1+1"` is NOT a reliable gate: when page-world eval is CSP-blocked, cmux retries
in an isolated content world, so `1+1` still returns `2` while page globals stay
unreachable. Probe a page-global instead; full procedure in
[references/csp-precheck.md](references/csp-precheck.md).

```bash
# page-world discriminator — not "1+1"
cmux browser surface:7 eval 'String(!!window.__NEXT_DATA__ || !!document.querySelector("[data-reactroot],[data-v-app],[ng-version]"))'
```

## Common Flows

### Form Submit (with hydration wait)

```bash
cmux --json browser open https://example.com/signup
cmux browser surface:7 get url
cmux browser surface:7 wait --load-state complete --timeout-ms 15000
cmux browser surface:7 wait --function 'document.body.innerText.length>30' --timeout-ms 10000
cmux browser surface:7 snapshot --interactive
cmux browser surface:7 fill e1 "Jane Doe"
cmux browser surface:7 fill e2 "jane@example.com"
cmux --json browser surface:7 click e3 --snapshot-after
cmux browser surface:7 wait --url-contains "/welcome" --timeout-ms 15000
# destination route also hydrates client-side — wait again before snapshotting
cmux browser surface:7 wait --function 'document.body.innerText.length>30' --timeout-ms 10000
cmux browser surface:7 snapshot --interactive
```

### Clear an Input

```bash
cmux browser surface:7 fill e11 "" --snapshot-after --json
cmux browser surface:7 get value e11 --json
```

### Stable Agent Loop (Recommended)

```bash
# navigate -> verify -> wait(load) -> wait(hydrate) -> snapshot -> action -> snapshot
cmux browser surface:7 get url
cmux browser surface:7 wait --load-state complete --timeout-ms 15000
cmux browser surface:7 wait --function 'document.readyState==="complete" && document.body.innerText.length>30' --timeout-ms 10000
cmux browser surface:7 snapshot --interactive
cmux --json browser surface:7 click e5 --snapshot-after
cmux browser surface:7 snapshot --interactive
```

If `get url` is empty or `about:blank`, navigate first instead of waiting on load state.

## Deep-Dive References

| Reference | When to Use |
|-----------|-------------|
| [references/spa-hydration.md](references/spa-hydration.md) | SPA hydration protocol: framework auto-detect, content-density vs selector waits, snapshot validation |
| [references/csp-precheck.md](references/csp-precheck.md) | Detect CSP that blocks `eval`/`snapshot --interactive`, and fallbacks |
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
| [templates/spa-hydration-wait.sh](templates/spa-hydration-wait.sh) | Open + load-state + hydration wait + snapshot with validation/retry |
| [templates/e2e-login-flow.sh](templates/e2e-login-flow.sh) | Login E2E: hydrate, fill, submit, wait for destination, re-hydrate, assert |
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

## Troubleshooting

### Empty snapshot tree (2-5 nodes, no nav/content)

SPA hydration did not complete. Re-run the hydration wait with a longer timeout or an
explicit selector, then re-snapshot. See [references/spa-hydration.md](references/spa-hydration.md).

### `js_error` on `snapshot --interactive` or `eval`

Some complex pages can reject or break the JavaScript used for rich snapshots and ad-hoc evaluation.

Recovery steps:

```bash
cmux browser surface:7 get url
cmux browser surface:7 get text body
cmux browser surface:7 get html body
```

- Use `get url` first so you know whether the page actually navigated.
- Fall back to `get text body` or `get html body` when `snapshot --interactive` or `eval` returns `js_error`.
- If the page is still failing, navigate to a simpler intermediate page, then retry the task from there.
- Persistent `eval` rejection on a page that loads fine in a normal browser usually means CSP — see [references/csp-precheck.md](references/csp-precheck.md).
