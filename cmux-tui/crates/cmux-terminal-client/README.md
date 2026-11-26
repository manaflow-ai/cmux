# cmux-terminal-client

A small C ABI over `cmux-remote` for programs that embed a cmux terminal
without running the `cmux-tui` binary: the macOS TerminalBytes demo and the
iOS app. `include/cmux_terminal_client.h` is the contract; this file explains
the parts a caller has to get right.

## Two ways to connect

`cmux_terminal_client_connect` is the original demo entry point: an invitation
URI, an `iroh://` route hint inside it, a fresh device key every run, and one
terminal attached immediately.

`cmux_terminal_client_connect_route` is the app entry point. It takes the route
itself (`ws://`, `wss://`, or `iroh://`), a state directory, a device name, an
optional invitation, and an optional WireGuard tunnel. It attaches nothing; the
caller lists or creates a terminal and attaches it afterwards.

## Device identity and the state directory

`state_dir` is owned by this library. It is created `0700` and holds
`client-identity.json` (this device's X25519 key) and the daemons the device
has enrolled with, using the same `ClientIdentityStore` the `cmux-tui` sidecar
uses under `--state-dir`. Give each app installation one directory that
survives launches (on iOS, under Application Support) and never share it
between devices.

The first connect to a daemon needs an invitation. The control plane approves
it, and the daemon then knows this device key. Later connects pass a NULL
invitation: the library looks up the daemon whose remembered route matches
`route` and authenticates with the enrolled key. A route with no enrolled
daemon fails with an error that says to connect with an invitation; the caller
fetches a new invitation from the control plane and retries.

Current Cloud servers can instead return `trustedCarrier: true`. Call
`cmux_terminal_client_connect_trusted_route` only for that explicit authenticated
response. It uses the same Carrier authentication as the Mac client and requires
a live WireGuard tunnel plus a literal destination IP inside its AllowedIPs.
DNS names and routes outside the tunnel are rejected before connecting, so the
ordinary dialer's OS fallback cannot grant trust. The encrypted connection pins
the daemon key for reconnects and remembers a carrier record separately from
invitation enrollment. A missing invitation alone never enables this mode.

## Reaching a private address

A cmux Cloud machine sits on its owner's private network and opens no public
port. `cmux_wireguard_net_start` takes wg-quick text (as returned by the cmux
tunnel enrollment API with the caller's own `PrivateKey` filled in) and runs
WireGuard plus a userspace TCP stack in process, with no system interface, no
root, and no VPN entitlement. Pass the handle to `connect_route`; addresses
inside the tunnel's `AllowedIPs` are dialed through it and everything else
uses the operating system. One tunnel serves every client in the process. Free
it after the last client has disconnected.

## Raw output for an embedding renderer

The library decodes terminal frames into plain text rows by default, which is
what the demo shows. A renderer that owns its own terminal emulator (libghostty
on iOS) wants the bytes instead. Install `cmux_terminal_client_set_output_callback`
before attaching; the client then skips its local parser and delivers:

| kind | meaning |
| --- | --- |
| `SNAPSHOT` | replay bytes for a fresh parser sized `cols` x `rows`; reset the emulator first |
| `OUTPUT` | live VT bytes, in order |
| `RESIZED` | the host resized to `cols` x `rows` |
| `EXIT` | the process ended |

A resync (the daemon asks the client to start over) arrives as a new
`SNAPSHOT`. Input still goes through `cmux_terminal_client_send`; the
embedding emulator encodes keys itself, so `send_key` is unavailable in this
mode.

## Viewer-size priority

By default the terminal host sizes a shared terminal to the smallest grid among
its attached viewers, so a phone and a Mac on the same terminal both get a size
neither asked for. `cmux_terminal_client_set_viewer_size_priority(client, true)`
before attaching makes this client's size win: other viewers crop or pan
instead. The choice is fixed per attachment, like the output callback, and
every automatic reconnect repeats it. The client asks by adding
`viewer_size_priority: preferred` to the `terminal-bytes-v1` open. A daemon
without `terminal-viewer-size-priority-v1` rejects that key as
`invalid-argument`; the client then reopens once without it, keeps the
smallest-viewer behavior, and stops asking on that connection. A current daemon
in front of an older terminal host falls back the same way without an error.

## Terminal catalog

`cmux_terminal_client_list_terminals` and `cmux_terminal_client_create_terminal`
speak `cmux.protocol/2` to the daemon over its mux control service, the same
operations the `cmux-tui` CLI sends through the sidecar's local socket. They
return the operation's JSON result. Create uses `workspace.create` with
`initial_content: terminal`, so one call yields a workspace and a terminal.

`cmux_terminal_client_create_terminal_in_workspace` adds a terminal to a
workspace that already exists. It sends `tab.create_terminal` with only the
`workspace` selector, and the daemon puts the new tab in that workspace's
focused pane (the active pane of its active screen) and selects it there, the
way opening a tab in the TUI does; a workspace with no screen gets a new screen
and pane. The session's focused workspace does not move. The result is the same
`MutationResult` shape as create, so `value.terminal_id` is the id to attach.
The workspace must be named by its opaque `ws_` id. The library rejects a name
or `current` before sending anything, because the daemon would otherwise
resolve it as a selector and could pick a different workspace.

`cmux_terminal_client_session_snapshot` returns `session.snapshot`: every
workspace, screen, pane, tab, and terminal in one result. `terminal.list` has no
workspace, so a caller that groups terminals by workspace follows the snapshot's
links instead: a terminal's `tab_id`, the tab's `pane_id`, the pane's
`screen_id`, then the screen's `workspace_id`.

## Threads

Callbacks run on library worker threads and are serialized. The output
callback's registration is held across its invocation, so clearing the
callback waits for an in-flight call and the embedder can release its context
as soon as the clearing call returns; the callback itself must not clear or
replace the registration, which would deadlock on it. UI code must hop to its
main actor, which also keeps it clear of that rule. `disconnect` and
`cmux_wireguard_net_free` return immediately and finish teardown on a
background thread.
