# SSH Terminal (sample third-party backend)

A sample app that acts as an outside publisher (`manaflow-ai/ssh-terminal`: the
publisher is not `cmux`, so it gets the unverified tier; we own the GitHub owner)
that brings its own terminal backend: plain SSH to any host that runs an SSH
server. The far host runs no cmux. The app implements `cmux.terminal.backend/1`
in bytes mode for kind `ssh`, over the channel that the host opens for it
(`connection.channel.*`, coordinator decision 8). Its purpose is to prove that
the public interface works for an outside author, and to find where it does not
(see "Interface gaps").

Plan: `plans/cmux-next/cloud-app.md` (package C3) and
`plans/cmux-next/ghostty-next-switch.md` sections 3.3 to 3.5. Interface:
`cmux-tui/crates/cmux-app-host/interfaces/cmux.terminal.backend/1.json`.

## What it proves

- An app outside the cmux tree implements the backend trait with no cmux
  crate at run time and no SSH crate at all. The trait and the host ops are a
  local mirror (`server/src/iface.rs`) of the landed JSON. The cmux Cloud
  rescue shell (cloud-app.md 3.4, package C2) copies the same mirror, so both
  swap to the real crate the same way when it lands.
- The host owns the SSH transport. The app passes an opaque `connection`
  handle and the host's `open_token` to `connection.channel.open`. The host
  dials, checks the host key the user pinned, authenticates with the user's
  key and gives back a channel id. The app never sees a host name, a key, a
  known_hosts file or a signature, and the interface has no signing op.
- Bytes mode is enough for a plain shell: the backend only moves bytes. The
  local session host parses them, owns the VT state, snapshots and journal,
  and answers terminal queries (`capabilities.answers_queries: false`).
- The backend keeps the interface's ordering and flow rules on top of the
  channel: input in `seq` order, resize and signal behind the input before
  them, contiguous output offsets, bounded buffers, and no call that waits.

## Behavior

