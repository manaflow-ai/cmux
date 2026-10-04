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
- Origin `user` (A2, React UIs lead's design, 2026-10-04): on every `apps-*` command, origin `user` (install, grant, gestures) is accepted only from the hosting app connection, the same two gates as provider registration; any other connection that sends it gets `apps.origin_forbidden`, never a silent downgrade. The native confirmation sheet's provider sets the top-level `origin` after OK. Other origins are unchanged, and hiding still works from any origin (D55). Residual risk: kind `app` is self-declared, so the agent binding is the real barrier; a same-uid process that is not an agent and declares kind `app` passes.
- Shared fix (owner: the cmux-tui reviewer, after its flake branch): the daemon verifies the hosting app connection by its peer's code signature (audit token, team id). The apps provider gate, the apps origin gate and `settings.team_policy.set` / `domains.publish` all use it. In the supervisor the check is one function, `apps::provider::hosting_app_connection(claim)`, so the signature check replaces its body without touching the apps code.
- The supervisor's checks stay first: scope, grant, sandbox, gesture (a gesture spent for `fs.pick` because it opens a panel). The provider trusts the supervisor's actor and origin and enforces its own owner rules.

## D1: who calls the API Worker (decided, app platform lead, 2026-10-02)

- Now (A): cloud ops go to the Mac app over the provider channel; the app holds the install JWT and its API client. No user credential enters the daemon. A daemon without a connected app answers cloud ops with `no_provider`.
- End state: per identity spec D5 every daemon (Mac mini, Cloud VM) becomes an install with its own keypair and short-lived install JWT. When daemon enrollment lands, the supervisor sends cloud ops itself with the daemon's install token, actor `app:<id>` on behalf of the user; the Mac-app path stays the fallback for unenrolled daemons.
- Never: a user token delegated from the app to the daemon.

## Work

1. Daemon: provider registry, request table with deadlines (one-shot timer, no polling), disconnect cleanup, routing in `calls.rs`, tests with a fake provider connection.
2. scopes.json lists every routed op (build-time scopes, step 3d).
3. Swift lane: the App registers as provider and implements `fs.*` (NSOpenPanel/NSSavePanel through the gesture), `action.*` (ActionRegistry with origin from the request), `app.settings.set`, and, with A, cloud ops through its API client.
4. COORDINATION.md line for the protocol change.
