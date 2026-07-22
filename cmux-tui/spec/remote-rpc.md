# Remote workspace RPC contract

Status: normative schema for remote protocol 1.

This contract describes the `workspace-rpc`, `process-stream`, and `tcp-tunnel` services. Rust enum variant names serialize as kebab-case `type` values. Struct field names remain snake_case. Identifier wrappers serialize as their underlying JSON string or unsigned integer.

## Service opening and message framing

Open a logical service stream by sending one control object:

```json
{"type":"open","service":"workspace-rpc","metadata":{"lane":"control"}}
```

The server accepts it with:

```json
{"type":"opened","service":"workspace-rpc"}
```

It may instead return `{"type":"rejected","code":"...","message":"..."}`. The implemented service names are `mux-control`, `workspace-rpc`, `process-stream`, `tcp-tunnel`, and `computer-use`.

After service opening, each `workspace-rpc` or `process-stream` JSON message is prefixed by one unsigned 32-bit big-endian byte length. A message may contain at most 16 MiB of JSON. A `tcp-tunnel` stream carries raw bytes after its open response.

A client normally keeps four `workspace-rpc` streams open:

| Purpose | Open metadata | Requests |
| --- | --- | --- |
| Interactive | `{"lane":"interactive"}` | `write-process`, `resize-process`, `signal-process` |
| Control | `{"lane":"control"}` | Workspace, process lifecycle, route, capability, and computer-use control |
| Cancellation | `{"lane":"control","purpose":"cancellation"}` | `cancel-request` only |
| Bulk | `{"lane":"bulk"}` | File, search, patch, Git, diff, and retained process-event reads |

The server rejects `tunnel` as a workspace RPC lane. `purpose` defaults to `requests`; `cancellation` is valid only on the control lane. Requests received on one traffic-class stream preserve receive order when they mutate state. Requests started concurrently on different streams have no implicit ordering.

## Envelopes

A direct service request is:

```json
{
  "id": 42,
  "timeout_ms": 5000,
  "request": {"type":"list-workspaces"}
}
```

`id` is an unsigned 64-bit integer unique among active requests in one authenticated client session. `timeout_ms` is optional. A timeout is accepted only for cancel-safe requests: `capabilities`, `list-workspaces`, `stat`, `read-file`, `list-directory`, `search`, `git-status`, `diff`, `wait-process`, `read-process-events`, and both computer-use capability queries. A mutating request with `timeout_ms` returns `deadline-unsupported`.

A successful direct service response uses Rust `Result` encoding:

```json
{
  "id": 42,
  "result": {"Ok":{"type":"workspaces","workspaces":[["w:abc","/srv/project"]]}}
}
```

An error is:

```json
{
  "id": 42,
  "result": {
    "Err": {
      "code": "invalid-path",
      "message": "path escapes the workspace root",
      "retryable": false
    }
  }
}
```

`details` is optional. Implemented detail objects are `{"type":"patch-rollback","failed_paths":[...]}` and `{"type":"process-replay-gap","requested_after":17,"range":{...}}`.

`cmux-tui rpc` is a convenience adapter. Its stdin and `--request` value are bare request objects, and it prints the bare successful `WorkspaceResponse` or exits with an error. Do not wrap CLI input in the direct service envelope.

## Scalar and shared types

`ByteString` is a standard padded base64 JSON string. File data, process input and output, and legacy diff data use this type.

| Type | JSON values |
| --- | --- |
| `FilePrecondition` | `"any"`, `"missing"`, or `{"content-hash":"<sha256>"}` |
| `DiffFormat` | `"unified"`, `"structured"`, or `"structured-v1"` |
| `ProcessLifetime` | `"operation"`, `"workspace"`, or `"detached"` |
| `ProcessEnvironment` | `"inherit"` or `"clean"`; omitted defaults to `inherit` |
| `ProcessSignal` | `"interrupt"`, `"terminate"`, `"kill"`, or `"hangup"` |
| `PtyEofPolicy` | `"reject"`, `"control-d"`, or `"hangup"`; omitted defaults to `reject` |
| `RoutePolicy` | `"loopback-only"`, `"private-network"`, or `"any"` |
| `FileKind` | `"file"`, `"directory"`, `"symlink"`, or `"other"` |

