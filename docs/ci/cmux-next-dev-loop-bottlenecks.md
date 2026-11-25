# cmux-next dev loop: where agent time goes (2026-10-18)

Measured from 1,711 Claude transcripts of cmux-next and hq lanes (2026-10-13 to
2026-10-18) and 1,259 gate receipts in `/tmp/gates`. Time is the wall time
between a Bash tool call and its result.

## Agent tool time by kind

| Kind | Calls | Hours | Share | Mean |
| --- | ---: | ---: | ---: | ---: |
| Other commands (reads, edits, scripts) | 94,850 | 540 | 36 % | 20 s |
| `cmux-ci wait` / `nx-remote wait` | 3,698 | 340 | 23 % | 331 s |
| GitHub CI waits (`glaeda-gh wait`, `gh pr checks`) | 2,179 | 156 | 11 % | 258 s |
| `gate-run.sh` (landing gates) | 3,016 | 141 | 9.5 % | 168 s |
| ssh | 9,914 | 51 | 3.4 % | 18 s |
| `safe-push.sh` | 2,774 | 49 | 3.3 % | 63 s |
| git | 19,603 | 47 | 3.1 % | 9 s |
| nx-remote jobs (submit, foreground) | 4,838 | 39 | 2.6 % | 29 s |
| cargo test / nextest | 1,027 | 37 | 2.5 % | 128 s |
| Unit receipts tool (`cmux-next-receipts.py`) | 74 | 0.1 | 0 % | 6 s |

Waiting on remote builds, tests and CI is 43 % of all tool time. The unit
receipts tool, which skips units that are already green, ran 74 times against
3,016 gate runs.

## Gate steps by cost (1,259 receipts, 189 step-hours)

| Step | Runs | Hours | Needed for |
| --- | ---: | ---: | --- |
| Release compile (`check-release-compile.sh`) | 78 | 14 | app host, project, local package changes |
| `verify-cmux-tui-hosted.sh --full` | 9 | 10.7 | Cargo.toml, Cargo.lock, toolchain or spec changes |
| Whole CmuxNext `swift build --build-tests` (nx-remote) | 154 | 11.5 | nothing a target-scoped suite does not cover |
| GUI gate jobs (`--needs gui`) | 79 | 5.4 | GUI-visible changes |
| Web bundle build (Freestyle) | 86 | 3.2 | bundle input changes (safe-push rule) |
| `cmux-tui-rust-check.sh` (whole workspace) | about 22 | about 11 | workspace-wide Rust changes |

No rule asks for the Release compile or the full Rust suite on every push.
Agents picked them by hand. Re-running a step that was already green at the
same head cost only 3 hours, so caching at the gate level saves little. The
saving is in picking fewer and smaller steps.

## Outside the gates

The most frequent remote jobs are `nx-remote --needs gui --app-from-fleet`
(807), `cmux-ci build cmux` (786 full app builds), and `package-test-lane.sh`
(677). A full app build only to look at a React change is already against the
skill. The HMR gallery is the loop for React work.

## What changed

`scripts/cmux-next/gate-plan.py` writes the gate steps file from the diff:

- CmuxNext: only the test targets that `scripts/ci/cmux_next_route.py` selects,
  in one cmux-ci `package-test-lane.sh suite` step (one build). In a test
  target with more than 40 files, only the suites in test files that the change
  names: changed test files, files that use a type a changed source declares,
  and files that share the first two words of a changed source file's name. A
  whole CmuxNextAppTests run (271 files) did not finish within the 900 s limit
  per filter on 2026-10-19.
- Release compile: only when the route's native tier runs and a changed file
  is outside CmuxNext `Sources/` and `Tests/`, the CI files, repo tests, docs
  and web sources. A Release build compiles no test target. The push to
  feat-cmux-next runs every tier in CI as the backstop.
- Full Rust suite: only for workspace files and the spec. Otherwise the
  affected crates and their dependents, through the receipts tool, which skips
  green units.
- Webviews: the affected test files, through the receipts tool.
- Not in the gate: the live-daemon suites (CI's daemon tier). The plan says
  when the change reaches them, and the feat-cmux-next push runs them.
- Web bundles: the verified Freestyle build when a bundle input changed.
- Changed `tests/test_*.py` files run as short local checks.

Every step and every heavy step that it leaves out comes with its reason.
Usage is in the script header.
