# Cloud (`cmux/cloud`)

Create, start, pause, resize and delete cmux Cloud machines, take and restore snapshots, read the plan and usage, work with the files on a machine, and forward its ports to this Mac. Plan: `plans/cmux-next/cloud-app.md` (package C1: manifest, catalog fragment, app server core; C2: attach; C5: files, ports and the browser proxy route).

Status: manifest v2 only (`cmux-app.v2.json`), like `remote-desktop/`, so `first-party-apps/build.ts` does not bundle it. `cargo test` in `server/` validates the manifest and the fragment with `cmux-app-manifest`, and `cmux-app-manifest`'s own first-party test covers it too.

## Parts

| Part | Where | What |
| --- | --- | --- |
| native server `cmux-cloud` | `server/` (Rust, its own Cargo workspace) | runs the catalog ops; the only writer of the machine projection on this machine; one instance per machine |
| catalog fragment | `catalog/cloud-catalog.json` (family `cloud`) | every op with its risk, idempotency, CLI path, MCP exposure and palette title (en, ja) |
| page | `cmux.pane/1` with `"native": "cloud"` | the native view hosts the React page `cmux-page://cmux.cloud/` (`webviews/src/pages/cloud/`, package C4), the same pattern as `app-store` |
| machine records | the cmux-next Cloud backend (`cmux.wire/1`, owner `cloud:CloudDO`; plans/cmux-next/cloud-client-contract.md) | the owner; the server keeps a projection only |

## Credentials

The server never sees a credential. It sends each Cloud op as a `cmux.wire/1` call `{op, params, idempotency_key}` to the host (`ControlPlane` in `server/src/api/control_plane.rs`, line `relay.op`). The host adds the install token, posts it to `POST /v1/read` (no key) or `POST /v1/ops`, and answers the wire result or the typed wire error (`relay.result`). Team wire events reach the server as `team.event` lines (`server/src/api/events.rs`). The host sends `{"type":"op.cancel","id"}` when its caller drops a request: a running file op or a waiting connect answers that id once with `cmux.op.cancelled` and stops; an unknown or finished id gets no line (`plans/cmux-next/app-op-routing.md`, Op cancel). Attach and files never call a Cloud API route: attach reads `cloud.machine.connect_info` and dials the machine's host id with `cmux link dial` (`server/src/link/carrier.rs`, `dial.rs`); files are daemon `fs.*` ops on the link behind the `fs-v1` capability (`server/src/fs/link_files.rs`). Tests serve the shared vectors `backend/catalog/cloud-vectors.json` (`server/tests/wire_common`, also read by the backend tests; synthetic data).

## Scopes

| Scope | Class | Why |
| --- | --- | --- |
| `cloud:read` | standard | list machines, connect info, snapshots, plan, migration status |
| `cloud:write` | sensitive | create, rename, start, pause, resize, delete, snapshots |
| `fs:write` | restricted (first-party) | write, make and copy files on a machine (`cloud.fs.write`, `cloud.fs.mkdir`, `cloud.file.push`) and copy files to this Mac (`cloud.file.pull`); `cloud.fs.remove` also needs a person |
| `op:cmux.credential.relay` (server) | sensitive, server only | the host credential relay; the op does not exist yet (APP-R1) |

## Ops (`catalog/cloud-catalog.json`)

Fragment names are `cloud.<noun>.<verb>`; the full name is `cmux.cloud.<noun>.<verb>`. The server accepts both and the old relay names. The backend catalog (`backend/catalog/cloud-operations.json`, owner `cloud:CloudDO`) is the single owner of the client-facing machine, snapshot, plan, billing and migration ops; the fragment declares none of them and the manifest names them in `consumes.ops`. The server still serves them (projection, ledger, checks) and forwards each to the backend op of the same name. The fragment declares only the app-local ops (`cloud.auth.status`, `cloud.machine.watch`, attach, files, ports, browser).

