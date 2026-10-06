# cmux-next CI tiers

A pull request into `feat-cmux-next` runs only the checks its change can break.
`scripts/ci/cmux_next_route.py` reads the changed files (the merge commit
against its first parent) and picks the tiers; the `cmux-next path routing`
job's summary lists each tier and the reason for it.

| Tier | Check (job) | Runs when the PR changes | Runner |
| --- | --- | --- | --- |
| checks | `cmux-next checks` (god files, concurrency, crash safety, string tables, script tests, package conventions, tier routing) | any cmux-next path | Linux (Blacksmith) |
| generated | `cmux-next generated files` (action catalog, surfaces and inventory; CI target graph) | the CmuxNext package, `plans/cmux-next/`, the generators | mini |
| native | `cmux-next Release compile (Xcode 26)` | Swift or app sources | mini |
| scheme | `cmux app scheme compile (Debug)` | the app host, Xcode project, CLI, resources, webviews, local packages CmuxNext uses, an executable target | mini |
| swift | `cmux-next swift test` | the test targets the target graph reaches | mini |
| daemon | `wait for the same-tree cmux-tui` and `cmux-next daemon tests` | cmux-tui tree inputs, daemon capabilities, `pin-cmux-tui.sh`, CmuxNextDaemon or CmuxNextMobile and their dependencies, CmuxNextControl | Linux wait, then a mini |

Every tier runs on:

- a pull request labeled `full-ci`. Use it on a batch integration PR, so the
  heavy suites run once for the batch before it merges;
- every `feat-cmux-next` push (a superseded push skips its Mac jobs, so a burst
  of merges is checked once at its newest commit). When a push job fails,
  `cmux-next push attribution` comments on each PR merged since that job last
  passed on a push. The owning lane fixes forward;
- a change to the manifest, the target graph, the router, the workflow or the
  test runner scripts, or to a file in the CmuxNext package that no target owns.

## Which test targets a change selects

`Packages/macOS/CmuxNext/ci-target-graph.json` comes from
`swift package dump-package`, via `scripts/cmux-next/ci-target-graph.py`:

- each target's directory and the targets and local packages it depends on;
- each local package's directory. Its own path dependencies come from
  `scripts/ci/select_package_tests.py`;
- for each test target, the repository files its sources name in string
  literals (schemas, fixtures, plans, cmux-tui vectors).

A test target runs when a target it depends on, directly or transitively,
changed, when the test target itself changed, or when a file it reads changed.
`cmux-next generated files` fails when the committed graph is stale.

The live-daemon suites skip without the same-tree cmux-tui binary. The daemon
tier runs them against it. A UI change does not wait for the tree.

## Generated files fix themselves

When the action contracts or the graph are stale, `cmux-next generated files`
regenerates them and uploads the patch. On a same-repository PR,
`cmux-next generated autofix` commits the patch to the PR branch if both hold:

- the patch touches only `plans/cmux-next/*.json`, `plans/cmux-next/*.md` and
  the graph;
- the branch head has not moved.

The new commit starts a fresh run. Pull before your next push.

## Measurements

Before (#17470, a UI-only PR, run 37402420094):

| Job | Wall time | Where the time went |
| --- | --- | --- |
| cmux-next swift test | 28.5 min | 13.2 min waiting for the base head's cmux-tui tree to publish, 10.4 min package tests on a busy mini, 2.6 min build |
| cmux app scheme compile (Debug) | 20.9 min | 16.9 min waiting for the same tree, 2.6 min compile |
| cmux-next Release compile | 4.4 min | |
| cmux-next checks | 1.1 min | |
| whole run | 40 min | |

The same package tests take 2.1 min on an idle mini (push run 37405228160).

### Why the tree wait took 13 minutes

`pin-cmux-tui.sh fetch` did not build anything. Its cache is already keyed by
the cmux-tui tree hash (key v2, `scripts/ci/cmux_tui_tree_key.py`). An
unchanged tree is a download of a few seconds once it is published.

The PR's merge tree had the base's cmux-tui tree, `a4098bcb`. The base had just
moved to it, and the cmux-tui artifacts workflow publishes a tree only after its
build and the `cmux_next_` daemon tests pass. Every PR merged in that window
waited for the base head's publication. That key changes often: the 40 first-parent
commits on `feat-cmux-next` up to f9e139f (about 7 hours on 2026-10-05) have
18 different keys.

A UI-only PR now neither waits for the tree nor runs the scheme compile that
bundles it.

### Sharding

Package tests are not sharded across minis. On an idle mini the whole suite
takes 2.1 min, and SwiftPM links every test target into one bundle, so each
shard pays the 2.6 min build again and asks for one more mini. The 10.4 min
on #17470 was contention on a busy mini. Selecting only the affected targets
reduces that contention, and sharding would add to it.
