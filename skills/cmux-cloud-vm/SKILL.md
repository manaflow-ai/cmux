---
name: cmux-cloud-vm
description: Drive cmux Cloud machines (persistent cloud VMs) from the CLI — `cmux vm run` routes commands to a machine automatically (no ids), plus create, exec, push/pull files, ports, checkpoints, forks, desktops. Use when an agent should run builds, tests, servers, or experiments on a cloud machine instead of the local Mac, or when the user says "cloud machine", "cloud VM", "run it in the cloud", or "cmux vm".
---

# cmux Cloud Machines

Everything the Machines sidebar can do, from the CLI — plus agent-only primitives (`exec`, `push`, `pull`, `wait`). Requires the cmux app running and a signed-in account (`cmux auth status`, `cmux auth login`).

- **Machine**: a persistent cloud VM (`cmux vm ls`). It sleeps when idle (free while asleep) and wakes on connect or exec; home survives sleep.
- **Box types**: Desktop (default image, has a screen reachable over noVNC) and Base (`--base`, shell-only).
- **Base**: one pinned persistent slot (`cmux vm base open`) that reuses the same VM every time.
- **Checkpoint / fork**: `snapshot` mints a restorable checkpoint; `fork` clones a machine for a parallel experiment.
- **Plan meter**: `cmux vm ls` prints "N of M machines". At the limit, creates fail with an upgrade action — never delete machines to make room without asking the user.

## Fast start — let the router pick the machine

You usually don't need a machine id at all. `cmux vm run` routes for you: it reuses the warm machine bound to your current directory, else an idle pool machine, wakes a sleeper, or provisions a fresh one — then passes the exit code through.

```bash
cmux vm run -- uname -a                                  # zero setup: routed, executed, done
cmux vm run --sync -- bun test                           # push cwd to work/<dir> first, run there
cmux vm run --sync --pull work/app/dist -- sh -c 'cd work/app && bun run build'
```

Repeat runs from the same directory hit the same machine (sticky binding), so synced checkouts and installed dependencies stay warm. `--new` forces a fresh machine; `--machine <id>` pins one.

## Named-machine primitives

```bash
cmux vm ls --json                       # fleet + plan meter; reuse before creating
cmux vm new --base --detach --json      # shell-only machine, no UI churn; prints the id
cmux vm wait <id> --wake                # block until ready and awake
cmux vm exec <id> -- uname -a           # run a command; exit code passes through
cmux vm push <id> ./myrepo work/myrepo  # copy a dir up (no SSH needed; .git etc. skipped)
cmux vm pull <id> work/out.tgz          # copy results back
cmux vm open <id> 3000 --print          # mint a private tokened URL for an HTTP port
cmux vm shell <id>                      # show the human: terminal pane in their cmux
cmux vm desktop <id>                    # show the human: the machine's screen (desktop boxes)
```

Every subcommand honors the global `--json` flag and exits non-zero on failure; `vm exec` and `vm run` pass the remote exit code through and keep stdout/stderr separated. This works for any agent — Claude Code, Codex, or open-source-model harnesses — it's all plain CLI.

## Agent policy

- **Prefer `vm run` over naming machines.** It reuses/wakes/provisions only machines it provisioned itself (recorded in `~/.cmuxterm/vm-run-pool.json`, shown as `agent-pool` in `vm ls`) and never drafts machines the user created by hand — `--machine <id>` is the deliberate way to use one. Machines are the user's paid, limited resources.
- **Reuse before create** when you do name machines: `cmux vm ls` first; prefer an existing idle machine or `vm base open`.
- **Stay headless while working.** `vm new --detach`, then `exec`/`push`/`pull`. `vm shell` (a cmux-tui session — the machine's session daemon is cmux-tui), `vm desktop`, and `vm open` (without `--print`) open panes in the user's app — use those to *show* results, not to do the work.
- **Checkpoint before risky operations** (`cmux vm snapshot <id>`), and fork instead of experimenting on a machine the user relies on.
- **Only destroy what you created this session.** `vm rm` permanently deletes the machine and everything on it; confirm with the user otherwise.
- **Surface URLs and evidence proactively.** The user cannot see inside the machine. Print the `vm open --print` URL, pull artifacts, or open a shell/desktop pane when done, and `cmux notify` for long-running work.
- **Only share URLs minted by `cmux vm open`.** They are private and token-authenticated (and expire). Never reconstruct or guess raw provider preview URLs.

## Common issues and fixes

| Symptom | Fix |
|---------|-----|
| `vm exec` hangs or times out on a long command | Exec is capped (~30 s default). Background it: `cmux vm exec <id> -- sh -c 'nohup make build > /tmp/build.log 2>&1 &'`, then poll `tail -n 20 /tmp/build.log`. |
| First command after idle is slow or flaky | The machine was asleep. `cmux vm wait <id> --wake` first. |
| `vm new` opened a workspace in the user's app | Pass `--detach` (`-d`) in agent flows. |
| `vm ssh` errors on the default provider | SSH is provider-dependent. Use `vm exec` for commands and `vm shell` for an interactive pane. |
| Create fails with an active-limit error | The plan is at its machine cap. Report it and let the user upgrade or choose a machine to remove — don't pick for them. |
| Need to send file content into the machine | Don't inline big content in `exec` argv — `cmux vm push <id> <local> [remote]` (SHA-256 verified). |
| Pushed a repo but `.git` is missing | `push` skips `.git`, `node_modules`, `.venv`, `__pycache__`, `.DS_Store` by default. Pass `--no-default-excludes`, or ship history as a bundle (see workflows). |
| Push/pull refuses a large payload | Exec-chunked transfer caps at 256 MB. Clone/download inside the machine (`vm exec <id> -- git clone …` / `curl -LO`). |
| Command works in `vm shell` but not `vm exec` | Exec is non-interactive and has no TTY/stdin. Use flags that skip prompts, or script the input. |

## Deep-dive references

| Reference | When to Use |
|-----------|-------------|
| [references/commands.md](references/commands.md) | Exhaustive `cmux vm` command list with examples |
| [references/agent-workflows.md](references/agent-workflows.md) | Recipes: cloud dev box from a local repo, cloud builds/tests, parallel forks, showing the human |
| [../cmux/SKILL.md](../cmux/SKILL.md) | Windows/workspaces/panes when presenting machine panes |
| [../cmux-workspace/SKILL.md](../cmux-workspace/SKILL.md) | Non-disruptive automation rules (focus, caller workspace) |
