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
cmux server start [START OPTIONS]
cmux attach [START OPTIONS] [--terminal <terminal-id>]
cmux relay [ROUTING OPTIONS]
cmux machine-agent [OPTIONS]
cmux wg hub --config <wg-quick file> --socket <unix socket>
```

`relay` copies private protocol bytes between standard I/O and one session
socket. Machine connectors use it as a transport primitive. `wg hub` owns one
in-process WireGuard tunnel and serves SOCKS5 CONNECT on an owner-only Unix
socket so several `remote connect --wireguard-hub <socket>` clients share one
key; it prints one `hub-ready` JSON line when listening and removes the socket
on SIGTERM or SIGINT. `attach` opens the
complete session TUI. `attach --terminal <terminal-id>` resolves an exact ID
from `cmux terminal list` and renders only that terminal, without session
chrome or unrelated event traffic. Startup attach does not accept internal
runtime identifiers, abbreviated identifiers, names, or `current`.

Interactive and headless ownership are intentionally separate:

| Form | Contract |
| --- | --- |
| `cmux` or `cmux --session NAME` | Create or attach an interactive session. |
| `cmux server start --session NAME` | Start a headless owner. |
| `cmux attach --session NAME` | Attach an existing owner and fail if it is absent. |

The explicit split prevents two clients from silently creating competing
owners. A future attach-or-create shortcut needs a readiness and concurrency
contract before it can be added safely.

Migration from tmux or Zellij keeps the owner and client steps visible. Run the
owner in one terminal:

```bash
cmux server start --session agents
```

Then attach from another terminal:

```bash
cmux attach --session agents
```

Callers supervise the owner. A blind attach retry cannot distinguish a missing
owner from an owner still starting.

`server` is the local durable mux owner for exactly one named session:

```text
cmux server start [START OPTIONS]
cmux server status [--session <name>] [--socket <path>]
cmux server stats [--session <name>] [--socket <path>] [--json]
cmux server stop [--session <name>] [--socket <path>] [--force]
cmux server reload-config [--session <name>] [--socket <path>]
```

`server stats` prints the `server-stats` diagnostics (registry lock contention
with holder sites, journal writer batches and commit latency, connection
admission); see `docs/journal-operations.md` for how to read it.

`server start` is the canonical foreground spelling of `--headless`.
The shared `--session` and `--socket` routing options can also precede the
scope, for example `cmux --session agents server start --socket /path/to.sock`.
Detached startup is deferred until cmux has explicit supervisor ownership,
readiness, log, PID/state, crash, and stop contracts.
The local socket accepts ordinary protocol clients while the owner finishes
startup. Its `identify` response reports `lifecycle_ready`; lifecycle commands
fail fast while this field is `false` and can be retried after the owner is ready.
`server stop` first reads the process identity, then sends the existing PID and
generation-fenced graceful shutdown operation. An absent server is success,
and stopping never deletes the durable topology. Once the owner has closed
its socket, stop removes the socket's `<socket>.spawn-lock` start lock (a
running owner does not hold it; stop does not wait for the process, which can
stay a zombie of its parent). Stop takes the lock first, so it never unlinks a
lock that a starting owner holds, and reports the removed paths as `removed`
(`[]` when there was none; an absent server also removes a stale lock).
Durable state (`writer.lock`, the registry) stays; `session <name> reset-state`
deletes it. A starter of an older cmux-tui version does not check the lock
file again after it locks it, so a stop that removes the file while such a
starter waits can let it start beside a newer one; this needs two versions
starting the same session at once. `session <name>|current stop` is an alias for the same local operation. Opaque session IDs are not accepted
because local socket resolution uses a session name. `--all` is intentionally
deferred until a multi-session registry can identify every target without
introducing a second command registry.

`server status` fails when no server is listening. In contrast, `server stop`
is idempotent and reports `not_running` as success for an absent socket. JSON
errors use stable lifecycle codes and do not include raw transport, server, or
filesystem error text.

Authenticated network operations use `remote connect|ssh|forward|rpc`,
`remote enroll`, and `remote known-daemons`; they cannot accept local server
targeting. `remote doctor HOST` is a read-only reachability probe that needs no
server or enrollment. `remote trust` edits this machine's per-peer trust
records in the remote state root and needs no server. `remote connect --carrier` dials a `ws`/`wss` route with carrier
authentication and no enrollment; only a daemon started with
`--remote-ws-trusted-carrier` (or `CMUX_TUI_REMOTE_WS_TRUSTED_CARRIER=1`), whose
listener is reachable solely from a private network of authorized members,
accepts it. `remote stop` manages only a replaceable SSH sidecar. A listener
embedded by `server start` stops only through `server stop`, which also stops
the local owner and its workspaces. `server start` accepts the explicit
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
terminal browser  notification  agent  attention  sidebar
pairing  projection  provider  raw
```

