# Browser REPL scenarios

Checks `cmux browser repl` against its one API
([plans/cmux-next/browser-repl](../../plans/cmux-next/browser-repl/README.md)): behavior values
against real Playwright, snapshot and printing formats against reviewed
cmux goldens.

## Layout

- `fixtures/`: pages served on two origins (`localhost` and `127.0.0.1`, so the
  peer is cross-site) by `lib/fixture-server.mjs`.
- `scenarios/NN-name.js`: REPL code in the cmux API. `PRIMARY`, `PEER`,
  `emit(key, value)` and `emitCmux(key, value)` are predefined.
  - `emit` records a behavior value; the oracle owns it.
  - `emitCmux` records a value whose format cmux defines (snapshot text,
    printing); cmux-dev owns it and a person reviews it.
  - `// ---- cell [session=NAME] [capture] [cmux-only]` starts a new call.
    Without `session` a call is one-shot (its tabs close unless kept);
    `capture` records the call's printed output as `output:N`; `cmux-only`
    cells use APIs with no Playwright counterpart and the oracle skips them.
  - A header line `// oracle: skip (<reason>)` makes a whole scenario cmux-owned.
- `goldens/NN-name.json`: `{ "oracle": {key: value}, "cmux": {key: value} }`.
- `fixtures/corpus/`: nine public pages (Wikipedia, Hacker News, a GitHub
  repository, two MDN pages, one with live-example iframes, NPR text, BBC
  News, an e-commerce listing, Vercel's marketing SPA) frozen by
  `lib/corpus.mjs capture` in logged-out headless Chrome: post-JavaScript DOM,
  scripts removed, stylesheets inlined and pruned to matching rules, fonts and
  remote images replaced, iframes inlined as `srcdoc`. `NAME.oracle.json`
  (`lib/corpus.mjs oracle`) holds what Chrome's Playwright AI snapshot lists
  as interactive and the text Chrome does not render; `size-budgets.json`
  holds the byte budget of each frozen page's snapshot. Scenario
  `27-corpus` checks recall (every Chrome interactive element, same role and
  name), leaks (no unrendered text) and size (within the budget) per page.
  Re-capture only on purpose: it changes the pages under test.
- `fixtures/stress/`: synthetic large pages (`stress.html?kind=cards|table|list|deep|iframes|shadow|text|select|virtual&n=N`),
  built by script so the same query gives the same DOM. Scenario `30-stress`
  checks Playwright behavior on them against the oracle and the print budget.
- `perf/`: `bench.mjs` times snapshots, diffs and ref resolution per page for
  cmux (dev driver or a tagged app); `report.mjs` renders `perf/results/*.json`
  as Markdown tables.
- `unit/`: `node --test` tests for the runtime,
  including `budget.test.mjs` (print budget, diff bounds, output spill) and
  `perf.test.mjs` (scaling and bounded-output guards on the stress pages).

## Backends

- `cmux-dev`: the runtime in `cmux-tui/crates/cmux-browser-host/js` in this Node process on
  Playwright WebKit through `lib/dev-driver.mjs`, behind the reference host
  (`lib/reference-host.mjs`: domain policy, secret vault, TOTP, masking, the
  contract the Rust host implements). No app build.
- `oracle`: real Playwright on headless Google Chrome (throwaway profile) with
  a thin shim of the globals (`lib/oracle.mjs`).
- `cmux`: the app's CLI, one `cmux browser repl --eval -` call per cell.
- `host-headless`, `host-cef`, `host-webkit`: the Rust browser host
  (plans/cmux-next/browser-host.md) on one engine, one call per cell:
  `$PARITY_HOST_BIN eval [--session S] --engine E -` (default
  `cmux-browser-host`), or with `PARITY_HOST_CLI=<cmux>`
  `cmux browser repl --engine E --eval -`. `host-cef` and `host-webkit` need a
  tagged no-activate app connected to the host as its engine provider. Same
  goldens as `cmux`; `gate.sh --host <engine>` adds them to the gate.

## Intentional cmux-next differences

The host backends follow cmux-next's automation lease
(plans/cmux-next/automation-lease.md), which classic and `cmux-dev` do not
have. Where the lease changes a value on purpose, the golden's `lease`
section overrides it for `host-*` backends (`{"$absent": true}`: the key is
not emitted) and `lease.reasons` names the rule. These are deliberate
differences, not regressions:

- 35-pointer-owner `names-holder`: false. Act rule: the holder's input took
  the tab's lease, so the other session's input is refused at once with
  `lease_held`, before any pointer wait; the refusal names no mouse holder.
- 37-session-context `other-session-acts`, `third-session-acts`:
  `lease-held`. Act rule: the owner session holds the tab's lease until it
  ends, so other sessions' evaluate and reload are refused.
  `owner-options-survive-another-session` is not emitted (the third session
  cannot read the owner's tab).

A golden's `backends` section overrides values for one backend only, where
that engine differs from classic on purpose (`backends.<backend>.reasons`
names why):

- 19-clipboard `late-copy` on host-headless: the late Copy fails with
  `timeout` and its result is dropped, but the tab's web content process is
  not ended (`endedWebContent: false`, `crashed: false`). host-headless runs
  Copy, Cut and Paste on the tab's clipboard, never on the browser's, so a
  late Copy cannot reach a clipboard outside the tab; WebKit ends the process
  because its late Copy would write the system clipboard.

## Commands

```sh
node tests/browser-parity/run.mjs check --backend cmux-dev     # all keys
node tests/browser-parity/run.mjs check --backend oracle       # oracle keys
node --test tests/browser-parity/unit/*.test.mjs

# A tagged app build
PARITY_CMUX_CLI=<tagged cmux CLI> CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock \
  node tests/browser-parity/run.mjs check --backend cmux

# Re-record: behavior from the oracle, then cmux formats from cmux-dev.
# Review every changed cmux value line by line before committing it.
node tests/browser-parity/run.mjs record --backend oracle
node tests/browser-parity/run.mjs record --backend cmux-dev

# Print values without comparing: run --backend <name> [--only NN] [-v]

# Corpus: freeze the pages again, then record Chrome's expectations
node tests/browser-parity/lib/corpus.mjs capture [--only NAME]
node tests/browser-parity/lib/corpus.mjs oracle [--only NAME]
```

Snapshot bytes on the corpus (cmux-dev):

| Page | cmux | Budget | Chrome AI snapshot |
| --- | ---: | ---: | ---: |
| wikipedia | 63,363 | 75,504 | 210,081 |
| hackernews | 10,045 | 13,065 | 62,999 |
| github | 61,467 | 67,798 | 227,801 |
| mdn | 20,504 | 31,276 | 73,141 |
| mdn-iframe | 43,843 | 62,001 | 146,590 |
| npr | 2,500 | 5,318 | 5,561 |
| bbc | 16,616 | 17,752 | 50,935 |
| books | 9,165 | 16,471 | 35,677 |
| vercel | 6,698 | 11,437 | 26,338 |

cmux keeps visible text such as card descriptions and times, heading anchors
and README table cells. cmux sizes include `[url=host/…]` on off-site
links. Recall is judged in the engine that renders cmux: each recorded
element is found by its path and `fixtures/corpus/gt.js` decides there whether
a user can see it (70 GitHub links an overflow box clips out are not shown in
Chrome either); no element is exempt otherwise.

Playwright loads from `PARITY_PLAYWRIGHT_DIR` or `node_modules`; `package.json`
pins the version the oracle and the corpus scripts need (`npm ci` in
`tests/browser-parity`); WebKit comes from `~/.cache/cmux-parity-browsers`.
A record refuses a scenario with an uncaught error, so goldens never hold one.
