# Dedicated cmux-next nightly builder Mac

> **Moved 2026-10-25.** All nine M6 minis (cmux16..cmux24) are reserved for the cmux Performance Lead
> (Lawrence). The nightly-next builder now runs on cmux7s (M4 Pro, runner `cmux7s-mac-mini-nightly-next`, `CI_NIGHTLY_NEXT_TRUSTED_RUNNER=glaeda-runner-cmux7s-mac-mini-nightly-next`). It keeps `/Users/cmux` paths (no `/Users/runner` link: that needs sudo), so a paired Linux darling parity run has no matching profile. Install with `scripts/ci/nightly-builder-install.sh HOST`; the old M6 runner is removed.

Owner: Chief subagent "Dedicated nightly builder Mac" (2026-10-20). User ask: "one machine whose job is
always to build the nightly ... nightlies for cmux-next nightly never, ever get
blocked, ever."

## What was slow (measured 2026-10-20)

- The cmux NEXT app build (`nightly.yml` job `build-nightly-app`) ran on
  `cmux15-glaeda-1`. That runner also carries the shared trusted pool label
  `glaeda-trusted-std-xcode-26.6`, so `seed` jobs land on it between nightlies
  (06:16Z to 07:10Z: four nightly builds, then a `seed` job held the runner).
  cmux15 also runs fuzz, seed prefetch, idle-warm, a cua driver and main's
  NIGHTLY runner, so one build took 13 to 28 minutes.
- A nightly-next push run waited in `build-nightly-app` while the runner was
  busy (run 39383410626 queued 06:58Z, still queued 07:11Z).
- Push to publish on a good run (39374887542): helper 7 min, app 11 min,
  variant 5 min, sign and notarize 15 min, verify 3 min, publish 2 min:
  about 43 min after the nightly-next push.

## Decision

1. **Host: `cmux22`** (Apple M6, 16 GB, 245 GB disk, 132 GB free, macOS 27,
   Xcode 26.6, user `cmux`). It is a held worker: not in the cmux-ci
   controller pool, no GitHub runners, idle. Not cmux10s/cmux11s (full disks),
   not cmux20 (a153 benchmark), not cmux14 (12 runners, 22 GB free), not cmux15
   (shared; 84 GB free).
2. **One GitHub Actions runner on cmux22, used only by the nightly.** Name
   `cmux22-nightly-next`, labels (no default labels):
   `glaeda-trusted-light-xcode-26.6`, `glaeda-runner-cmux22-nightly-next`,
   `glaeda-trusted-next-nightly`. No other workflow asks for
   `glaeda-trusted-light-xcode-26.6`, so nothing else matches it. The repo
   variables point the NEXT build there:
   `CI_NIGHTLY_NEXT_TRUSTED_POOL=glaeda-trusted-light-xcode-26.6`,
   `CI_NIGHTLY_NEXT_TRUSTED_RUNNER=glaeda-runner-cmux22-nightly-next`. Both
   values pass `scripts/ci/runner_label_policy.py`, and the owned-pool rescue
   still watches the run (its `glaeda-trusted-`/`glaeda-runner-` prefixes).
3. **Admission hook** (`scripts/ci/nightly_builder.py admit`, the runner's
   `ACTIONS_RUNNER_HOOK_JOB_STARTED`): admits only repo `manaflow-ai/cmux`,
   workflow `nightly.yml`, job `build-nightly-app`, event `push`, ref
   `refs/heads/nightly-next`, with at least 40 GiB free. Anything else fails
   before its first step. This is the reservation: no seed, PR, test, bench or
   main NIGHTLY job can run on cmux22 even if a label is misconfigured.
4. **Coalescing stays in GitHub.** `build-nightly-app` on nightly-next already
   shares one concurrency slot (`nightly-next-build-app-warm`,
   `cancel-in-progress: false`): one build runs, at most one waits, and a newer
   push replaces the waiting one. So after a build ends, the newest head builds
   next, and no backlog forms.
