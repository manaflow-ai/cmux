---
name: cmux-cloud-vm
description: Route work to cmux Cloud machines (persistent cloud VMs) from the CLI — `cmux vm route`/`run`/`agent` pick a machine for you; `vm tree` / `surface ls` show the surface catalog (This Mac and every machine: terminals, VNC screens, browsers) and `vm open` / `surface open` put any of them in a pane; plus create, exec, push/pull, ports, checkpoints, forks. Use when an agent should run builds, tests, servers, desktop/browser tasks, or another agent on a cloud machine instead of the local Mac, or when the user says "cloud machine", "cloud VM", "run it in the cloud", or "cmux vm".
---

# cmux Cloud Machines

Everything the Cloud sidebar can do, from the CLI — plus agent-only primitives (`route`, `run`, `agent`, `exec`, `push`, `pull`, `wait`). Requires the cmux app running and a signed-in account (`cmux auth status`, `cmux auth login`). All of it is plain CLI, so it works for Claude Code, Codex, OpenCode, Pi, or any harness — and `cmux vm prompt` bootstraps an agent that has no skill loaded: it installs the app-bundled cmux-cloud skill at `~/.config/cmux/skills/cmux-cloud.md` and prints a kickoff prompt pointing at it (`--open <agent>` starts a local agent terminal with that prompt directly).

## What a machine is

| Term | Meaning |
|------|---------|
| **Machine** | A persistent cloud VM (`cmux vm ls`). Sleeps when idle (free while asleep), wakes on connect or exec. `/root` is a 16 GB persistent volume; the rest of the filesystem is disposable compute. |
| **Contents** | Ubuntu 22.04 (xfce desktop image, the default): node 22, bun, uv, git, gh, ripgrep, fd, jq, tmux, xdotool. **Claude Code, Codex, OpenCode, and Pi are preinstalled** under `/root/.npm-global/bin`. The desktop runs TigerVNC + noVNC and the CUA driver (`cua-computer-server`) for computer-use agents. Provisioning runs in the background on first boot — `cat /tmp/cmux/provision.log` on a brand-new machine if a tool is missing. |
| **Session** | Every machine runs the **cmux-tui remote daemon**: its own workspaces → terminals, visible in `cmux vm tree`. A terminal you start there keeps running when the Mac disconnects. |
| **Surface** | A terminal, VNC screen or browser — on This Mac or on a machine — with a stable id `<machine>/<kind>/<key>` (`cmux surface ls --json`). Panes *project* surfaces: `cmux surface open <id>` reuses the pane already showing one, or lands it at a pane edge you choose; closing a pane never kills a machine's terminal. |
| **Base** | The one pinned persistent machine (`cmux vm base open`) — use it for the user's ongoing work. |
| **Pool** | Machines the router provisioned for agent work (`agent-pool` in `vm ls`). `vm run`/`vm agent` only draft these; hand-made machines need `--machine <id>`. |
| **Plan meter** | `cmux vm ls` prints `N of M machines`. Free plans get **1 machine and a 7-day cloud window**; `vm ls --json` carries `limits.freeAccessExpiresAt`. At the cap, creates fail with an upgrade action — never delete machines to make room without asking. |
| **Checkpoint / fork** | `snapshot` mints a restorable checkpoint; `fork` clones a machine for a parallel experiment. |

## Decide: cloud or local?

| Run in the cloud when… | Stay local when… |
|------------------------|------------------|
| Builds/tests take minutes, need Linux, or would hog the user's Mac | The task is a quick edit or read |
| The task needs a desktop, browser automation, or a screen the user can watch (`vm open <m>:desktop`) | The user is editing the same files right now |
| You want isolation (fork per experiment, throwaway machine) | The repo has uncommitted local-only state you cannot sync |
| You want to fan out: several agents on several machines in parallel | |
| The user said "cloud", "machine", "VM", or the sticky machine for this directory already has a warm checkout (`cmux vm route`) | |

## Fast start — let the router pick

