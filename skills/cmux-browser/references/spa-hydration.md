# SPA Hydration

Single-page apps render the DOM client-side *after* the network finishes loading.
This reference is the full protocol for waiting until the page is actually hydrated
before you snapshot or act on it.

**Related**: [SKILL.md](../SKILL.md), [csp-precheck.md](csp-precheck.md), [snapshot-refs.md](snapshot-refs.md)

## Contents

- [Why load-state is not enough](#why-load-state-is-not-enough)
- [The Protocol](#the-protocol)
- [Framework Auto-detect](#framework-auto-detect)
- [Content-Density Wait](#content-density-wait)
- [Explicit Selector Wait](#explicit-selector-wait)
- [Snapshot Validation](#snapshot-validation)
- [Re-hydrate After Navigation](#re-hydrate-after-navigation)

## Why load-state is not enough

```text
wait --load-state complete  =>  HTML + CSS + scripts downloaded and parsed
                                (document.readyState === "complete")
```

That gate fires *before* the framework mounts. For React/Vue/Next/Nuxt/SvelteKit/Angular
the visible DOM is built by JavaScript after `complete`. A snapshot taken at this moment
captures the skeleton/shell — typically a 2-node tree — and every selector you derive
from it misses.

## The Protocol

Run once per page (and again after every navigation):

1. **Load-state gate** — necessary, not sufficient.
2. **Detect** whether the page is an SPA.
3. **Hydration wait** — content-density (default) or explicit selector (precision).
4. **Snapshot.**
5. **Validate** the snapshot really hydrated; retry if it is an empty shell.

## Framework Auto-detect

```bash
cmux browser "$SURFACE" eval '!!(window.__NEXT_DATA__||window.__NUXT__||window.__remixContext||window.__SVELTEKIT_DATA__||window.___gatsby||window.__INITIAL_STATE__||window.ng||document.querySelector("[data-reactroot],[data-v-app],[data-server-rendered],[ng-version],[data-svelte-h],[q\\:container]"))'
```

- `true`  → SPA detected → run the content-density wait (or selector wait if you know the DOM).
- `false`/`null`/error → run the content-density wait anyway with a short timeout as a
  safety net (it passes instantly on truly static pages, so there is no penalty).

| Framework | Detection signal |
|-----------|------------------|
| Next.js   | `window.__NEXT_DATA__` |
| Nuxt.js   | `window.__NUXT__` |
| Remix     | `window.__remixContext` |
| React (CRA) | `[data-reactroot]` |
| Vue 3     | `[data-v-app]` |
| Gatsby    | `window.___gatsby` |
| SvelteKit | `window.__SVELTEKIT_DATA__` |
| Angular   | `[ng-version]` |
| Qwik      | `[q:container]` |

## Content-Density Wait

Default, framework-agnostic. Waits past the loading state until real text exists:

```bash
cmux browser "$SURFACE" wait \
  --function 'document.readyState==="complete" && !document.querySelector("[aria-busy=true],[data-loading=true]") && document.body.innerText.length>30' \
  --timeout-ms 10000
```

- `innerText.length > 30` — minimal threshold; covers sparse login/OTP/confirmation pages.
  A high threshold (e.g. `> 200`) would time out on fully-hydrated but sparse pages.
- `[aria-busy=true]`, `[data-loading=true]` — loading state cleared. Unquoted attribute
  selectors are valid per the CSS spec.

For content-rich pages (docs, dashboards) you can tighten:

```bash
cmux browser "$SURFACE" wait \
  --function 'document.readyState==="complete" && document.body.innerText.length>200 && document.querySelectorAll("a[href],button").length>5 && !document.querySelector("[aria-busy=true],[data-loading=true]")' \
  --timeout-ms 10000
```

## Explicit Selector Wait

When you know the target DOM, this is the most precise gate:

```bash
cmux browser "$SURFACE" wait --selector "nav, aside, [role='navigation']" --timeout-ms 10000
cmux browser "$SURFACE" wait --selector "main article, .content > *:not(:empty)" --timeout-ms 10000
cmux browser "$SURFACE" wait --text "API Reference" --timeout-ms 10000
```

Some sidebar-driven doc SPAs (e.g. ReadMe.io) need a class-prefix selector:

```bash
cmux browser "$SURFACE" wait --selector "[class*='Sidebar'],[class*='rm-Sidebar'],nav.sidebar" --timeout-ms 15000
```

## Snapshot Validation

After snapshotting, confirm hydration completed. A near-empty tree means retry — do not
proceed on the shell:

```bash
cmux browser "$SURFACE" snapshot --interactive

NODE_COUNT=$(cmux browser "$SURFACE" eval 'document.querySelectorAll("a[href],h1,h2,h3,button,nav,article").length' | tr -d ' \n')
if [ "${NODE_COUNT:-0}" -lt 3 ]; then
  echo "snapshot validation: only $NODE_COUNT elements — likely pre-hydration shell, retrying" >&2
  cmux browser "$SURFACE" wait \
    --function 'document.readyState==="complete" && !document.querySelector("[aria-busy=true],[data-loading=true]") && document.body.innerText.length>30' \
    --timeout-ms 15000 || { echo "hydration retry timed out — supply an explicit selector and retry" >&2; exit 1; }
  cmux browser "$SURFACE" snapshot --interactive
fi
```

- `< 3` → truly empty shell (2-node skeleton) → retry with the content-density wait.
- `>= 3` → hydrated. Sparse pages (login/OTP/confirmation) are valid at 3-8 elements;
  do not treat them as failures by setting the threshold too high.

Use a **content-density** retry, not a bare structural selector — `main`/`nav` often exist
in the pre-hydration shell, so waiting on them passes too early.

## Re-hydrate After Navigation

Every `goto`/`navigate`, and every client-side route change after a `click` that changes
the URL, lands on a page that hydrates again. Re-run the load-state + hydration wait before
the next snapshot:

```bash
cmux browser "$SURFACE" click e3 --snapshot-after
cmux browser "$SURFACE" wait --url-contains "/dashboard" --timeout-ms 15000
cmux browser "$SURFACE" wait --load-state complete --timeout-ms 15000
cmux browser "$SURFACE" wait --function 'document.body.innerText.length>100 && document.querySelectorAll("a[href],button").length>3' --timeout-ms 10000
cmux browser "$SURFACE" snapshot --interactive
```

**Never swallow a hydration timeout** (`|| true`): proceeding after a failed wait captures
the pre-hydration DOM. Fall back to an explicit selector wait or stop with an error instead.
