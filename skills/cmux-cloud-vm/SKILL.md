---
name: cmux-cloud-vm
description: "Teach and drive cmux Cloud from the plain `cmux vm` CLI (alias `cmux cloud`): route work, run commands and agents, transfer files, control detached terminals, inspect/open surfaces, and publish protected or public VM ports on generated or custom domains. Use when an agent should run builds, tests, servers, desktop/browser tasks, or another agent on a cloud machine, or when the user says \"cloud machine\", \"cloud VM\", \"run it in the cloud\", \"cmux vm\", or \"cmux cloud\"."
---

# cmux Cloud Machines

Everything cmux Cloud exposes from the CLI, for any coding agent (Claude Code, Codex, OpenCode, Pi, or another harness): the agent-only primitives (`route`, `run`, `agent`, `exec`, `push`, `pull`, `wait`, `terminal send|read|wait`) plus every verb the Cloud sidebar has. The app must be running and signed in (`cmux auth status`, `cmux auth login`). Bring up WireGuard (`cmux vpn up`) before private VM attach, exec, desktop, or port operations; a published domain is reached through its HTTPS edge and does not require the viewer's tunnel. `cmux vm --help` is the overview and `cmux vm <verb> --help` prints a verb's own options, both offline; [references/commands.md](references/commands.md) is the complete reference and CI keeps it in lockstep with the CLI (`tests/test_cloud_vm_skill_coverage.py`). An agent with no skill loaded can bootstrap itself with `cmux vm prompt`, which installs the app-bundled copy of this skill at `~/.config/cmux/skills/cmux-cloud.md` and prints a kickoff prompt.