Workspace paths are relative to the opened root and may not escape it through `..` or symlinks. `open-workspace.root` is a path on the daemon machine.

## Request inventory

Every field in the table is required unless marked optional or given a default.

| Request `type` | Fields | Successful response `type` |
| --- | --- | --- |
| `capabilities` | none | `capabilities` |
| `open-workspace` | `root:string` | `workspace` |
| `list-workspaces` | none | `workspaces` |
| `stat` | `workspace:string`, `path:string`, `follow_symlinks:bool` | `stat` |
| `read-file` | `workspace`, `path`, `offset:u64`, `limit:u32` | `file` |
| `write-file` | `workspace`, `path`, `data:ByteString`, `precondition:FilePrecondition`, `create_parents:bool` | `written` |
| `list-directory` | `workspace`, `path`, `include_hidden:bool`, `limit:u32`, optional `cursor:string` | `directory` |
| `search` | `workspace`, `query`, `paths:[string]`, `globs:[string]`, `include_hidden`, `max_results:u32`, optional `cursor` | `search` |
| `apply-patch` | `workspace`, `patch:string`, `dry_run:bool`, optional `preconditions:{path:FilePrecondition}` default `{}` | `patch` |
| `git-status` | `workspace` | `git-status` |
| `diff` | `workspace`, `paths:[string]`, `staged:bool`, `context:u16`, `format:DiffFormat`, optional `cursor`, optional `max_bytes:u32` | `diff` or `structured-diff` |
| `spawn-process` | Process fields below | `process-started` |
| `write-process` | `process:u64`, `write_id:u64`, `data:ByteString`, `eof:bool` | `process-write-accepted` |
| `resize-process` | `process`, `cols:u16`, `rows:u16` | `process-resized` |
| `signal-process` | `process`, `signal:ProcessSignal` | `process-signaled` |
| `wait-process` | `process` | `process-exit` |
| `read-process-events` | `process`, `after_sequence:u64`, `limit:u32` | `process-events` or `process-replay-gap` |
| `finish-operation` | `operation:string` | `operation-finished` |
| `close-workspace` | `workspace` | `workspace-closed` |
| `cancel-request` | `request:u64` | `request-canceled` |
| `create-route` | `workspace`, `host:string`, `port:u16`, `policy:RoutePolicy` | `route-created` |
| `close-route` | `route:u64` | `closed` |
| `computer-use-capabilities` | none | `computer-use-capabilities` |
| `computer-use-capabilities-v1` | none | `computer-use-capabilities-v1` |
| `invoke-computer-use` | `invocation:ComputerUseInvocation` | unavailable in protocol 1 |
| `cancel-computer-use` | `invocation:u64` | `computer-use-canceled` with `accepted:false` |

Common response objects have these fields:

| Response `type` | Fields |
| --- | --- |
| `capabilities` | `capabilities:[string]` |
| `workspace` | `id:string`, `root:string` |
| `workspaces` | `workspaces:[[id,root]]` |
| `stat` | `stat:FileStat` |
| `file` | `data:ByteString`, `offset:u64`, `eof:bool`, `content_hash:string` |
| `written` | `bytes:u64`, `content_hash:string` |
| `directory` | `entries:[DirectoryEntry]`, `truncated:bool`, optional `next_cursor` |
| `search` | `matches:[SearchMatch]`, `truncated:bool`, optional `next_cursor` |
| `patch` | `changed_paths:[string]`, `applied:bool`, optional `files:[PatchFileResult]` default `[]` |
| `git-status` | `status:{branch,head,changes}` |
| `diff` | `data:ByteString`, `format:DiffFormat`, optional `next_cursor` |
| `structured-diff` | `diff:StructuredDiffV1`, optional `next_cursor` |
| `process-started` | `process:u64`, `pid:u32|null`, optional `operation:string` |
| `process-write-accepted` | `process`, `write_id` |
| `process-resized` | `process`, `cols`, `rows` |
| `process-signaled` | `process`, `signal` |
| `process-exit` | `process`, `code:i32|null`, `signal:i32|null` |
| `process-events` | `process`, `range`, `events`, optional `next_cursor:u64` |
| `process-replay-gap` | `process`, `requested_after`, `range` |
| `operation-finished` | `operation`, `processes_signaled:u32` |
| `workspace-closed` | `workspace` |
| `request-canceled` | `request`, `accepted:bool` |
| `route-created` | `route:u64`, `host`, `port` |
| `closed` | no fields |

Protocol 1 currently advertises `workspace-files-v1`, `workspace-search-v1`, `workspace-patch-v1`, `workspace-diff-v1`, `process-pipes-v1`, `process-pty-v1`, `tcp-routes-v1`, `computer-use-negotiation-v1`, `workspace-pagination-v1`, `workspace-patch-v2`, `structured-diff-v1`, `process-lifecycle-v2`, `process-replay-v1`, and `request-control-v1`.

## Files, search, patch, and diff

Read and write binary data as base64. This writes `hello\n` only when the target does not exist:

```json
{
  "type": "write-file",
  "workspace": "w:abc",
  "path": "notes.txt",
  "data": "aGVsbG8K",
  "precondition": "missing",
  "create_parents": false
}
```

`file` responses contain `data`, `offset`, `eof`, and `content_hash`. `written` contains `bytes` and `content_hash`. A `stat` object contains `path`, `kind`, `size`, optional `modified_unix_ms`, `executable`, and optional `content_hash`.

`directory` returns `entries`, `truncated`, and optional `next_cursor`. Each entry contains `name`, `path`, `kind`, and `size`. `search` returns `matches`, `truncated`, and optional `next_cursor`. Each match contains `path`, one-based `line` and `column`, `text`, `before`, and `after`. A cursor is opaque and bound to the original request parameters.

`apply-patch.patch` is a unified text patch. A `patch` response contains `changed_paths`, `applied`, and `files`. Each file result has `path`, optional `previous_path`, `action`, optional `old_content_hash`, and optional `new_content_hash`. `action` is `created`, `modified`, `deleted`, or `renamed`.

Request a typed diff with:

```json
{
  "type": "diff",
  "workspace": "w:abc",
  "paths": [],
  "staged": false,
  "context": 3,
  "format": "structured-v1",
  "max_bytes": 1048576
}
```

`unified` returns `{"type":"diff","data":"<base64>","format":"unified",...}`. Legacy `structured` returns base64-encoded JSON in the same `diff` shape. `structured-v1` returns `{"type":"structured-diff","diff":{"version":1,"files":[...]},...}`. Each typed file has optional `old_path`, optional `new_path`, `metadata`, and `hunks`; each hunk has `header` and `lines`; each line has `kind` (`context`, `add`, `delete`, or `metadata`) and `text`. All diff responses may include `next_cursor`.

## Processes

`spawn-process` fields are:

| Field | Contract |
| --- | --- |
| `workspace` | Open workspace ID |
| `argv` | Nonempty argv executed directly, without a shell |
| `cwd` | Optional workspace-relative directory |
| `env` | Required string-to-string map |
| `io` | Optional `pipes` or `pty` object; defaults to writable pipes |
| `lifetime` | Required `operation`, `workspace`, or `detached` |
| `operation` | Optional string valid only with operation lifetime; the daemon creates one when omitted |
| `timeout_ms` | Optional process lifetime timeout |
| `retained_output_bytes` | Optional retained replay budget |
| `environment` | Optional `inherit` or `clean`, default `inherit` |

