# Bounded pre-push feedback

The installed pre-push hook runs a four-second work budget before the existing
web and native source checks. Those existing checks and fleet verification keep
their current authority. The budget applies to this additional tier, not to the
entire hook.

The tier reads the pushed commit's Python files and package.json manifests as data and reports new
syntax errors. A reviewed manifest selects small pure TypeScript modules and their
Bun unit suites when either source or test changes. TypeScript checks only those
source files with strict ES2022 settings; project-wide checks still run in CI.
When a module gains dependencies, extend and measure its manifest entry before
adding it back to this fast subset.

Unit tests and the warm TypeScript compiler run in a disposable Linux bubblewrap
sandbox: only explicitly selected Git blobs, system executables, the Bun binary,
and the compiler are readable. It exposes no home, Git directory, environment
credentials or network. The source snapshot is read-only and temporary storage
is private. A working-tree fix cannot hide an error in the pushed commit.

No dependency installation happens during a push. Missing tools, unavailable
sandboxing (including macOS), merge attribution and exhausted budgets produce
`deferred`, not `passed`. The existing full checks cover that work. Set
`CMUX_FAST_TIER_DISABLED=1` to disable only this early tier.

The post-edit hook records its first observed edit event in the worktree's Git
directory, `cmux-inner-loop.json`, with schema `cmux-inner-loop/v1`. Pre-push adds
the exact head, elapsed milliseconds and per-check outcome. Missing edit events
remain null; commit dates and file modification times are not substituted.
The observation persists across commits and resets when the worktree changes
branches. CI tooling can join it with the first terminal fleet signal.

Verify with `cmux-ci test -- python3 tests/test_prepush_fast_tier.py`. The runtime
tests exercise a committed syntax error with an uncommitted fix, changed unit
assertions, sandbox isolation and edit-time attribution.