Structural resources may be addressed directly by opaque ID or through their
parents:

```text
cmux pane pane_… show
cmux workspace ws_… screen screen_… pane pane_… show
```

Both paths send `pane.get`. A direct opaque target ID may omit structural
ancestors. A name or `current` target requires its complete parent chain. Every
supplied ancestor is checked for containment before the operation runs. A tab
name under `current` workspace, screen and pane selectors (what `cmux tab NAME`
sends) that the current pane does not have is looked up in the current screen,
then the current workspace, then the session; the first level with a match
wins, and two or more tabs there are `selector.ambiguous`. A tab name under an
explicit pane stays in that pane.

Run `cmux <resource> --help` for its exact paths, and add `--help` to an action
(`cmux tab <selector> move --help`, or `cmux help tab <selector> move`) for
every flag it takes, its value, and whether it is required. One catalog,
`crates/cmux-tui/src/cli/command/actions.rs`, lists each action's flags: the
parser rejects a flag the action does not list before reading any value, reports
all missing required flags in one error, and debug builds fail when the parser
reads a flag the catalog does not list. Help, usage errors, and `--version` name
the program as it was invoked (`argv[0]`): `cmux` through the npm launcher,
`cmux-tui` where the binary is installed under that name.

Parser tests
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
`current` in the selected session, not a remembered client or shell.

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
`cmux server ensure --session NAME` to ensure a detached owner. `neww` creates a
screen inside the selected session's workspace.

## Selectors

An instance selector accepts:

- a typed opaque ID such as `ws_…`, `pane_…`, or `term_…`;
- `current`;
- an exact name.

Names may be empty, contain Unicode or whitespace, and need not be unique.
`name:<value>` forces name interpretation and is required for names equal to
`current`, names containing `_`, reserved command words, and ID-shaped names.
An ambiguous name returns `selector.ambiguous` with every candidate ID. It
never chooses one or changes state.

An agent name (`cmux agent start NAME`) and any tab name that is unique in the
session select that tab's terminal, tab or pane wherever such a selector goes:
the word after `terminal`, `tab` or `pane`, and the `--terminal` and `--pane`
values of those scopes and of `agent` and `notification`. Before it parses the
command, the CLI reads one `session.snapshot` and puts the id in place of the
name: a tab with that name whose terminal runs (with an agent or not), else one
whose terminal exited (so `terminal NAME resume` finds it). Two tabs at the
first step that has any return `selector.ambiguous` with their tab ids, also an
agent tab and a shell tab with one name. A name only fills a gap: when a name
matches, the CLI first asks the daemon to resolve the word with the rules above
(the current scope, names under a parent), and a word that resolves stays as it
is, so a selector that worked before selects the same object. The flag values
of `agent` and `notification` take `term_` ids only, so a name there always
becomes its id. A word that matches no tab, an id, `current`, command words and
the parser's subcommand words (such as `create` in `tab create terminal`) are
left to those rules. No agent can take a literal word of an action path
(`write`, `keys`, `create`, ...) as its name. A terminal title under the
current tab, and a pane's own name under the current screen, win over a tab
name, because the daemon resolves them first. The scan reads flag values as the
parser does: every flag that is not a boolean flag takes the next word.

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

Both run forms accept `--on-exit <close|keep>`. `close` (the default)
detaches every view when the process exits and leaves only the durable exit
receipt. `keep` retains the tab and the final screen next to that receipt
until the terminal is closed; after a daemon restart a kept-exited terminal
degrades to the normal detach.

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

agent list [--state working|blocked|done|idle|unknown|ended] [--terminal <id>]
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
workspace <selector> screen ...

screen list|create [--workspace <selector>] [--focus]
screen <selector> show|rename|focus|close
screen <selector> layout export|undo
screen <selector> pane ...

