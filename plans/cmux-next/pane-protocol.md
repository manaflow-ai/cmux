# Pane protocol: one typed, engine-neutral, forkable protocol (draft v0)

Status: draft for Leo and the coordinator. Local until the first code lands with it.
Owner: lawrence/cmuxterm-hq-48. Decisions recorded 2026-10-04 by Lawrence: schemars is the
schema source, one catalog for panes and apps, the first slice proves the whole path.

## Goals

1. Every surface (agent/ACP, diff, markdown viewer, Monaco editor, CodeMirror app) runs the same
   way in WebKit, CEF/Chromium and a plain browser.
2. Rust types are the source of truth. Clients in TS, Swift, Go and the other SDK languages are
   generated from one committed IR.
3. No chokepoint: no single process or thread carries all traffic.
4. Anyone can fork a surface (frontend) or a backend (provider), in any language, as a separate
   process, and reserve a namespace.
5. Safe to expose to a browser page: an untrusted page or provider gets only what it was granted.

## Planes

- **Control plane (the router, in the cmux-tui daemon).** Discovery, the namespace registry,
  provider admission, grants, and minting capability tokens. Small and rare messages only.
- **Data plane (direct).** A page talks directly to the provider that owns a namespace. The router
  is not on this path. Providers verify capability tokens offline (signature check, no router
  round trip), so the router can restart without breaking open streams.

Strongest objection: two planes cost more than one daemon that relays everything. Answer: a relay
makes every byte of every surface pass one process and one event loop, which is the chokepoint we
must not have; and acpmux already works as a direct data-plane provider today.

## Wire

- Encoding: UTF-8 JSON text messages. Bulk binary goes in binary frames that reference a stream id
  (below), never base64 in JSON.
- Framing: WebSocket frames for pages; on unix sockets, a 4-byte big-endian length prefix and then
  the message bytes. Max message 16 MiB; larger data uses a stream.
- Envelope (every message):
  - call: `{"t":"call","id":<u64>,"op":"<ns>.<family>.<verb>","params":{...},"cap"?:<handle>}`
  - result: `{"t":"ok","id":<u64>,"value":...}` or
    `{"t":"err","id":<u64>,"code":"<ns>.<code>","message":"...","retryable":bool,"details"?:{}}`
  - subscribe: `{"t":"sub","id":<u64>,"stream":"<ns>.<family>.<event>","filter"?:{...}}`, the
    answer is `ok` with `{"sub":<u64>}`; events are `{"t":"ev","sub":<u64>,"seq":<u64>,"data":{...}}`;
    `{"t":"unsub","sub":<u64>}`.
  - cancel: `{"t":"cancel","id":<u64>}`.
  - release a handle: `{"t":"release","handle":"<id>"}`.
  - byte stream: `{"t":"open","stream":<u32>,"op":...}` then binary frames
    `[u32 stream id BE][u32 credit or 0][payload]`; flow control is credit based
    (`{"t":"credit","stream":<u32>,"bytes":<u32>}`), so one large stream cannot starve calls.
- Both peers may call: a provider can call the page (callbacks) with the same envelope.
- Ids are per connection. A peer must handle out-of-order results.

## Wire decisions

These rules fill gaps in the envelope above. The TS client implements them
(`webviews/src/protocol/`); the Rust and Go peers must match them or object before they ship.

1. `open` carries `id` and may carry `params`:
   `{"t":"open","id":<u64>,"stream":<u32>,"op":"...","params"?:{...},"cap"?:<handle>}`. The peer
   answers that `id` with the normal `ok` or `err`, so an unknown stream op fails like an unknown call.
2. `{"t":"end","stream":<u32>}` ends one direction of a byte stream. With `"code"` and `"message"` it
   aborts both directions. A stream is finished when both directions ended.
3. Stream ids use parity. The side that connects opens odd ids; the side that accepts opens even ids.
   A peer refuses an `open` whose id has its own parity or is already in use.
4. Event `seq` starts at 1 for each subscription and increases by 1. A receiver reports a gap.
5. Auth refusal is an `{"t":"err","id":0,...}` before any other message, or the listener closing
   the socket. The client then closes the socket (close code 4001). A listener may acknowledge
   auth with `{"t":"ok","id":0}`; a client may wait for it.
