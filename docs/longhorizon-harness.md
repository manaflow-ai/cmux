# Sustained agent tasks with LongHorizon-Harness

[日本語](longhorizon-harness.ja.md)

[LongHorizon-Harness](https://github.com/AMAP-ML/LongHorizon-Harness) is an
optional external task runner that can run in a cmux terminal. It carries a
goal across execution rounds, starts each round with fresh agent context, and
uses a separate Auditor to check results before accepting progress. cmux
provides the terminal, workspace, browser, and notification surfaces around
that loop. This example uses their existing command-line interfaces; cmux does
not bundle the harness or provide a dedicated adapter.

## State ownership

| Responsibility | Owner |
| --- | --- |
| Goal, next step, accepted progress, audit evidence, and recovery | LongHorizon-Harness |
| Executing a bounded step with its configured tools | The selected agent runtime |
| Terminal layout, scrollback, browser panes, and attention routing | cmux |

The harness's Manager chooses a step, its Executor performs it, and its Auditor
checks the resulting files, tests, or application state. Failed verification
becomes evidence for another round. Keep that ledger as the source of truth:
terminal output, an idle agent hook, a notification, and a successful process
exit do not establish that the task passed its acceptance criteria.

cmux [session restoration](../README.md#session-restore) can restore a supported
agent's conversation. It does not checkpoint the harness's task or resume its
outer loop. Resuming a child agent independently can bypass the harness's next
audit; use the harness's recovery controls for harness-managed work.

## Run a bounded task

Follow the harness's [installation and configuration instructions](https://github.com/AMAP-ML/LongHorizon-Harness#one-command-full-visibility)
and authenticate an agent runtime it supports. A terminal-only task does not
need a computer-use plugin.

In a cmux terminal, enter a dedicated project checkout or worktree. Create
`task.md` there with the goal, allowed changes, and concrete acceptance checks.
For a first trial, ask for an inventory of a small fixture directory with no
file modifications. Initialize the project configuration:

```sh
lh-harness init
```

`init` creates `.lh-harness/config.toml` without overwriting an existing file.
Select your authenticated agent and compatible models for each role, and review
the timeouts. Run the trial with that configuration:

```sh
lh-harness run --task @task.md --max-rounds 3 --dashboard --dashboard-no-open
```

The three-round limit bounds the trial; it does not guarantee completion or
impose a total spending limit. The working directory is where the agent acts.
The dashboard records the worker's ownership for later recovery without opening
a browser automatically. A run started with `--no-dashboard` lacks that managed
ownership and appears as read-only history in the workbench.

By default, run state lives under `.lh-harness/runs/<run-id>/`. Preserve this
directory and the project files together, and keep private logs and task state
out of version control. If interrupted, inspect the existing run through the
harness workbench:

```sh
lh-harness web --workspace-root . --port 0 --no-open
```

Open the printed local URL, optionally in a cmux browser pane. Inspect the
run's audit evidence and use its available continuation controls. Keep the
same configured runs root and ensure the previous worker has stopped before
continuing. Repeating `lh-harness run` normally creates a new run, not a resume.

## Route attention to the task

An integration script can notify the terminal's workspace when the harness
needs human review. Run this from the cmux terminal that owns the task:

```sh
cmux notify \
  --workspace "${CMUX_WORKSPACE_ID:?Run inside the task's cmux terminal}" \
  --surface "${CMUX_SURFACE_ID:?Run inside the task's cmux terminal}" \
  --title "Task needs review" \
  --body "Inspect the harness audit and remaining work before continuing."
```

Connect notifications to an actual harness state transition or a manual review
decision. The snippet sends a notification only; it does not install a harness
hook or accept progress. A failed notification must not change the task ledger.
For background controllers, capture the owning workspace and surface when the
task starts, revalidate them after restoration, and never retarget a missing
surface to whichever terminal is focused.

See [notifications](notifications.md) and [agent hooks](agent-hooks.md) for
cmux's existing integration points. The harness commands and recovery behavior
were checked against [upstream revision a1dd930](https://github.com/AMAP-ML/LongHorizon-Harness/tree/a1dd930614972b92361c1b9cd6aac441a6db5a65);
consult your installed version's help when its interface differs.
