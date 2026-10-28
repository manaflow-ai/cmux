# cmux browser use: speed against browser-use, Playwright MCP, Stagehand and Aside

Measured 2026-10-23/24 by the computer and browser use lead's helper (a618), no model in any loop.
Scripts: [tests/automation-bench/perf/](../../tests/automation-bench/perf/) (`bench.py`, `bu_driver.py`,
`sh_driver.mjs`, `aside_bench.py`, `report.py`, `setup.sh`); fleet entry
[scripts/measure/browser-use-perf.sh](../../scripts/measure/browser-use-perf.sh) (measures only, no gate).
Related: [automation-bench.md](automation-bench.md) (this is its browser primitive leg, level 1),
[perf-lead.md](perf-lead.md).

## Short answer

cmux is not 1000x faster than the others. It is not faster at every primitive. Measured at p50:

- **cmux wins on page-state size**, which drives model cost and model latency. On a big page the cmux
  snapshot is 20,001 characters (about 5,000 tokens); Playwright MCP sends 509,985 and Stagehand 493,806 for
  the same Wikipedia article (25x more); browser-use sends 23,794. On World War II: cmux 20,014, browser-use
  27,985, Stagehand 845,049, Playwright MCP 1,096,632 (55x more). After a typed action cmux prints a diff:
  1,040 characters against 24,361 (browser-use) and 509,991 (Playwright MCP). Note: the cmux tree over
  20,000 characters is condensed (long runs of similar rows cut to the first few, with refs that still work);
  the others send everything.
- **cmux wins on navigation** on every page that loads (goto p50 88-262 ms, browser-use 159-4,064,
  Playwright MCP 121-676, Stagehand 87-372).
- **cmux wins end to end where a site tool replaces DOM steps** (YouTube top 5: one call, 2.7 s, 141 tokens
  of result; the DOM path is 3 model turns and 5,800-23,800 tokens of results page).
- **cmux loses on click, type and on the first snapshot of a new page**, and **cmux cannot open
  github.com/browser-use/browser-use at all** (20 of 20 goto timeouts). All four causes are in cmux code and
  are cheap to fix (section "Top 5 fixes"). With fixes 2 and 4 emulated in REPL code (`cmux-tuned`), the
  first snapshot of example.com goes from 561 to 24 ms and a click from 558-677 to 86-165 ms.

## Setup

- Mac: Mac17,6, Apple M5 Max, 128 GB, macOS 27.0 (26A428). This is Lawrence's laptop, shared with other
  agents: load average 97 at the start, 74 after the warm run, 69 at the end (other agents' git and
  Chromium work). All numbers carry that noise; every tool had the same noise because rounds interleave
  the tools (order reversed every other round). A network drop hit 3 rounds of every tool on 5 sites (the
  `fail` counts on goto).
- Browser for every tool: the same headless Google Chrome 155.0.8059.85 (`/Applications/Google Chrome.app`).
- cmux: `cmux-browser-host` 1.0.0 (fdf549691801) from cmux NIGHTLY, a private host on its own socket
  (`cmux`), the same host through one `cmux-browser-host eval --session` process per call (`cmux-cli`), and
  `cmux mcp serve --all-tools` tool `browser_repl_eval` through the running NIGHTLY daemon's host, headless
  engine (`cmux-mcp`). `cmux-tuned` is NOT a shipped default: the same host with two fixes emulated in REPL
  code (snapshot diff baselines cleared after each goto; `page.mouse.configure({ motion: "instant" })`).
- browser-use 0.13.11 in its own venv (uv, Python 3.12), driven with `python -I` from another directory:
  `Tools` actions (`navigate`, `click`, `input`, `send_keys`) through the action registry and
  `get_browser_state_summary(include_screenshot=False)` + `dom_state.llm_representation()`, defaults as
  shipped (0.25 s minimum page-load wait, 0.5 s network idle, 0.1 s between actions).
- Playwright MCP 0.0.83 (playwright 1.64.0-alpha) over stdio, `--headless --isolated`, defaults (every
  action answers with a snapshot and waits a 500 ms settle).
- Stagehand 4.2.1 `localBrowser` (no Browserbase, no key). Page state is `page.snapshot()`, the tree that
  `observe()` sends to the model, with no model call; click and type use the xpath that tree maps the
  element to (what `act()` runs after the model picks). Its browser connection closed after about round 9
  in the warm run ("RPC client is closed"), so its warm cells have 8-9 samples, not 20.
