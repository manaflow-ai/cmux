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
  `stderr`; `new-machine` returns `machine_id` and `target` (or `pending: true` while
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

`cmux cloud list-machines` is read only: it answers the app's own Cloud machine list,
the one the sidebar's Cloud machines show, so an agent can check whether its machine
already exists before it runs `new-machine`. It takes no target. Run by a person from
the palette, it shows the Cloud sidebar instead.

```bash
cmux cloud list-machines --json
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
  but it cannot tell an unloaded list from an empty one; check `cloud list-machines`
  before you create a machine.

## Machine actions

```bash
cmux cloud list-machines                                    # the app's Cloud machines
cmux cloud new-machine                                      # answers machine_id (or pending)
cmux cloud new-workspace                                    # New Cloud Workspace
cmux cloud open-machine --target machine:vm-…
cmux cloud open-desktop --target machine:vm-…                # its desktop in a cmux browser tab, over the app's Cloud tunnel
cmux cloud open-desktop --target machine:vm-… --viewer native # the same desktop in the native remote view pane (development builds)
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

cmux Cloud pauses a machine after 30 idle minutes by default (no attached terminal, ssh or app,
no running agent turn, no command still running in a terminal, no forwarded port). The
machine's record says `pauseReason: "idle"`; opening a workspace or terminal on it, or ssh,
resumes it. `set-idle-pause` changes the timeout per machine.

A machine reaches the whole internet by default. `set-network-access` narrows it, live and with no
restart: `trusted` allows only GitHub, the package registries and the model providers the server
lists as presets, and `none` only the hosts cmux itself needs. The machine's own allowed ranges
and domains (set in the dashboard) are kept. An agent may only choose `none` (turn access off).

## Shell, commands and files

```bash
cmux cloud ssh --target machine:vm-…                           # opens an SSH terminal; surface_id
cmux cloud exec --target machine:vm-… --command '<cmd>'        # exit_code, stdout, stderr (25 s cap)
cmux cloud setup-github --target machine:vm-…                  # this Mac's git identity + gh device-flow sign-in
cmux cloud files-list --target machine:vm-… --path <dir>
cmux cloud file-read --target machine:vm-… --path <file>
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
cmux cloud tunnel-attach | tunnel-detach | tunnel-rotate-key                 # attach/detach: --path <network-id>; rotate-key: a public key (see cmux action describe); this Mac
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
cmux cloud start-session --target machine:<id> --agent claude              # start a session in that machine's acpmux
cmux cloud start-session --name dev --agent codex --cwd /home/cmux/work     # take machine "dev", or create it
```

`start-session` answers `machine_id`, `session_id` and `host` (the machine's
`registry:` host), plus the chat's `workspace_id` and `surface_id`. The chat's
tab opens in the machine's first workspace. Without `--cwd` the session starts
in that workspace's folder. An agent's run asks the person first with a card in
its own chat (Start, Not now), like an agent's `cloud move`. It waits up to 2
minutes for an answer and then refuses. Each refusal names the machine and gives
the command to run again.

## Account and diagnostics

```bash
cmux cloud sign-in
cmux cloud sign-out
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

| Old verb | Closest supported path |
| --- | --- |
| `vm ls` | `cmux cloud list-machines` |
| `vm route`, `vm tree`, `vm self`, `surface ls` | none on the Mac; `cmux self` and `cmux self peers` inside a machine |
| `vm new\|create` with `--size`, `--name`, `--desktop`, `--detach` | `cmux cloud new-machine` (returns `machine_id`) |
| `vm exec`, `vm run`, `vm dev`, `vm agent` | `cmux cloud exec --command …`, or open a terminal on the machine and use `cmux workspace current run -- <argv>` or `cmux agent <harness>` there |
| `vm terminal send\|read\|wait\|wait-exit\|output\|close` from the Mac | the same work with `cmux terminal <term_…> write\|screen read\|screen wait\|process wait\|output read\|close` inside the machine |
| `vm push\|upload` | `cmux cloud file-write --path <file> --contents …`, or `cmux cloud prepare-scp` then scp |
| `vm pull\|download` | `cmux cloud file-read --target machine:vm-… --path <file>` |
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
| `vpn up\|down` | `cmux cloud tunnel-attach\|tunnel-detach --path <network-id>` (no machine target) |
| `vpn status`, `ai-accounts`, `auth login\|logout` | none on the CLI; use the app |
| `capabilities`, `rpc <method>` | `cmux app capabilities`, `cmux action list` |
