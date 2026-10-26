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
