# cmux Events

cmux exposes a reconnectable event stream for local tools that need to observe
workspace, pane, surface, notification, browser, Feed, and agent-hook activity.

The same events are appended to `~/.cmuxterm/events.jsonl` as newline-delimited
JSON. The live stream is delivered over the existing cmux socket. Clients call
the v2 method `events.stream`, then keep reading newline-delimited JSON frames
from the same connection.

## Quick start

```bash
cmux events --cursor-file ~/.cache/cmux/events.seq --reconnect
cmux events --category window --category workspace --category pane --category surface
cmux events --category notification
cmux events --category feed --category agent --no-heartbeat
```

Every event has a monotonically increasing process-local `seq` and a `boot_id`.
Persist the latest processed `seq`, then reconnect with `after_seq` or use
`cmux events --cursor-file`. If cmux restarts, `boot_id` changes and the server
marks stale cursors as a resume gap.

Use the JSONL log for audit and catch-up tools. Use the socket stream for live
delivery with bounded replay.

Lifecycle events with `source: "window.lifecycle"` or
`source: "workspace.lifecycle"` are emitted from the cmux model, so they cover
UI actions, CLI/socket commands, shortcuts, startup creation, restore paths, and
AppKit focus/key transitions. Socket-sourced events are reserved for command
effects that do not have an authoritative model lifecycle event.

## Stream request

Send one JSON request line to the socket:

```json
{"id":"client-1","method":"events.stream","params":{"after_seq":123,"categories":["notification","feed"]}}
```

Parameters:

| Param | Type | Meaning |
| --- | --- | --- |
| `after_seq` | integer | Replay retained events whose `seq` is greater than this value. |
| `after` | integer | Alias for `after_seq`. |
| `names` | string array | Optional event-name filter. |
| `name` | string or array | Alias for `names`. |
| `categories` | string array | Optional category filter. |
| `category` | string or array | Alias for `categories`. |
| `include_heartbeats` | boolean | Defaults to `true`. Sends heartbeat frames when no event arrives. |

The request line takes over the socket connection. Do not send additional
commands on that connection after `events.stream`.

## Frames

The server writes one JSON object per line. The first frame is always `ack`.
After that, the stream sends retained replay events, then live events and
heartbeats.

### Ack

```json
{
  "type": "ack",
  "protocol": "cmux-events",
  "version": 1,
  "boot_id": "0F221057-0320-41B7-8CB3-083C8D927D95",
  "subscription_id": "8F6F1E66-0D6E-4B4D-A0F8-0F7B0B7B92CA",
  "heartbeat_interval_seconds": 15,
  "replay_count": 2,
  "resume": {
    "after_seq": 123,
    "requested_after_seq": 123,
    "oldest_seq": 120,
    "latest_seq": 125,
    "next_seq": 126,
    "gap": false
  },
  "filters": {
    "names": [],
    "categories": ["notification"]
  }
}
```

`resume.gap` is `true` when the requested cursor is older than cmux still keeps
in memory, or newer than the current process after an app restart. In that case,
process the replayed tail, then refresh any state you need through
snapshot-style commands such as `list-workspaces`, `list-notifications`, `tree`,
`extension.sidebar.snapshot`, or focused surface queries.

### Event

```json
{
  "type": "event",
  "protocol": "cmux-events",
  "version": 1,
  "boot_id": "0F221057-0320-41B7-8CB3-083C8D927D95",
  "seq": 126,
  "id": "0F221057-0320-41B7-8CB3-083C8D927D95-126",
  "name": "notification.created",
  "category": "notification",
  "source": "notification.store",
  "occurred_at": "2026-05-06T19:18:03.421Z",
  "workspace_id": "9B6920C1-6C29-4C27-A069-78CF285F932A",
  "surface_id": "83F4E6A4-5246-4DB8-A412-9CE7B059FA6C",
  "pane_id": null,
  "window_id": null,
  "payload": {
    "notification_id": "7ED5F805-CC6F-4B06-9701-AC798F63E209",
    "title": null,
    "subtitle": null,
    "body": null,
    "title_length": 14,
    "subtitle_length": 0,
    "body_length": 13,
    "redacted_fields": ["title", "subtitle", "body"],
    "delivery": "store"
  }
}
```

Event fields:

| Field | Meaning |
| --- | --- |
| `seq` | Process-local sequence. Increases by one for every emitted event. |
| `boot_id` | UUID process-boot identifier for this in-memory event log. Changes when cmux restarts. |
| `id` | Stable event id for the current cmux process. Use it for dedupe. |
| `name` | Specific event name, such as `feed.item.received`. |
| `category` | Coarse subscription group. |
| `source` | Producer, such as `socket.v2`, `notification.store`, or `codex`. |
| `occurred_at` | ISO-8601 timestamp with fractional seconds. |
| `workspace_id` | Workspace UUID when known. |
| `surface_id` | Surface UUID when known. |
| `pane_id` | Pane UUID when known. |
| `window_id` | Window UUID when known. |
| `payload` | Event-specific JSON object. |

### Heartbeat

