# ChatGPT auth refresh on remote app-server paths

Status: design note. No runtime change is safe until the auth owner and wire
boundary are selected.

## Finding

Codex app-server can send a server-initiated JSON-RPC request named
`account/chatgptAuthTokens/refresh` (the generated Rust variant is
`ChatgptAuthTokensRefresh`). The request has an `id` and waits for a matching
JSON-RPC result or error. The request is part of Codex's external-auth bridge,
so the host that owns ChatGPT credentials must answer it. The upstream bridge
uses a bounded wait and attempts to cancel its request after a timeout.

The current cmux-tui remote path has no owner for this message:

* `cmux-tui/crates/cmux-tui/src/session/remote.rs:2553-2683` tracks cmux daemon
  command responses in a `HashMap<u64, PendingRemoteRequest>`. It accepts only
  cmux envelopes (`id`, `ok`, `data`, and cmux error fields). Shutdown drains
  this map and sends a `{\"shutdown\":true}` response, so these cmux requests
  do not explain an app-server request that is waiting remotely.
* `cmux-tui/crates/chatmux-relay/src/wire.rs:97-131` defines relay server
  frames. It has no server-request variant carrying a JSON-RPC method, params,
  and request id. `parse_server_frame` returns `Unknown` for newer frame types
  (`:163-216`), and `session.rs:1022-1033` logs and ignores them. An auth
  refresh request would therefore be dropped before it can reach a host.
* `cmux-tui/crates/cmux-remote/src/client.rs:346-374` resolves workspace RPC
  responses and fails every pending sender when its stream closes. This is a
  separate workspace-RPC channel and has no app-server request forwarding.
* The macOS `CodexAppServerSession` has an explicit unsupported-request path:
  it sends JSON-RPC `-32601` for methods outside its approval set. It does not
  own ChatGPT refresh credentials, so changing it to fabricate a successful
  token response would be unsafe.

As a result, the failure is an ownership gap. A remote Codex app-server either
waits for a host response that cmux-tui cannot produce, or the relay ignores
the request as an unknown frame. Extending the relay to forward arbitrary
JSON-RPC would move credential-bearing traffic across a protocol that is
currently designed for opaque terminal/workspace operations. Extending the
TUI to mint or refresh tokens would make the TUI an auth owner without a
credential-store contract.

## Decision required

Choose one explicit boundary before implementation:

1. **Host-owned bridge.** The app-server host answers
   `account/chatgptAuthTokens/refresh`. The relay and cmux-tui remain unaware
   of the method. Remote hosting must provide a separate authenticated bridge
   beside the terminal relay.
2. **Relay-carried bridge.** Add a versioned relay server-request/result pair
   with strict method allowlisting, request-id correlation, cancellation, and
   credential redaction. The endpoint that owns the ChatGPT tokens must be
   explicit; the relay must not inspect or persist token values.
3. **Unsupported by policy.** Reject the request at the app-server boundary
   with a stable JSON-RPC error and surface a sign-in or host-configuration
   action. This prevents an unresolved wait but does not provide refresh.

Do not add a generic `Unknown -> error` response in `chatmux-relay`: older
servers may send unknown notification or control frames, and replying without
an agreed request contract can create a response loop or protocol downgrade
failure.

## Required behavior tests after the decision

The selected owner should add tests at the selected boundary, not in the
unrelated cmux command map:

* **Success:** emit one refresh request, preserve its opaque JSON-RPC id and
  `previousAccountId`, accept one typed response, and unblock the app-server
  exactly once.
* **Unsupported:** send a JSON-RPC error with a stable code and message for
  the refresh method when the host has no auth owner. The app-server must
  receive this error instead of waiting for a timeout.
* **Shutdown/error:** close the transport while refresh is pending. The
  app-server wait must resolve as a transport cancellation, the pending entry
  must be removed, and a late response must not be delivered to a new request
  that reuses state.
* **Correlation:** a response with an unknown or already-settled id must be
  ignored or reported as a protocol error according to the selected wire
  contract; it must never satisfy another request.

Tokio's channel contract supports this ownership model: dropping a oneshot
sender makes its receiver resolve with `RecvError`, and `Receiver::closed`
lets a producer stop work when the consumer no longer waits. `select!` cancels
the losing branch, so every pending request needs an explicit cleanup owner.
`JoinSet::shutdown` aborts and joins tracked tasks, which is the appropriate
final step for relay connection handlers.

References:

* Codex protocol and external-auth implementation:
  https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/v2/account.rs
  and https://github.com/openai/codex/blob/main/codex-rs/app-server/src/external_auth.rs
* Tokio oneshot cancellation:
  https://docs.rs/tokio/latest/tokio/sync/oneshot/struct.Sender.html
  and https://docs.rs/tokio/latest/tokio/sync/oneshot/struct.Receiver.html
* Tokio `select!` cancellation safety:
  https://docs.rs/tokio/latest/tokio/macro.select.html
* Tokio `JoinSet` shutdown:
  https://docs.rs/tokio/latest/tokio/task/struct.JoinSet.html

## Verification limit

This audit used source inspection, `git diff --check`, and direct formatting
review only. No local Cargo, rustc, or test command was run. The note does not
claim that a remote auth refresh currently succeeds.