| Op | Class, risk | MCP | CLI | Cloud API | Rule |
| --- | --- | --- | --- | --- | --- |
| `cloud.auth.status` | read | default | `auth status` | none (host) | the host answers from its sign-in |
| `cloud.machine.list` | read | default | `machine list` | `cloud.machine.list {cursor?, limit?}` | one page; a listing from the first page to the last also removes unseen machines |
| `cloud.machine.watch` | read | never | `machine watch` (hidden) | none | answers `{revision}`; the stream is the `cloud.machine.watch` events (below) |
| `cloud.machine.get` | read | default | `machine get` | `cloud.machine.get` | `cloud.machine.not_found` removes it here too |
| `cloud.machine.create` | mutation, mutate-own | never | `machine create` (hidden) | `cloud.machine.create` | key required; retry an unknown outcome with the same key; a same-key retry returns the same machine; origin `user` only, gesture required |
| `cloud.machine.rename` | mutation, mutate-shared | default | `machine rename` | `cloud.machine.rename` | key required; retry an unknown outcome with the same key |
| `cloud.machine.start` | mutation, mutate-shared | default | `machine start` | `cloud.machine.start` | aliases `cloud.machine.resume`, `vm.start`, `vm.resume` |
| `cloud.machine.pause` | mutation, mutate-shared | opt_in | `machine pause` | `cloud.machine.pause` | |
| `cloud.machine.resize` | mutation, mutate-shared | never | `machine resize` (hidden) | `cloud.machine.resize` | origin `user` only, gesture required (a resize may cost money) |
| `cloud.machine.delete` | mutation, destructive | never | `machine delete` (hidden) | `cloud.machine.delete` | origin `user` only, gesture required; a retry answers `{deleted: true}` |
| `cloud.machine.idle_policy.set` | mutation, mutate-shared | default | `machine idle-policy set` | `cloud.machine.idle_policy.set` | |
| `cloud.machine.connect_info` | read | default | `machine connect-info` | `cloud.machine.connect_info {machine} or {host}` | contract 1.7 record (peer data in every bound state; `state: paused` is not an error); it carries no credential (an answer with a `link_token` is `bad_response`; the token is `cloud.machine.link_token`, which only `cmux link` calls); `not_bound` while provisioning |
| `cloud.machine.upgrade` | mutation, mutate-own | never | `machine upgrade` (hidden) | `cloud.machine.upgrade` | classic machines only; origin `user` only, gesture required |
| `cloud.snapshot.list` | read | default | `snapshot list` | `cloud.snapshot.list {machine?}` | one machine or the team |
| `cloud.snapshot.create` | mutation, mutate-own | default | `snapshot create` | `cloud.snapshot.create` | |
| `cloud.snapshot.restore` | mutation, mutate-own | opt_in | `snapshot restore` | `cloud.snapshot.restore` | a new machine; same-key retry returns it |
| `cloud.snapshot.delete` | mutation, destructive | never | `snapshot delete` (hidden) | `cloud.snapshot.delete {snapshot}` | origin `user` only, gesture required |
| `cloud.plan.get` | read | default | `plan get` | `cloud.plan.get` | limits and usage in one record; no plan logic in cmux |
| `cloud.billing.checkout` | mutation, mutate-own | never | `billing checkout` (hidden) | `cloud.billing.checkout` | an https URL the host opens; origin `user` only, gesture required |
| `cloud.migration.status` | read | default | `migration status` | `cloud.migration.status` | |
| `cloud.migration.start` | mutation, mutate-own | never | `migration start` (hidden) | `cloud.migration.start` | one way; origin `user` only, gesture required |
| `cloud.fs.list` | read | default | `fs list` | daemon `fs.list` (behind `fs-v1`) | one batch (no cursor) |
| `cloud.fs.stat` | read | default | `fs stat` | daemon `fs.stat` | |
| `cloud.fs.read` | read | default | `fs read` | daemon `fs.stat`, then `fs.read` | at most 16 MiB, else `file_too_large` before the bytes move |
| `cloud.fs.write` | mutation, mutate-shared | opt_in | `fs write` | daemon `fs.write` (`overwrite`, or `replace` with `baseRevision`) | at most 12 MiB raw (decision D2); `mode` answers `unsupported` |
| `cloud.fs.mkdir` | mutation, mutate-shared | opt_in | `fs mkdir` | daemon `fs.mkdir` | |
| `cloud.fs.remove` | mutation, destructive | never | `fs remove` (hidden) | daemon `fs.delete` | origin `user` only, gesture required |
| `cloud.file.push` | mutation, mutate-shared | never | `file push` (hidden) | daemon `fs.write` mode `create` | origin `user` only, gesture required; at most 12 MiB raw (decision D2) until the daemon has a write stream |
| `cloud.file.pull` | mutation, mutate-own | never | `file pull` (hidden) | the same | origin `user` only, gesture required; never overwrites a local file (`local_exists`) |
| `cloud.file.transfer.list` | read | default | `file transfer list` | none | running transfers, then at most 32 finished ones from the last hour (newest first); no local paths |
| `cloud.file.transfer.cancel` | mutation, mutate-own | never | `file transfer cancel` | none | stops a running transfer: `cancelling` now, then one `cloud.file.transfer.changed` with `state: cancelled` (`done` for a push whose copy had already finished); an ended transfer answers `ended` and no `cancelled` event follows (its own end event goes out after the answer when it was not sent yet); an id this server never issued is `not_found`; never replayed |
| `cloud.port.list` | read | default | `port list` | none | this Mac's forwards, up or down |
| `cloud.port.forward` | mutation, mutate-own | opt_in | `port forward` | the link (`loopback-forward-v1`) | 127.0.0.1 and a random port; one per (machine, port); never replayed |
| `cloud.port.close` | mutation, mutate-own | default | `port close` | none | |
| `cloud.browser.open` | mutation, mutate-own | opt_in | `browser open` | the link | a proxy route descriptor; opens no tab; never replayed |

