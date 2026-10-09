# Browser REPL performance and large output

How fast `snapshot()` is on large pages, what an agent reads when a page is
too big to print, and how both compare with reference A, reference B and
Playwright AI snapshot. Measured 2026-09-30 on an M-series Mac (the dev machine),
the frozen corpus, synthetic stress pages and four live pages.

```sh
node tests/browser-parity/perf/bench.mjs --backend cmux-dev --pages all --label after
node tests/browser-parity/perf/bench.mjs --backend chrome   --pages all --label ref   # Playwright AI snapshot
node tests/browser-parity/perf/bench.mjs --backend reference-a --pages all --label ref   # PARITY_REFERENCE_A_CLI, one call per page
PARITY_CMUX_CLI=<tagged cmux CLI> CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock \
  node tests/browser-parity/perf/bench.mjs --backend cmux --pages all --label after
node tests/browser-parity/perf/report.mjs before-cmux after-cmux ref-chrome ref-reference-a
```

`perf/results/*.json` holds every number below. "cmux app" is the fleet
build `brepl-perf1` running the runtime from `CMUX_BROWSER_REPL_RUNTIME_DIR`:
`f38f867647b` (before this work) and this branch (after), so both columns
use the same binary. "cmux dev" is the same runtime on Playwright WebKit. Each page gets one program:
load, five full snapshots, one small change (a heading's text) and one more
snapshot, then a locator resolving the last ref. For cmux the snapshot also
reports where its time went: traversal in the page, the driver round trip,
and host work (stitching, shaping, the diff).

## Pages

Stress pages (`tests/browser-parity/fixtures/stress/stress.html`, built by
script, deterministic): `cards-50k` and `cards-200k` (cards of heading, text,
link, button; the count is DOM elements), `table-10k` (a data table of
10,000 rows), `list-5k` (a navigation list), `deep-500` and `deep-1k` (nested
divs; WebKit lays out no box past about 512 levels, so the button at the
bottom of `deep-1k` is not visible there and cmux leaves it out), `iframes-300` (100 srcdoc,
100 cross-origin, 100 same-origin frames that each nest a cross-origin one:
401 frames), `shadow-2k` (2,000 open shadow roots), `text-2m` (one text node of
2,000,000 characters), `select-5k` (a drop-down and a list box of 5,000
options), `virtual-100k` (a virtualized list of 100,000 rows, 22 rendered).
Then the nine frozen corpus pages and four live pages:
Wikipedia's list of largest cities, this PR's files view on GitHub (logged
out), an Amazon search and a Hacker News thread of about 800 comments.

## Results

In the app, the runtime of this branch against the runtime before it, same
binary:

| Page | before | after | |
| --- | ---: | ---: | --- |
| cards-50k | 3,297 ms | 427 ms | 7.7x faster; the label scan is gone |
| cards-200k | over 6 min | 2,099 ms | was quadratic |
| iframes-300 | 10,831 ms | 6,210 ms | frames read concurrently; the driver bounds the rest |
| table-10k, list-5k, shadow-2k, corpus, live | | | within noise or faster (tables below) |
| printed, list-5k | 404,210 chars | 19,959 chars | condensed; `.tree` is still 404,210 |
| printed, live Hacker News thread | 326,185 chars | 19,900 chars | about 98,000 tokens down to 6,000 |
| two large pages in one session | 7 GB and minutes (app), out of memory (Node) | one snapshot | the diff is bounded |

Where the time goes after (app, p50 of snapshots 2 to 5): `cards-50k` 279 ms
in the page, 13 ms transport, 134 ms host (shaping, render, diff);
`cards-200k` 1,470 / 104 / 512 ms; `table-10k` 224 / 24 / 121 ms. A
`cmux browser repl '1'` call costs about 50 to 60 ms end to end (process start
and socket round trip; the evaluation itself 0 ms); a reference A REPL call of `1` about
450 ms. A ref resolves through a locator in 3 to 10 ms in the app on every
page, including in-frame refs on `iframes-300` (34 ms). Ref tables over 100
snapshots of a page that replaces 200 buttons each time: at most 3,600 refs
in the app and 4,600 on the dev driver (bounded), where the dev driver grew
by 2,000 every ten snapshots before (14,800 after 100).

Reference A timings include its CLI and extension round trips; its `cards-200k`
run failed after 52 s with `fetch failed: other side closed`. Playwright AI snapshot
(`_snapshotForAI()`) timed out after 30 s on `cards-200k`. Reference B AX times
were recorded once from an offline reference renderer (reference B's
own WASM renderer fed by CDP from Node), not reference B's production path; its
sizes are exact. That renderer is no longer in this repository, so new
`--backend chrome` runs record Playwright AI snapshot only. Amazon served Playwright WebKit a bot page in the final dev run
(401 characters); the app and the other tools got the results page. The
live GitHub page was logged out everywhere except, possibly, reference A's own
browser profile, which was not inspected; reference A's 80 KB there reflects a
smaller page.

### Snapshot time, p50 of 5 (ms; first snapshot in parentheses)

| Page | cmux app before | cmux app after | cmux dev before | cmux dev after | Reference A | Playwright AI snapshot | Reference B AX |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| cards-50k | 3,297 (3,443) | 427 (527) | 4,193 (4,301) | 529 (780) | 7,374 (12,042) | 631 (3,125) | 21,897 (18,561) |
| table-10k | 471 (524) | 372 (508) | 534 (712) | 454 (619) | 1,202 (1,156) | 875 (927) | 10,889 (10,889) |
| list-5k | 107 (127) | 102 (130) | 139 (191) | 133 (199) | 1,863 (1,863) | 128 (128) | 3,835 (3,892) |
| deep-500 | 8 (25) | 7 (19) | 17 (52) | 12 (36) | 442 (293) | 14 (28) | 14 (30) |
| deep-1k | 2 (30) | 2 (24) | 8 (33) | 3 (22) | 3,899 (4,249) | 33 (152) | 24 (102) |
| iframes-300 | 10,831 (11,948) | 6,210 (6,210) | 3,403 (22,565) | 500 (3,686) | 3,494 (1,830) | 663 (4,446) | 4,745 (4,026) |
| shadow-2k | 61 (89) | 53 (83) | 82 (152) | 62 (130) | 561 (335) | 106 (143) | 1,936 (1,592) |
| text-2m | 47 (75) | 45 (53) | 85 (129) | 48 (64) | 992 (747) | 76 (56) | 2,059 (1,816) |
| select-5k | 12 (20) | 14 (24) | 15 (49) | 9 (34) | 2,346 (2,346) | 142 (142) | 2,334 (2,343) |
| virtual-100k | 2 (23) | 3 (15) | 6 (41) | 3 (25) | 325 (2,007) | 4 (11) | 15 (15) |
| wikipedia | 32 (59) | 30 (61) | 48 (100) | 28 (91) | 1,537 (667) | 58 (79) | 1,524 (1,643) |
| hackernews | 9 (22) | 9 (24) | 13 (61) | 10 (43) | 1,058 (261) | 39 (38) | 540 (293) |
| github | 38 (54) | 32 (57) | 46 (73) | 33 (72) | 624 (597) | 94 (94) | 1,303 (1,303) |
| mdn | 12 (26) | 12 (39) | 17 (63) | 13 (36) | 201 (201) | 19 (38) | 457 (267) |
| mdn-iframe | 21 (35) | 19 (39) | 27 (67) | 24 (56) | 490 (672) | 36 (52) | 866 (806) |
| npr | 3 (12) | 3 (15) | 4 (33) | 7 (27) | 89 (21) | 3 (13) | 13 (29) |
| bbc | 17 (36) | 18 (41) | 23 (109) | 19 (72) | 522 (1,405) | 81 (41) | 240 (237) |
| books | 7 (30) | 7 (21) | 11 (67) | 13 (33) | 49 (71) | 30 (32) | 548 (576) |
| vercel | 8 (34) | 8 (38) | 20 (61) | 9 (42) | 42 (36) | 15 (48) | 22 (23) |
| live-wikipedia-cities | 67 (160) | 51 (120) | 75 (225) | 60 (148) | 317 (667) | 139 (139) | 5,811 (5,055) |
| live-github-pr-files | 305 (350) | 237 (237) | 289 (495) | 255 (326) | 664 (689) | 1,670 (787) | 38,242 (14,586) |
| live-amazon-search | 50 (164) | 60 (191) | 64 (200) | 4 (23) | 353 (336) | 155 (157) | 1,292 (1,292) |
| live-hn-thread | 184 (262) | 172 (270) | 209 (437) | 215 (336) | 1,229 (1,131) | 629 (702) | 5,506 (4,770) |
| cards-200k | over 6 min | 2,099 (2,240) | over 6 min | 3,082 (3,082) | failed | timeout | not run |

### Printed characters (what the agent reads by default)

| Page | cmux app before | cmux app after | cmux dev before | cmux dev after | Reference A | Playwright AI snapshot | Reference B AX |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| cards-50k | 1,480,540 | 19,967 | 1,480,540 | 19,967 | 1,655,559 | 2,679,497 | 28,989 |
| table-10k | 533,767 | 19,864 | 533,767 | 19,864 | 299,755 | 2,543,522 | 92,749 |
| list-5k | 404,210 | 19,959 | 404,210 | 19,959 | 554,357 | 713,094 | 59,894 |
| deep-500 | 538 | 538 | 538 | 538 | 543 | 684 | 730 |
| deep-1k | 121 | 121 | 121 | 121 | 1,105 | 1,396 | 1,151 |
| iframes-300 | 29,834 | 19,876 | 29,834 | 19,876 | 29,791 | 30,964 | 41,609 |
| shadow-2k | 116,806 | 19,943 | 116,806 | 19,943 | 116,811 | 189,140 | 32,117 |
| text-2m | 2,000,181 | 5,321 | 2,000,181 | 5,321 | 2,000,186 | 2,000,154 | 2,000,443 |
| select-5k | 134,215 | 19,932 | 134,215 | 19,932 | 474,752 | 366,950 | 19,875 |
| virtual-100k | 1,715 | 1,715 | 1,715 | 1,715 | 2,267 | 3,085 | 2,576 |
| wikipedia | 62,898 | 19,855 | 63,316 | 19,855 | 68,532 | 198,392 | 118,416 |
| hackernews | 9,991 | 9,991 | 10,045 | 9,991 | 11,869 | 57,539 | 22,214 |
| github | 60,764 | 19,830 | 61,391 | 19,884 | 61,270 | 218,184 | 143,301 |
| mdn | 20,439 | 19,799 | 20,491 | 19,799 | 28,338 | 67,022 | 30,385 |
| mdn-iframe | 43,765 | 19,869 | 43,830 | 19,869 | 56,261 | 134,323 | 58,422 |
| npr | 2,499 | 2,499 | 2,500 | 2,499 | 4,835 | 5,021 | 3,861 |
| bbc | 16,586 | 16,586 | 16,616 | 16,586 | 16,126 | 48,959 | 21,272 |
| books | 8,869 | 8,869 | 9,135 | 8,869 | 14,715 | 33,233 | 18,345 |
| vercel | 6,696 | 6,696 | 6,698 | 6,696 | 10,399 | 24,880 | 2,185 |
| live-wikipedia-cities | 113,598 | 19,423 | 114,163 | 19,423 | 91,977 | 364,721 | 202,327 |
| live-github-pr-files | 397,705 | 19,594 | 401,369 | 19,594 | 80,053 | 1,381,261 | 758,856 |
| live-amazon-search | 58,861 | 19,636 | 53,606 | 401 | 68,811 | 413,126 | 87,723 |
| live-hn-thread | 326,185 | 19,900 | 319,107 | 19,902 | 399,015 | 2,692,570 | 505,687 |
| cards-200k | | 19,970 | | 19,970 | failed | timeout | not run |

### Snapshot after one change (ms)

| Page | cmux app before | cmux app after | cmux dev before | cmux dev after | Reference A | Playwright AI snapshot | Reference B AX |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| cards-50k | 3,313 | 477 | 4,379 | 506 | 2,636 | 577 | 8,285 |
| table-10k | 424 | 390 | 496 | 397 | 1,445 | 896 | 15,150 |
| list-5k | 108 | 117 | 147 | 127 | 1,227 | 120 | 6,869 |
| deep-500 | 12 | 9 | 14 | 18 | 1,099 | 11 | 14 |
| deep-1k | 1 | 2 | 12 | 9 | 1,018 | 30 | 44 |
| iframes-300 | 11,706 | 6,152 | 3,619 | 356 | 3,505 | 500 | 4,469 |
| shadow-2k | 76 | 59 | 82 | 69 | 1,025 | 94 | 1,965 |
| text-2m | 33 | 38 | 52 | 47 | 1,041 | 116 | 3,520 |
| select-5k | 11 | 32 | 12 | 17 | 1,386 | 98 | 1,612 |
| virtual-100k | 3 | 2 | 11 | 4 | 13 | 1 | 25 |
| wikipedia | 25 | 25 | 51 | 26 | 1,158 | 49 | 1,420 |
| hackernews | 13 | 9 | 12 | 13 | 1,018 | 50 | 425 |
| github | 34 | 31 | 36 | 30 | 3,988 | 64 | 1,512 |
| mdn | 11 | 11 | 18 | 13 | 69 | 15 | 584 |
| mdn-iframe | 19 | 19 | 26 | 22 | 439 | 63 | 1,265 |
| npr | 4 | 17 | 14 | 9 | 20 | 25 | 26 |
| bbc | 18 | 23 | 39 | 19 | 45 | 15 | 263 |
| books | 9 | 7 | 12 | 9 | 21 | 19 | 469 |
| vercel | 9 | 7 | 15 | 9 | 22 | 17 | 19 |
| live-wikipedia-cities | 74 | 62 | 86 | 73 | 400 | 103 | 4,508 |
| live-github-pr-files | 282 | 359 | 392 | 798 | 634 | 1,613 | 38,444 |
| live-amazon-search | 49 | 52 | 72 | 7 | 288 | 116 | 874 |
| live-hn-thread | 207 | 196 | 206 | 265 | 1,833 | 610 | 9,136 |
| cards-200k | | 2,102 | | 2,220 | failed | timeout | not run |

## Frame calls and Playwright AI snapshot (round 2)

The app with the frame registry and batched iframe resolution (fleet build
job `e2caae86412457153a5b4865`, runtime of `80e062e5051`) against the build
before it (job `201035b028490968f42acc7f`) and Playwright AI snapshot
(`_snapshotForAI()` on headless Chrome), run back to back while the
machine's load average was about 290 (other agents), so absolute numbers
are higher than in the idle runs above; compare within a row. p50 / p95 of
five snapshots in milliseconds; p95 is the first, cold snapshot on most
pages.

| Page | cmux app before | cmux app after | Playwright AI snapshot | cmux printed | Playwright AI snapshot printed |
| --- | ---: | ---: | ---: | ---: | ---: |
| iframes-300 | 6,216 / 6,980 | 179 / 686 | 155 / 4,522 | 19,876 | 30,964 |
| nested-frames | 14 / 34 | 6 / 38 | 9 / 35 | 490 | 511 |
| cards-50k | 454 / 588 | 419 / 522 | 577 / 3,105 | 19,967 | 2,679,497 |
| cards-200k | 2,229 / 2,298 | 2,224 / 2,505 | timeout (30 s) | 19,970 | |
| table-10k | | 392 / 511 | 886 / 967 | 19,864 | 2,543,522 |
| list-5k | | 123 / 158 | 160 / 257 | 19,959 | 713,094 |
| shadow-2k | | 78 / 84 | 89 / 134 | 19,943 | 189,140 |
| text-2m | | 46 / 67 | 41 / 221 | 5,321 | 2,000,154 |
| select-5k | | 12 / 32 | 112 / 197 | 19,932 | 366,950 |
| wikipedia | 28 / 54 | 33 / 54 | 68 / 91 | 19,855 | 197,896 |
| hackernews | 8 / 23 | 10 / 24 | 35 / 177 | 9,991 | 57,509 |
| github | 30 / 44 | 31 / 48 | 89 / 228 | 19,830 | 217,559 |
| mdn | 14 / 27 | 16 / 35 | 66 / 109 | 19,799 | 66,991 |
| mdn-iframe | 19 / 36 | 19 / 44 | 35 / 51 | 19,869 | 134,276 |
| npr | 3 / 25 | 3 / 15 | 3 / 19 | 2,499 | 5,020 |
| bbc | 18 / 39 | 15 / 41 | 17 / 44 | 16,586 | 48,935 |
| books | 8 / 23 | 8 / 28 | 8 / 23 | 8,869 | 32,973 |
| vercel | 8 / 42 | 9 / 35 | 12 / 57 | 6,696 | 24,862 |
| live Wikipedia cities | | 51 / 114 | 106 / 123 | 19,423 | 364,023 |
| live GitHub PR files | | 225 / 282 | 1,820 / 3,073 | 19,607 | 1,433,802 |
| live Hacker News thread | | 187 / 265 | 788 / 859 | 19,932 | 2,884,237 |

By p50, cmux is as fast as Playwright AI snapshot or faster on every page but two: on
`iframes-300` its warm p50 is 24 ms slower (its cold first snapshot is 6.6x
faster), and on `text-2m` 5 ms. On Amazon Playwright's Chrome got a
703-character bot page, so that row is left out. Playwright AI snapshot prints the
whole tree (up to 2.9 MB); cmux prints at most 20,000 characters and keeps
the rest in `.tree`. `perf/results/round2*.json` has every number.

## What was slow, and the fixes

**Naming controls was quadratic on WebKit.** Playwright's accessible-name
code reads `element.labels` for every button and input. WebKit answers that
by walking the whole document (a `LabelsNodeList` with no cache when the
page has no labels), so a page with 8,000 buttons spent 3.3 s of a 3.8 s
snapshot there, and 200,000 elements took minutes. During a synchronous read
(snapshot, locator query, `elementAt`) the page agent's own world now answers
`labels` from an index of `<label>` elements per tree, keyed by each label's
`control`, which is the HTML definition of `labels`; page scripts are not
affected. The same window turns on Playwright's aria caches (roles, names,
hidden state; its own snapshot and `getByRole` use them the same way) and a
computed-style cache. Principled: the result is what the native getter
returns, computed once instead of per control. Guarded by a scaling test
(4x the elements must take under 7x the time; it was 14x).

