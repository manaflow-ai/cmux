# 2026-11-24-fast-tier-cargo-4

Above the step `Mount the warm cargo target (feat-cmux-next push, commits)` (job `fast-tier-cargo`) in `.github/workflows/cmux-next.yml`.

On Blacksmith (RUNNER_POOLS sends the job there when the pool is down or overflowing) the same
tree lives on a sticky disk, as cmux-tui-spec.yml's warm clippy target: feat-cmux-next pushes
commit it, every other run mounts a clone and never writes it back. Keys are literal
(tests/test_ci_testbox_broker_guard.py).
