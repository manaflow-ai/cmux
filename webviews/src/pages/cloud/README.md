# Cloud page (`cmux-page://cmux.cloud/`)

The React page of the `cmux/cloud` app (plans/cmux-next/cloud-app.md, layer L7). It talks only
through `PageClient` (`../shared/pageClient.ts`): `call` and `subscribe` on the `cmux.cloud`
namespace, plus the native UI op `cmux.app.action.run`. It speaks the shapes the Cloud app server
`cmux-cloud` answers in the `cmux.wire/1` era (plans/cmux-next/cloud-client-contract.md 1.2 to 1.5
and 4; server `first-party-apps/cloud/server/src/ops/*.rs`, `src/api/models.rs`, `src/fs/*.rs`).

## Files

| File                                            | Role                                                                                                                                  |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `ops.ts`                                        | Op names, `NATIVE_ACTIONS`, error codes and the snake_case records (`CloudMachine`, `CloudSnapshot`, `CloudPlan`, `MigrationStatus`). |
| `store.ts`                                      | Page-side state: machine mirror (list pages once, then `cmux.cloud.machine.watch` events), the pending intent log, create draft.      |
| `account.ts`                                    | Teams (not served), plan read and re-read, "See plans" checkout (kept for when billing lands), the classic migration banner state.    |
| `detail.ts`                                     | Reads and changes for the selected machine: snapshots, port forwards, browser route.                                                  |
| `files.ts`, `transfers.ts`                      | Files over the machine daemon (`fs-v1`) and push/pull transfers settled by `cmux.cloud.file.transfer.changed`.                        |
| `model.ts`                                      | Pure logic: events into the mirror, intent settlement, visible rows, classic rows, plan sizes, labels.                                |
| `mockProvider.ts`, `mockData.ts`, `mockEdge.ts` | In-memory provider for tests and the dev loop. It answers like the server: same fields, guards (origin, key, args) and error codes.   |
| `Localizable.xcstrings`                         | String source (21 languages). `node webviews/scripts/pages/gen-strings.mjs` writes `generated/strings.json`.                          |

## Rules the page keeps

- No polling and no timers. The list changes only from the watch stream; the detail is read on
  selection and after a confirmed change; the plan is read on sign-in and after a confirmed change
  that may move its usage.
- One pending intent log (OWNERSHIP-PRINCIPLES "Clients are projections"). A machine mutation answers
  `{machine, revision}`: the intent settles when the mirror reaches that projection revision (no
  refetch), or when the record shows the change. The record's own `revision` is a decimal string.
- Every mutation sends an idempotency key. The create sheet keeps one key for its life.
- Money, destructive and one-way ops never run from the page (ops.ts `NATIVE_ACTIONS`): create,
  resize, delete, upgrade, snapshot create, restore and delete, billing checkout, migration start,
  file remove, push and pull, connect, sign-in and sign-out. The page calls
  `cmux.app.action.run {action: <op name>, args}`; the host confirms (or shows its file panel), stamps
  origin user, runs the op and answers its result fields at the top level, or `{confirmed: false}`.
  The server refuses these ops from any other origin (`origin_refused`); the mock does too.
- Create sends `{name?, size: {memory_mb}, from_snapshot?}`. The sheet shows the plan's
  `memory_options_mb`; sizes in `locked_memory_options_mb` show disabled with "Not in your plan".
  The page computes no limit: `plan_required`, `quota_exceeded {limit, used}` and `size_locked` show
  as localized sentences (in the sheet for a create, else as a page notice) with "See plans", which
  links the public plans page (`PLANS_URL`, opened outside the page on the click) when a plan lifts
  the limit (the error's `details.plan`, else `CloudPlan.upgrade_plan`). Billing is not built
  (`cloud.billing.checkout` answers owner.unreachable); "See plans" runs the checkout when it lands.
- Classic machines (`classic: true`, contract 4) show a "Classic" badge and are read-only: no
  inline or header actions, no ports or files, snapshots listed without actions. A one-time banner
  ("Machines from cmux Cloud classic: N") shows while `cloud.migration.status` is `available` with
  `classic_count > 0`; "Later" hides it for the page session, "Move them" runs
  `cloud.migration.start`. After the move (`moved`), Upgrade runs `cloud.machine.upgrade` per machine.
- A delete or remove answered `cmux.cloud.not_found` found the item gone: no error.
- Files are daemon ops behind `fs-v1`: a machine whose daemon lacks it answers
  `cmux.cloud.unsupported`, and only that machine's Files section shows "Not available yet". Reads
  are at most 16 MiB, writes and pushes at most 12 MiB (`file_too_large`); `file_ops_busy` and
  `transfer_busy` are retryable. A save after a preview sends the read `revision` as `baseRevision`.
- No Cmd or Ctrl chord handling. Plain Up/Down/Return/Escape in a focused list or field only.

## Not served (the page shows "Not available yet")

Sign-in, sign-out, team list and team select (no catalog declares them yet;
first-party-apps/cloud/README.md "Gaps"). The mock answers them with an unknown-op error
(`SERVER_GAPS`); `/cloud/?mock=all` serves them for design work. Removed in v1 (contract 1.3, C1):
network, tunnel, firewall, domain and publication ops, `snapshot.fork`, `machine.stats`,
`usage.get` (folded into `plan.get`) and `billing.open` (now `billing.checkout`).

## Host gaps

- Live route: the page's consumed `cloud.*` ops reach `cmux-cloud` only when the host routes them
  (D-ROUTE). That route stays off until the app-host generator guard lands; the page has no flag of
  its own and changes nothing when it turns on.
- `browser.tab.open` is served by the app (`RemoteLocalhost/BrowserTabOpen.swift`) for this page
  only. Open in browser calls it with
  `{url, machineStore: {machine, machineName, proxy}, engine: "cef"}` from `cloud.browser.open`.
  The app opens a CEF tab whose store sends every request,
  loopback included, to the HTTP proxy on 127.0.0.1; any other engine, proxy or URL is a typed
  refusal (`cmux.browser.*`), never an unproxied tab.
- File push sends `{machine, path: <current folder>}`; the host's file panel adds `localPath` and the
  file name. Pull sends `{machine, path}`; the save panel picks `localPath`.
- The host must deliver the server's `cloud.machine.watch` and `cloud.file.transfer.changed` lines as
  page events, move `idempotency_key` from the params to the op request's key, and pass the server
  error's `details` (`{limit, used}`, `{plan}`) to the page error.
- The watch revision has no server epoch: after a server restart the host must restart the page.

## Machine list layout (prototype variants)

`rows` (default) or `cards`: the host sets `data-cloud-machines-layout` on `<html>` from the Debug
setting **`cloud.machines.layout`**; in the dev loop use `/cloud/?mock&layout=cards`.

## Dev loop

`cd webviews && bun run dev`, then open `/cloud/?mock` (or `/cloud/?mock=all`).