**The diff ran out of memory.** The Myers diff kept every step's full
frontier, O((N+M)·D) memory: snapshotting a 20,000-item page and then a
different large page in one session exhausted Node's 4 GB heap, and the
REPL in the app would do the same in JavaScriptCore. The diff now anchors on
lines that occur once in both trees (patience diff; refs make most element
lines unique), runs Myers only between anchors, keeps only the [-d, d] band
of each step, and bounds each span's work (past it the span is a
replacement). Ancestor context and changed-line pairing, which were
quadratic in the number of changes, are linear. A 100,000-line tree with one
change diffs in about 50 ms, a full rewrite of 50,000 lines in about 150 ms,
and 1,000 scattered changes in about 200 ms.

**Frames were read one after another, and every frame call read the whole
frame tree.** Each iframe cost two sequential round trips (resolve the frame,
read its tree), and the app's driver looked every frame up with WebKit's
`_frames:`, which asks every web process of the page for its frames (about
5 ms on 400 frames), also for main-frame calls once the runtime knew the main
frame's id. A burst of calls queued those reads behind each other: 100
concurrent calls to the main frame of `iframes-300` all finished together
after 526 ms, 400 did not finish in 15 s, and a snapshot with 300 frame
calls in flight never finished (CPU idle, every later call on the tab
queued too). Plain WebKit with the frame infos cached answers 400
concurrent calls in 25 ms. Now:

