---
name: cmux-cloud-vm
description: "Route work to cmux Cloud machines from the plain `cmux vm` CLI (alias `cmux cloud`): route/run/agent pick a machine, `vm tree` and `surface ls` catalog This Mac and cloud surfaces, and open, exec, transfer, workspace, terminal, port, checkpoint, and domain operations share the same app paths. Use when an agent should run builds, tests, servers, desktop/browser tasks, or another agent on a cloud machine, or when the user says \"cloud machine\", \"cloud VM\", \"run it in the cloud\", \"cmux vm\", or \"cmux cloud\"."
---

# cmux Cloud Machines

Everything cmux Cloud exposes from the CLI, for any coding agent (Claude Code, Codex, OpenCode, Pi, or another harness): the agent-only primitives (`route`, `run`, `agent`, `exec`, `push`, `pull`, `wait`, `terminal send|read|wait`) plus every verb the Cloud sidebar has. Host-side operations require the cmux app and a signed-in account (`cmux auth status`, `cmux auth login`); a guest-safe auth/CodeRouter subset is available inside a machine. Bring up WireGuard (`cmux vpn up`) before private VM attach, exec, desktop, or port operations; a published domain is reached through its HTTPS edge and does not require the viewer's tunnel. `cmux vm --help` is the overview and `cmux vm <verb> --help` prints a verb's own options, both offline; [references/commands.md](references/commands.md) is the complete reference and CI keeps it in lockstep with the CLI (`tests/test_cloud_vm_skill_coverage.py`). An agent with no skill loaded can bootstrap itself with `cmux vm prompt`, which installs the app-bundled copy of this skill at `~/.config/cmux/skills/cmux-cloud.md` and prints a kickoff prompt.

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
| **Machine** | A persistent cloud VM (`cmux vm ls`); its generated name (for example `brave-otter`) is its id everywhere, while `vm rename` changes only a display label. New machines run terminals, agents, exec, and the desktop as `cmux` (uid 1000, home `/home/cmux`, passwordless sudo). Older machines keep their root layout until recreated; resolve paths from the remote `$HOME`. A machine may sleep when idle and wakes on connect or exec. |
| **Kind** | Every new machine uses the devbox with TigerVNC on `:1`, openbox, the dock, and noVNC on 6901. `--desktop`, `--base`, and `--no-desktop` remain accepted for older scripts; they no longer select different new-machine kinds. Historical `base` machines can still lack a screen. Shells receive the desktop environment, including `DISPLAY=:1`, so `agent-browser`, `xdotool`, and `cua-driver` can drive the screen. |
| **Contents** | The Ubuntu 24.04 devbox supplies node, bun, uv, git, gh, ripgrep, fd, jq, tmux, xdotool, Chrome, and `cua-driver`; Claude Code, Codex, OpenCode, and Pi are installed on the session PATH. If a fresh machine is still bootstrapping, inspect `/tmp/cmux/provision.log`. |
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
cmux vm run --sync --pull work/app/dist -- bun run build
cmux vm agent --agent claude --sync -- "run the tests and fix failures"   # a detached Claude Code session on the routed machine
cmux vm tree                                             # the surface catalog: This Mac, then every machine → workspaces → ports → VNC displays → terminals
cmux vm open vivid-newt/main/term_2f9c                   # show the human one terminal (reuses its pane if open)
cmux surface open vivid-newt/terminal/term_2f9c --pane pane:2 --left   # any surface, at a pane edge (same drop rules as the sidebar)
cmux cloud domains publish vivid-newt 3000                # public HTTPS hostname, personal access by default
cmux pane resize vivid-newt --disk 40G                      # grow persistent disk (4 GiB steps; never shrinks)
```

Repeat runs from the same directory hit the same machine (sticky binding, 14 days), so synced checkouts and dependencies stay warm. `--new` forces a fresh pool machine; `--machine <id>` pins one. For a machine the router creates, `--size` accepts `4g`, `8g`, `16g`, `24g`, `32g`, `64g`, or raw MB; read `vm ls --json` → `limits.memoryOptionsMb` first because the server advertises the current plan's allowed choices and resolves unsupported requests to its default.

## Picking a machine

1. `cmux vm route` — the router's answer for this directory. If it says it *would provision*, that costs a machine slot: check `cmux vm ls` first (`--provision` creates it now).
2. Ongoing user work → Base (`cmux vm base open`, or `--machine <base-id>`).
3. A new task on a machine you already use → a new **workspace**, not a new machine (`cmux vm workspace new <id> --name <task>`): one machine hosts many workspaces, and that is the intended unit of scale.
4. Hard isolation (a different environment, a risky experiment) → `cmux vm fork <id>` of a warm machine, or `cmux vm new --detach --json` for a new devbox; add `--name <label>`. Choose `--size` from `vm ls --json` → `limits.memoryOptionsMb` (named aliases: `4g`, `8g`, `16g`, `24g`, `32g`, `64g`; raw MB also parses). Never pass `--image` unless you have a specific image id. Then `--machine <id>`, and `cmux vm wait <id> --wake` before the first command.
5. Persistent disk growth → `cmux pane resize <id> --disk <GiB>` after confirming the target and requested capacity. Values are 4–256 GiB in 4 GiB steps; the operation is grow-only, keeps the machine data and identity intact, and can take a provider minute. Run `cmux vm stats <id>` afterward to verify `disk_total_mb`.
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

Opening a machine (`cmux vm shell <id>`, `vm new`, `vm base open`, the sidebar) gives a **plain terminal** on it — one terminal in the machine's cmux-tui session attached in a pane like an ssh session; it keeps running if the pane closes and shows up in `cmux vm tree` (reattach with the `cmux vm open <m>/<ws>/<term>` address the `OK` line prints). Use `cmux vm open` or `cmux surface open` for the machine's individual surfaces. Long shell work under `exec` must be backgrounded (see recipes) — never hold a long `exec` open.

## Watching and reporting back

```bash
cmux vm tree <id>                       # live: terminals with title, cwd, agent state, (open: surface)
cmux vm terminal read <id> <term>       # the screen of any machine terminal, without a pane
cmux vm open <id>                       # the machine's shell
cmux vm open <id>/<ws>/<term>           # one terminal as a pane; reuses the pane already showing it
cmux vm workspace open <id> <ws> [--here|--tabs|--pane <p> --left]   # a whole workspace: new local workspace, or into this one
cmux vm open <id>:desktop               # the noVNC screen (new machines; historical shell-only machines have no screen)
cmux vm open <id>:port/3000 [--print]   # URL for an HTTP port on the machine's private address (--print: URL only; needs `cmux vpn up`)
cmux vm workspace rename <id> <ws> <name>   # rename it; `close` keeps its terminals (they detach into the pool), `rm` deletes it AND kills them
cmux vm tab rename <id> <tab> <name>       # rename one exact tab placement; "" clears its custom label
cmux vm terminal rename <id> <term> <name> # rename every tab placement; "" clears every custom label
cmux surface ls --json                  # every surface (local + cloud) with ids, lifecycle, and which panes show it
cmux surface open <resource> [--new] [--pane <p> --left|--right|--up|--down|--tab]   # one open path for all of them
cmux notify --title "Cloud build done" --body "…"
```

The user cannot see inside the machine: print URLs, pull artifacts, or open a pane when there is something to look at, and `cmux notify` for long work. Only share URLs minted by `cmux vm open`; never guess raw provider URLs. A pane showing a machine surface is an ordinary local pane: move, split, reorder, or close it with the local topology verbs (`../cmux/SKILL.md`); the surface catalog follows the pane.

## Workspaces and terminals on a machine

`cmux vm workspace new|open|rename|close|rm` and `cmux vm terminal close|send|read|wait` are the machine's cmux-tui session verbs; ids come from `cmux vm tree`. `workspace rm` is the sidebar's "Close Workspace…" (kills the workspace's terminals); `workspace close` is CLI-only and keeps them running in the Terminals pool. Every sidebar action has a CLI verb over the same socket method — [references/sidebar-parity.md](references/sidebar-parity.md).

## Credentials

Agents started with `vm agent` authenticate inside the machine the way they would locally: their own login under the remote `$HOME` (set up once with `vm exec`; it persists with the machine), or the team's subrouter through `cmux ai-accounts upload` (uploads local credentials so no token is copied onto a machine). Do not put the user's tokens on a machine unless they ask.

## Guest auth and CodeRouter

Start with `cmux self --json` to identify the current machine and `cmux vm ls`
to list the team's live machines. The guest reads those through its VM-bound
TLS edge without a Mac account token. Host lifecycle verbs still run on the Mac;
read the guest's `cmux --help` for the subset its image supports.

Inside a Cloud machine, the guest `cmux` adapter can report route health and run
an agent through the shared CodeRouter without exposing the Mac's Stack session:

```bash
cmux auth status --json
cmux coderouter status --json
cmux coderouter usage
cmux coderouter models
cmux coderouter agent claude "summarize the current checkout"
cmux agent codex "run the tests"
```

These commands describe the machine's daemon, TLS edge, and VM-bound route.
Host account login and upstream credential management remain on the Mac; do not
copy those tokens into a VM. `vm agent` still starts a detached terminal on the
selected machine, while the guest `cmux agent` form runs through CodeRouter.

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
| `claude`/`codex` not found on a brand-new machine | Provisioning is still running: `cmux vm exec <id> -- tail /tmp/cmux/provision.log`; the agents land in the session PATH (use a login shell). |
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
---
name: cmux-cloud-vm
description: "Route work to cmux Cloud machines (persistent cloud VMs) from the CLI — `cmux vm route`/`run`/`agent` pick a machine for you; `vm tree` / `surface ls` show the surface catalog (This Mac and every machine: terminals, VNC screens, browsers) and `vm open` / `surface open` put any of them in a pane; plus create, exec, push/pull, ports, checkpoints, forks. Use when an agent should run builds, tests, servers, desktop/browser tasks, or another agent on a cloud machine instead of the local Mac, or when the user says \"cloud machine\", \"cloud VM\", \"run it in the cloud\", or \"cmux vm\"."
---

# cmux Cloud Machines

Everything the Cloud sidebar can do, from the CLI — plus agent-only primitives (`route`, `run`, `agent`, `exec`, `push`, `pull`, `wait`). Host-side operations require the cmux app and a signed-in account (`cmux auth status`, `cmux auth login`); the guest-safe subset documented below runs inside a VM without a Stack session. All of it is plain CLI, so it works for Claude Code, Codex, OpenCode, Pi, or any harness — and `cmux vm prompt` bootstraps an agent that has no skill loaded: it installs the app-bundled cmux-cloud skill at `~/.config/cmux/skills/cmux-cloud.md` and prints a kickoff prompt pointing at it (`--open <agent>` starts a local agent terminal with that prompt directly).

## What a machine is

| Term | Meaning |
|------|---------|
| **Machine** | A persistent cloud VM (`cmux vm ls`). cmux-created machines have no provider idle timeout, so they stay available until the user pauses/stops or destroys them; an already-sleeping machine wakes on connect or exec. `/root` is a 16 GB persistent volume; the rest of the filesystem is disposable compute. |
| **Contents** | Ubuntu 24.04 (shared devbox image): node, bun, uv, git, gh, ripgrep, fd, jq, tmux, xdotool, Chrome, `cua-driver`. **Claude Code, Codex, OpenCode, and Pi are preinstalled**. Desktop-kind machines (the default; `vm new --base` makes a shell-only machine with no screen) boot a desktop: TigerVNC on `:1` with an openbox session, a dock (Chrome, Files, Ghostty) and noVNC on 6901 — the **Desktop** row in the sidebar / `vm open <m>:desktop` shows it. Shells on the machine get `DISPLAY=:1` (and the accessibility bus) while the desktop is up, so `agent-browser`, `xdotool` and `cua-driver mcp` act on that screen. |
| **Session** | Every machine runs the **cmux-tui remote daemon**: its own workspaces → terminals, visible in `cmux vm tree`. A terminal you start there keeps running when the Mac disconnects. |
| **Workspaces** | One machine hosts **many** cmux-tui workspaces: the machine is the big box, workspaces are the desks in it. Make a workspace per task *inside* a machine (`cmux vm workspace new <id> --name <task>`, the machine's ⌘N) — not a machine per task. The Cloud sidebar shows them grouped under the machine's Workspaces group. A workspace **is a layout**: its screen's splits, ratios and tabs. `cmux vm layout export/apply` reads and writes that shape as JSON (the same document `cmux new-workspace --layout` and `cmux layout save/get` use locally), and clicking the workspace row opens it on the Mac with the same geometry. |
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
cmux vm env set vivid-newt DATABASE_URL=postgres://… --from-file .env     # project secrets, on the machine's persistent volume, in every shell/agent it starts
cmux vm layout apply vivid-newt dev-layout.json --name app --open       # build the workspace shape (panes, ratios, tabs, commands) and show it
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
cmux vm terminal wait-exit <id> <term> --timeout 900   # block until the process exits (exit code passes through as exited/pending)
cmux vm terminal output <id> <term>     # the full output so far (scrollback), with a resume cursor for the next read
cmux vm exec <id> --timeout 600 -- <command>   # one command up to 15 minutes; default cap is 30 s
cmux vm pause <id> / cmux vm resume <id>   # park a machine when the work is done (stops its compute); resume brings it back
cmux vm agent --agent claude --machine <id> --wait --output --timeout 1800 -- "…"   # until-done: block, then print everything the agent wrote; exit code passes through
cmux vm dev <id> [<folder>] [--name <ws>] [--layout <file>] [--command "<cmd>"] [--port <n>] [--remote <path>] [--sync|--no-sync] [--no-open] [--dry-run] [--json]   # route + optional sync + detected command + named workspace/layout
```

