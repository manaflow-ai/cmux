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
cmux attach [START OPTIONS] [--terminal <terminal-id>] [--pipe-io [--cols <n> --rows <n>]]
cmux relay [ROUTING OPTIONS]
cmux machine-agent [OPTIONS]
```

`relay` copies private protocol bytes between standard I/O and one session
socket. Machine connectors use it as a transport primitive. `attach` opens the
complete session TUI. `attach --terminal <terminal-id>` resolves an exact ID
from `cmux terminal list` and renders only that terminal, without session
chrome or unrelated event traffic. Startup attach does not accept internal
runtime identifiers, abbreviated identifiers, names, or `current`.

`attach --terminal <terminal-id> --pipe-io` is the same scoped attach without
a renderer, for an embedder that parses terminal bytes itself. stdout carries
raw bytes: the daemon replay first, then live output, with a full reset
(`ESC c` plus erase-scrollback) before any replay that is not the relay's
first output, because a replay replaces state while a byte stream appends.
stdin takes one JSON object per line: `{"input":"<base64>"}` forwards bytes to
the terminal, `{"resize":{"cols":N,"rows":N}}` drives the attached viewer
size, and `{"claim":{"geometry":true}}` re-asserts this relay's geometry
authority (authority is last-claim-wins across a terminal's attachments; an
embedder sends it when its pane receives user input, so the typed-in pane
owns the PTY size). Each applied resize and claim is reported as one
`{"diag":...}` stderr line; unknown keys are ignored. stderr ends with one
JSON line. Input objects are limited to 1 MiB of decoded bytes and each JSON
line is limited to 2 MiB, including its newline.
`{"exit":{"reason":"terminal-ended"|"daemon-lost"|"parent-closed"}}`. Exit
code 0 means the terminal ended or the embedder closed stdin (do not
respawn); exit code 2 means the daemon connection was lost and a respawn
reattaches and resyncs from a fresh replay. `--cols` and `--rows` set the
initial viewer size (default 80x24). `--pipe-io` requires `--terminal`.

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
cmux server stop [--session <name>] [--socket <path>] [--force]
cmux server reload-config [--session <name>] [--socket <path>]
```

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
and stopping never deletes the durable topology. `session <name>|current stop`
is an alias for the same local operation. Opaque session IDs are not accepted
because local socket resolution uses a session name. `--all` is intentionally
deferred until a multi-session registry can identify every target without
introducing a second command registry.

`server status` fails when no server is listening. In contrast, `server stop`
is idempotent and reports `not_running` as success for an absent socket. JSON
errors use stable lifecycle codes and do not include raw transport, server, or
filesystem error text.

Authenticated network operations use `remote connect|ssh|forward|rpc`,
`remote enroll`, and `remote known-daemons`; they cannot accept local server
targeting. `remote stop` manages only a replaceable SSH sidecar. A listener
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
terminal browser  notification  agent  sidebar
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
supplied ancestor is checked for containment before the operation runs.

Run `cmux <resource> --help` for its exact paths and flags. Parser tests
map every operational one-shot command and parameter in
[`resource-operations-v2.json`](resource-operations-v2.json) to a public path.
Sensitive renderer grants and connection-owned stream/viewer controls remain
SDK and raw-only.

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

agent list
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

screen list|create
screen <selector> show|rename|focus|close
screen <selector> layout export|undo
screen <selector> pane ...

pane list|create
pane <selector> show|rename|focus|close|split|neighbor|swap|zoom|run
pane <selector> focus direction <left|right|up|down>
pane <selector> split ratio set
pane <selector> viewport width set
pane <selector> tab ...

tab list
tab create terminal|browser
tab <selector> show|rename|move|focus|close
tab <selector> terminal|browser ...

terminal list
terminal <selector> show|write|keys|mouse|copy|move|project|attach|close
terminal <selector> focus <in|out>
terminal <selector> screen read|wait
terminal <selector> state read
terminal <selector> history read|clear
terminal <selector> output read [--after <offset>] [--max-bytes <n>]
terminal <selector> process show|wait
terminal <selector> viewport scroll

browser list
browser <selector> show|navigate|back|forward|reload|activate
browser <selector> key|text|attach|close
browser <selector> mouse|wheel --pointer-frame-seq <decimal>

notification list|create
agent list|report
pairing request list
pairing request <selector> respond <accept|reject>
projection <selector> show|put

sidebar view show|ensure|attach|input|resize|reload
sidebar plugin list|install|use|update|remove

provider authority install

```

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

## Local sidebar plugins

`sidebar plugin` commands read and write local plugin installation state. They
never open a protocol connection or send a plugin ID to a session. Optional
plugin names are slugs matching `[a-z0-9-_]+`.

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
