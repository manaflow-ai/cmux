# cmux vm command reference

`cloud` is an alias for `vm` (`cmux cloud ls` == `cmux vm ls`). The global `--json` flag works on every subcommand and may appear before or after the subcommand. The control-plane commands below are host-side commands and require a signed-in account. A process inside a Cloud VM uses the guest commands in the next section and does not use host resource IDs.

## Guest scope: the commands a remote agent may use

These commands run inside a Cloud VM. The VM-local daemon checks the agent's
machine, session, and workspace lease before every read or mutation. The
normative, complete allowlist is in
[`docs/cloud-guest-command-policy.md`](../../../docs/cloud-guest-command-policy.md):

```bash
cmux workspace list --json
cmux workspace <workspace-id> show --json
cmux workspace <workspace-id> move --target <workspace-id>
cmux tab list --workspace <workspace-id> --json
cmux tab <tab-id> move --workspace <workspace-id> --before <other-tab-id>
cmux pane list --workspace <workspace-id> --json
cmux surface list --workspace <workspace-id> --json
cmux surface <surface-id> move --workspace <workspace-id> --before <other-surface-id>
cmux open ./README.md
cmux diff --repo .
cmux markdown open ./docs/plan.md
cmux browser open http://127.0.0.1:3000
cmux browser <browser-id> navigate http://127.0.0.1:3000
cmux browser <browser-id> snapshot --interactive
cmux browser <browser-id> click <selector-or-ref>
cmux browser <browser-id> fill <selector-or-ref> "query"
cmux peer list --json
```

The guest may address only VM-owned resources in its lease. It must not use
`local` IDs, host workspace or pane selectors, a host path, a host URL, a host
browser profile, clipboard, keychain, SSH agent, reverse relay, or
`CMUX_SOCKET_PATH`. The guest daemon rejects missing or ambiguous scope with
`scope.denied`; it never falls back to a host socket.

`open`, `diff`, and `markdown` accept VM-relative paths only. They return
bounded immutable snapshots or structured models and create VM-owned viewer
surfaces. `browser` runs in the VM and sends only pixels and explicit input to
an optional host projection. Its `file:` and network policy is VM-local,
declared same-project application services, or an exact peer grant. The host
gateway, Mac LAN, metadata, link-local, daemon ports, and undeclared private
addresses are denied. Redirects, subresources, WebSockets, WebRTC, DNS, and
downloads use the same managed policy. Public Internet access needs the
host-selected, expiring `internet` grant for this lease.

Host projection and transfer are separate host-user actions:

```bash
cmux cloud projection attach <remote-workspace> --workspace <local-workspace> [--follow-focus]
cmux cloud projection move <projection> --workspace <local-workspace>
cmux cloud network egress <session> set internet --ttl 1h --domain example.com
cmux vm pull <id> work/app/report.html ./report.html
```

The remote agent cannot request a host picker, supply a host path, or move a
host resource. A host projection is a display binding, not a shared filesystem
or a host WebView. VM tab, pane, and surface changes mirror only inside the
host-attached projection container for that remote workspace. A guest-created
workspace stays closed on the Mac until the host attaches it.
Host input stays bound to one projection and remote surface. Guest focus cannot
retarget it. Closing or replacing that surface drops later input.

## Discovery: the cloud tree

```bash
cmux auth status                       # signed in?
cmux vm ls                             # NAME / LABEL / STATE / KIND / IMAGE + plan meter (+ free-window countdown)
cmux vm ls --json                      # {vms: [{id, status, image, createdAt, freeAccessExpiresAt}], limits: {maxActiveVms, planId, freeAccessWindowDays, freeAccessExpiresAt}}
cmux vpn status                        # this build's WireGuard tunnel to its private machine network (machines open no public port): up, down, or up for another enrollment (stale)
cmux vpn up                            # enroll this Mac and bring the tunnel up (sudo); a stale tunnel (rotated keys) is replaced. One tunnel per deployment (`cmux` for production, `cmux-staging`/`cmux-dev` for dev builds), so a dev build and the production app can both be up
cmux vpn down                          # take this build's tunnel down (sudo)
cmux vm tree                           # host view of Cloud machines, workspaces, terminals, desktop, and ports
cmux vm tree <id> --refresh            # one Cloud machine, re-synced first
cmux vm workspace new <id> [--name n]  # host-created workspace on the machine, projected to a new local workspace
cmux vm workspace open <id> <ws-id>    # host projection of a machine workspace as a new local Cloud workspace
cmux vm workspace open <id> <ws-id> --here [--workspace <local>]      # host-user-only placement into a local workspace
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
cmux surface ls [--json]               # same catalog; `surface open <resource>` / `surface new-terminal --machine <m>` are the generic verbs
cmux vm status <id>                    # kind, status, image
cmux vm stats <id>                     # CPU/mem/disk now; sleeping machines stay asleep
cmux vm tools <id>                     # which tools are installed
cmux vm ports <id>                     # listening TCP ports inside the machine
cmux vm handoff <id>                   # short attach block to paste to a human or another agent
```