`terminal send/wait/read` is the interactive counterpart of `exec`: a REPL, a TUI, a long test run, or another agent's session on the machine can be driven and observed without attaching a pane or stealing focus. Start the program with `cmux surface new-terminal --machine <id> --no-open -- <cmd>` (its `term_…` id comes back on the OK line), then loop send → wait → read.

### One-command dev setup

Use `vm dev` when the input is a local project folder and the desired result is a running, inspectable dev layout:

```bash
cmux vm dev <machine> [<folder>] [--name <workspace>] [--layout <file>] [--command "<cmd>"] [--port <n>] [--remote <path>] [--sync|--no-sync] [--no-open] [--dry-run] [--json]
```

It checks the machine, optionally pushes the folder (default remote `work/<basename>`), detects a command and port, then creates or reuses the named workspace through `vm layout apply --name`. The built-in layout is a dev terminal on the left and a focused shell on the right, with a browser tab when a port is known. Re-running with the same workspace name preserves a workspace that already has live terminals; it does not start a second dev server. `--command` and `--port` override detection, `--layout` replaces the built-in layout, and `--dry-run` performs no socket calls. Sync defaults on when a folder or recognizable project is supplied; use `--no-sync` for a machine-side checkout. `--no-open` stages the workspace and prints the `vm workspace open` command instead of opening a local pane. `--json` includes `machine`, `workspace_id`, `workspace_name`, `existing`, `remote`, `synced`, `detected`, `command`, `port`, `url`, terminal ids, `layout_applied`, and `opened`.

