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
- The supervisor forwards an admitted call as event `apps-provider-request {request_id, app, actor: "app:<id>", origin, gesture?, op, params, deadline_ms}` to that connection only.
- The provider answers `apps-provider-result {request_id, ok, body}` (ABI body shapes). Unanswered after the deadline (default 30 s; `fs.pick` waits for the user, 10 min) -> `operation.failed` with `reason: timeout`. A disconnect fails its pending requests at once.
- No provider registered -> `operation.unsupported` with `reason: no_provider` (headless daemons, Cloud VMs).
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