- `BrowserReplFrameRegistry` (CmuxBrowser) keeps one tree read per web
  view. A frame call finds its frame by id without a read (frame ids are
  stable for a frame's life); an unknown id reads once. Callers that need
  the tree as it is now (`frames.list`, iframe to frame, the owner box) get
  a read that starts after their request, and requests during a read share
  the next one, so at most one read is in flight and a burst costs at most
  two. `frames.list` reads frame names in parallel.
- `frame.contentFrames` resolves all iframes of a frame in one call (one
  evaluation in the parent, two tree reads and one concurrent position
  probe per child frame) instead of one call per iframe.
- Frame trees are read concurrently, up to 256 calls in flight, and stitched
  in document order, so ref prefixes (`f1`, `f2`) do not depend on which
  frame answered first. On `iframes-300` the app takes 137 ms at 256 in
  flight, 257 ms at 32, 549 ms at 8.
- A frame that does not answer within 10 s is left out and its iframe line
  says `[not read: timed out]`; the rest of the page still reads.

Scenario 31 guards this on the real app: 300 iframes against 30 and 400
concurrent calls against 40 must scale linearly (the old driver was 61x
for 10x the frames).

**Transport and tables.** The dev driver now returns agent results as JSON
text like the app's driver (Playwright's per-value serializer was 90% of the
time on a 5,000-item page). A closed drop-down sends only the ten options it
prints and a count. Refs and element handles are held weakly; past 5,000
entries the tables also drop elements that left the document, so a page
that keeps replacing its content does not grow them without bound (100
snapshots of a page that replaces 200 buttons each time: at most about 5,200
refs, where it had grown to 14,800 and kept growing until the engine
collected).