```json
{
  "type": "heartbeat",
  "protocol": "cmux-events",
  "version": 1,
  "boot_id": "0F221057-0320-41B7-8CB3-083C8D927D95",
  "subscription_id": "8F6F1E66-0D6E-4B4D-A0F8-0F7B0B7B92CA",
  "latest_seq": 126,
  "occurred_at": "2026-05-06T19:18:18.421Z"
}
```

Heartbeats have no `seq`. They keep the connection observable and tell clients
the server's latest sequence.

## Resume contract

The intended client loop is:

1. Connect to the cmux socket and authenticate if required.
2. Send `events.stream` with the last fully processed `seq`.
3. Read `ack`.
4. If `ack.resume.gap` is true, refresh state through snapshot commands.
5. Process replayed events, then live events.
6. Persist each event's `seq` only after your side effect succeeds.
7. Reconnect with the latest persisted `seq` if the socket closes.

The retained replay buffer is in memory and bounded to 4,096 events. Individual
event frames are capped to 16 KiB after JSON encoding; oversized payloads are
replaced with a small payload that sets `payload_truncated: true`.

Each live subscriber also has a bounded pending queue of 1,024 events. If a
client stops reading and falls behind that queue, cmux closes that subscription
with a `slow_consumer` error. The client should reconnect with the last `seq` it
successfully processed.

The durable event log is bounded too. cmux writes current events to
`~/.cmuxterm/events.jsonl`, rotates the previous file to
`~/.cmuxterm/events.jsonl.1`, and caps each file at 16 MiB. Disk writes are
batched behind a bounded 1,024-line queue. Under sustained disk backpressure,
cmux drops the oldest pending disk-only lines and keeps the live socket stream
and in-memory replay buffer moving. Clients can read those files for recent
auditing, but should treat the socket `ack.resume.gap` contract plus snapshot
commands as the source of truth for catch-up after long outages. Feed still
writes its specialized long-term audit log to `~/.cmuxterm/workstream.jsonl`.

## CLI

`cmux events` prints the stream as newline-delimited JSON.

Options:

| Option | Meaning |
| --- | --- |
| `--after <seq>` | Start after a sequence number. |
| `--after-seq <seq>` | Alias for `--after`. |
| `--cursor-file <path>` | Read the starting sequence from a file and update it after each event. |
| `--name <event>` | Filter by event name. Repeatable. |
| `--category <name>` | Filter by category. Repeatable. |
| `--reconnect` | Reconnect forever and resume from the last received event. |
| `--limit <n>` | Exit after printing `n` event frames. |
| `--no-ack` | Hide the initial ack frame. |
| `--no-heartbeat` | Hide heartbeat frames. |

## Event catalog

Window:

| Name | Trigger |
| --- | --- |
| `window.created` | A main cmux window is registered in the app model. Covers startup, session restore, shortcuts, menus, and socket commands. |
| `window.focused` | A cmux window focus request succeeded. This is an app-level focus action, not necessarily a new AppKit key transition. |
| `window.keyed` | AppKit reported a main cmux window became the key window. Use this to track the window receiving keyboard input. |
| `window.unkeyed` | AppKit reported a main cmux window resigned key status. |
| `window.closed` | A main cmux window was unregistered during close. |

Window lifecycle payloads include `window_id`, `workspace_id`,
`workspace_count`, `selected_workspace_index`, `is_key_window`,
`is_main_window`, and `origin`.

Workspace:

| Name | Trigger |
| --- | --- |
| `workspace.created` | Workspace model created through UI, CLI, socket, startup, or restore. |
| `workspace.selected` | Selected workspace changed in a window. Fires for sidebar clicks, shortcuts, command palette actions, tmux-compatible `next-window`/`previous-window`/`last-window`, CLI, and socket commands. |
| `workspace.closed` | Workspace closed. |
| `workspace.renamed` | Workspace renamed. |
| `workspace.reordered` | Workspace order changed. |
| `workspace.moved` | Workspace moved to another window. |
| `workspace.action` | Workspace action command completed. |
| `workspace.prompt.submitted` | A prompt was submitted in a workspace. Used by extension sidebars to keep derived state fresh without polling. |

`workspace.reordered` payloads are published by the shared workspace lifecycle
path and include ordered `workspace_ids`, `moved_workspace_ids`,
`pinned_workspace_ids`, and `count`.

`workspace.prompt.submitted` payloads include `workspace_id`, a redacted
`message`, `message_preview`, `message_length`, and `redacted_fields`. This is
local sensitive data, so consumers should only forward it with explicit user
opt-in.

Extension sidebars should bootstrap from the v2 socket method
`extension.sidebar.snapshot`, then subscribe to `cmux events --category
workspace --category notification --category sidebar --reconnect` and reduce
events from the returned `seq`. The snapshot returns `selected_workspace_id`
and an ordered `workspaces` array containing workspace ids/refs, title,
description, pinned state, root/project paths, branch summary, remote status,
latest submitted prompt preview/time, listening ports, pull request URLs,
panel directories, and git branch summaries.

Socket `workspace.reorder` and `workspace.reorder_many` command results include
`plan` and `events` arrays that use short refs and final indexes. Those response
fields describe the command result; they are not separate event-stream payloads:

```json
{
  "window_id": "2FB4...",
  "window_ref": "window:1",
  "workspace_id": "8D10...",
  "workspace_ref": "workspace:11",
  "from_index": 12,
  "to_index": 1
}
```

Surface and pane:

| Name | Trigger |
| --- | --- |
| `surface.created` | Terminal, browser, markdown, or file preview surface created in a pane. |
| `surface.selected` | Selected surface changed inside a pane. Fires for horizontal tab selection and programmatic selection convergence. |
| `surface.focused` | Focused surface changed for a workspace. This is the surface that should receive keyboard/input commands. |
| `surface.closed` | Surface closed. |
| `surface.moved` | Surface moved to another pane, workspace, or window. |
| `surface.reordered` | Surface order changed inside a pane. |
| `surface.action` | Surface or tab action command completed. |
| `surface.input_sent` | Text was sent through the socket API. Text is redacted. |
| `surface.key_sent` | Key was sent through the socket API. |
| `pane.created` | Pane created. |
| `pane.closed` | Pane closed. |
| `pane.focused` | Focused pane changed for a workspace. Fires for pane clicks, split focus, `focus-pane`, `last-pane`, and selection convergence after close/move. |
| `pane.resized` | Pane resized. |
| `pane.swapped` | Two panes swapped. |
| `pane.broken` | Pane broken into a new workspace. |
| `pane.joined` | Pane joined into another pane. |

Workspace selection payloads include `previous_workspace_id`, `index`, and
`tab_count`. Surface selection payloads include `previous_surface_id`, `pane_id`,
`kind`, and `focused`. Pane focus payloads include `selected_surface_id`.

Sidebar metadata:

| Name | Trigger |
| --- | --- |
| `sidebar.metadata.updated` | Status pill, metadata entry, or metadata block updated. |
| `sidebar.metadata.cleared` | Status pill, metadata entry, or metadata block cleared. |
| `sidebar.progress.updated` | Sidebar progress set or updated. |
| `sidebar.progress.cleared` | Sidebar progress cleared. |
| `sidebar.log.appended` | Sidebar log entry appended. |
| `sidebar.log.cleared` | Sidebar log cleared. |
| `sidebar.reset` | Sidebar context reset. |

Notifications:

| Name | Trigger |
| --- | --- |
| `notification.requested` | Socket command asked cmux to create a notification. |
| `notification.clear_requested` | Socket command asked cmux to clear notifications. |
| `notification.dismiss_requested` | Socket command asked cmux to remove one notification or already-read notifications. |
| `notification.mark_read_requested` | Socket command asked cmux to mark notifications read. |
| `notification.open_requested` | Socket command asked cmux to open a notification by id. |
| `notification.jump_to_unread_requested` | Socket command asked cmux to jump to the latest unread notification. |
| `notification.created` | Notification store created a notification. |
| `notification.read` | Notification was marked read. |
| `notification.removed` | One notification was removed. |
| `notification.cleared` | Notifications were cleared in bulk. |

Feed and agent hooks:

| Name | Trigger |
| --- | --- |
| `feed.item.received` | `feed.push` received a hook/workstream event. |
| `feed.item.completed` | `feed.push` returned a hook decision, timeout, or no-op result. |
| `feed.item.resolved` | A Feed reply command resolved a permission, question, or plan item. |
| `agent.hook.<HookEventName>` | Agent hook event received through Feed. Examples include Claude Code and Codex permission requests when their hooks are installed. |

App, browser, and config:

| Name | Trigger |
| --- | --- |
| `app.focus_override.changed` | Test/debug focus override changed. |
| `app.simulated_active` | Test/debug app-active event simulated. |
| `browser.navigation` | Browser navigation command completed. |
| `browser.interaction` | Browser click, hover, scroll, key, select, or focus command completed. |
| `browser.input` | Browser type/fill command completed. Input value is redacted. |
| `config.reloaded` | Configuration reload requested through the v1 socket API. |

## Agent hooks

Agent integrations use `cmux hooks feed --source <agent>` or an equivalent
plugin bridge. The event stream publishes both agent and Feed events:

```json
{
  "name": "agent.hook.PermissionRequest",
  "category": "agent",
  "source": "codex",
  "workspace_id": "9B6920C1-6C29-4C27-A069-78CF285F932A",
  "payload": {
    "session_id": "session-123",
    "hook_event_name": "PermissionRequest",
    "_source": "codex",
    "tool_name": "exec_command",
    "_opencode_request_id": "request-456",
    "phase": "received"
  }
}
```

The `feed.item.completed` event contains the same workstream payload plus a
`result` object matching the `feed.push` socket response.

## Privacy

`surface.input_sent`, `browser.input`, v1 terminal send commands, notification
text fields, and large agent-hook fields redact local text and include only
length metadata. Feed and agent-hook events keep operational identifiers such as
hook name, tool name, request id, phase, and decision result so local consumers
can correlate events without receiving prompt/tool payloads by default.

Consumers should treat the stream as local-sensitive data and avoid forwarding
it to third-party services without an explicit user opt-in.