**The mission is delegation.** A local agent (you, on the user's Mac) sends work to machines that outlive the laptop: every terminal and agent session lives in the machine's own cmux-tui daemon, so work keeps running with every pane closed and the lid shut, and any signed-in Mac reattaches later through the same addresses. Compose machine workspaces headlessly (as many as the task needs), watch them with `vm tree --json` and `vm terminal read` without opening anything, and surface panes or a `cmux notify` only when the user should look.

**The shortest reliable loop is:** authenticate → inspect limits and routing → run or stage work headlessly → observe with `tree`/`terminal read` → open a pane or share a URL only when there is something useful to show. Ask for confirmation before creating, forking, resetting, or destroying a machine, because those operations consume plan capacity or delete data.

**Treat the installed CLI as the contract.** Read `cmux vm --help` and the
specific `cmux vm <verb> --help` before using a newly added flag, and check the
`In flight` section of the reference only for planning. A tagged app, an older
machine image, and the app's bundled CLI can be on different rollout versions;
if help and this document disagree, follow help and report the discrepancy.

## What a machine is

| Term | Meaning |
|------|---------|
| **Machine** | A persistent cloud VM (`cmux vm ls`); its generated name (for example `brave-otter`) is its id everywhere, while `vm rename` changes only a display label. `/root` is persistent; the compute filesystem is disposable. A machine may sleep when idle and wakes on connect or exec. |
| **Kind** | `base` is shell-only; `desktop` adds TigerVNC on `:1`, openbox, the devbox dock, and noVNC on 6901. `vm base open` chooses desktop by default on first creation; the current `vm new` path requests shell-only unless `--desktop` is explicitly supplied and the deployment has a desktop image. Shells on a desktop machine get `DISPLAY=:1`, so `agent-browser`, `xdotool`, and `cua-driver` can drive its screen. |
| **Contents** | The Ubuntu 24.04 devbox supplies node, bun, uv, git, gh, ripgrep, fd, jq, tmux, xdotool, Chrome, and `cua-driver`; Claude Code, Codex, OpenCode, and Pi are provisioned under `/root/.npm-global/bin`. If a fresh machine is still bootstrapping, inspect `/tmp/cmux/provision.log`. |
| **Session** | Every machine runs a **cmux-tui remote daemon** with workspaces (`ws_…`) and terminals (`term_…`). A terminal keeps running when the Mac disconnects or its pane closes. |
| **Publication** | `cmux cloud domains publish` maps one VM port to one HTTPS hostname. `personal` allows the owner, `team` allows current members of a selected team, and `public` allows anyone with the URL. |
| **Workspaces** | One machine hosts **many** cmux-tui workspaces: the machine is the big box, workspaces are the desks in it. Make a workspace per task *inside* a machine (`cmux vm workspace new <id> --name <task>`, the machine's ⌘N) — not a machine per task. The Cloud sidebar shows them grouped under the machine's Workspaces group. |
| **Surface** | A terminal, VNC screen, or browser — on This Mac or on a machine — with a stable id `<machine>/<kind>/<key>` (`cmux surface ls --json`). Panes *project* surfaces: `cmux surface open <id>` reuses the pane already showing one or lands it at a pane edge; closing a pane never kills a machine's terminal. |
| **Base** | The one pinned persistent machine per user (`cmux vm base open`; `base reset` mints a new generation and keeps the old VM) — the user's ongoing work. |
| **Pool** | Machines the router provisioned for agent work (labeled `agent-pool` in `vm ls`, membership persisted in `~/.cmuxterm/vm-run-pool.json`). `vm run`/`vm agent` only draft these; any other machine needs `--machine <id>`. |
| **Plan meter** | `cmux vm ls` prints the meter; the cap is whatever the backend sends (`vm ls --json` → `limits.maxActiveVms`; absent = uncapped, printed as `no limit`). The same `limits` object advertises `memoryOptionsMb`; plan tiers change, so read those fields instead of relying on remembered caps or sizes. Where the deployment gates provisioning to paid plans, `vm new`, the first `vm base open`, `base reset`, `fork`, `restore`, and the router's own provisioning answer `vm_requires_pro` with the pricing link on free or unknown plans; a free plan that can provision gets its advertised machine inside a 7-day access window (`limits.freeAccessExpiresAt` — after it, access verbs need a paid plan while list/status/delete keep working). Never delete machines to make room without asking. |
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
cmux vm tree                                             # the surface catalog: This Mac, then every machine → workspaces → ports → VNC displays → terminals
cmux vm open vivid-newt/main/term_2f9c                   # show the human one terminal (reuses its pane if open)
cmux surface open vivid-newt/terminal/term_2f9c --pane pane:2 --left   # any surface, at a pane edge (same drop rules as the sidebar)
cmux cloud domains publish vivid-newt 3000                # public HTTPS hostname, personal access by default
cmux vm resize vivid-newt --disk 40G                      # grow persistent disk (4 GiB steps; never shrinks)
```

Repeat runs from the same directory hit the same machine (sticky binding, 14 days), so synced checkouts and dependencies stay warm. `--new` forces a fresh pool machine; `--machine <id>` pins one. For a machine the router creates, `--size` accepts `4g`, `8g`, `16g`, `24g`, `32g`, `64g`, or raw MB; read `vm ls --json` → `limits.memoryOptionsMb` first because the server advertises the current plan's allowed choices and resolves unsupported requests to its default.

## Picking a machine

1. `cmux vm route` — the router's answer for this directory. If it says it *would provision*, that costs a machine slot: check `cmux vm ls` first (`--provision` creates it now).
2. Ongoing user work → Base (`cmux vm base open`, or `--machine <base-id>`).
3. A new task on a machine you already use → a new **workspace**, not a new machine (`cmux vm workspace new <id> --name <task>`): one machine hosts many workspaces, and that is the intended unit of scale.
4. Hard isolation (a different environment, a risky experiment) → `cmux vm fork <id>` of a warm machine, or `cmux vm new --detach --json` (shell-only; `--desktop` requests a machine with a screen and fails if that deployment has no desktop image); add `--name <label>`. Choose `--size` from `vm ls --json` → `limits.memoryOptionsMb` (named aliases: `4g`, `8g`, `16g`, `24g`, `32g`, `64g`; raw MB also parses). Never pass `--image` unless you have a specific image id. Then `--machine <id>`, and `cmux vm wait <id> --wake` before the first command.
5. Persistent disk growth → `cmux vm resize <id> --disk <GiB>` after confirming the target and requested capacity. Values are 4–256 GiB in 4 GiB steps; the operation is grow-only, keeps `/root` and the machine identity intact, and can take a provider minute. Run `cmux vm stats <id>` afterward to verify `disk_total_mb`.
6. Never draft the user's own machines without `--machine`, and respect the plan meter.

## Publish a VM port safely

Use the domains namespace when a user needs a stable HTTPS URL. It is separate from `vm open <id> <port>`: the latter is a private, tunnel-only preview, while a publication creates a public edge with an explicit viewer policy.

```bash
# Generated cmux hostname; no customer DNS setup is needed.
cmux cloud domains publish <machine> <port> --json

# See the URL, policy, lifecycle state, and any verification instructions.
cmux cloud domains list

# Custom zone: print the complete DNS checklist, add the records, then retry.
cmux cloud domains verify example.com
cmux cloud domains publish <machine> <port> --domain app.example.com --access team --team <team-id>
cmux cloud domains zones

# Change or remove an existing publication (hostname or id is accepted).
cmux cloud domains access app.example.com public
cmux cloud domains rm app.example.com
```

The custom-domain flow is intentionally two-phase. The first `verify` call creates a pending ownership challenge and prints labelled records: an ownership TXT record, apex and wildcard routing records, and `_acme-challenge` NS delegation. Add those records at the DNS provider, run `verify` again, and wait for the certificate/routing state to become active. A verified zone can serve the apex or one-label children (`example.com` or `app.example.com`); deeper names need a covering zone. Generated cmux names are already reserved and certificate-covered, so they skip verification.

Choose the narrowest access mode: `personal` (the default) for the owner, `team` with a required `--team <id>` for current members of that team, or `public` for anyone holding the URL. `access` changes the policy immediately; it does not create viewer grants. Treat a `public` URL as a credential and do not put it in logs or prompts. Use `--json` when another tool will consume the result; it returns stable publication/domain objects rather than the human DNS table.

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
cmux vm open <id>:desktop               # the noVNC screen (desktop-kind machines; base machines have no screen)
cmux vm open <id>:port/3000 [--print]   # URL for an HTTP port on the machine's private address (--print: URL only; needs `cmux vpn up`)
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
| `vm tree --json` times out while a link is connecting | Retry without `--refresh` or scope it to `cmux vm tree <id>`; inspect `cmux vm ls --json`/`vm status <id>`, then use `vm exec` or `vm terminal read` directly when you already know the target. |
| `vm route` says it would provision | The pool is empty/busy. Check the plan meter; `--provision` (or `vm run`) creates one. |
| Create fails with `vm_requires_pro` or an active-limit error | Provisioning needs a paid plan (`cmux.com/pricing`), or the plan's machine cap is reached. Report it; let the user upgrade or choose a machine to remove. |
| `vm open <m>/<ws>` says no such workspace | Names are the cmux-tui workspace names; copy the `ws_…` id from `cmux vm tree <m>` (`--refresh` right after a link attach). |
| `vm terminal wait` exits 1 | Timeout (default 30 s; raise `--timeout`) — the error carries the screen tail; `terminal read` shows the whole screen. |
| Pushed a repo but `.git` is missing | `push` skips `.git`, `node_modules`, `.venv`, `__pycache__`, `.DS_Store` by default; `--no-default-excludes`, or ship a `git bundle` (recipes). |
| Push/pull refuses a large payload | 256 MB cap. Clone/download inside the machine instead. |
| Command works in `vm shell` but not `vm exec` | Exec has no TTY/stdin; use non-interactive flags, or `surface new-terminal` + `terminal send|read|wait` for interactive programs. |
| `vm snapshot`/`vm fork` refused | Provider capability (`vm ls --json` → `capabilities`); providers without it hide the sidebar verbs too. |
| `vm ssh` errors | The default provider attaches through the cmux-tui daemon and mints no SSH endpoint; use `exec`, `agent`, or `open`. |
| `cloud domains verify` still says pending | DNS is eventually consistent. Compare the printed record name/type/value exactly, wait for propagation, and rerun `cmux cloud domains verify <domain>`; do not create a second zone for the same name. |
| A publication is not active | `cmux cloud domains list --json` shows `state` and `verification`; custom domains must be verified and certificate-ready before routing activates. Generated domains do not need DNS proof. |
| A viewer is denied | Check the publication's `accessMode`: `personal` requires the owner, `team` requires current membership in the selected team, and `public` is the only unauthenticated mode. Change it deliberately with `cmux cloud domains access`. |

## Deep-dive references

| Reference | When to use |
|-----------|-------------|
| [references/commands.md](references/commands.md) | Every verb, alias, flag, `--json` shape, exit code, socket method, and the sidebar action it mirrors — plus the "In flight" list of verbs that exist only in open PRs |
| [references/sidebar-parity.md](references/sidebar-parity.md) | Every Cloud-sidebar action and the CLI verb that does the same thing (1:1) |
| [references/agent-workflows.md](references/agent-workflows.md) | Recipes: cloud dev box, routed agents, headless terminal loops, parallel forks, desktop/browser tasks, showing the human |
| [../cmux/SKILL.md](../cmux/SKILL.md) | Windows/workspaces/panes when presenting machine panes |
| [../cmux-workspace/SKILL.md](../cmux-workspace/SKILL.md) | Non-disruptive automation rules (focus, caller workspace) |