pane list|create
pane <selector> show|rename|focus|close|split|neighbor|swap|zoom|run
pane <selector> move --to-pane <selector> [--split <dir>]|--to-tab <selector>|--to-workspace <selector>|--new-screen [--name <value>] [--focus]
pane <selector> focus direction <left|right|up|down>
pane <selector> split ratio set
pane <selector> viewport width set
pane <selector> tab ...

tab list
tab create terminal|browser
tab <selector> show|rename|move|focus|close
tab <selector> terminal|browser ...

terminal list
terminal <selector> show|write|keys|mouse|move|project|attach|close
terminal <selector> focus <in|out>
terminal <selector> screen read [--unwrap] [--lines <n>] [--details]
terminal <selector> screen wait --pattern <regex> [--new] [--timeout-ms <n>]
terminal <selector> copy [--mode screen|selection|scrollback] [--unwrap]
terminal <selector> state read
terminal <selector> history read|clear
terminal <selector> output read [--after <offset>] [--max-bytes <n>]
terminal <selector> process show|wait
terminal <selector> wait --until ready [--timeout <duration>]
terminal <selector> resume [OPTIONS] [-- ARGS...]
terminal <selector> viewport scroll

browser list
browser <selector> show|navigate|back|forward|reload|activate
browser <selector> key|text|attach|close
browser <selector> mouse|wheel --pointer-frame-seq <decimal>

notification list
notification create --title <text> --body <text> [--subtitle <text>] [--level <level>] [--terminal <term_id>]
notification clear [--terminal <term_id>]
notification ack --client <id> <notification-id>...
notify [--title <text>] [--subtitle <text>] [--body <text>] [--clear] [--surface <term_id|current>] [--workspace <ws_id|current>]
attention next [--after <tab_…>] [--focus]
attention list
agent list|report
agent start|resume <name> [OPTIONS] [-- ARGS...]
agent plugin list|install|use|update|remove
pairing request list
pairing request <selector> respond <accept|reject>
projection <selector> show|put

sidebar view show|ensure|attach|input|resize|reload
sidebar plugin list|install|use|update|remove

provider authority install

