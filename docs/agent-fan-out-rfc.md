# Agent fan-out

Status: proposed

This RFC defines a first-class way to start several independent coding-agent
runs from one prompt while keeping the runs visible, addressable, and safe to
retry. It builds on the detached terminal primitive used by `cmux vm agent`;
it does not create a second agent launcher.

## Why this needs a protocol

Today an agent can start one detached run with:

```bash
cmux vm agent --agent codex --machine vivid-newt --no-open -- \
  "review the authentication changes"
```

Starting several commands in a shell loop is easy, but cmux then has no
parent/child relationship, no aggregate state, no stable retry operation, and
no way for the sidebar to show that the terminals belong to one operation. A
client that is interrupted after creating some terminals also cannot tell which
children were created by that invocation.

Fan-out is therefore an operation with a durable id and child records. The
operation can be observed and resumed after the creating CLI exits.

## User-facing contract

The first CLI surface is an extension of `vm agent`:

```text
cmux vm agent --agent <claude|codex|opencode|pi> \
  [--machine <id>] [--remote-workspace <ws>] \
  [--fan-out <count>] [--name <prefix>] [--no-open] \
  [--json] -- <prompt or agent args...>
```

`--fan-out 1` is exactly the existing behavior. `count` is an integer from 1
through a server-advertised limit (initially 32). The prompt and agent argv are
copied byte-for-byte to every child. Each child gets a unique terminal and a
stable name such as `codex: review authentication [3/8]`.

By default the children are created in one newly-created remote workspace
named `<prefix> · fan-out <short-id>`. `--remote-workspace` opts into an
existing workspace. `--no-open` still prevents local projection; it does not
prevent remote creation. A future `--workspace-mode separate` may provision
one remote workspace per child, but that is deliberately out of the MVP.

The non-JSON result prints one operation id and every child address only after
the create request has been accepted:

```text
Fan-out f_01J… started (8 children, 7 running, 1 failed)
  [1/8] term_…  cmux vm open vivid-newt/ws_…/term_…
  …
Watch: cmux vm agent status f_01J…
```

`--json` returns the same data as a single object. Creation is asynchronous;
the command does not wait for child completion unless a later `status` or
`wait` operation is requested. This avoids eight agents making a synchronous
CLI call hold open for an arbitrary amount of time.

## Wire API

The control socket gets three methods. They belong beside the existing
`surface.new_terminal` and `vm.terminal_wait_exit` methods in
`Sources/Surfaces/SurfaceSocketCommands.swift` and are dispatched from
`Sources/TerminalController.swift`.

### `vm.agent_fan_out`

Request:

```json
{
  "machine": "vivid-newt",
  "agent": "codex",
  "argv": ["codex", "exec", "review the authentication changes"],
  "count": 8,
  "name_prefix": "codex: review authentication",
  "remote_workspace_id": null,
  "open": false,
  "focus": false,
  "operation_id": null
}
```

The server validates the complete request before creating a child. It returns
an operation record even when the first child cannot be started:

```json
{
  "operation_id": "f_01J…",
  "machine": "vivid-newt",
  "remote_workspace_id": "ws_…",
  "requested": 8,
  "created": 8,
  "children": [
    {"index": 0, "state": "running", "terminal_id": "term_…",
     "reattach": "cmux vm open vivid-newt/ws_…/term_…"}
  ],
  "state": "running"
}
```

The operation is idempotent when `operation_id` is supplied. A retry returns
the existing operation and never starts another child. If creation stops part
way through, already-created children remain running and missing indexes are
returned as `failed` with an error code. The server must not silently retry an
agent process.

### `vm.agent_fan_out_status`

Request: `{ "machine": "vivid-newt", "operation_id": "f_01J…" }`.

The response returns the full operation and child records. Child state is
derived from the same terminal exit receipt used by
`vm.terminal_wait_exit`: `starting`, `running`, `needs_input`, `exited`, or
`failed`. A status read never refreshes every machine in the account; it reads
the pinned machine and uses the catalog's cached terminal snapshot.

### `vm.agent_fan_out_wait`

Request: `{ "machine": "vivid-newt", "operation_id": "f_01J…",
"timeout_ms": 30000 }`.

This is a bounded long-poll. It returns when a child changes state, all
children settle, or the timeout expires. Repeating it gives the same bounded
latency behavior as `waitForVMTerminalExit` in
`CLI/CMUXCLI+VMTransfer.swift`.