The detector checks, in order, `package.json`, `Cargo.toml`, `go.mod`, `Makefile`, `manage.py`, `uv.lock`, `pyproject.toml`, `requirements.txt`, and `index.html`. For JavaScript projects it chooses bun, pnpm, yarn, or npm from the lockfile, prefers `dev` then `start`, and infers a port from the script or framework defaults. When no project is recognized, it stages a shell-only workspace; pass `--command` to run something anyway.

`vm agent` starts the agent as a **detached terminal in the machine's cmux-tui session**: it survives closed panes and reconnects from any device (`cmux vm open <machine>/<ws>/<term>`). Long shell work should also be backgrounded (see recipes) — never hold a long `exec` open.

## Watching and reporting back

```bash
cmux vm tree <id>                       # live: terminals with title, cwd, agent state, (open: surface)
cmux vm open <id>                       # the machine's shell (+ its screen on desktop machines)
cmux vm open <id>/<ws>/<term>           # one terminal as a pane; reuses the pane already showing it
cmux vm workspace open <id> <ws> [--here|--tabs|--pane <p> --left]   # a whole workspace: new local workspace, or into this one
cmux vm workspace rename <id> <ws> <name>   # rename it; `close` keeps its terminals (they detach into the pool), `rm` deletes it AND kills them
cmux vm tab rename <id> <tab> <name>       # rename one exact tab placement; "" clears its custom label
cmux vm terminal rename <id> <term> <name> # rename every tab placement; "" clears every custom label
cmux vm open <id>:desktop               # the noVNC screen
cmux vm open <id>:port/3000 [--print]   # private tokened URL for an HTTP port (--print: URL only)
cmux surface ls --json                  # every surface (local + cloud) with ids, lifecycle, and which panes show it
cmux surface open <resource> [--new] [--pane <p> --left|--right|--up|--down|--tab]   # one open path for all of them
cmux surface new-terminal --machine <id> --cwd /root/work/app -- bun test          # a terminal on the machine, opened as a pane
cmux notify --title "Cloud build done" --body "…"   # inside a machine too: lands on the Mac pane showing this terminal
```