```

In the human output `screen read` prints the screen's text as it shows (no
trailing blank rows); `--details` prints every field of the record (`text`,
`cols`, `rows`, ...), and `--json` prints the record as before.

Terminal text reads break lines where the terminal wrapped them unless asked
not to (`terminal-read-unwrap-v1`). `screen read --unwrap` (`unwrap`) joins
rows the terminal soft-wrapped (the program printed past the right edge) into
the lines the program printed; rows it ended with a newline stay separate.
`--lines <n>` (`lines`, 1 to 10000) reads the last n lines of scrollback and
screen together, oldest first, without the blank rows below the last printed
line: logical lines with `--unwrap`, rows without it; the cursor fields still
describe the screen. `copy --unwrap` joins soft wraps for `screen` and
`scrollback`. `screen wait --new` (`new`, `terminal-wait-new-v1`) matches only
text printed below the line the cursor is on when the wait starts, soft wraps
joined, and `text` is then that new text: the echo of a command typed on that
line and older output never match. Output printed before the wait starts is
not new, so start the wait before the command prints.

A `--pattern` regex (`screen wait`, and the raw `wait-for` command) is
multi-line: `^` and `$` match at the start and end of each line, so
`'^READY$'` matches a line that is only `READY`. Start the pattern with
`(?-m)` to anchor at the start and end of the whole text.

`screen create` does not move the focus: the workspace's focused screen
stays, unless `--focus` is given (`screen.create.focus`, default false for a
caller; the TUI's own new screen still shows it) or the workspace had no
screen. It takes `--workspace <selector>` to choose the workspace. A
`screen.create` in a session with no workspace makes one, which takes the
focus as before (main's `workspace.create` has no focus option).

`pane <p> move` moves a whole pane: every tab in it, in order, with one
`tab.move` each (the daemon has no pane move), and the emptied pane closes.
`--to-pane <q>` appends the tabs to pane q; with `--split right|down|left|up`
they go into a new pane split off q. `--to-tab <t>` puts them after tab t in
its pane. `--to-workspace <w>` and `--new-screen` (alias `--new-tab`, the
pane's own workspace) put them into a new screen there, named `--name`. A new
pane's shell ends once the tabs are in (`terminal <t> close`, which takes its
tab; a tab close alone left the shell running with no tab), and the new pane
takes the moved pane's name. `tab.move` focuses what it moved, so afterwards
the command focuses the pane that had the focus before (`--focus`: the
destination pane); when the moved pane had the focus, the focus stays with its
tabs. A destination in the pane itself is a usage error. The result is `{pane,
moved_tabs, destination: {workspace, screen, pane, index}, created,
focused_pane}`, `created` being `{screen, pane}`, `{pane}` or null. The
command resolves every selector (ids, unique id prefixes, `name:` and exact
names, `focused`, `current`, `caller`) against one `session.snapshot` and
sends ids only. Each step is its own request, its idempotency key derived from
the command's (`--idempotency-key`, else a random one). A failed step names
itself and what already moved in `details.step` and `details.made`; running
the command again does not resume it (`details.retry`), so move the remaining
tabs with `tab move`.

`agent list` is one `agent.list` read and one `notification.list` read; the
daemon's rows are unchanged except that the CLI adds `status`, the word the
TUI sidebar shows: `blocked`, `done` (idle with an unread notification on its
terminal), `working`, `idle` or `unknown`, and `null` for an agent whose
session ended. The daemon's `state` field (`working`, `blocked`, `idle`,
`done` = ended, `unknown`) stays as it was. `--state` takes the status words
and `ended` and asks the daemon for its state: `done` and `idle` ask for
`idle` (the CLI then keeps the rows with that status), `ended` asks for the
daemon's `done`, the others for themselves. `--state done` used to select the
ended sessions; that is `--state ended` now. A refused notification read (an
older daemon) leaves every idle agent `idle`.

`agent list` then reads one `session.snapshot` and adds the place of each
row's terminal: `tab_id`, `tab_name` and `pane_id` of the tab that shows it,
and `name`, the tab's name when it is an agent name (`cmux agent start NAME`),
else `null`. A terminal the snapshot does not show, or a refused snapshot
read, gives `null` for all four.

`agent hook status` reports each provider on its own row. A provider whose
config cannot be read is `state: unavailable`, `reason: unreadable`, with the
cause in `detail`; the other providers still answer and the command exits 0.
A failed `agent hook install|uninstall` names each cause in its message
(`<provider>: <cause>`). `agent|sidebar plugin list` with no plugin installed
prints how to install one (`--json` prints `[]`).

A selector that starts with an id prefix (`term_`, `ws_`, `pane_`, ...) but is
not an id (not 32 lowercase hex digits) is refused as a mistyped id: the
message names the id shape, the list command that prints real ids, and the
`name:` escape for a name.

With OSC 133 shell integration the terminal record carries
`extra.last_command` (`terminal-exit-status-v1`): the last command the shell
finished, with `exit_code` from `D;<code>` (absent when the shell sent none,
or when the next prompt came without `D`), `finished_at_ms` and
`started_at_ms` (decimal strings). Without integration the field is absent, so
its absence never means success. A change to it publishes a terminal upsert,
so a subscriber sees the new value without a read.

`notify` takes the flags of the macOS `cmux notify` so scripts and agent hooks
work unchanged inside a machine: `--title` (default `Notification`, at most
512 characters), `--subtitle` (at most 512), `--body` (at most 4096),
`--clear`, `--surface`, `--workspace`, `--json`; `--window`, `--id-format`, and
`--desktop` (validated as `true|false`) are accepted and ignored. The target defaults to the caller's own terminal
(`CMUX_TUI_TERMINAL_ID`, which the daemon injects into every PTY); `--surface
current` says the same, `--surface <term_id>` names another terminal of this
session, and `--workspace` alone posts a session-level row with no terminal.
A machine can only address its own session. `--clear` removes the retained
rows for that target on the machine (`notification.clear`), so every attached
client drops them. `--reply` is refused: a reply would type into a terminal,
and that channel does not cross the link. Every row is bounded because each
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

`attention next` and `attention list` read one `session.snapshot` and answer
the tabs that need the person, in the order the TUI's `next-attention` key
(`Ctrl-b a`) visits them: tabs whose agent is `blocked` first, then tabs with
an unread `error` or `warning` notification, then other unread tabs, each
oldest first. A queue entry is `{tab, terminal, workspace_id, workspace,
title, kind, reason, level, since_ms}`; `kind` is `blocked` or `unread`, and
`reason` is the notification title. `list` answers `{queue}`. `next` answers
`{target, queue_length, focused}`: `target` is the entry after the focused tab
(or after `--after <tab_…>`), wrapping, else the first, or null when the queue
is empty. Focus moves only with `--focus`, which sends `tab <tab> focus`.
An entry names the tab of its terminal's `tab_id`; a terminal projected into
several tabs is listed once, for that tab.

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
pane, screen, and workspace closes detach PTY views; `terminal close` ends the
session-owned process at once and removes all of its placements. An owner
started with `--terminal-reap-grace-seconds <n>` (`identify` lists
`terminal-reaper-active-v1`) also ends a terminal that has had no tab for `n`
seconds, counted across owner restarts.
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

## Agent start and resume

```text
cmux agent start NAME [--cmd <launcher>] [--harness H] [--pane <sel>]
  [--split right|down|left|up] [--cwd DIR] [--focus|--no-focus]
  [--timeout 90s] [--no-wait] [-- ARGS...]