- In-app tabs (CEF, WebKit): **not measured**. The Performance Lead's rule is that an in-app number counts
  only through `bench_launch.py` BenchApp with `debug.cef` ready, on a fleet measure worker; that leg is not
  written yet. The fleet step for the headless legs is queued (below).
- Element choice: each tool reads its own page state, then the script finds the element there by role and
  name (cmux, Playwright MCP, Stagehand) or by tag and attributes (browser-use selector map), as an agent
  would, and acts on that ref or index. Times are wall clock from the driver's call to its answer.
- Sizes are characters; tokens are characters / 4 (the same rule for all; real tokenizers differ by tool).

## Warm primitives (20 rounds, p50 / p95 ms)

`state` is the page-state read (cmux `snapshot()`, browser-use state summary, Playwright MCP
`browser_snapshot`, Stagehand `page.snapshot()`); `state_interactive` is cmux's `snapshot({ interactive:
true })` (no equivalent elsewhere). `click` on HN navigates (link "new"). `type` on todomvc presses Enter.

| site | primitive | cmux | cmux-tuned | cmux-cli | cmux-mcp | browser-use | pwmcp | stagehand |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| example | goto | 93 / 2503 | 88 / 221 | 110 / 793 | 103 / 239 | 159 / 1766 | 121 / 638 | 87 / 172 (11 fail) |
| example | state | 561 / 842 | 24 / 98 | 530 / 1067 | 524 / 861 | 42 / 351 | 12 / 122 | 29 / 57 |
| example | state_interactive | 1637 / 3309 | 10 / 82 | 1839 / 3583 | 1794 / 3983 |  |  |  |
| hn | goto | 135 / 236 (3 fail) | 118 / 215 (2 fail) | 117 / 1059 (2 fail) | 150 / 341 (2 fail) | 396 / 1520 (2 fail) | 195 / 438 (2 fail) | 167 / 856 (11 fail) |
| hn | state | 55 / 161 | 37 / 150 | 77 / 1629 | 53 / 190 | 183 / 567 | 35 / 71 | 136 / 242 |
| hn | state_interactive | 46 / 136 | 36 / 888 | 92 / 1252 | 50 / 116 |  |  |  |
| hn | click | 677 / 1099 | 165 / 2153 | 746 / 3783 | 705 / 1087 | 885 / 1023 | 748 / 950 | 199 / 582 |
| hn | state_after_click | 49 / 486 | 51 / 167 | 59 / 1838 | 49 / 193 | 1611 / 3362 | 37 / 72 | 128 / 178 |
| wiki_rust | goto | 231 / 706 (2 fail) | 236 / 2506 (2 fail) | 434 / 2047 (2 fail) | 243 / 491 (2 fail) | 1954 / 5006 (2 fail) | 489 / 738 (2 fail) | 290 / 395 (11 fail) |
| wiki_rust | state | 1434 / 3005 | 406 / 583 | 1238 / 2782 | 1334 / 2152 | 2017 / 5273 | 201 / 297 | 894 / 2801 |
| wiki_rust | state_interactive | 1563 / 3447 | 387 / 1039 | 1666 / 2463 | 1849 / 4060 |  |  |  |
| wiki_rust | type | 565 / 702 | 563 / 2026 | 667 / 4162 | 573 / 755 | 163 / 384 | 93 / 412 | 66 / 73 |
| wiki_rust | state_after | 244 / 347 | 282 / 439 | 266 / 508 | 257 / 400 | 2084 / 4307 | 184 / 324 | 886 / 2115 |
| gh_bu | goto | fail 20/20 | fail 20/20 | fail 20/20 | fail 20/20 | 1381 / 8650 (2 fail) | 1002 / 3000 (2 fail) | 1096 / 2415 (11 fail) |
| gh_bu | state |  |  |  |  | 366 / 3944 | 60 / 88 | 314 / 474 |
| checkboxes | goto | 285 / 372 (3 fail) | 243 / 332 (3 fail) | 207 / 1371 (3 fail) | 289 / 348 (3 fail) | 372 / 4039 (3 fail) | 352 / 435 (3 fail) | 287 / 371 (12 fail) |
| checkboxes | state | 751 / 1117 | 22 / 60 | 839 / 6801 | 743 / 1792 | 50 / 1372 | 15 / 33 | 19 / 68 |
| checkboxes | state_interactive | 983 / 1370 | 13 / 158 | 1070 / 2337 | 953 / 1961 |  |  |  |
| checkboxes | click | 558 / 1099 | 94 / 153 | 650 / 938 | 595 / 743 | 843 / 963 | 1117 / 1210 | 24 / 74 |
| checkboxes | state_after_click | 6 / 53 | 20 / 50 | 39 / 168 | 15 / 41 | 69 / 126 | 8 / 19 | 9 / 67 |
| todomvc | goto | 106 / 184 (3 fail) | 96 / 140 (3 fail) | 129 / 278 (3 fail) | 91 / 183 (3 fail) | 216 / 317 (3 fail) | 152 / 289 (3 fail) | 135 / 313 (12 fail) |
| todomvc | state | 19 / 102 | 20 / 42 | 76 / 227 | 20 / 55 | 56 / 129 | 9 / 29 | 30 / 73 |
| todomvc | state_interactive | 12 / 51 | 10 / 50 | 58 / 217 | 12 / 99 |  |  |  |
| todomvc | click | 623 / 701 | 86 / 313 | 620 / 1097 | 597 / 739 | fail 17/17 | 559 / 663 | 23 / 37 |
| todomvc | state_after_click | 16 / 89 | 16 / 55 | 28 / 188 | 15 / 36 |  | 9 / 20 | 19 / 54 |
| todomvc | type | 547 / 632 | 550 / 645 | 612 / 1404 | 549 / 631 | 317 / 475 | 558 / 715 | 62 / 130 |
| todomvc | state_after | 15 / 32 | 13 / 120 | 37 / 176 | 16 / 70 | 54 / 171 | 9 / 27 | 16 / 70 |
| heavy_wiki_ww2 | goto | 262 / 1191 (3 fail) | 224 / 399 (3 fail) | 246 / 1864 (3 fail) | 250 / 435 (3 fail) | 4064 / 7193 (3 fail) | 676 / 1141 (3 fail) | 372 / 503 (12 fail) |
| heavy_wiki_ww2 | state | 1279 / 10321 | 706 / 1177 | 1284 / 2619 | 1291 / 2364 | 2917 / 5311 | 370 / 478 | 1751 / 2566 |
| heavy_wiki_ww2 | state_interactive | 3577 / 14537 | 1023 / 1847 | 2834 / 5252 | 2826 / 4376 |  |  |  |

#### Page-state size, first read (characters / approx tokens at 4 chars per token)

| site | read | cmux | cmux-tuned | cmux-cli | cmux-mcp | browser-use | pwmcp | stagehand |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| example | state | 1,060 / 265 | 1,060 / 265 | 1,060 / 265 | 1,060 / 265 | 1,007 / 252 | 1,288 / 322 | 1,305 / 326 |
| example | state_interactive | 99 / 25 | 99 / 25 | 99 / 25 | 99 / 25 |  |  |  |
| hn | state | 9,988 / 2,497 | 9,988 / 2,497 | 9,988 / 2,497 | 9,988 / 2,497 | 13,163 / 3,291 | 49,277 / 12,319 | 34,366 / 8,592 |
| hn | state_interactive | 8,856 / 2,214 | 8,856 / 2,214 | 8,856 / 2,214 | 8,856 / 2,214 |  |  |  |
| hn | state_after_click | 11,635 / 2,909 | 11,635 / 2,909 | 11,635 / 2,909 | 11,635 / 2,909 | 14,901 / 3,725 | 58,645 / 14,661 | 37,905 / 9,476 |
| wiki_rust | state | 20,001 / 5,000 | 20,001 / 5,000 | 20,001 / 5,000 | 20,083 / 5,021 | 23,794 / 5,948 | 509,985 / 127,496 | 493,806 / 123,452 |
| wiki_rust | state_interactive | 20,045 / 5,011 | 20,045 / 5,011 | 20,045 / 5,011 | 20,127 / 5,032 |  |  |  |
| wiki_rust | state_after | 1,040 / 260 | 2,156 / 539 | 2,156 / 539 | 1,040 / 260 | 24,361 / 6,090 | 509,991 / 127,498 | 497,819 / 124,455 |
| gh_bu | state |  |  |  |  | 21,607 / 5,402 | 64,413 / 16,103 | 60,602 / 15,150 |
| checkboxes | state | 448 / 112 | 448 / 112 | 448 / 112 | 448 / 112 | 389 / 97 | 878 / 220 | 599 / 150 |
| checkboxes | state_interactive | 348 / 87 | 348 / 87 | 348 / 87 | 348 / 87 |  |  |  |
| checkboxes | state_after_click | 187 / 47 | 187 / 47 | 187 / 47 | 187 / 47 | 388 / 97 | 888 / 222 | 609 / 152 |
| todomvc | state | 484 / 121 | 885 / 221 | 797 / 199 | 484 / 121 | 322 / 80 | 841 / 210 | 615 / 154 |
| todomvc | state_interactive | 339 / 85 | 613 / 153 | 566 / 142 | 339 / 85 |  |  |  |
| todomvc | state_after | 411 / 103 | 330 / 82 | 330 / 82 | 411 / 103 | 419 / 105 | 1,723 / 431 | 1,397 / 349 |
| todomvc | state_after_click | 466 / 116 | 425 / 106 | 425 / 106 | 466 / 116 |  | 1,831 / 458 | 1,547 / 387 |
| heavy_wiki_ww2 | state | 20,014 / 5,004 | 20,014 / 5,004 | 20,014 / 5,004 | 20,096 / 5,024 | 27,985 / 6,996 | 1,096,632 / 274,158 | 845,049 / 211,262 |
| heavy_wiki_ww2 | state_interactive | 19,987 / 4,997 | 19,987 / 4,997 | 19,987 / 4,997 | 20,069 / 5,017 |  |  |  |

Notes on the warm table:

- gh_bu: cmux failed 20 of 20 (`Timed out waiting for navigation`); fix 1 below. The others loaded it.
- todomvc click for browser-use: its selector map after the typed todo had no index for the item's toggle
  checkbox (17 of 17); the item text shows, the checkbox does not get an index.
- cmux `state` right after a goto to a small page (example 561 ms, checkboxes 751 ms) is the cost of a diff
  against the previous page's tree, not of reading the page: `cmux-tuned` reads the same pages in 24 and
  22 ms. Fix 2.
- Playwright MCP click (559-1,117 ms) includes its default 500 ms settle wait and the snapshot it returns
  with every action; with `--snapshot-mode none` it is lower. Stagehand click and type (23-199 ms, 62-66 ms)
  wait for nothing after the input.

## Cold start (20 runs, a new host or server and a new browser each run, to example.com loaded)

`cold_total` is from process start; `cold_browser` from the driver's start call (browser launch + first
goto).

| site | primitive | cmux | browser-use | pwmcp | stagehand |
| --- | --- | --- | --- | --- | --- |
| example | cold_total | 1369 / 2113 | 3472 / 5390 | 1369 / 1962 | 2144 / 2824 |
| example | cold_browser | 1354 / 2100 | 1921 / 2963 | 1045 / 1510 | 1633 / 2194 |

cmux ties Playwright MCP at p50 (1,369 ms each), is 1.6x faster than Stagehand and 2.5x faster than
browser-use. Under the heavier load of the first probe runs, cmux cold was 3.5-4.3 s, of which
`browser.repl.open` (browser launch and attach) was 2.2-3.1 s while a bare `chrome --headless` reached
"DevTools listening" in 0.46-0.95 s; the first goto on a new browser then took 1.0-1.5 s against 0.24 s
for the second. See fix 5.

## End to end: "top 5 YouTube results for rust programming" (10 runs)

cmux: one call, `await sites.youtube.search("rust programming", { limit: 5 })`, 5 results with title, URL,
channel, duration, views (565 characters, about 141 tokens). The others: the DOM steps an agent would take
(open youtube.com, read, type the query + Enter, read the results page). Each read is followed by a model
turn in a real agent; the bench waits a fixed 1.5 s before each read (not counted) instead.

| site | primitive | cmux | cmux-mcp | browser-use | pwmcp | stagehand |
| --- | --- | --- | --- | --- | --- | --- |
| youtube | site_tool | 2710 / 4809 | 2613 / 5273 |  |  |  |
| youtube | dom_goto |  |  | 1006 / 1486 | 579 / 1988 | 430 / 1122 |
| youtube | dom_state1 |  |  | 186 / 462 | 31 / 54 | 85 / 145 |
| youtube | dom_type_enter |  |  | 952 / 1230 | 1631 / 1851 | 61 / 97 |
| youtube | dom_state2 |  |  | 1052 / 2529 | 102 / 144 | 436 / 688 |

Results-page size the model must read: browser-use 23,087 characters (5,772 tokens), Stagehand 38,233
(9,558), Playwright MCP 95,278 (23,820), against 565 for the cmux site tool.

- Tool time alone (no model): Stagehand's 4 steps sum to about 1.0 s, Playwright MCP about 2.3 s,
  browser-use about 3.2 s; the cmux site tool is 2.7 s (p95 4.8 s). So **without a model, Stagehand's DOM
  path is faster than the cmux site tool**; the site tool makes several YouTube requests.
- With a model (estimate, not measured): the DOM path needs at least 3 model turns (after the home page,
  after the results page, and the answer), each reading 1-24 k tokens; at an estimated 1.5-4 s per turn
  that adds 4.5-12 s, so about 6-15 s in total against about 2.7 s + 1 turn (1.5-4 s) for cmux: about
  2-4x faster end to end and 40-170x fewer result tokens.

## cmux against Aside (public pages only)

`aside repl` opened its own new tab with `openTab(url)` on example.com, Hacker News and Wikipedia, ran 2
rounds of goto / snapshot / interactive snapshot (and a click on HN's "new" link) inside the same call,
then `closeTab()`; it never listed or attached to the person's tabs. The same script body ran in a private
cmux headless host. Times are measured inside the REPL (`Date.now()`); `call_wall` is the whole CLI call.
Only 2 samples per cell: the 20-sample run found Aside not running ("Aside isn't running on this
machine"), and the bench does not start the person's browser. Aside runs in a visible browser, cmux in
headless Chromium, so this compares setups, not only code.

| site | primitive | cmux | aside |
| --- | --- | --- | --- |
| example | goto | 230 / 387 | 206 / 226 |
| example | state | 21 / 30 | 36 / 41 |
| example | state_interactive | 9 / 14 | 26 / 42 |
| example | call_wall | 562 / 562 | 7284 / 7284 |
| hn | goto | 106 / 141 | 159 / 169 |
| hn | state | 36 / 41 | 161 / 185 |
| hn | state_interactive | 68 / 80 | 50 / 54 |
| hn | click | 592 / 620 | 472 / 493 |
| hn | call_wall | 1611 / 1611 | 3353 / 3353 |
| wiki_rust | goto | 265 / 402 | 346 / 355 |
| wiki_rust | state | 880 / 1346 | 720 / 772 |
| wiki_rust | state_interactive | 1842 / 2031 | 564 / 615 |
| wiki_rust | call_wall | 5975 / 5975 | 5897 / 5897 |

#### Page-state size, first read (characters / approx tokens at 4 chars per token)

| site | read | cmux | aside |
| --- | --- | --- | --- |
| example | state | 1,059 / 265 | 265 / 66 |
| example | state_interactive | 98 / 24 | 324 / 81 |
| hn | state | 9,989 / 2,497 | 13,523 / 3,381 |
| hn | state_interactive | 8,857 / 2,214 | 11,727 / 2,932 |
| wiki_rust | state | 19,952 / 4,988 | 16,413 / 4,103 |
| wiki_rust | state_interactive | 19,930 / 4,982 | 16,380 / 4,095 |

In the 20-sample run (cmux side only, same script) cmux read Wikipedia in 376 / 650 ms (full) and
648 / 1,295 ms (interactive). Aside is faster than cmux on Wikipedia's interactive snapshot (564 against
648-1,842 ms) and on the HN click (472 against 592 ms); cmux is faster on HN's full snapshot (36 against
161 ms) and on HN and Wikipedia goto (Aside is faster on example.com goto, 206 against 230 ms); a whole Aside CLI call costs 3.4-7.3 s against 0.6-1.6 s for cmux on small pages.

## CLI and MCP overhead

`cmux-mcp` (through `cmux mcp serve` and the daemon's host) is within noise of the direct socket at p50
(goto HN 150 against 135 ms, snapshot HN 53 against 55 ms): the MCP path adds no real cost.
`cmux-cli` (a new `cmux-browser-host eval` process per call) adds about 20-60 ms at p50 and much more at
p95 under load (HN snapshot p95 1,629 against 161 ms): process start on a busy Mac. Agents that make many
calls should use the MCP tool or one session socket, not one CLI process per call.

## Where cmux wins (p50)

| What | cmux | best other | factor |
| --- | --- | --- | --- |
| Page-state size, Wikipedia Rust | 20,001 chars | browser-use 23,794; Playwright MCP 509,985 | 1.2x / 25x fewer tokens |
| Page-state size, Wikipedia WW2 | 20,014 | browser-use 27,985; Stagehand 845,049; Playwright MCP 1,096,632 | 1.4x / 42x / 55x |
| Page-state size, HN | 9,988 | browser-use 13,163; Stagehand 34,366; Playwright MCP 49,277 | 1.3x / 3.4x / 4.9x |
| State after typing (Wikipedia) | 1,040 (diff) | browser-use 24,361 | 23x |
| goto, Wikipedia WW2 | 262 ms | Stagehand 372, Playwright MCP 676, browser-use 4,064 | 1.4x / 2.6x / 15x |
| goto, Wikipedia Rust | 231 ms | Stagehand 290, Playwright MCP 489, browser-use 1,954 | 1.3x-8.5x |
| Snapshot after an action (HN after click) | 49 ms | Stagehand 128, browser-use 1,611 (Playwright MCP is faster: 37) | 2.6x / 33x |
| Cold start | 1,369 ms | Playwright MCP 1,369, Stagehand 2,144, browser-use 3,472 | 1x / 1.6x / 2.5x |
| YouTube top 5 with a model (estimate) | about 4-7 s | about 6-15 s | about 2-4x |

## Where cmux loses (p50), and why

| What | cmux | faster tool | cause in cmux |
| --- | --- | --- | --- |
| goto github.com/browser-use/browser-use | fails 20/20 (30 s timeout) | Playwright MCP 1,002 ms | fix 1: navigation.rs:86 |
| First snapshot on a new small page | example 561, checkboxes 751 ms | Playwright MCP 12 / 15 ms | fix 2: snapshot.js:1225-1233 |
| First interactive snapshot on a new page | example 1,637 ms | (tuned cmux 10 ms) | fix 2, twice (interactive also diffs the full tree) |
| type (fill) | 547-565 ms | Stagehand 62-66, Playwright MCP 93 ms | fix 3: evaluate.rs:21,98 via gate.rs:511 |
| click | 558-677 ms | Stagehand 24-199 ms | fix 4: human-mouse.js:16, runtime-core.js:2718-2731 |
| Full snapshot, big page (Wikipedia Rust, WW2) | 1,434 / 1,279 ms (tuned 406 / 706) | Playwright MCP 201 / 370 ms | fix 2 for most; the rest is fix 5 (capture) |
| Interactive snapshot, Wikipedia (Aside) | 648-1,842 ms | Aside 564 ms | fix 2 and capture cost |
| YouTube, tool time only (no model) | 2,710 ms (one call) | Stagehand DOM steps about 1,000 ms | the site tool's several requests |

## Top 5 fixes, with expected gains

1. **goto never returns when the page changes its URL in the same document after load** (GitHub's
   `replaceState`, todomvc's `#/` without the hash in the URL). `Inner::navigate` waits for
   `tab.nav_seq > before && !tab.last_nav_same_document && reached(...)`
   (cmux-tui/crates/cmux-browser-host/src/cdp/navigation.rs:84-88), but `Page.navigatedWithinDocument`
   bumps `nav_seq` and sets `last_nav_same_document = true` (src/cdp/state.rs:572-578) after the real
   navigation committed, so the condition stays false until the 30 s timeout although the document loaded
   (`document.readyState` was `complete`; 4 `framenavigated` events in the first 1.6 s). Fix: count
   cross-document commits separately (`doc_seq`) and wait for `doc_seq > before_doc && reached(...)`.
   Gain: GitHub (and every SPA that rewrites its URL on load) from a 30 s failure to about 1 s.
