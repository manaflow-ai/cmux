# Is a red web test the PR's fault?

When a `web / Web tests (N/4)` shard fails on a pull request, answer with one
command before rerunning, de-flaking or holding the merge:

```bash
python3 scripts/ci/web_test_verdict.py --pr 21651
```

The CI failure attribution comment names this command, with the test file,
when a red web test isn't one of the PR's files.

On Linux it reads the PR's code only inside a sandbox (see [What runs](#what-runs)). It prints one line per failed test file, for example:

> `tests/vm-route-deadlines.test.ts`: **also red on main**. 1 other failure in 7 days (1 on main, 0 other PR branches); vm-route-deadlines.test.ts imports 1 changed file(s); 2 of 2 failure(s) here passed on a re-run of the same SHA

When the test imports changed code, `--coverage` tells you whether it runs any
of it. **`--coverage` runs the PR head's test code**, with your
`web/node_modules`. Use it only for a PR from this repository whose code you'd
run anyway; the script refuses it for forks.

| Verdict | Meaning | Next step |
| --- | --- | --- |
| likely this PR's | the test imports or runs changed code (or the PR changes the runner) and fails nowhere else | fix the PR |
| touched, also flaky | the PR reaches the test's code, and the test also fails elsewhere | read the diff against the failure; don't assume either way |
| also red on main | the PR can't reach it, and it also failed on main | check main's runs first: main may be broken, not flaky |
| unrelated flake | the PR can't reach it, and it failed on other PRs too | rerun; file or fix the flake separately |
| probably unrelated | the PR can't reach it, and nothing else failed it in the window | rerun the shard; a pass settles it |
| can't analyse safely | the head has an import attribute clause or similar, so no import graph | read the diff yourself; the history is still printed |

`--post` comments the verdict on the PR, editing its earlier verdict comment
rather than adding another. Without it, the script only prints.

## The two parts

Each part also runs on its own:

- `scripts/ci/web_test_failure_census.py --file <test> [--test <name>]` lists
  the test's failures over `--days` (default 7), split into main and PRs, with
  job links and whether a re-run of the same SHA passed.
- `scripts/ci/test_touches_diff.py <test> --base <ref> --head <ref> [--coverage]`
  bundles the test with `bun build --metafile` and reports each changed file
  as not imported, tree-shaken, imported, or (`--coverage`) executed or not
  executed. Without `--coverage` it needs only git and bun, not `node_modules`.

## What runs

- **The sandbox is the guarantee.** bun touches the PR head only in a Linux
  user namespace (`unshare`): no network, its own PID namespace (no
  `/proc/<pid>/root` back to the host), the whole filesystem read-only
  except bun's own work directory (so it can't plant files in another
  checkout), `/tmp`, `/var/tmp`, `/run`, `/dev/shm` and your home directory
  hidden behind empty tmpfs mounts (so no tmux, D-Bus, docker or ssh-agent
  sockets), and
  an environment of just `PATH`, `LANG`, `LC_ALL`, `TERM`
  and a throwaway `HOME` and `TMPDIR`.
- **No sandbox, no bundle.** On macOS, or wherever user namespaces are off,
  the import graph is skipped ("can't analyse safely"; the history still
  prints) unless you pass `--allow-unsandboxed`. That runs bun as you, so use
  it only for a PR you'd run anyway. It's refused for forks, as `--coverage` is.
  For an untrusted PR, use a Linux machine or a throwaway VM.
- **The scan is a second line of defence.** bun runs `with { type: "macro" }`
  imports while bundling, and `--no-macros` doesn't stop it. So the check also
  refuses heads with any import attribute clause, an `import()` with a second
  argument (or one it can't read to its closing parenthesis), a package.json
  mentioning macros, or a symlink. Files are read as UTF-8, and JS line
  terminators and whitespace are normalised first. The head's bunfig.toml is
  read as data and never handed to bun.

## Cost and limits

- The census reads failed shards' JUnit reports
  (`web-test-junit-shard<N>-attempt<A>` artifacts), which costs about a dozen
  REST calls plus one download per new report. When the window has no
  reports, it falls back to job logs: all of main's failed runs, the PR's
  branch, and a sample of the newest `--max-runs` other failed runs. ci.yml
  fails about 300 times a day, so the fallback costs one call per run it
  reads; it says how many it read, and how many it couldn't (an expired log).
  A rate limit partway through stops the census: no partial history is
  reported, since a missing failure could flip the verdict.
- A failure counts as main only when it ran on this repository's `main`; a
  fork's `main` is a PR branch.
- Downloads and completed job lists are cached under
  `~/.cache/cmux-ci/web-test-census-v2`. The script checks the REST rate limit
  first and never uses GraphQL.
- The import graph cannot see files a test reads at run time (fs, fetch,
  spawn), `import()` of a computed path, `mock.module()` targets, or deleted
  files; the output says so and lists the deleted files. bun's
  coverage marks only the start of each block, so a changed line counts under
  the block above it. Comment, blank and type-declaration lines are skipped. A
  change that only deletes lines counts as the lines on either side of it.
