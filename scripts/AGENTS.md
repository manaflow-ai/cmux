# scripts/ and tests/ agent instructions

Where CI tooling and its tests live, and how to check one change in minutes. Workflows and the files that
register them: [.github/AGENTS.md](../.github/AGENTS.md). Rules for every session stay in the
[root CLAUDE.md](../CLAUDE.md).

## Where things live

| Path | What |
| --- | --- |
| `scripts/ci/` (about 860 files) | What the workflows call: the routers (`pr_router.py`, `job_inputs.py`, `focused_tests.py`, `affected_tests.py`), the step runner `ci_steps.py`, the guard runner `run_ci_guards.py`, the registry checkers. Name prefixes group them: `nightly`, `cmux`, `pr`, `ios`, `check`. |
| `scripts/cmux-next/` (about 1,960 files) | cmux-next tooling: the pre-push gate `prepush-gate.py` with `lint/` and `arch_rules/`, about 100 `check-*` scripts, `cloud-*`, `bench-*`, `build-*`. |
| `scripts/` top level (about 210 entries) | Older and app-wide tools: `check-*`, `lint-*`, `build-*`, `verify-*`, `blacksmith-*` (the Testbox, see [cmux-tui/AGENTS.md](../cmux-tui/AGENTS.md)), `setup.sh`, `install-git-hooks.sh`. |
| `scripts/git-hooks/` | The tracked hooks that `install-git-hooks.sh` copies out of the checkout. |
| `scripts/bench/`, `scripts/measure/` | Benchmarks; one entry point, `scripts/bench/cmux-bench` (each folder has a README). |
| `ci/steps.toml`, `ci/run` | The PR pipeline's one step table and its runner. |
| `tests/` (about 980 `test_*` files plus helpers) | Python and shell guards for scripts, workflows and repo rules. Most run on Linux with no app. |
| `tests/test-execution.d/<area>.toml` | The lane registry for Python tests: one fragment per first word of the test name, else `other.toml`. |
| `scripts/tests/` | Seven more Python tests (PR-scoped lint gates); `test-ios.yml` and `ci-web.yml` run them. |
| `tests_v2/` | 29 tests that drive a running cmux over the v2 socket (`tests_v2/cmux.py`). They need a tagged build (`CMUX_SOCKET_PATH`); CI runs two, in `test-feed-reply-providers.yml`. |

## Test one script in five minutes

1. Find its tests: `python3 scripts/ci/focused_tests.py --files scripts/ci/x.py` lists every test that names
   the path, with its lane. The name `tests/test_<name>.py` (`tests/test_ci_<name>.py` for `scripts/ci/`)
   holds for about a third of scripts; trust the map, not the name.
2. Run one: `python3 tests/test_x.py` or `./tests/test_x.sh` (seconds). On a lane VM, or when it needs a fleet
   machine: `cmux-ci test -- python3 tests/test_x.py`.
3. Run one CI guard step the way CI does: `python3 scripts/ci/run_ci_guards.py --group GROUP --step "STEP NAME"
   --no-stamp`. `--group ci --list` prints a group's steps; `scripts/ci/guards-local.sh` runs the fast set.
4. See which PR-pipeline steps a change routes: `python3 ci/run route --paths-file FILE` (one path per line).
   `python3 ci/run run --job linux --only STEP` runs one.
5. Python syntax as CI checks it: `git ls-files 'tests/*.py' 'tests_v2/*.py' 'scripts/*.py' | xargs python3 -m py_compile`.

## The git hooks

`scripts/setup.sh` runs `scripts/install-git-hooks.sh`, which copies `scripts/git-hooks/` into the clone's git
dir (`cmux-git-hooks/`). The post-merge hook refreshes that copy after a pull to main or feat-cmux-next.

- pre-commit: normalizes a staged `cmux.xcodeproj/project.pbxproj`, and registers the tests the commit adds
  (`scripts/ci/validate_test_execution_registry.py --write`).
- pre-push: the fast tier (`scripts/cmux-next/prepush_fast_tier.py`), web lint (warns only), the cmux-next gate
  `scripts/cmux-next/prepush-gate.py` (refuses a new violation), and `scripts/ci/base_merge_warning.py`. Each
  step has a time limit; past it the push goes on. The header of `scripts/git-hooks/pre-push` lists them all.

## Mechanical reds

| Red | Reported by | Fix |
| --- | --- | --- |
| A syntax error in any tracked `.py` under `tests/`, `tests_v2/` or `scripts/` | `ci-guards.yml` step "Validate Python test harness syntax" (group `quality-determinism`) | Run the py_compile line above. |
| Python 3.10+ in a file the hooks run (`match`, an `X \| Y` annotation without `from __future__ import annotations`, `zip(strict=)`) | `tests/test_py39_names.py`; a Mac's hooks run `/usr/bin/python3` 3.9.6, and the `workflow-guard-cli-scripts` and `workflow-guard-source-lints` jobs set up 3.9 | Add `from __future__ import annotations`, or guard the code with `sys.version_info`. |
| A registry entry that is malformed, duplicated, or on a lane the workflows contradict | `scripts/ci/validate_test_execution_registry.py` | Run it with `--write`. Misplaced or unsorted entries: `python3 scripts/ci/test_execution_registry.py fix`. |
| A test that reads `.github/workflows/` but no workflow runs it | `tests/test_ci_workflow_guards_are_wired.py` | Add a workflow step that runs it (usually in `ci-guards.yml`). |

A test with no registry entry only warns. Where a new test goes and which lane it takes:
[adding a test](../skills/cmux-testing/references/adding-a-test.md).

## Deeper docs

- [skills/cmux-testing/references/adding-a-test.md](../skills/cmux-testing/references/adding-a-test.md),
  [pr-ci-coverage.md](../skills/cmux-testing/references/pr-ci-coverage.md)
- [skills/cmux-dev-workflow/references/hooks-and-lints.md](../skills/cmux-dev-workflow/references/hooks-and-lints.md),
  [pushing.md](../skills/cmux-dev-workflow/references/pushing.md)
- [docs/ci/landing.md](../docs/ci/landing.md), [docs/ci/risk-tiers.md](../docs/ci/risk-tiers.md),
  [docs/ci-test-health.md](../docs/ci-test-health.md), [scripts/bench/README.md](bench/README.md)
