# Cloud (`cmux/cloud`)

Create, start, pause, resize and delete cmux Cloud machines, take and restore snapshots, read the plan and usage, work with the files on a machine, and forward its ports to this Mac. Plan: `plans/cmux-next/cloud-app.md` (package C1: manifest, catalog fragment, app server core; C2: attach; C5: files, ports and the browser proxy route).

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
| `fs:write` | restricted (first-party) | write, make and copy files on a machine (`cloud.fs.write`, `cloud.fs.mkdir`, `cloud.file.push`) and copy files to this Mac (`cloud.file.pull`); `cloud.fs.remove` also needs a person |
| `op:cmux.credential.relay` (server) | sensitive, server only | the host credential relay; the op does not exist yet (APP-R1) |

## Ops (`catalog/cloud-catalog.json`)

Fragment names are `cloud.<noun>.<verb>`; the full name is `cmux.cloud.<noun>.<verb>`. The server accepts both and the old relay names.

| Op | Class, risk | MCP | CLI | Cloud API | Rule |
| --- | --- | --- | --- | --- | --- |
| `cloud.auth.status` | read | default | `auth status` | none (host) | the host answers from its sign-in |
| `cloud.machine.list` | read | default | `machine list` | `GET /api/vm` | refreshes the projection (a diff) |
| `cloud.machine.watch` | read | never | `machine watch` (hidden) | none | answers `{revision}`; the stream is the `cloud.machine.watch` events (below) |
| `cloud.machine.get` | read | default | `machine get` | `GET /api/vm/:id` | |
| `cloud.machine.create` | mutation, mutate-own | opt_in | `machine create` | `POST /api/vm` | idempotency key required; a retry with the same key returns the same machine and makes no second call; the API gets a derived key (below) |
| `cloud.machine.rename` | mutation, mutate-shared | default | `machine rename` | `PATCH /api/vm/:id` | |
| `cloud.machine.start` | mutation, mutate-shared | default | `machine start` | `POST /api/vm/:id/resume` | aliases `cloud.machine.resume`, `vm.start`, `vm.resume` |
| `cloud.machine.pause` | mutation, mutate-shared | opt_in | `machine pause` | `POST /api/vm/:id/pause` | |
| `cloud.machine.resize` | mutation, mutate-shared | opt_in | `machine resize` | `POST /api/vm/:id/resize` | answers stats with the plan maximums |
| `cloud.machine.delete` | mutation, destructive | never | `machine delete` (hidden) | `DELETE /api/vm/:id` | origin `user` only, gesture required |
| `cloud.machine.stats` | read | default | `machine stats` | `GET /api/vm/:id/stats` | |
| `cloud.machine.idle_policy.set` | mutation, mutate-shared | never | `machine idle-policy set` (hidden) | none | answers `cmux.cloud.unsupported` (gap) |
| `cloud.snapshot.list` | read | default | `snapshot list` | `GET /api/vm/:id/snapshots` | |
| `cloud.snapshot.create` | mutation, mutate-own | default | `snapshot create` | `POST /api/vm/:id/snapshot` | |
| `cloud.snapshot.restore` | mutation, mutate-own | opt_in | `snapshot restore` | `POST /api/vm/restore` | a new machine; same-key retry returns it |
| `cloud.snapshot.fork` | mutation, mutate-own | opt_in | `snapshot fork` | `POST /api/vm/:id/fork` | a new machine with its `snapshotId`; same-key retry returns it |
| `cloud.snapshot.delete` | mutation, destructive | never | `snapshot delete` (hidden) | `DELETE /api/vm/:id/snapshots/:sid` | origin `user` only, gesture required |
| `cloud.plan.get` | read | default | `plan get` | `GET /api/vm` (`limits`) | no plan logic in cmux |
| `cloud.usage.get` | read | default | `usage get` | `GET /api/vm` (`limits`) | |
| `cloud.fs.list` | read | default | `fs list` | `GET /api/vm/:id/fs/dir?path=` | one batch (no cursor) |
| `cloud.fs.stat` | read | default | `fs stat` | `GET /api/vm/:id/fs/stat?path=` | |
| `cloud.fs.read` | read | default | `fs read` | `GET …/fs/stat`, then `GET …/fs/read?path=` | at most 16 MiB, else `file_too_large` before the bytes move |
| `cloud.fs.write` | mutation, mutate-shared | opt_in | `fs write` | `POST /api/vm/:id/fs/write` | at most 16 MiB; `baseRevision` answers `unsupported` (the route has no revision) |
| `cloud.fs.mkdir` | mutation, mutate-shared | opt_in | `fs mkdir` | `POST /api/vm/:id/fs/mkdir` | |
| `cloud.fs.remove` | mutation, destructive | never | `fs remove` (hidden) | `DELETE /api/vm/:id/fs/remove?path=` | origin `user` only, gesture required |
| `cloud.file.push` | mutation, mutate-shared | never | `file push` (hidden) | `POST /api/vm/:id/scp-endpoint`, then SSH through the link | origin `user` only, gesture required; a new key per transfer (below) |
| `cloud.file.pull` | mutation, mutate-own | never | `file pull` (hidden) | the same | origin `user` only, gesture required; never overwrites a local file (`local_exists`) |
| `cloud.port.list` | read | default | `port list` | none | this Mac's forwards, up or down |
| `cloud.port.forward` | mutation, mutate-own | opt_in | `port forward` | the link (`loopback-forward-v1`) | 127.0.0.1 and a random port; one per (machine, port); never replayed |
| `cloud.port.close` | mutation, mutate-own | default | `port close` | none | |
| `cloud.browser.open` | mutation, mutate-own | opt_in | `browser open` | the link | a proxy route descriptor; opens no tab; never replayed |

