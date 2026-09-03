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

## Terminal catalog

`cmux_terminal_client_list_terminals` and `cmux_terminal_client_create_terminal`
speak `cmux.protocol/2` to the daemon over its mux control service, the same
operations the `cmux-tui` CLI sends through the sidecar's local socket. They
return the operation's JSON result. Create uses `workspace.create` with
`initial_content: terminal`, so one call yields a workspace and a terminal.

## Threads

Callbacks run on library worker threads and are serialized. The output
callback is invoked with no client lock held, so it may call back into the
library. UI code must hop to its main actor. `disconnect` and
`cmux_wireguard_net_free` return immediately and finish teardown on a
background thread.
