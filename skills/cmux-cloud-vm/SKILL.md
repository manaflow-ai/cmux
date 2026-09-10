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

To talk to **another** machine (a second agent, a service box), a machine discovers its peers through reflection (`cmux self peers` or `cmux vm ls`; the owner's private network is the trust boundary, so no Mac step is needed — older Mac-written route files still work). Inside `src`, `cmux vm …` takes the peer as its first argument with the same grammar the Mac uses: `cmux vm tree <dst>`, `cmux vm exec <dst> -- <cmd>`, `cmux vm terminal send|read|wait|close <dst> <term> …`, `cmux vm send-key <dst> <term> enter`, `cmux vm workspace new|rename|close|rm <dst> …`, `cmux vm agent <dst> --agent codex -- "review work/app"` (a durable terminal on the peer running the peer's own agent config), `cmux vm layout export|apply <dst> …`, `cmux vm env set|ls|rm <dst> …`, `cmux vm push <dst> <file> <remote-path>` (one file over the link, secret-safe), `cmux vm agent <dst> … --wait --output` (until the peer's agent exits). No control-plane credential lives in any VM; a machine reaches only machines of its own owner.

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