The user cannot see inside the machine: print URLs, pull artifacts, or open a pane when there is something to look at, and `cmux notify` for long work. Only share URLs minted by `cmux vm open` — never guess raw provider URLs.

`cmux notify` run inside a machine reaches the user's Mac as data: the machine's daemon records it and the Mac shows it on the pane displaying the terminal it ran in (or at workspace level wherever the machine is open; nowhere if nothing of the machine is on screen). Keep `--title`/`--body` short (128 B / 1 KiB caps, 5 per burst then 1 per second); `--subtitle` folds into the body; Mac selectors (`--workspace`, `--surface`, `--window`, `--tab`, `--panel`) and `--reply` are ignored there, and nothing can be typed back into the machine from the notification.

A pane showing a machine surface is an ordinary local pane: move, split, reorder, or close it with the local topology verbs (`../cmux/SKILL.md`) and the surface catalog follows the pane; closing a pane never kills the machine's terminal. Inside the machine, use `cmux workspace rename`, `cmux terminal rename`, `cmux tab move`, and `cmux pane split|swap|resize` to arrange its own layout (`cmux workspace help`).

## Layouts as data (the shape of a workspace)

When a person clicks a machine workspace they land in a **layout**: which panes exist, how they are split, the divider ratios, which tabs sit in each pane, and what runs where. Agents author and read that shape as JSON, never by dragging panes:

```bash
cmux vm layout export <m> <ws>                    # {"name","cwd","layout": …} for that workspace (--raw: the daemon's exact LayoutDocument)
cmux vm layout apply  <m> dev.json --name app     # build a NEW workspace on the machine from the document (never touches a non-empty one)
cmux vm layout apply  <m> - --workspace <ws> <<'JSON'   # stdin; --workspace must already be empty; prefer --name or vm dev
{"direction":"horizontal","split":0.6,"children":[
  {"pane":{"surfaces":[{"type":"terminal","name":"agent","cwd":"work/app","command":"claude"}]}},
  {"direction":"vertical","children":[
    {"pane":{"surfaces":[{"type":"terminal","name":"tests","cwd":"work/app","command":"bun test --watch"}]}},
    {"pane":{"surfaces":[{"type":"browser","url":"http://localhost:3000"}]}}]}]}
JSON
cmux vm layout apply <m> --from-saved dev --open  # a layout saved on the Mac (`cmux layout save dev`) applied in the cloud, then opened here
cmux layout get dev | cmux vm layout apply <m> -  # the same, piped
```

The document is the one cmux already uses locally (`cmux new-workspace --layout`, `cmux layout save|get|open`, `cmux.json` workspaces): `{"pane":{"surfaces":[…]}}` leaves and `{"direction":"horizontal"|"vertical","split":0.1–0.9,"children":[a,b]}` splits; `horizontal` = side by side (first child left), `vertical` = stacked (first child top), `split` = the first child's share. A surface is `{"type":"terminal"|"browser","name"?,"cwd"?,"command"?,"env"?,"url"?,"focus"?}`. In the cloud a terminal surface is a login shell in `cwd` (relative to the work user's home, or the document's `cwd`) with `env` in its process environment; `command` is typed into that shell and stays reviewable in the scrollback, so the pane survives the command. `project` surfaces are Mac-only and skipped. `vm workspace open` (and the sidebar click) then materializes the same splits, ratios and tabs locally, so the layout an agent arranged in the cloud is the layout the person sees. Export first when you want to reproduce a human's arrangement on another machine or in a fork.

