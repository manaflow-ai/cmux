# Public CLI

`cmux` exposes `cmux.protocol/2` as a noun-first CLI. The public command
tree uses the same resource hierarchy and operation catalog as the handwritten
SDKs. The private protocol-v12 command set is available only through the
explicit `raw command` escape.

## Process modes

These modes start or connect a TUI process. They do not send a public resource
request:

```text
cmux [START OPTIONS]
cmux daemon start [START OPTIONS]
cmux attach [START OPTIONS] [--terminal <terminal-id>]
cmux relay [ROUTING OPTIONS]
cmux machine-agent [OPTIONS]
cmux wg hub --config <wg-quick file> --socket <unix socket>
cmux wg dial --hub <unix socket> <host> <port>
cmux link dial --host <install or host id> [--service daemon|ssh] [--socket <absolute path>]
cmux link ensure --state-dir <dir> [--install ID] [--port PORT] [--session-socket PATH] [--server-config PATH] [--handoff]
cmux link stop --state-dir <dir>
cmux link status --state-dir <dir>
cmux link archive --state-dir <dir>
cmux apps run <app> <op> [--args JSON] [--idempotency-key KEY]
cmux script run (FILE | -e CODE | -) [KEY=VALUE ...] [--args JSON] [--timeout MS]
cmux script repl [--timeout MS]
cmux script types
```

`relay` copies private protocol bytes between standard I/O and one session
socket. Machine connectors use it as a transport primitive. `wg hub` owns one
in-process WireGuard tunnel and serves SOCKS5 CONNECT on an owner-only Unix
socket so several `remote connect --wireguard-hub <socket>` clients share one
key; it prints one `hub-ready` JSON line when listening and removes the socket
on SIGTERM or SIGINT.

`cmux-tui __daemon-capabilities [--json]` (private, not in help) prints, with
no daemon running, the capabilities every daemon
of this build always advertises in `identify` (one per line, or
`{"capabilities": [...]}` with `--json`). Capabilities a daemon adds for what it
installs at startup (a cloud transport, a WebSocket listener, the search index)
are not listed. The cmux NEXT app bundle records the list, with acpmux's, in
`Contents/Resources/bin/daemon-capabilities.json`. `cmux capabilities` is the
classic verb that asks the running app (`system.capabilities`).

`link dial` bridges standard I/O to a service of a paired install or a Cloud
host (`host_…`) through this machine's running `cmux link` (the caller never
holds peer keys or link tokens). `--service` is `daemon` (the default; the
session's remote entry) or `ssh` (the host's sshd, Cloud hosts only, when
their policy allows it; paired installs serve only `daemon`). `--socket`
dials exactly that link socket instead of looking up the running link (for a
caller with a private `HOME`, or a tagged link); it must be an absolute path
to a socket (otherwise exit 64), and a path that does not exist means the
link is not running (exit 6). Standard error
always gets exactly one JSON line first: `{"ok":true,"path_state":"direct"|"tunnel",
"relay_available":false}` when connected, then the stream's bytes use
standard input and output until the stream ends; otherwise
`{"ok":false,"error_code":...,"path_state":"unreachable","relay_available":false}`.
Key order is not part of the contract. Exit codes:

| Exit | `error_code` | Meaning |
| --- | --- | --- |
| 0 | (none) | connected; the stream ended |
| 2 | `unknown_host` | no paired install or Cloud machine has this id |
| 3 | `not_authorized` | the caller may not reach this host or service |
| 4 | `host_paused` | the Cloud machine is paused; start it and dial again |
| 5 | `unreachable` | no path answered |
| 6 | `link_unavailable` | no `cmux link` runs, or it did not answer the dial |
| 64 | `bad_request` | bad arguments or a malformed dial |

`link ensure`, `link stop` and `link status` let an app run the per-user
link on demand, as it ensures the session daemon (`server ensure`). One link
runs per state directory: `serve` holds `<state dir>/link.lock` for its life
(taken before the UDP bind; a second `serve` exits with "a cmux link already
runs"), and `ensure` and `stop` hold `<state dir>/link.ensure.lock` while
they run. The registration is `link.json` in the state directory's parent;
the socket is `link-<12 hex>.sock` in the runtime directory, named from the
state directory, in a folder that must be this user's private folder (a real
folder, owned by this user, mode `0700`; also the `/tmp/cmux-tui-<uid>`
fallback). `stop`, `status` and `ensure` use a registration only when its
socket is their state directory's own socket (its `link-<12 hex>.sock`
name; the folder depends on the `TMPDIR` of the process that started the
link, so a CLI caller with another `TMPDIR` still finds the app's link, and
that folder must be this user's private folder), so a link of another state
folder, or a socket in an open or foreign folder, is never reported or
stopped.

`ensure` runs `init` first when the state directory has no config (then
`--install` is required; `--port 0` binds any free UDP port). When a link of
this state directory runs, `ensure` keeps it and prints
`{"status":"running","pid","socket","build","udp"}`. Otherwise it starts
`cmux link serve` in its own session (the link outlives the caller; output
goes to `<state dir>/link.log`), waits for its ready line on a private pipe,
and prints `{"status":"started","pid","socket","udp","build"}`. Without
`--handoff`, `ensure` refuses a different `--install` or `--port` than the
config has (`install_mismatch`, `port_mismatch`) and a running link that
serves another `--session-socket` or `server.json` (`config_mismatch`; the
`server.json` is compared by path and SHA-256), and keeps a running link of
another build.

`--handoff` is for the app that owns its link only (not in the help text).
With it, `ensure` restarts a running link of another build or of another
session socket or `server.json` (`"status":"restarted"`), and a different
`--install` or `--port` replaces the config: the running link stops, the old
install's WireGuard key and paired peers are kept under its name
(`private.key.<install>`, `peers.<install>.json`), and the new install gets
its own kept pair back, or a new key and no paired peers. Nothing is
deleted; a new install may be another signed-in person, so another install's
paired machines never carry over. Same-user access is the trust boundary of
the state directory.

`stop` signals only the pid that a fresh connection proved serves the
registered socket, waits for that connection to end (the link removes its
registration first) and then for the process to exit (an exit event), all
within 10 s; a link that does not end is an error (`stop_timeout`) and is
not reported stopped. It prints `{"ok":true,"stopped":true|false}`.
`archive` is for the app after a sign-out: with the link of this state
directory stopped (else `link_running`), it moves the install's WireGuard key
and paired peers into the install's archive (`private.key.<install>`,
`peers.<install>.json`) and removes the config, so no `ensure` without
`--install` starts the link as that install again. It prints
`{"ok":true,"archived":true|false,"install"?}`. An `ensure --install ID` on a
state directory with no config gets `ID`'s archived key and peers back.
`status` prints `{"running":false}` or the link's own `link.status` answer
with `"running":true` (`pid`, `socket`, `state_dir`, `install`, `port`,
`udp`, `build`, `session_socket`, `server_config: {path, sha256}`). The
link's local socket also answers `{"op":"link.status"}` with that line.