cmux agent resume NAME [the same options]
cmux terminal <sel> resume [the same options]
cmux terminal <sel> wait --until ready [--timeout D]
```

`agent start` runs a coding agent in a new tab named NAME and waits until it
can take a message. NAME is a lowercase letter, then up to 31 lowercase
letters, digits, `-` or `_`; it may not be a command word, `current`,
`caller`, `focused`, `start`, `resume` or id-shaped, and no running tab may
have it (`agent.name_taken`). The launcher is a shell command line: `--cmd`,
else the `CMUX_AGENT_COMMAND` environment variable, else `claude` (`claude
--model opus`, `codex --model o3`, any wrapper). The tab runs `$SHELL -lc 'LAUNCHER "$@"'
cmux-agent ARGS...` (`/bin/sh` when `$SHELL` is not a POSIX shell), so each
extra argument stays one argv word, with `pane run --on-exit keep`: the exited
terminal keeps its argv and name for `resume`. Without `--pane` or `--split`
the caller's pane (else the focused pane) is split to the right; `--pane SEL`
alone opens a tab in that pane; `--split DIR` splits SEL (default: the
caller's pane). In a session with no pane yet (a daemon that no client
opened), it creates a workspace named NAME; the pane and its shell come from
the create receipt (else the pane of the receipt's workspace), never from
focus, so two starts at once each use their own workspace. The shell that a
split or a new workspace opens with ends once the agent runs, with `terminal
<t> close` as `pane move` does, so no running shell stays without a tab; `tab
close` is only the fallback when the terminal is not known or does not close.
The tab is focused unless `--no-focus`. These commands are client flows over
the requests above (`pane split`, `pane run`, `workspace create`,
`session.snapshot`, `terminal.screen.read`, `agent.list`,
`terminal.process.get`, `terminal close`, `tab close`).

The wait looks four times a second at the terminal, its agent records and its
screen. A startup dialog in the last 16 non-blank rows of the screen, where no
input box shows, is `blocked` with `dialog` (`folder_trust`,
`bypass_permissions_warning`, `api_key`, `login`, `onboarding`,
`update_prompt`) and a `reason`; a fresh hook record that says `blocked` is
`agent_question`. Otherwise a fresh hook record that says idle (the
`SessionStart` hook) or the agent's input box on screen is `ready`. Both count
only once the screen stood still for 1 s. cmux never answers a dialog.

`--json` prints `{name, state, reason, dialog, harness, launcher, args, cwd,
placement, workspace_id, screen_id, pane_id, tab_id, terminal_id, waited_ms}`.
`state` is `ready` (exit 0), `blocked` (exit 4), `timeout` (exit 124, default
`--timeout` 90s), `exited` (exit 1) or `started` with `--no-wait` (exit 0).
`harness` is one word per harness: `claude` (input aliases `claude-code`,
`claude_code`, `Claude Code`), `codex` (`codex-cli`), `opencode`, `gemini`,
`amp`.

`agent resume NAME` and `terminal <sel> resume` bring back an agent whose
terminal exited (a running one is `agent.running`). They read the harness
session id from `agent list --terminal` (`extra.agent_session_id`), else from
the terminal itself: an agent that quit leaves the roster, and the daemon keeps
its last harness session id and harness on the terminal's snapshot value
(`extra.agent_session_id`, `extra.agent`; memory only, a daemon restart forgets
it). With neither, the error is `agent.no_session`. They take the launcher
from `terminal <t> process show`, but not the extra arguments the start
passed (`-- ARGS` may hold the first prompt, which a resume must not send
again; put launcher flags in `--cmd`), add this command's own `-- ARGS`, and
append the harness's own resume arguments as separate argv words: `claude
--resume <id>`, `codex resume <id>`, `gemini --resume <id>`, `opencode
--session <id>`, `amp threads continue <id>`. `--cmd` replaces the recorded
launcher; `--harness` names the harness when no record does. The agent reopens
in the exited tab's pane unless `--pane` or `--split` say otherwise, with the
old tab's name and folder; the exited tab is closed. The output adds `resumed:
{terminal_id, tab_id, agent_session_id, tab_closed}`.

For `terminal <sel> resume` and `terminal <sel> wait`, `current` and
`focused` are resolved by the daemon (`terminal <sel> show`), as in every
other terminal command; other selectors are matched in one
`session.snapshot` (ids, id prefixes, titles, then names).

`terminal <sel> wait --until ready` is the same wait for any terminal (agent
records of any age count). `ready` is the only `--until` value. `ready` and
`blocked` print `{terminal_id, until, state, dialog, reason, waited_ms}` and
exit 0 and 4; an exit is `terminal.exited` (exit 1) and a passed `--timeout`
`wait.timeout` (exit 124). Without `--timeout` the wait has no practical
limit.

## Identity and agent guide

```text
cmux identify
cmux skill show
```

`identify` prints where the calling process runs. In a cmux-tui terminal
(`CMUX_TUI_TERMINAL_ID` names a `term_…` id) it reads that terminal's own
session (`CMUX_TUI_SOCKET`, or the session `--socket`/`--session` names) and
follows the terminal to its tab, pane, screen and workspace. With `--json` it
prints one object:

```json
{"kind": "cmux-tui", "socket_path": "...",
 "session": {"id": "session_…", "name": "main"},
 "machine": {"id": "machine_…", "name": "local"},
 "caller": {"found": true, "terminal_id": "term_…", "tab": "tab_…", "tab_name": null,
            "pane": "pane_…", "screen": "screen_…", "screen_name": "0",
            "workspace": "ws_…", "workspace_name": "api"},
 "outer_app": null, "guide": "cmux skill show"}