## Project environment: env vars, files, repos

```bash
cmux vm env set <m> DATABASE_URL=… API_KEY=…       # stored 0600 at ~/.config/cmux/env in the work user's home on the machine's persistent volume
cmux vm env set <m> --from-file .env               # dotenv rules: blank/# skipped, optional `export `, quotes stripped
cat .env | cmux vm env set <m> -                  # same, from stdin (nothing in argv or history)
cmux vm env ls <m> [--show] [--json]               # names only unless --show
cmux vm env rm <m> API_KEY
cmux vm push <m> ./config work/app/config          # files and folders (tarball, SHA-256 verified; .git/node_modules excluded by default)
cmux vm push --secret <m> ./id_ed25519 ~/.ssh/id_ed25519   # ONE secret file over the link into `cmux file receive` (0600, atomic); never through exec
cmux vm push <m> ./config work/app/config --watch  # keep it in sync while you edit locally (Ctrl-C to stop)
git bundle create /tmp/repo.bundle --all && cmux vm push <m> /tmp/repo.bundle work/repo.bundle   # a private repo with history, no credential on the machine
cmux vm exec <m> -- sh -c 'cd work && git clone repo.bundle app'
```

`vm env` values are sourced by every login and interactive shell on the machine (`~/.profile` / `~/.bashrc` hook, installed once), so terminals from `vm open`, `surface new-terminal`, `vm agent`, layout panes and `vm exec` all see them, and so do agents the in-VM `cmux agent …` starts.

**How values travel, and the rules that keep them secret.** `vm env set` sends values over the machine's cmux-tui link (end-to-end encrypted between the Mac and the daemon on the private WireGuard network; the control plane brokers the route but never reads it) into the machine's `cmux env receive`, which turns terminal echo off before it reads. Nothing passes through `vm.exec`, a provider API, a command line, shell history, or a terminal's screen, and the daemon never journals terminal input. On the machine they are one root-only 0600 file. Your side of the bargain: prefer `--from-file .env` or `-` (stdin) over `KEY=VALUE` arguments so values stay out of *your* shell history and `ps`; keep values out of layout documents (names belong there, values in `vm env`); `vm env ls` prints names unless you pass `--show`; and remember that forks, snapshots and templates copy the volume, file included (`cmux vm env rm` before `vm promote-template`). Do not put the user's own account tokens on a machine unless they ask; model credentials already reach agents through CodeRouter's edge and never sit in the guest.