`apps run` runs one catalog op of an installed app through the session
daemon (`apps-run`; the CLI sends no `origin`, so gesture-required and
destructive ops answer `apps.gesture_required` or `apps.scope_missing`) and
prints its result data as JSON (exit 0; an op error exits 1 with its
`error_code` and `error_details`). Ctrl-C cancels the op: when the daemon
advertises `cancel-request-v1` in `identify`, the CLI sends
`{"cmd":"cancel-request","target":<the apps-run id>}` on the same connection,
waits at most 3 seconds for the run to answer `cmux.op.cancelled`, prints
"cancelled" and exits 130; otherwise it closes the connection (the daemon
then cancels the op) and prints "cancelled (no confirmation)", exit 130. A
second Ctrl-C exits 130 at once. A cancelled mutation may or may not have
taken effect; retry it with the same `--idempotency-key`.

`script run` runs JavaScript in a sandboxed script session of the session
daemon (`script-run`; plans/cmux-next/scripting-runtime.md) and prints the
value of its last expression statement: nothing for null, a string as is,
other values as JSON (compact JSON for every value with `--json`). `KEY=VALUE`
words and `--args JSON` become `cmux.args`. Console output arrives as
`script-log` events before the answer and is printed as it comes (info and
debug on stdout, warn and error on stderr; all on stderr with `--json`). A
script calls ops through the global `cmux` with the rights of the calling
connection, only ops the daemon owns, and has no network, filesystem or
process access. An error exits 1 with its `error_code` (an op's own code, or
`script.error`, `script.timeout`, `script.memory`, `script.cpu`,
`script.host`); a usage error or a TypeScript file exits 2; Ctrl-C sends
`cancel-request` for the running cell and exits 130. `script repl` keeps one
session across lines (one line per cell; a line that ends with `\`
continues), prints each value, and opens a new session when a cell ended its
session. `script types` prints the TypeScript declarations of the `cmux`
global. Connections bound to an agent, and remote connections, answer
`script.forbidden`.

`attach` opens the
complete session TUI. `attach --terminal <terminal-id>` resolves an exact ID
from `cmux terminal list` and renders only that terminal, without session
chrome or unrelated event traffic. Startup attach does not accept internal
runtime identifiers, abbreviated identifiers, names, or `current`.

Interactive and headless ownership are intentionally separate:

| Form | Contract |
| --- | --- |
| `cmux` or `cmux --session NAME` | Create or attach an interactive session. |
| `cmux daemon start --session NAME` | Start a headless owner. |
| `cmux attach --session NAME` | Attach an existing owner and fail if it is absent. |

The explicit split prevents two clients from silently creating competing
owners. A future attach-or-create shortcut needs a readiness and concurrency
contract before it can be added safely.

Migration from tmux or Zellij keeps the owner and client steps visible. Run the
owner in one terminal:

```bash
cmux daemon start --session agents
```

Then attach from another terminal:

```bash
cmux attach --session agents
```

Callers supervise the owner. A blind attach retry cannot distinguish a missing
owner from an owner still starting.

`daemon` is the local durable mux owner for exactly one named session
(`cmux-tui server …` is the same scope; on `cmux`, `server` is the machine
server, see `cmux help server`):

```text
cmux daemon start [START OPTIONS]
cmux daemon status [--session <name>] [--socket <path>]
cmux daemon stats [--session <name>] [--socket <path>] [--json]
cmux daemon stop [--session <name>] [--socket <path>] [--force] [--end-terminals]
  [--restore-wait-seconds <n>]
cmux daemon reload-config [--session <name>] [--socket <path>]
```

`daemon stats` prints the `server-stats` diagnostics (registry lock contention
with holder sites, journal writer batches and commit latency, connection
admission); see `docs/journal-operations.md` for how to read it.

`daemon start` is the canonical foreground spelling of `--headless`.
The shared `--session` and `--socket` routing options can also precede the
scope, for example `cmux --session agents daemon start --socket /path/to.sock`.
Detached startup is deferred until cmux has explicit supervisor ownership,
readiness, log, PID/state, crash, and stop contracts.
The owner binds its local socket before it restores its session (registry,
terminal host adoption). While it restores, the socket accepts connections
and holds them unanswered; when the restore ends, every held connection is
served by the normal protocol handler. `identify` then reports
`lifecycle_ready: false` until the owner finishes startup. `daemon stop` waits
for a restoring owner, through both phases, and then stops it: up to
`--restore-wait-seconds` (1 to 3600, default 120, the bound `server ensure`
gives a restore). While it waits it prints a progress line on stderr after the
first second and then every 5 s (with `--json`, one JSON object per line:
`progress: "restoring"`, `session`, `phase` (`restoring`: the owner holds the
connection unanswered; `starting`: it restored and reports
`lifecycle_ready: false`), `pid` when known, `waited_ms`, `message`). Past the
bound it fails with `server.stop_restoring` (exit 3, retryable; `details`:
`reason`, `phase`, `pid`, `waited_ms`, and `retry`, the stop command with a
longer wait, also named in the message) and leaves the owner running. Other
lifecycle commands fail fast while `lifecycle_ready` is `false` and can be
retried after the owner is ready. `server ensure` waits for a restoring
owner (up to 2 minutes, then `server.restore_timeout`) instead of starting
another.
`server ensure --ws-loopback [--ws-allow-origin <origin>[,<origin>...]]` (private app
contract, cx-hnmbt.2) starts an owner it spawns with `--ws 127.0.0.1:0` (and the
extra page origins, a comma-separated list: the app passes every first-party page origin
`cmux-page://cmux.<page>`, cx-hnmbt.10; one malformed member refuses the list): that owner mints its WebSocket credential and writes it
to `<socket>.websocket.json` (transports.md "App listener and page files"). A
running owner keeps the listener it was started with. The owner serves the page
bundle from `CMUX_TUI_PAGES_DIR`, else `<binary dir>/../share/cmux-tui/pages`.
`daemon stop` first reads the process identity, then sends the existing PID and
generation-fenced graceful shutdown operation. An absent server is success,
and stopping never deletes the durable topology. `session <name>|current stop`
is an alias for the same local operation. Opaque session IDs are not accepted
because local socket resolution uses a session name. `--all` is intentionally
deferred until a multi-session registry can identify every target without
introducing a second command registry.

`daemon status` fails when no server is listening. In contrast, `daemon stop`
is idempotent and reports `not_running` as success for an absent socket. JSON
errors use stable lifecycle codes and do not include raw transport, server, or
filesystem error text.

Authenticated network operations use `remote connect|ssh|forward|rpc`,
`remote enroll`, and `remote known-daemons`; they cannot accept local server
targeting. `remote connect --carrier` dials a `ws`/`wss` route with carrier
authentication and no enrollment; only a daemon started with
`--remote-ws-trusted-carrier` (or `CMUX_TUI_REMOTE_WS_TRUSTED_CARRIER=1`), whose
listener is reachable solely from a private network of authorized members,
accepts it. `remote stop` manages only a replaceable SSH sidecar. A listener
embedded by `daemon start` stops only through `daemon stop`, which also stops
the local owner and its workspaces. `daemon start` accepts the explicit
remote-listener flags when the owning process also serves authenticated
clients. Top-level remote commands and `remote-stop` remain compatibility
aliases for one release cycle.

## Public grammar

```text
cmux [GLOBAL OPTIONS] <resource> <action> [OPTIONS]
```

The public resource roots are:

```text
server   machine  session  client  workspace  screen  pane  tab
terminal browser  notification  agent  sidebar  git
pairing  projection  provider  raw
```

Run as `cmux`, the CLI spells the lifecycle root `daemon`, and `server` is
the machine server (`cmux help server`); `srv` is a shorthand on `cmux-tui`
only.

Structural resources may be addressed directly by opaque ID or through their
parents:

```text
cmux pane pane_… show
cmux workspace ws_… screen screen_… pane pane_… show
```

Both paths send `pane.get`. A direct opaque target ID may omit structural
ancestors. A name or `current` target requires its complete parent chain. Every
supplied ancestor is checked for containment before the operation runs.

Run `cmux <resource> --help` for its exact paths and flags. Parser tests
map every operational one-shot command and parameter in
[`resource-operations-v2.json`](resource-operations-v2.json) to a public path.
Sensitive renderer grants and connection-owned stream/viewer controls remain
SDK and raw-only.

## Shorthands

`cmux help shorthands` lists the supported spellings. Every shorthand lowers to
this same public resource grammar, with identical validation, idempotency keys,
output modes, and exit codes. It never sends private protocol commands.

| Short form | Canonical equivalent | Notes |
| --- | --- | --- |
| `ws`, `win` / `window`, `p`, `term`, `notif`, `srv` | `workspace`, `screen`, `pane`, `terminal`, `notification`, `server` | Resource positions, including nested paths |
| `ls`, `new`, `get`, `rm`, `select` after a resource | `list`, `create`, `show`, `close`, `focus` | Only where the resource supports that action |
| `pane split --right`, `p zoom`, `term read` | `pane current split --right`, `pane current zoom`, `terminal current read` | Omit `current` on instance actions |
| `list-sessions` / `ls` | `session list` | Describes the selected local session, not every socket on the computer |
| `list-windows` / `lsw` | `screen list` | `-t` / `--target` selects a workspace |
| `list-panes` / `lsp` | `pane list` | `-t` / `--target` selects a screen |
| `new-window` / `neww -n api` | `screen create --name api` | `-t` selects a workspace |
| `split-window` / `splitw -h` | `pane current split --right` | Default / `-v` splits down; `-c` sets cwd; `-t` selects a pane |
| `select-pane` / `selectp -L` | `pane current focus direction left` | One of `-L`, `-R`, `-U`, `-D`; `-t` selects a pane |
| `select-window` / `selectw -t api` | `screen api focus` | Exact screen selector |
| `rename-window` / `renamew -t api backend` | `screen api rename --name backend` | One new name |
| `capture-pane` / `capturep -t term_…` | `terminal term_… screen read` | `-p` is accepted; uses normal cmux output |
| `send-keys -t term_… C-c Enter` | `terminal term_… keys ctrl+c enter` | Named keys, including `C-`, `M-`, and `S-` modifiers |
| `send-keys -l -- 'hello 世界'` | `terminal current write --text 'hello 世界'` | Literal arguments concatenate without inserted spaces |

All `-t` values are cmux selectors. They do not interpret tmux numeric indexes,
`%pane`, `@window`, or `session:window.pane` targets. Capture/input also accept a
full `pane_…` ID, selecting its current tab's terminal. An omitted target uses
`current` in the selected session (the caller's own object inside cmux), not a
remembered client or shell.

Explicit selector paths take precedence over shorthand actions. Use `name:` for
names that collide with command words. Names, option values, key payloads, and
argv after `--` are never rewritten. Resource aliases and action aliases are
fixed spellings; partial prefixes are not automatically guessed.

This is a bounded convenience vocabulary, not tmux script compatibility. Unknown
flags, combined short flags, repeated targets, conflicting directions, arbitrary
mixed text/key payloads, tmux formats, buffers, shell-command split arguments,
and detached split flags are rejected. Use `send-keys -l` or `terminal write`
for text, and `--help` for help (`splitw -h` means horizontal).

There is no `new-session` alias because a cmux session owns a separate process.
Use `cmux --session NAME` for interactive create/attach or
`cmux daemon ensure --session NAME` to ensure a detached owner. `neww` creates a
screen inside the selected session's workspace.

## Selectors

An instance selector accepts:

- a typed opaque ID such as `ws_…`, `pane_…`, or `term_…`;
- `caller`, for a workspace, screen, pane, tab or terminal;
- `current`;
- an exact name.

`caller` is the object the command runs in: the caller's terminal
(`CMUX_TUI_TERMINAL_ID`) and the tab, pane, screen and workspace that hold it,
or for an agent session (`CMUX_AGENT_SESSION`) the place of its chat that the
app's `system.identify` reports. The CLI resolves it to ids before it sends the
request. It fails with `selector.not_found` when no caller is known and with
`selector.invalid` under `--socket`, `--session` or `--machine`, which name
another session or machine.

`current` is the caller's object as well when a caller is known and the
request routes to the caller's own session, so an agent never acts on the
workspace or pane the person is looking at. It is the session's focused object
when no caller is known or the caller cannot be found (a shell outside cmux, a
stale terminal id, an app that does not answer), under `--socket`, `--session`
or `--machine`, below an explicit parent that is not the caller's, above an
explicit id or name, and for a browser target. The daemon itself only knows
`current` as focused. `cmux agents` keeps `current` focused and does not take
`caller`. The MCP tools resolve `current` to the chat's own place themselves,
use `focused` for the object the person looks at, and do not take `caller`.

Names may be empty, contain Unicode or whitespace, and need not be unique.
`name:<value>` forces name interpretation and is required for names equal to
`current` or `caller`, names containing `_`, reserved command words, and ID-shaped names.
An ambiguous name returns `selector.ambiguous` with every candidate ID. It
never chooses one or changes state.

`--machine` and `--session` provide routing defaults. `--socket` selects an
exact local socket. Local socket precedence is explicit `--socket`, explicit
`--session`, inherited `CMUX_TUI_SOCKET` or `CMUX_MUX_SOCKET`, then the default
`main` session. Thus an explicit session never targets an inherited caller
socket from a different session.

One endpoint describes exactly one local mux session. `machine list`,
`machine get`, `session list`, `session get`, and `session open` expose that
local route. Cross-machine discovery and provider lifecycle require a later
broker protocol.

## Output

The output modes are mutually exclusive:

| Flag | Output |
| --- | --- |
| none | Concise human text |
| `--json` | One JSON result or structured error |
| `--jsonl` | One JSON value per result, stream item, or stream end |
| `--quiet` | No successful output |

Standard output carries successful data. Human-mode diagnostics use standard
error. JSON modes preserve the server's error code, message, details, and
retryable flag, including local CLI syntax errors.

| Exit | Meaning |
| --- | --- |
| `0` | Success or clean stream completion |
| `1` | Structured server error |
| `2` | Invalid CLI syntax or local parameter validation failure |
| `3` | Connection, framing, timeout, or protocol failure |

Requests are limited to 4 MiB. Responses and stream items are limited to
16 MiB.

## Mutations

Every mutation sends a cryptographically random 128-bit idempotency key unless
the caller supplies `--idempotency-key`. The CLI sends one request and never
retries a mutation. Mutations that support optimistic concurrency expose
`--expected-revision`.

An explicit idempotency key contains 1 to 128 UTF-8 bytes, at least one
Unicode scalar outside the Unicode `White_Space` property, and no Unicode
`Cc` control scalar. Non-control whitespace is preserved when the key also
contains a non-whitespace scalar.

Repeating a committed key with the same canonical request returns the recorded
result. Reusing it for another request returns `idempotency.conflict`.
`mutation.indeterminate` means the server crashed during an external effect and
will not repeat that key automatically.

Commands that create a workspace, screen, pane, terminal tab, or browser tab
accept `--correlation-key`. The key defaults to the idempotency key.
Resolve an interrupted creation with
`session <selector> creation <correlation-key> resolve` before retrying.

`workspace run` and `pane run` preserve exact argument arrays after `--`:

```bash
cmux workspace current run -- cargo test --workspace cmux-tui
cmux pane current run -- sh -lc 'printf "%s\n" ready'
```

The explicit shell form runs through the server platform's default shell:

```bash
cmux workspace current run shell 'cargo test && printf ready'
```

The client never reads or expands `$SHELL`.

`workspace create` starts the new workspace's first terminal the same way:
`--cwd <path>` sets its folder, and exact argv after `--` or `--shell <script>`
replaces the login shell. Apps need the `workspace:execute` scope for a command.

```bash
cmux workspace create --name build --cwd ~/src/app -- make watch
cmux workspace create --cwd ~/src/app --shell 'npm install && npm run dev'
```

`screen create`, `pane create`, `pane <selector> split` and `tab create
terminal` take the same exact argv after `--` or `--shell <script>`: the new
terminal runs it instead of a shell. Apps need `workspace:execute` for these
too. Text after `--` on a command that starts no terminal is a usage error.

```bash
cmux tab create terminal --pane current -- htop
cmux screen create --name logs -- tail -f /var/log/system.log
```

Both run forms accept `--on-exit <close|keep|shell>`. `close` (the default)
detaches every view when the process exits and leaves only the durable exit
receipt. `keep` retains the tab and the final screen next to that receipt
until the terminal is closed; after a daemon restart a kept-exited terminal
degrades to the normal detach. `shell` keeps the tab and the final screen,
then starts a new shell in it under the same terminal id (as Restart does);
that shell's own exit closes the tab.
The policies apply only to a process end, an exit status or signal that
the terminal host reported. When the host dies without one (it is killed,
or it dies while no daemon runs), every tab stays and shows the terminal
dead; only a close removes it. A process that dies of a signal while its
session shuts down (logout, reboot, `SIGTERM` to the daemon) counts as a
host death too.

## Resource paths

```text
machine list
machine <selector> show
machine <selector> session list
machine <selector> session <selector> open

session list
session <selector> open|show|snapshot|events|ping|shutdown
session <name>|current stop
session <selector> journal subscribe [--from tail|beginning]
  [--cursor-session <session-id> --sequence <sequence>]
  [--kinds <kind,...>] [--classes <class,...>] [--subjects <kind>:<id>,...]
  [--max-sensitivity public|metadata|sensitive]
  [--regex <pattern>] [--regex-field kind|subjects|payload|record|terminal_output] [--ignore-case]
session <selector> journal read [--from beginning]
  [--cursor-session <session-id> --sequence <sequence>] [FILTERS]
session <selector> journal producer list
session <selector> journal producer put --manifest-json <json> --idempotency-key <key>
session <selector> journal append --event-json <json> --idempotency-key <key>
session <selector> journal hook list
session <selector> journal hook put --manifest-json <json> --idempotency-key <key>
session <selector> journal checkpoint create --idempotency-key <key>
session <selector> journal checkpoint list
session <selector> journal restore preview [--checkpoint latest|<checkpoint-id>]
session <selector> journal segment list
session <selector> journal segment seal --through <sequence> --idempotency-key <key>
session <name> reset-state [--force --confirm-reset <token>] [--state <path>]
session <selector> creation <correlation-key> resolve
session <selector> config reload
session <selector> window title set|clear
session <selector> terminal defaults set

agent list [--needs-me] [--state <state>] [--terminal <id>] [--sort needs-me|recent|none] [--limit <n>] [--counts]
agent <agent_id|term_id> focus
agent message <agent> [--from <name>] [--thread <id>] [--] <text...|->
agent message --reply-to <message-id> [--from <name>] [--] <text...|->
agent message release <message-id> --recipient <agent> --approve|--decline
agent message unsend <message-id> [--recipient <agent>]
agent inbox [<agent>] [--state <state>] [--limit <n>] [--ack]
agent report --terminal <selector> --state <state> --source <source>
agent hook emit --source <provider> --event <native-event> [--terminal <id>]
agent hook install|uninstall|status [provider...]

client list
client <selector> show|detach
client <selector> metadata set
client <selector> sizing set|release
client <selector> cell pixels set

workspace list|create
workspace <selector> show|rename|move|focus|close|run
workspace <selector> layout apply
workspace [<selector>] open-url --url <url>
workspace <selector> screen ...

screen list|create
screen <selector> show|rename|focus|close
screen <selector> layout export|undo
screen <selector> column <split_id> update
screen <selector> pane ...

pane list|create
pane <selector> show|rename|focus|close|split|neighbor|swap|zoom|run
pane <selector> focus direction <left|right|up|down>
pane <selector> split ratio set
pane <selector> viewport width set
pane <selector> tab ...

tab list
tab create terminal|browser [--engine chromium|webkit]
tab <selector> show|rename|move|focus|close
tab <selector> terminal|browser ...

terminal list
terminal <selector> show|status|write|keys|mouse|copy|move|project|attach|close
terminal <term_id> keep on|off
terminal <selector> focus <in|out>
terminal <selector> screen read|wait
terminal <selector> state read
terminal <selector> history read|clear
terminal <selector> output read [--after <offset>] [--max-bytes <n>]
terminal <selector> process show|wait
terminal <selector> viewport scroll

browser open <url> | --url <url> [--engine chromium|webkit] [OPTIONS]
browser list
browser profile list
browser profile create --name <name> [--color <value>] [--icon <value>] [--index <n>]
browser profile move --profile <id-or-name> --index <n>
browser profile open <url> | --url <url> --profile <id-or-name> [--engine chromium|webkit] [--pane <selector>] [--title <value>] [--background true|false]
browser <selector> show|navigate|back|forward|reload|activate
browser <selector> key|text|attach|close
browser <selector> mouse|wheel --pointer-frame-seq <decimal>

notification list
notification create --title <text> --body <text> [--subtitle <text>] [--level <level>] [--terminal <term_id>]
notification clear [--terminal <term_id>]
notification ack --client <id> <notification-id>...
attention request --tab <tab_…> --reason <text>
attention clear --tab <tab_…>
git status [--path <path>|--workspace|--screen|--pane|--tab|--terminal <selector>]
git diff [TARGET] [--scope uncommitted|unstaged|staged|committed|branch] [--patch]
  [--max-patch-bytes <n>] [--max-files <n>] [--context-lines <n>] [<path>...]
git branches [TARGET] [--limit <n>]
git files [TARGET] [--limit <n>] <query>...
git list [TARGET] [--limit <n>]
git checkpoint create [TARGET] [--untracked eligible | <untracked-path>...] [--exclude <path,...>]
  [--reason manual|handoff|turn] [--max-bytes <n>] [--max-files <n>]
  [--expected-repository <id>] [--expected-worktree <id>]
git checkpoint get [TARGET] <checkpoint> | --key <idempotency-key>
git checkpoint list [TARGET] [--cursor <cursor>] [--limit <n>] [--candidates]
git checkpoint pin [TARGET] <checkpoint> --pin <pin-id> --reason <text>
git checkpoint unpin [TARGET] <checkpoint> --pin <pin-id>
git checkpoint diff [TARGET] <from> [<to>] [--only <path,...>] [--patch] [--max-patch-bytes <n>] [--max-files <n>] [--context-lines <n>]
git commit [TARGET] --message <text> [--all [--include-untracked]] [--amend] [--no-verify] [--expected-head <commit>] [<path>...]
git push [TARGET] [--remote <name>] [--branch <name>] [--set-upstream | --no-set-upstream] [--expected-head <commit>]
git worktree create [TARGET] [--name <name>] [--base <revision>]
git worktree apply [TARGET]
git worktree remove [TARGET] [--discard]
notify [--title <text>] [--subtitle <text>] [--body <text>] [--clear] [--surface <term_id|current>] [--workspace <ws_id|current>]
conversation list                                             (cmux-tui only)
conversation <conv_id> get [--tail <0..500>]
conversation <conv_id> history --before-seq <n> --limit <1..500>
conversation search <words>... [--limit <1..100>]
conversation <conv_id> send --text <text> | --parts-json <json> [--reply-to <msg_id> [--reply-part <n>]]
conversation <conv_id> events [--tail <0..500>] [--cursor-rev <rev>]
chief [-p <text>] [--timeout <seconds>] [--history <n>]   (also `cmux chief`)
chief engine [--harness <h>] [--model <m>] [--effort <e>] [--speed <s>] [--compactor-speed <s>] [--compactor-harness <h>] [--compactor-model <m>] | chief stop [<subagent>]
chief list | chief new --name <name> [<profile>] | chief edit <chief> [<profile>] [--clear-avatar] | chief delete <chief> | chief history <chief> [--limit <n>] | chief undo <chief> [--to-rev <n>]
chief usage [--chief <id>] [--since <24h|7d|30d|90d|1y|all>] [--until <d>] [--bucket hour|day|week|month] [--by chief|agent|model|harness|kind] [--top <n>] [--json]
agent list|message|inbox|report
agent plugin list|install|use|update|remove
pairing request list
pairing request <selector> respond <accept|reject>   (accept: only from the verified cmux app; other callers may reject)
projection <selector> show|put

sidebar view show|ensure|attach|input|resize|reload
sidebar plugin list|install|use|update|remove
sidebar section-scroll <section> fixed|flow   (sidebar.section.update {scroll})
sidebar section-max-rows <section> <1-50>|none   (sidebar.section.update {max_rows}; none grows without limit)

provider authority install

```

`notify` takes the flags of the macOS `cmux notify` so scripts and agent hooks
work unchanged inside a machine: `--title` (default `Notification`, at most
512 characters), `--subtitle` (at most 512), `--body` (at most 4096),
`--clear`, `--surface`, `--workspace`, `--json`, `--desktop true|false`
(`false`: the app shows no banner; the sidebar marker still shows), and
`--reply` (the banner takes a typed reply, which the app pastes into the
target terminal and submits with Return); `--window`
and `--id-format` are accepted and ignored. The target defaults to the caller's own terminal
(`CMUX_TUI_TERMINAL_ID`, which the daemon injects into every PTY); `--surface
current` says the same, `--surface <term_id>` names another terminal of this
session, `--workspace <ws_id>` posts a row with no terminal that belongs to
that workspace (`workspace_id`; the app's banner names it), and `--workspace
current` posts a session-level row. A machine can only address its own
session. `--clear` removes the retained rows for that target on the machine
(`notification.clear`), so every attached client drops them; `--clear
--workspace <ws_id>` removes that workspace's rows and those of its terminals. A reply goes only to the notification's target
terminal, while that notification is still unread, as text the user typed into its banner, over the same link the
app's terminal input uses. Every row is bounded because each
one is pushed to every attached client.

`notification ack --client <id> <notification-id>...` records that one client
install has read the listed notifications. `--client` is the durable client
id (1 to 128 printable ASCII bytes) that the client also reports through
`client-focus`. Read state is per client: every notification row carries
`read_by`, the sorted client ids that acknowledged it, and a second client
keeps its own unread state. The shared `unread` marker on the console tree is
unchanged by an acknowledgement. Ids the bounded ledger no longer retains are
returned under `unknown`, not rejected, so a late acknowledgement after
eviction is complete.

`terminal <selector> output read` returns a bounded plain-text window of the
terminal's journaled output stream: `{text, start_offset, next_offset,
complete}`. Offsets are `terminal.output` stream byte offsets; pass a previous
`next_offset` as `--after` to resume exactly, and omit it to read from the
earliest still-retained byte. `complete` is false when `--max-bytes` (default
262144, maximum 4194304) truncated the window. The command works on live
terminals and on exited ones under both exit policies; after exit, reads
before the durable exit snapshot's coverage answer with the snapshot's screen
projection (`start_offset` 0), so the read never needs unbounded record
retention. Escape sequences never appear in `text`, though a window that
starts mid-stream may carry escape-state artifacts at its leading edge.

Workspace creation starts with one terminal unless `--empty` is present.
`terminal <selector> project` requires destination `--workspace`, `--screen`,
`--pane`, and `--index` values and creates an unfocused tab placement. Tab,
pane, screen, and workspace closes detach PTY views; only `terminal close`
ends the session-owned process and removes all of its placements.
`tab`, `pane`, `screen` and `workspace <selector> close` with `--others`,
`--to-right`, `--to-left` or `--all` (panes: `--others` or `--all`) send one
`layout.bulk` close: the selected object's siblings in its pane, screen,
workspace or session close in one commit as one closed-history group, which
`closed reopen` restores whole. Pinned tabs, screens and workspaces stay unless
`--include-pinned`; the home workspace never closes; `--end-terminals` ends
the terminals the close leaves without a view.
`client <selector> metadata set` leaves an omitted field unchanged and clears
one passed as null. A non-null name or kind preserves its exact value, contains
at most 64 Unicode scalars, and contains no Unicode `Cc` control scalar.
`screen layout undo` requires `--confirm-close` when the recorded change would
close created panes. The read-only response includes an opaque confirmation
token, the current global revision, and pane IDs. A confirmed retry sends that
exact token and revision with a new idempotency key. The server revalidates the
token under the mutation lock, so tab or layout changes make it stale and
close nothing.

Terminal and sidebar attachments stream styled render snapshots and patches.
Browser attachments stream browser state and frames. Public attachments never
expose raw PTY bytes. Each frame includes a nullable `pointer_frame_seq`.
Pointer commands require the exact non-null token from the rendered frame.
Stream cancellation and terminal/browser viewer leases remain owned by the
long-lived attachment connection. SDK attachment objects manage those
connection controls; one-shot CLI paths do not advertise them. `raw operation`
remains available for transport testing.

`git status`, `git diff` and `git branches` are read-only git reads (`git.status`,
`git.diff`, `git.branches`) of the repository a path is in, or the working directory of the terminal a
selector names (a workspace, screen, pane or tab names its current terminal). Without
a target the CLI sends the current directory. The session host runs git with
no ambient `GIT_*` environment, no fsmonitor, external diff or textconv,
literal pathspecs, a deadline and bounded output. `git diff` lists each file's
status and line counts, adds patches only with `--patch` (each cut at
`--max-patch-bytes`, 262144 by default, and marked `patch_truncated`; each
hunk keeps `--context-lines` unchanged lines around it, 3 by default), lists at
most `--max-files` (500) files with the rest counted in `files_omitted`, and
counts at most 200 untracked files, reporting the rest as `untracked_skipped`.
The base branch (`git status`'s `base`, the `branch` scope's merge base) is the
one `git worktree create` recorded for the current branch
(`branch.<branch>.cmuxBase`) while it still names a commit, else origin's
default branch, else `origin/main`, `origin/master`, `main` or `master`. In a
linked worktree `git status` adds `worktree.main_root`, its main checkout.
`git branches` (`git.branches`, capability `git-branches-v1`) lists at most
`--limit` (200, up to 1000) branches: local ones, then remote-tracking ones,
each by newest tip commit. Each carries its full ref, commit and whether HEAD
is on it; a local branch also carries its upstream and its ahead and behind
counts. `suggested_bases` lists the bases a branch diff may compare with,
best first: the base branch above (the recorded base, then the default
branch), then the upstream of HEAD's branch when it is a different ref.
`truncated` says more branches exist.
`git files` (`git.files.search`) lists the files under the target folder whose
path holds the query's characters in order, case-insensitively and ignoring
spaces, best first: tracked files still in the working tree and untracked
files no ignore rule hides. It prints at most `--limit` (50, up to 200)
results relative to `search_root`, the folder searched; `root` is the
repository top level.
`git list` (`git.files.list`, shorthand `git ls`) lists the immediate children of the target folder
for a file explorer: each candidate `git files` would rank folds into its
first path component, a `directory` when paths sit below it or it is a
submodule, else a `file`. Directories come first, then names
case-insensitively. It prints at most `--limit` (2000, up to 5000) entries
and sets `truncated` when more exist.
A repository's filter drivers never run: every configured `filter.<driver>` is
blanked for the read. One reply carries at most 8 MiB of patches.

`conversation` maps one verb to each `conversation.*` operation of the local
conversation owner (resource-api-v2.md, "Conversations"); it is a
`cmux-tui` scope only, and the conversation operations are not MCP tools,
because MCP clients act as the local user. `send` takes its idempotency key
from `--idempotency-key` or a random one; the key is the message's
`client_msg_id`. `events` prints one item per line with `--jsonl`.

`chief` is the chat with the person's Chief over the same operations: it
selects the Chief conversation (the oldest one with participant `agent_mux`),
reads `conversation.events`, and sends with `conversation.send` as the
person, so Home and the CLI show the same messages live. With `-p <text>`, or
with text on stdin, it sends one message, prints the Chief's reply (live from
its `draft` items when stdout is a terminal, else only the posted messages,
or each as a JSON line with `--json`) and exits 0 when the turn that answers
the message ends; it gives up after `--timeout` seconds (default 1800,
`0` waits without a limit) and exits 124. After a stream gap it takes the
turn's state from the reopened stream's snapshot, so a lost typing item
never makes it wait for nothing. On a terminal it opens an inline
chat: finished messages go into the terminal's scrollback, the live reply and
the input stay at the bottom; Enter sends, Alt+Enter or Ctrl+J adds a line,
Ctrl+D quits, Ctrl+C stops the Chief's turn (`chief.stop`), `/model` and
`/effort` read or set the engine (`chief.engine.get|set`), `/help` lists the
commands. `chief engine` and `chief stop` make one such call without the
chat. `chief usage` reads this Mac's Chief usage ledgers (tokens by kind, cost, cache hit,
turn time over time; plans/cmux-next/chief-usage-analytics-DESIGN.md) through the bundled
`optchat-chief usage`; no daemon or brain needs to run. `chief list`, `chief new`, `chief edit` and `chief delete` make the
person's Chiefs with the Chief registry (`chief.profile.list`, `chief.profile.create`,
`chief.profile.update`, `chief.profile.delete`, `chief.profile.avatar.set`): `<chief>` is an id or one
Chief's display name; `<profile>` is `--name`, `--role`, `--personality`,
`--instructions` or `--instructions-file`, `--avatar <png|jpeg|gif|webp file>`,
`--tools`, `--harnesses`, `--self-edit` (comma lists) and `--harness`,
`--model`, `--effort` (the Chief's backend, written into its brain's engine
file), `--lock` / `--unlock` (the person's lock: no Chief may change it).
`chief adopt <agent> [<profile>]` (`chief.profile.adopt`)
makes an agent already in the person's conversations a Chief under its own
id; its conversations and history stay. `chief history <chief>`
(`chief.profile.history`) lists the kept revisions (rev, time, actor,
operation); `chief undo <chief> [--to-rev <n>]` (`chief.profile.undo`)
restores the one before the current rev, or rev `n`, as a new rev. Every
write (new, adopt, edit, delete, undo) is refused for an agent caller (`origin.forbidden`, reason
`agent_caller`). `--json` prints the record. It refuses a socket under
`~/.cmux/brains/` (a Chief brain's own session, where a client acts as the
Chief) and `--machine`. Exit codes: 0, 1 refused, 2 usage, 3 transport, 124
timeout.

`git checkpoint` (`git.checkpoint.create|get|list|pin|unpin`, capability
`git-checkpoints-v1`) stores an immutable checkpoint of a repository: the raw
index entries, the tracked worktree files, and the untracked files the caller
names (or `--untracked eligible` for every eligible one), each tree with its
modes and raw bytes, plus `metadata.json`, in one parentless commit published
as `refs/cmux/checkpoints/<worktree_id>/<checkpoint_id>`. Capture never changes
HEAD, the index, the worktree or any branch, and runs no hooks, filters or
fsmonitor. Untracked files are read without following links. Refusals are
`operation.failed` whose `details.reason` is the machine reason and whose
`extra.message` explains it: `unsupported_index` for skip-worktree,
assume-unchanged, intent-to-add, unmerged, split or sparse indexes;
`repository_changed` when the repository changes under the capture, an
`--expected-*` id no longer matches, or a key is reused for a target that now
resolves elsewhere; `budget_exceeded` past `--max-bytes` (128 MiB) or
`--max-files` (1000); and `no_state_directory`, `store_failed`,
`not_a_repository`, `no_working_directory` or `git_failed`. Ignored,
credential (`.env*`, `.netrc`, `.npmrc`, `.pypirc`, `.git-credentials`,
`credentials`, SSH private keys, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.jks`,
`*.keystore`), over-10 MB, nested-repository and unselected untracked files
are skipped and reported. `complete` is false when anything other than an
ignored or credential file was skipped. Checkpoints live in the session's
state directory, so an in-memory session refuses with `no_state_directory`.
Mutations are recorded in the session's resource mutation ledger: a create,
pin or unpin retried with the same key and arguments replays its first
result, and `get --key` finds a create of the same worktree after an
uncertain reply. A create that stopped after publishing its ref is finished
by its retry, and a create sweeps refs of its worktree that have no record.
`list --candidates` counts every ignored path in `ignored_total` and lists at
most 200 of them. Unpinned checkpoints expire after 7 days and at most 50 are
kept per repository; pins never expire, and pins beginning `handoff:` or
`restore:` are owned by cmux and cannot be removed with `unpin`.

`git commit` (`git.commit`, capability `git-commit-v1`) and `git push`
(`git.push`, capability `git-push-v1`) are the user's own actions: git runs in
the user's environment as in a terminal, so their config, identity, signing,
hooks, credential helper and SSH agent apply, and inherited `GIT_*` variables
of the daemon are dropped. Git never prompts (no terminal,
`GIT_TERMINAL_PROMPT=0`, no askpass) and is stopped after 120 s with
`timed_out`; a GUI prompt the user's own tools open (a signing pinentry, a
Keychain dialog) can still hold a run until that deadline. Both run only on
this machine: with another machine as the target the CLI refuses them. `commit` commits the named paths as they are in the working tree
(paths are relative to the current directory; they are staged first and stay staged when the commit is refused; other staged changes stay out of the commit), every tracked
change with `--all` (plus untracked files with `--include-untracked`), or the
index as it is; `--no-verify` skips pre-commit and commit-msg. It refuses with
`nothing_to_commit`, `head_moved` (HEAD is not `--expected-head`),
`merge_in_progress` (also a rebase, cherry-pick or revert), `hook_failed` (with
the hook's output, at most 16 KiB, in `extra.output`), `identity_missing`,
`index_locked`, `path_not_found` or `git_failed`. A retry with the same key
replays the first result, and a retry after a lost reply or a timeout
reports the commit the first attempt made: the attempt's id is in the commit's
reflog message (bounded attempt journal: 7 days, 256 entries). `push` pushes the branch's tip (the current branch unless
`--branch`) to the branch of the same name on a configured remote (default:
where `git push` would go, else `origin`), never forced, and makes it the
branch's upstream when the branch has none (or with `--set-upstream`). It
refuses with `no_remote`, `push_refspec_configured`, `mirror_remote`, `upstream_mismatch`, `detached_head`, `branch_not_found`, `head_moved`,
`rejected_non_fast_forward`, `rejected_by_remote` (with the remote's message),
`hook_failed`, `auth_failed`, `network_failed` or `git_failed`; pushing a
commit the remote has succeeds with `up_to_date`.

`git worktree create` (`git.worktree.create`, capability `git-worktree-v1`)
makes a chat's own worktree, in the user's environment like `commit`, and
only on this machine. The worktree is `~/.cmux/worktrees/<project>/<name>`
(`<project>` is the main checkout's folder name) on a new branch
`cmux/<name>` from `--base` (default: the current branch, else HEAD's
commit), and the base is recorded as `branch.cmux/<name>.cmuxBase` (a branch by
name, any other revision as its commit). The name
is `--name` as a slug (lowercase letters, digits and `-`, at most 48 before a suffix), else
`chat-` and six random hex digits; a name taken by a folder or a branch gets
the next free suffix (`-2` to `-99`). The user's checkout, its index and its
uncommitted changes are untouched. The result is the worktree's `root`,
`branch`, `base`, `base_commit` and, unless the repository is bare,
`main_root`. It refuses with `base_not_found`, `name_taken`, `path_exists`,
`no_home` or `git_failed`; a retry after a lost reply or a timeout finds the
worktree the first attempt made. A failing post-checkout hook does not undo
the worktree, so it is reported as made.

`git worktree apply` (`git.worktree.apply`, capability `git-worktree-apply-v1`),
run in a worktree whose branch `git worktree create` recorded a base for, brings
its work back to the main checkout, in the user's environment and only on this
machine. Everything the worktree changed since the merge base with that base
(its commits, its uncommitted edits and the new files it never added) lands in
the main checkout's files as uncommitted changes; submodules are left out. HEAD
and the index of both checkouts stay as they are, and the user's diff and apply
settings change nothing. The result is `main_root` and the `files` it changed.
It refuses, changing nothing, with `not_a_worktree`, `no_base`, `unmerged`
(mid-merge or mid-rebase), `no_merge_base`, `nothing_to_apply`,
`main_checkout_changed` (the main checkout has a change of its own, or a file git
does not track, at those paths, listed in `extra.files`), `does_not_apply` or
`git_failed`. A retry after a lost reply or a timeout finds the work applied
instead of applying it twice; one stopped while git wrote the files is refused
as `interrupted`, as the main checkout may hold part of it.

`git worktree remove` (`git.worktree.remove`, capability `git-worktree-remove-v1`),
run in a linked worktree, removes it with `git worktree remove` from the main
checkout, in the user's environment and only on this machine; the folder goes
with its ignored files. Its branch goes too, with its settings, when `git
worktree create` made it (`cmux/<name>` with a recorded base); any other branch
stays. Without `--discard` it refuses, changing nothing, with
`uncommitted_changes` (tracked or untracked files; `extra.files` lists up to 20,
`extra.count` all) or `unpushed_commits` (commits on no other branch and no
remote, on a detached HEAD or on the branch that goes; `extra.count`), checked
again right before the folder and the branch go: a branch that got new commits
meanwhile stays. With `--discard` that work is lost. The main checkout is
refused as `not_a_worktree`, and other worktrees are never touched. The result
is the removed `root`, `main_root`, the `branch` and whether it was deleted
(`branch_deleted`). A retry after a timeout finishes what the first attempt
started; once the folder is gone, a request naming it finds no repository.

## Local sidebar plugins

`sidebar plugin` commands read and write local plugin installation state. They
never open a protocol connection or send a plugin ID to a session. Optional
plugin names are slugs matching `[a-z0-9-_]+`.

## Agent list

`agent list` is one `agent.list` read; the CLI ranks, limits and counts its
rows, so the wire value is unchanged. `--state` and `--terminal` are the
read's own filters. `--needs-me` lists the blocked agents (`state: blocked`)
and is refused with any other `--state`.

`--sort needs-me`, the default, puts blocked agents first, then working, then
idle and done together, then unknown; `recent` ignores state; `none` keeps the
daemon's order. Within a group the most recently updated agent comes first,
and equal times fall back to the agent id. `--limit <n>` (at least 1) keeps
the first `n` ranked rows.

The command also reads `terminal.list` on the same connection, so each row
can show its terminal's title and folder. A refused or failed terminal read
leaves those out. AGE is the time since the agent's `updated_at_ms`, its
last report.

Human output starts with the counts by state over every listed agent, before
`--limit` (`2 blocked · 1 working · 3 idle · 0 done`, plus `unknown` when
there is one, and `(showing n of m)` when the limit hid rows), then one row per
agent: STATE, AGE, AGENT (`extra.agent`), TITLE, FOLDER (with `~` for the
home folder) and TERMINAL, with SESSION first under `--all-sessions`. With no
agents it prints `No agents.`

`--json` prints the ranked agents as a bare array, as it always has; only the
default order changed (it was the daemon's order). Each agent is the
`AgentSnapshot` plus `age_ms` and, when its terminal was listed, its `title`
and `cwd`. `--json --counts` prints `{"agents": [...], "counts": {...}}`
instead: `counts` has `blocked`, `working`, `idle`, `done`, `unknown` and
`total`, counted before `--limit`. `--jsonl` prints one agent per line with
or without `--counts`.

## Agent messages

`agent message` stores a message with `agent.message.send` and then delivers
it. `<agent>` is a terminal agent (`term_...`), an agent (`agent_...`, sent to
its terminal), or an acpmux session by name or id (`acp:` optional). The
daemon sets the sender from the caller's launch credential (the CLI sends it to
its own terminal's session): the agent's terminal or ACP session, else `cli`
(the person); `--from` adds an untrusted display name. A recipient in another
workspace, or one whose workspace is unknown, may be held for the person
(`agent.message.send` in resource-api-v2.md).
A lone `-` reads the body from standard input. `--reply-to` answers a message:
the reply goes to its sender and stays in its thread.

For an acpmux recipient the daemon's delivery pump prompts the session with
the message, using the message id as the acpmux prompt id, and marks the
receipt `delivered` (or `failed`, with acpmux's error); the command waits up
to 15 seconds for it and reports a delivery still `queued` (acpmux is down or
the session has not started; the pump retries). Neither starts the acpmux
daemon. For a Codex terminal agent whose thread the shared Codex app-server
daemon has loaded, it hands the agent's queued messages to Codex as one input
(`turn/start` when the thread is idle, `turn/steer` when a turn is running)
and marks them `delivered`. Any other terminal agent's message, or one Codex
cannot take now, stays `queued` until the agent's hooks take it. The command exits 1 when this message's own delivery failed; the message is
stored either way, and problems with older messages are reported on stderr.

`terminal <t> write` (and `send-keys -l`) into a terminal whose hooks report a
live agent (any state but `done`) still types the text, then prints on stderr
the `agent message` command that would send it as a message instead, with the
caller's `--machine`, `--session` and `--socket`, and `--` before the text so
text that starts with a dash stays the message. Text with a control character, a line
break or more than 200 characters shows as `'…'`. `--quiet` prints no hint,
`terminal <t> keys` gets none, and the lookup (`terminal.get`, `agent.list`)
gives up silently when a read waits 500 ms.

`agent message release` is the person's decision on a held delivery of
`<message-id>` to `--recipient`: `--approve` queues it, `--decline` declines
it (one `agent.message.release`). Only the verified cmux app may decide, so
from a terminal the command is refused with reason `release_needs_app`; the
app's Approve and Decline controls make the same request.

`agent message unsend` takes `<message-id>` back, from every recipient or
only `--recipient` (one `agent.message.unsend`), and prints each delivery's
outcome: `unsent` (it never reached the agent), `retracted` (acpmux told the
agent in its turn that it was withdrawn), `too_late` (its turn ended, or the
delivery path cannot take it back) or `failed` (acpmux refused, did not
answer or may still take it; try again). `failed` exits 1, after the result
is printed. Only the message's sender, from its own terminal or ACP session
(its launch credential), or the person in the cmux app may take it back;
there is no time limit. From a plain terminal the command is refused
with reason `unsend_needs_app`.

The daemon delivers messages to acpmux recipients (its delivery pump), and
retries while acpmux is down or the session has not started, so a message that
waited for acpmux, or for the person's approval, goes out without another
`agent message`. `agent message` waits for the pump's hand-over to each acpmux
recipient and reports one that failed or still waits.

`agent inbox` lists messages newest first for `<agent>`, or for the caller's
own address when it has one, else every message. `--state` is any delivery
state: held, queued, delivered, acknowledged, failed, unsent, retracted or
declined. `--ack` marks the listed queued, delivered or failed messages
acknowledged for that recipient.

## Local agent plugins

`agent plugin` commands read and write local installation state. They clone
and build the selected package, validate its `kind = "agent"` manifest, and
write the selected background command to `agents.plugin`. They do not open a
protocol connection or send a plugin ID to a session. Run `cmux daemon
reload-config` after changing the selection. The running plugin uses the
generic journal producer and append operations over the server socket. Use
`agent plugin use --builtin` to disable the selected userland plugin and return
to no agent detector.

`provider authority install` is a local Linux host-administration action. It
installs the credential for an already running provider-managed session and is
not a transported resource operation or cross-machine discovery API.

## Group actions

```text
cmux tab group list|create|remove ...
cmux tab group <group> update|add|move|split|column|new-workspace|ungroup|close|save|unsave ...
cmux screen group <group> update [--icon <icon>|--clear-icon] ...
cmux tab group saved list | saved <saved> delete|reopen --pane <id>
cmux workspace group list [--room <room>]
cmux workspace group create --name <name> [--color <c>] [--room <room>] [--index <n>] [--collapse]
cmux workspace group remove --workspace <ws>
cmux workspace group <group> update|delete|move|add ...
```

Tab groups and saved tab groups are private protocol-v12 commands
(`create-tab-group` and so on; see `spec/commands.md`). These actions build
exactly one such request and send it like `raw command`, so they work against
a headless daemon with no app running. Tab and pane arguments take the
private protocol's ids or public `tab_...` and `pane_...` ids.
`tab group <group> update --icon <icon>` and `screen group <group> update
--icon <icon>` set the group's icon (the same icon string as a workspace
group's) through `tab_group.update` and `screen_group.update`, and
`--clear-icon` removes it (`tab-group-icon-v1`, `screen-group-icon-v1`).

Workspace groups are personal state of the home session. `workspace group`
uses the `workspace_group.*` resource operations, and `add`/`remove` use
`workspace.place` with a workspace selector (`--workspace <ws>`). The shared
workspace group commands are no longer used by the CLI. `workspace group <group> update --top-index <n>`
puts a group right before the personal workspace at placement index `<n>`;
`--clear-top-index` puts it after every loose workspace
(`personal-mixed-order-v1`). `workspace group <group> update --icon <icon>`
sets the group's icon (one emoji, an SF Symbol name, or a stored
`image:sha256-<hex>` or `svg:sha256-<hex>` asset) and `--clear-icon`
removes it (`workspace-group-icon-v1`); `--pinned true|false` pins (saves)
or unpins it (`workspace-group-pin-v1`). `workspace list --order personal` lists the
workspaces in the sidebar order. With the sidebar document (`sidebar-doc-v1`),
`workspace list` without `--order` also lists the sidebar order (one order
with the sidebar). `--order session` (and, without the
document, no `--order`) lists the session's workspace order, the same order as
`topology.workspaces`: creation order unless a workspace was moved. The app's `snapshot.get` `windows[].workspaces` lists the order
each window shows.
Every `workspace list` row has `extra.pinned`: whether the sidebar shows the
workspace pinned (at the top level of Pinned, or pinned inside its group, in
the sidebar document; without the document, or for a workspace it does not
place, the daemon's `workspace-pin-v1` flag). `workspace <ws_…> pin` and
`unpin` run the app's Pin/Unpin Workspace action (`workspace pin-unpin
--target <ws_…> --pinned true|false`, MCP `app_workspace_pin_unpin` with
`pinned`), the same pin path as the sidebar; they need the app.

## Raw access

```text
cmux raw operation <dotted.name> [--params-json <object>]
  [--mutation --idempotency-key <value>] [--stream]

cmux raw command --request-json <private-protocol-object>
```

`raw operation` sends a generic `cmux.protocol/2` request. Known operations
still use their catalog class. `raw command` sends a private protocol-v12
object and has no compatibility promise.

The old action-first commands are removed. They fail locally with exit code 2
before opening a socket.
