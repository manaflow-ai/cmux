# Oracle snapshot schema v1

The refactor oracle (plans/cmux-next/chrome-parity/p15-oracle.md, section 3A) records one snapshot at each
checkpoint of a case. A refactor must give the same normalized snapshots at the base SHA and at the head SHA.

| File | What it is |
| --- | --- |
| `snapshot-v1.schema.json` | The snapshot: `schema`, `meta`, `facets`. JSON Schema draft-07 plus the `x-oracle-*` annotations below. |
| `fixtures/snapshot-example.json` | One settled checkpoint of an app case with all 20 facets (`webviews` as not-comparable). |

A snapshot holds semantic state, never pixels. Private text (terminal content, drafts, find queries) is
recorded only as `sha256:<hex>`.

## Shape

- `schema` is `cmux.oracle.snapshot/v1`.
- `meta` is the run identity that the runner writes: case, step, checkpoint, product, SHA, host, clock.
- `facets` holds the facets that the case asked for. Each facet is its object, or
  `{"status": "not-comparable", "reason": "...", "task": "p15-oracle-NNN"}` when the build has no source for it
  (a v0 base, a failed overlay, a product without that state). A missing source is never `pass`.

## Annotations

Every rule that changes a value before the diff is written in the schema, next to the field it changes.
`normalize.py` (task p15-oracle-013) applies only these rules.

| Keyword | Where | Meaning |
| --- | --- | --- |
| `x-oracle-source` | every property, every facet | `{method, path}`: the wire method that gives the value and the JSON pointer into that method's result (`*` is any array item or map key, `**` is any depth). Optional `from` names the model value behind it; `derive` says what the capture computes (for example `sha256`). On a facet it also has `v0` (the push-base method, or `null`), `provider` and `task`. |
| `x-oracle-order` | every array | `sequence`: order is behavior. `set`: order is not behavior; normalize sorts it. |
| `x-oracle-id-kind` | id strings | The id kind. Normalize relabels ids per kind (`pane#1`, `pane#2`, ...) so that runs with different random ids compare equal. |
| `x-oracle-id-patterns` | schema root | Id regex per kind, for ids inside open objects (`LayoutDocument`, `extra`, `projection`). |
| `x-oracle-volatile` | a field | `{reason, task}`. Normalize drops the field. The reason names the source of nondeterminism. |
| `x-oracle-precision` | every number | Normalize rounds to this step. Ratios use 0.001, frame fractions and zoom use 0.01. `x-oracle-precision-default` (0.001) applies to numbers inside open objects. |
| `x-oracle-rewrite` | path and URL strings | `path`: the case root becomes `$ROOT` and the hermetic home becomes `$HOME`. `url`: the loopback fixture origin becomes `$WEB`. |
| `x-oracle-time` | time values | `{unit, epoch: fixture}`: an offset from the fixture epoch of the virtual clock (task p15-oracle-185). When `meta.clock` is `wall`, these fields are not comparable. |
| `x-oracle-counter` | totals | `monotonic`: a process total. The runner compares the delta between two checkpoints, not the value. |

Hash fields have the pattern `^sha256:[0-9a-f]{64}$`.

### Normalization order

1. Drop `x-oracle-volatile` fields.
2. Apply `x-oracle-rewrite`.
3. Change `x-oracle-time` values to fixture offsets (or mark them not comparable on a wall clock).
4. Round numbers to `x-oracle-precision`.
5. Sort `set` arrays by the canonical JSON of each item with its ids masked to their kind.
6. Relabel ids per kind in first-seen order of a sorted-key traversal: typed fields by `x-oracle-id-kind`,
   strings in open objects by `x-oracle-id-patterns`.
7. Hash the canonical JSON (sorted keys, no whitespace) with sha256.

## Source methods

| Method | Owner | Gives |
| --- | --- | --- |
| `oracle.runner` | `scripts/cmux-next/oracle/oracle.py` (task 017) | `schema`, `meta`, the not-comparable form |
| `snapshot.get` | `ControlRouter+Builtins.swift`, `ControlTopology+JSON.swift` | `topology` |
| `session.snapshot`, `settings.snapshot` | cmux-tui resource API (`ResourceSnapshot`) | `daemon.session`, `daemon.settings` |
| `oracle-state` | cmux-tui `oracle_state.rs` (task 021) | `daemon.journalHead`, `daemon.oracle` |
| `debug.oracle.snapshot` | `CmuxNextOracle` facet providers (task 030) | every other facet; its result is `{<facet>: <value>}` |
| `terminal.screen.read` | cmux-tui resource API | the input of `terminals.list[].last24Sha256` |

Facets that pass a method result through (`topology`, `daemon.session`, `daemon.settings`) keep that method's
wire keys, so a pointer maps one to one. Facets that a provider builds use camelCase keys and public ids
(`win_…`, `ws_…`, `pane_…`), never model keys, so that one object gets one label in all facets.

The `debug.oracle.snapshot` result shape and `oracle-state` are not on `perf/chrome-parity` yet. This schema is
their interface; tasks 021 and 030 implement it.

### v0 facets

Task p15-oracle-006 captures the push base with methods that exist there. `x-oracle-source.v0` names them:
`topology` (`snapshot.get`), `daemon` (`session.snapshot` + `settings.snapshot`; `journalHead` and `oracle` are
absent), `focus` (`debug.focus`), `settings` (`settings.snapshot`), `invariants` (`debug.desync`) and
`switches` (`debug.tunables`). A facet with `v0: null` is not-comparable at the push base.

## Validator subset

The fleet Macs have no `jsonschema`, so `normalize.py` has its own stdlib validator. The schema uses only these
keywords: `type` (a name or a list), `enum`, `const`, `pattern`, `minimum`, `maxItems`, `required`, `properties`,
`additionalProperties` (a boolean or a schema), `items`, `oneOf` and `$ref` (only `#/definitions/...`). A new
keyword needs support in `normalize.py` first. `jsonschema.Draft7Validator` gives the same result.

`normalize.py --validate` also checks the schema itself: every property has `x-oracle-source` with a method
and a path, every array has `x-oracle-order`, every number has `x-oracle-precision`, and every
`x-oracle-volatile` has a reason and a task.

## Changes

- To add a field: give it `x-oracle-source`, and the annotations its type needs. If its value is not
  deterministic, fix the source (virtual clock, seeded ids, stable order) before you mark it volatile.
- An optional field or a new facet stays v1. A removed, renamed or changed field is v2 and a rebaseline.
- Test: `python3 -I scripts/cmux-next/oracle/normalize.py --validate schemas/oracle/fixtures/snapshot-example.json`.

## Chrome analogs

- Blink web tests compare text dumps of semantic state, not screenshots, where they can
  (`third_party/blink/renderer/core/layout/layout_tree_as_text.cc`).
- Accessibility dump tests keep volatile properties out with written filters
  (`ui/accessibility/platform/inspect/ax_tree_formatter_base.cc`,
  `content/browser/accessibility/dump_accessibility_browsertest_base.cc`): the model for `x-oracle-volatile`.
- Kombucha waits on observed state, not on time (`ui/base/interaction/state_observer.h`).
