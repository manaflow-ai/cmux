# CSP Pre-check

`snapshot --interactive` and `eval` run JavaScript inside the page. A
Content-Security-Policy that omits `unsafe-eval` can reject them, so eval-dependent flows
fail in a way that looks like a page bug. Probe for it before you rely on those commands.

**Related**: [SKILL.md](../SKILL.md), [spa-hydration.md](spa-hydration.md)

## Contents

- [Why it matters](#why-it-matters)
- [Three-step probe](#three-step-probe)
- [Decision](#decision)
- [Fallbacks when eval is blocked](#fallbacks-when-eval-is-blocked)

## Why it matters

The hydration protocol and rich snapshots both depend on in-page `eval`. If CSP blocks
eval, the auto-detect and content-density waits cannot run, and `snapshot --interactive`
may return `js_error`. Detecting this up front saves a confusing debugging loop.

## Three-step probe

```bash
# 1. Response header CSP — -L follows redirects (http->https, bare domain->www)
curl -sIL <target-url> | grep -i content-security-policy

# 2. Meta-tag CSP — fetch the HTML with curl, NOT via cmux eval (which is itself blocked
#    when the meta CSP omits unsafe-eval, creating a circular dependency)
curl -sL <target-url> | grep -i 'content-security-policy'

# 3. Live eval probe — open here and reuse $SURFACE downstream; do NOT re-open.
SURFACE=$(cmux browser open <target-url> | grep -oE 'surface:[0-9]+')
cmux browser "$SURFACE" wait --load-state complete --timeout-ms 10000

# Do NOT probe with `eval "1+1"` — it is NOT a reliable CSP gate. When a page's CSP
# blocks page-world eval, cmux retries the script in an isolated content world
# (WKContentWorld.defaultClient), so a context-free expression like `1+1` still
# returns 2 even though page-world eval is blocked. The isolated world cannot see
# page globals (window.__NEXT_DATA__, framework markers), which is exactly what the
# SPA auto-detect and content-density waits depend on.
#
# Probe a PAGE-WORLD-dependent expression instead — read a global the page itself sets:
cmux browser "$SURFACE" eval 'typeof window.document.title'    # "string" in either world (sanity)
cmux browser "$SURFACE" eval 'String(!!window.__NEXT_DATA__ || !!window.__NUXT__ || !!window.ng || !!document.querySelector("[data-reactroot],[data-v-app],[ng-version]"))'
```

## Decision

- Steps 1-2 show `script-src` **without** `unsafe-eval` → page-world eval likely blocked.
- Step 3, page-global probe returns a coherent value that matches what you can see on
  the page (e.g. `true` on a known SPA) → page-world eval works, proceed with the full skill.
- Step 3 errors, or returns `false`/`undefined` on a page you know is an SPA → page-world
  eval is blocked (cmux fell back to the isolated world, which cannot read page globals).
  The auto-detect and content-density waits will not work; use the selector/text-based
  fallbacks below, or drive the page with a CDP-based tool for rich interaction.

> Note: cmux's isolated-world retry is silent on the plain CLI — the output does not
> label which world produced the result. That is why a page-global probe (not `1+1`)
> is the reliable discriminator.

## Fallbacks when eval is blocked

`eval`-free commands still work — they do not inject page JavaScript:

```bash
cmux browser "$SURFACE" get url
cmux browser "$SURFACE" get text body
cmux browser "$SURFACE" get html body
cmux browser "$SURFACE" wait --selector "#ready" --timeout-ms 10000
cmux browser "$SURFACE" wait --text "Welcome" --timeout-ms 10000
cmux browser "$SURFACE" click "button[type='submit']"
```

Replace the eval-based hydration gate with selector/text waits (see
[spa-hydration.md](spa-hydration.md) → Explicit Selector Wait), and replace
`snapshot --interactive` reads with `get text body` / `get html body`.
