# Browser REPL scenarios

Checks `cmux browser repl` against its one API
([docs/browser-repl](../../docs/browser-repl/README.md)): behavior values
against real Playwright, and snapshot and printing formats against reviewed
cmux goldens. [capabilities.json](capabilities.json) maps every Aside and
ChatGPT for Chrome capability to the scenario key that proves the cmux
equivalent.

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
  as interactive and the text Chrome does not render; `aside-sizes.json`
  holds the size of Aside's snapshot of each frozen page. Scenario
  `27-corpus` checks recall (every Chrome interactive element, same role and
  name), leaks (no unrendered text) and size (within 10% of Aside) per page.
  Re-capture only on purpose: it changes the pages under test.
- `reference/`: API surfaces captured from Aside and ChatGPT for Chrome.
- `unit/`: `node --test` tests for the runtime and for capabilities.json.

## Backends

- `cmux-dev`: the runtime in `Resources/browser-repl` in this Node process on
  Playwright WebKit through `lib/dev-driver.mjs`. No app build.
- `oracle`: real Playwright on headless Google Chrome (throwaway profile) with
  a thin shim of the globals (`lib/oracle.mjs`).
- `cmux`: the app's CLI, one `cmux browser repl --eval -` call per cell.

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

Snapshot bytes on the corpus (cmux-dev, Aside CLI 1.26.916.1741):

| Page | cmux | Aside | Chrome AI snapshot |
| --- | ---: | ---: | ---: |
| wikipedia | 62,634 | 68,640 | 210,081 |
| hackernews | 10,574 | 11,878 | 62,999 |
| github | 62,821 | 61,635 | 227,801 |
| mdn | 19,929 | 28,433 | 73,141 |
| mdn-iframe | 43,485 | 56,365 | 146,590 |
| npr | 2,486 | 4,835 | 5,561 |
| bbc | 16,257 | 16,139 | 50,935 |
| books | 7,814 | 14,974 | 35,677 |
| vercel | 6,372 | 10,398 | 26,338 |

Aside's GitHub and BBC snapshots leave out visible text that cmux keeps
(card descriptions and times, heading anchors, README table cells).

Playwright loads from `PARITY_PLAYWRIGHT_DIR`, the ChatGPT app's bundled copy,
or `node_modules`; WebKit comes from `~/.cache/cmux-parity-browsers`.
A record refuses a scenario with an uncaught error, so goldens never hold one.
