# cmux-next diff viewer: load and parse performance

Status: measured, design chosen, prototype measured. Owner: feat-cmux-next-diff-perf.
Related: diff-host.md, pane-protocol.md, the cmux-git crate (feat-cmux-next-cmux-git), the
virtualization lane (feat-cmux-next-diff-virt).

## Method

Fixtures (`webviews/bench/perf/make-fixtures.py`, two commits each, diff `HEAD~1`, branch session):

| fixture | files | changed lines | patch |
| --- | --- | --- | --- |
| medium | 50 | 4,863 | 0.5 MB |
| large | 2,000 | 210,155 (3 added 20k-line files, 2 rewritten 20k-line files) | 19.7 MB |
| huge | 51 | 913,225 (one 100 MB generated `dist/generated/bundle.js`) | 101.4 MB |

Machine: Blacksmith Testbox, Linux x86_64, 32 vCPU, 113 GB. The release sidecar
(`cargo build --release`, opt-level z, fat LTO) runs there, under the webviews dev server
(`bun run dev`, real `cmux-diff-sidecar rpc` per request), with headless Playwright Chromium and
WebKit at 1600x1000. Each number is the median or the range of 2 to 3 warm runs after one
discarded warm-up load. Times are page-relative milliseconds (0 = navigation start). The
fixture indexes are refreshed (`git status` after 2 s) so git does not rehash racy files.

Scripts: `git-stages.sh` (git and sidecar), `js-stages.ts` (Pierre parse and full Shiki
highlighting in bun), `browser-stages.mjs` + `run-browser.sh` (page milestones, long tasks,
memory), `worker-trace.mjs` (highlight worker queue), `syntect-bench/` (Rust highlighters),
`lazy-stages.sh` (prototype sidecar calls).

## Measurements: the current pipeline

Git and sidecar (ms):

| stage | medium | large | huge |
| --- | --- | --- | --- |
| `git diff` full patch to /dev/null | 5 | 132 | 168 |
| `git diff` full patch to a file (patch write) | 6 | 142 | 251 |
| git peak RSS | 5 MB | 12 MB | 191 MB |
| sidecar `sessionOpen` total (rev-parse, merge-base, diff to file, check-attr, manifest) | 12 | 162 | 263 |
| `--name-status -z` (no file contents) | 1 | 7 | 1 |
| `--numstat -z` (reads every blob) | 4 | 106 | 135 |
| patch of the first 40 files | 4 | 29 | 4 |
| patch of the largest file | 1 | 3 | 164 |

JS off the page (bun, ms):

| stage | medium | large | huge |
| --- | --- | --- | --- |
| streamPatch + Pierre `processFile`, all files | 10 | 165 | 2,939 |
| heap after parse | 1.6 MB | 63 MB | 224 MB |
| full Shiki (oniguruma WASM) highlighting, one thread | 1.0 s | 27.0 s | 139 s |
| Shiki lines per second | 13.5k | 18.2k | 6.6k |

Page milestones, classic `/diff/` (ms; Chromium / WebKit):

| milestone | medium | large | huge |
| --- | --- | --- | --- |
| RPC `sessionOpen` returns | 20 / 19 | 170-180 / 179-191 | 252-283 / 355-370 |
| first file list row | 213 / 334-354 | 461-498 / 694-912 | 443-481 / 8,043-8,189 |
| first visible hunk | 338 / 534-563 | 904-958 / 1,174-1,190 | 682-758 / 8,211-8,344 |
| visible part highlighted | 402-416 / 575-621 | 4,720-5,271 / 5,346-5,590 | 769-857 / 8,263-8,409 |
| whole patch parsed | 243-253 / 414-455 | 919-972 / 1,026-1,049 | 6,351-6,676 / 8,043-8,189 |
| main-thread long tasks (Chromium) | 0 | 441-578, max 316 | 5,368-5,599, max 1,111 |
| JS heap (Chromium) | 38-40 MB | 242 MB | 290-1,297 MB |
| browser RSS (all processes) | 657 / 855 | 1,660 / 2,450-2,680 | 1,190-2,180 / 1,245 |

The page boot (dev modules, React, config) takes about 130-150 ms before the first RPC in
both pages; it is a floor that no diff change removes.

## Where the time goes

- medium: the page boot. All diff work is under 100 ms.
- large: the highlight queue, not the highlighter speed. `worker-trace.mjs` shows that the three
  workers get the five 20k-40k-line files first, in item order, although those files start
  collapsed ("Load diff") and are not visible. The visible 207-line file is sent at 5.5 s, 3.8 s
  after the workers are ready. Next: the full patch (162 ms in git before the RPC returns, then
  about 600 ms of streamed fetch and parse on the main thread) and memory (1.7-2.7 GB RSS).
- huge: JS text parsing of the 100 MB file on the main thread: 6.0-6.7 s with 5.4 s of long
  tasks (the UI freezes for up to 1.1 s at a time). WebKit shows nothing for 8 s. The file is
  deferred, but it is parsed anyway. Git (168 ms) is small.