Tree line shapes:

```
vivid-newt  running  · 24 GB · 16 GB disk · link connected
  workspaces/                                  ← one machine, many workspaces: what you open and drag
    main  ws_3c1…  *  (cmux vm open vivid-newt/ws_3c1…)
      ● term_2f9…  bun test  ~/work/app  [agent claude running]  (open: surface:4)
      ○ term_88a…  bash                                  ← exited
    tests  ws_9ab…  (cmux vm open vivid-newt/ws_9ab…)   ← a second workspace on the same machine
  ports/
    3000  http  (cmux vm open vivid-newt:port/3000)
  VNC Displays/
    ● display:1  Desktop  noVNC  (cmux surface open vivid-newt/display/display:1)
  terminals/                                  ← every terminal resource the machine owns
    ● term_2f9…  bun test  ~/work/app             ← shown in a workspace
    (detached: no tab on the machine shows these)
      ● term_c04…  sleep 1000                   ← live, but in no workspace's layout
```

The sidebar shows the same tree in the same order: the machine's **Workspaces** group first (always its own row, with a ＋ that is `vm workspace new`; each workspace lists exactly its layout, so a terminal whose tab closed is gone from the folder), then **Ports**, **VNC Displays** (one row per screen), and last, its own section, **Terminals** (every terminal resource the machine owns, detached ones greyed; always present, ＋ = `surface new-terminal`). Every sidebar verb has a CLI verb. See [sidebar-parity.md](sidebar-parity.md). `<machine>/<workspace>` addresses take the `ws_…` id, or the workspace name only when exactly one workspace has it (colliding names need the id); an empty workspace still resolves, and `vm open` starts a shell in it.

## Surfaces: one host projection path for Cloud resources

```bash
cmux surface open vivid-newt/terminal/term_2f9c…                 # reuse the pane showing it, else open beside you
cmux surface open vivid-newt/terminal/term_2f9c… --new           # a second pane on the same terminal
cmux surface open vivid-newt/display/display:1 --pane pane:3 --left   # the VNC screen, split left of pane 3
cmux surface open local/terminal/<uuid> --workspace workspace:2  # host-user-only local operation
cmux surface new-terminal --machine vivid-newt --remote-workspace ws_3c1… --name "tests" -- bun test
cmux surface new-terminal --machine local --cwd ~/src/app        # host-user-only local shell
```

Resource ids come from the host `surface ls --json`; a guest receives only
VM-local IDs from its lease. `--pane` + a side uses the same drop rules as
dragging a row from the sidebar, and is host-user-only for Cloud resources.

## Routing: which machine, without running anything

```bash
cmux vm route                          # machine=<id> created=false / reason: reused, warm machine for this directory
cmux vm route --cwd ~/src/app --json   # {machine, created, reason, would_provision, directory}
cmux vm route --new --provision        # actually create the fresh pool machine the router would use
```

Policy (shared with `run` and `agent`): the machine bound to the directory → an awake idle pool machine → a sleeping pool machine → provision (only with `--provision` here) → at the plan cap, the least-loaded busy pool machine. Hand-made machines are never drafted. New cmux-created machines have no automatic idle timeout; a sleeping entry is an older or explicitly paused machine and is woken before an open operation.

## Lifecycle

```bash
cmux vm new --detach                   # new Desktop machine (screen + shell), headless create
cmux vm new --base --detach            # shell-only machine
cmux vm new --size 16g --detach        # memory preset: 2g|4g|8g|16g|24g|32g or raw MB (disk follows memory, 16 GB max)
cmux vm new --name "build box" --detach # display label; the id stays the address
cmux vm new --no-wait --detach         # return the cold-create operation without waiting
cmux vm wait <id> [--timeout <sec>] [--wake]   # block until ready; --wake also wakes it
cmux vm rename <id> <label>            # display label; the id stays the address
cmux vm rename <id> --clear
cmux vm rm <id>                        # PERMANENT delete of machine + data (aliases: destroy, delete)
```

Create claims a clean, single-claim warm machine when one matches the requested
kind, size, region, image family, and persistence profile. A warm slot has never
had a tenant and is destroyed after its one tenant releases it. The target is
p50 under 3 seconds and p95 under 10 seconds to daemon readiness. If no warm
slot exists, the Rust client follows the tracked operation by default.
`--no-wait` returns that operation immediately. `--detach` only controls
whether cmux opens a local pane after readiness.

## Domains and publication

Preserve the shipped domain verbs and flow:

```bash
cmux cloud domains list
cmux cloud domains zones
cmux cloud domains verify example.com
cmux cloud domains publish <vm> <port> --domain app.example.com --access team --team <team-id>
cmux cloud domains access app.example.com public
cmux cloud domains rm app.example.com
```

