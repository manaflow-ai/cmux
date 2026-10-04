# SSH Terminal (sample third-party backend)

A sample app from an outside publisher (`example/ssh-terminal`, unverified
tier) that brings its own terminal backend: plain SSH to any host that runs an
SSH server. The far host runs no cmux. The app implements
`cmux.terminal.backend/1` in bytes mode for kind `ssh`. Its purpose is to
prove that the public interface works for an outside author, and to find
where it does not (see "Interface gaps").

Plan: `plans/cmux-next/cloud-app.md` (package C3) and
`plans/cmux-next/ghostty-next-switch.md` section 3.

## What it proves

- An app outside the cmux tree implements the backend trait with no cmux
  crate at run time. The trait is a local mirror (`server/src/iface.rs`) of the
  shape that the ghostty-next lead chose; the cmux Cloud app server uses the
  same mirror. Both swap to the real crate the same way when it lands.
- Bytes mode is enough for a plain shell: the backend only moves bytes. The
  local session host parses them, owns the VT state, snapshots and journal,
  and answers terminal queries (`answersQueries: false`).
- Handles, not strings (app-platform.md 12.1 V6): the app gets an opaque
  `connection` handle. The host resolves it to a host, port and user, answers
  the host key question, and signs the auth payload with the user's key. The
  app never sees a private key or a known_hosts file.

## Behavior

| Op or event | SSH mapping |
| --- | --- |
| `open {kind: "ssh", target: conn_…, grid, env.TERM?}` | resolve the handle, TCP connect, key exchange, host key check, public key auth through the credential handle, session channel, PTY request (grid), shell |
| `write {seq, bytes}` | channel data, in `seq` order (out-of-order chunks wait, at most 256; a used seq is refused) |
| `resize {cols, rows}` | `window-change` |
| `signal` | SSH `signal` (INT, TERM, HUP, KILL) |
| `close` | channel close (`Now` also ends the SSH connection) |
| event `output` | channel data and stderr data, in order; the byte offset is the running total |
| event `exit {code}` | the server sent `exit-status` (or `exit-signal`, code empty) or closed the channel |
| event `lost` | the channel ended with no exit and no close: the transport dropped, or 3 keepalives (15 s apart) got no answer |

`command` and `cwd` in `open` are refused: this sample opens the login shell
only.

Host key check: mandatory. The check runs during key exchange. An unknown or
changed key ends the connection before authentication and before any
channel, so no byte reaches the shell and the credential never signs. `open`
fails with `Unavailable {reason: "host-key-unknown SHA256:…" | "host-key-changed SHA256:…", retryable: false}`.
The app never accepts a key by itself and never writes a known_hosts file. The
host asks the user and records the decision; the user then opens again. Host
certificates are refused (not supported in the sample).

## Resume

The backend keeps a session alive when the session host drops the terminal
handle without `close` (for example a session host restart while the app
server keeps running). `resume_token` is `ssh:<terminal>@<offset>`, where
offset is the next output byte the session host has not received.

- At most 64 KiB of unread output waits per terminal. When it is full, the
  backend stops reading from the SSH channel; the SSH window fills and the far
  end blocks. No byte is dropped.
- At most 64 KiB of already delivered output stays for replay. `resume` from
  an offset inside that window continues there; an older offset, a gone
  session or a second attach gives a terminal whose only event is `lost`.
- At most 16 detached sessions stay; the oldest is closed after that.
- An SSH session does not outlive the app server process. After an app server
  restart, every resume gives `lost`.

## Conformance

`server/tests/conformance.rs` holds interface vectors that use only the
interface types and a `FarEnd` trait (kind refusal, echo round trip, write
order under concurrent writers, resize, exit status, lost, close, resume).
Another backend copies the `vectors` module and implements `FarEnd` for its
own far end. The far end must run this tiny shell: a line `echo X` answers
`X\r\n`; a line `exit N` exits with status N.

The tests run an in-process SSH server (`russh` server on 127.0.0.1) inside
the test, never a real sshd and never a real host. Keys are made in memory in
the test.

## Scopes and handles

The manifest asks for no scope. It asks for a `connection` handle of kind
`ssh` and a `credential` handle of kind `ssh-key` (the host signs; the app
gets no secret). No network scope: SSH targets come only through handles.

Target shape, not in the manifest yet (it waits for app platform approval of
app-provided terminal backends):

```json
"implements": {
  "cmux.terminal.backend/1": { "server": true, "options": { "kinds": ["ssh"] } }
},
"scopes": { "terminal:backend": "Serve terminals for the SSH hosts you connect." },
"server": { "kind": "<third-party server kind>", "instances": "user", "hosts": ["local"] }
```

Registry id: `app:example/ssh-terminal/ssh`.

## Interface gaps (found by this sample)

1. No server kind for a third-party native server. `server.kind: native` is
   first-party only, and `js` does not fit a Rust SSH client. A sandboxed
   third-party server kind (or WebAssembly) is needed; until then the
   manifest has no `server` block and the crate is a library.
2. `terminal:backend` is restricted, so an unverified app can never hold it.
   An outside author needs a Verified review before a backend can run.
3. Manifest ids are `owner/name`; pane-protocol.md asks for a reverse-DNS
   namespace for third-party ops (`com.example.ssh-terminal`). The two need
   one rule.
4. `BackendError` has no typed host key refusal; the sample uses
   `Unavailable` with a reason prefix. A `HostKey {decision, fingerprint}`
   variant would let the host show its accept sheet without parsing text.
5. The connection and credential handle calls (resolve, host key decision,
   sign) have no provider-channel ops yet; `server/src/handles.rs` models
   them as traits.
6. `ByteEvent::Output` carries no offset, and `BackendCapabilities` has no
   `answers_queries`. The sample keeps offsets in the resume token and
   exports `ANSWERS_QUERIES`.
7. The mirror's `LocalId` allows 32 characters; the interface schema allows 64.
8. `ExitStatus` has no signal name for `exit-signal`.

## Build and test

`server/` is its own Cargo workspace (no cmux crate at run time; the
manifest test uses `cmux-app-manifest` by path as a dev-dependency). In this
repo, Rust runs on a Testbox:

```bash
cd samples/apps/ssh-terminal/server
cargo fmt --check && cargo clippy --locked --all-targets -- -D warnings && cargo test --locked
```

License: GPL-3.0-or-later. `russh` uses the `ring` crypto backend (Apache-2.0
AND ISC) instead of its default backend; every crate in `Cargo.lock` has a
license that GPL-3.0-or-later can include.
