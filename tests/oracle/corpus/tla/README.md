# tests/oracle/corpus/tla

Golden suite `tla` of the oracle (p15-oracle-100). Generated; do not edit. Git carries only this README: the cases are
a content-addressed tarball pinned in [`tests/oracle/corpus-store/tla.pin.json`](../../corpus-store/tla.pin.json)
(sha256 of the tarball and `tree_sha256` of its files). Every oracle tool writes them here first
(`scripts/cmux-next/oracle/corpus_store.py ensure`); when no store has the tarball, `gen_tla.py` writes them (about
15 minutes) and the result must match the pin. Regenerate and publish with:

```bash
python3 -I scripts/cmux-next/oracle/gen_tla.py            # or: oracle.py gen --suite tla
python3 -I scripts/cmux-next/oracle/gen_tla.py --check    # exit 1 when the pinned suite differs from a fresh run
python3 -I scripts/cmux-next/oracle/corpus_store.py publish tla   # upload to R2, rewrite the pin; commit the pin
```

Each case is one TLC simulate trace of a spec in `plans/cmux-next/formal/`, mapped by
[`oracle-actionmap.json`](../../../../plans/cmux-next/formal/oracle-actionmap.json) to
resource-operations-v2 calls. TLC 1.7.4 (the `tlc.sh` pin) runs each config with one worker and a fixed seed, so a
regeneration gives the same files. A case id is `<spec slug>-<config>-<nnnn>`.

| Cases | Spec | Configs | Count |
| --- | --- | --- | --- |
| `layoutrows-*` | `LayoutRows.tla` | `LayoutRows.cfg`, `LayoutRows_dock3.cfg`, `LayoutRows_2clients.cfg` | 220 |
| `tablayout-*` | `TabLayout.tla` | `TabLayout_fixed.cfg` with `MaxOps = 3` | 220 |
| `closefocus-*` | `closefocus.tla` | `closefocus-strip.cfg` | 220 |
| `ownership-*` | `OwnershipConvergence.tla` | `OwnershipConvergence.cfg` | 220 |

- `_expected-<slug>.json`: the model's abstract state after each mapped step of each case (tab and pane tokens
  `t:<id>`, `p:<id>`; container ids erased as LayoutRows' `Sig` erases them). `oracle.py` skips `_` files.
- `coverage.json`: actions and op kinds exercised per spec, the excluded ones with their reason, and per config the
  traces simulated, kept, duplicated and dropped by reason. A trace that applies an op with no product op
  (`unmapped` in the action map) is dropped and counted, never rewritten. A duplicate is a trace whose product
  form (`product_digest`: the steps without ids, notes or TLA step numbers, step refs by position, plus the
  model's states) an earlier case already has, so every case here is a distinct product run.
- `FeedHandoff.tla` and `hovercard.tla` have action maps but no cases: the feed handoff needs FeedDO (cloud-api),
  which the offline daemon has none of, and the hover card is app pointer state no op or facet carries.
  `gen_tla.py` still simulates them so their maps cover Next, and `coverage.json` lists them as excluded.

Check a run against the model (the driver checks each step's outcome; `check` adds the abstract state):

```bash
python3 -I scripts/cmux-next/oracle/gen_tla.py vm --binary "$CMUX_TUI" --jobs 64 [--spec tablayout] [--out DIR]
python3 -I scripts/cmux-next/oracle/gen_tla.py check RESULT.json tests/oracle/corpus/tla/<case>.json
```

The `view` part of a closefocus state (the window's focused pane after a close, `FocusAfterClose.pane`) is client
view state that no product checks yet: the daemon facet has none, and `driver_app.py` runs no `resource.call` step,
so a daemon run reports it as not checked and `coverage.json` lists `closefocus:view` as excluded. The app variant
of these cases, checked against the layout facet's `focusedPane`, is
[#26009](https://github.com/manaflow-ai/cmux/issues/26009).

Restarts: after a daemon restart the terminals adopt on their own threads, and a `tab.move` on a tab that is still
adopting fails at random with `layout-conservation-violation`
([#25999](https://github.com/manaflow-ai/cmux/issues/25999)). No event or read tells a client the adoption ended,
so a case cannot wait for it. Until that is fixed, three cases per spec with one `tab.move` after a restart stay
here under a `[ Pass Failure ]` line on that step in `tests/oracle/Expectations.d/tla.txt` (the generator writes
it), and the other traces with a `tab.move` after a restart are dropped and counted as `restart-race (#25999)`.

A `screen.get` read of a LayoutRows case can fail `driver_daemon.py`'s read-only check when a new shell's first
output lands during the read (2 in about 2,000 runs); that is the driver's check, not the model
([#26022](https://github.com/manaflow-ai/cmux/issues/26022)).
