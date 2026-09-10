# cmux vm command reference

`cloud` is an alias for `vm` (`cmux cloud ls` == `cmux vm ls`). The global `--json` flag works on every subcommand and may appear before or after the subcommand. All of this requires the cmux app running and a signed-in account, except the guest `cmux self` and `cmux vm ls`, which run inside a machine on its edge-injected credential.

## Discovery: the cloud tree

```bash
cmux auth status                       # host: signed in; guest: daemon/edge route health
cmux vm ls                             # NAME / LABEL / STATE / PROVIDER / IMAGE + plan meter (+ free-window countdown)
cmux vm ls --json                      # {vms: [{id, status, image, createdAt, freeAccessExpiresAt, capabilities: {ports, …}}], limits: {maxActiveVms, planId, freeAccessWindowDays, freeAccessExpiresAt}}
cmux vpn status                        # this build's WireGuard tunnel to its private machine network (machines open no public port): up, down, or up for another enrollment (stale)
cmux vpn up                            # enroll this Mac and bring the tunnel up (sudo); a stale tunnel (rotated keys) is replaced. One tunnel per deployment (`cmux` for production, `cmux-staging`/`cmux-dev` for dev builds), so a dev build and the production app can both be up
cmux vpn down                          # take this build's tunnel down (sudo)
cmux self                              # INSIDE a machine: this machine's name, id, status, team (--json: {schema, machine, team, machines}); the guest `cmux vm ls` lists the team's machines with this one marked *
cmux vm tree                           # the surface catalog: This Mac (terminals by workspace, browsers), then every machine → Workspaces, Ports, VNC Displays, Terminals
cmux vm tree <id> --refresh            # one machine (`local` for This Mac), re-synced first (fleet + provider refresh)
cmux vm workspace new <id> [--name n] [--reuse] [--no-open]   # a new cmux-tui workspace on the machine (⌘N there); --reuse returns the existing workspace of that name instead of a second one
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
cmux vm terminal wait-exit <id> <term-id> [--timeout <s>]   # block until the process exits: exited code=<n> | exited signal=<s> | pending (exit 1)
cmux vm terminal output <id> <term-id> [--after <offset>] [--max-bytes <n>]   # the full output stream (scrollback), resumable with --after <next_offset>
cmux vm tree --json                    # {machines: [{id, local, name, status, link_state, …}], resources: [{id, machine, kind, key, title, detail, lifecycle, agent, remote_workspace, port, url, open, open_surface_ids}], projections: […]}
cmux surface ls [--json]               # same catalog; `surface open <resource>` / `surface new-terminal --machine <m>` are the generic verbs
cmux vm status <id>                    # provider, status, image
cmux vm stats <id>                     # CPU/mem/disk now; sleeping machines stay asleep
cmux vm tools <id>                     # which tools are installed
cmux vm ports <id>                     # listening TCP ports inside the machine
cmux vm handoff <id>                   # short attach block to paste to a human or another agent
cmux vm self <id> [<path>] [--json]    # the machine's reflection through your session: index (name, machine, owner, team, paths) or peers | integrations | owner | machine

# Guest-safe auth and CodeRouter commands (run inside a Cloud VM)
cmux auth status [--json]              # daemon, TLS edge, and VM-bound route status
cmux coderouter status [--json]        # same route/auth report
cmux coderouter usage                  # this machine's 30-day usage JSON
cmux coderouter models                 # models exposed through the edge
cmux coderouter agent <agent> ...      # run claude/codex/opencode/pi via CodeRouter
cmux agent <agent> ...                 # short alias for coderouter agent

# In-VM parity verbs (the Mac spellings, against this machine's own session; default target = $CMUX_TUI_TERMINAL_ID)
cmux tree [--json]                     # session snapshot (workspaces, screens, panes, tabs, terminals)
cmux new-workspace [--name <n>]        # workspace create
cmux new-split <left|right|up|down> [--pane <pane_id>]
cmux send [--terminal <id>] <text…> ; cmux send-key [--terminal <id>] <key…> ; cmux read-screen [--terminal <id>]
cmux terminal send <id> [text] [--keys k1,k2] | read <id> | wait <id> --pattern <re> [--timeout <s>] | close <id>
cmux layout export [--workspace <ws>] [--raw] | cmux layout apply [--workspace <ws>|--name <n>] [--cwd <dir>] [<file>|-]
cmux env set KEY=VALUE… [--from-file <.env>] [-] | ls [--show] [--json] | rm KEY… | path
cmux vm <verb> <peer> …                # any of the above on a peer machine (see "Machine-to-machine links")
cmux self [--json]                     # who am I: name, id, status, team, owner, plan (reflection; falls back to /api/vm/self on older servers)
cmux self peers|integrations|owner|machine [--json]   # reflection sub-resources (aliases: cmux whoami = cmux self, cmux reflect <path> = cmux self <path>)
cmux vm ls [--json]                    # the owner's machines, this one marked *, reachable/linked/connected
cmux terminal wait-exit <id> [--timeout <s>] [--json] | output <id> [--after <offset>] [--max-bytes <n>] [--json]
cmux agent <a> [--timeout <s>] <args…>   # runs here, in this terminal, until it exits (it IS the wait; exit code passes through; --timeout caps it). Peers: cmux vm agent <peer> --agent <a> --wait [--output] [--timeout <s>] -- <prompt>
cmux file receive <path> [--mode <octal>]   # the receiver `cmux vm push --secret` (Mac) and peer `cmux vm push` (machine) type into; not for hand use
cmux vm push <peer> <local-file> <remote-path> [--mode <octal>]   # one file to a peer, always over the link (secret-safe by construction)
```

