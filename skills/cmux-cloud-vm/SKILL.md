---
name: cmux-cloud-vm
description: Drive cmux Cloud machines (persistent cloud VMs) from the plain `cmux vm` CLI (alias `cmux cloud`) — the complete verb set. `vm route`/`run`/`agent` pick a machine for you (no ids); `vm exec`/`push`/`pull`/`wait` do headless work; `vm terminal send|read|wait` drive an interactive program on a machine without a pane; `vm tree`/`surface ls` catalog every surface (This Mac and each machine's workspaces, terminals, VNC screen, browsers) and `vm open`/`surface open` put any of them in a pane; plus create, Base, rename, checkpoints, forks, ports, SSH, auth, plan limits. Use when an agent should run builds, tests, servers, desktop/browser tasks, or another agent on a cloud machine instead of the local Mac, or when the user says "cloud machine", "cloud VM", "run it in the cloud", "cmux vm", or "cmux cloud".
---

# cmux Cloud Machines

Everything cmux Cloud exposes from the CLI, for any coding agent (Claude Code, Codex, OpenCode, Pi, or any open-source-model harness): the agent-only primitives (`route`, `run`, `agent`, `exec`, `push`, `pull`, `wait`, `terminal send|read|wait`) plus every verb the Cloud sidebar has. Requires the cmux app running, a signed-in account (`cmux auth status`, `cmux auth login`), and — since machines live on a private per-user network with no public ports — the WireGuard tunnel up once per boot (`cmux vpn up`; `cmux vpn status` to check). `cmux vm --help` is the overview and `cmux vm <verb> --help` prints a verb's own options, both offline; [references/commands.md](references/commands.md) is the complete reference and CI keeps it in lockstep with the CLI (`tests/test_cloud_vm_skill_coverage.py`). An agent with no skill loaded can bootstrap itself with `cmux vm prompt`, which installs the app-bundled copy of this skill at `~/.config/cmux/skills/cmux-cloud.md` and prints a kickoff prompt.

## What a machine is

| Term | Meaning |
|------|---------|
| **Machine** | A persistent cloud VM (`cmux vm ls`); its generated name (`brave-otter`) is its id everywhere, a `vm rename` label is cosmetic. Sleeps when idle (free while asleep), wakes on connect or exec. `/root` is the persistent volume; the rest of the filesystem is disposable compute. |
| **Kind** | `base` (shell-only, the default for `vm new`) or `desktop` — but **no provider ships a desktop image today**, so `--desktop` fails closed with an image config error and there is no VNC screen to open until one lands. Ubuntu (shared devbox image) with node, bun, uv, git, gh, ripgrep, fd, jq, tmux, xdotool; **Claude Code, Codex, OpenCode, and Pi preinstalled** under `/root/.npm-global/bin`. Provisioning runs in the background on first boot (`cat /tmp/cmux/provision.log` if a tool is missing). |
| **Session** | Every machine runs the **cmux-tui remote daemon**: its own workspaces (`ws_…`) → terminals (`term_…`), visible in `cmux vm tree`. A terminal started there keeps running when the Mac disconnects or a pane closes. |
| **Surface** | A terminal, VNC screen, or browser — on This Mac or on a machine — with a stable id `<machine>/<kind>/<key>` (`cmux surface ls --json`). Panes *project* surfaces: `cmux surface open <id>` reuses the pane already showing one or lands it at a pane edge; closing a pane never kills a machine's terminal. |
| **Base** | The one pinned persistent machine per user (`cmux vm base open`; `base reset` mints a new generation and keeps the old VM) — the user's ongoing work. |
| **Pool** | Machines the router provisioned for agent work (labeled `agent-pool` in `vm ls`, membership persisted in `~/.cmuxterm/vm-run-pool.json`). `vm run`/`vm agent` only draft these; any other machine needs `--machine <id>`. |
| **Plan meter** | `cmux vm ls` prints the meter; the cap is whatever the backend sends (`vm ls --json` → `limits.maxActiveVms`; absent = uncapped, printed as `no limit`). Plan tiers change — read `limits`, not memory. **Provisioning requires a paid plan**: `vm new`, the first `vm base open`, `base reset`, `fork`, `restore`, and the router's own provisioning answer `vm_requires_pro` with the pricing link on free or unknown plans. Never delete machines to make room without asking. |
| **Checkpoint / fork** | `vm snapshot` mints a restorable checkpoint, `vm fork` clones a machine for a parallel experiment, `vm restore` brings a snapshot back — where the provider supports it (`vm ls --json` → `capabilities`). |

## Decide: cloud or local?

| Run in the cloud when… | Stay local when… |
|------------------------|------------------|
| Builds/tests take minutes, need Linux, or would hog the user's Mac | The task is a quick edit or read |
| The task needs Linux isolation or a machine the user can watch through panes and port URLs | The user is editing the same files right now |
| You want isolation (a fork per experiment, a throwaway machine) | The repo has uncommitted local-only state you cannot sync |
| You want to fan out: several agents on several machines in parallel | |
| The user said "cloud", "machine", "VM", or `cmux vm route` shows a warm machine for this directory | |

## Fast start — let the router pick

```bash
cmux vm route                                            # which machine this directory would get, and why (--json for scripts)
cmux vm run -- uname -a                                  # routed, executed, exit code passed through
cmux vm run --sync -- bun test                           # push cwd to work/<dir> first, run there
cmux vm run --sync --pull work/app/dist -- sh -c 'cd work/app && bun run build'
cmux vm agent --agent claude --sync -- "run the tests and fix failures"   # a detached Claude Code session on the routed machine
cmux vm tree                                             # the surface catalog: This Mac, then every machine → workspaces → terminals, desktop, ports
cmux vm open vivid-newt/main/term_2f9c                   # show the human one terminal (reuses its pane if open)
cmux surface open vivid-newt/terminal/term_2f9c --pane pane:2 --left   # any surface, at a pane edge (same drop rules as the sidebar)
```

Repeat runs from the same directory hit the same machine (sticky binding, 14 days), so synced checkouts and dependencies stay warm. `--new` forces a fresh pool machine; `--machine <id>` pins one; `--size 8g` sizes a machine the run creates.

## Picking a machine

1. `cmux vm route` — the router's answer for this directory. If it says it *would provision*, that costs a machine slot: check `cmux vm ls` first (`--provision` creates it now).
2. Ongoing user work → Base (`cmux vm base open`, or `--machine <base-id>`).
3. Isolation → `cmux vm new --detach --json` (shell-only; `--desktop` fails closed until a desktop image ships); add `--size 8g` / `--name <label>`. The CLI requests a machine *kind*; never pass `--image` unless you have a specific image id. Then `--machine <id>`, and `cmux vm wait <id> --wake` before the first command.
4. Never draft the user's own machines without `--machine`, and respect the plan meter.

## Running work

| Need | Verb |
|------|------|
| One non-interactive command, ~30 s | `cmux vm exec <id> -- <cmd...>` (`--json` → `{stdout, stderr, exit_code}`; wrap shell constructs in `sh -c`) |
| A command with no machine id, minutes long, exit code through | `cmux vm run [--sync] [--pull <path>] [--timeout <s>] -- <cmd...>` |
| A coding agent, detached, reattachable from anywhere | `cmux vm agent --agent <claude\|codex\|opencode\|pi> [--sync] [--no-open] -- "<prompt>"` (flag/subcommand-led args pass through) |
| An interactive program (REPL, TUI, long test run) driven headlessly | `cmux surface new-terminal --machine <id> --no-open -- <cmd>`, then `cmux vm terminal send <id> <term> 'input' --keys enter` → `cmux vm terminal wait <id> <term> --pattern 'pass\|fail' --timeout 300` → `cmux vm terminal read <id> <term>` |
| Files in and out | `cmux vm push <id> ./repo work/repo` / `cmux vm pull <id> work/repo/out.tgz` (SHA-256 verified, 256 MB cap, `.git`/`node_modules` skipped by default) |
| A machine that is asleep or still booting | `cmux vm wait <id> --wake` |

Opening a machine (`cmux vm shell <id>`, `vm new`, `vm base open`, the sidebar) gives a **plain terminal** on it — one terminal in the machine's cmux-tui session attached in a pane like an ssh session; it keeps running if the pane closes and shows up in `cmux vm tree` (reattach with the `cmux vm open <m>/<ws>/<term>` address the `OK` line prints). `cmux vm tui <id>` is the only command that opens the full cmux-tui client. Long shell work under `exec` must be backgrounded (see recipes) — never hold a long `exec` open.

## Watching and reporting back

```bash
cmux vm tree <id>                       # live: terminals with title, cwd, agent state, (open: surface)
cmux vm terminal read <id> <term>       # the screen of any machine terminal, without a pane
cmux vm open <id>                       # the machine's shell
cmux vm open <id>/<ws>/<term>           # one terminal as a pane; reuses the pane already showing it
cmux vm workspace open <id> <ws> [--here|--tabs|--pane <p> --left]   # a whole workspace: new local workspace, or into this one
cmux vm open <id>:desktop               # the noVNC screen (desktop-image machines only — none ship today)
cmux vm open <id>:port/3000 [--print]   # tokened URL for an HTTP port (--print: URL only; dormant — no deployment implements open-port yet)
cmux surface ls --json                  # every surface (local + cloud) with ids, lifecycle, and which panes show it
cmux surface open <resource> [--new] [--pane <p> --left|--right|--up|--down|--tab]   # one open path for all of them
cmux notify --title "Cloud build done" --body "…"
```

The user cannot see inside the machine: print URLs, pull artifacts, or open a pane when there is something to look at, and `cmux notify` for long work. Only share URLs minted by `cmux vm open`; never guess raw provider URLs. A pane showing a machine surface is an ordinary local pane: move, split, reorder, or close it with the local topology verbs (`../cmux/SKILL.md`); the surface catalog follows the pane.

## Workspaces and terminals on a machine

`cmux vm workspace new|open|rename|close|rm` and `cmux vm terminal close|send|read|wait` are the machine's cmux-tui session verbs; ids come from `cmux vm tree`. `workspace rm` is the sidebar's "Close Workspace…" (kills the workspace's terminals); `workspace close` is CLI-only and keeps them running in the Terminals pool. Every sidebar action has a CLI verb over the same socket method — [references/sidebar-parity.md](references/sidebar-parity.md).

## Credentials

Agents started with `vm agent` authenticate inside the machine the way they would locally: their own login under `/root` (set up once with `vm exec`; it persists on the volume), or the team's subrouter through `cmux ai-accounts upload` (uploads local credentials so no token is copied onto a machine). Do not put the user's tokens on a machine unless they ask.

## Agent policy

- **Prefer `vm route` / `vm run` / `vm agent` over naming machines.** They only draft pool machines; `--machine <id>` is the deliberate way to use another.
- **Reuse before create.** `vm ls`, then an idle machine or Base. Creating machines needs a paid plan and counts against its cap.
- **Stay headless while working** (`--detach`, `--no-open`, `--print`, `terminal send|read|wait`); open panes (`vm open`, `vm tree`'s addresses) to *show* results, and `--focus true` only when the user should be looking.
- **Checkpoint before risky operations** (`vm snapshot`); fork instead of experimenting on a machine the user relies on.
- **Only destroy what you created this session.** `vm rm` and `vm workspace rm` are permanent; `vm base reset` keeps the old VM but the user must ask for it.
- **Read plan limits and sizes from `cmux vm ls` and `--help`, not from memory.**

## Common issues and fixes

| Symptom | Fix |
|---------|-----|
| `vm exec` hangs or times out | Exec is capped (~30 s). Background it: `nohup … > /tmp/x.log 2>&1 &`, then poll — or use `vm run`, `vm agent`, or a session terminal driven with `terminal send|wait|read`. |
| `claude`/`codex` not found on a brand-new machine | Provisioning is still running: `cmux vm exec <id> -- tail /tmp/cmux/provision.log`; the agents land in `/root/.npm-global/bin` (on PATH in login shells). |
| First command after idle is slow | The machine was asleep: `cmux vm wait <id> --wake`. |
| Attach/exec cannot reach any machine | The WireGuard tunnel is down: `cmux vpn up` (state: `cmux vpn status`; needs `brew install wireguard-tools`). Machines have no public ports. |
| `vm route` says it would provision | The pool is empty/busy. Check the plan meter; `--provision` (or `vm run`) creates one. |
| Create fails with `vm_requires_pro` or an active-limit error | Provisioning needs a paid plan (`cmux.com/pricing`), or the plan's machine cap is reached. Report it; let the user upgrade or choose a machine to remove. |
| `vm open <m>/<ws>` says no such workspace | Names are the cmux-tui workspace names; copy the `ws_…` id from `cmux vm tree <m>` (`--refresh` right after a link attach). |
| `vm terminal wait` exits 1 | Timeout (default 30 s; raise `--timeout`) — the error carries the screen tail; `terminal read` shows the whole screen. |
| Pushed a repo but `.git` is missing | `push` skips `.git`, `node_modules`, `.venv`, `__pycache__`, `.DS_Store` by default; `--no-default-excludes`, or ship a `git bundle` (recipes). |
| Push/pull refuses a large payload | 256 MB cap. Clone/download inside the machine instead. |
| Command works in `vm shell` but not `vm exec` | Exec has no TTY/stdin; use non-interactive flags, or `surface new-terminal` + `terminal send|read|wait` for interactive programs. |
| `vm snapshot`/`vm fork` refused | Provider capability (`vm ls --json` → `capabilities`); providers without it hide the sidebar verbs too. |
| `vm ssh` errors | The default provider attaches through the cmux-tui daemon and mints no SSH endpoint; use `exec`, `agent`, or `open`. |

## Deep-dive references

| Reference | When to use |
|-----------|-------------|
| [references/commands.md](references/commands.md) | Every verb, alias, flag, `--json` shape, exit code, socket method, and the sidebar action it mirrors — plus the "In flight" list of verbs that exist only in open PRs |
| [references/sidebar-parity.md](references/sidebar-parity.md) | Every Cloud-sidebar action and the CLI verb that does the same thing (1:1) |
| [references/agent-workflows.md](references/agent-workflows.md) | Recipes: cloud dev box, routed agents, headless terminal loops, parallel forks, desktop/browser tasks, showing the human |
| [../cmux/SKILL.md](../cmux/SKILL.md) | Windows/workspaces/panes when presenting machine panes |
| [../cmux-workspace/SKILL.md](../cmux-workspace/SKILL.md) | Non-disruptive automation rules (focus, caller workspace) |