Every op has `remote_relay: deny` and `queue_offline: false`. Every mutation needs an idempotency key (it rides the `apps-run` envelope); a read with a key is refused. The server records each attempt before the Cloud API call and the result after a success, for the life of the process: the same key with the same op and args returns the recorded result with no call, the same key with another op or other args is `cmux.cloud.idempotency_conflict` (also after a failure), and refused args free the key. The Cloud API gets `Idempotency-Key = sha256(op, canonical args, key)`, because it matches keys per team without comparing the op or the body; a retry after a lost answer sends the same derived key, so the Cloud API returns the first machine. Ids are checked against `[A-Za-z0-9][A-Za-z0-9_-]{0,127}` before they enter a path; display names follow the Cloud API (1 to 64 characters, no control characters).

Delete ops need origin `user`. Origin is not the caller's claim: the app supervisor stamps `user` only after its native confirmation sheet (app-platform.md 13.1 and 15), so the delete ops are hidden on the CLI and never on MCP. This server trusts the stamped origin; it cannot check it.

Errors are `cmux.cloud.*`: `file_too_large`, `transfer_failed`, `local_exists`, `port_limit`, `proxy_refused`, `listen_failed`, `auth_required` (401, or no sign-in at the host; the projection is cleared), `plan_limit` (402, or a plan error code), `forbidden`, `not_found`, `conflict`, `rate_limited`, `unsupported` (501), `upstream_error`, `bad_response`, `invalid_args`, `unknown_op`, `origin_refused`, `idempotency_key_required`, `idempotency_key_forbidden`, `idempotency_conflict`, `relay_unavailable`.

## Projection and refresh

The server is the only writer of the machine projection, and the projection is the only source of `cloud.machine.watch` events. A list refreshes it as a diff (records missing from the list are removed, new or changed records upserted; destroyed machines are not kept); a get, create, rename, start, pause, restore or fork answer is merged into the record (fields the answer does not carry are kept; for a machine the projection does not know, a rename, start or pause first reads the full record and writes both as one change); a delete, or a delete answered `not_found`, removes the record. `createdAt` is epoch milliseconds whether the API sends a number or an ISO string.