Reflection (`https://coderouter.cmux.internal/api/vm/reflection`, also `https://reflection.cmux.internal/` on new machines) is how a machine identifies itself: the edge asserts the identity (the VM-bound route token), the guest holds no credential, and `/peers` lists the owner's other machines with their private routes so `cmux vm exec <peer>` works without any Mac step.

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
    (detached — no tab on the machine shows these)
      ● term_c04…  sleep 1000                   ← live, but in no workspace's layout
```

The sidebar shows the same tree in the same order: the machine's **Workspaces** group first (always its own row, with a ＋ that is `vm workspace new`; each workspace lists exactly its layout — a terminal whose tab closed is gone from the folder), then **Ports**, **VNC Displays** (one row per screen), and last, its own section, **Terminals** (every terminal resource the machine owns, detached ones greyed; always present, ＋ = `surface new-terminal`). Every sidebar verb has a CLI verb — see [sidebar-parity.md](sidebar-parity.md). `<machine>/<workspace>` addresses take the `ws_…` id, or the workspace name only when exactly one workspace has it (colliding names need the id); an empty workspace still resolves, and `vm open` starts a shell in it.

## Surfaces: one open path for terminals, screens and browsers

```bash
cmux surface open vivid-newt/terminal/term_2f9c…                 # reuse the pane showing it, else open beside you
cmux surface open vivid-newt/terminal/term_2f9c… --new           # a second pane on the same terminal
cmux surface open vivid-newt/display/display:1 --pane pane:3 --left   # the VNC screen, split left of pane 3
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

Policy (shared with `run` and `agent`): the machine bound to the directory → an awake idle pool machine → a sleeping pool machine → provision (only with `--provision` here) → at the plan cap, the least-loaded busy pool machine. Hand-made machines are never drafted. New cmux-created machines clear the provider idle timeout; a sleeping entry is an older/provider-managed or explicitly paused machine and is woken before an open operation.

## Lifecycle

```bash
cmux vm new --detach                   # new Desktop machine (screen + shell), headless create
cmux vm new --base --detach            # shell-only machine
cmux vm new --size 16g --detach        # memory preset: 2g|4g|8g|16g|24g|32g or raw MB (disk follows memory, 16 GB max)
cmux vm new --name "build box" --detach # display label; the id stays the address
cmux vm wait <id> [--timeout <sec>] [--wake]   # block until ready; --wake also wakes it
cmux vm rename <id> <label>            # display label; the id stays the address
cmux vm rename <id> --clear
cmux vm pause <id>                     # park it: compute stops, the home volume and the daemon state stay; `cmux vm ls` shows paused
cmux vm resume <id>                    # wake a paused machine (the same plan limits as a create apply)
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
cmux vm agent --agent claude --machine <id> --wait --output --timeout 1800 -- "fix the failing tests"   # block until the agent exits, then print everything it wrote; its exit code passes through (1 on timeout/signal)
cmux vm run --machine <id> --wait --output -- sh -c 'bun test'    # accepted for symmetry: run already blocks on exec and prints the output

cmux vm exec <id> -- <command...>      # one command; remote exit code passes through; 30 s default cap
cmux vm exec <id> --timeout 600 -- <command...>   # up to 900 s for a build or a test run
cmux vm exec <id> --json -- ls -la     # {stdout, stderr, exit_code}
# long work: a durable terminal, then wait for exit and read the whole output
t=$(cmux surface new-terminal --machine <id> --no-open --json -- sh -c 'cd work/app && bun run build' | jq -r .terminal_id)
cmux vm terminal wait-exit <id> "$t" --timeout 900     # exited code=0 | exited signal=… | pending (exit 1)
cmux vm terminal output <id> "$t"                      # everything it printed; --json adds next_offset to resume from
```

