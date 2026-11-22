> RESUME NOTE (updated 2026-10-03, Rust lane of the app platform)
> State: branch feat-cmux-next-apps-routing (pushed, no base push) on top of #17008 (no actor commit). Done: provider channel + review fixes + registration gate; `coderouter` family; apps-list `commands`; default apps from the shipped first-party directory (CMUX_APPS_FIRST_PARTY_DIR). Testbox 54/54.
> Gate: every_bundled_first_party_app_loads_and_is_installed_by_default must pass on the real tree before this branch lands (CodeRouter passes with 21a0be05f06 + its BUNDLED marker; lane 3 fixes the other cmux-app.v2.json files and marks them BUNDLED). The loader prefers cmux-app.v2.json in the first-party directory.
> Next: landing window (after lane 13 sizing and 17112): first commit regenerates cmux-app-host/generated (chief.*, closed.*, column.update, calendar.*, mail.* ...), then #16872, #17008, routing; exact-head gates incl. check-app-platform; push with .cmux-scratch/nx-worker/safe-push.sh. When the identity lane's Actor/dispatch API lands: set the `app` actor explicitly; gate on terminal/acp_session agent actors.
> Later queue: build-time scopes, then power assertions.

# App op routing from the supervisor (app platform step 3c)

Status: accepted (provider channel as written; D1 decided), Rust lane of the app platform, 2026-10-02. Stacked on #17008. Binding: OWNERSHIP-PRINCIPLES.md, app-platform.md section 13.

## Problem

