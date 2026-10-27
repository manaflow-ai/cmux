# tests/oracle/corpus/tla

Golden suite `tla` of the oracle (p15-oracle-100). Generated; do not edit. Regenerate with:

```bash
python3 -I scripts/cmux-next/oracle/gen_tla.py            # or: oracle.py gen --suite tla
python3 -I scripts/cmux-next/oracle/gen_tla.py --check    # exit 1 when this directory is stale
```

Each case is one TLC simulate trace of a spec in `plans/cmux-next/formal/`, mapped by
[`oracle-actionmap.json`](../../../../plans/cmux-next/formal/oracle-actionmap.json) to
resource-operations-v2 calls. TLC 1.7.4 (the `tlc.sh` pin) runs each config with one worker and a fixed seed, so a
regeneration gives the same files. A case id is `<spec slug>-<config>-<nnnn>`.

| Cases | Spec | Configs | Count |
| --- | --- | --- | --- |
| `layoutrows-*` | `LayoutRows.tla` | `LayoutRows.cfg`, `LayoutRows_dock3.cfg`, `LayoutRows_2clients.cfg` | 220 |
| `tablayout-*` | `TabLayout.tla` | `TabLayout_fixed.cfg` | 220 |
| `closefocus-*` | `closefocus.tla` | `closefocus-strip.cfg` | 220 |
| `ownership-*` | `OwnershipConvergence.tla` | `OwnershipConvergence.cfg` | 220 |

- `_expected-<slug>.json`: the model's abstract state after each mapped step of each case (tab and pane tokens
  `t:<id>`, `p:<id>`; container ids erased as LayoutRows' `Sig` erases them). `oracle.py` skips `_` files.
- `coverage.json`: actions and op kinds exercised per spec, the excluded ones with their reason, and per config the
  traces simulated, kept, duplicated and dropped by reason. A trace that applies an op with no product op
  (`unmapped` in the action map) is dropped and counted, never rewritten.

Check a run against the model (the driver checks each step's outcome; `check` adds the abstract state):

```bash
python3 -I scripts/cmux-next/oracle/gen_tla.py vm --binary "$CMUX_TUI" --jobs 64 [--spec tablayout] [--out DIR]
python3 -I scripts/cmux-next/oracle/gen_tla.py check RESULT.json tests/oracle/corpus/tla/<case>.json
```

The `view` part of a closefocus state (the window's focused pane after a close, `FocusAfterClose.pane`) is client
view state: the daemon facet has none, so a daemon run reports it as not checked and the app product (its layout
facet's `focusedPane`) checks it.