Each write that changes at least one record raises the revision by one and queues one event per changed record, all with that revision: `{type: "upsert", revision, machine}` (the full record) or `{type: "removed", revision, id}`. A write that changes nothing (a no-op refresh, an answer equal to the record) raises nothing and emits nothing. After each op result the serve loop sends the queued events as `{"type":"event","event":"cloud.machine.watch","data":<event>}` lines. Machine mutation results (create, rename, start, pause, resize, snapshot restore and fork) carry a top-level `revision`: the revision the change reached (the current one when nothing changed). A client settles its intent when its mirror has seen that revision. The ledger records the result with its revision, so a same-key replay answers the same revision and emits nothing. A delete keeps its `{ok: true}` result; the `removed` event for the id settles it. There is no timer and no polling: the page and the sidebar read on open, on app activation and after a change (cloud-app.md DECISION 5).

## Files, ports and the browser route (C5)

Files go through the Cloud API file routes over the host relay (`cmux.fs.provider/1` with `server: true` and scheme `cloud-vm` in the manifest; the provider view is `Server::fs_provider`). The VM daemon path over the link (`workspace-rpc` file ops) is a later improvement; the op shapes do not change for it. Guest paths are checked before any call: absolute, at most 4096 bytes, no `..` segment, no NUL or control character; in a query every byte but unreserved characters and `/` is percent-encoded. Reads and writes are bounded at 16 MiB (the route's own write limit); a read states the file first, so a large file is refused before its bytes cross the relay, and the answer is checked again. The ledger keeps a SHA-256 of each mutation's args, not the args, so a 16 MiB write does not stay in memory.

`cloud.file.push` and `cloud.file.pull`: the server makes an Ed25519 key in memory for each transfer (`TransferKey`; the seed is zeroed on drop, `Debug` shows only the public key) and sends only the public half to `POST /api/vm/:id/scp-endpoint` (no idempotency key: a retry authorizes its own key). The answer must name user `cmux`, one Ed25519 host key and a future expiry. The guest SSH port is reached through the link with a one-shot forward on 127.0.0.1, so this Mac needs no private-network route. `OpenSshTransfer` runs a private `ssh-agent`, gives it the key on `ssh-add -` stdin and runs `scp` with the agent, `StrictHostKeyChecking=yes` and the pinned host key under an alias; the key is never on disk, on argv, in a log or in an error. Push and pull are origin `user` only: the local path reaches any file this Mac's user can read or write, so a person picks it (the host's native file panel), never an agent; agents use `cloud.fs.read` and `cloud.fs.write`. Local paths are absolute without `.` or `..`; guest paths for a transfer have no glob characters. A pull lands in a hidden random name next to the target and is published with a hard link, which never overwrites and never follows a symlink placed at the target; a failed pull leaves nothing. `scp` runs in SFTP mode (`-s`) with `IdentitiesOnly=yes` and the transfer key's public half as `IdentityFile`, so the user's own keys are never offered to the guest.

Ports: `cloud.port.forward {machine, port}` listens on 127.0.0.1 and a port the system picks, and each accepted connection opens one `loopback-forward-v1` stream to `localhost:<port>` on the machine through the link's local socket (`PortTunnel`; the real one is `LoopbackTunnel`). There is one forward per (machine, port) and one browser route per machine; `Edge` is their only writer and the op loop its only caller. A forward belongs to one link generation, and each new connection first checks that the link socket file is still the one the forward saw (a new generation binds a new file at the same path), so an old forward never reaches a new link. When the link goes down or is replaced, the serve loop (and every port op) closes the listener and its connections and the record shows `down` with a reason. Nothing is queued; a new `cloud.port.forward` opens a new listener on the new link. `POST /api/vm/:id/open-port` is a different feature (a public preview URL with a bearer token through the provider edge); these ops do not use it.

`cloud.browser.open {machine, port, host?, path?}` answers `{proxy: {kind: "http", host: "127.0.0.1", port}, url}`. The route is an HTTP proxy for `CONNECT` and absolute-form HTTP/1.1 that reaches only the machine: `localhost`, a name under `.localhost` or a loopback literal, decided from the text without DNS. Other hosts get 403 (and `proxy_refused` at the op); origin-form requests get 400, so a page cannot use the route directly.

## Gaps