| Backend op or event | Host channel mapping |
| --- | --- |
| `open {kind: "ssh", target: conn_…, open_token, grid, env.TERM?, command?}` | `connection.channel.open {connection: target, open_token, pty: {term, cols, rows}, command}`. `term` is `env.TERM` or `xterm-256color` |
| `write {seq, bytes}` | channel data, in `seq` order (out-of-order chunks wait, at most 256 ahead; a used seq is refused) |
| `resize {cols, rows}` | `connection.channel.resize`, after the input accepted before it. A host refusal is dropped; the shell keeps running |
| `signal` | `connection.channel.signal` (INT, TERM, HUP, KILL), after the input accepted before it. A host refusal is dropped; the shell keeps running |
| `close` | `connection.channel.close`. `Graceful` first sends the input the host takes now; `Now` drops unsent input. Output after close is discarded |
| event `output {offset, bytes}` | channel data; `offset` is the running byte total after the chunk |
| event `exit {code?, signal?, core_dumped, message?}` | the channel ended with an exit status or exit signal; `message` is cut to 4 KiB |
| event `lost {reason, retryable}` | the channel dropped with no exit (the host's `reason`, cut to 4 KiB, and `retryable`), or sending input failed for good (`retryable: false`) |

`cwd` in `open` is `unsupported`: `connection.channel.open` has no cwd. Other
`env` entries than `TERM` are not sent (the host op has no env field).

Errors pass through unchanged: an unknown or changed host key is
`hostKey {decision: unknown|changed, fingerprint: "SHA256:…"}` from the host,
and no channel exists, so no byte reached the shell and no event follows. The
host shows its accept sheet; the user opens again with a new `open_token`. A
missing, unknown or reused `open_token` and an unknown or revoked handle are
`denied` from the host. A kind other than `ssh` is `denied` before any host op.
A call on a terminal that is closed, exited or lost is `invalid`.

Flow control. No call waits. The data plane of the channel answers a full
host buffer with `unavailable {retryable: true}`; the backend keeps the
command and sends it on the next call. The backend holds at most 1 MiB of
unsent input (and 1024 commands); more is `unavailable {retryable: true}` and
changes nothing. The backend asks the host for at most the free room of its
64 KiB output buffer, so a flood waits in the host, whose own buffer and SSH
flow control stop the far end. A host that sends more than it was asked for
ends the terminal with `lost`.

The sample calls the host ops while it holds the lock of one session. That
is safe only because the `HostChannels` contract says that no op waits and no
op calls back into the backend. The real async trait must not hold a lock
across an `.await`.

Tokens: `OpenToken` and `ResumeToken` print as `..` in `Debug`, so neither
reaches a log. A resume token is a bearer credential for its session (see
gap 5).

## Resume

The backend keeps a session alive when the session host drops the terminal
handle without `close` (for example a session host restart while the app
server keeps running). `resume_token` is `ssh:<terminal>@<offset>#<nonce>`:
offset is the next output byte the session host has not received; nonce is
128 random bits per session, so a guessed token never attaches. `resume
{resume_token, open_token}` answers the terminal and the offset; output
offsets continue from there.

- At most 64 KiB of already delivered output stays for replay. `resume` from
  an offset inside that window continues there; an older offset, a gone
  session or a wrong nonce gives a terminal whose only event is
  `lost {retryable: false}`. `resume` while a terminal is attached is
  `invalid`. `resume` with an empty `open_token` is `invalid`.
- At most 16 detached sessions stay; the oldest channel is closed after that.
- A session that exited or was lost closes its channel at once.
- A channel does not outlive the app server process. After an app server
  restart, every resume gives `lost`.

## Conformance

`server/tests/conformance.rs` holds interface vectors that use only the
interface types and a `FarEnd` trait: kind refusal, `answers_queries`, echo
round trip, contiguous offsets, write order under concurrent writers, resize,
signal, exit shape, lost, close, resume at an offset, and resume from a stale
offset. Another backend (the Cloud rescue shell) copies the `vectors` module
and implements `FarEnd` for its own far end. The far end must run this tiny
shell: a line `echo X` answers `X\r\n`; `exit N` exits with status N;
`flood N` answers N KiB of output.

`server/tests/host_channel.rs` covers the SSH mapping: the handle, token and
PTY pass through unchanged, no op except the channel ops, the typed host key
refusal with no byte and no event, token reuse, the exit signal shape with a
bounded message, graceful and immediate close, a full input buffer, resize
and signal order behind buffered input, output that waits in the host, stale
handles, resume nonces, eviction and backend shutdown.

The tests run against an in-memory fake of the host ops (`tests/common`): no
network, no SSH, no key.

## Scopes and handles

The manifest asks for no scope and for one `connection` handle of kind `ssh`.
It asks for no `credential` handle: the host signs in with the user's key, so
the app needs none. No network scope: SSH targets come only through handles.

Target shape, not in the manifest yet (it waits for app platform approval of
app-provided terminal backends, a third-party server kind and the host op
scope name):

```json
"implements": {
  "cmux.terminal.backend/1": { "server": true, "options": { "kinds": ["ssh"] } }
},
"scopes": { "terminal:backend": "Serve terminals for the SSH hosts you connect." },
"server": {
  "kind": "<third-party server kind>",
  "instances": "user",
  "hosts": ["local"],
  "scopes": {
    "op:connection.channel.open": "Ask cmux to open a shell on a host you picked. cmux connects and signs in; the app never sees your key."
  }
},
"handles": { "connection": { "kinds": ["ssh"], "max": 16, "reason": "…" } }
```

Registry id: `app:manaflow-ai/ssh-terminal/ssh`.

## Interface gaps (found by this sample)

Open:

1. No server kind for a third-party native server. `server.kind: native` is
   first-party only, and `js` does not fit a Rust server. A sandboxed
   third-party server kind (or WebAssembly) is needed; until then the
   manifest has no `server` block and the crate is a library.
2. `terminal:backend` is restricted, so an unverified app can never hold it.
   An outside author needs a Verified review before a backend can run.
3. Manifest ids are `owner/name`; pane-protocol.md asks for a reverse-DNS
   namespace for third-party ops (`com.example.ssh-terminal`). The two need
   one rule.
4. The channel's data plane has no op or frame. The JSON says the channel
   carries "data in and out" and an exit status, but names only
   `connection.channel.open|resize|signal|close`. The mirror adds
   `HostChannels::send` (all or nothing, `unavailable {retryable: true}` when
   full) and `HostChannels::receive` (at most `max_bytes`, the end event once
   after the last data). The real shape should be credit based.
5. No host op takes the `open_token` of a `resume`. The JSON issues one per
   resume, but a resumed terminal reuses its open channel. The sample only
   checks that the token is present; the host cannot refuse a stale one.
6. `connection.channel.close` has no graceful form (EOF first), and the
   channel op has no `cwd` and no `env` besides `pty.term`.
7. The JSON names no error for a kind outside `options.kinds` (the sample
   uses `denied`) or for a call on a closed terminal (the sample uses
   `invalid`). `unsupported` carries no reason.
8. No host op scope name is defined for `connection.channel.*` (the target
   shape above guesses `op:connection.channel.open`).
9. The mirrored trait is synchronous and drains events with `take_events`;
   the real trait is async with a stream.
10. The JSON `open` answers `{terminal, ...}` (the backend names the
    terminal), but the plan's Rust `OpenRequest` carries the terminal id that
    the session host chose. The mirror follows the plan and keeps
    `OpenRequest.terminal`; one of the two must change.
11. `open` answers `capabilities` and `resume_token?` in the JSON; the mirror
    keeps `TerminalBackend::capabilities` and `ByteTerminal::resume_token`.

Closed by the landed interface (2026-10-04): output offsets, the typed host
key refusal, the exit signal, `answers_queries`, a 64-character `LocalId`
(`^[a-z][a-zA-Z0-9-]{0,63}$`), and the signing oracle (no signing op: the
host owns the transport).

## Build and test

`server/` is its own Cargo workspace (no cmux crate at run time; the manifest
test uses `cmux-app-manifest` by path as a dev-dependency). In this repo, Rust
runs on a Testbox:

```bash
cd samples/apps/ssh-terminal/server
cargo fmt --check && cargo clippy --locked --all-targets -- -D warnings && cargo test --locked
```

License: GPL-3.0-or-later. Every crate in `Cargo.lock` has a license that
GPL-3.0-or-later can include.