## Data model and persistence

The daemon stores one operation record in its existing durable session/receipt
store. The record is independent of local projection and survives a client
disconnect:

```text
AgentFanOutOperation
  id: String
  machineID: String
  remoteWorkspaceID: String
  agent: String
  argvDigest: String       # no prompt text in telemetry
  requestedCount: Int
  createdAt: Date
  updatedAt: Date
  state: creating|running|partial|completed|failed|cancelled
  children: [AgentFanOutChild]

AgentFanOutChild
  index: Int               # immutable 0-based position
  terminalID: String?
  state: starting|running|needs_input|exited|failed
  exitCode: Int?
  errorCode: String?
  startedAt: Date?
  endedAt: Date?
```

The prompt itself stays in the terminal's command/scrollback storage and is
not copied into operation telemetry. `argvDigest` is only for identifying a
safe idempotent retry. The server must enforce ownership of both the machine
and operation before returning child addresses.

## Sidebar and workspace presentation

The operation should use the existing workspace-group model rather than a
second grouping implementation:

1. Create or reuse one remote workspace with
   `vm.workspace_new` (`Sources/Surfaces/SurfaceSocketCommands.swift`).
2. Return `remote_workspace_id` in the operation record.
3. When `open` is true, project the workspace once through
   `SurfaceCatalog.project`; individual children remain remote terminals and
   are visible in the Cloud tree.
4. Add an `AgentFanOut` badge to the Cloud workspace row. The row shows
   `created/requested` and the aggregate state. Selecting it opens the
   operation status view; selecting a child opens that terminal.

The local left sidebar should continue to show one workspace row. A compact
fan-out glyph and `3/8` progress are enough for the row; child state belongs in
the expanded workspace/Cloud tree. This avoids eight near-identical rows
overwhelming the workspace list.

The state projection belongs in the existing Cloud tree snapshot path
(`Sources/Cloud/CloudTreeNode.swift`, `Sources/Cloud/CloudTreeRowContentView.swift`)
and should reuse the agent lifecycle vocabulary already consumed by
`WorkspaceSidebarAgentRuntimeObservationModel`.

## Failure, cancellation, and resource limits

- The server validates `count`, agent name, workspace ownership, and machine
  availability before the first child is created.
- A machine or quota failure after creation produces `partial`; existing
  children are never killed implicitly.
- A future explicit `vm agent cancel <operation>` may terminate only children
  that are still running. Cancellation is not part of the MVP because terminal
  kill semantics need to be shared with the existing wait/close paths.
- The initial count limit is 32 per operation and 128 live children per user
  and machine. Limits are returned as structured `limit_exceeded` errors so a
  client can offer a smaller count.
- `--wait` and `--output` remain single-agent options. Fan-out output must be
  collected with per-child `vm.terminal_output` calls so output cannot be
  interleaved or attributed incorrectly.

## Implementation sequence

1. Add `AgentFanOutOperation` and persistence to the daemon's existing
   terminal receipt store. Add pure validation/state-transition tests.
2. Add `vm.agent_fan_out` and status/wait socket handlers. Internally call the
   same `surfaceNewTerminal` helper used by `surface.new_terminal`; do not
   duplicate provider or projection logic.
3. Extend `CLI/CMUXCLI+VMTransfer.swift` and `CLI/CMUXCLI+VMHelp.swift` with
   `--fan-out`, operation formatting, and `status`/`wait` subcommands. Keep
   `--fan-out 1` on the old path until the new method is proven equivalent.
4. Add Cloud tree aggregate badges and operation selection. Reuse
   `SidebarCompactStatusGlyph` for the compact row state.
5. Add reconnect tests: create, drop the client, reconnect, status, and wait.

## Tests required for the first PR

- `cmuxTests/AgentFanOutOperationTests.swift`: validation, idempotent retry,
  partial creation, aggregate state, and count limits.
- `cmuxTests/CLIVMTransferTests.swift`: argument parsing and JSON/non-JSON
  output using the existing mock socket server.
- `cmuxTests/CloudTree*Tests.swift`: aggregate badge and child selection.
- A socket integration test proving that a duplicate request with the same
  `operation_id` creates no additional terminal.

Linux cloud containers cannot run the Swift/Xcode test suite; run the local
syntax/wiring checks and the full XCTest target on macOS before opening the
upstream PR.