`verify` prints labelled DNS records on the first call. Change DNS, then run
the same command again. Generated `cmux.sh` names need no customer DNS proof.
Human output starts with the URL. Protected viewers see sign-in or denial;
`rm` remains one no-prompt command during migration. A domain is a publication,
not a port-open alias.

Without `--detach`, `vm new`, `vm fork`, and `vm restore` also open a host
projection of the machine in the user's app. These commands are not available
to an untrusted guest agent.

## Base (the pinned persistent slot)

```bash
cmux vm base open                      # open (or create) the one persistent Base machine
cmux vm base reset --reason "fresh"    # new Base generation; the old VM is retained
```

## Running work

```bash
# routed (no machine id): sticky per directory, then an idle pool machine, then provision
cmux vm run -- <command...>
cmux vm run --sync -- bun test                 # push cwd to work/<basename>, run there
cmux vm run --sync --pull work/app/dist -- sh -c 'cd work/app && bun run build'
cmux vm run --machine <id> -- <command...>     # pin; --new forces a fresh pool machine
cmux vm run --size 16g --new -- <command...>   # size applies to machines this run creates

# a coding agent as a detached terminal in the machine's cmux-tui session
cmux vm agent --agent claude --sync -- "run the tests and fix failures"        # bare prompt → claude -p …
cmux vm agent --agent codex --machine <id> -- exec "summarize work/app"        # flag/subcommand-led args pass through
cmux vm agent --agent opencode --no-open --json -- "add a README"              # headless; {terminal_id, workspace_id, reattach}
cmux vm agent --agent pi --name "pi: docs" --cwd ~/src/app --sync -- "write docs for src/"
# agents: claude | codex | opencode | pi (preinstalled under /root/.npm-global/bin)

cmux vm exec <id> -- <command...>      # one command; remote exit code passes through; ~30 s default cap
cmux vm exec <id> --json -- ls -la     # {stdout, stderr, exit_code}
cmux vm exec <id> -- sh -c 'nohup bun run build > /tmp/build.log 2>&1 &'   # long work: background, then poll
cmux vm exec <id> -- tail -n 20 /tmp/build.log
```

## Files

```bash
cmux vm push <id> <local-path> [remote-path]        # file or directory (tarball), SHA-256 verified
cmux vm push <id> ./site --exclude dist             # extra excludes on top of defaults
cmux vm push <id> ./repo --no-default-excludes      # include .git, node_modules, ...
cmux vm pull <id> <remote-path> [local-path]        # file or directory back to local disk
```

Aliases: `upload` / `download`. Transfers ride the exec channel (no SSH), chunked base64, 256 MB cap; directories travel as tarballs and merge into the destination. Remote paths are relative to `/root` (the persistent volume).

## Opening things for the human (`vm open`, host-side)

```bash
cmux vm open <id>                      # the machine's shell (same as `vm shell`); desktop machines also get their screen beside it
cmux vm open <id>/<ws>                 # a cmux-tui workspace (ws_… id or name): its focused terminal, or a new shell if empty
cmux vm open <id>/<ws>/<term_…>        # one terminal: focuses the pane already showing it instead of opening a second
cmux vm open <id>:desktop              # the noVNC screen as a browser pane (also: `cmux vm desktop <id>`)
cmux vm open <id>:port/3000            # private tokened URL for an HTTP port, as a browser pane
cmux vm open <id> 3000                 # same as :port/3000
cmux vm open <id> 3000 --print         # URL only, no pane
cmux vm open … --workspace <ws> --focus true   # target a local workspace; focus the new pane (default: open beside you)
cmux vm shell <id>                     # a plain terminal on the machine (like ssh): one terminal in its cmux-tui session, attached in a pane
cmux vm tui <id>                       # the FULL cmux-tui client in a pane (its own workspaces/panes): only when you want the client itself
```

`vm open` prints `OK surface=… workspace=… terminal=… [reused=true]`; `--json` prints the socket payload. The IDs in this receipt are host projection IDs and never cross into a Cloud VM.

## Checkpoints, forks, templates

```bash
cmux vm snapshot <id> [--name <name>]  # checkpoint; prints the snapshot id (alias: checkpoint)
cmux vm fork <id> [--name <n>] [--detach]      # clone for a parallel experiment
cmux vm restore <snapshot-id> [--detach]       # snapshot -> new tracked machine
cmux vm promote-template <id>          # template-named snapshot for reuse
```

## SSH (when available)

```bash
cmux vm ssh <id>                       # cmux-managed SSH workspace when the machine exposes it
cmux vm ssh-info <id>                  # raw SSH endpoint details when available
```

The default Cloud path attaches through the cmux-tui remote daemon, not SSH. If
`ssh` errors, use `exec`, `agent`, or `open` instead.