The supervisor answers an app call only when the daemon owns the op (`cmux.protocol/2` catalog), the op is app storage, or it is `net.fetch`. Everything else answers `operation.unsupported`:
- host-capability ops whose owner is the Mac app: `fs.pick|read|write` (the app's file panel, used by notes Export and Import), `action.run`, `action.list`, `app.settings.set`, pane open;
- cloud ops whose owner is the backend: `feed.*`, `app.*`, `integration.request`, `team.*`.

## Owners and the channel

| Op family | Owner | Route |
| --- | --- | --- |
| `cmux.protocol/2` ops | daemon | own dispatcher, actor `app:<id>` (#17008) |
| host capability (`fs.*`, `action.*`, `app.settings.set`, `power.assertion.*`) | the Mac app that is the machine's native host | provider channel below |
| cloud (`feed.*`, `app.*`, `integration.*`, `team.*`) | API Worker | see decision D1 |

Provider channel, modeled on `url_open` (daemon asks a connected frontend) and `browser_provider` (a client registers as provider):
- `apps-provider-register {families: ["fs", "action", ...]}` on a local connection; the capability set is per connection and ends with it. One provider per family; a second registration replaces the first.
- The supervisor forwards an admitted call as event `apps-provider-request {request_id, app, actor: {kind: "app", id, host, version, on_behalf_of} (identity.md section 3), origin, op, params, idempotency_key?, deadline_ms}` to that connection only.
- The provider answers `apps-provider-result {request_id, ok, body}` (ABI body shapes). Unanswered after the deadline (default 30 s; `fs.pick` waits for the user, 10 min) -> `operation.failed` with `reason: timeout`. A disconnect fails its pending requests at once.
- No provider registered, or the provider disconnects mid-call -> `provider.unavailable` at once (retryable, details `{family, op}`; APP-R1). An op of no provider family -> `operation.unsupported`.
- Who may register (app platform lead, 2026-10-03): a connection whose stamped actor is `agent:<id>` is refused (`apps.provider.forbidden`); this is the real barrier against an agent in a pane. The connection must also have declared `set-client-info` kind `app` (self-declared). The Mac app registers its families as the first thing after it connects, so the window for an impostor is short. Residual risk: a same-uid process that is not an agent and claims kind `app` can still register first; that is inside the documented local trust boundary until per-install keys bind the Mac app's connection.
- Origin `user` (A2, React UIs lead's design, 2026-10-04; tightened by the coordinator 2026-10-04, request-origin.md): on every `apps-*` command, origin `user` (install, grant, gestures) and every `apps-set` change (install, uninstall, enable, disable, hide, sandbox, grant, whatever origin it claims) need a verified cmux app connection; any other connection gets `origin.forbidden` "needs a verified cmux app connection" `{required: "user", derived}`, never a silent downgrade. A connection that only declares kind `app` is not the verified app. A verified connection bound to an agent still gets `apps.origin_forbidden`. The native confirmation sheet's provider sets the top-level `origin` after OK. Hide needs a verified app (origin user) until P8 adds the verified-app path; agents must not change what the user sees (D55 as amended). No connection is verified before P8, so these are refused everywhere until then. P8 (2026-10-04) adds the verified-app path, and provider registration (`apps-provider-register`) now needs the verified app too; a declared kind `app` no longer counts anywhere.
- Shared fix (owner: the cmux-tui reviewer, after its flake branch): the daemon verifies the hosting app connection by its peer's code signature (audit token, team id). The apps provider gate, the apps origin gate and `settings.team_policy.set` / `domains.publish` all use it. In the supervisor the check is one function, `apps::provider::hosting_app_connection(claim)`, so the signature check replaces its body without touching the apps code.
- App servers (open, waits for build-time scopes in step 3d): a catalog op of an app with a manifest `server` runs in that server only through `apps-run`. Calls from another app's VM are refused earlier because server ops are not in `scopes.json`. On `apps-run` the supervisor checks the op's scope (fragment family + risk, the `gen-cmux-global` derivation), and a `gesture: required` op needs origin user (A2); the server checks again as a second layer.
- The supervisor's checks stay first: scope, grant, sandbox, gesture (a gesture spent for `fs.pick` because it opens a panel). The provider trusts the supervisor's actor and origin and enforces its own owner rules.

## Credential relay: the `credential` family (cx-wb5.57, chief 2026-10-08)

A first-party app server that declares the server scope `op:cmux.credential.relay` sends `relay.op {id, op, params, idempotency_key?, origin?}` and `relay.session {id}` lines (the shape of first-party-apps/cloud/server/src/api/relay.rs). The supervisor (`cmux-tui-core/src/apps/relay.rs`) routes them to the provider of the new family `credential` as `credential.relay {op, params, idempotency_key?, origin?}` and `credential.session {}`, with the stamped `app:<id>` actor and the provider deadline. Answers to the server: `relay.result` (the provider's `{value, revision?, replayed?}`, or `ok: false` with the owner's ABI error), `relay.session {signed_in, team}`, or `relay.error` with `not_signed_in` (the provider's code), `unavailable` (no provider, it left, or the deadline passed), `apps.scope_missing` or `validation.invalid`. A server that stops or exits cancels its pending relay calls (`apps-provider-cancel`, reason `host_exited`). The provider (the Mac app) sends the op with its INSTALL token to `POST /v1/read` or `/v1/ops`; never a Stack bearer (decision 2026-10-08: a bearer is the user's whole identity and cannot be scoped or revoked per install). No line carries a credential and the daemon holds none. The `origin` is the server's claim; only first-party servers may relay.

## Op cancel: `op.cancel` (decided, coordinator, 2026-10-04)

When a caller drops a request it made (page navigation or tab close in the page bridge, Ctrl-C in the CLI, a client connection that closes), the request is cancelled end to end, so a slow op never runs on for nobody and a caller never hangs.

- Supervisor to app server, on the server's op channel: `{"type":"op.cancel","id":<the op line id>}` (the same `id` the supervisor gave the `{"type":"op",...}` line).
- Idempotent. A cancel of an unknown or finished id is a no-op and gets NO line. A second cancel of the same id is a no-op.
- A running or waiting op that is cancelled answers its ORIGINAL id exactly once: `{"type":"result","id":<id>,"ok":false,"error":{"code":"cmux.op.cancelled","message":...,"retryable":false}}`, and no later result for that id follows. Its work stops (cmux-cloud: the file job's dial child ends; a parked link wait is dropped).
- A cancelled mutation may or may not have taken effect: the caller retries it with the SAME idempotency key (the app server's ledger keeps the attempt open, so the retry runs again).
- An app server that does not know the line answers nothing for it (the op then answers normally); the supervisor must not depend on a cancel answer beyond "at most one result per id".

Senders (who emits `op.cancel`):
- cmux-cloud (first-party Cloud app server): RECEIVER, done (`first-party-apps/cloud/server/src/api/serve.rs`, `fs/jobs.rs`, `link/park.rs`; tests `tests/op_cancel.rs`).
- The app supervisor: SENDER, done for a closed connection (`cmux-tui/crates/cmux-tui-core/src/apps/cancel.rs`; tests `apps/supervisor_cancel_tests.rs`). It keeps each `apps-run` caller by connection and request id and answers a cancelled caller `cmux.op.cancelled` once; a later answer of the op is dropped. Callers that share an idempotency key share one op: `op.cancel` goes out only when the last of them cancels, and a queued line is dropped instead of sent. A QuickJS host run cannot be stopped; its callers are answered and its own answer is kept for the key. The caller-side cancel is the `cancel-request` frame, done: `{"id","cmd":"cancel-request","target":<the apps-run id>}` on the run's connection answers `{}` and cancels that caller's run (`cmux-tui-core/src/server/apps.rs`); `identify` advertises `cancel-request-v1` with `apps-v1`. Owner: app platform / daemon lane.
- The page bridge (webviews client `call`, with an AbortSignal on navigation and tab close) and the Rust CLI (Ctrl-C during `cmux ... ` app op verbs): send the caller-side cancel to the supervisor. Owners: app platform (bridge) and the CLI owner.

## D1: who calls the API Worker (decided, app platform lead, 2026-10-02)

- Now (A): cloud ops go to the Mac app over the provider channel; the app holds the install JWT and its API client. No user credential enters the daemon. A daemon without a connected app answers cloud ops with `no_provider`.
- End state: per identity spec D5 every daemon (Mac mini, Cloud VM) becomes an install with its own keypair and short-lived install JWT. When daemon enrollment lands, the supervisor sends cloud ops itself with the daemon's install token, actor `app:<id>` on behalf of the user; the Mac-app path stays the fallback for unenrolled daemons.
- Never: a user token delegated from the app to the daemon.

## Work

1. Daemon: provider registry, request table with deadlines (one-shot timer, no polling), disconnect cleanup, routing in `calls.rs`, tests with a fake provider connection.
2. scopes.json lists every routed op (build-time scopes, step 3d).
3. Swift lane: the App registers as provider and implements `fs.*` (NSOpenPanel/NSSavePanel through the gesture), `action.*` (ActionRegistry with origin from the request), `app.settings.set`, and, with A, cloud ops through its API client.
4. COORDINATION.md line for the protocol change.