## The grammar (one spelling per concept)

| Where you are | What you address | Spelling |
|---|---|---|
| Mac | a machine | `cmux vm <verb> <machine> …` — everything about machines lives here |
| Mac | this Mac's own session | the unprefixed local verbs (`cmux send-key`, `cmux new-workspace`, …) |
| inside a machine | **this** machine's session | the same unprefixed local verbs as on a Mac (`cmux send-key`, `cmux terminal send`, `cmux layout apply`, `cmux env set`, `cmux notify`) |
| inside a machine | **another** machine | `cmux vm <verb> <machine> …` — the same grammar as on the Mac |
| inside a machine | the owner's machines | `cmux vm ls` (this one marked `*`, with reachability) |
| inside a machine | myself | `cmux self [peers\|integrations\|owner\|machine] [--json]` (aliases: `cmux whoami`, `cmux reflect [<path>]`) |
| Mac | a machine's identity | `cmux vm self <machine> [<path>] [--json]` — the same reflection payloads through your session |

## Inside a machine: the same verbs, and other machines

Every machine has its own `cmux` (a shim over its cmux-tui daemon). An agent running *in* the machine drives its own session with the Mac spellings — the target defaults to its own terminal (`$CMUX_TUI_TERMINAL_ID`):

```bash
cmux self                               # who am I: name, id, status, team, owner, plan (reflection; no credential in the guest)
cmux self peers                         # the owner's other machines and their routes; `cmux self integrations` = what I can use, with help commands
cmux vm ls                              # every machine of the owner, this one marked *, with reachable/linked state
cmux tree --json                        # this machine's workspaces/terminals
cmux new-workspace --name tests         # a workspace here
cmux terminal send <term> 'bun test' --keys enter ; cmux terminal wait <term> --pattern 'pass|fail' ; cmux terminal read <term>
cmux terminal wait-exit <term> --timeout 600 ; cmux terminal output <term>   # block until the process exits, then read the full output (not just the screen)
cmux send-key --terminal <term> ctrl+c  # keys into another terminal on this machine
cmux layout apply --name app app.json   # the same layout verb, locally
cmux env ls                             # the same env file
cmux notify --title "done" --body "…"   # lands on the Mac pane showing this terminal
cmux agent claude --timeout 600 "fix the tests"     # runs in this terminal until it exits (it is the wait; exit code passes through; --timeout caps it)
```

