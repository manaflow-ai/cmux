# Cloud (`cmux/cloud`)

Create, start, pause, resize and delete cmux Cloud machines, take and restore snapshots, and read the plan and usage. Plan: `plans/cmux-next/cloud-app.md` (package C1: manifest, catalog fragment, app server core).

Status: manifest v2 only (`cmux-app.v2.json`), like `remote-desktop/`, so `first-party-apps/build.ts` does not bundle it. `cargo test` in `server/` validates the manifest and the fragment with `cmux-app-manifest`, and `cmux-app-manifest`'s own first-party test covers it too.

## Parts

| Part | Where | What |
| --- | --- | --- |
| native server `cmux-cloud` | `server/` (Rust, its own Cargo workspace) | runs the catalog ops; the only writer of the machine projection on this machine; one instance per machine |
| catalog fragment | `catalog/cloud-catalog.json` (family `cloud`) | every op with its risk, idempotency, CLI path, MCP exposure and palette title (en, ja) |
| page | `cmux.pane/1` with `"native": "cloud"` | the native view hosts the React page `cmux-page://cmux.cloud/` (`webviews/src/pages/cloud/`, package C4), the same pattern as `app-store` |
| machine records | the cmux Cloud API (`web/app/api/vm`) | the owner; the server keeps a projection only |

## Credentials

The server never sees the sign-in. It sends each Cloud API call as `{op, method, path, body, idempotency_key}` to the host (`ControlPlane` in `server/src/api/control_plane.rs`). The host adds the bearer and the team header and returns `{status, body}`. The real implementation (`HostRelay`, JSON lines on stdin/stdout) is a placeholder for the APP-R1 provider channel and its credential relay op (`op:cmux.credential.relay` in `server.scopes`). Tests use a fake control plane with recorded responses (`server/tests/fixtures/`, shapes from the `web/app/api/vm/**` route code; no customer data).

## Scopes

| Scope | Class | Why |
| --- | --- | --- |
| `cloud:read` | standard | list machines, stats, snapshots, plan, usage |
| `cloud:write` | sensitive | create, rename, start, pause, resize, delete, snapshots |
| `op:cmux.credential.relay` (server) | sensitive, server only | the host credential relay; the op does not exist yet (APP-R1) |

## Ops (`catalog/cloud-catalog.json`)

Fragment names are `cloud.<noun>.<verb>`; the full name is `cmux.cloud.<noun>.<verb>`. The server accepts both and the old relay names.

| Op | Class, risk | MCP | CLI | Cloud API | Rule |
| --- | --- | --- | --- | --- | --- |
| `cloud.auth.status` | read | default | `cloud auth status` | none (host) | the host answers from its sign-in |
| `cloud.machine.list` | read | default | `cloud machine list` | `GET /api/vm` | replaces the projection |
| `cloud.machine.get` | read | default | `cloud machine get` | `GET /api/vm/:id` | |
| `cloud.machine.create` | mutation, mutate-own | opt_in | `cloud machine create` | `POST /api/vm` | idempotency key required; a retry with the same key returns the same machine and makes no second call; the key also goes to the API as `Idempotency-Key` |
| `cloud.machine.rename` | mutation, mutate-shared | default | `cloud machine rename` | `PATCH /api/vm/:id` | |
| `cloud.machine.start` | mutation, mutate-shared | default | `cloud machine start` | `POST /api/vm/:id/resume` | aliases `cloud.machine.resume`, `vm.start`, `vm.resume` |
| `cloud.machine.pause` | mutation, mutate-shared | default | `cloud machine pause` | `POST /api/vm/:id/pause` | |
| `cloud.machine.resize` | mutation, mutate-shared | opt_in | `cloud machine resize` | `POST /api/vm/:id/resize` | answers stats with the plan maximums |
| `cloud.machine.delete` | mutation, destructive | never | `cloud machine delete` | `DELETE /api/vm/:id` | origin `user` only, gesture required |
| `cloud.machine.stats` | read | default | `cloud machine stats` | `GET /api/vm/:id/stats` | |
| `cloud.machine.idle_policy.set` | mutation, mutate-shared | opt_in | `cloud machine idle-policy set` | none | answers `cmux.cloud.unsupported` (gap) |
| `cloud.snapshot.list` | read | default | `cloud snapshot list` | `GET /api/vm/:id/snapshots` | |
| `cloud.snapshot.create` | mutation, mutate-own | default | `cloud snapshot create` | `POST /api/vm/:id/snapshot` | |
| `cloud.snapshot.restore` | mutation, mutate-own | opt_in | `cloud snapshot restore` | `POST /api/vm/restore` | a new machine; same-key retry returns it |
| `cloud.snapshot.fork` | mutation, mutate-own | opt_in | `cloud snapshot fork` | `POST /api/vm/:id/fork` | a new machine; same-key retry returns it |
| `cloud.snapshot.delete` | mutation, destructive | never | `cloud snapshot delete` | `DELETE /api/vm/:id/snapshots/:sid` | origin `user` only, gesture required |
| `cloud.plan.get` | read | default | `cloud plan get` | `GET /api/vm` (`limits`) | no plan logic in cmux |
| `cloud.usage.get` | read | default | `cloud usage get` | `GET /api/vm` (`limits`) | |