6. Session-level error codes are `cmux.protocol.*`: `closed`, `cancelled`, `unknown_op`,
   `unknown_stream`, `invalid_params`, `invalid_result`, `invalid_event`, `internal`,
   `credit_exceeded`, `stream_aborted`, `auth_refused`. Op-level codes come from the IR.
7. A session with a schema refuses every op, stream op and event that the IR does not declare.
   Stream ops must therefore be in the IR.
8. On a MessagePort only, a side sends `{"t":"bye"}` before it closes the port, because MessagePort
   has no portable close signal. Session never sees this message.
9. The codegen refuses any JSON Schema keyword outside the subset it supports. It never emits a
   validator that accepts everything.
31. Operation ids (2026-10-04, zero-latency lane, [zero-latency.md](zero-latency.md)): `call` may carry `"opid":"<string>"` (1 to 128 characters of `[A-Za-z0-9._:-]`), a client-generated operation id for one user intent. A provider that applies the call echoes the id on every event the call caused: `{"t":"ev","sub":…,"seq":…,"data":…,"opid":"<id>"}` (envelope field, outside the IR-validated `data`). A provider applies an opid once per caller identity (the token's `sub`, the page instance, so a resend on a new connection after a reconnect is covered): a repeated opid is answered with the first run's `ok` or `err` and runs nothing. Remember at least the last 1024 opids per caller for 10 minutes. `ok` and `err` are matched by `id` and carry no opid. A malformed opid is a bad message (`cmux.protocol.bad_message`). TS: `CallOptions.opid`, `HandlerContext.opid`, `emit(data, {opid})`, `onEvent(data, seq, {opid})`, `OpidLedger` for providers, and the page bridge carries it (`PageClient.call(op, params, {opid})`). Rust and Go providers follow; no Rust change in this slot.
   (Decisions 10 to 30 are in the IR change log, `/tmp/pane-protocol/ir-changes.md`.)

## Namespaces and the catalog

- Op names: `<namespace>.<family>.<verb>`; events `<namespace>.<family>.<event>`.
- `cmux.*` is first party. A third party's namespace is its app id in reverse DNS
  (`com.acme.diff`). The registry makes app ids unique, so registration reserves the namespace.
  The router refuses a provider that declares ops outside its namespaces.
- Interfaces (`cmux.diff.source/1`, `cmux.viewer/1`, `cmux.editor/1`) are shared contracts. A provider
  may implement an interface for its own namespace; a surface asks the router which providers
  implement an interface.
- One catalog: first-party panes are first-party apps with grants (cmux-app-host scopes).

## Schema source and codegen

- Rust: op params, results, events and errors derive `serde` + `schemars::JsonSchema`, and an op
  is declared with a registration macro (name, scope, kind read/mutation, params, result).
- `emit-ir` writes `cmux-tui/spec/pane-protocol.json`: `{version, namespaces, ops[], events[],
  interfaces[], types{...JSON Schema 2020-12 $defs}}`. It is committed; CI fails on drift.
- Generators read only the IR: TS (typed client and types), Swift, Go (third-party provider and
  client SDK, extends `cmux-tui/bindings/codegen/emit_go.py`), Rust client. Every receiver
  validates incoming params and results against the IR schemas (generated validators), in every
  language, because peers are untrusted.

## Transports (one interface)

`interface Transport { send(msg: string | Uint8Array): void; onMessage(cb); onClose(cb); close() }`.
Typed `call`, `subscribe`, handles and streams sit on top and do not know the transport.
Adapters: WebSocket (pages; dev and in-app), unix socket (native peers, providers), WebKit
message handler and CEF binding (handshake and native UI ops only), MessagePort (iframes,
workers), in-memory mock (tests).

## Engines

The engine bridge does only two things: the handshake (router endpoint plus the surface's
initial capability token) and native UI ops (tab open, dictation), which are catalog ops that
Swift serves. WebKit: `WKScriptMessageHandlerWithReply`. CEF: a V8 binding from the render
process handler (or CDP `Runtime.addBinding` where we drive CEF over CDP). Plain browser: the
token in the URL fragment (dev only).

## Security

- Capability tokens: signed by the router (Ed25519), short lived (minutes, refreshed over the
  control plane), with claims `{sub: surface id, app, ns[], ops or scopes, origin, exp, aud:
  provider}`. Providers verify with the router's public key. A token in a page is never valid for
  another provider (`aud`) or another origin.
- WebSocket auth: the first frame carries the token (`{"t":"auth","token":...}`), not the URL
  query, so tokens do not land in logs or history. The listener closes a connection that does not
  authenticate within 2 s. Origin and Host checks stay (cmux-local-auth, DNS rebinding).
- Listeners bind loopback only, on random ports. Providers that the router spawns get a
  socketpair fd (no filesystem socket to hijack); providers that start by themselves connect to
  the router's unix socket (0600, per-user dir) and present an app credential.
- Pages run with a CSP whose `connect-src` lists only the endpoints in their handshake.
- Third-party surfaces and providers get only their grants; a `cmux.*` op from a third party is
  checked against its scopes like any other.

## Latency

- Every TCP socket we accept or dial sets `TCP_NODELAY` (acpmux's web listener does not today:
  `cmux-tui/crates/acpmux/src/server/mod.rs`). We coalesce our own writes per event-loop tick
  instead of relying on Nagle.
- Control and bulk traffic use separate connections or credit-limited streams, and sockets set
  `TCP_NOTSENT_LOWAT` (16 KiB), so a small call does not wait behind megabytes in a send buffer.
- Unix sockets have no Nagle; the same framing applies.
- Bulk static data (patch files, images) is served over HTTP from the provider with the same
  token, so the browser can cache and range-request it.

## Pages (React UI with a Rust backend: Settings, History, App Store, viewers, agent pane)

A page is a surface that a manifest declares. It is the unit that gets a route, a token and grants.

```json
{
  "id": "cmux.settings",
  "route": "/settings",
  "entry": "pages/settings/index.html",
  "namespace": "cmux.settings",
  "provider": { "kind": "daemon-module" },
  "consumes": ["cmux.settings/1", "cmux.git.status"],
  "scopes": ["settings:read", "settings:write"],
  "engines": ["webkit", "cef", "browser"]
}
```

- `id`: namespaced like ops (`cmux.*` first party, reverse-DNS app id for third parties).
- `route`: the path on the surface server in dev (`http://127.0.0.1:<slot port>/settings`) and on the
  app scheme in the app (`cmux-page://cmux.settings/`). One origin per page id in the app, so a page
  never shares an origin (and its tokens) with another page.
- `namespace`: the ops the page's backend serves. `provider.kind` is `daemon-module` (Rust, in the
  cmux-tui daemon), `process` (`{command, args}`, spawned by the router with a socketpair fd) or
  `external` (self-started, connects to the router socket with an app credential).