To talk to **another** machine (a second agent, a service box), a machine discovers its peers through reflection (`cmux self peers` or `cmux vm ls`; the owner's private network is the trust boundary, so no Mac step is needed — older Mac-written route files still work). Inside `src`, `cmux vm …` takes the peer as its first argument with the same grammar the Mac uses: `cmux vm tree <dst>`, `cmux vm exec <dst> -- <cmd>`, `cmux vm terminal send|read|wait|close <dst> <term> …`, `cmux vm terminal send <dst> <term> enter`, `cmux vm workspace new|rename|close|rm <dst> …`, `cmux vm agent <dst> --agent codex -- "review work/app"` (a durable terminal on the peer running the peer's own agent config), `cmux vm layout export|apply <dst> …`, `cmux vm env set|ls|rm <dst> …`, `cmux vm push <dst> <file> <remote-path>` (one file over the link, secret-safe), `cmux vm agent <dst> … --wait --output` (until the peer's agent exits). No control-plane credential lives in any VM; a machine reaches only machines of its own owner.

A pane showing a machine surface is an ordinary local pane: move, split, reorder, or close it with the local topology verbs (`../cmux/SKILL.md`) and the surface catalog follows the pane; closing a pane never kills the machine's terminal. A local workspace that *mirrors* a machine workspace (opened with `cmux vm workspace open`, or bound with `workspace.cloud_vm_bind`) is that workspace seen from the Mac, so its structure is the machine's: a pane moved into it takes its tab there (a pool terminal gets one), a terminal pane closed in it closes that tab (the terminal detaches into the Terminals pool, still running), and a tab or workspace renamed there is renamed on the machine. Closing the local workspace itself (⌘⇧W) only ends the view: the machine workspace and its terminals stay exactly as they were. Panes in any other local workspace are viewers and never touch the machine's layout. Rearranging the machine's topology in full is what `cmux vm tui <id>` is for.

## CodeRouter and model credentials

CodeRouter routes **model credentials**, not compute. An agent started with `vm agent` inside a machine authenticates the same way it would locally (its own login, or CodeRouter's env/config in the machine's `/root`); set that up once on the machine (`vm exec <id> -- …`) and it persists on the volume. Do not put the user's tokens on a machine unless they ask.

The guest `cmux` adapter exposes the shared auth and CodeRouter commands:

```bash
cmux auth status --json
cmux coderouter status --json
cmux coderouter usage
cmux coderouter models
cmux coderouter agent claude "summarize the current checkout"
cmux agent codex "run the tests"
```

`auth status` reports daemon health, TLS reachability, and VM-bound route authentication
without printing credentials. Stack account login and upstream credential management remain
host-owned (`cmux auth login`, `cmux coderouter claude …` on the Mac); never copy those
tokens into a VM. A bare agent sentence uses the provider's one-shot form, while flags and
provider subcommands pass through unchanged.

## Agent policy

- **Prefer `vm route` / `vm run` / `vm agent` over naming machines.** They only draft pool machines; `--machine <id>` is the deliberate way to use another.
- **Reuse before create.** `vm ls`, then an idle machine or Base. Free plans: one machine, 7 days.
- **Stay headless while working** (`--detach`, `--no-open`, `--print`); open panes (`vm open`, `vm tree`'s addresses) to *show* results.
- **Checkpoint before risky operations** (`vm snapshot`), fork instead of experimenting on a machine the user relies on.
- **Only destroy what you created this session.** `vm rm` is permanent.
- **Stage, then show.** Prefer `vm dev --no-open` for a project, or `vm layout apply --name <workspace>` for a hand-authored layout; `vm workspace new --no-open` intentionally preserves a starter-shell workspace and is not an empty layout target. Verify with `vm tree`/`terminal read`, then `vm workspace open` so the person lands in a finished layout, not a half-built one.

## Common issues and fixes

| Symptom | Fix |
|---------|-----|
| `vm exec` hangs or times out | Exec is capped (~30 s default). Background it: `nohup … > /tmp/x.log 2>&1 &`, then poll — or use `vm agent` / a terminal in the session for long work. |
| `claude`/`codex` not found on a brand-new machine | Provisioning is still running: `cmux vm exec <id> -- tail /tmp/cmux/provision.log`; the agents land in `/root/.npm-global/bin` (on PATH in login shells). |
| First command after idle is slow | The machine was asleep: `cmux vm wait <id> --wake`. |
| `vm route` says it would provision | The pool is empty/busy. Check the plan meter; `--provision` (or `vm run`) creates one. |
| Create fails with an active-limit error | Plan cap (free: 1). Report it; let the user upgrade or choose a machine to remove. |
| `vm open <m>/<ws>` says no such workspace | Names are the cmux-tui workspace names; copy the `ws_…` id from `cmux vm tree <m>`. |
| `vm layout apply --workspace` says the workspace is not empty | `vm workspace new --no-open` preserves a starter shell; use `vm layout apply --name <workspace>` or `vm dev` instead. |
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
