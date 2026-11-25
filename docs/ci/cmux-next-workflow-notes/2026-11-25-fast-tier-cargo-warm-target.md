# fast-tier-cargo: the warm cargo target and the R2 dependency cache

Moved out of `.github/workflows/cmux-next.yml` (tests/test_ci_workflow_file_size.py), word for word.

`Test the warm cargo target` in fast-tier-cargo:

A persistent pool runner keeps this job's whole target between its jobs and gives each source
whose bytes are unchanged its recorded mtime back, so cargo rebuilds only the crates a change
reaches and their dependents (scripts/ci/pool-warm-target.sh); on Blacksmith a sticky disk holds it.
The warm target's own test, where cargo is: unchanged bytes stay fresh, a changed crate and its
dependents rebuild, an unrecorded job leaves nothing to trust (a three-crate workspace, ~5 s).

`Mount the warm cargo target` in fast-tier-cargo:

On Blacksmith (RUNNER_POOLS sends the job there when the pool is down or overflowing) the same
tree lives on a sticky disk, as cmux-tui-spec.yml's warm clippy target: feat-cmux-next pushes
commit it, every other run mounts a clone and never writes it back. Keys are literal
(tests/test_ci_testbox_broker_guard.py).

`Key the cargo build in R2` in fast-tier-cargo:

Off Blacksmith the GitHub store above always misses (it is full and churns in minutes), so the
compiled dependencies come from R2 instead. Why: [note-210b](../cmux-next-workflow-notes.md#note-210b)
Skipped, with its restores and saves, when the warm target above is linked: cargo then builds in
that tree (CARGO_TARGET_DIR), which keeps the dependencies, and cmux-tui/target stays empty.
