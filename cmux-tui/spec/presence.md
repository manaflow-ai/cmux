# Presence

Presence is the "look here" signal between people attached to one session: a
pointer and a highlight per connection, on one surface at a time. It exists so
a teammate can point at a line in a terminal or a spot in a browser while
talking. It is not focus, not selection, and not input.

## Invariants

1. Presence is ephemeral. It is never written to the session journal, a daemon
   restart forgets it, and `session.journal.subscribe` never carries it.
2. The daemon stores only the latest state per connection. Delivery on the
   subscribe stream is coalesced per client, so a slow subscriber sees the
   newest pointer, never a backlog of intermediate ones.
3. A disconnect, `presence-clear`, or the exit of the pointed-at surface emits
   one `presence-changed` with `surface:null`. Frontends remove every overlay
   for that client on such an event.
4. Anchors are surface coordinates, never pixels. `cell` is a terminal grid
   cell plus the publisher's `scroll_offset`: how many rows the publisher's viewport sits above the live bottom (0 when at the bottom). A viewer at offset `V` draws the cell on row `row + V - scroll_offset` and hides it when that falls outside the grid. `point` is a browser or
   display point in CSS/document pixels. Frontends own the mapping to their
   own viewport and may hide an anchor they cannot place.
5. The daemon validates that the surface is alive and nothing else. It does
   not require the publisher to be attached to the surface, because a control
   link and a viewer can be separate connections.
6. Identity is the connection: `client`, plus the `set-client-info` labels
   `name` and `kind`, plus a daemon-assigned `color` slot. Authenticated actor
   identity is a separate, later contract; until then labels are self-asserted.
7. Limits: 240 updates per second per connection, 256 connections holding
   presence, and a 60 second idle drop for pointers without a `pin` highlight.

## State ownership

| State | Owner | Lifetime and responsibility |
| --- | --- | --- |
| Current pointer, highlight, generation, color | Daemon presence hub | One latest entry per connection; coalesces delivery and clears on disconnect, surface exit, or explicit clear. Never journaled. |
| Local desired pointer and pending publication | `CloudPresenceLink` | One presence-only connection per cloud machine. Sends at most 30 pointer updates per second, flushes the final position, reconnects, and republishes desired state. |
| Local pane to remote surface mapping and received entries | `CloudPresenceStore` | Registers cloud panes, owns their machine links, filters entries by surface, and drops cached entries when the connection ends. |
| Cell size, padding, visible rows, scroll offset | Ghostty terminal surface | Authoritative renderer metrics in logical points. The terminal view uses the same geometry for publishing cells and placing overlays. |
| Cursor pixels, name pill, highlight fading | `CloudPresenceOverlayView` | Click-through view above the terminal. Uses the shared Computer Use cursor artwork; it never owns terminal input or selection. |
| Display name | Connection's `set-client-info` label | Self-asserted presentation metadata, not authenticated identity or access control. |

`CloudPresenceLink` is the Mac's transport adapter to the daemon presence hub.
It does not attach a terminal or stream terminal output. The store owns its
lifetime: the first pane on a machine creates the link and the last pane closing
stops it.

## Wire

| Item | Name |
| --- | --- |
| capability | `presence-v1` |
| commands | `presence-update`, `presence-clear`, `presence-list`; `subscribe` with `presence_only:true` |
| event | `presence-changed` on the subscribe stream |

Command and payload shapes are normative in [`commands.md`](commands.md) and
[`events.md`](events.md); types are in `sdk-schema.json`.

## Rendering guidance

- `laser` highlights fade after about two seconds on the viewer's side.
- `pin` highlights stay until the publisher clears or disconnects.
- Hide a pointer whose `updated_at_ms` is older than a few seconds; the daemon
  keeps it for late joiners but a resting pointer is noise.
- A `cell` anchor is visible only when the viewer's scrollback offset places
  that row on screen; compare `scroll_offset` to the local viewport.