## Large output

What each tool does when a page or an output is too big to read. Sources:
the tools' own code and guides, and runs of each (2026-09-30).

| | Reference A (CLI 1.26.916) | Reference B | Playwright AI snapshot | cmux |
| --- | --- | --- | --- | --- |
| Default snapshot size | everything (`list-5k`: 404 KB) | AX text: first 500 children of a node, depth 200, URLs to about 4,000 characters in all; visible DOM: 20,000 characters or 200 elements | everything (`list-5k`: 713 KB); after actions it writes the snapshot to a file and returns the link | at most 20,000 characters printed, condensed; `.tree` complete |
| When cut | `maxChars` throws `Output exceeds N character limit`; per frame, so the stitched tree can exceed it | children: ` (showing 0-500 of N items)` on the parent; depth and the DOM view: nothing | not cut | a line at each cut with count, refs and scope ref, and a closing `# condensed` line |
| Per-call output | none: 5 MB printed in one call came back whole | results: strings past 200,000 characters are cut, arrays past 2,000 items are sliced | none; Claude Code saves results past 25,000 tokens to a file | 25,000 characters (`--max-output`), the rest to a file named in the output |
| Guidance | "NEVER truncate snapshot with `substring()`, `slice()`" and a runtime warning on `tree.slice()` | none | `browser_snapshot` takes `depth` and a target | `snapshot(ref)`, `{ viewport: true }`, `{ maxChars: Infinity }`, search `.tree` |

