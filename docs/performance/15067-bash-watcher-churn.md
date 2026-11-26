# Bash watcher process churn (#15067)

The bash integration no longer ships the obsolete per-pane PR poller. Git
filesystem watching and GitHub polling already belong to cmux. Bash still
reports the current directory and branch at prompts, clears stale PR badges
when HEAD changes, and sends successful PR command hints to the app.

## What the audit found

At `0485e93ec0`, the two reported bash countdowns were:

| Function | Work while active | Lifecycle |
| --- | --- | --- |
| `_cmux_start_pr_poll_loop` | One `sleep 1` per countdown tick, between 45-second PR probes | Disowned child; stopped by a process-group kill or parent PID/start-time guard |
| `_cmux_run_pr_probe_with_timeout` | One `sleep 1` per tick while a probe runs; up to two `sleep 0.2` calls during timeout cleanup | Child of the poller; supervises the PR probe and its descendants |

These are nested phases of one poller, not two simultaneous bash watchers.
The poller has **no production caller** on this revision or on the reported
`v0.64.25` tag (`b685a275c2`). [#2585][2585] had
already moved PR polling into the app; tests for [#10926][10926] explicitly
invoked the leftover function. Bash has no persistent HEAD watcher either.
Its HEAD read happens at the prompt. The zsh HEAD watcher is still called from
preexec and is outside this change.

The report of about 160 sleeps/second across 166 panes on cmux 0.64.25 is useful
incident evidence, but this audit does not establish that those processes came
from the current bash prompt path. It cannot establish a reduction in the
reported 12 GB/hour of security logs. Existing shells retain sourced function
bodies after an app update; removing the resource does not hot-patch or kill
watchers already running from older integrations.

## Why remove the timer instead of replacing sleep

Apple's bash 3.2 has an integer `read -t`, but reading `/dev/null` immediately
returns EOF; it is not a timer. Reading the terminal would consume user input
and is unsafe in a background job. A private FIFO held open for both reading
and writing can support integer timed reads, but requires safe creation,
descriptor ownership, and cleanup, cannot use EOF to detect the parent while
the child retains its own writer, and does not handle the 0.2-second waits on
bash 3.2. A new helper process would merely move the process cost.

None is justified for an unused subsystem. Removing the poller, its private
GitHub/config parser, cache-file support, timeout tree-killer, identity helpers, and
no-op lifecycle calls eliminates that executable path. No interval changes,
new shell descriptors, or replacement per-pane daemons are introduced. The
remaining bash cleanup of its active-directory marker is retained.

Bash also stops checking for retired PR cache/force-signal files at prompts,
preexec, environment changes, and cleanup. Any files left by an older shell
are left untouched; current bash neither reads nor creates them. Keeping a
cache cleanup path indefinitely would add filesystem work for an owner that
no longer exists. Zsh's legacy cache cleanup still has its own coverage.

## Existing app ownership

- `CmuxSidebarGit/SidebarGitMetadataService` owns FSEvents-backed
  `RecursivePathWatcher` instances. Registrations share a watcher by watched
  paths, event-filter identity, and coalescing interval. Worktree-specific paths
  remain distinct. Panel/directory changes release membership; the last member
  releases the native watcher and event consumer. Workspace removal cancels
  pending registrations, and generation checks reject stale completions.
- `CmuxSidebarGit/PullRequestPollService` owns cancellable poll deadlines and
  per-workspace/panel state. `CmuxGit/PullRequestProbeService` groups candidates
  by repository slug and fetches repository results once per refresh group,
  using the shared short-lived repository cache. Existing selected/background
  cadence, command-hint handling, and transient-error behavior are preserved.
  Panel/workspace removal prunes tracking; reset/deinit cancels outstanding work.
- Deduplication is within each `TabManager` service instance, not a new
  application-wide registry across windows. Cross-window sharing and remote
  filesystem monitoring would need their own ownership design. This change
  does not expand local watchers into remote paths or change remote reporting.

## Proof and limits

Run `python3 tests/test_issue_15067_bash_watcher_churn.py` with `/bin/bash`.
It uses private shells, scratch repositories and a socket, intercepts each
external `sleep` launch through PATH, and executes the real delay. Python owns
the 2.2-second observation window so the driver adds no shell sleeps. The
legacy case bypasses GitHub and Darwin identity lookup to isolate countdown
cost. It explicitly invokes the old function only when available; it is not
represented as a normal prompt workload or a measurement of all shell forks.

| Workload | Regression commit `919887c824` | After removal |
| --- | --- | --- |
| Prompt, branch change and PR merge hint, two shells | 0 sleeps; correct branch, clear and action reports | 0 sleeps; same reports |
| Explicit legacy poller invocation, four shells | 3 sleeps each (12 total); assertion fails | 0 sleeps; assertion passes |

The second row reproduces roughly one sleep launch/second/poller, with an
immediate first tick. It is not evidence of a new runtime speedup on current
main, whose normal prompt case already passed. Removing the unused supervisor
also removes its timeout sleeps; that phase is identified by the call-site
audit, not independently timed by this countdown benchmark.

Additional shell checks cover PR hints and HEAD changes (#1138), interactive
bash job notifications, zsh PID reuse/zombie-parent/parent-death teardown
(#10926), and the remaining zsh config parser. The launch and #1138 tests run
in the Linux guard job, including on thin PRs that skip the macOS shell lane;
bash 3.2 is exercised locally on macOS. No local native app build or live app dogfood is
part of this shell-only proof; app watcher sharing and lifecycle were audited
in the existing owners and their tests, not reimplemented here.

## Related work

[#2924][2924] by Taylor Steil first proposed removing the abandoned PR pollers
from both shells. This change adopts and credits its bash cleanup approach,
adds launch/lifecycle proof, and leaves its zsh cleanup available separately.
[#6032][6032] by Josh Samuel optimizes the still-active zsh HEAD watcher with
`zsh/zselect`; it remains necessary for that launch source. The zsh identity
guards and teardown coverage from [#10926][10926] remain intact.

[2585]: https://github.com/manaflow-ai/cmux/pull/2585
[2924]: https://github.com/manaflow-ai/cmux/pull/2924
[6032]: https://github.com/manaflow-ai/cmux/pull/6032
[10926]: https://github.com/manaflow-ai/cmux/issues/10926