### `vm dev`: a folder to a running dev layout in one verb

```bash
cmux vm dev <id>                                   # check machine + optional sync + detect command/port + layout apply --name + open
cmux vm dev <id> ~/src/app --name app --port 3000  # explicit folder, workspace name, and port
cmux vm dev <id> --command "make serve" --no-open  # override command; stage without opening a local pane
cmux vm dev <id> --layout dev.json --no-sync       # custom layout; skip the push
cmux vm dev <id> --dry-run --json                  # print the plan and JSON; zero socket traffic
cmux vm dev <id> --sync                            # force the folder push; --no-sync forces a machine-side checkout
```

Detection: `--command` wins; otherwise `package.json` (lockfile selects bun, pnpm, yarn, or npm; `dev` then `start`), `Cargo.toml` → `cargo run`, `go.mod` → `go run .`, `Makefile` with `dev:` → `make dev`, `manage.py` → `python manage.py runserver 0.0.0.0:8000`, `uv.lock` → `uv sync`, `pyproject.toml` → `pip install -e .`, `requirements.txt` → `pip install -r requirements.txt`, or `index.html` → `python3 -m http.server 8000`; otherwise the layout is shell-only. The port comes from `--port`, then `-p`/`--port`/`PORT=` in the script, then a framework default (Next/Nuxt/react-scripts 3000; Vite/SvelteKit/Remix 5173; Astro 4321; Angular 4200; Expo 8081; Wrangler 8787). The built-in layout is a horizontal split (0.62): the dev command on the left, a focused shell on the right, and a browser tab on `http://localhost:<port>` when a port is known. `vm dev` creates or reuses the workspace through `vm layout apply --name`; if it already has live terminals, the layout is kept and a second dev server is not started. `--no-open` prints the workspace-open command. The `next:` lines are the `terminal output` / `terminal send` commands for the dev terminal.

## Files

```bash
cmux vm push <id> <local-path> [remote-path]        # file or directory (tarball), SHA-256 verified
cmux vm push <id> ./site --exclude dist             # extra excludes on top of defaults
cmux vm push <id> ./repo --no-default-excludes      # include .git, node_modules, ...
cmux vm pull <id> <remote-path> [local-path]        # file or directory back to local disk
cmux vm push --secret <id> ./id_ed25519 ~/.ssh/id_ed25519 [--mode 600]   # ONE file that must never transit exec: over the machine's link into `cmux file receive` (0600 by default, 256 KiB cap)
cmux vm push <id> ./site work/site --watch [--interval 1]              # keep copying on change (mtime/size scan, same excludes); remote-only files are preserved; Ctrl-C exits 0
```

Aliases: `upload` / `download`. Transfers ride the exec channel (no SSH), chunked base64, 256 MB cap; directories travel as tarballs and merge into the destination. Remote paths are relative to the work user's home (on the persistent volume). `--secret` is the exception: like `vm env set`, it goes Mac → app → the machine's cmux-tui link → a receiver terminal (`cmux file receive <path>`) that turns echo off before it reads, writes to a temp file next to the destination and moves it into place atomically. Nothing appears in a command line, the control plane, the provider API, a screen or scrollback. It refuses directories and `--exclude`; use it for keys, tokens, kubeconfigs, `.npmrc` and the like.

## Layouts (the shape of a machine workspace)

