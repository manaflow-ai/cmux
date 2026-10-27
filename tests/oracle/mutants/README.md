# tests/oracle/mutants

Seeded faults for the oracle's mutation smoke test ([p15-oracle spec](../../../plans/cmux-next/chrome-parity/p15-oracle.md),
section 3F "Mutation strength", task 026). There are 10 app mutants in `app/` and 10 daemon mutants in `daemon/`.
Each one is a patch file. A job applies the patch in its own build worktree before the build. The patch is never
committed to the sources: Packages and the crates have no fault hooks and no `OracleFaults` switch.

| Product | Applied by | Command |
| --- | --- | --- |
| daemon | `linux_run.sh` (VM queue) | `scripts/cmux-next/oracle/linux_run.sh diff SHA SHA --mutant tests/oracle/mutants/daemon/NAME.patch` |
| app | `scripts/measure/oracle.sh` (fleet step) | `python3 scripts/cmux-next/oracle/fleet.py diff --base SHA --head SHA --head-mutant tests/oracle/mutants/app/NAME.patch` |

In both commands, the head side is built with the patch. The base side is built without it. Divergences (exit 1)
mean that the oracle caught the mutant. A fleet step applies the copy of the patch in its own checkout, so an app
mutant must be in the commit's tree. `oracle.py selftest --mutants` (task 115) runs every mutant and requires that
the oracle catches at least 19 of 20, and at least 9 of 10 for each product.

## Format

Each patch has header lines, then a blank line, then the `git diff` output. `git apply` ignores the header.

```
Mutant: daemon/workspace-move-lands-left
Suite: daemon-ops
Exercises: workspace.move
Fault: workspace.move by selector puts the workspace one slot left of the index it was asked for.

diff --git a/cmux-tui/crates/... b/cmux-tui/crates/...
```

- **Mutant**: `<product>/<file name without .patch>`.
- **Suite**: the suite that must catch the mutant (`baselines.SUITE_CLASSES`).
- **Exercises**: the operation, action or facet that the fault breaks.
- **Fault**: what is wrong, in one sentence.

A mutant changes product sources only. App mutants change `Packages/macOS/CmuxNext/Sources/**.swift`. Daemon
mutants change `cmux-tui/crates/*/src/**.rs`, and never a test file. The change has at most 12 lines, and the
lines it adds do not name the oracle.

## Task mutants

`tests/oracle/task-mutants/<product>/<name>.patch` has the same format and checks, but is not part of the smoke
set of 10 per product. Each one is the fault that one task's test phase must catch. For example,
`daemon/tab-create-terminal-runs-again-on-replay` is p15-oracle-206's double create, caught by invariant I10. Apply
one with the same `--mutant PATCH` flag, and check them with `patch_mutants.py check --task`.

## Check

```
python3 -I scripts/cmux-next/oracle/patch_mutants.py check [--ref REF]
python3 -I scripts/cmux-next/oracle/patch_mutants.py list [--product app|daemon] [--json]
python3 -I scripts/cmux-next/oracle/selftest.py -k PatchMutants
```

`check` refuses a malformed header and a file outside the product's sources. It also refuses two patches with the
same change, and a patch that does not apply at REF. It applies each patch against REF's tree with a scratch index,
so it does not change the work tree. It also refuses fault hooks in Packages or in the crates at REF, and a product
that does not have exactly 10 mutants.

When a source change makes a patch stop applying, write the same fault again against the new code, with the same
name. Do not delete the mutant.

## Coverage at 6dd74be8546f

The catch run (">= 9/10 caught per product") did not run yet. Two parts of the oracle are missing on
perf/chrome-parity:

- **Daemon:** `driver_daemon.py` has no case runner there (`oracle.py run --product daemon` stops with
  "runs no cases on this branch yet (p15-oracle-023)"). The VM builds of the mutants work:
  `linux_run.sh build SHA --mutant PATCH` compiles each of the 10 with the `oracle` profile and features.
- **App:** there is no `tests/oracle/corpus/actions/` (gen_actions.py and the action cases are tasks 071 to 081).

The table below is from a read of the generated `daemon-ops` cases (gen_daemon_ops.py, task 060). It shows which
case makes each fault visible in a settled snapshot. The fix for a "no" row is a case in the generator, not a
change to the mutant: task 115 files each miss as a corpus gap.

| Mutant | Case that exercises it | Caught by the current corpus? |
| --- | --- | --- |
| daemon/workspace-rename-drops-last-char | `workspace-rename-ok` (name `oracle`) | yes, by reading: the name becomes `oracl` |
| daemon/notification-ack-forgets-first | `notification-ack-ok` (one notification) | yes, by reading: `read_by` in the session facet |
| daemon/screen-rename-keeps-old-name | none: `screen-rename-ok` renames a screen with no name, and `or` gives the same name | no: needs a rename of a named screen, or a clear to null |
| daemon/workspace-move-lands-left | none: `workspace-move-ok` moves to index 0, and `saturating_sub` keeps 0 | no: needs a move to index >= 1 |
| daemon/tab-move-right-overshoots | none: `tab-move-ok` moves to another pane | no: needs a move to the right inside one pane of 3 or more tabs |
| daemon/tab-pin-after-first-unpinned | none: `tab-pin-ok` pins the only tab | no: needs a pin in a pane of 3 or more tabs |
| daemon/split-right-opens-left | none: `pane-split-ok` splits `left` only | no: needs `direction: right` |
| daemon/split-ratio-mirrored | none: `pane-split-ratio-set-ok` names a placeholder split id, and 0.5 mirrors to itself | no: needs a real split id and a ratio that is not 0.5 |
| daemon/focus-direction-left-right-swapped | none: `pane-focus-direction-ok` has one pane | no: needs two panes side by side |
| daemon/zoom-ignores-enabled | none: `pane-zoom-ok` omits `enabled`, and a toggle of an unzoomed pane zooms it | no: needs `enabled: true` on a zoomed pane or `enabled: false` on an unzoomed one |

App mutants: no case exercises `closePane`, `equalizeSplits`, `focusLeft`/`Right`, `resizePane*`,
`selectSurfaceByNumber`, `splitLeft`/`Up`/`Right`/`Down` or `swapPaneLeft`/`Right` yet. They are the actions
cases of tasks 077 (layout, split, resize, swap) and 080 (focus, pane).

`app/close-keeps-focus` is caught only by I3 (optimistic prefix) on a run with turn checkpoints (the recorder
armed). The daemon's snapshot moves focus to the successor, so the settled state equals the clean build's. A
settled-snapshot diff cannot catch it, and a run without turn checkpoints counts it as a miss.
