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
```

Playwright loads from `PARITY_PLAYWRIGHT_DIR`, the ChatGPT app's bundled copy,
or `node_modules`; WebKit comes from `~/.cache/cmux-parity-browsers`.
A record refuses a scenario with an uncaught error, so goldens never hold one.