```bash
cmux vm layout export <id> [<ws-id|name>] [--raw] [--json]   # {"name","cwd","layout": Node}; default: the focused workspace; --raw: the daemon LayoutDocument (pane/tab ids, split ids)
cmux vm layout apply <id> <file>|- [--name <n>] [--cwd <dir>] [--open] [--json]   # build a NEW workspace from the document; --open shows it here with the same geometry
cmux vm layout apply <id> <file> --workspace <ws-id>          # into an already-empty workspace; a non-empty one is refused. `vm workspace new --no-open` creates a starter shell, so prefer `--name` or `vm dev`.
cmux vm layout apply <id> --from-saved <name> [--open]        # a Mac saved layout (`cmux layout save <name>`), applied in the cloud
```

Document (identical to `cmux new-workspace --layout`, `cmux layout get`, cmux.json workspaces):

```json
{"name": "app", "cwd": "work/app",
 "layout": {"direction": "horizontal", "split": 0.6, "children": [
   {"pane": {"surfaces": [{"type": "terminal", "name": "agent", "command": "claude"}]}},
   {"direction": "vertical", "split": 0.5, "children": [
     {"pane": {"surfaces": [{"type": "terminal", "name": "tests", "command": "bun test --watch"},
                            {"type": "terminal", "name": "logs", "cwd": "logs"}]}},
     {"pane": {"surfaces": [{"type": "browser", "url": "http://localhost:3000"}]}}]}]}}
```

