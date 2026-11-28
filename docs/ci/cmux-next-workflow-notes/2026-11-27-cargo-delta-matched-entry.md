# Pool cargo legs: the workspace delta of the dependency entry actually restored

Above `Key the workspace delta to the restored dependency entry` in `.github/workflows/cmux-tui-build-package.yml` and in the
cmux-next.yml fast tier (cargo).

The R2 dependency entry is keyed by the cmux-tui Cargo.locks, the toolchain and rustc/cargo versions, and restored by prefix;
the per-commit workspace delta (2026-11-26-cargo-target-delta.md) was looked up only under the leg's own inputs. A leg whose
inputs have no entry yet restores another inputs' entry and finds no delta, so every workspace crate compiles. That is most
legs: cmux-tui/Cargo.lock changed 53 times on feat-cmux-next in the 24 h to 2026-11-27 08:00Z, and a PR that touches a lock
never has its own entry. Machine channel PR head builds (x86_64 and aarch64 musl, about 19,000 runner-min/day) spent 12-16 min
in `Build cmux-tui (Linux cross)` in about 92% of runs, about 2 min in the rest; job 140359967645 logged a prefix match on the
dependency entry, then "cargo delta: miss" and 613 s in cargo group 1.

Now the step after the dependency restore maps its `cache-matched-key` to that entry's inputs
(scripts/ci/cargo-delta-prefix.sh), and the delta restore tries that prefix first and the leg's own inputs second. The delta
found was built on the same dependency entry the leg holds. Saves are unchanged. Correctness still never rests on the delta: a
changed file keeps a fresh mtime and Cargo's fingerprints rebuild what differs. Test: tests/test_ci_cargo_delta_matched_entry.py,
which also fails a new step that applies a delta without this lookup.

The clippy seed writer follows the same matched-entry lookup. Fleet job
`9b929e853c7404ced70d4e48` at `323681481459c89e63a3baf3ac471a7be49fb519`
exposed its missing lookup after the workflow guard was wired into CI. It retains
the existing `cmux-tui-clippy-seed-*` cache namespace and save keys.
Detector: `tests/test_ci_cargo_delta_matched_entry.py` discovers every workflow
that applies a Cargo workspace delta and also checks the seed writer's key outputs.