- Git is not the bottleneck at any size. The JS side does work proportional to the diff before
  and around the first pixel.

## Design

Goal: the time to the first useful pixel does not grow with the diff size. Each option, with
the numbers and the strongest objection:

(a) Summary first, hunks on demand (cmux-git). The file list comes from `--name-status`
(1-7 ms, no blob reads), stats stream after it (`--numstat`, 4-135 ms), and the viewport asks
for the hunks of only its files (12 ms per batch of 24). Measured in the prototype below: the
first pixel is flat across the three sizes. Strongest objection: everything that needs all hunks
(find in diff, "expand all", accurate scroll heights) now needs either a load-all stream or Rust
support (search in Rust over the diff, heights estimated from numstat and corrected on load).
A second objection: the working-tree side is live, so a file can change between the summary and
its hunk load; the session must pin each file by blob OID or stat key and report a change
instead of mixing versions. Decision: do it.

(b) Rust parses into Pierre's structured form. After (a), JS parses only viewport files, a few
ms. A full JS parse costs 165 ms (large) and 2.9 s (huge), but (a) never runs it. Value that
remains: it removes the prototype's header rebuild, puts word-diff ranges in Rust, and makes the
reply binary-ready. Pierre accepts it: `FileDiffMetadata` is documented as a JSON-compatible
object, and CodeView items take `fileDiff` directly. Strongest objection: the type has render
fields (`splitLineStart`, `unifiedLineCount`, `hunkContent`), so Rust couples to one Pierre
version; a Pierre upgrade becomes a Rust change. Decision: later, behind a version check, only if
profiling after (a) shows parse time.

(c) Rust highlighting. Same text, one thread: Shiki 6.6-18.2k lines/s, syntect 11.4-33.6k
lines/s (TextMate family, Sublime syntaxes), tree-sitter-highlight 27-47k lines/s. On 32 threads
the large fixture takes 2.6 s (syntect) and 0.8 s (tree-sitter), but one 900k-line file stays
serial: 84 s and 18 s. So Rust is 2-3x per core, not 10x, and the measured slowness came from the
queue order. Strongest objection: a second grammar engine. syntect reads `.sublime-syntax`, not
the JSON `.tmLanguage` that user grammars in `diff/languages/` use (not tested here; a
converter would be needed), its default set has no TypeScript or Swift, and tree-sitter has a
different grammar set and theme mapping. Colors would differ from the Shiki fallback. Pierre has
no pre-tokenized input: `preferredHighlighter` is only `shiki-js` or `shiki-wasm`. The one seam is
`workerFactory`, whose message protocol (`RenderDiffRequest` in, HAST `ThemedDiffResult` out)
is internal and marked experimental. Decision: no Rust highlighting now. Fix the queue (below).
Never highlight generated or huge files by default.

(d) Transport: credit streams and binary frames. With (a) the replies are small (summary 3-148
KB, a viewport of hunks 160-260 KB of JSON). Credit-based binary streams matter for bulk data
only: load-all, search results, a full-file expansion. Strongest objection: binary framing for
sub-300 KB replies adds a codec in two languages for no measured gain. Decision: typed
pane-protocol calls with JSON for summary, stats and patches; a credit stream for load-all.
The one-shot `rpc` process per call (5-10 ms of the 9-16 ms) is replaced by a long-lived
provider, which (e) needs anyway.

(e) Cache keyed by blob OIDs, refreshed by a filesystem watch. A refresh today regenerates the
whole patch (162-263 ms) and reparses it in JS (0.6-6 s). With (a), a refresh re-reads the
summary and reloads only files whose key changed. Strongest objection: working-tree files have no
OID until git hashes them (164 ms for the 100 MB file), so the worktree side keys on
(path, size, mtime, inode) and the index or commit side on the OID. Needs a `--raw` parser in
cmux-git. Decision: with the long-lived provider, slice 4.

(f) JS keeps only the DOM of visible rows, Pierre's per-file parse of loaded files, and Shiki in
the workers with viewport priority.

## Pierre: what it accepts

- Pre-parsed input: yes. `FileDiffMetadata` is a plain object; `parsePatchFiles` output is
  "partial" and can be hydrated in place through `loadDiffFiles`.
- Lazy hunks: yes, through the uncontrolled CodeView handle: `updateItem` with a higher
  `version` replaces a placeholder item. There is no visible-range API; the prototype uses
  `renderCustomHeader` calls, which the virtualizer makes only for rendered items.
- Pre-tokenized or custom highlighter: no public API. Options: a custom `workerFactory` that
  answers the internal protocol (fragile), `@pierre/highlights` (73 WAT lexers, `LiveTokenizer`
  with `renderRange`; different lexers than TextMate, no user grammars), or an upstream hook.
