# cmux-next.yml fast-tier-cargo: moved comments

Comments moved out of `.github/workflows/cmux-next.yml` job `fast-tier-cargo` to keep the file under GitHub's workflow
file size limit (`tests/test_ci_workflow_file_size.py`). Each section is one comment, numbered as its
`# Why:` line links it, with the line it stood above.

## 1

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-209`

Enforcement is promoted only after the HQ mirror collector has a complete

## 2

Stood above: `- name: Test the warm cargo target`

A persistent pool runner keeps this job's whole target between its jobs and gives each source
whose bytes are unchanged its recorded mtime back, so cargo rebuilds only the crates a change
reaches and their dependents (scripts/ci/pool-warm-target.sh); on Blacksmith a sticky disk holds it.
The warm target's own test, where cargo is: unchanged bytes stay fresh, a changed crate and its
dependents rebuild, an unrecorded job leaves nothing to trust (a three-crate workspace, ~5 s).

## 3

Stood above: `- name: Mount the warm cargo target (feat-cmux-next push, commits)`

On Blacksmith (RUNNER_POOLS sends the job there when the pool is down or overflowing) the same
tree lives on a sticky disk, as cmux-tui-spec.yml's warm clippy target: feat-cmux-next pushes
commit it, every other run mounts a clone and never writes it back. Keys are literal
(tests/test_ci_testbox_broker_guard.py).

## 4

Stood above: `- name: Link this runner's warm cargo target`

A run that never writes the disk links it only when a feat-cmux-next run recorded a tree there;
an empty disk would be a cold build where rust-cache holds the third-party crates.

## 5

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-210`

As cmux-tui.yml: cargo's registry and dependency builds under cmux-tui/target.
Skipped when the warm target above is linked.

## 6

Stood above: `- name: Key the cargo build in R2`

Off Blacksmith the GitHub store above always misses (it is full and churns in minutes), so the
compiled dependencies come from R2 instead. Why: docs/ci/cmux-next-workflow-notes.md#note-210b
Skipped, with its restores and saves, when the warm target above is linked: cargo then builds in
that tree (CARGO_TARGET_DIR), which keeps the dependencies, and cmux-tui/target stays empty.

## 7

Stood above: `- name: Record this runner's warm cargo target`

After every cargo step, pass or fail, never on cancel: the source manifest the next job on this
runner restores mtimes from. A job that ends before it leaves none (restore consumed it).

## 8

Stood above: `- name: Strip the workspace's own output before the R2 save`

A feat-cmux-next push off Blacksmith whose inputs R2 lacks saves them: dependencies only, as
rust-cache keeps (scripts/ci/cargo_target_strip.py). Why: docs/ci/cmux-next-workflow-notes.md#note-210b

## 9

Stood above: `rm -rf "$REGISTRY/src"`

Extracted sources come back from the .crate files in registry/cache.

## 10

Stood above: `actions: read`

The reuse lookup lists artifacts.

## 11

Stood above: `- name: Verify planner promotion evidence`

The mode switch is deliberately insufficient on its own.  Promotion
