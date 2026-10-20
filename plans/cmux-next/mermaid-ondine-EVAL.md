# Mermaid renderer: Ondine evaluation (2026-10-19)

User (u2481): "https://github.com/wevm/ondine should we use this? I think we might need a better
Mermaid parser … if it is good then we should migrate to it."

**Verdict: migrate, behind a flag, with Mermaid as fallback.** Ondine draws every diagram the
bundled Mermaid draws (and 215 more), about 200× faster in WebKit, its script is 23% smaller raw,
and a review of its source and package found no security issue. Our bundled Mermaid 11.4.1 has 9
open advisories (2 label XSS, 3 CSS/HTML injection, 2 infinite-loop DoS, 2 prototype pollution),
and our insertion code breaks any Mermaid diagram with HTML labels. The risk Ondine adds is age: the
repo is 2 days old, 0.0.1, one maintainer.

## 1. Mermaid in cmux-next today

| Surface | Path | Renderer |
| --- | --- | --- |
| Markdown page (`cmux.markdown`) | `webviews/src/pages/markdown/diagrams.ts` `renderMermaid` | `Resources/markdown-viewer/mermaid.min.js` (Mermaid **11.4.1**, 2.57 MB) served as `__lib/mermaid.js`, `securityLevel: "strict"` |
| Classic viewer (`shell.html`) | `Resources/markdown-viewer/shell.html` | same file |
| Agent pane / Home chat | `DiagramBlock.tsx` | **not drawn**: Mermaid stays a code block ("until the shared diagram worker draws it"; that worker does not exist) |

Sandbox: the markdown page runs under `PageCSP` `script-src 'self'` (no inline script, no
`unsafe-eval`), `img-src 'self' data:`, no `connect-src`. Mermaid runs on the page's main thread.

Bugs found:

- **HTML labels truncate the diagram.** `renderMermaid` parsed Mermaid's SVG as XML
  (`image/svg+xml`). Mermaid writes labels as HTML in `<foreignObject>` (`<br>` unclosed) and
  `xlink:href` without the namespace, so WebKit stops at the first error and shows "This page
  contains the following errors" plus the diagram up to that point. 14 of 379 corpus diagrams Mermaid
  draws hit this (every `<br>` label, sequence links, some class/c4/state diagrams).
- **9 open advisories against 11.4.1** (GitHub advisory DB, fixed in 11.10.0–11.16.1):
  GHSA-7rqq-prvp-x9jh (sequence label XSS), GHSA-8gwm-58g9-j8pw (architecture iconText XSS),
  GHSA-ghcm-xqfw-q4vr (state classDef HTML injection), GHSA-xcj9-5m2h-648r and GHSA-87f9-hvmw-gh4p and
  GHSA-6x64-9x62-f2gx (CSS injection), GHSA-6m6c-36f7-fhxh (gantt infinite loop), GHSA-2v8p-3f2j-5mp7
  (xychart infinite loop), GHSA-c4c3-pg64-4m4v (prototype pollution). The CSP blocks the script
  payloads; CSS injection and the hangs (main thread: the page freezes) are not blocked.
- 11.4.1 lacks 16 newer diagram types (block, packet, radar, sankey, treemap, venn, …).

## 2. Ondine

Mermaid source → SVG, written in Rust, compiled to WebAssembly. Ported from Pele (Obsidian's
Mermaid port); parses against Mermaid 12.1.0 grammar with an oracle test suite and a recorded list
of intentional divergences (`test/oracles/Divergences.ts`). Output is monochrome (themed with
`--ondine-*` CSS variables), monospace, square shapes; `style`/`classDef` colors are kept.

Maintenance: repo created 2026-10-18, 185 commits (jxom 120, Claude 61), 11 stars, npm `ondine`
0.0.1 published 2026-10-19 by `jmoxey`, MIT. Release cadence and longevity are unknown.

### Correctness (603-source corpus, WebKit 26, same page CSP)

Corpus: 522 examples from Mermaid's syntax docs (33 types, vendored in Ondine's test vectors), the
18 Mermaid blocks in this repo (showcase, threat model, iroh audit), 26 edge cases (Unicode,
subgraphs, classDef, markdown labels, `<br>`, 300-node chain, 400-edge dense graph, empty, bad
syntax, init directives), 37 XSS payloads.

| | Drawn | Only this one drew |
| --- | ---: | ---: |
| Ondine 0.0.1 | **594 / 603** | 215 |
| Mermaid 11.4.1 | 379 / 603 | **0** |

All 9 Ondine refusals are invalid input Mermaid also refuses (empty, "not a diagram", trailing
`-->`, `%%` after a statement, malformed `style`/`classDef`, bad ER/architecture syntax).
All 18 repo diagrams draw in both. Side-by-side screenshots (showcase flowchart, sequence, class,
state, threat model, gantt) show the same structure; Ondine's layout is tidier (orthogonal edges, no
label overlap in the threat model), Mermaid's is colored.

