# cmux Cloud CLI reference

The Rust `cmux` reaches Cloud machines through the app's cloud actions. The Swift
`cmux vm …` family and its `cmux cloud` alias were removed: there is no `vm.*` socket
method on the CLI and no `cmux rpc`. Today's `cmux vm` calls the cmux VM API with an
API key and no app; see [headless.md](headless.md).

## Conventions

- **Requires** the cmux app running on the Mac and a signed-in account. Actions go
  to the app control socket (`CMUX_SOCKET_PATH`, else the app bundle's socket).
- **Discover** with `cmux action list --category cloud [--available]` and
  `cmux action describe "<cli name>"`. `describe` prints targets and arguments.
- **Run** with `cmux <noun> <verb> [--target machine:vm-…] [--<arg> <value>] [--wait]`
  or `cmux action run <id> …` with the same flags. `--wait` waits for the action's
  work to finish. `--json` prints the result object.
- **Target:** `--target machine:vm-…`, required from the CLI or MCP: a machine
  action run without it is refused (only a person's own click falls back to the
  machine in front of them). The copy actions (machine id, link, port)
  are menu-only: the CLI never writes the clipboard.
- **Results** come back in the action result's `result` object (`--json` prints it);
  nothing opens on the person's screen. `cloud exec` returns `exit_code`, `stdout` and
  `stderr`; `cmux machine new` (the `new-machine` action) returns `machine_id` and `target` (or `pending: true` while
  the server still provisions); `ssh` and `new-terminal-on-machine` return `machine_id`,
  `workspace_id` and, when known, the new terminal's `surface_id` (see [Terminals](#terminals));
  `machine-status`, `machine-ports`, `machine-tools`, `hand-off-machine`,
  `snapshot-machine` (`snapshot_id`, or `pending`), the file actions, `prepare-scp`
  and the network, firewall, domain and publication lists return `text` and their fields.
  `list-machines` returns `machines` (see [Listing machines](#listing-machines)).
- **GitHub on a machine:** `cloud setup-github` sets `git config --global user.name`
  and `user.email` on the machine (as its work user) from this Mac's global git config,
  and starts `gh auth login --web` there. It returns only `ok`, `user_name`,
  `user_email`, `gh_status` (`logged_in`, `pending`, `missing`, `failed`) and, while
  pending, `device_code` and `verification_uri`: the person enters the code at
  https://github.com/login/device. No token leaves the Mac; the machine gets its own.
  Add `--focus` to open that page in the person's browser.
- **Exit codes:** `0` success, `1` action failure, `2` usage, `3` app unreachable.

## Listing machines

<<<<<<< HEAD
`cmux vm ls` is read only: it answers the app's own Cloud machine list,
the one the sidebar's Cloud machines show, so an agent can check whether its machine
already exists before it runs `cmux machine new`. It takes no target. Run by a person from
the palette, it shows the Cloud sidebar instead.
=======
```bash
cmux auth status
cmux vm ls --json
cmux vm route --json
cmux vm tree --json
```

### Command catalog

These are individual examples, not a sequence to run. VPN and workspace commands
below can change state; choose only the operation needed for the task.

```bash
cmux auth status                       # signed in?
cmux vm ls                             # NAME / LABEL / STATE / PROVIDER / IMAGE + plan meter (+ free-window countdown)
cmux vm ls --json                      # {vms: [{id, status, image, createdAt, freeAccessExpiresAt, capabilities: {ports, …}}], limits: {maxActiveVms, planId, memoryOptionsMb, freeAccessWindowDays, freeAccessExpiresAt}}
cmux vpn status                        # this build's WireGuard tunnel to its private machine network (machines open no public port): up, down, or up for another enrollment (stale)
cmux vpn up                            # enroll this Mac and bring the tunnel up (sudo); a stale tunnel (rotated keys) is replaced. One tunnel per deployment (`cmux` for production, `cmux-staging`/`cmux-dev` for dev builds), so a dev build and the production app can both be up
cmux vpn down                          # take this build's tunnel down (sudo)
cmux self                              # INSIDE a machine: this machine's name, id, status, team (--json: {schema, machine, team, machines}); guest `cmux vm ls` lists the team's machines with this one marked *
cmux vm tree                           # the surface catalog: This Mac (terminals by workspace, browsers), then every machine → Workspaces, Ports, VNC Displays, Terminals
cmux vm tree <id> --refresh            # one machine (`local` for This Mac), re-synced first
cmux vm workspace new <id> [--name n]  # a new cmux-tui workspace on the machine (⌘N there), opened as a new local workspace
cmux vm workspace open <id> <ws-id>    # open a machine workspace as a NEW local workspace: one pane per terminal/browser (clicking its row)
cmux vm workspace open <id> <ws-id> --here [--workspace <local>]      # into the current local workspace: one pane + the rest as tabs (drop a workspace row onto a pane)
cmux vm workspace open <id> <ws-id> --tabs [--pane <p>]                # all as tabs of the focused/--pane pane (CLI placement)
cmux vm workspace open <id> <ws-id> --pane <p> --left|--right|--up|--down   # what dropping the row on that pane edge does
cmux vm workspace rename <id> <ws-id> <name>   # rename that workspace (the row's "Rename…")
cmux vm workspace close <id> <ws-id>   # CLI-only: close that workspace but keep its terminals running in the Terminals pool
cmux vm workspace rm <id> <ws-id>      # close that workspace AND kill every terminal in it (the row's "Close Workspace…" / hover ×). Permanent.
cmux vm terminal close <id> <term-id>  # end one terminal on the machine (the sidebar's ×); its local panes close too
cmux vm terminal send <id> <term-id> [text] [--keys enter,ctrl+c,…]   # type into the terminal headlessly (as-is, no newline), then press named keys (chords join with +); no pane, no focus
cmux vm terminal read <id> <term-id>   # the visible screen as text (--json: + rows, cols, cursor)
cmux vm terminal wait <id> <term-id> --pattern <regex> [--timeout <s>]   # block until the screen matches (default 30 s); exit 1 on timeout
cmux vm tree --json                    # {machines: [{id, local, name, status, link_state, …}], resources: [{id, machine, kind, key, title, detail, lifecycle, agent, remote_workspace, port, url, open, open_surface_ids}], projections: […]}
cmux surface ls [--json]               # same catalog; `surface open <resource>` / `surface new-terminal --machine <m>` / `surface new-display --machine <m>` are the generic verbs
cmux vm status <id>                    # provider, status, image
cmux vm stats <id>                     # CPU/mem/disk now; sleeping machines stay asleep
cmux vm clean <id>                     # dry-run: what disk cleanup would free (removes nothing); --apply removes it
cmux vm resize <id> --disk 40G         # grow persistent disk in 4 GiB steps (never shrinks)
cmux vm network <id>                   # outbound policy: mode, presets, domains, ranges, applied state
cmux vm agent-updates <id>             # latest (updated on attach) or image (baked pins)
cmux vm tools <id>                     # which tools are installed
cmux vm ports <id>                     # listening TCP ports inside the machine
cmux vm handoff <id>                   # short attach block to paste to a human or another agent
```

Only then choose `vm run`/`vm agent` (router-managed work), `vm base open`
(the persistent personal machine), or an explicit `vm new`. Use `--json` for
automation and the human output when teaching a person what to click or copy.

## Machines

### `cmux vm ls`

```bash
cmux vm ls [--json]                    # alias: cmux vm list
```

Socket `vm.list`. Text: a `NAME  LABEL  STATE  PROVIDER  IMAGE` table, then the plan meter (`N of M machines on the <plan> plan` when `limits.maxActiveVms` is set, `N machines on the <plan> plan, no limit` when it is absent) and, on free plans, when free cloud access expires. Empty: `No cloud VMs. Try: cmux vm new`.
`--json`: `{vms: [{id, displayName?, status, provider, image, kind?, capabilities?: {snapshot, fork}, resources?: {vcpus, memoryMb, diskMb?}, createdAt?, freeAccessExpiresAt?}], limits: {maxActiveVms, planId, memoryOptionsMb?, maxDiskMb?, maxMemoryMb?, maxVcpus?, poolVcpus?, poolMemoryMb?, usedVcpus?, usedMemoryMb?, freeAccessWindowDays?, freeAccessExpiresAt?}, imageKinds?}`. Sidebar: the Machines panel list.

### Lifecycle and safety

Create a machine only after `vm ls` shows the available plan capacity. A bare
`vm new` provisions the devbox with displays. The legacy `--base`,
`--no-desktop`, and `--desktop` flags remain accepted but all select that same devbox. Use
`--detach` for a headless create, then wait for readiness before the first
command:
>>>>>>> origin/main

```bash
cmux vm ls --json
```

```json
{"loaded": true,
 "machines": [{"machine_id": "vm-…", "target": "machine:vm-…", "title": "api",
               "status": "running", "owner": "team", "created_at": "2026-10-21T08:00:00Z"}],
 "count": 1, "account": {"signed_in": true}}
```

- `loaded` says whether the app holds a machine list the server answered. Until it
  does (right after launch, signed out, or a first list that failed) the answer is
  `loaded: false` with no machines: that means "not known yet", not "none", so do
  not create a machine on it. A run that finds the list unloaded loads it first and
  answers within about 25 s; a load that takes longer answers `loaded: false` and
  `pending: true` while it finishes, so run it again.

- `status` is the machine's record: `provisioning`, `running`, `paused`, `failed` or
  `unknown`. A paused machine reads `paused`, never `failed`.
- `owner` is `team` when the list is the signed-in team's, else `personal`.
- `created_at` is ISO 8601, or `null` when the server did not say.
- `account` has `signed_in`. It has no `limits`: the app does not keep the plan's
  `max_active_vms`, and a machine count is not an entitlement (`0` means provisioning
  is closed on the plan, `null` means uncapped), so check the plan, not the count.
- Signed out, it answers `signed_in: false` and `loaded: false`. Right after launch it
  waits for the saved sign-in to restore first.
- `cmux machine list` also shows the app's Cloud machines (rows with `kind: "cloud"`),
  but it cannot tell an unloaded list from an empty one; check `vm ls`
  before you create a machine.

## Machine actions

```bash
cmux vm ls                                    # the app's Cloud machines
cmux machine new                                            # prints its target and next steps (--json: machine_id, or pending)
cmux cloud new-workspace                                    # New Cloud Workspace: a new small machine of its own, never a listed one
cmux cloud new-workspace --target machine:vm-…              # a new workspace on that machine
cmux cloud open-machine --target machine:vm-…
cmux cloud open-desktop --target machine:vm-…                # its desktop as a live video stream over the carrier (your own cmux NEXT machine only)
cmux cloud new-terminal-on-machine --target machine:vm-…      # a new workspace with a terminal
cmux cloud new-terminal-on-machine --target machine:vm-… --workspace <workspace-id>   # a terminal tab in that workspace
cmux cloud rename-machine --target machine:vm-… --name <label>
cmux cloud resize-machine --target machine:vm-… --size small|medium|large|xlarge
cmux cloud resize-machine --target machine:vm-… --disk 100   # disk in whole GiB: 4 GiB steps, up to 256, grow-only; --size and --disk may go together
cmux cloud machine-status --target machine:vm-…              # stats, plus hourly_rate_usd, running_since, estimated_cost_usd
cmux cloud machine-ports --target machine:vm-…
cmux cloud snapshot-machine --target machine:vm-…
cmux cloud fork-machine --target machine:vm-…
cmux cloud restore-machine --target machine:vm-… --snapshot <snapshot-id>
cmux cloud promote-machine-to-template --target machine:vm-…
cmux cloud hand-off-machine --target machine:vm-…
cmux cloud kill-machine --target machine:vm-…
cmux cloud pause-machine --target machine:vm-…
cmux cloud resume-machine --target machine:vm-…
cmux cloud set-idle-pause --target machine:vm-… --minutes off|15|30|60|120   # answers idle_pause_minutes
cmux cloud set-network-access --target machine:vm-… --access full|trusted|none   # answers network_access, applied
cmux cloud delete-snapshot --target machine:vm-… --snapshot <snapshot-id>
cmux workspace new-on-machine --machine machine:vm-…
```

`open-machine` (Open Machine) and `machine-tools` (Cloud Machine Tools) are GUI-only: the
sidebar and palette run them, the CLI has no verb for them. From the CLI, open a terminal with
`cmux cloud new-terminal-on-machine --target machine:vm-…` (`--focus` shows it) or
`cmux cloud ssh --target machine:vm-…`, inspect the machine with
`cmux cloud machine-status --target machine:vm-…`, and check its tools with
`cmux cloud exec --target machine:vm-… --command '…'`.

cmux Cloud pauses an idle machine (no attached terminal, ssh or app, no running agent turn, no
command still running in a terminal, no forwarded port). Production pauses it after 2 idle
minutes, counted from 10 minutes after a chat's last turn; a machine whose daemon does not count
agent turns falls back to its own idle policy (30 minutes unless set). The machine's record says
`pauseReason: "idle"`; opening a workspace or terminal on it, or ssh, resumes it.
`set-idle-pause` changes the timeout per machine; `--minutes off` (or `cmux vm new --persistent`)
keeps it running, with only a 24-hour backstop.

A machine reaches the whole internet by default. `set-network-access` narrows it, live and with no
restart: `trusted` allows only GitHub, the package registries and the model providers the server
lists as presets, and `none` only the hosts cmux itself needs. The machine's own allowed ranges
and domains (set in the dashboard) are kept. An agent may only choose `none` (turn access off).

## Shell, commands and files

```bash
cmux cloud ssh --target machine:vm-…                           # opens an SSH terminal; surface_id
cmux cloud exec --target machine:vm-… --command '<cmd>'        # exit_code, stdout, stderr (25 s cap)
cmux vm setup-github --target machine:vm-…                  # this Mac's git identity + gh device-flow sign-in
cmux cloud files-list --target machine:vm-… --path <dir>
cmux vm file-read --target machine:vm-… --path <file>
cmux cloud file-write --target machine:vm-… --path <file> --contents '<text>'
cmux cloud file-mkdir --target machine:vm-… --path <dir>
cmux cloud file-remove --target machine:vm-… --path <file>     # destructive; confirms
cmux cloud file-stat --target machine:vm-… --path <file>
cmux cloud prepare-scp --target machine:vm-…                   # takes an SSH public key
```

From the CLI, `cloud exec` runs the command through the Cloud API and returns its
exit code and output (a person's run types it into a new terminal instead); for a
command longer than 25 s, open a terminal on the machine. `cloud ssh` starts a
terminal. `files-list`, `file-read` (`text`, or `data_base64` for binary), `file-stat`
and `prepare-scp` return their result to the CLI. Run `cmux action describe "cloud prepare-scp"`
for the public-key argument's flag.

## Ports and browser tabs

```bash
cmux cloud open-browser --target machine:vm-… --port 3000 [--path /docs]   # Chromium tab on the machine's localhost:3000; url, surface_id
cmux cloud machine-link --target machine:vm-… --port 3000                  # url (and open_url) of the port; prints it, copies nothing
cmux cloud machine-link --target machine:vm-…                              # machine_id, target, address
cmux cloud port-forward --target machine:vm-… --port 3000                  # local_port and url http://127.0.0.1:<local_port>/ on this Mac
cmux cloud port-list --target machine:vm-…                                 # forwards: port, local_port, url, state
cmux cloud port-close --target machine:vm-… --port 3000
```

`open-browser` opens the tab in the focused pane of the active window and changes
nothing else on screen unless the run passes `--focus`. On a machine of the classic
Cloud link the tab opens in the machine's first workspace, where its `localhost` is
the machine's (`browser.remoteLocalhost`), and it also answers `workspace_id`.
`port-forward`, `port-list` and `port-close` need the Cloud app link; on a classic
link machine they say so and name `open-browser` and `machine-link` instead.

## Terminals

`cloud ssh` opens a terminal tab in the machine's first workspace.
`cloud new-terminal-on-machine` (New Terminal Workspace on Machine) makes a new workspace with a
terminal; with `--workspace <id>` it adds a terminal tab to that workspace of the machine instead.
The id is the `workspace_id` an earlier run answered (or the workspace's `ws_…` id).
From the CLI both answer the new terminal's ids, and nothing moves on the person's screen unless
you pass `--focus`:

```bash
cmux cloud new-terminal-on-machine --target machine:vm-… --json
cmux cloud new-terminal-on-machine --target machine:vm-… --workspace <workspace-id> --json
cmux cloud ssh --target machine:vm-… --json
```

```json
{"machine_id": "vm-…", "workspace_id": "…", "surface_id": "12", "terminal_id": "term_…"}
```

- `surface_id` is the tab's handle on the machine's own daemon; `terminal_id` comes from
  daemons that report one. A new workspace's terminal ids are there once the app has the
  workspace's first tab, so a script should not count on them there.
- A paused machine resumes first. If that takes longer than about 30 s, the answer is
  `{"machine_id": "vm-…", "resuming": true, "pending": true}` and the terminal still opens;
  run `cmux cloud machine-status --target machine:vm-…` to see when the machine is running.
- An unknown `--workspace` is refused: "Machine `vm-…` has no workspace `<id>`.
  `cmux cloud new-terminal-on-machine --target machine:vm-…` makes one." A workspace the app
  has no pane of yet (after a short wait) is refused the same way, naming it; run it again.

## Networks, domains and chat moves

```bash
cmux cloud network-list
cmux cloud firewall-list | firewall-get | firewall-create | firewall-delete   # --path <rule-id>, or JSON for create
cmux cloud tunnel-attach | tunnel-detach | tunnel-rotate-key                 # attach/detach: no arguments (this Mac's team network; a --path id must be that team's); rotate-key: no arguments, the agent daemon makes the new key; this Mac
cmux cloud domain-list
cmux cloud publication-list
cmux cloud provision-api --target machine:vm-… --port 3000 [--name ci]   # URL + API key, one call
cmux cloud api-key-list --path <publication id or hostname>
cmux cloud api-key-revoke --path <publication> --key <key-id> --confirm
cmux cloud move          # Move to Cloud: an agent chat tab, optional --machine
cmux cloud bring-back    # Bring Back Local: the reverse
```

`provision-api` publishes a machine port behind cmux sign-in under a generated
HTTPS hostname and mints an API key for it. It answers `url`, `key`, `cookie`,
`publication_id` and `api_key_id`; the key is shown once. API clients send it as
the `__Host-cmux-api-key` cookie (`curl -H 'Cookie: __Host-cmux-api-key=<key>' <url>`), which
the machine never receives. Running it again for the same port reuses the URL
and mints another key. `api-key-revoke` cuts a key off from the next request.
A browser still reaches the URL by signing in to cmux.

Other domain and publication actions only list. Publishing a public domain,
verifying or removing one has no CLI path. Check each action's arguments with
`cmux action describe` before running it.

Creating, forking, restoring, resizing and killing machines need the user's
authorization for the target and effect.

## Agent sessions on a machine

```bash
cmux cloud start-chat --prompt 'Summarize README.md' --wait --json         # new machine, chat, prompt, reply: one command
cmux cloud start-chat --name dev --prompt '…' --json                       # on machine "dev" (created when missing); answers once sent
cmux vm start-session --target vm:<id> --agent claude              # start a session in that machine's acpmux
cmux vm start-session --name dev --agent codex                          # take machine "dev", or create it
```

`start-chat` is `start-session` plus the prompt and, with `--wait`, the reply: it
answers `reply` (with `--wait`), `machine_id`, `session_id`, `workspace_id`, `tab_id`
and `follow_up`, the `cloud exec` commands that send, wait and read on
that chat in the machine's own acpmux (`cmux-tui acp send|wait|last SESSION_ID`).
With no prompt it answers `sent: false`, `ready_ms` and, when `start-session` named
one, `daemon_tab` (the chat tab's number on the machine's daemon: `start-session`'s
`surface_id`, what `agent-session-attach` takes).

`start-session` answers `machine_id`, `session_id` and `host` (the machine's
`registry:` host), plus the chat's `workspace_id` and `surface_id`. The chat's
tab opens in the machine's first workspace. Without `--cwd` the session starts
in a new folder of its own, `~/chats/<chat-id>`, on the machine. An agent's run starts at once, as the person's own
would; only the Cloud plan's limits refuse it. When the person turned off
`cloud.agentsStartWithoutAsking`, an agent's run asks them first with a card in
its own chat (Start, Not now), like an agent's `cloud move`, and waits up to 2
minutes for an answer. Each refusal names the machine and gives the command to
run again.

## Account and diagnostics

```bash
cmux login
cmux logout
cmux cloud team-picker
cmux cloud diagnostics
cmux cloud open-mobile-pairing
```

## SSH remotes

`cmux remote connect|new-workspace|reconnect|disconnect|install|forget|open-terminal-here` are the
app's actions for cmux-tui on an SSH host. `cmux action describe "remote connect"`
lists its arguments (destination, session, binary, state directory).

## Inside a machine

The machine's own `cmux` speaks the cmux-tui resource grammar (`cmux workspace …`,
`cmux pane …`, `cmux tab …`, `cmux terminal …`) plus guest verbs: `self`, `auth
status`, `coderouter`, `agent`, `env`, `layout export|apply`, `notify`, `open-url`
and `vm ls`. See [guest operations](guest.md).

## Old `vm` verbs and their replacements

<<<<<<< HEAD
| Old verb | Closest supported path |
| --- | --- |
| `vm ls` | `cmux cloud list-machines` |
| `vm route`, `vm tree`, `vm self`, `surface ls` | none on the Mac; `cmux self` and `cmux self peers` inside a machine |
| `vm new\|create` with `--size`, `--name`, `--desktop`, `--detach` | `cmux cloud new-machine` (returns `machine_id`) |
| `vm exec`, `vm run`, `vm dev`, `vm agent` | `cmux cloud exec --command …`, or open a terminal on the machine and use `cmux workspace current run -- <argv>` or `cmux agent <harness>` there |
| `vm terminal send\|read\|wait\|wait-exit\|output\|close` from the Mac | the same work with `cmux terminal <term_…> write\|screen read\|screen wait\|process wait\|output read\|close` inside the machine |
| `vm push\|upload` | `cmux cloud file-write --path <file> --contents …`, or `cmux cloud prepare-scp` then scp |
| `vm pull\|download` | `cmux vm file-read --target machine:vm-… --path <file>` |
| `vm layout export\|apply`, `vm env set\|ls\|rm` from the Mac | `cmux layout …` and `cmux env …` inside the machine |
| `vm open`, `vm shell`, `vm tui`, `vm desktop`, `surface open\|new-terminal` | `cmux cloud new-terminal-on-machine`, `cmux cloud ssh` |
| `vm open <id> <port>`, `vm ports` | `cmux cloud open-browser --target machine:vm-… --port <port>`, `cmux cloud machine-link --target machine:vm-… --port <port>`, `cmux cloud machine-ports` |
| `vm ssh`, `vm scp` | `cmux cloud ssh`, `cmux cloud prepare-scp` |
| `vm pause`, `vm resume` | `cmux cloud pause-machine`, `cmux cloud resume-machine` |
| `vm wait`, `vm restart`, `vm stats`, `vm base open\|reset`, `vm prompt` | none |
| `vm snapshot\|fork\|restore\|promote-template\|rename\|rm\|handoff\|status\|resize` | the matching `cmux cloud …-machine` action |
| `cloud domains list` | `cmux cloud domain-list`, `cmux cloud publication-list` |
| `cloud domains publish` (protected, for an API) | `cmux cloud provision-api --target machine:vm-… --port <port>` |
| `cloud domains publish\|verify\|access\|rm\|zones` (public or custom domains) | none |
| `vpn up\|down` | `cmux cloud tunnel-attach\|tunnel-detach` (this Mac's team network; no machine target) |
| `vpn status`, `ai-accounts`, `auth login\|logout` | none on the CLI; use the app |
| `capabilities`, `rpc <method>` | `cmux app capabilities`, `cmux action list` |
=======
```bash
cmux surface open <resource> [--workspace <id|ref|index>] [--pane <id|ref>] [--left|--right|--up|--down|--tab] [--new] [--focus|--no-focus] [--json]
# alias: cmux surface project
```

Socket `surface.project {resource, workspace_id?, pane_id?, direction?, placement?, reuse?, focus?}` → `{surface_id, workspace_id, reused, resource}`: puts one surface in a pane through the single open path. Reuses the pane already showing the resource unless `--new`; `--pane` + a side splits that pane on that side, `--tab` adds a tab to it, otherwise the workspace's focused pane; a local terminal moves to the destination (it can be shown once). Text `OK surface=… workspace=… resource=… [reused=true]`. Sidebar: row click, Open in New Tab, Open in New Pane, drag onto a pane edge.

### `cmux surface new-terminal`

```bash
cmux surface new-terminal --machine <id|local> [--cwd <dir>] [--name <name>] [--remote-workspace <ws_…>] [--workspace <id|ref|index>] [--no-open] [--focus|--no-focus] [--json] [-- <command...>]
# alias: cmux surface new
```

Socket `surface.new_terminal {machine, command?, cwd?, name?, remote_workspace_id?, open?, workspace_id?}` → `{resource, terminal_id, machine, remote_workspace_id, workspace_id?, surface_id?}`: a terminal on the machine through its provider (cloud terminals land in the machine's cmux-tui session; `--remote-workspace` picks which; `local` is a new shell on This Mac), opened as a pane unless `--no-open`. Sidebar: Terminals / Workspaces › New Terminal; workspace row › New Terminal Here.

### `cmux surface new-display`

```bash
cmux surface new-display --machine <cloud-id> [--workspace <id|ref|index>] [--no-open] [--focus|--no-focus] [--json]
```

Socket `surface.new_display {machine, open?, workspace_id?, focus?}` → the created display resource (`resource`, `id`, `machine`, `kind`, `title`, `url`, and related catalog fields), plus `workspace_id` / `surface_id` when opened. Creates a new VNC display on a cloud machine through the guest display helper. It opens the display in the selected workspace unless `--no-open`; `--focus` and `--no-focus` control whether that pane is focused. `local` is rejected because display creation is a cloud-machine operation. If the display is created but cannot be opened, the result has `projection_failed: true`, `open: false` and a `projection_error`; the exit status stays 0 and `cmux surface open <resource>` retries the open. A second creation on the same machine while one is running fails with code `busy`. The method is available on the local cmux socket and is intentionally not relayed through a remote machine.

## Checkpoints and forks

Provider-dependent: `cmux vm ls --json` → `capabilities.snapshot` / `capabilities.fork` say whether a machine supports them; the sidebar hides the verbs on providers that cannot.

### `cmux vm snapshot`

```bash
cmux vm snapshot <id> [--name <name>] [--json]    # alias: cmux vm checkpoint
```

Socket `vm.snapshot {id, name?}`. Text `OK snapshot=<snapshot id>`; `--json` the payload (`snapshot_id` or `id`). Sidebar: machine row › Checkpoint.

### `cmux vm fork`

```bash
cmux vm fork <id> [--name <name>] [--window <id|ref|index>] [--detach|-d] [--json]
```

Socket `vm.fork {id, name?, idempotency_key}`: clones a machine as a new tracked machine for a parallel experiment. `--detach` prints `OK <id>` with provider, image, and snapshot (`native fork` when the provider forks without one); otherwise opens the new machine's shell. Sidebar: machine row › Fork.

### `cmux vm restore`

```bash
cmux vm restore <snapshot-id> [--provider <provider>] [--window <id|ref|index>] [--detach|-d] [--json]
```

Socket `vm.restore {snapshot_id, provider?, idempotency_key}`: a snapshot as a new tracked machine; opens its shell unless `--detach`.

### `cmux vm promote-template`

```bash
cmux vm promote-template <id> [--json]
```

Socket `vm.snapshot` with a template-oriented name (`template-<id>-<unix time>`). Text `OK template=<snapshot id>`.

## Networking and ports

### `cmux vm ports`

```bash
cmux vm ports <id> [--json]
```

A `vm.exec` of `ss -ltnp` (or `netstat -ltnp`): the TCP ports listening **inside** the machine. `--json`: the exec payload.

### Port URLs: `cmux vm open <id> <port>`

See `vm open`: `cmux vm open <id> 3000` opens an HTTP port on the machine as a browser pane (`vm.port_open`); `--print` only mints and prints the URL (`vm.open_port`, `--json` → `{open_url, …}`). The URL points at the machine's **private VPC address** — reachable only through the owner's WireGuard tunnel (`cmux vpn up`), never a public ingress; the daemon's own port is refused, and the lease carries an expiry. Only share URLs minted this way; never guess provider URLs (they resolve for the machine's owner only).

## Account and plan

### `cmux vpn`

```bash
cmux vpn up          # enroll this Mac on first run, bring the WireGuard tunnel up (wg-quick, prompts for sudo; brew install wireguard-tools)
cmux vpn down        # tunnel down; enrollment kept
cmux vpn status      # tunnel state, config path, backend
cmux vpn on           # alias for up
cmux vpn off          # alias for down
cmux vpn revoke       # tunnel down + unenroll (server deletes its side)
```

The tunnel between this Mac and the private Cloud VM network. Config lives under `~/.cmuxterm/wireguard/` — **one tunnel per deployment** (interface `cmux` for production, `cmux-staging`/`cmux-local`/`cmux-dev` for other API origins), so a dev build and the production app can both be up side by side. The private key is generated on this Mac and never leaves it. Run `up` once per boot before the attach/exec/port verbs; a stale tunnel (another enrollment's keys — `vpn status` reports it) is replaced by `up` instead of read as up.

`hosts` reads `vm.list` and publishes `<machine>.internal` names (id slug, plus the display label when it differs) system-wide, so browsers and curl resolve them whenever the tunnel is up — a manual convenience for you and the user; the verbs themselves use raw addresses. `up` re-syncs the block quietly on success, so run `hosts` yourself mainly right after `cmux vm new`; `--json` answers `{hosts_changed, machine_count}`.

### `cmux auth`

```bash
cmux auth status [--json]              # {signed_in, …}; socket auth.status
cmux auth login                        # alias: cmux login — opens the sign-in popup (auth.begin_sign_in / auth.sign_in_url) and waits
cmux auth logout                       # alias: cmux logout — auth.sign_out
```

Every `cmux vm` verb requires a signed-in app.

### Plan meter and limits

`cmux vm ls` prints `N of M machines on the <plan> plan` when the plan carries a cap, or `N machines on the <plan> plan, no limit` when it does not — the cap is whatever the backend sends (`cmux vm ls --json` → `limits`: `maxActiveVms?`, `planId`, `memoryOptionsMb?`, `freeAccessExpiresAt` when a free window applies); plan tiers and their caps change on the pricing page, so read them from `limits`, never from memory. **Provisioning is gated to paid plans**: `vm new`, a first `vm base open`, `base reset`, `fork`, `restore`, and the router's provisioning path return the `vm_requires_pro` error (with the pricing link) on free or unknown plans. Report caps and gates — never delete machines to make room without asking. A parsed size not present in `memoryOptionsMb` resolves to the plan default; inspect the create result or `vm stats` rather than assuming the request was honored.

### `cmux ai-accounts`

```bash
cmux ai-accounts list [--team <id>] [--json]
cmux ai-accounts upload <claude|codex|anthropic-key|openai-key> [--label <s>] [--key <s>] [--team <id>] [--validate] [--json]
cmux ai-accounts remove <account-id> [--team <id>] [--json]
```

Sockets `aiAccounts.list` / `aiAccounts.upload` / `aiAccounts.remove`: uploads local AI credentials to the team's subrouter tenant so agents started with `vm agent` can authenticate on a machine without copying tokens onto it. Only on the user's say-so.

### `cmux capabilities` and `cmux rpc`

```bash
cmux capabilities                      # socket system.capabilities: every method the app serves, including the vm.* and surface.* set below
cmux rpc <method> [json-params]        # call any v2 method directly, e.g. cmux rpc vm.stats '{"id":"brave-otter"}'
```

## Socket methods (the app's `vm.*` / cloud `surface.*` set)

| Method | CLI verb |
|---|---|
| `vm.list` | `vm ls` |
| `vm.create` | `vm new`, and `vm run` / `vm route --provision` / `vm agent` when they provision |
| `vm.base_open`, `vm.base_reset` | `vm base open`, `vm base reset` |
| `vm.status` | `vm status`, `vm handoff`, `vm wait` |
| `vm.stats` | `vm stats`; the router's load scoring |
| `vm.hygiene` | `vm clean`, `vm clean --apply` |
| `vm.env_set` | `vm env set` |
| `vm.file_put` | `vm push` |
| `vm.pause`, `vm.resume`, `vm.restart` | `vm pause`, `vm resume`, `vm restart` |
| `vm.reflection` | `vm self` |
| `vm.snapshot_list`, `vm.snapshot_delete` | `cmux rpc vm.snapshot_list`, `cmux rpc vm.snapshot_delete` |
| `vm.terminal_output`, `vm.terminal_wait_exit` | `vm terminal output`, `vm terminal wait-exit` |
| `vm.diagnostics` | `cmux rpc vm.diagnostics '{}'` returns the app's cloud-operation report; `{"show":true}` also opens the diagnostics window |
| `vm.resize` | `vm resize <id> [--cpu …] [--memory …] [--disk …]`; machine row › Resize machine |
| `vm.rename` | `vm new --name` and the router's `agent-pool` label; direct machine-label editing is currently a sidebar action |
| `vm.tab_rename` | `vm tab rename` |
| `vm.terminal_rename` | `vm terminal rename` |
| `vm.publication_grant`, `vm.publication_grants`, `vm.publication_ungrant` | publication viewer grant management exposed by the Cloud publication controller |
| `vm.tunnel_config`, `vm.tunnel_up`, `vm.tunnel_down`, `vm.tunnel_status`, `vm.tunnel_wait`, `vm.tunnel_revoke` | WireGuard enrollment and lifecycle behind `cmux vpn up|down|status|on|off|revoke` |

| `vm.snapshot` | `vm snapshot`, `vm promote-template` |
| `vm.fork`, `vm.restore` | `vm fork`, `vm restore` |
| `vm.destroy` | Cloud sidebar machine deletion |
| `vm.exec` | `vm exec`, `vm run`, `vm push`, `vm pull`, `vm wait --wake`, `vm tools`, `vm ports` |
| `vm.open_port`, `vm.port_open` | `vm open <id> <port> --print`, `vm open <id> <port>` / `<id>:port/<n>` |
| `vm.desktop_open` | `vm desktop`, `vm open <id>:desktop`, the split beside `vm shell` |
| `vm.cmux_remote_info`, `vm.link_socket` | the shared machine shell and surface open path |
| `vm.ssh_info` | provider-specific attach diagnostics surfaced by the app |
| `vm.diagnostics` | machine and cloud-operation diagnostics returned by the app for support and failure inspection |
| `vm.scp_info` | SCP endpoint setup and public-key diagnostics used by `vm push` / `vm pull` |
| `vm.attach_info`, `vm.session_attach_info`, `vm.sessions` | legacy websocket/SSH attach transports the open path falls back to on deployments without a cmux-tui daemon (`cmux rpc` reaches them directly) |
| `vm.tree` | the pre-catalog tree; `vm tree` uses `surface.catalog` |
| `vm.terminal_open`, `vm.terminal_new` | older terminal verbs; `vm open <m>/<ws>/<term>` and `surface new-terminal` use `surface.project` / `surface.new_terminal` |
| `vm.workspace_new`, `vm.workspace_open`, `vm.workspace_rename`, `vm.workspace_close`, `vm.workspace_delete` | `vm workspace new|open|rename|close|rm` |
| `vm.terminal_close` | `vm terminal close` |
| `vm.terminal_write`, `vm.terminal_read`, `vm.terminal_wait` | `vm terminal send`, `vm terminal read`, `vm terminal wait` |
| `vm.cloud_prompt`, `vm.cloud_agent_open` | `vm prompt`, `vm prompt --open` |
| `vm.publication_list`, `vm.publication_create`, `vm.publication_verify`, `vm.publication_update`, `vm.publication_delete` | `cloud domains list`, `publish`, `access`, `rm`; `vm.publication_verify` is the app-side publication retry path |
| `vm.domain_list`, `vm.domain_verify` | `cloud domains zones`, `cloud domains verify` |
| `surface.catalog`, `surface.project`, `surface.new_terminal`, `surface.new_display` | `vm tree` / `surface ls`, `surface open` / `vm open`, `surface new-terminal` / `vm agent`, `surface new-display` |

The authenticated public-domain workflow is **shipped on this branch**: use
`cmux cloud domains` for generated or custom HTTPS publications. `cmux vm open
<id> <port>` remains the private WireGuard preview path; it is not a substitute
for a domain publication.

### Current VM primitives

The current CLI also exposes these machine-scoped operations:

```bash
cmux vm self <id> [<path>] [--json]
cmux vm pause <id>
cmux vm resume <id>
cmux vm restart <id>
cmux vm dev <id> [<folder>] [--name <workspace>] [--layout <file>] [--no-open]
cmux vm layout export <id> [<workspace>] [--raw]
cmux vm layout apply <id> <file>|- [--name <workspace>] [--workspace <empty-workspace>]
cmux vm env set <id> KEY=VALUE…
cmux vm terminal wait-exit <id> <terminal> [--timeout <seconds>]
cmux vm terminal output <id> <terminal> [--after <offset>]
```
>>>>>>> origin/main