```

`caller` uses the field names of the cmux app's `system.identify` caller, so a
script reads either answer the same way. Outside a cmux-tui terminal, or when
the session does not place the terminal, `caller.found` is false and
`caller.error` says why; `session` and `machine` are still the ones this CLI
reaches. `outer_app.socket_path` is the cmux app the environment names
(`CMUX_SOCKET_PATH`); this answer is not from it. Exit codes: 0, 2 for an
invalid `--session` name, 3 when the session cannot be reached, 1 when it
refuses a read.

`skill show` prints the agent guide for this build as Markdown: the caller's
live ids (as `identify` reports them), the targeting rules, task recipes, waits,
errors and exit codes, the scope table and the terminal, pane and tab paths.
The recipes are data that a test runs through this parser, and the scope table
and paths come from the help text, so the guide never names a command the build
lacks. The guide names the executable that printed it: in a cmux app
terminal the `cmux` on PATH can be the app's CLI, so an agent runs that path
when `cmux --json identify` does not answer `kind: "cmux-tui"`. Its recipes
never `run` in the caller's own pane: `pane run` shows its new tab in the pane
it names, so the recipes split first. With `--json` it prints
`{name, version, markdown}`.

Claude Code and Codex started through the cmux-tui shims receive a short form of
the same place at session start (`SessionStart` `additionalContext`); see
[Agent hooks](../docs/agent-hooks.md#session-context).

## Local sidebar plugins

`sidebar plugin` commands read and write local plugin installation state. They
never open a protocol connection or send a plugin ID to a session. Optional
plugin names are slugs matching `[a-z0-9-_]+`.

## Local agent plugins

`agent plugin` commands read and write local installation state. They clone
and build the selected package, validate its `kind = "agent"` manifest, and
write the selected background command to `agents.plugin`. They do not open a
protocol connection or send a plugin ID to a session. Run `cmux server
reload-config` after changing the selection. The running plugin uses the
generic journal producer and append operations over the server socket. Use
`agent plugin use --builtin` to disable the selected userland plugin and return
to no agent detector.

`provider authority install` is a local Linux host-administration action. It
installs the credential for an already running provider-managed session and is
not a transported resource operation or cross-machine discovery API.

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