- Upstream asks (pierrecomputer/pierre, our call to make): highlight requests in viewport
  order, no highlight for collapsed items, and a token-provider hook.

## Prototype: summary first, hunks on demand

Behind the cargo feature `lazy-hunks` (the shipped binary has no new code paths) and a separate
dev page (`/bench/perf/lazy/index.html`; the classic `/diff/` is unchanged). Sidecar:
`Native/DiffSidecar/src/lazy.rs`, three untyped stdio methods (`lazySummary`, `lazyStats`,
`lazyPatches`) that call only `cmux-git` (`diff::diff_args`, `parse::name_status`,
`parse::numstat`, `parse::patches`); no new git code. `lazyPatches` returns files with 2,000 or
more changed lines as `deferred`. Page: `webviews/src/diff-lazy/` with the classic Pierre options,
tree options and worker pool.

Sidecar calls including process spawn (ms):

| call | medium | large | huge |
| --- | --- | --- | --- |
| `lazySummary` | 9 | 16 | 9 |
| `lazyStats` | 10 | 112 | 146 |
| `lazyPatches`, 24 files | 12 | 12 | 13 |

Page milestones, before (classic) and after (prototype), Chromium (ms):

| milestone | medium | large | huge |
| --- | --- | --- | --- |
| first file list row | 213 -> 154-158 | 461-498 -> 180-186 | 443-481 -> 158-169 |
| first visible hunk | 338 -> 249-251 | 904-958 -> 265-284 | 682-758 -> 258-265 |
| visible part highlighted | 402-416 -> 309-313 | 4,720-5,271 -> 339-350 | 769-857 -> 302-308 |
| long tasks | 0 -> 0 | 441-578 -> 58-60 | 5,368-5,599 -> 0 |
| JS heap | 38-40 -> 26 MB | 242 -> 36-38 MB | 290-1,297 -> 26 MB |
| RSS | 657 -> 639 MB | 1,660 -> 652-661 MB | 1,190-2,180 -> 631-633 MB |

WebKit (ms):

| milestone | medium | large | huge |
| --- | --- | --- | --- |
| first file list row | 334-354 -> 227-229 | 694-912 -> 246-253 | 8,043-8,189 -> 224-227 |
| first visible hunk | 534-563 -> 386-387 | 1,174-1,190 -> 395-402 | 8,211-8,344 -> 364-382 |
| visible part highlighted | 575-621 -> 434-447 | 5,346-5,590 -> 438-448 | 8,263-8,409 -> 426-446 |
| RSS | 850-859 -> 792-798 MB | 2,450-2,680 -> 772-780 MB | 1,245 -> 783-789 MB |

The first visible lines are the same file in both pages (`dump-line.mjs`). Huge goes from 8.4 s
to 0.43 s in WebKit and large from 5.3 s to 0.34 s in Chromium.

Prototype limits: no untracked files; placeholders have header height, so the scrollbar is wrong
until files load; the tree shows no stats; deferred files show a header only, with no "Load
diff"; the header rebuild in `fileDiffFromHunks` is a stand-in for (b).

## Slice plan

1. webviews (virtualization lane, no Rust): do not send deferred or collapsed items to the
   highlighter, and send visible items first. This alone removes the 3.8 s on large.
2. cmux-git: `diff::summary` (`--raw -z` parser with OIDs and modes, plus renames),
   `diff::file_patches(repo, comparison, paths, limit)` returning each file with its header,
   `diff::merge_base_with(repo, base_ref)` for an explicit base, and a numstat-based deferral
   helper. Tests in cmux-git.
3. Sidecar: typed `sessionSummary`, `sessionStats`, `sessionPatches` in `protocol.rs`
   (generated TS types), replacing the untyped prototype methods; then the sidecar becomes a
   long-lived pane-protocol provider that holds the session (pinned base, per-file keys).
4. Protocol: `cmux.diff.session.summary`, `cmux.diff.session.patches {paths}`, a
   `cmux.diff.session.stats` event, a `cmux.diff.session.changed {paths}` event from a
   filesystem watch with the OID/stat cache (e), and a credit stream for load-all and search.
5. webviews: replace `streamPatch` with the summary model; placeholder heights from numstat;
   hunk loads from the rendered range; find and "expand all" through the load-all stream.
6. Later, only on new numbers: (b) Rust `FileDiffMetadata`; (c) Rust highlighting.

## Unverified

- The app's WKWebView and CEF on macOS: these numbers are Playwright WebKit and Chromium on
  Linux.
- The production bundle: measured on the dev server (unbundled modules, React development
  build). The shipped page loads faster; the diff-dependent stages do not change.
- A fleet Mac: the sidecar and git ran on the Linux Testbox only.
- Scroll latency into unloaded files: the prototype loads on header render; a jump test did not
  move CodeView's viewport and was discarded, so no number is reported.
- syntect with JSON `.tmLanguage` grammars, and syntect or tree-sitter color parity with Shiki.
