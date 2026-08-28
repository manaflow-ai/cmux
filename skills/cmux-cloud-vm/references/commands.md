# cmux vm command reference

`cloud` is an alias for `vm` (`cmux cloud ls` == `cmux vm ls`). The global `--json` flag works on every subcommand and may appear before or after the subcommand. All of this requires the cmux app running and a signed-in account.

## Discovery: the cloud tree

```bash
cmux auth status                       # signed in?
cmux vm ls                             # NAME / LABEL / STATE / PROVIDER / IMAGE + plan meter (+ free-window countdown)
cmux vm ls --json                      # {vms: [{id, status, image, createdAt, freeAccessExpiresAt}], limits: {maxActiveVms, planId, freeAccessWindowDays, freeAccessExpiresAt}}
cmux vm tree                           # the surface catalog: This Mac (terminals by workspace, browsers), then every machine → workspaces/ → terminals, desktop, ports/
cmux vm tree <id> --refresh            # one machine (`local` for This Mac), re-synced first
cmux vm workspace new <id> [--name n]  # a new cmux-tui workspace on the machine (⌘N there), opened as a new local workspace
cmux vm workspace open <id> <ws-id>    # open a machine workspace here: one pane per terminal (same as clicking its sidebar row)
cmux vm workspace close <id> <ws-id>   # close that workspace and its terminals on the machine
cmux vm terminal close <id> <term-id>  # end one terminal on the machine (the sidebar's ×)
cmux vm tree --json                    # {machines: [{id, local, name, status, link_state, …}], resources: [{id, machine, kind, key, title, detail, lifecycle, agent, remote_workspace, port, url, open, open_surface_ids}], projections: […]}
cmux surface ls [--json]               # same catalog; `surface open <resource>` / `surface new-terminal --machine <m>` are the generic verbs
cmux vm status <id>                    # provider, status, image
cmux vm stats <id>                     # CPU/mem/disk now; sleeping machines stay asleep
cmux vm tools <id>                     # which tools are installed
cmux vm ports <id>                     # listening TCP ports inside the machine
cmux vm handoff <id>                   # short attach block to paste to a human or another agent
```

Tree line shapes:

```
vivid-newt  running  · 24 GB · 16 GB disk · link connected
  workspaces/
    main  ws_3c1…  *  (cmux vm open vivid-newt/ws_3c1…)
      ● term_2f9…  bun test  /root/work/app  [agent claude running]  (open: surface:4)
      ○ term_88a…  bash                                  ← exited
  desktop  (cmux vm open vivid-newt:desktop)
  ports/
    3000  http  (cmux vm open vivid-newt:port/3000)
```

## Surfaces: one open path for terminals, screens and browsers

```bash
cmux surface open vivid-newt/terminal/term_2f9c…                 # reuse the pane showing it, else open beside you
cmux surface open vivid-newt/terminal/term_2f9c… --new           # a second pane on the same terminal
cmux surface open vivid-newt/screen/display:1 --pane pane:3 --left   # the VNC screen, split left of pane 3
cmux surface open local/terminal/<uuid> --workspace workspace:2  # move a local terminal into another workspace
cmux surface new-terminal --machine vivid-newt --remote-workspace ws_3c1… --name "tests" -- bun test
cmux surface new-terminal --machine local --cwd ~/src/app        # a new local shell
```

Resource ids come from `surface ls --json`; `--pane` + a side uses the same drop rules as dragging a row from the sidebar.

## Routing: which machine, without running anything

```bash
cmux vm route                          # machine=<id> created=false / reason: reused, warm machine for this directory
cmux vm route --cwd ~/src/app --json   # {machine, created, reason, would_provision, directory}
cmux vm route --new --provision        # actually create the fresh pool machine the router would use
```

Policy (shared with `run` and `agent`): the machine bound to the directory → an awake idle pool machine → a sleeping pool machine → provision (only with `--provision` here) → at the plan cap, the least-loaded busy pool machine. Hand-made machines are never drafted.

## Lifecycle

```bash
cmux vm new --detach                   # new Desktop machine (screen + shell), headless create
cmux vm new --base --detach            # shell-only machine
cmux vm new --size 16g --detach        # memory preset: 2g|4g|8g|16g|24g|32g or raw MB (disk follows memory, 16 GB max)
cmux vm new --name "build box" --detach # display label; the id stays the address
cmux vm wait <id> [--timeout <sec>] [--wake]   # block until ready; --wake also wakes it
cmux vm rename <id> <label>            # display label; the id stays the address
cmux vm rename <id> --clear
cmux vm rm <id>                        # PERMANENT delete of machine + data (aliases: destroy, delete)
```

Without `--detach`, `vm new`, `vm fork`, and `vm restore` also open the machine as a workspace in the user's app.

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

## Opening things for the human (`vm open`)

```bash
cmux vm open <id>                      # the machine's shell (same as `vm shell`); desktop machines also get their screen beside it
cmux vm open <id>/<ws>                 # a cmux-tui workspace (ws_… id or name): its focused terminal, or a new shell if empty
cmux vm open <id>/<ws>/<term_…>        # one terminal — focuses the pane already showing it instead of opening a second
cmux vm open <id>:desktop              # the noVNC screen as a browser pane (also: `cmux vm desktop <id>`)
cmux vm open <id>:port/3000            # private tokened URL for an HTTP port, as a browser pane
cmux vm open <id> 3000                 # same as :port/3000
cmux vm open <id> 3000 --print         # URL only, no pane
cmux vm open … --workspace <ws> --focus true   # target a local workspace; focus the new pane (default: open beside you)
cmux vm shell <id>                     # a plain terminal on the machine (like ssh): one terminal in its cmux-tui session, attached in a pane
cmux vm tui <id>                       # the FULL cmux-tui client in a pane (its own workspaces/panes) — only when you want the client itself
```

`vm open` prints `OK surface=… workspace=… terminal=… [reused=true]`; `--json` prints the socket payload.

## Checkpoints, forks, templates

```bash
cmux vm snapshot <id> [--name <name>]  # checkpoint; prints the snapshot id (alias: checkpoint)
cmux vm fork <id> [--name <n>] [--detach]      # clone for a parallel experiment
cmux vm restore <snapshot-id> [--detach]       # snapshot -> new tracked machine
cmux vm promote-template <id>          # template-named snapshot for reuse
```

## SSH (provider-dependent)

```bash
cmux vm ssh <id>                       # cmux-managed SSH workspace (not on every provider)
cmux vm ssh-info <id>                  # raw SSH endpoint details when available
```

The default cmux Cloud provider attaches through the cmux-tui remote daemon, not SSH — when `ssh` errors, use `exec`, `agent`, or `open` instead.