### Speed and size

| | Ondine | Mermaid 11.4.1 |
| --- | ---: | ---: |
| Warm render, mean over the 379 diagrams both draw (WebKit) | **0.042 ms** | 8.40 ms (~200×) |
| Cold: load module + first diagram (WebKit) | 21 ms | 25 ms |
| Largest: 3,000-edge flowchart (40 KB source, Node) | 54 ms | 229–291 ms for 300–400 edges |
| Script on disk, raw / gzip | **1.98 MB** / 0.83 MB | 2.57 MB / 0.74 MB |

Ondine ships its `all` module as base64 (the page has no `connect-src`, so it cannot fetch a
`.wasm`); the binary alone is 1.48 MB. Per-type modules (flowchart 0.32 MB) could shrink this later.
The app grows by 1.98 MB while Mermaid stays as fallback.

### Security review

- **Package:** no dependencies, no install scripts in the published `package.json`, SLSA provenance
  attestation (built by GitHub Actions `wevm/ondine/.github/workflows/main.yml` at
  `f662aa795b91bf2dfc7162f48035be3884201193`); tarball sha512 matches `dist.integrity`. The repo's own
  `postinstall` (`zile dev`) is dev-only and not in the tarball. Rust: 0 runtime crates (only `insta`,
  dev). No GitHub advisories.
- **JS glue** (`Render.js`, `internal/Wasm.js`, ~200 lines, read in full): no `eval`/`Function`/
  `fetch`/`import()`/DOM access; instantiates the module with an **empty import object**, so the
  WebAssembly code cannot reach the page, network or clock. `Mount.js` uses `innerHTML`; cmux does not
  use it.
- **Output:** 37 XSS payloads (HTML/script/`<svg onload>`/`<a href=javascript:>` in labels of 9
  types, `click` with `javascript:`, mixed case, leading spaces, entities, `data:`, `securityLevel:
  loose` init, `themeCSS`/`fontFamily` breakouts, `</text><foreignObject>` breakout, architecture
  icons, node `img:`) → no `<script>`, no `on*` attribute, no `javascript:`/`data:` URL, no
  `<foreignObject>` in any output. HTML tags in labels are dropped or escaped as text; script URLs in
  `click`/`href` are removed (Ondine's `util/url.rs` ports `@braintree/sanitize-url`); CSS values
  pass Pele's filter (`url(`, `expression(`, `javascript:`, `<>{};\`, `@import`). Mermaid 11.4.1
  under `strict` let `<img>`/`<a>`/`<svg>` elements into `<foreignObject>` (handlers stripped).
- **External URLs:** `click A "https://…"` links and node `img: "https://…"` stay in the SVG (as
  Mermaid's); the page CSP blocks remote images, and links go through the page's link routing.
- **DoS:** gantt with `tickInterval 1millisecond` over 9,999 days, zero/negative ranges, xychart
  extremes, 3,000-axis radar, 200 nested subgraphs, 3,000-edge graphs: all finish in under 60 ms.
  Source over 50,000 characters is refused (Mermaid's `maxTextSize` default). Prototype keys in init
  directives pollute nothing.

## 3. Decision and change

Rule: migrate only if at least as correct, faster or smaller, and no unfixed security issue. All
three hold, so:

- `Resources/markdown-viewer/ondine.min.js`: Ondine 0.0.1 pinned by tarball digest, rebuilt by
  `scripts/cmux-next/vendor-ondine.mjs` (never runs package code); license in `ondine.LICENSE` and
  the notices.
- `diagrams.ts`: one `renderMermaid` path. Flag `MermaidRenderer` (`"ondine"` default, page config
  `mermaidRenderer: "mermaid"` forces Mermaid). Ondine first; a refused source falls back to Mermaid;
  when both refuse, Ondine's diagnostic shows. Either SVG is parsed as HTML (fixes the truncation bug)
  and cleaned (script-like elements, `on*`, script URLs) before insertion.
- Markdown page CSP adds `'wasm-unsafe-eval'` (WebAssembly compile only; the diff and editor pages
  already have it). JavaScript `eval` stays blocked.
- Ondine's colors follow the page (`--ondine-*` from `--page-*`).

Not done here (follow-ups):

- Upgrade the Mermaid fallback to 11.16.1+ or 12.x to close its 9 advisories (a source Ondine
  refuses still reaches it), or drop the fallback once Ondine has a track record.
- Draw Mermaid in the agent pane and Home chat with the same function.
- Classic `shell.html` still uses Mermaid only.
- `bun install` here refuses packages younger than 7 days; this vendored file sidesteps that
  policy for a 1-day-old release. The digest pin, provenance and the no-import WebAssembly sandbox
  are the mitigation; re-vendor from a later release after review.

Harness (outside the repo, untrusted copies): `~/fun/scratch/ondine-eval/` (`corpus.json`,
`run.mjs`, `analyze.py`, `compare.html`, screenshots `cmp1.png`–`cmp3.png`).