Every op has `remote_relay: deny` and `queue_offline: false`. Every mutation needs an idempotency key (it rides the `apps-run` envelope); a read with a key is refused. The server records each attempt before the backend call and the result after a success, for the life of the process: the same key with the same op and args returns the recorded result with no call, the same key with another op or other args is `cmux.cloud.idempotency_conflict` (also after a failure), and refused args free the key. The backend gets the caller's key unchanged in the wire envelope; its own ledger compares the op and params (`idempotency.conflict`) and replays the stored result. One retry rule (`server/src/ops/delete_retry.rs`): when the outcome is unknown (`cmux.cloud.indeterminate` from `mutation.indeterminate`, or `relay_unavailable` after a lost answer), the answer is retryable and the caller retries with the SAME key; the server sends that key again and the backend resumes the call or answers the stored result. A delete retried after the delete answers `{deleted: true}` (the backend keeps a tombstone 30 days). Ids are checked against `[A-Za-z0-9][A-Za-z0-9_-]{0,127}`; names are 1 to 80 characters after trimming with no control characters; sizes are `{cpu?, memory_mb?, disk_mb?}` in the provider's range (the plan decides the rest).

Destructive and money ops (`cloud.machine.create`, `cloud.machine.resize`, `cloud.machine.delete`, `cloud.snapshot.delete`, `cloud.billing.checkout`, `cloud.migration.start`, `cloud.machine.upgrade`) need origin `user` (contract 1.1). Origin is not the caller's claim: the app supervisor stamps `user` only after its native confirmation sheet (app-platform.md 13.1 and 15), so these ops are hidden on the CLI and never on MCP. This server trusts the stamped origin; it cannot check it. The backend refuses agent principals for the same ops (`auth.forbidden`, here `cmux.cloud.forbidden`).

