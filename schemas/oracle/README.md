# Oracle snapshot schema v1

The refactor oracle (plans/cmux-next/chrome-parity/p15-oracle.md, section 3A) records one snapshot at each
checkpoint of a case. A refactor must give the same normalized snapshots at the base SHA and at the head SHA.

| File | What it is |
| --- | --- |
| `snapshot-v1.schema.json` | The snapshot: `schema`, `meta`, `facets`. JSON Schema draft-07 plus the `x-oracle-*` annotations below. |
| `fixtures/snapshot-example.json` | One settled checkpoint of an app case with all 20 facets (`webviews` as not-comparable). Wire-true: decimals are strings, enums are strings, private text is hashed. |
| `fixtures/wire/<method>.json` | Real `session.snapshot` and `settings.snapshot` replies of a cmux-tui daemon, recorded by `scripts/cmux-next/oracle/capture_wire_fixtures.py`. |

A snapshot holds semantic state, never pixels. Private text is recorded only as `sha256:<hex>` (see
[Private text](#private-text)).

## Shape

- `schema` is `cmux.oracle.snapshot/v1`.
- `meta` is the run identity that the runner writes: case, step, checkpoint, product, SHA, host, clock, and
  `facets`, the facets that the case asked for.
- `facets` holds exactly the facets of `meta.facets`. Each facet is its object, or
  `{"status": "not-comparable", "reason": "...", "task": "p15-oracle-NNN"}` when the build has no source for it
  (a v0 base, a failed overlay, a product without that state). A requested facet that is absent is an error,
  never `pass`: the check below and `diff.py` (task 014) refuse that snapshot.

## Annotations

Every rule that changes a value before the diff is written in the schema, next to the field it changes.
`normalize.py` (task p15-oracle-013) applies only these rules.

| Keyword | Where | Meaning |
| --- | --- | --- |
| `x-oracle-source` | every property, every facet | `{method, path}`: the wire method that gives the value and the JSON pointer into that method's result (`*` is any array item or map key, `**` is any depth). A field that keeps the wire value has the path of its own location: its parent's path plus `/<key>` (`/*` for array items). A field that the capture computes has `derive` (for example `sha256`); its path names the wire value it is computed from, and the key may differ. Optional `from` names the model value behind it. On a facet it also has `v0` (the push-base method, or `null`), `provider` and `task`. |
| `x-oracle-order` | every array | `sequence`: order is behavior. `set`: order is not behavior; normalize sorts it. |
| `x-oracle-id-kind` | id strings | The id kind, or a list of kinds when the field can hold more than one (`tabs[].content_id` is a terminal or a browser id). For a list, normalize takes the kind whose `x-oracle-id-patterns` entry matches the value. |
| `x-oracle-id-patterns` | schema root | Id regex per kind, one for each id prefix the daemon and the app make (resource ids, `grp_`, `tgrp_`, `sgrp_`, `saved_`, `ssaved_`, `prof_`, `closed_`, `stash_`, ...) and `uuid` for session registry ids and workspace keys. |
| `x-oracle-id-unpatterned` | schema root | Kinds with no stable prefix, each with a reason. They are relabeled only in typed fields; a list `x-oracle-id-kind` cannot name one. |
| `x-oracle-open-keys` | schema root | Rules by key name for values inside open objects (`extra`, `LayoutNode`, `projection`): `*_at_ms` and `since_ms` are times, `*revision` and `*generation` are volatile. |
| `x-oracle-decimal` | wire decimals | The wire sends this uint64 as a decimal string (`"42"`, cmux-tui/spec/bindings.md: "Decimal wire values remain strings"). The schema keeps the string, with pattern `^(0\|[1-9][0-9]*)$`, so a capture passes through unchanged. |
| `x-oracle-volatile` | a field | `{reason, task}`. Normalize drops the field. The reason names the source of nondeterminism. |
| `x-oracle-precision` | every number | Normalize rounds to this step. Ratios use 0.001, frame fractions and zoom use 0.01. `x-oracle-precision-default` (0.001) applies to numbers inside open objects. |
| `x-oracle-rewrite` | path, URL and shell-title strings | `path`: the case root becomes `$ROOT`, the hermetic home becomes `$HOME`. `url`: the loopback fixture origin becomes `$WEB`. For a `derive: sha256` field the capture rewrites first, then hashes: the runner passes the prefixes it gives normalize.py (`--root`, `--home`) as `paths: {root: [...], home: [...]}` to `debug.oracle.snapshot`, `debug.oracle.wait_for` and an arming `debug.oracle.recorder`, and the app applies `_Rewriter`'s rule (`OraclePaths`). |
| `x-oracle-time` | time values | `{unit, epoch: fixture}`: a timestamp, changed to an offset from the fixture epoch of the virtual clock (task p15-oracle-185). Only timestamps: a duration is not a time (`clients[].connected_seconds` is volatile). |
| `x-oracle-counter` | totals | `monotonic`: a total of person or script actions (`intents.totals`). The runner compares the delta between two checkpoints, not the value. |

Hash fields have the pattern `^sha256:[0-9a-f]{64}$`.

### Counters of commits

`topology.sequence`, `daemon.journalHead`, `session.revision`, `cursor.revision`, `settings.revision`,
`frontend_projections[].projection_revision`, `terminals[].exit.revision`, `terminals[].stream_revision` and every
`*revision` key in an open object are volatile, for the same reason as `topology.generation`: they count commits
or publishes, not state. The perf push coalesces bursts into one model update and applies batches as one
transaction (CLAUDE.md), which changes these counts and leaves the state the same; the oracle must pass such a
refactor. The commit count is a perf metric, measured by the perf benches. The runner still reads the raw
`sequence` and `journalHead` before normalize, to pair the app cut with the daemon cut.

### Normalization order

1. Parse every `x-oracle-decimal` string to an integer, so that the rules below apply to numbers. A value that
   does not match the pattern is a validation error, not a value to compare.
2. Drop `x-oracle-volatile` fields, and keys in open objects that a volatile `x-oracle-open-keys` rule matches.
3. Apply `x-oracle-rewrite`. In every string of an open object, the case root, the hermetic home and the
   loopback origin are rewritten as `path` and `url` do, and the capture host name becomes `$HOST`.
4. Change `x-oracle-time` values, and open-object values that a time rule of `x-oracle-open-keys` matches, to
   offsets from the fixture epoch. When `meta.clock` is `wall`, each of these values becomes the string
   `wall-clock`: the key stays, and `--explain` lists it as not compared. Open-object times are comparable only
   under `clock: virtual`.
5. Round numbers to `x-oracle-precision`.
6. Relabel ids (below).
7. Sort `set` arrays by the canonical JSON of each item, with its ids relabeled.
8. Hash the canonical JSON (sorted keys, no whitespace) with sha256.

### Id relabeling

An id is a typed string with `x-oracle-id-kind`, or, in an open object, every substring that a pattern of
`x-oracle-id-patterns` matches without its anchors (the longest prefix first, left to right, so that
`itm_w_<uuid>_ws_<hex>` gives `itm_w_uuid#1_workspace#1`). Each id gets `<kind>#<n>`. The labels must not depend
on the random ids, so normalize gives them structurally, as color refinement (1-dimensional Weisfeiler-Leman)
does:

1. Anchors first: walk the snapshot in sorted-key order, skip the items of `set` arrays, and label each id in
   first-seen order. Focus fields, `sequence` arrays and the layout tree are anchors.
2. Refine: in each `set` array, write each item as canonical JSON with the labeled ids as their labels and the
   other ids as their kind. Sort the items by that text. An item whose text is unique in its array labels its
   ids in first-seen order. Repeat from the start of this step until no new label is given.
3. Ties: items of one array that still have the same text differ only in ids that nothing outside them refers
   to in a way that tells them apart. Normalize labels the first of them and refines again (step 2), until no
   ids are left. For a reference forest (parents, children and focus pointers, which is what the snapshot
   holds), refinement distinguishes all items that are not symmetric, so the choice cannot change the hash.
   Normalize checks this: it also labels the tie in reverse order, and when the two hashes differ, it reports
   `tie-unresolved` with the pointer and compares that array as a multiset of items with ids masked to
   their kind.

A typed id string with no `x-oracle-id-kind` is a schema error (the check below refuses it), so an id cannot
stay raw.

## Private text

Text that a person, a shell or an agent writes is hashed by the capture (`derive: sha256`, after the path
rewrite): terminal and tab titles (a shell title holds the cwd and the command), the last 24 terminal rows,
notification title, subtitle and body (agent hooks and OSC 9/777 output), the palette query and the sidebar
filter (`querySha256`, `filterSha256`), the find query, drafts, the settings files (`effective_sha256`,
`file_sha256`) and closed-tab titles.

These strings stay raw, because only the case writes them and the corpus is hermetic: workspace, screen, pane,
tab and group names that a case step sets; page titles and URLs of the hermetic web fixture (`$WEB`); app
strings (AX label keys, palette and dialog ids, sidebar row labels, which are workspace names); enum values.
A new raw text field needs that reason in its `description`.

### Case root and home

A hash cannot be rewritten after the capture, so the app rewrites `x-oracle-rewrite: path` text itself
before it hashes it (the `terminals` facet's `title` and `last24Sha256`). It must know the prefixes that
normalize gets as `--root` and `--home`. The app driver (task p15-oracle-200) launches the app for each case
with the variables that `normalize.py`'s `app_environment(Context)` gives for the same `Context`:

| Variable | Value |
| --- | --- |
| `CMUX_NEXT_ORACLE_ROOT` | The case root and each alias a shell may report (`/tmp/o/<run6>/<case6>` and `/private/tmp/o/<run6>/<case6>` on macOS), separated by `:`: the `--root` values. The `CMUX_NEXT_` prefix is required: the app unsets every other inherited `CMUX*` variable at launch (`LaunchIdentity.inheritedKeys`). |
| `HOME` | The hermetic home: the one `--home` value. |

The app reads both once, at its composition root (`AppEnvironment`). When `CMUX_NEXT_ORACLE_ROOT` is not set
and a hashed text still holds a path under `/tmp/o/`, the `terminals` facet answers not-comparable, never a
hash of the raw path. `fixtures/path-rewrite.json` holds one environment and texts with their rewrites; the
normalize selftest (`app_environment_rewrite_matches`) and `OracleTerminalsFacetTests` both check it.

## Source methods

| Method | Owner | Gives |
| --- | --- | --- |
| `oracle.runner` | `scripts/cmux-next/oracle/oracle.py` (task 017) | `schema`, `meta`, the not-comparable form |
| `snapshot.get` | `ControlRouter+Builtins.swift`, `ControlTopology+JSON.swift` | `topology` |
| `session.snapshot`, `settings.snapshot` | cmux-tui resource API (`ResourceSnapshot`, `cmux-config` `Snapshot::to_json`) | `daemon.session`, `daemon.settings` |
| `oracle-state` | cmux-tui `oracle_state.rs` (task 021) | `daemon.journalHead`, `daemon.oracle` |
| `debug.oracle.snapshot` | `CmuxNextOracle` facet providers (task 030) | every other facet; its result is `{<facet>: <value>}` |
| `terminal.screen.read` | cmux-tui resource API (`TerminalScreenResult.text`) | the input of `terminals.list[].last24Sha256` |
| `cli` | the shipped `cmux` binary, run by `scripts/cmux-next/oracle/driver_cli.py` (task 048) | `cli`: a cli step's exit code, stdout (open) and typed error, in its settled checkpoint |
| `mcp` | `cmux mcp serve --all-tools` over stdio, run by `scripts/cmux-next/oracle/driver_mcp.py` (task 209) | `mcp`: an mcp step's tool-error flag, result (open) and typed error, in its settled checkpoint |
| `resource.call` | the reply of a resource.call step with expect outcome `any` (a walk move), read by `scripts/cmux-next/oracle/driver_daemon.py` (task 098) | `reply`: ok with the receipt's replayed flag, or the typed error code, in its settled checkpoint |
| `tui` | the PTY output of `cmux-tui attach`, kept as a character grid by `scripts/cmux-next/oracle/driver_tui.py` (task 234) | `tui`: the frontend's grid size, the sha256 of its last complete frame's row text and style runs, cursor and exit code, after the settle probe |

Facets that pass a method result through keep that method's wire keys and shape, so a pointer maps one to one:
`topology` is the whole `snapshot.get` result (path `/`), `daemon.session` is `ResourceSnapshot`. The capture
changes only `derive` fields: `daemon.settings` is the `settings.snapshot` result with `effective` and `file`
hashed. The machine `platform` and `capabilities` come only to catalog readers; `platform` is volatile
(the host check covers it). Facets that a provider builds use camelCase keys and public ids
(`win_…`, `ws_…`, `pane_…`), never model keys, so that one object gets one label in all facets.

The `debug.oracle.snapshot` result shape and `oracle-state` are not on `perf/chrome-parity` yet. This schema is
their interface; tasks 021 and 030 implement it.

### v0 facets

Task p15-oracle-006 captures the push base with methods that exist there. `x-oracle-source.v0` names them:
`topology` (`snapshot.get`), `daemon` (`session.snapshot` + `settings.snapshot`; `journalHead` and `oracle` are
absent), `focus` (`debug.focus`), `settings` (`settings.snapshot`), `invariants` (`debug.desync`) and
`switches` (`debug.tunables`). A facet with `v0: null` is not-comparable at the push base.

## Validator subset

The fleet Macs have no `jsonschema`, so the oracle has its own stdlib validator (task 013 moves it into
`normalize.py`). The schema uses only these keywords: `type` (a name or a list), `enum`, `const`, `pattern`,
`minimum`, `maxItems`, `required`, `properties`, `additionalProperties` (a boolean or a schema), `items`, `oneOf`
and `$ref` (only `#/definitions/...`). A new keyword needs support in the validator first.
`jsonschema.Draft7Validator` gives the same result.

## Check

`python3 -I scripts/cmux-next/oracle/check_snapshot_schema.py` checks, with the stdlib only:

1. Lint: every property has `x-oracle-source` with a method and a path, and the path is its location (above)
   unless it has a `derive`; every array has `x-oracle-order`; every number has `x-oracle-precision`; every
   `x-oracle-volatile` has a reason and a task; every id kind has a pattern or an unpatterned reason; an
   `*_id` or `id` string has `x-oracle-id-kind` (or is volatile); a `sha256` derive has the hash pattern; a
   time is not volatile; no keyword is outside the subset.
2. Each example passes the schema, has every facet of `meta.facets` and no other, and each id-shaped string in a
   typed field has an id kind that matches it.
3. Wire shape: `daemon.session` against `ResourceSnapshot` in `cmux-tui/spec/resource-operations-v2.json`, field
   by field (required, enums, decimals as strings, resource ids with their kind, fixed-field objects listed),
   and `daemon.settings` against the result keys of `settings.snapshot`.
4. Wire captures: each file of `fixtures/wire/` passes the daemon facet after the capture's `derive` rules.

`--selftest` seeds nine schema defects (a copy-paste source path, a decimal typed as an integer, a capture with
an integer revision, a missing facet, an id without a kind, raw text in a hash field, a wire key missing from the
schema, a volatile without a reason, a wrong id kind) and fails unless the check reports each one. Task 013 runs
the same lint from `normalize.py --validate`.

To record the wire fixtures again (on Linux or a fleet Mac, never on the person's Mac):
`python3 -I scripts/cmux-next/oracle/capture_wire_fixtures.py --cmux <cargo target>/debug/cmux-tui`.

## Changes

- To add a field: give it `x-oracle-source`, and the annotations its type needs. If its value is not
  deterministic, fix the source (virtual clock, seeded ids, stable order) before you mark it volatile.
- A wire change to `ResourceSnapshot` or `settings.snapshot` makes the check fail until the schema follows it.
- An optional field or a new facet stays v1. A removed, renamed or changed field is v2 and a rebaseline.
- Test: `python3 -I scripts/cmux-next/oracle/check_snapshot_schema.py` and `--selftest`; after task 013 also
  `python3 -I scripts/cmux-next/oracle/normalize.py --validate schemas/oracle/fixtures/snapshot-example.json`.

## Chrome analogs

- Blink web tests compare text dumps of semantic state, not screenshots, where they can
  (`third_party/blink/renderer/core/layout/layout_tree_as_text.cc`).
- Accessibility dump tests keep volatile properties out with written filters
  (`ui/accessibility/platform/inspect/ax_tree_formatter_base.cc`,
  `content/browser/accessibility/dump_accessibility_browsertest_base.cc`): the model for `x-oracle-volatile`.
- Kombucha waits on observed state, not on time (`ui/base/interaction/state_observer.h`).
