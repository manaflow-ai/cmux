# Browser REPL parity suite

Checks that `cmux browser repl` reproduces Aside's `aside repl` and the ChatGPT
for Chrome runtime: the same API, the same text representations, and real input.
Design: [docs/browser-repl](../../docs/browser-repl/README.md).

## Layout

- `fixtures/`: pages served on two origins (`localhost` and `127.0.0.1`, so the
  peer is cross-site) by `lib/fixture-server.mjs`.
- `scenarios/<dialect>/`: REPL code. `PRIMARY`, `PEER` and `emit(key, value)`
  are predefined; each `emit` is one compared value.
- `goldens/<dialect>/`: `<scenario>.json` from the reference (Aside or ChatGPT),
  `<scenario>.playwright.json` from real Playwright, and `<scenario>.choices.json`
  naming the values where the reference is wrong and another source wins, with
  a reason. `lib/goldens.mjs` merges them. Reference errors are never expected.
- `reference/`: API surfaces captured from both references.

## Commands

```sh
# Check cmux (tagged build) against every golden
PARITY_CMUX_CLI=<tagged cmux CLI> CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock \
  node tests/browser-parity/run.mjs check --backend cmux

# Re-record references
node tests/browser-parity/run.mjs record --backend aside        # needs Aside running
node tests/browser-parity/run.mjs record --backend playwright   # needs Google Chrome
PARITY_CHATGPT_CODEX_HOME=~/.codex-chatgpt \
  node tests/browser-parity/run.mjs record --backend chatgpt    # needs a ChatGPT-account Codex login

# Filter: --dialect aside|chatgpt, --only <scenario prefix>, -v for raw output
```

The Playwright backend loads Playwright from `PARITY_PLAYWRIGHT_DIR`, the
ChatGPT app's bundled copy, or `node_modules`, and runs headless Chrome with a
throwaway profile. The ChatGPT backend drives the installed Chrome extension
through `codex exec`; its tabs open in your Chrome in the agent tab group.