```bash
cmux vm route                                            # which machine would be used for this directory, and why
cmux vm run -- uname -a                                  # routed, executed, exit code passed through
cmux vm run --sync -- bun test                           # push cwd to work/<dir> first, run there
cmux vm agent --agent claude --sync -- "run the tests and fix failures"   # a detached Claude Code session on the routed machine
cmux vm tree                                             # the surface catalog: This Mac, then every machine, workspace, terminal, desktop, port
cmux vm open vivid-newt/main/term_2f9c                   # show the human one terminal (reuses its pane if open)
cmux surface open vivid-newt/display/display:1 --pane pane:2 --left   # any surface, at a pane edge (same drop rules as the sidebar)
```

Repeat runs from the same directory hit the same machine (sticky binding), so synced checkouts and dependencies stay warm. `--new` forces a fresh machine; `--machine <id>` pins one.

## Picking a machine

1. `cmux vm route` — the router's answer for this directory; `--json` for scripts. If it says it *would provision*, that costs a machine slot: check `cmux vm ls` first.
2. Ongoing user work → Base (`cmux vm base open`, or `--machine <base-id>`).
3. Isolation → `cmux vm new --detach --json` (desktop machine) or `--base` (shell-only); add `--size 8g`/`--name <label>` as needed. The CLI requests a machine *kind*; never pass `--image` unless you have a specific image id. Then `--machine <id>`.
4. Never draft the user's own named machines without `--machine`, and respect the plan meter.

## Running work

Opening a machine (`cmux vm shell <id>`, `vm new`, `vm base open`, the sidebar) gives a **plain terminal** on it — one terminal in the machine's cmux-tui session, attached in a pane like an ssh session; it keeps running if the pane closes and shows up in `cmux vm tree` (reattach with the `cmux vm open <m>/<ws>/<term>` address the `OK` line prints). `cmux vm tui <id>` is the only command that opens the full cmux-tui client.

```bash
cmux vm run --sync --pull work/app/dist -- sh -c 'cd work/app && bun run build'
cmux vm agent --agent codex --machine <id> -- exec "summarize work/app"       # args pass through when they start with a flag/subcommand
cmux vm agent --agent opencode --no-open --json -- "add a README"             # headless; prints terminal + reattach address
cmux vm exec <id> -- <command...>       # one command, non-interactive, ~30 s default cap
cmux vm push <id> ./repo work/repo && cmux vm pull <id> work/repo/out.tgz
cmux vm wait <id> --wake                # block until ready and awake
cmux vm terminal send <id> <term> 'bun test' --keys enter     # drive a machine terminal headlessly: type, then press keys (no pane, no focus)
cmux vm terminal wait <id> <term> --pattern 'pass|fail' --timeout 300   # block until the screen matches; exit 1 on timeout
cmux vm terminal read <id> <term>       # the visible screen — what a person at that terminal sees
```

`terminal send/wait/read` is the interactive counterpart of `exec`: a REPL, a TUI, a long test run, or another agent's session on the machine can be driven and observed without attaching a pane or stealing focus. Start the program with `cmux surface new-terminal --machine <id> --no-open -- <cmd>` (its `term_…` id comes back on the OK line), then loop send → wait → read.

`vm agent` starts the agent as a **detached terminal in the machine's cmux-tui session**: it survives closed panes and reconnects from any device (`cmux vm open <machine>/<ws>/<term>`). Long shell work should also be backgrounded (see recipes) — never hold a long `exec` open.

## Watching and reporting back

```bash
cmux vm tree <id>                       # live: terminals with title, cwd, agent state, (open: surface)
cmux vm open <id>                       # the machine's shell (+ its screen on desktop machines)
cmux vm open <id>/<ws>/<term>           # one terminal as a pane; reuses the pane already showing it
cmux vm workspace open <id> <ws> [--here|--tabs|--pane <p> --left]   # a whole workspace: new local workspace, or into this one
cmux vm workspace rename <id> <ws> <name>   # rename it; `close` keeps its terminals (they detach into the pool), `rm` deletes it AND kills them
cmux vm open <id>:desktop               # the noVNC screen
cmux vm open <id>:port/3000 [--print]   # private tokened URL for an HTTP port (--print: URL only)
cmux surface ls --json                  # every surface (local + cloud) with ids, lifecycle, and which panes show it
cmux surface open <resource> [--new] [--pane <p> --left|--right|--up|--down|--tab]   # one open path for all of them
cmux surface new-terminal --machine <id> --cwd /root/work/app -- bun test          # a terminal on the machine, opened as a pane
cmux notify --title "Cloud build done" --body "…"
```

