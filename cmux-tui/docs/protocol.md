# Raw control protocol v12

This is the private implementation interface for cmux frontends and
compatibility adapters. New applications should use the public resource API,
not this socket protocol:
[`cmux.protocol/2`](../spec/resource-api-v2.md), the
[noun-first CLI](../spec/cli.md), or a [handwritten SDK](../spec/bindings.md).
High-level packages expose protocol v12 only through their `raw` namespace.

Protocol v12 and resource API v2 are separate version domains. They use
different messages, identifiers, and negotiation. A resource API client does
not connect to this socket directly, and a raw client does not become a
resource API client by reporting `protocol: 12`.

As of protocol v12, every server speaks JSON Lines over a Unix domain socket. Send one JSON object per line. Every request receives one response line. `subscribe` and `attach-surface` also push event lines on the same connection.

Remote clients can carry the same JSON-lines stream through `cmux relay --session <name>`. The relay copies stdio to an existing local session socket and is commonly launched with `ssh -T`; it performs no authentication or command decoding itself. Client internals consume complete JSON messages, so WebSocket text frames and future framed transports can reuse the same remote-session implementation. See the [transport contract](../spec/transports.md#relay-stdio).

PTY relay clients must use the `pty_error` contract and terminal lookup rule in
[transports.md](../spec/transports.md#pty-lifecycle-errors-and-terminal_gone).
`terminal_gone` is definitive only after a successful workspace listing proves
that the requested resource is absent. A closed or saturated control connection
is not proof that the terminal is gone; retry only after a new authenticated
transport generation is established.

For shell use, prefer the noun-first public CLI, such as
`cmux workspace list --json`.

Default socket path:

```text
$TMPDIR/cmux-tui-<uid>/<session>.sock
```

`identify` reports the protocol version:

```json
{"id":1,"cmd":"identify"}
{"id":1,"ok":true,"data":{"app":"cmux-tui","version":"...","protocol":12,"capabilities":["attach-initial-size","workspace-registry-v1","daemon-handoff-force-v1","browser-provider-v1","browser-pointer-frame-guard-v1","viewport-splits-v1","viewport-column-resize-v1","layout-undo-v1","clear-history-v1","surface-subscribe-filter","view-attachment-lease-v1","view-attachment-detach-v1","shared-sizing-v1","creation-receipts-v1","creation-attempt-keys-v1","creation-selector-fallbacks-v1","provider-managed-workspace-authority-v2","machine-listening-tcp-v1","server-stats-v1","terminal-idle-close-v1","clear-history-key-v1"],"session":"main","pid":12345}}
```

Responses have this shape. The second example is a failed `clear-history` request:

```json
{"id":1,"ok":true,"data":{}}
{"id":2,"ok":false,"error":"unknown surface 99","error_delivery":"known-not-delivered"}
```

Bad JSON returns `ok:false` with no request id.

## Command Contract

The complete command schemas live in
[`spec/commands.md`](../spec/commands.md), event schemas and stream scoping in
[`spec/events.md`](../spec/events.md), and framing, state-path, and security
rules in [`spec/transports.md`](../spec/transports.md). This guide illustrates
common flows rather than duplicating the exhaustive command list.

Clients must require the `clear-history-v1` capability before sending `clear-history` to a protocol-v9 server.

Clients may include the structured `fallback_key` defined in `spec/commands.md` only when `identify` also advertises `clear-history-key-v1`. The server clears a primary screen without using the fallback. On an alternate screen it leaves both screens intact and encodes the fallback with the authoritative terminal keyboard modes.

Failed `clear-history` responses add `error_delivery`. `known-not-delivered` proves that no clear or fallback input reached the terminal. `ambiguous` means delivery may have started. Missing or unknown values must be treated as ambiguous.

`provider-managed-workspace-authority-v2` means the mux was provider-locked before its first control client and accepts private mirror commits only with its pre-provisioned authority. `mark-workspaces-provider-managed` validates that authority without changing ownership. Ordinary `close-workspace` and `rename-workspace` requests always fail on that mux. The provider-aware TUI sends an authorized `close-provider-managed-workspace` or `rename-provider-managed-workspace` only after the external provider accepts the corresponding lifecycle request. Provider-aware clients must refuse provider-owned mode when the server does not advertise this capability.

`browser-provider-v1` means browser tabs are attach-only: cmux-tui waits for cmux-browser to publish a connection-scoped loopback CDP endpoint and a target keyed by the tab's stable public id. It never discovers or launches an isolated Chrome process and never closes a provider-owned target. Endpoints and targets are available only to trusted-local `register-browser-provider` and `get-browser-provider` callers. Optional bearer credentials are accepted only during registration and are never returned. Multiple renderer clients may attach independently; presentation focus and scroll remain client-local. Provider disconnects leave canonical topology intact and reattach when a replacement lease appears.

cmux-browser starts the helper with its private agent-browser provider mode. New terminals use isolated upstream agent-browser daemon sessions; the `agent-browser.plugin.v1` adapter resolves the caller's containing workspace from its stable terminal id and returns one page-scoped provider target. This adapter is a control-plane bridge only—snapshotting, refs, actions, and policy remain upstream agent-browser behavior. It rejects bearer CDP leases because the current upstream direct-page provider response has no WebSocket-header field.

`browser-pointer-frame-guard-v1` means browser attach state and frame events report authoritative `pointer_frame_seq` and `pointer_frame_floor_seq`, and the server accepts `browser-frame-presented`, `browser-mouse-guarded`, and `browser-wheel-guarded`. Each admitted bitmap receives a new pointer sequence even when its document and dimensions match the previous bitmap. The reported floor through latest range proves only that a token belongs to the current document and coordinate mapping. `browser-frame-presented` advances one exact acknowledged token for that connection, and only that token authorizes a new guarded pointer action. A guarded pointer command also acknowledges its own token, so a dropped presentation message cannot strand input. Each connection retains one acknowledged token, while the browser input queue bounds actions admitted before a later presentation. Navigation or geometry changes reset the range and all acknowledgements. An accepted press keeps its original guard for motion across ordinary repaints while document and geometry remain valid; invalidation suppresses further motion but retains its balancing release. A remote TUI sends the same capability in `set-client-info`; the server permits browser attach only when both peers advertise it. Clients and servers that omit it remain compatible for PTY surfaces. The legacy `browser-mouse` and `browser-wheel` JSON schemas still accept an omitted or null guard, but a guarded server rejects those requests before surface lookup instead of interpreting the current frame as authority.

`viewport-splits-v1` adds `new-pane-right` and a `viewport_splits` array to screen snapshots that use horizontal viewport columns. Each entry identifies a stable split id and gives the right child's width as a fraction of the frontend viewport. Frontends that implement it render the existing tree at one viewport width, append the marked right child, and expose horizontal viewport movement. Ordinary screen snapshots omit this viewport-only metadata. Other clients can ignore it and use the split ratio.

`viewport-column-resize-v1` adds `set-viewport-pane-width` and `viewport_base_width`. Widths remain frontend-relative, from 0.1 through 1.0. Clients must require this capability before sending the resize command. An older server still renders the fallback split ratios and rejects the unknown command without changing layout. Invalid widths return `error_code:"viewport-width-out-of-range"`; a missing or ordinary pane returns `error_code:"viewport-column-not-found"`.

`layout-undo-v1` adds server-owned structural layout history and `undo-layout`. A creation undo first returns `confirmation_required`, the pane ids it would close, and a unique confirmation revision bound to those panes' exact tab membership. The client must show that consequence and resend the exact revision with `confirm_close:true`. A stale revision or changed tab membership fails without closing a pane; request a new preview before retrying. Resize-only and other non-destructive entries undo in one request.

`move-tab` moves a surface to a target pane and insertion index. It supports same-pane reorder and cross-pane moves.

```json
{"id":10,"cmd":"move-tab","surface":4,"pane":2,"index":0}
```

`move-workspace` moves a workspace to a zero-based insertion index. When moving
right, the final index is one less than the requested insertion index because
the source workspace is removed first.

```json
{"id":11,"cmd":"move-workspace","workspace":3,"index":0}
```

`workspace-groups-v1` adds durable sidebar groups. `list-workspaces` gains an
ordered top-level `groups` array (`{id,name,color,collapsed,index}`) and a
`group` field on each workspace. `create-workspace-group`,
`update-workspace-group`, `delete-workspace-group`, and `move-workspace-group`
edit groups and emit `tree-changed`. `move-workspace-to-group` sets membership
and an optional final index inside the section in one workspace-registry
revision, so it takes the durable mutation envelope and emits
`workspace-moved`:

```json
{"id":13,"cmd":"create-workspace-group","group":"agents","name":"Agents","color":"gray"}
{"id":14,"cmd":"move-workspace-to-group","key":"6ba7b810-9dad-41d1-80b4-00c04fd430c8","group":"agents","index":0,"origin":"mac-1","mutation_id":"m-41"}
```

`workspace-metadata-v1` adds shared workspace presentation: `color` (a
frontend palette token or `#RRGGBB[AA]`), `icon` (an SF Symbol name), and a
custom `title` on every workspace. `set-workspace-metadata` treats an absent
field as unchanged and `null` as clear, commits one workspace-registry
revision, and emits `workspace-changed` with the full workspace entity.

`tab-metadata-v1` adds `pinned`, `cwd`, `git_branch`, and `git_detached` to
every tab. `set-tab-pinned` pins a tab; pinned tabs sort first, and
`move-tab` keeps them ahead of unpinned tabs. The daemon resolves `cwd` from
OSC 7 (or the launch directory) and reads the repository's HEAD on the host
that owns the PTY, so remote daemons report their own branches. `tab-changed`
delivers the refreshed tab after a pin or directory change.

Protocol-v8 split nodes serialize as `{type:"split",split:<id>,dir,ratio,a,b}`. The `split` value remains stable until that node collapses. Resize an exact divider with:

```json
{"id":12,"cmd":"set-split-ratio","split":9,"ratio":0.65}
```

Ratios are clamped to `0.05..0.95`. A live split in a horizontal viewport can still imply a column width outside the supported `0.1..1.0` range. The server rejects that request with `error_code:"layout-ratio-out-of-range"` and keeps the split and layout unchanged; `layout-ratio-target-missing` is reserved for an absent pane or split.

`frontend-browser-tabs-v1` adds browser tabs whose page the frontend
renders with WebKit or CEF. `new-frontend-browser-tab` creates one in the
durable tree with `url`, `engine`, and optional `title`, `favicon_url`, and
`profile_id`; `update-frontend-browser-tab` records navigation. The daemon
persists and restores these tabs but never attaches a CDP target or renders
frames for them, and `attach-surface` refuses them. Tabs report
`browser_renderer:"frontend"` and `browser_engine`. CDP browser tabs keep
their existing behavior and report `browser_renderer:"daemon"`.

`tab-drag-v1` makes every tab drag outcome one atomic command:
`move-tab` (pane and index, across screens and workspaces),
`move-tab-to-split` (pane edge), `move-tab-to-column` (new niri column),
`move-tab-to-workspace`, and `move-tab-to-new-workspace` (optional group and
index; returns the new workspace). Each takes an optional client
`transaction`, echoed in the moved tab's `tab-changed` delta. Drags that stay
on one screen and keep their source pane record a layout-undo entry that
moves the tab back without closing anything:

```json
{"id":15,"cmd":"move-tab-to-split","surface":4,"pane":2,"edge":"right","transaction":"drop-9"}
{"id":16,"cmd":"undo-layout","pane":2}
```

`notification-ack-v1` decouples notification acknowledgement from focus.
`ack-tab-notifications {surface}` clears a tab's unread marker and records the
acknowledgement durably, so it survives a daemon restart; frontends call it
when the user has seen the tab instead of sending `select-tab`.
`list-notifications` returns the retained ledger with `created_at_ms` and an
`acknowledged` flag, and each workspace reports `unread_count`.

`tab-groups-v1` adds Chrome-style tab groups inside a pane's strip. Panes
report `tab_groups` (id, name, color, collapsed, saved id, start, count,
surfaces) and tabs report `group`. Members stay contiguous. Every change is
one command: `create-tab-group`, `update-tab-group` (rename, recolor,
collapse), `add-tabs-to-tab-group`, `remove-tabs-from-tab-group`,
`move-tab-group` (within or across strips), `move-tab-group-to-split`,
`move-tab-group-to-column`, `move-tab-group-to-new-workspace`,
`ungroup-tab-group`, and `close-tab-group`. Commands that move tabs take a
`transaction` echoed in each member's `tab-changed`.

`saved-tab-groups-v1` adds saved groups that outlive their placements:
`save-tab-group`, `unsave-tab-group`, `delete-saved-tab-group`,
`list-saved-tab-groups`, and `reopen-saved-tab-group`, which reattaches
running terminals and starts the rest in their saved directories.

```json
{"id":17,"cmd":"create-tab-group","surfaces":[4,7],"name":"agents","color":"green","transaction":"g-1"}
{"id":18,"cmd":"move-tab-group-to-split","group":"tgrp_0d4c...","pane":2,"edge":"right"}
```

`terminal-env-v1` lets `new-tab`, `split`, and `create-terminal` carry an
`env` object for the new terminal's child only, so a frontend can pass the
user's login-shell environment to a daemon that started with a minimal
launchd environment:

```json
{"id":19,"cmd":"new-tab","pane":2,"cwd":"/Users/me/src","env":{"PATH":"/opt/homebrew/bin:/usr/bin:/bin"}}
```

`loopback-forward-v1` gives an opted-in Unix client TCP streams to this
machine's loopback services (browser tabs whose machine is this daemon), with
credit flow control in both directions. See "Loopback forwarding" in
`spec/commands.md` for the full contract:

```json
{"id":21,"cmd":"set-client-info","capabilities":["loopback-forward-v1"]}
{"id":22,"cmd":"loopback-open","stream":1,"host":"localhost","port":5173}
{"id":22,"ok":true,"data":{"stream":1,"address":"127.0.0.1:5173","window":262144}}
{"cmd":"loopback-data","stream":1,"data":"R0VUIC8gSFRUUC8xLjENCg0K"}
{"event":"loopback-data","stream":1,"data":"SFRUUC8xLjEgMjAwIE9LDQo="}
```

`terminal-placement-env-v1` adds a caller-chosen `terminal_id` to `new-tab`,
`split`, `new-pane`, and `new-pane-right` (and `cwd`/`env` to the last two),
so the child starts with its own id in its environment:

```json
{"id":20,"cmd":"new-pane-right","pane":2,"width":0.5,"terminal_id":"3f0c2d9e8b1a4c7d9e2f1a0b3c4d5e6f","env":{"CMUX_SURFACE_ID":"3f0c2d9e8b1a4c7d9e2f1a0b3c4d5e6f"}}
{"id":20,"ok":true,"data":{"surface":9,"terminal_id":"3f0c2d9e8b1a4c7d9e2f1a0b3c4d5e6f","terminal_incarnation":"..."}}
```

## Events

`subscribe` starts event streaming:

```json
{"id":20,"cmd":"subscribe"}
```

Response data is `{}`. Future event lines may interleave with responses.

Subscribed event lines are:

```json
{"event":"surface-output","surface":4}
{"event":"surface-resized","surface":4,"cols":120,"rows":40,"reservation_id":7}
{"event":"surface-resize-failed","surface":4,"cols":120,"rows":40,"error":"browser is not responding","retry_after_ms":250,"reservation_id":7}
{"event":"surface-exited","surface":4}
{"event":"title-changed","surface":4,"title":"build logs"}
{"event":"bell","surface":4}
{"event":"tree-changed"}
{"event":"empty"}
```

`surface-resized` reports the final clamped cell size and is emitted only when the surface size actually changes. `surface-resize-failed` reports an asynchronous browser resize failure and the delay before an automatic retry, or `null` after retries are exhausted. Browser resize completions repeat the numeric `reservation_id` returned by the accepted request so clients can ignore stale completions.

Protocol v7 and newer `title-changed` events carry the authoritative current `title`. Slow subscribers coalesce repeated pending title changes per surface to the latest value.

Browser input, navigation, activation, and browser reconfigure work from `resize-surface` enqueue per-surface CDP work. Protocol v7 and newer `resize-surface` responses include `data.accepted` and `data.reservation_id`; `true` means the resize was applied or queued, and `false` means it was already satisfied, pending, or waiting for its retry backoff. Completion arrives as `surface-resized`, and asynchronous failure arrives as `surface-resize-failed`. Two consecutive CDP call timeouts mark only that browser surface failed with `browser is not responding`.

## Attach Surface

`attach-surface` streams a PTY or browser surface.

```json
{"id":30,"cmd":"attach-surface","surface":4,"cols":120,"rows":40}
```

The server first sends:

```json
{"event":"vt-state","surface":4,"cols":120,"rows":40,"data":"<base64-vt-replay>"}
```

If this connection negotiated `view-attachment-lease-v1`, the later command
response contains `data.lease`. The lease addresses this exact attach stream.
Use it with `resize-attached-view` and `release-attached-view-size`. With
`view-attachment-detach-v1`, `detach-attached-view` closes only that stream and
releases its size contribution.

Terminals keep running after every view detaches. When `identify` advertises
`terminal-idle-close-v1`, a client can bound that with
`set-terminal-idle-policy`: `{"cmd":"set-terminal-idle-policy","surface":4,"idle_close_seconds":86400}`
stores a durable per-terminal policy (a `terminal_id` may name the terminal
instead of `surface`, and `null` clears the policy so the terminal is never
closed for idleness). The owner closes the terminal, through the same path as
`close-terminal`, once it has had no attach stream on any of its views for
that long. The idle clock restarts at every attach and when the owner restarts,
so a restart can delay a close but never make it early.

When `identify` advertises `terminal-reap-v1`, the owner also ends a terminal
that has had no tab placement for the reap grace period and emits
`terminal-reaped`, but only when the owner was started with
`--terminal-reap-grace-seconds` (reaping is opt-in). Mark a
terminal that must outlive its tabs with
`{"cmd":"set-terminal-keep","terminal_id":"term_...","keep":true}` or pass
`"keep":true` to `new-tab`, `split`, or `create-terminal`. A close commits and
updates the tree before its host exits; hosts of closed terminals end in
parallel. For test teardown, `shutdown-daemon` with `"end_terminals":true`
ends every terminal before the handoff. To close many tabs at once, send
`{"cmd":"close-tabs","surfaces":[...],"end_terminals":true}`: one durable
commit (one journal fsync) removes every tab and ends every terminal left
with no view that is not kept. The container closes take the same
`end_terminals` field.

Then it sends ordered stream frames:

```json
{"event":"output","surface":4,"data":"<base64-pty-bytes>"}
{"event":"resized","surface":4,"cols":132,"rows":43,"replay":"<base64-vt-replay>"}
```

The `resized` attach frame carries the new cell size and a fresh VT replay captured at that size. It is delivered in the same attach stream as output frames, so a client can reset its local terminal, apply the replay, and continue consuming later output in order.

For browser surfaces, the server first sends `browser-state` with URL, title, size, status, stalled-frame state, `pointer_frame_seq`, and the latest PNG frame if one exists. A null pointer sequence keeps the retained image renderable but blocks pointer input. Later updates send `browser-state` and `frame` events. Each frame event couples the PNG with its authoritative `status`, `error`, and `pointer_frame_seq`; that sequence changes with every admitted replacement but authorizes input only after the client acknowledges presenting it. Clients must not infer pointer admission from the image sequence. Frame payloads are base64 PNG data and slow clients skip older frames rather than buffering unboundedly.

When the stream ends, it sends:

```json
{"event":"detached","surface":4}
```

A server-initiated detach adds `reason` (`network`, `disconnected-by` with
`by`, or `host-shutdown`). Do not reconnect automatically after
`disconnected-by`.

## Shared Terminal Sizing

`shared-sizing-v1` means terminals use the shared sizing reducer of
[`docs/shared-terminal-sizing.md`](../../docs/shared-terminal-sizing.md): by
default ("Fit everyone") the grid is the smallest attached viewport, and an
owner that leaves hands the grid to the next owner. A client opts in to the new events by sending the
same capability in `set-client-info`, together with its identity:

```json
{"id":3,"cmd":"set-client-info","name":"mirror","kind":"mac","capabilities":["shared-sizing-v1"],"user_id":"u_maya","display_name":"Maya","device_kind":"mac","device_name":"Mac Studio"}
```

It then receives `size-state` events, `participant` and `size_state` in terminal
`attach-surface` responses, and can use `set-size-policy`, `set-size-counts`,
`get-size-state`, `note-size-activity` (with `view`, a relay credits
forwarded input to that sub-view), relay sub-views (`resize-attached-view`
with `view` and `identity`), and `detach-client` with a participant id and
`by`. `user_id` is
asserted by the client; the daemon does not verify it. The cmux-tui frontend
opts in with `device_kind: "tui"` and its hostname as `device_name`. See
[`spec/commands.md`](../spec/commands.md#sizing).

## Client Compatibility

The remote TUI requires protocol v12. It rejects protocol-v11 servers because v12 adds lifecycle readiness to the strict identify response. Protocol v11 changed terminal placement nullability, terminal identity nullability, lifecycle typing, typed terminal exit records, and renderer minting responses. Protocol-v12 servers without `browser-pointer-frame-guard-v1` remain compatible for PTY surfaces, but the remote TUI rejects browser attachment because it cannot route browser pointer input safely. Every bundled client that opens a long-lived `attach-surface` socket sends `set-client-info` with `browser-pointer-frame-guard-v1` on that same connection before attaching a browser surface, because capability state and guarded-client pointer captures are scoped to the connection. Legacy one-shot pointer commands retain owner zero so a down/move/up sequence can remain compatible across short-lived sockets.

Existing `set-ratio` clients remain source-compatible and the server keeps the pane-and-direction command unchanged. Protocol-v8 and newer frontends should read `layout.split` and send `set-split-ratio` so nested same-direction dividers are addressed exactly. Protocol v9 adds stack layout nodes and `new-pane`; clients must not send `new-pane` to a protocol-v8 server. Protocol v10 requires `surface` on every `set-client-sizing` request and moves `size_participating` into each `list-clients.sizes` entry.

Attach clients mirror PTY surfaces locally. After `identify` advertises `attach-initial-size`, a client can include paired `cols` and `rows` in `attach-surface`, so the server records its initial size claim before capturing the first VT replay or render state. Older servers that omit the capability must receive neither field. Bundled long-lived clients echo `view-attachment-lease-v1` and `view-attachment-detach-v1` through `set-client-info`; against older servers, they close the transport when a raced attach must be abandoned because transport teardown is the only cleanup fence.

When several clients display one terminal, their size reports are passive
viewport hints until one exact client and terminal view claim geometry
authority. Only that owner can resize the canonical PTY grid; every other view
crops, pans, or scales it locally. Releasing or disconnecting the owner, or a
refused owner resize, fences the old owner and freezes the current grid. A
replacement report and claim must come from a newly attached client; the core
server does not elect a survivor across sockets because the wire contract has
no generation token for that hand-off.
Browser surfaces retain the legacy smallest-participating-size reducer because
each browser has one live tab. A client releases its report when that view
becomes hidden. Input and mux-driven redraws never claim geometry or reassert an
idle viewport. See the canonical [`Sizing`](../spec/commands.md#sizing)
contract.

Provider-aware clients require `provider-managed-workspace-authority-v2` before exposing provider-owned workspace lifecycle controls. The server starts with provider ownership fixed for that mux generation, including during temporary provider descriptor gaps, so an older or stale client cannot reopen ordinary rename or close paths.

## Browser Limitations

Browser surfaces appear in `list-workspaces` as `kind: "browser"` with `browser_source: "external"` once live, plus additive `browser_status`, `browser_error`, `browser_frames_stalled`, and `url` fields. Canonical screen snapshots may also carry explicit viewport `columns`; focus and horizontal scroll are frontend-local. PTY and VT commands against browser surfaces return errors.