2. **A snapshot diffs against the previous document's tree.** The baseline key is
   `[scope, interactive, showHidden, options, urls, viewport]` with no document identity
   (js/snapshot.js:1225), so the first snapshot after a goto runs the patience/Myers diff
   (js/snapshot.js:597-725, `myersSpan` at 672, work bound 20,000,000 steps) between two unrelated pages,
   and an interactive snapshot also diffs the full tree (js/snapshot.js:1233). Fix: drop the page's
   baselines on a main-frame cross-document navigation (or key them by the document's loader id), and skip
   the diff when the header URL changed. Gain, measured with `cmux-tuned`: example 561 -> 24 ms,
   checkboxes 751 -> 22 ms, interactive 1,637 -> 10 ms, Wikipedia Rust 1,434 -> 406 ms, WW2 1,279 -> 706 ms.
3. **The first typed input on each document waits 500 ms.** The gate measures the focused element for the
   agent cursor overlay (`typing_details` -> `measure_focus`, src/gate.rs:511, 528-532) with a
   `frame.evaluate` in the host world; the host world is never created on a new document, so
   `Inner::context` waits the whole `CONTEXT_GRACE` (src/cdp/evaluate.rs:21, 98) before it calls
   `Page.createIsolatedWorld`. Probe: `insertText` 518 ms first, 3-8 ms after; `fill` 528 then 12 ms.
   Fix: create the host world with the agent world at frame setup (src/cdp/driver.rs:626 adds only
   `AGENT_WORLD`), or skip the grace for `World::Host` as fetch shells already do (evaluate.rs:97-98).
   Gain: type 550 -> about 60 ms (Stagehand's level).
4. **Agent clicks play a human pointer path in headless tabs nobody sees.** The default motion is
   `"human"` (js/human-mouse.js:16): a Fitts-law glide, 40-110 ms dwell and 50-110 ms press hold per click
   (js/runtime-core.js:2716-2731). Fix: default to `"instant"` for headless tabs (keep `"human"` for a
   visible in-app tab, where the person watches the cursor). Gain, measured: click 558-677 -> 86-165 ms.
5. **Capture cost on big pages and the cold launch.** Tuned cmux still reads Wikipedia in 406 ms and WW2
   in 706 ms against Playwright MCP's 201 and 370 ms (which reads 25-55x more text). `_timing` on Wikipedia:
   agent 140-171 ms, CDP call 198-278 ms per frame (js/snapshot.js:1068-1071), so most of it is moving the
   node list across CDP, and the first `String(snapshot)` print added 157 ms. Fix: build the compact text
   (or a packed node array) inside the page agent and return one string. Expected about 2x on big pages.
   Cold: `browser.repl.open` took 2.2-3.1 s under load while Chrome itself starts in 0.5-0.9 s; the launch
   sets up and then closes Chromium's start tab (src/headless_source.rs:99-106) before the first real tab
   gets the same setup (likely part of it; not traced). A trace of `HeadlessSource::launch` is the next step.

Also: `cmux-cli` per-call process cost at p95 (use MCP or one socket); and the YouTube site tool's tool-only
time (2.7 s) is above Stagehand's DOM path (1.0 s), worth a look at its request count.

## Fleet run and the perf cron

- `scripts/measure/browser-use-perf.sh` builds `cmux-browser-host` at the ref (release), installs the three
  competitors at pinned versions under the step, finds Chrome (or installs Chrome for Testing through
  playwright-core), and runs the warm, cold and YouTube legs; it prints `BROWSER-USE-PERF` lines and writes
  `browser-use-perf.json`. It never fails on a number. Command:
  `cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/browser-use-perf.sh --ref SHA --artifact browser-use-perf.json --timeout 7200`.
- Step e64b54ef1da8dfae06234aa5 (ref 441f5a3955e; it replaced 53c8a51b5bfe at eac20cff835, cancelled
  after 80 min in the queue) was queued on the measure lane when this was written; no fleet numbers yet. The local numbers above are from the laptop under load.
- Not done: the in-app CEF/WebKit leg through `bench_launch.py` BenchApp with the `debug.cef` ready check,
  and Release signposts for app-side timing (the headless host has no app side).

## Reproduce

```
tests/automation-bench/perf/setup.sh /tmp/cu-bench
cd /tmp && python3 -I <repo>/tests/automation-bench/perf/bench.py --runs 20 --tools cmux,cmux-cli,cmux-tuned,cmux-mcp,browser-use,pwmcp,stagehand --out OUT
python3 -I <repo>/tests/automation-bench/perf/bench.py --cold 20 --tools cmux,browser-use,pwmcp,stagehand --out OUT
python3 -I <repo>/tests/automation-bench/perf/bench.py --task youtube --runs 10 --tools cmux,cmux-mcp,browser-use,pwmcp,stagehand --out OUT
python3 -I <repo>/tests/automation-bench/perf/aside_bench.py --runs 20 --per-call 10 --out OUT   # needs Aside running
python3 -I <repo>/tests/automation-bench/perf/report.py OUT
```

Every process the scripts start is stopped by its own pid (the host's process group holds its Chromium).