The user cannot see inside the machine: print URLs, pull artifacts, or open a pane when there is something to look at, and `cmux notify` for long work. Only share URLs minted by `cmux vm open` — never guess raw provider URLs.

A pane showing a machine surface is an ordinary local pane: move, split, reorder, or close it with the local topology verbs (`../cmux/SKILL.md`) and the surface catalog follows the pane; closing a pane never kills the machine's terminal. Rearranging the machine's own cmux-tui topology from inside is what `cmux vm tui <id>` is for.

## CodeRouter and model credentials

CodeRouter routes **model credentials**, not compute. An agent started with `vm agent` inside a machine authenticates the same way it would locally (its own login, or CodeRouter's env/config in the machine's `/root`); set that up once on the machine (`vm exec <id> -- …`) and it persists on the volume. Do not put the user's tokens on a machine unless they ask.

## Agent policy

- **Prefer `vm route` / `vm run` / `vm agent` over naming machines.** They only draft pool machines; `--machine <id>` is the deliberate way to use another.
- **Reuse before create.** `vm ls`, then an idle machine or Base. Free plans: one machine, 7 days.
- **Stay headless while working** (`--detach`, `--no-open`, `--print`); open panes (`vm open`, `vm tree`'s addresses) to *show* results.
- **Checkpoint before risky operations** (`vm snapshot`), fork instead of experimenting on a machine the user relies on.
- **Only destroy what you created this session.** `vm rm` is permanent.

## Common issues and fixes

| Symptom | Fix |
|---------|-----|
| `vm exec` hangs or times out | Exec is capped (~30 s default). Background it: `nohup … > /tmp/x.log 2>&1 &`, then poll — or use `vm agent` / a terminal in the session for long work. |
| `claude`/`codex` not found on a brand-new machine | Provisioning is still running: `cmux vm exec <id> -- tail /tmp/cmux/provision.log`; the agents land in `/root/.npm-global/bin` (on PATH in login shells). |
| First command after idle is slow | The machine was asleep: `cmux vm wait <id> --wake`. |
| `vm route` says it would provision | The pool is empty/busy. Check the plan meter; `--provision` (or `vm run`) creates one. |
| Create fails with an active-limit error | Plan cap (free: 1). Report it; let the user upgrade or choose a machine to remove. |
| `vm open <m>/<ws>` says no such workspace | Names are the cmux-tui workspace names; copy the `ws_…` id from `cmux vm tree <m>`. |
| Pushed a repo but `.git` is missing | `push` skips `.git`, `node_modules`, `.venv` by default; `--no-default-excludes` or ship a bundle (recipes). |
| Push/pull refuses a large payload | 256 MB cap. Clone/download inside the machine instead. |
| Command works in `vm shell` but not `vm exec` | Exec has no TTY/stdin; use non-interactive flags or `vm agent`/`vm.terminal_new` for interactive programs. |

## Deep-dive references

| Reference | When to Use |
|-----------|-------------|
| [references/commands.md](references/commands.md) | Exhaustive `cmux vm` command list with examples |
| [references/sidebar-parity.md](references/sidebar-parity.md) | Every Cloud-sidebar action and the CLI verb that does the same thing (1:1) |
| [references/agent-workflows.md](references/agent-workflows.md) | Recipes: cloud dev box, routed agents, parallel forks, desktop/browser tasks, showing the human |
| [../cmux/SKILL.md](../cmux/SKILL.md) | Windows/workspaces/panes when presenting machine panes |
| [../cmux-workspace/SKILL.md](../cmux-workspace/SKILL.md) | Non-disruptive automation rules (focus, caller workspace) |