Every op has `remote_relay: deny` and `queue_offline: false`. Every mutation needs an idempotency key (it rides the `apps-run` envelope); a read with a key is refused. The server keeps a replay record of each successful mutation for the life of the process: the same key with the same op and args returns the recorded result, the same key with other args is `cmux.cloud.idempotency_conflict`. Ids are checked against `[A-Za-z0-9][A-Za-z0-9_-]{0,127}` before they enter a path.

Errors are `cmux.cloud.*`: `auth_required` (401, or no sign-in at the host; the projection is cleared), `plan_limit` (402, or a plan error code), `forbidden`, `not_found`, `conflict`, `rate_limited`, `unsupported` (501), `upstream_error`, `bad_response`, `invalid_args`, `unknown_op`, `origin_refused`, `idempotency_key_required`, `idempotency_key_forbidden`, `idempotency_conflict`, `relay_unavailable`.

## Projection and refresh

The server is the only writer of the machine projection. A list replaces it; a get, create, rename, start, pause, restore or fork answer is merged into the record (fields the answer does not carry are kept); a delete removes the record. Every change raises the revision and sends one `cloud.machine.changed {revision, change, machine}` event to the host after the op result. There is no timer and no polling: the page and the sidebar read on open, on app activation and after a change (cloud-app.md DECISION 5).

## Gaps

- The catalog fragment schema has no `aliases` field. Aliases (`cmux.cloud.*`, `cloud.machine.resume`, the `vm.*` relay names) live only in the server's table, so the CLI and MCP do not offer them. The relay names take other args (`vm_id`) than the fragment ops (`machine`).
- The fragment validator needs op names in the fragment's family, so the fragment says `cloud.machine.list`, not `cmux.cloud.machine.list`.
- No idle policy route in the Cloud API: `cloud.machine.idle_policy.set` answers `unsupported`.
- `POST /api/vm/:id/snapshot` takes no idempotency key: a snapshot whose answer was lost may be taken twice on retry.
- `backend/catalog/cloud-relay-operations.json` binds `vm.snapshot.restore` to `POST /api/vm/:vm_id/restore`; the Cloud API route is `POST /api/vm/restore` with `{snapshotId}`. The server uses the route.
- Plan and usage have no route of their own; both come from the `limits` of `GET /api/vm`. Hours are reported only for plans with an hour allowance.
- Not declared yet (other packages): `auth.sign_in`, `auth.sign_out`, `team.list`, `team.select` (host credential owner), attach (C2), files and ports (C5), domains and network (C6), `machine.watch` (needs a machine change feed, DECISION 5).
- Events do not carry the request's transaction id and there is no `request-settled`; the app host protocol for native servers does not define them yet.
- The icon is a symbol (`icon.noImage` warning), like `app-store`.

## Proposals for the app platform lead (not used in this manifest)

1. `server: true` inside an `implements` entry and `kinds` on implementations, so `cmux.terminal.connector/1` and `cmux.terminal.backend/1` can be served by this server for `cloud-vm` and `cloud-vm-rescue` (C2 needs them).
2. A `cache` data class (rebuildable state that may be dropped at any time); the projection uses `ephemeral` until then.