- Wrappers accepted: the bare `layout` node, `{"name","cwd","env","layout"}`, or a saved layout `{"name","description","workspace":{…}}`.
- `horizontal` = side by side (first child left), `vertical` = stacked (first child top); `split` = the first child's share, 0.1–0.9 (default 0.5).
- Surface: `type` terminal|browser (`project` is Mac-only and skipped with a warning), `name` (tab name), `cwd` (relative to the document `cwd`, default: the work user's home), `env` (process environment of that shell), `command` (typed into the shell, then Enter — the shell survives it), `url` (browser), `focus`.
- Every terminal is a login shell (`bash -l`), so `vm env` values and the agents' PATH apply. Output: `OK workspace=ws_… name=… panes=N surfaces=M` or `--json` `{workspace_id, workspace_name, panes:[{pane_id, surfaces:[{type, terminal_id|browser_id, tab_id, name}]}], warnings}`.
- The same verb exists inside the machine (`cmux layout export|apply`) and toward linked peers (`cmux vm layout … <peer>`); the Mac form runs that implementation over the exec channel. A machine whose shim predates it says so (reconnect: `cmux vm tree <id> --refresh`).
- Exit codes: 0 built; 1 daemon refused (message names the op); 2 invalid document (message names the JSON path, e.g. `$.children[1]`) — nothing is created on a 2.

## Environment (project secrets and settings on a machine)

```bash
cmux vm env set <id> KEY=VALUE [KEY2=VALUE2 …]        # ~/.config/cmux/env (0600) in the work user's home on the persistent volume
cmux vm env set <id> --from-file .env                 # dotenv rules: blank and # lines skipped, optional `export `, matching quotes stripped
cmux vm env set <id> -                                # KEY=VALUE lines on stdin (preferred for scripts: nothing in argv)
cmux vm env ls <id> [--show] [--json]                 # names; --show adds values; --json {path, keys, values?}
cmux vm env rm <id> KEY [KEY2 …]
```

Values are sourced by every login/interactive shell on the machine (a one-line hook in `~/.profile` and `~/.bashrc`, installed on first `set`), so every terminal cmux starts (`vm open`, `surface new-terminal`, `vm agent`, layout panes), `vm exec`, and the in-VM `cmux agent …` see them. Keys must match `[A-Za-z_][A-Za-z0-9_]*`.

Transport: `vm env set` is the one `vm` verb that does **not** ride `vm.exec`. Values go to the app over the local socket and from there over the machine's cmux-tui link (Noise-authenticated end to end, on the private WireGuard network) into the machine's `cmux env receive`: a receiver terminal turns PTY echo off, prints `CMUX-ENV-READY`, reads base64 lines until `CMUX-ENV-END`, writes `~/.config/cmux/env` (0600), and answers `CMUX-ENV-OK keys=<n>`; the sender closes the terminal. So a value is never in a command line, never in the control plane or the provider API, never on a screen or in scrollback (the daemon does not journal input), and `ls` never prints one without `--show`. Inside a machine, `cmux vm env set <peer> …` uses the same handshake toward a linked peer. Snapshots, forks, and templates carry the file (it lives in the work user's home): `cmux vm env rm` what must not travel before `vm promote-template`. A machine whose shim predates the verb is reported as such (reconnect: `cmux vm tree <id> --refresh`).

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
cmux vm snapshot ls <id> [--json]      # this machine's snapshots, newest first: <id>\t<created>\t<name|->
cmux vm snapshot rm <id> <snapshot-id> # delete one (only a snapshot of THIS machine; a later `vm restore` of it answers not found)
cmux vm fork <id> [--name <n>] [--detach]      # clone for a parallel experiment
cmux vm restore <snapshot-id> [--detach]       # snapshot -> new tracked machine
cmux vm promote-template <id>          # template-named snapshot for reuse
```

## Machine-to-machine links

A machine discovers its peers itself: `cmux self peers` (or `cmux vm ls`) lists the
owner's other machines with their private daemon routes, and the daemon's
private-network listener is a trusted carrier (every member of the network is the
owner's Mac or machine), so `cmux vm exec <dst> -- <command>` connects with the route
alone — no Mac step, no enrollment, no credential in the guest. Peer route files written
by the earlier `vm link` broker keep working and take precedence. From inside a
machine the installed `cmux` shim can run `cmux vm exec <dst> -- <command>`,
`cmux vm tree <dst>`, `cmux vm terminal send|read|wait|close <dst> <term> …`,
`cmux vm send-key <dst> <term> <keys…>`, `cmux vm workspace new|rename|close|rm <dst> …`,
`cmux vm agent <dst> --agent <a> [--name <n>] [--cwd <dir>] -- <prompt>` (a durable
terminal on the peer running `cmux agent <a> …` with the peer's own CodeRouter config),
`cmux vm layout export|apply <dst> …`, `cmux vm env set|ls|rm <dst> …`, and
`cmux vm push <dst> <file> <remote-path>` (one file over the link, never through exec);
`cmux vm agent <dst> … --wait --output` blocks until the peer's agent exits and prints what
it wrote. No control-plane credential enters a machine.

## SSH (provider-dependent)

```bash
cmux vm ssh <id>                       # cmux-managed SSH workspace (not on every provider)
cmux vm ssh-info <id>                  # raw SSH endpoint details when available
```

The default cmux Cloud provider attaches through the cmux-tui remote daemon, not SSH — when `ssh` errors, use `exec`, `agent`, or `open` instead.

### Arrange the view from inside the machine

Use these commands in a daemon terminal (`cmux tree --json` supplies workspace,
screen, pane, split and tab IDs):

```bash
cmux workspace rename <ws> "Review ready"
cmux terminal rename current "Builder" --json
cmux tab rename <tab> "Test results" --json
cmux pane split <pane> right --ratio 0.6 --json
cmux tab move <tab> --workspace <ws> --screen <screen> --pane <destination-pane> --index 0 --json
cmux pane swap <pane> --other-workspace <ws> --other-screen <screen> --other-pane <other-pane> --json
cmux pane resize <pane> --split <split> --ratio 0.65 --json
cmux workspace move <ws> --index 0
cmux tab focus <tab>
cmux notify --title "Review ready" --body "The workspace has the app, logs, and test results."
```

`tab rename` labels one placement; `terminal rename` labels every current placement
of that terminal. Names, including spaces and an empty string, are passed as exact
arguments. A terminal with several views should be moved by its tab ID. Moving,
renaming, swapping, and changing split ratios preserve running terminal processes.
`pane resize` changes layout geometry; machine disk resizing remains unavailable.

Local commands use `cmux <resource> <verb> …`; a peer uses
`cmux vm <resource> <verb> <machine> …` (for example,
`cmux vm tab rename <machine> <tab> "Logs"`). Existing ID-first daemon syntax is
also supported. `cmux workspace help` lists the full topology grammar.

Arrange the daemon workspace before presenting it. The Mac's
`cmux vm workspace open <machine> <ws>` reads that layout when creating its local
view. These guest commands do not force focus or rearrange an already-open Mac
projection. `layout apply` is for new/empty workspaces; use the commands above to
change an occupied workspace without restarting its agents.
