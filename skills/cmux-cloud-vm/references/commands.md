# cmux Cloud CLI reference

Every verb the cmux CLI exposes for cmux Cloud, as it exists on this branch. `cmux cloud` is an alias for `cmux vm` (`cmux cloud ls` == `cmux vm ls`). Verbs that exist only in an open PR are listed at the end under [In flight](#in-flight) and nowhere else, so nothing above that heading is something you cannot run today. `tests/test_cloud_vm_skill_coverage.py` fails CI when this file and `CLI/cmux.swift` disagree.

## Conventions

- **Requires** the cmux app running on the Mac and a signed-in account (`cmux auth status`). Every verb talks to the app over its Unix socket (`CMUX_SOCKET_PATH` when set; the app's default socket otherwise) — the app, not the CLI, holds the cloud credentials.
- **`--json`** is a global flag: it may appear before or after the subcommand and prints the socket payload (or the CLI's own summary object, noted per verb) instead of text. Parse JSON, never the human tables.
- **`--help` / `-h`** works offline (no app needed). `cmux vm --help` is the overview; `cmux vm run --help`, `route`, `agent`, `push`, `pull`, `wait`, `open`, `tree`, `workspace`, `terminal`, `tui`, `prompt`, and `base` print that verb's own options (`cmux vm terminal --help` covers close, send, read, and wait). Anything after `--` is never treated as a help flag (`cmux vm exec <id> -- --help` runs `--help` on the machine).
- **Exit codes:** `0` success; `1` any error (socket missing, backend error, usage error, unknown `vm` verb); `2` missing or unknown top-level command. `cmux vm run` exits with the **remote command's exit code**; `cmux vm exec` prints `exit <n>` to stderr and exits `1` when the remote command fails; `cmux vm wait` and `cmux vm terminal wait` exit `1` on timeout (or a failed machine).
- **Ids:** a machine's generated name (`brave-otter`) is its id everywhere; the display label from `vm rename` is cosmetic. Workspace ids are `ws_…`, terminal ids `term_…` (both from `cmux vm tree`). `--window <id|ref|index>` on the opening verbs picks the local window; `--workspace <id|ref|index>` the local workspace.
- **Env:** `CMUX_VM_API_BASE_URL` overrides the backend origin (dev stacks). `HOME` is honored for the router's state files (`~/.cmuxterm/vm-run-pool.json`, `~/.cmuxterm/vm-run-bindings.json`).

## Machines

### `cmux vm ls`

```bash
cmux vm ls [--json]                    # alias: cmux vm list
```

Socket `vm.list`. Text: a `NAME  LABEL  STATE  PROVIDER  IMAGE` table, then the plan meter (`N of M machines on the <plan> plan`, or `N machines on the <plan> plan, no limit` when the paid plan has no cap) and, on free plans, when free cloud access expires. Empty: `No cloud VMs. Try: cmux vm new`.
`--json`: `{vms: [{id, displayName?, status, provider, image, kind?, capabilities?: {snapshot, fork}, createdAt?, freeAccessExpiresAt?}], limits: {maxActiveVms, planId, freeAccessWindowDays?, freeAccessExpiresAt?}, imageKinds?}`. Sidebar: the Machines panel list.

### `cmux vm new`

```bash
cmux vm new [--desktop|--base] [--size <2g|4g|8g|16g|24g|32g|MB>] [--name <label>] [--provider <p>] [--image <id>] [--workspace <id>] [--window <id|ref|index>] [--detach|-d] [--json]
# alias: cmux vm create
```

Socket `vm.create` with the machine **kind** — shell-only (`base`) by default; `--desktop` fails closed with a server-side image config error because no provider ships a desktop image today (`--base`/`--no-desktop` stay accepted for old scripts). The backend picks the image for the kind; `--image <id>` is the explicit override and the only way an image id leaves the client. `--size` is a memory preset (`2g|4g|8g|16g|24g|32g`, aliases `small|medium|large|xl|xxl`, or MB ≥ 512); plans cap it. `--name` applies a display label through `vm.rename` after the create. Positional arguments are rejected (`cmux vm new myvm` errors instead of provisioning). Retries of a failed create reuse an idempotency key so a transient failure never mints two machines.
Without `--detach`, opens a plain terminal on the machine (the same open path as `vm shell`); desktop machines would also get their screen in a split, when a desktop image exists. `--detach` prints `<id> is ready` and the follow-up commands. `--json`: the `vm.create` payload (`{id, provider, image, kind?, …}`) and no pane. Sidebar: Machines panel ＋ / "New Cloud Machine…" sheet (name, kind, size, plan meter). On a free or unknown plan the backend returns `vm_requires_pro` (exit 1); paid plans have no machine cap. Providers: `--provider e2b|freestyle|daytona` (default Freestyle, chosen server-side).

### `cmux vm status`

```bash
cmux vm status <id> [--json]           # alias: cmux vm info
```

Socket `vm.status`. Text: `<id>  [<provider>] <status>` and `image: <image>`. `--json`: `{id, provider, image, status, kind?, …}`. Sidebar: machine row › Status.

### `cmux vm stats`

```bash
cmux vm stats <id> [--json]            # alias: cmux vm top
```

Socket `vm.stats`. CPU, memory, and disk right now; a sleeping machine reports `asleep` and is not woken. `--json`: `{id, state: awake|asleep, cpu_percent, cpus, memory_used_mb, memory_total_mb, disk_used_mb, disk_total_mb}`. The router uses this to pick the least-loaded pool machine.

### `cmux vm rename`

```bash
cmux vm rename <id> <label…>
cmux vm rename <id> --clear
```

Socket `vm.rename {id, display_name?}`. Display label only; the id stays the address. `--json`: the rename payload (`{id, displayName}`). Sidebar: machine row › Rename…. The router labels its own machines `agent-pool`; a user machine renamed `agent-pool` is still never drafted (membership is the persisted id list, not the label).

### `cmux vm rm`

```bash
cmux vm rm <id>                        # aliases: cmux vm destroy, cmux vm delete
```

Socket `vm.destroy`. **Permanent** — machine and its persistent volume. Text `OK <id>`; `--json` `{"ok":true,"id":"<id>"}`. Sidebar: machine row › Delete… (confirms; the CLI does not).

### `cmux vm wait`

```bash
cmux vm wait <id> [--timeout <seconds>] [--wake] [--json]
```

Polls `vm.status` until the machine reports a ready status (`running`, `ready`, `standby`, `paused` — the same set the Machines panel calls ready); `--wake` then runs a trivial `vm.exec` so a sleeper is awake on return. Default timeout 180 s; exit 1 on timeout or a failed state. `--json`: the last status payload plus `{ok: true, waited_seconds, woke}`. Use this instead of polling `vm status` yourself.

### `cmux vm tools`

```bash
cmux vm tools <id> [--json]            # alias: cmux vm tool-inspector
```

A `vm.exec` probe: shell, and whether `zsh git gh htop btop node bun python3` are installed. `--json`: the exec payload `{stdout, stderr, exit_code}`.

### `cmux vm handoff`

```bash
cmux vm handoff <id> [--json]
```

Socket `vm.status`, printed as a short block (id, provider, status, `attach: cmux vm ssh <id>`, `inspect: cmux vm tools <id>`) to paste to a person or another agent. `--json`: the status payload.

### Base: `cmux vm base open` / `cmux vm base reset`

```bash
cmux vm base [open] [--desktop|--base] [--workspace <workspace-id>] [--window <id|ref|index>] [--detach|-d] [--json]
cmux vm base reset [--desktop|--base] [--reason <text>] [--workspace <workspace-id>] [--window <id|ref|index>] [--detach|-d] [--json]
```

Base is the one pinned persistent machine per user. `open` (`vm.base_open`) reuses the same VM every time, creating it on first use with the chosen kind (desktop by default); an existing Base keeps its image. `reset` (`vm.base_reset`) mints a new Base generation and retains the previous VM so an accidental reset is recoverable. Both open a plain terminal unless `--detach`; text `OK <id>`, `--json` the payload. Sidebar: Open Base / Set Up Base sheet.

## Files

### `cmux vm push`

```bash
cmux vm push <id> <local-path> [remote-path] [--exclude <pattern>]... [--no-default-excludes] [--json]
# alias: cmux vm upload
```

Copies a file or directory onto the machine over the exec channel (`vm.exec`, no SSH or daemon needed): base64 chunks of 64 KiB, SHA-256 verified end to end (byte-count fallback when the machine lacks `sha256sum`). Directories travel as tarballs with no AppleDouble `._*` sidecars and merge into the destination; `.git`, `node_modules`, `.venv`, `__pycache__`, `.DS_Store` are skipped unless `--no-default-excludes`; `--exclude` adds patterns. The remote path defaults to the local basename in the exec working directory (`/root`, the persistent volume). 256 MB cap — clone or download inside the machine past that. Text: a one-line summary (plus the excludes applied); `--json`: `{ok, direction: "push", vm, local, remote, kind: file|directory, bytes, sha256, seconds, excluded?}`.

### `cmux vm pull`

```bash
cmux vm pull <id> <remote-path> [local-path] [--json]
# alias: cmux vm download
```

The reverse: file or directory back to local disk (defaults to the remote basename in the current directory). `--json`: `{ok, direction: "pull", vm, remote, local, kind, bytes, sha256, seconds}`.

## Execution

### `cmux vm exec`

```bash
cmux vm exec <id> [--json] -- <command...>
```

Socket `vm.exec {id, command}`. Each argv element is shell-quoted, then joined, so `-- printf '%s\n' "a b"` means what it says; wrap shell constructs as `-- sh -c '<script>'`. No TTY, no stdin, a ~30 s server-side cap (35 s client timeout): background long work (`nohup … > /tmp/x.log 2>&1 &`) and poll, or use `vm agent` / a session terminal. stdout and stderr pass through; a non-zero remote exit prints `exit <n>` and exits 1. `--json`: `{stdout, stderr, exit_code}` (still exit 1 when `exit_code != 0`). Sidebar: none (a person types into a pane).

### `cmux vm run`

```bash
cmux vm run [--sync] [--pull <remote-path>] [--machine <id>] [--new] [--size <2g|4g|8g|16g|24g|32g>] [--timeout <seconds>] [--json] -- <command...>
```

Runs a command on a cloud machine **without naming one**: sticky binding for the caller's directory (`~/.cmuxterm/vm-run-bindings.json`, 14-day TTL) → idle awake pool machine, least-loaded by `vm.stats` → sleeping pool machine (exec wakes it) → provision a fresh shell-only pool machine (`vm.create {kind: base}`, labeled `agent-pool` via `vm.rename`, recorded in `~/.cmuxterm/vm-run-pool.json` under a cross-process `flock`, waited to ready) → at the plan cap, the least-loaded busy pool machine. Only machines the router itself provisioned are drafted; `--machine <id>` pins any machine, `--new` forces a fresh pool machine, `--size` applies to a machine this run creates. `--sync` pushes the current directory to `work/<basename>` first and runs there; `--pull <remote>` fetches that path back afterwards. `--timeout` default 600 s, max 15 minutes.
The routing decision goes to **stderr** (`[cmux vm run] <id> (<reason>)`); stdout is the command's own stdout; the remote **exit code passes through**. `--json`: `{ok, machine, created, exit_code, stdout, stderr, seconds, synced_to?, pulled_to?}`. Socket calls: `vm.list`, `vm.stats`, `vm.exec`, and on provision `vm.create`, `vm.rename`, `vm.status`.

## Routing

### `cmux vm route`

```bash
cmux vm route [--cwd <dir>] [--new] [--provision] [--size <2g|4g|8g|16g|24g|32g>] [--json]
```

Prints the machine `vm run` / `vm agent` would use for a directory and why, without running anything (same policy, same `vm.list` + `vm.stats` calls). Text: `machine=<id> created=<bool>` and `reason: …`; when the pool is empty or busy it prints that `cmux vm run` would provision and stops — unless `--provision`, which creates the machine now. `--json`: `{machine (null when it would provision), created, reason, would_provision, directory}`. Exit 0 in every routed case.

### `cmux vm agent`

```bash
cmux vm agent --agent <claude|codex|opencode|pi> [--machine <id>] [--sync] [--cwd <dir>] [--name <name>] [--no-open] [--new] [--size <s>] [--json] -- <prompt or args...>
```

Starts a coding agent on a cloud machine chosen like `vm run` (or pinned with `--machine`) as a **detached terminal in the machine's cmux-tui session**: `surface.new_terminal {machine, command, cwd, name, open}`, where the command is a login shell that puts `/root/.npm-global/bin`, `/root/.bun/bin`, `/root/.local/bin` first. A bare prompt uses the agent's one-shot form (`claude -p`, `codex exec`, `opencode run`, `pi -p`); args that start with a flag or a known subcommand (`codex exec …`, `claude --resume …`) pass through verbatim. `--sync` pushes `--cwd` (default: the current directory) to `work/<basename>` first and starts the agent there; `--name` sets the terminal's name in the tree (default `<agent>: <prompt…>`); `--no-open` starts it without a pane. The command returns as soon as the terminal starts.
Text: `Started <agent> on <machine> — terminal <term> in workspace <ws> …`, `Reattach: cmux vm open <machine>/<ws>/<term>`, and `OK surface=… terminal=… workspace=…` when a pane opened. `--json`: `{ok, machine, created, reason, agent, command, name, terminal_id, workspace_id, cwd, reattach, surface_id?}`. Credentials: the agent authenticates inside the machine the way it would locally (its own login under `/root`, or `cmux ai-accounts upload` for the team's subrouter).

## Workspaces and terminals (the machine's cmux-tui session)

Every machine runs the cmux-tui remote daemon: its own workspaces (`ws_…`) → terminals (`term_…`). Terminals keep running detached; panes on the Mac merely project them.

### `cmux vm tree`

```bash
cmux vm tree [<machine>|local] [--refresh] [--json]
```

Socket `surface.catalog {machine?, refresh?}` (plus `workspace.list` to name local workspaces). The Finder-style view of every surface: **This Mac** first (terminals grouped by workspace, then browsers), then each cloud machine — its workspaces, each workspace's terminals (title, cwd, lifecycle, agent state, and the pane that already shows it), `desktop`, and forwarded `ports/`. Every line carries an address `cmux vm open` or `cmux surface open` accepts. `--refresh` re-syncs every provider first. `--json`: `{machines: [{id, local, name, status, image, has_desktop, memory_mb, disk_mb, link_state, link_error, cpu_percent, memory_used_mb, disk_used_mb}], resources: [{id, machine, kind: terminal|screen|browser, key, title, detail, lifecycle, agent, remote_workspace, port, url, open, open_surface_ids, open_workspace_ids}], projections: [{resource, workspace_id, surface_id}]}`. Same as `cmux surface ls`. Sidebar: the Cloud tree itself; machine row › Refresh.

```
vivid-newt  running  · 24 GB · 16 GB disk · link connected
  workspaces/
    main  ws_3c1…  *  (cmux vm open vivid-newt/ws_3c1…)
      ● term_2f9…  bun test  ~/work/app  [agent claude running]  (open: surface:4)
      ○ term_88a…  bash                                  ← exited
  terminals/                                   ← the pool: every terminal the machine owns
  desktop  (cmux vm open vivid-newt:desktop)
```

### `cmux vm workspace new`

```bash
cmux vm workspace new <machine> [--name <name>] [--json]
```

Socket `vm.workspace_new`: creates a workspace on the machine (its ⌘N, with a first terminal) and opens it as a new local workspace. Text `OK workspace=<local id> remote_workspace=<ws id> machine=<id>`. Sidebar: machine row › New Workspace; Workspaces ＋.

### `cmux vm workspace open`

```bash
cmux vm workspace open <machine> <workspace-id> [--here] [--tabs] [--workspace <local>] [--pane <id|ref> [--left|--right|--up|--down]] [--json]
```

Socket `vm.workspace_open`: the machine workspace's terminals and browsers as a **new local workspace**, one pane each (what clicking the row does). `--here` projects them into the current (or `--workspace`) local workspace instead — one pane at the destination, the rest as tabs ("Open All Here"); `--tabs` makes all of them tabs of the focused (or `--pane`) pane; `--pane <p>` + a side splits that pane on that side (dropping the row on a pane edge). Text `OK workspace=<local> opened=<n> machine=<id> [here]`. Also `cmux vm open <machine>/<ws>` for the workspace's focused terminal only. An empty workspace opens nothing.

### `cmux vm workspace rename`

```bash
cmux vm workspace rename <machine> <workspace-id> <name> [--json]
```

Socket `vm.workspace_rename`. Sidebar: workspace row › Rename….

### `cmux vm workspace close`

```bash
cmux vm workspace close <machine> <workspace-id> [--json]
```

Socket `vm.workspace_close`: closes the workspace; its terminals **keep running** in the machine's Terminals pool (plain rows there). CLI-only — the sidebar's single "Close Workspace…" is the full close (`vm workspace rm`).

### `cmux vm workspace rm`

```bash
cmux vm workspace rm <machine> <workspace-id> [--json]     # alias: cmux vm workspace delete
```

Socket `vm.workspace_delete`: kills every terminal viewed in the workspace, then closes it. Permanent. Text `OK deleted workspace <ws> on <machine> (<n> terminals closed)`. Sidebar: workspace row › Close Workspace… and its hover × (confirms only when there is something to kill).

### `cmux vm terminal close`

```bash
cmux vm terminal close <machine> <terminal-id> [--json]
```

Socket `vm.terminal_close`: ends a terminal on the machine (the process and its tab); every local pane showing it closes too. Sidebar: terminal row › Close Terminal / hover ×.

### `cmux vm terminal send`

```bash
cmux vm terminal send <machine> <terminal-id> [text] [--keys <k1,k2,…>] [--json]    # alias: cmux vm terminal write
cmux vm terminal send <machine> <terminal-id> -- 'text that starts with --keys'
```

Socket `vm.terminal_write {id, terminal_id, text?, keys?}` (cmux-tui `terminal <id> write` / `keys`): types `text` into the machine terminal exactly as given (no newline), then presses the named keys — `enter`, `tab`, `escape`, `up`, `down`, …; chords join with `+` (`ctrl+c`). `--keys enter` alone presses Enter; give text and/or `--keys`. Headless: no pane is attached or focused, and every pane already projecting the terminal shows the input. Put `--` before text that contains this command's own flags. Text `OK sent <n> chars [+ keys …] to <term> on <machine>`; `--json`: the payload (`{wrote, …}`). Sidebar: none by design (a person types into the pane).

### `cmux vm terminal read`

```bash
cmux vm terminal read <machine> <terminal-id> [--json]    # alias: cmux vm terminal screen
```

Socket `vm.terminal_read {id, terminal_id}` (cmux-tui `terminal <id> screen read`): the terminal's visible screen as text — what a person at that terminal sees. `--json`: `{text, rows, cols, cursor_row, cursor_col, cursor_visible}`.

### `cmux vm terminal wait`

```bash
cmux vm terminal wait <machine> <terminal-id> --pattern <regex> [--timeout <seconds>] [--json]
```

Socket `vm.terminal_wait {id, terminal_id, pattern, timeout_ms}` (cmux-tui `terminal <id> screen wait`): blocks until the screen text matches the regex. `--timeout` is seconds (default 30, 0.001–3600; out of range is an error). Text `OK matched /<pattern>/ on <term>`; `--json`: `{matched, text, …}`. Exit 1 with the screen tail on timeout.

The headless loop for any interactive program on a machine (a REPL, a TUI, a long test run, another agent's session): `cmux surface new-terminal --machine <m> --no-open -- <cmd>` (or `vm agent --no-open`), then `terminal send … --keys enter`, `terminal wait … --pattern '…'`, `terminal read …`. Open a pane for the person only when there is something to show.

### `cmux vm prompt`

```bash
cmux vm prompt [--json]                # alias: cmux vm skill
cmux vm prompt --open <claude|codex|opencode>
```

Bootstraps an agent that has **no skill loaded**: `vm.cloud_prompt` installs the app-bundled cmux-cloud skill file at `~/.config/cmux/skills/cmux-cloud.md` and prints the kickoff prompt that points any agent at it (the skill path goes to stderr; `--json`: `{prompt, skill_path}`). `--open <agent>` (`vm.cloud_agent_open`) opens a local terminal running that agent with the prompt (`OK opened <agent> … (terminal=<surface>)`; `--json`: `{surface_id|terminal_id, …}`). Sidebar: control bar › Copy Cloud Prompt / Open Cloud Agent.

## Surfaces and display

A **surface** is a terminal, VNC screen, or browser on This Mac or on a machine, with a stable id `<machine>/<kind>/<key>` (`local/terminal/<uuid>`, `vivid-newt/terminal/term_2f9c…`, `vivid-newt/display/display:1`, `vivid-newt/browser/port:3000`). Panes project surfaces; closing a pane never kills a machine's terminal.

### `cmux vm shell`

```bash
cmux vm shell <id> [--window <id|ref|index>] [--json]    # alias: cmux vm attach
```

A **plain terminal** on the machine, like an ssh session (not the cmux-tui client): one shared open path — `vm.cmux_remote_info` (availability and protocol check), `workspace.create` (or `workspace.cloud_vm_terminal_ready` for `--workspace`), `workspace.cloud_vm_bind`, then `surface.new_terminal {machine, open: true, name: "shell"}`, which creates a `bash -l` terminal in the machine's session and projects it as a pane; the placeholder pane is closed with `surface.close`. Desktop machines also get their screen in a split (`vm.desktop_open`). Text `OK workspace=<ws> transport=cmux-remote terminal=<term>` plus `Reattach: cmux vm open <m>/<ws>/<term>`; `--json` adds `terminal_id`, `remote_workspace_id`, `surface_id`. Every other cloud open (`vm new`, `vm fork`, `vm restore`, `vm base open`, the Machines panel, the sidebar cloud button) uses this path. Older deployments without a cmux-tui daemon fall back to the websocket/SSH transports (`vm.attach_info`, `vm.session_attach_info`, `vm.sessions`); a machine that answers `vm_attach_transport_unsupported` is cmux-tui only. Sidebar: machine row › Open Shell / click.

### `cmux vm open`

```bash
cmux vm open <target> [--workspace <id|ref|index>] [--focus <true|false>] [--print] [--json]
cmux vm open <id> <port> [--print] [--json]
```

One resolver, several target shapes (copy them from `cmux vm tree`):

| Target | Does | Socket |
|---|---|---|
| `<machine>` | the machine's shell — exactly `cmux vm shell <machine>` | see `vm shell` |
| `<machine>/<ws>` (`ws_…` id or workspace name) | that workspace's focused/first live terminal, or a new terminal there when it is empty (`OK terminal=… workspace=… surface=…`) | `surface.catalog`, `surface.project` / `surface.new_terminal {machine, remote_workspace_id, open}` |
| `<machine>/<ws>/<term_…>` | one terminal; reuses the pane already showing it (`reused=true`) | `surface.project {resource: "<m>/terminal/<term>", workspace_id?, focus?}` |
| `<machine>:desktop` | the noVNC screen as a browser pane — same as `cmux vm desktop` (desktop-image machines only; none ship today) | `vm.desktop_open` |
| `<machine>:port/<n>` and `<machine> <n>` | a private tokened URL for an HTTP port, as a browser pane — dormant today: no deployment implements open-port yet | `vm.port_open {id, port, workspace_id?}` |
| `… --print` | ports only: mint and print the URL, no pane | `vm.open_port {id, port}` → `{open_url, …}` |

`--workspace` targets a local workspace (default: the machine's open workspace, else where you are); `--focus` defaults to false so the pane opens beside you without stealing typing. Text `OK surface=… workspace=… terminal=… [reused=true]`; ports print `<id>:<port>` and the URL. Anything else is a usage error (exit 1). `cmux vm port` is an alias for the verb. Sidebar: row click / Open; Port row click.

### `cmux vm desktop`

```bash
cmux vm desktop <id> [--workspace <id|ref|index>] [--json]    # alias: cmux vm vnc
```

Socket `vm.desktop_open {id, workspace_id?, focus: false}`: the machine's noVNC desktop as a browser pane in the machine's open workspace, else the one you name, else where you are. Text `OK surface=… url=…`. Desktop-image machines only — **none ship today** (every current machine is shell-only, exit 1); the verb is kept for Freestyle desktop support. Sidebar: machine row › Open Desktop; Displays › Open Desktop.

### `cmux vm tui`

```bash
cmux vm tui <id> [--window <id|ref|index>]
```

The **full cmux-tui client** (its own workspaces, panes, tabs) in a pane — the only open that runs the client; everything else gives a plain terminal. Enrolls this Mac's device on first use (`vm.cmux_remote_info`, `vm.cmux_remote_approve`; the link socket comes from `vm.link_socket`), later attaches reconnect with the stored device key. Needs a local cmux-tui client (bundled beside the CLI, or `CMUX_TUI_CLIENT`, `~/.cmux/bin/cmux`, `cmux-tui` on PATH). Hidden helpers used only by this verb: `vm-tui-connect --config <file>` and `vm-tui-approve --id <vm> --invitation-id <id>`. Sidebar: machine row › Open Full cmux-tui Client.

### `cmux surface ls`

```bash
cmux surface ls [<machine>|local] [--refresh] [--json]   # aliases: cmux surface list, cmux surface tree, cmux surface catalog
```

Socket `surface.catalog` — exactly `cmux vm tree`, including This Mac.

### `cmux surface open`

```bash
cmux surface open <resource> [--workspace <id|ref|index>] [--pane <id|ref>] [--left|--right|--up|--down|--tab] [--new] [--focus <true|false>] [--json]
# alias: cmux surface project
```

Socket `surface.project {resource, workspace_id?, pane_id?, direction?, placement?, reuse?, focus?}` → `{surface_id, workspace_id, reused, resource}`: puts one surface in a pane through the single open path. Reuses the pane already showing the resource unless `--new`; `--pane` + a side splits that pane on that side, `--tab` adds a tab to it, otherwise the workspace's focused pane; a local terminal moves to the destination (it can be shown once). Text `OK surface=… workspace=… resource=… [reused=true]`. Sidebar: row click, Open in New Tab, Open in New Pane, drag onto a pane edge.

### `cmux surface new-terminal`

```bash
cmux surface new-terminal --machine <id|local> [--cwd <dir>] [--name <name>] [--remote-workspace <ws_…>] [--workspace <id|ref|index>] [--no-open] [--json] [-- <command...>]
# alias: cmux surface new
```

Socket `surface.new_terminal {machine, command?, cwd?, name?, remote_workspace_id?, open?, workspace_id?}` → `{resource, terminal_id, machine, remote_workspace_id, workspace_id?, surface_id?}`: a terminal on the machine through its provider (cloud terminals land in the machine's cmux-tui session; `--remote-workspace` picks which; `local` is a new shell on This Mac), opened as a pane unless `--no-open`. Sidebar: Terminals / Workspaces › New Terminal; workspace row › New Terminal Here.

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

Socket `vm.fork {id, name?, idempotency_key}`: clones a machine as a new tracked machine for a parallel experiment. `--detach` prints `OK <id>` with provider, image, and snapshot (`native fork` when the provider forks without one); otherwise opens the new machine's shell. Sidebar: machine row › Fork. (Not to be confused with `cmux fork`, a local agent-session verb — see In flight.)

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

See `vm open`: `cmux vm open <id> 3000` opens a private tokened HTTPS URL for an HTTP port as a browser pane (`vm.port_open`); `--print` only mints and prints it (`vm.open_port`, `--json` → `{open_url, …}`). **Dormant on every current deployment**: no provider driver implements open-port yet, so the backend answers `open-port is not supported by this deployment` — expose a service by running it on the machine and reading it from a terminal, or tunnel over `vm ssh` where the provider supports SSH. When it lights up: only share URLs minted this way; never guess provider URLs.

### `cmux vm ssh`

```bash
cmux vm ssh <id> [--window <id|ref|index>]
```

A cmux-managed SSH workspace for the machine (`vm.ssh_info`, then the same session path as `cmux ssh`). Provider-dependent: the default cmux Cloud provider attaches through the cmux-tui daemon and may mint no SSH endpoint — that is not an error; use `exec`, `agent`, or `open` instead.

### `cmux vm ssh-info`

```bash
cmux vm ssh-info <id> [--json]
```

Socket `vm.ssh_info`. Text: the `ssh <user>@<host> -p <port>` line plus host/port/username (password redacted); `--json` the raw payload. Explains itself when the machine exposes no SSH.

### `cmux vm ssh-attach`

Internal helper the SSH workspace pane runs; not for direct use.

## Account and plan

### `cmux auth`

```bash
cmux auth status [--json]              # {signed_in, …}; socket auth.status
cmux auth login                        # alias: cmux login — opens the sign-in popup (auth.begin_sign_in / auth.sign_in_url) and waits
cmux auth logout                       # alias: cmux logout — auth.sign_out
```

Every `cmux vm` verb requires a signed-in app.

### Plan meter and limits

`cmux vm ls` prints `N of M machines on the <plan> plan` — or `N machines on the <plan> plan, no limit`, since paid plans have no active-machine cap (`limits.maxActiveVms` is absent then). `cmux vm ls --json` carries `limits` (`maxActiveVms?`, `planId`, `freeAccessExpiresAt` when a free window applies). **Provisioning is gated to paid plans**: `vm new`, a first `vm base open`, `base reset`, `fork`, `restore`, and the router's provisioning path return the `vm_requires_pro` error (with the pricing link) on free or unknown plans. Report it — never delete machines to make room without asking. Sizes above the plan's ceiling are refused by the backend.

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
| `vm.rename` | `vm rename`, `vm new --name`, the router's `agent-pool` label |
| `vm.snapshot` | `vm snapshot`, `vm promote-template` |
| `vm.fork`, `vm.restore` | `vm fork`, `vm restore` |
| `vm.destroy` | `vm rm` |
| `vm.exec` | `vm exec`, `vm run`, `vm push`, `vm pull`, `vm wait --wake`, `vm tools`, `vm ports` |
| `vm.open_port`, `vm.port_open` | `vm open <id> <port> --print`, `vm open <id> <port>` / `<id>:port/<n>` |
| `vm.desktop_open` | `vm desktop`, `vm open <id>:desktop`, the split beside `vm shell` |
| `vm.cmux_remote_info`, `vm.cmux_remote_approve`, `vm.link_socket` | the shared open path (`vm shell` and friends), `vm tui` enrollment |
| `vm.ssh_info` | `vm ssh`, `vm ssh-info` |
| `vm.attach_info`, `vm.session_attach_info`, `vm.sessions` | legacy websocket/SSH attach transports the open path falls back to on deployments without a cmux-tui daemon (`cmux rpc` reaches them directly) |
| `vm.tree` | the pre-catalog tree; `vm tree` uses `surface.catalog` |
| `vm.terminal_open`, `vm.terminal_new` | older terminal verbs; `vm open <m>/<ws>/<term>` and `surface new-terminal` use `surface.project` / `surface.new_terminal` |
| `vm.workspace_new`, `vm.workspace_open`, `vm.workspace_rename`, `vm.workspace_close`, `vm.workspace_delete` | `vm workspace new|open|rename|close|rm` |
| `vm.terminal_close` | `vm terminal close` |
| `vm.terminal_write`, `vm.terminal_read`, `vm.terminal_wait` | `vm terminal send`, `vm terminal read`, `vm terminal wait` |
| `vm.cloud_prompt`, `vm.cloud_agent_open` | `vm prompt`, `vm prompt --open` |
| `surface.catalog`, `surface.project`, `surface.new_terminal` | `vm tree` / `surface ls`, `surface open` / `vm open`, `surface new-terminal` / `vm agent` |

## In flight

Verbs that exist only in an open PR. They are **not** on this branch; do not run them until the PR merges, at which point they move into the reference above.

- **#11324** adds a top-level `cmux fork [--surface <id|ref>] <kind> <checkpoint-id>` that forks a persisted local **agent session** (the `cmux restore` family). It is not a cloud verb: the machine clone, `vm fork <id>`, is already in the reference above.
- **#11347** tracks the live sidebar ↔ CLI parity loop (remaining gaps such as port rows in the tree and a socket method behind `vm route`). Check its state before assuming anything beyond this file. #11300 and #11301 were superseded by #11345, which is merged and reflected above (`vm terminal send|read|wait`, the single sidebar Close Workspace…).