Omitting `io` selects `{"type":"pipes","stdin":true}`. Read-only commands can explicitly close stdin:

```json
{
  "type": "spawn-process",
  "workspace": "w:abc",
  "argv": ["git", "status", "--short"],
  "cwd": null,
  "env": {},
  "io": {"type":"pipes","stdin":false},
  "lifetime": "operation",
  "operation": "agent-step-17"
}
```

Programs that need terminal behavior request a PTY:

```json
{
  "type": "spawn-process",
  "workspace": "w:abc",
  "argv": ["bash"],
  "cwd": null,
  "env": {},
  "io": {
    "type": "pty",
    "cols": 120,
    "rows": 40,
    "term": "xterm-256color",
    "eof": "control-d"
  },
  "lifetime": "workspace"
}
```

`write-process.data` is base64 and decodes to at most 32 KiB. `write_id` values increase monotonically per process. Repeating a retained ID with identical data and `eof` is idempotent; reusing it with different content is an error. PTY EOF defaults to rejection unless the spawn request chooses `control-d` or `hangup`.

`process-events` contains `process`, `range`, `events`, and optional `next_cursor`. `range` has optional `first_available`, `last_produced`, and `exited`. Each event envelope has `sequence` and `event`. Output event types are `stdout` and `stderr`, with `process`, `sequence`, and base64 `data`; an `exit` event has `process`, optional `code`, and optional `signal`.

For retained and live output, open `process-stream` with decimal metadata values:

```json
{"type":"open","service":"process-stream","metadata":{"process":"7","after":"12"}}
```

After the open response, the server sends length-prefixed `RpcEvent` objects and accepts no client messages on that stream.

## Cancellation

Send cancellation on the dedicated cancellation stream:

```json
{
  "id": 99,
  "request": {"type":"cancel-request","request":42}
}
```

The response is `{"type":"request-canceled","request":42,"accepted":true}` when the target was active or its pre-registration cancellation tombstone was recorded. Cancellation is scoped to the authenticated client session. It cannot cancel another client's request with the same numeric ID.

## Routes and TCP forwarding

Create a daemon-side target:

```json
{
  "type": "create-route",
  "workspace": "w:abc",
  "host": "127.0.0.1",
  "port": 3000,
  "policy": "loopback-only"
}
```

The response is `{"type":"route-created","route":9,"host":"127.0.0.1","port":3000}`. For each local accepted connection, open `tcp-tunnel` with `{"route":"9"}` metadata. After `opened`, copy raw TCP bytes in both directions. A tunnel is bound to one carrier generation and closes on reconnect; the local application reconnects it. Close the registration with `{"type":"close-route","route":9}`.

## Computer-use placeholders

`computer-use-capabilities-v1` returns entries with `feature` and `version`. Feature strings are `screenshot`, `accessibility-tree`, `pointer`, `keyboard`, `text-input`, and `scroll`. The default daemon returns an empty list.

An `invoke-computer-use` request contains an `invocation` with numeric `id`, optional `workspace`, optional `timeout_ms`, and an `action`. Action objects use the types `screenshot`, `accessibility-tree`, `pointer`, `keyboard`, `text-input`, or `scroll`. Protocol 1 returns `computer-use-unavailable` because no platform executor is wired. Future execution belongs on the separate `computer-use` service so media and long actions cannot block process input.

| Action `type` | Fields |
| --- | --- |
| `screenshot` | optional `display:u32` |
| `accessibility-tree` | optional `root:string` |
| `pointer` | `x:i32`, `y:i32`, `action:move|left-down|left-up|right-down|right-up` |
| `keyboard` | `key:string`, `action:down|up|press`, optional `modifiers:[string]` default `[]` |
| `text-input` | `text:string` |
| `scroll` | `x:i32`, `y:i32`, `delta_x:i32`, `delta_y:i32` |
