# cmux-next review and fix standard

Lawrence (2026-10-23): "reviewers for correctness, principled fixes, no hacky fixes"; "do the hard things now and bake in the patterns". A finding that breaks one is at least major.
- Correctness first: trace the real code path (every entrypoint, both engines, macOS 14/15/26/27 API differences,
  concurrency and reentrancy, error and cancel paths, lifetimes and leaks). State the failure scenario concretely.
- Root cause, not symptom: the fix removes the cause the reviewer named. A fix that moves work elsewhere (later frame,
  other thread with the same wait, Task hop) without removing it is not a fix.
- Hacks are rejected outright: sleeps, polling, retries or timeouts that hide a race; throttles and debounces that hide
  cost; widened test thresholds or loosened assertions; tests special-cased for the bench or CI; catching and ignoring
  errors; force unwraps traded for silent defaults that hide a broken state; feature flags or tunables used to hide a
  bug; magic numbers without a measured reason; skip-reason env vars to pass a gate; duplicated code paths instead of
  one shared path; a rename that dodges a count; TODOs instead of the fix.
- A regression guard must fail on the code before the fix and pass after it, through runtime behavior (CLAUDE.md test
  quality policy). The reviewer checks the guard against the real bug, not only an intermediate version.
- When the correct fix is larger than the slice, the fixer says so and does the correct fix, or stops and reports it;
  never a smaller fix that looks done.

- Daemon and acpmux rules D1-D8 and A1-A3 are in plans/cmux-next/perf-lead.md ("Daemon and acpmux targets"). Any
  change to cmux-tui or acpmux must follow them: no I/O on a request path, readers never wait, bounded per-connection
  queues, event driven (no idle timers or polling), client-minted ids. Every daemon or acpmux op < 2 ms p95.
- acpmux is owned end to end by cmux-4f's PL-acpmux (audit and fixes); nobody in cmux-b6 owns acpmux code.
- New landings get the deep review (workflow script cmux-next-deep-review), not the lighter two-review workflow.


## How to run it
- A deep review of landed commits: the repo workflow `.claude/workflows/cmux-next-deep-review.js` (six lenses, three
  refuters per finding, principled fixes, two-lens review of each fix, fleet test, land). Pass `args` as a list of
  `{name, ranges: ["OLD..NEW"], summary}`.
- Every change uses the patterns in [PATTERNS.md](PATTERNS.md) and keeps the counts in arch-ratchet.json going down.