- `consumes`: interfaces and ops the page may call. The router turns them into scopes; the user
  grants third-party scopes at install, first-party pages get theirs from the build.
- Handshake: the engine bridge gives the page `{router: <endpoint>, token: <page token>}`. The page
  token's claims are `{sub: <page instance id>, page: <id>, app, scopes, origin, aud: "router", exp}`.
- The page asks the router for each namespace it uses: `cmux.router.resolve {namespace}` ->
  `{endpoint, token}`, a data-plane token with `aud` set to that provider. Then it talks to the
  provider directly. `cmux.router.token.refresh` renews tokens before `exp`.

Router control ops in the first slice: `cmux.router.hello` (provider admission),
`cmux.router.resolve`, `cmux.router.token.refresh`, `cmux.router.interfaces.list`,
`cmux.router.pages.list`.

Every page also gets two event streams from its engine bridge (the host, not a provider), so pages
handle host state and host commands one way:

- `cmux.page.connection` `{connected: boolean}`: the page's backend connection went up or down.
  Pages show their own offline state from it instead of guessing from failed calls.
- `cmux.page.command` `{command: "find" | "focusSearch" | "back" | "forward" | "reset"}`: a host
  command for the focused page. The app's single key dispatcher (R59) maps keys to these commands;
  pages add no key handling of their own for them.

## First slice (proves every part)

1. Rust: envelope, framing, token mint and verify, router namespace registry and provider
   admission, `emit-ir`; `cmux.git.status` and `cmux.git.diff` declared with schemars; NODELAY fix.
2. TS: transport interface, WebSocket/WebKit/CEF/MessagePort/mock adapters, generated client from
   the IR, agent pane changes view reads git through it.
3. Go: generated provider SDK and an example third-party provider `com.example.hello` over a unix
   socket, called from a page.
4. Engines: the same page in WebKit, CEF and a plain browser.
5. Tests: wire conformance vectors shared by Rust, TS and Go.