cmux's budget (`maxChars`, 20,000 characters by default, about 6,000 o200k
tokens of snapshot text) was chosen from these measurements: it prints five of
the nine frozen corpus pages whole (the median page is 16,616 characters) and
condenses the four above it and every live page measured (51,000 to 396,000
characters). With the header and a few other lines it stays under the
per-call cap, and the cap (25,000) stays under Claude Code's 30,000-character
inline limit and Codex's 10,000-token cut (about 40,000 characters), so the
harness never truncates cmux output blindly.

The condensed print keeps, in order: on-screen controls and the focused
element with their ancestors; the outline (landmarks and frames, then
headings level by level, while it fits in half the budget); then the page
in document order, where a run of six or more similar siblings (also a
repeating group, such as a card flattened into heading, text, link and
button) keeps its first three and the rest come last. Prose, text between
links, is never a run. A small subtree prints whole or not at all. Example,
`list-5k` (Wikipedia and the Hacker News thread condense the same way):

```
title: Stress list 5000
url: http://localhost:60483/stress/stress.html?kind=list&n=5000
- heading "Stress page" [level=1]
- main:
  - navigation "Items" [ref=e1]:
    - list:
      - listitem:
        - link "Item 0" [ref=e2]
        - text: "alpha"
      …
      - listitem:
        - link "Item 248" [ref=e250]
        - text: "alpha"
      - … 4,751 more listitem (4,751 refs): snapshot("e1")
# condensed to 19,662 of 404,122 characters (4,751 of 5,001 refs not shown): snapshot(ref) prints a region, snapshot({ viewport: true }) what is on screen, snapshot({ maxChars: Infinity }) or .tree everything
```