- CLI paths are app-relative (R73 S1). `cloud` is a reserved CLI word (built-in `cmux cloud`), so the manifest has no `cli.name` and the verbs run as `cmux apps run cmux/cloud <path>` until the CLI owner maps the reserved word to this first-party app.
- The catalog fragment schema has no `aliases` field. Aliases (`cmux.cloud.*`, `cloud.machine.resume`, the `vm.*` relay names) live only in the server's table, so the CLI and MCP do not offer them. For a `vm.*` name the server maps the relay args (`vm_id` to `machine`, `snapshot_id` to `snapshot`).
- The fragment validator needs op names in the fragment's family, so the fragment says `cloud.machine.list`, not `cmux.cloud.machine.list`.
- No idle policy route in the Cloud API: `cloud.machine.idle_policy.set` answers `unsupported`.
- `POST /api/vm/:id/snapshot` takes no idempotency key: a snapshot whose answer was lost may be taken twice on retry.
- `backend/catalog/cloud-relay-operations.json` binds `vm.snapshot.restore` to `POST /api/vm/:vm_id/restore`; the Cloud API route is `POST /api/vm/restore` with `{snapshotId}`. The server uses the route.
- Plan and usage have no route of their own; both come from the `limits` of `GET /api/vm`. Hours are reported only for plans with an hour allowance.
- Not declared yet (other packages): `auth.sign_in`, `auth.sign_out`, `team.list`, `team.select` (host credential owner), domains and network (C6).
- Files: no list cursor, no read range, no write revision and no `watch` on the Cloud API file routes; each answers `unsupported` through the provider instead of pretending. A root is the scheme plus the machine id until `root_…` handles reach app servers.
- `cloud.port.list` lists this Mac's forwards, not the ports that listen on the machine (no route for that).
- The browser route opens no tab: the browser host needs a per-tab proxy op (`browser.tab.open {url, proxy}`, cloud-app.md 5.3). Any local process can use a forward or the route, like an SSH `-L` forward: the Swift proxy checks the peer process, which this server cannot do for browser helpers that are not its children.
- `LoopbackTunnel` opens one link connection per TCP connection (three round trips), not one multiplexed connection per machine.
- Forwards close only when an op runs (the serve loop reconciles after each op; it does not wake on link events yet); until then a connection accepted on a dead or replaced link fails at once and queues nothing.
- A transfer runs on the op loop with no overall deadline (`scp` has `ConnectTimeout` and keepalives only): a long copy delays other ops. Moving transfers to a worker with completion events is a follow-up.
- After an absolute-form request the proxy pins the client connection to that target; a server that ignores `Connection: close` can answer a reused connection for another port of the same machine. Traffic stays inside the machine.
- Browsers skip proxies for loopback by default: the browser host must set `<-loopback>` in the bypass list (remote-localhost.md 5), or a tab loads this Mac's localhost.
- `OpenSshTransfer` and `LoopbackTunnel` are not verified against a live machine (no non-production Freestyle account).
- The catalog fragment schema has no stream class (`class` is `read` or `mutation`). `cloud.machine.watch` is declared as a read that answers the current revision; the event name and shape are documented here and in its `docs`. The host must map `cloud.machine.watch` event lines to page subscriptions of `cmux.cloud.machine.watch` (not built yet).
- The revision has no epoch: it starts at 0 in each server process. A host that restarts the server must restart its page sessions (a new list), or a page keeps its old revision and drops the new events. An instance id on the list and the events would remove this rule.
- The projection sees only what this server does and what a list returns: a change made elsewhere (the web dashboard, another Mac) shows on the stream at the next list read (page open, app activation), not live. A live feed needs a Cloud API change feed (DECISION 5).
- Events do not carry the request's transaction id and there is no `request-settled`; the app host protocol for native servers does not define them yet.
- The icon is a symbol (`icon.noImage` warning), like `app-store`.
- Scope reasons in the manifest are English only: the schema takes one string per scope.
- The relay has no timer: the host must answer every relay request, with `relay.error` when its own HTTP deadline passes.

## Proposals for the app platform lead (not used in this manifest)

1. `server: true` inside an `implements` entry and `kinds` on implementations, so `cmux.terminal.connector/1` and `cmux.terminal.backend/1` can be served by this server for `cloud-vm` and `cloud-vm-rescue` (C2 needs them).
2. A `cache` data class (rebuildable state that may be dropped at any time); the projection uses `ephemeral` until then.