5. **Trigger stays event-driven, not cron.** `cmux-next.yml` asks main's
   `promote-nightly-next` to move `nightly-next` as soon as the head's Release
   compile gate is green (no debounce; `NIGHTLY_NEXT_MIN_INTERVAL_HOURS=0.25`).
   The push to `nightly-next` starts the build at once. The schedule crons in
   `nightly.yml` never build NEXT.
6. **Signing, notarization and publication stay in GitHub Actions**, in the
   `release-next` environment, on ephemeral hosted runners, unchanged. The
   Developer ID certificate, notary key, Sparkle key and upload keys never
   leave GitHub. A local launchd build-and-publish loop would need those
   secrets copied to a Mac (a credential step) and a second publisher beside
   the guarded one (double-publish risk), so it is not done.
7. **Warm cache.** By design the shipped app never builds on incremental
   DerivedData (stale autolink objects; see "Start Release DerivedData
   empty"). The warm state that stays on cmux22 between builds:
   the content-keyed Xcode compilation cache
   (`~/Library/Caches/cmux-nightly-next`, `nightly_build_state.py`), SwiftPM
   checkouts (`.spm-cache`), the cargo target (`Swatinem/rust-cache` plus the
   persistent work dir), web bundle caches and the Zig cache. On a dedicated
   runner these are never evicted by other jobs.

## The launchd loop (`scripts/ci/nightly_builder.py watch`)

LaunchAgent `ai.manaflow.nightly-builder.watch` on cmux22, every 60 s:

- `git ls-remote` for `feat-cmux-next` and `nightly-next` (no credential).
- Every 5 min, the newest `nightly.yml` runs on `nightly-next` from the public
  Actions API (unauthenticated, 12 calls per hour).
- Whether the runner listener is alive (LaunchAgent
  `ai.manaflow.nightly-builder.runner`, `KeepAlive`), and its last job lines
  from `_diag`.
- Free disk.
- Writes `~/Library/Application Support/nightly-builder/status.json` and one
  JSON line per change to `~/Library/Logs/nightly-builder.log`.
- Health (`status` field): `ok`, or `alert` with reasons:
  - `runner-down`: no `Runner.Listener` process.
  - `disk-low`: under 40 GiB free.
  - `build-failed`: the newest nightly-next run concluded `failure`.
  - `stale`: `nightly-next` moved more than 75 min ago and no run on it
    succeeded since.
  An alert posts a macOS notification once per new reason and is shown by
  `status`. The workflow's own `report-nightly-failure` issue stays the
  primary failure alert.
- Cleanup: deletes runner `_diag` logs older than 7 days and `_work/_temp`
  entries older than 1 day. It never deletes the compilation cache, SwiftPM,
  cargo or Zig caches. The workflow itself clears `build-universal` and the
  old archives at the start of each build.

Status from anywhere on the tailnet:

```bash
ssh cmux22 'python3 ~/nightly-builder/nightly_builder.py status'
```

## Blacksmith paths (2026-10-20 09:35 UTC)

A build records its paths in the shipped bytes (Swift `#file`, SwiftPM and
cargo registry paths, panic messages). The byte-parity reference is a
Blacksmith macOS build: user `runner`, `HOME=/Users/runner`, workspace
`/Users/runner/_work/cmux/cmux`, `RUNNER_TEMP=/Users/runner/_work/_temp`,
`CARGO_HOME=/Users/runner/.cargo`. So the runner on cmux22 now uses the same
paths, as real directories:

- `/Users/runner` is a real directory owned by `cmux` (made with sudo, mode
  755), with `Library/{Caches,Logs,Preferences}` and `.cache`. The runner
  still runs as `cmux` from `~/actions-runner-nightly-next`.
- `.runner` `workFolder` is `/Users/runner/_work` (was `_work`). The runner
  resolves it as an absolute path, so the workspace and `RUNNER_TEMP` are
  under `/Users/runner/_work`, with no link in the path.
- The runner's `.env` sets `HOME=/Users/runner`, and its `PATH` names
  `/Users/runner/.cargo/bin`. Every `$HOME` path of a job (`CARGO_HOME`,
  `RUSTUP_HOME`, Go, Bun, Zig, SwiftPM and Xcode caches, and
  `nightly_build_state.py`'s `~/Library/Caches/cmux-nightly-next`) is then
  under `/Users/runner`. The first build after the move downloads its
  toolchains again.
- `~/actions-runner-nightly-next/_work` is a link to `/Users/runner/_work`
  only so that the watch loop's `_work/_temp` cleanup keeps working. Jobs do
  not use that link. The old folder is `_work.old-20261020`; the old files are
  `.runner.bak-20261020` and `.env.bak-20261020`.
- The admission hook, both LaunchAgents, the runner name and its labels did
  not change.

Rollback: `launchctl bootout gui/$(id -u)/ai.manaflow.nightly-builder.runner`,
restore `.runner` and `.env` from the `.bak-20261020` copies, replace the
`_work` link with `_work.old-20261020`, then `launchctl bootstrap` the plist.

## Gate daemon tests on cmux22 (2026-10-21, proposed)

On 2026-10-21 nightly-next stopped at ff8d849c for more than 2 h. Each
feat-cmux-next push's `cmux_next_ daemon tests (macOS)` waited on
`CI_NEXT_DAEMON_POOL=glaeda-side-std-xcode-26.6`, which is the same label as
`CI_SIDE_LANE_RUNNER`. About 50 PR and lane jobs share that label, and GitHub
gives a gate job no priority among them. Without a daemon-tests marker no tree
can be promoted.

- A second runner on cmux22, `cmux22-next-gate`, with only the label
  `glaeda-runner-cmux22-next-gate`. Its job-started hook runs
  `nightly_builder.py admit --role next-gate`, which admits only
  `cmux-tui-artifacts.yml` job `cmux-next-daemon-tests` for a push to
  `refs/heads/feat-cmux-next`. The role is an argument of the hook script, not
  a job variable, so a job cannot choose it.
- `CI_NEXT_DAEMON_POOL=glaeda-runner-cmux22-next-gate`. Only attempt 1 of a
  feat-cmux-next push reads it.
- When a gate job gets the runner, attempt 1 of a feat-cmux-next push skips
  its tests if the branch head has a different key whose tree is published:
  the head's run tests that tree, and only the newest tested tree is
  promoted. An old job then takes about a minute, so one runner keeps up. A
  branch-wide concurrency group was rejected: an older push that reaches the
  group later replaces the head's waiting job. Trade-off: if the head's tests
  fail, the skipped older key stays unmarked until a later run tests it.
- `scripts/ci/nightly-builder-install.sh` writes a plain `admit` hook. The
  gate runner's hook must call `admit --role next-gate` (follow-up with the
  runner registration).

## Fallback

The GitHub-hosted path is the fallback with no extra switch: a retry
(attempt 2) or a dispatch of `nightly.yml` builds on `macos-26`, as before. To
go back to cmux15 set the two variables back to
`glaeda-trusted-std-xcode-26.6` and `glaeda-runner-cmux15-glaeda-1`. Only one
publisher exists, the guarded `publish-nightly` job, so the two paths never
double-publish.

## Not done (follow-ups)

- The Release compile gate in `cmux-next.yml` still runs on cmux14 (the
  promote pool). A red head blocks promotion until the next green head. That is
  intended: it is the only check before a build is shipped.
- Hosted helper, variant and signing jobs (about 30 min of the path) stay on
  GitHub-hosted runners, where signing secrets are allowed.
- cmux22 builds every head cold. `scripts/ci/nightly_build_state.py`
  keeps the compilation cache only for a runner name that matches
  `*-glaeda` or `*-glaeda-N`, and `cmux22-nightly-next` does not match.
  Run 39396919366 on cmux22: 425 compile cache misses and 1 hit, `xcodebuild`
  505 s, job 17.8 min. Run 39374887542 on cmux15: 21 misses, `xcodebuild`
  254 s, job 11.6 min. cmux22 did not swap during a build (swap 0 MB,
  75 % memory free by `memory_pressure`, load 17 on 12 cores).