Errors are `cmux.cloud.*`: `file_too_large`, `transfer_failed`, `transfer_busy` (retryable), `local_exists`, `relay_busy` (retryable: more than 64 op lines arrived while a relay call waited), `port_limit`, `proxy_refused`, `listen_failed`, `auth_required` (`auth.unauthenticated`, or no sign-in at the host; the projection is cleared), `plan_required` (`cloud.plan.required`), `quota_exceeded` (`cloud.quota.exceeded`; `details` carries `{limit, used}`), `size_locked`, `provider_unavailable` (retryable), `not_bound`, `machine_paused`, `migration_unavailable`, `not_classic`, `upgrade_failed`, `indeterminate` (retryable with the same key), `forbidden`, `not_found`, `conflict`, `rate_limited`, `unsupported`, `upstream_error`, `bad_response`, `invalid_args`, `unknown_op`, `origin_refused`, `idempotency_key_required`, `idempotency_key_forbidden`, `idempotency_conflict`, `relay_unavailable`. A backend error keeps its `cmux.wire/1` code in `upstream_code` and its `details`. A backend op answers only the codes its catalog row declares (`server/src/ops/declared.rs`); any other code is `protocol_error`, never guessed at.

## Projection and refresh

The server is the only writer of the machine projection, and the projection is the only source of `cloud.machine.watch` events. It fills from `cloud.machine.list` pages, op answers and the team wire events `cloud.machine.upsert {machine}` and `cloud.machine.removed {machine, revision}` (`team.event` lines). Every record carries its backend `revision` (the team owner's event sequence); a record, answer or event older than the record held, or not newer than a removal seen, is dropped, so a late event never undoes a newer answer. A listing that starts at the first page and follows each `next_cursor` to the last removes the machines it did not see, unless they are newer than the first page's revision; a page out of order removes nothing. A delete, or `cloud.machine.not_found` on a get or delete, removes the record.

Each write that changes at least one record raises the revision by one and queues one event per changed record, all with that revision: `{type: "upsert", revision, machine}` (the full record) or `{type: "removed", revision, id}`. A write that changes nothing (a no-op refresh, an answer equal to the record) raises nothing and emits nothing. After each op result the serve loop sends the queued events as `{"type":"event","event":"cloud.machine.watch","data":<event>}` lines. Machine mutation results `{machine, revision}` (create, rename, start, pause, resize, idle policy, upgrade, snapshot restore) carry a top-level `revision`: the revision the change reached (the current one when nothing changed). A client settles its intent when its mirror has seen that revision. The ledger records the result with its revision, so a same-key replay answers the same revision and emits nothing. A delete keeps its `{deleted: true}` result; the `removed` event for the id settles it. There is no timer and no polling: the page and the sidebar read on open, on app activation and after a change (cloud-app.md DECISION 5).

## Files, ports and the browser route (C5)

Files go through the machine's cmux daemon on the link behind the `fs-v1` capability (`server/src/fs/link_files.rs`; `cmux.fs.provider/1` with `server: true` and scheme `cloud-vm` in the manifest; the provider view is `Server::fs_provider`). Guest paths are checked before any call: absolute, at most 4096 bytes, no `..` segment, no NUL or control character. Reads go in 1 MiB daemon ranges up to 16 MiB; one write carries at most 12 MiB raw (decision D2); larger writes and pushes answer `file_too_large` until the daemon has a write stream.

`cloud.file.push` and `cloud.file.pull` (contract 2.4): daemon `fs.*` ops on the link behind `fs-v1` (no SSH key, no scp, no Cloud API route); without the capability both answer `unsupported` naming it. A pull reads 1 MiB ranges into a hidden random name next to the target and is published with a hard link, which never overwrites and never follows a symlink placed at the target; a failed pull leaves nothing. A push is one `fs.write` with mode `create` (never overwrite), at most 12 MiB raw (D2) until the daemon has a write stream. At most 4 transfers run at once (`MAX_TRANSFERS`); a fifth answers `transfer_busy` (retryable) before any backend call, and nothing queues. Each copy runs on its own worker thread; the op answers at once with a transfer id, and the end is one `cloud.file.transfer.changed` event (`done`, `failed`, or `cancelled`). `cloud.file.transfer.cancel` stops the copy between chunks; a cancelled pull's landing file is removed. Push and pull are origin `user` only: the local path reaches any file this Mac's user can read or write, so a person picks it (the host's native file panel), never an agent; agents use `cloud.fs.read` and `cloud.fs.write`. Local paths are absolute without `.` or `..`.

Ports: `cloud.port.forward {machine, port}` listens on 127.0.0.1 and a port the system picks, and each accepted connection opens one `loopback-forward-v1` stream to `localhost:<port>` on the machine through the link's local socket (`PortTunnel`; the real one is `LoopbackTunnel`). There is one forward per (machine, port) and one browser route per machine; `Edge` is their only writer and the op loop its only caller. A forward belongs to one link generation, and each new connection first checks that the link socket file is still the one the forward saw (a new generation binds a new file at the same path), so an old forward never reaches a new link. When the link goes down or is replaced, the serve loop closes the listener and its connections at once (a link process event wakes it; no op is needed) and the record shows `down` with a reason. The host gets the link change first, then one `{"type":"event","event":"cloud.port.changed","kind":"forward"|"browser","machine","port"?,"host","localPort","generation","state":"down","reason"}` line per closed forward or route, in (machine, port) order. Nothing is queued; a new `cloud.port.forward` opens a new listener on the new link. `POST /api/vm/:id/open-port` is a different feature (a public preview URL with a bearer token through the provider edge); these ops do not use it.

`cloud.browser.open {machine, port, host?, path?}` answers `{proxy: {kind: "http", host: "127.0.0.1", port}, url}`. The route is an HTTP proxy for `CONNECT` and absolute-form HTTP/1.1 that reaches only the machine: `localhost`, a name under `.localhost` or a loopback literal, decided from the text without DNS. Other hosts get 403 (and `proxy_refused` at the op); origin-form requests get 400, so a page cannot use the route directly.

## Test notes: rescue backend rules under mutation

Since C13 the backend uses the shared `cmux-terminal-iface` crate: input and output are data frames with the shared credit rule (`ReceiveWindow`, `SendWindow`). The input `seq` rules R1, R1b, R7 and R8 are gone (a gap, an overlap or data past the credit ends the terminal with `lost`, tests in `rescue_conformance.rs` and `rescue_rules.rs`), and R17 and R21 now live in the shared crate. The table and its file:line references describe the mirror-era backend at 097f7941743; the mutation run was not repeated after C13.

Each rule of the rescue backend (`server/src/rescue/backend.rs`, the local id and kind rules in `rescue/iface.rs`) was removed one at a time on a Testbox pinned to 097f7941743 (never committed; restored with `git checkout -- <file>`), and the rescue tests (`attach_rescue`, `rescue_conformance`, `rescue_rules`) ran. Every mutation fails at least one test on its assertion. The tests in `rescue_rules.rs` were added because no test failed under their mutation in the first run (bdc94453583); in that run the first R1 mutation (drop the stale-seq check) failed only on an integer overflow panic in the backend, not on an assertion, so the R1 MUTATION (not the rule) was changed: it now answers `Ok` for a stale seq.

| Rule | Mutation | Fails (test, file:line) |
| --- | --- | --- |
| R1 each written seq once | a seq below the next one answers `Ok` | `write_order_is_kept_by_seq` attach_rescue.rs:50; `rescue_concurrent_writes_keep_seq_order` rescue_conformance.rs:185 |
| R1b each held seq once | no check for a seq already held | `a_held_seq_is_written_once` rescue_rules.rs:48 |
| R2 refusal after close | `close` does not mark the stream closed | `close_ends_the_terminal_at_once` attach_rescue.rs:103; `rescue_close_refuses_later_calls` rescue_conformance.rs:232 |
| R2b refusal when not open | `open_stream` accepts any status | 6 tests, e.g. `rescue_far_exit_gives_exit_status` rescue_conformance.rs:210 |
| R2c, R2d resize, signal refused when not open | no `open_stream` check | `rescue_close_refuses_later_calls` rescue_conformance.rs:233, 234 |
| R3 lost on transport drop | a drop ends with `exit` | `transport_drop_gives_lost_and_no_input_queues` attach_rescue.rs:132; `rescue_transport_drop_gives_lost` rescue_conformance.rs:221 |
| R4 output offsets contiguous | offset = chunk length, not the running total | `output_reaches_the_terminal` attach_rescue.rs:70; `rescue_output_offsets_are_contiguous` rescue_conformance.rs:96 |
| R5 nothing after close | the pump delivers to any status | `close_ends_the_terminal_at_once` attach_rescue.rs:106 |
| R5b one end event, then nothing | the pump delivers after `exit`/`lost` | `nothing_follows_the_end_event` rescue_rules.rs:62 |
| R6 no empty output event | empty chunks become events | `empty_output_gives_no_event` rescue_rules.rs:72 |
| R7 held seq at most 256 ahead | no distance check | `a_seq_too_far_ahead_is_refused` rescue_rules.rs:83 |
| R8 held bytes at most 1 MiB | no byte check | `held_input_is_bounded` attach_rescue.rs:190 |
| R9 one write at most `max_write_bytes` | no size check | `a_write_over_max_write_bytes_is_invalid` rescue_rules.rs:93 |
| R10, R10b, R10c far-end text bounded | no cut of exit message, exit signal, lost reason | `far_end_text_is_bounded` attach_rescue.rs:122, 123; `a_lost_reason_from_the_far_end_is_bounded` rescue_rules.rs:109 |
| R11 a failed write ends the terminal | the error returns, the stream stays open | `a_transport_failure_is_a_typed_error_and_ends_the_terminal` attach_rescue.rs:175 |
| R12 a lost stream is closed once | close again on drop | the same test, attach_rescue.rs:178 |
| R13 no close of a stream the far end freed | a far close does not mark it released | `a_stream_the_far_end_closed_is_never_closed_again` rescue_rules.rs:120 |
| R14 drop closes the far shell | no close on drop | `dropping_an_open_terminal_closes_the_far_shell` rescue_rules.rs:128 |
| R15 close closes the transport stream | no transport close | `close_ends_the_terminal_at_once` attach_rescue.rs:101 |
| R16 close drops undelivered output | events kept at close | `close_drops_output_that_was_not_taken` rescue_rules.rs:137 |
| R17 default deny of kinds | `allow_kind` accepts any kind | `the_backend_refuses_kind_ssh_and_resume` attach_rescue.rs:145; `rescue_other_kind_is_refused` rescue_conformance.rs:129 |
| R18 login shell only | a command is accepted | `a_command_is_unsupported` rescue_rules.rs:147 |
| R19 grid needs columns and rows | no zero check | `a_grid_without_columns_or_rows_is_invalid` rescue_rules.rs:155 |
| R20 resume unsupported | resume answers `invalid` | `the_backend_refuses_kind_ssh_and_resume` attach_rescue.rs:156 |
| R21 local ids up to 64 characters | 32-character limit | `local_ids_follow_the_interface_pattern` attach_rescue.rs:161 |

Not a rule under test: `close` also clears held input, but held input never reaches the transport after close either way, so no test can see it (memory only).

## Gaps

- CLI paths are app-relative (R73 S1). `cloud` is a reserved CLI word (built-in `cmux cloud`), so the manifest has no `cli.name` and the verbs run as `cmux apps run cmux/cloud <path>` until the CLI owner maps the reserved word to this first-party app.
- The catalog fragment schema has no `aliases` field. Aliases (`cmux.cloud.*`, `cloud.machine.resume`, the `vm.*` relay names) live only in the server's table, so the CLI and MCP do not offer them. For a `vm.*` name the server maps the relay args (`vm_id` to `machine`, `snapshot_id` to `snapshot`).
- The fragment validator needs op names in the fragment's family, so the fragment says `cloud.machine.list`, not `cmux.cloud.machine.list`.
- Not declared yet (other packages): `auth.sign_in`, `auth.sign_out`, `team.list`, `team.select` (host credential owner). Network, firewall, tunnel, domain and publication ops are dropped in v1 (contract 5, C1).
- The `vm.*` relay names keep their id mapping, but their other args now follow the cmux.wire/1 shapes (`name`, `size`), not the classic ones.
- Files: no list cursor, no read range, no write revision and no `watch` on the Cloud API file routes; each answers `unsupported` through the provider instead of pretending. A root is the scheme plus the machine id until `root_…` handles reach app servers.
- `cloud.port.list` lists this Mac's forwards, not the ports that listen on the machine (no route for that).
- The browser route opens no tab: the browser host needs a per-tab proxy op (`browser.tab.open {url, proxy}`, cloud-app.md 5.3). Any local process can use a forward or the route, like an SSH `-L` forward: the Swift proxy checks the peer process, which this server cannot do for browser helpers that are not its children.
- `LoopbackTunnel` opens one link connection per TCP connection (three round trips), not one multiplexed connection per machine.
- Each daemon file op has a 30 s bound for the whole exchange (dial, reply line, request, answer); in the serve loop it runs on its own worker (at most `MAX_FILE_OPS` = 8, one more answers `file_ops_busy`), and the end of the host's input cancels the running ones. The `fs-v1` gate reads `connect_info` once per machine and caches it for 300 s (dropped on a machine event, a link down or a start); a pull has no overall deadline, and `cloud.file.transfer.cancel` stops it between chunks. Not verified against a live daemon (no daemon has `fs-v1` yet).
- Transfer ids (`transfer-<n>`) are unique per server process only: after a restart, `transfer-1` names a new transfer.
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

## Design: the relay call that blocks the serve loop (later slice)

Now: an op that needs the Cloud API calls `ControlPlane::call`, and `HostRelay` writes one `relay.op` and reads host lines until the matching `relay.result` or `relay.error`. The serve loop is blocked for that time: link wakes, transfer ends and other ops wait. Op lines that arrive meanwhile are kept in order (at most `RELAY_QUEUE_LINES` = 64; one more gets `cmux.cloud.relay_busy`, retryable), host frames are kept (a newer `host.event` replaces the waiting one of the same op), and wakes are taken after the call. The host answers every relay request (its own HTTP deadline gives `relay.error`), so the wait ends; the server has no timer.

Later slice (async relay), the same shape as C10's link waits (`link/park.rs`):

1. `HostRelay::call` no longer reads. It writes the `relay.op`, records the request id, and returns an internal `RELAY_WAIT` with that id. The op that called it is parked: `{op line id, request, relay ids answered so far}`. The op's result line goes out later.
2. Relay answers arrive through the inbox like every other host line. The loop matches `relay.response`/`relay.error` by id, stores the answer with the parked op, and runs the op again with the same request and key. The op reruns from the start; each `call` takes the next stored answer in call order, so an op with two calls parks twice. Ops stay deterministic up to each call: they change the projection, the ledger and the edge only after their answers, as today.
3. Ordering: at most one parked op per idempotency key and per machine for mutations; a second mutation of the same machine waits behind the first (FIFO per machine), reads do not. This keeps today's order for writes to one resource without blocking the loop.
4. Bounds: parked relay ops at most 64 (the inbox bound); one more answers `relay_busy`. Late answers (no parked op with that id) are dropped with a stderr line, as now. When the host closes the channel, every parked op answers `relay_unavailable`.
5. The ledger records the attempt before the first call, as now. A same-key retry that arrives while the op is parked joins it: both op line ids get the one answer, and there is no second Cloud API call.
6. No timers: the host's HTTP deadline ends every relay request with an answer.

Tests for the slice: a relay call does not block a link wake (a `cloud.link.changed` line goes out before the relay answer); two ops with interleaved answers each get their own result; a same-machine mutation waits for the first; 65 parked ops give one `relay_busy`; a closed channel answers every parked op.

## Proposals for the app platform lead (not used in this manifest)

1. `server: true` inside an `implements` entry and `kinds` on implementations, so `cmux.terminal.connector/1` and `cmux.terminal.backend/1` can be served by this server for `cloud-vm` and `cloud-vm-rescue` (C2 needs them).
2. A `cache` data class (rebuildable state that may be dropped at any time); the projection uses `ephemeral` until then.
