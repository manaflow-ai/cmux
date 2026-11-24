# Adding a test: what CI does with it

Write the test next to the code it covers, the way you already do. The tests a pull request
runs are worked out from the tree at its head, so no workflow needs a new job. Never add CI
jobs, gates or CI-only tests (root [AGENTS.md](../../../AGENTS.md)). The one file you may need
to touch is the Python lane registry (below). A test that sits where the map can see it runs
on the pull requests that can break it.

## Where a test goes, and what picks it up

| Kind | Put it in | It runs when a change touches |
| --- | --- | --- |
| Swift (app, shared packages) | `<package>/Tests/<Target>Tests/`, Swift Testing | the target, or any target its sources import (`import X`, `@testable import X`), across path-dependent packages |
| cmux-tui Rust (`cmux` CLI, daemon) | the crate's own `tests/` or `#[cfg(test)]` | the crate or anything it reaches by path dependency, plus files its sources name (`include_str!`, `../` fixtures) |
| Webviews (TypeScript) | `webviews/test/` or `webviews/src/**/*.test.ts` | any non-test `webviews/` file (that runs every webviews test). When only test files change, just those run |
| Web app (`web/`) | `web/`'s own suite | a `web/` path, or a path a `web/` test names |
| Python guards and tooling | `tests/test_*.py` or `scripts/tests/test_*.py`, plus an entry in `tests/test-execution.d/<area>.toml` | a path the test names in its source (the repo path, or a script's or workflow's distinctive basename), or a module it imports |
| Native cargo workspaces | the workspace's own tests | a file in that workspace |

**Python tests need a lane.** Add a `[[test]]` entry with `path` and `lane = "linux-guard"` to the
matching `tests/test-execution.d/*.toml`, kept sorted by path. An unregistered test is only
listed in the plan's `not_run` ("outside the lane registry"). The per-change plan runs the
`linux-guard` lane; other lanes are listed in `not_run`. New tests may not enter as `legacy`,
and `manual` needs a `reason`.

The map is `scripts/ci/focused_tests.py`, with the Rust crate graph in `scripts/ci/cargo_affected.py`.
`scripts/ci/affected_tests.py` turns it into the plan, and
`scripts/ci/affected_jobs.py` routes the pull request's Rust CI jobs from the same graph. A
Python test that covers a file it neither names nor imports stays invisible to the map. Name
the path in the test, for example in the `SCRIPT = ROOT / "scripts/ci/x.py"` line it already
needs. Use `scripts/ci/focused-tests-extra.json` only when the test truly cannot name the path.

## See the answer before you push

```sh
python3 scripts/ci/affected_tests.py                                 # this branch against origin/feat-cmux-next (fetches the base)
python3 scripts/ci/focused_tests.py --files path/you/changed.swift    # one path
```

The plan is JSON. `units` are what runs, `not_run` names what is left out and why, and
`ci_jobs` are the pull-request jobs the router starts. Check that your new test appears in
`units` for the change it guards. When it does not, fix the test so it names what it covers.
Don't add a rule to make it show up.

To run the plan, use `cmux-ci test --affected` from a machine with HQ's fleet client: it runs
each unit on its own fleet machine. On a lane VM, `cmux-ci` has no `--affected`. Run a unit's
command yourself with `cmux-ci test -- CMD`.

## Selection never trades a test for speed

- A path no rule maps, a change to the planner or the scripts it runs, or a very large diff
  selects everything, and the plan says why.
- On a push to `feat-cmux-next`, `affected_jobs.py` runs every Rust job it routes, and the Mac
  base tier runs at most every 15 minutes. Other workflows still apply their own `paths:`
  filters on push.
- Markdown runs the guards, plus any test that names the doc's own distinctive path.
- `scripts/ci/affected_tests_replay.py` and `affected_jobs_replay.py` replay merged pull requests.
  They check whether selection would have run every test that failed on them. A miss is a
  routing bug: fix the map, not the test.

## After you push

- One router job (`pr-router.yml`, `scripts/ci/pr_router.json`) starts only the workflows your
  change can reach. A skipped check under its own name means the change could not affect it.
- `cmux-next-pr-autofix.yml` commits mechanical repairs to the pull request for you, such as
  generated files, formatting and pins.
- The pull request's status comment lists its red web and size checks (`pr_red_checks_comment.py`).
- For a red web test, `python3 scripts/ci/web_test_verdict.py --pr N` tells the pull request's
  fault from a flake.
- Read what executed on the head SHA: a green skipped job is not coverage. `full-ci` is rare;
  see [PR CI coverage](pr-ci-coverage.md).

The regression test you add still runs on the fleet first (`cmux-ci test -- CMD`). Commit it
failing, then commit the fix, as the [skill](../SKILL.md#reproduce-and-repair) says.