### Why this beats both references

- **Nothing is cut silently.** Reference B drops children past 500 and depth past
  200 with at most a count, and its visible-DOM view stops at 20,000
  characters without a note. Reference A prints everything, and its own guide tells
  the agent never to slice the tree, so a 5,000-item page is a 400 KB tool
  result that the harness then truncates in the middle. cmux marks every cut
  where it happens, with a count, the refs it holds and the ref to scope to.
- **The cut keeps what an agent acts on.** On-screen controls, the focused
  element and the outline survive any budget; the page reads top down; long
  runs of similar items shrink before unique content does. Reference B keeps the
  first 500 children in document order whatever they are; reference A's `maxChars`
  is an error, not a smaller answer.
- **The complete tree costs nothing to keep.** `.tree` and `.diff` are whole,
  so `s.tree.includes("Checkout")` or a regex over it reads everything without
  spending context; printing is what is budgeted. Reference A's `maxChars` removes
  the tree; reference B's caps apply before the agent sees anything.
- **The REPL, not the harness, decides what is dropped.** 25,000 characters a
  call sits under Claude Code's 30,000 (inline, then a 2,000-character
  preview) and Codex's 10,000 tokens (head and tail around a gap), so neither
  cuts cmux output. What does not fit is in a file named in the output,
  written as it arrives.
