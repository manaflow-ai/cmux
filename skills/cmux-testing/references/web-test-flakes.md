# Is a red web test the PR's fault?

When a `web / Web tests (N/4)` shard fails on a pull request, answer with one
command before rerunning, de-flaking or holding the merge:

```bash
python3 scripts/ci/web_test_verdict.py --pr 21651
```

This runs none of the PR's code. It prints one line per failed test file, for example:

> `tests/vm-route-deadlines.test.ts`: **also red on main**. 1 other failure in 7 days (1 on main, 0 other PR branches); vm-route-deadlines.test.ts imports 1 changed file(s); 2 of 2 failure(s) here passed on a re-run of the same SHA

When the test imports changed code, `--coverage` tells you whether it runs any
of it. **`--coverage` runs the PR head's test code on your machine**, with your
`web/node_modules`. Use it only for a PR from this repository whose code you'd
run anyway; the script refuses it for forks.

| Verdict | Meaning | Next step |
| --- | --- | --- |
| likely this PR's | the test imports or runs changed code (or the PR changes the runner) and fails nowhere else | fix the PR |
| touched, also flaky | the PR reaches the test's code, and the test also fails elsewhere | read the diff against the failure; don't assume either way |
| also red on main | the PR can't reach it, and it also failed on main | check main's runs first: main may be broken, not flaky |
| unrelated flake | the PR can't reach it, and it failed on other PRs too | rerun; file or fix the flake separately |
| probably unrelated | the PR can't reach it, and nothing else failed it in the window | rerun the shard; a pass settles it |

`--post` comments the verdict on the PR. Without it, the script only prints.

## The two parts

Each part also runs on its own:

- `scripts/ci/web_test_failure_census.py --file <test> [--test <name>]` lists
  the test's failures over `--days` (default 7), split into main and PRs, with
  job links and whether a re-run of the same SHA passed.
- `scripts/ci/test_touches_diff.py <test> --base <ref> --head <ref> [--coverage]`
  bundles the test with `bun build --metafile` and reports each changed file
  as not imported, tree-shaken, imported, or (`--coverage`) executed or not
  executed. Without `--coverage` it needs only git and bun, not `node_modules`,
  and runs nothing from the head: it bundles a `git archive` copy with macro
  imports stripped and the head's bunfig.toml withheld.

## Cost and limits

- The census reads failed shards' JUnit reports
  (`web-test-junit-shard<N>-attempt<A>` artifacts), which costs about a dozen
  REST calls plus one download per new report. When the window has no
  reports, it falls back to job logs: all of main's failed runs, the PR's
  branch, and a sample of the newest `--max-runs` other failed runs. ci.yml
  fails about 300 times a day, so the fallback costs one call per run it
  reads; it says how many it read.
- A failure counts as main only when it ran on this repository's `main`; a
  fork's `main` is a PR branch.
- Downloads and completed job lists are cached under
  `~/.cache/cmux-ci/web-test-census-v2`. The script checks the REST rate limit
  first and never uses GraphQL.
- The import graph cannot see files a test reads at run time (fs, fetch,
  spawn), `import()` of a computed path, `mock.module()` targets, or deleted
  files; the output says so and lists the deleted files. bun's
  coverage marks only the start of each block, so a changed line counts under
  the block above it. Comment, blank and type-declaration lines are skipped.