- **Refs keep working.** A ref in a condensed-away region resolves like any
  other (`page.locator("e4000")`); reference B's cut children have no index.

## Agent worlds

Each session that drives a tab has its own agent world
([driver-protocol.md](driver-protocol.md#agent-world)), and the page agent
(Playwright's injected script plus `page-agent.js`, about 400 KB) runs in
that world in every frame of every document the tab loads. Measured
2026-10-04 on the dev Mac (M-series, macOS 27.0) with real WebKit in a
package test: a page of a 40-item list and, in the second table, 10
same-site iframes each holding a form and the same list; a reload's time
(p50 of 7) and the web content process's physical footprint after the
reloads, with 0 to 8 session worlds installed. Three runs; the ranges are
over runs.

```sh
CMUX_BREPL_WORLD_COST=1 swift test --package-path Packages/macOS/CmuxBrowser --filter BrowserReplSessionWorldCostTests
```

One document a load:

| Session worlds | Reload p50 (ms) | Footprint (MB) |
| ---: | ---: | ---: |
| 0 | 2.3-3.4 | 12-13 |
| 1 | 3.2-4.3 | 21-22 |
| 2 | 3.5-3.7 | 28-29 |
| 4 | 4.4-7.5 | 34 |
| 6 | 5.9-6.4 | 46-47 |
| 8 | 6.2-8.9 | 50-62 |

Eleven documents a load (10 iframes):

| Session worlds | Reload p50 (ms) | Footprint (MB) |
| ---: | ---: | ---: |
| 0 | 12-19 | 20-22 |
| 1 | 23-32 | 63-82 |
| 2 | 26-37 | 93-112 |
| 4 | 38-48 | 229-271 |
| 6 | 44-56 | 278-391 |
| 8 | 51-59 | 354-434 |

A session world costs about 4 to 6 MB per document it is loaded in, and a
reload grows by about 2 to 5 ms per world on the 11-document page. Time is
not the limit; memory is: a page with 30 frames (ads, embeds) holds about
150 MB per session world. So at most 4 sessions drive one tab
(`BrowserReplTabSessionLimit.standard`), which keeps a 30-frame page under
about 600 MB of agent worlds; a fifth session's call on the tab fails with
`limit`. One agent with two helpers fits.

World names are not reused (WebKit has no call that clears a world in a
loaded document). Sessions that come and go on one tab (120 in a row, one
attached at a time, a reload each, 11 documents) left the footprint at
130 to 220 MB, against 93 to 103 MB when every session reused one world:
an ended session's world is not all given back while the web content
process lives, about 0.3 to 1 MB per ended session on that page (two runs
held 112 to 196 MB from the 20th session on; one climbed to 219 MB by the
100th and held). A navigation to another web content process, or the tab
closing, ends it.

## Remaining limits

- The first snapshot of a page pays for installing the page agent in every
  frame (Playwright's injected script is about 300 KB); `iframes-300` spends
  most of its first snapshot there.
- The condensed print is a heuristic. A page that is one long run of prose
  prints its top; the outline and on-screen controls still come first, and
  the notes say where the rest is, but a question about the bottom of a long
  article needs `snapshot(ref)`, `{ viewport: true }` after scrolling, or a
  search of `.tree`.
- Memory in the page is not measured: WebKit has no `performance.memory`.
  The ref and handle table sizes and the host heap are.
- Timings vary by about 30% between runs on the same machine; the scaling
  and bounded-output tests compare the runtime with itself for that reason.
