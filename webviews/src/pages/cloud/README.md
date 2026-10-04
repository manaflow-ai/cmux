# Cloud page (`cmux-page://cmux.cloud/`)

The React page of the `cmux/cloud` app (plans/cmux-next/cloud-app.md, layer L7). It talks only
through `PageClient` (`../shared/pageClient.ts`): `call` and `subscribe` on the `cmux.cloud`
namespace, plus the native UI op `cmux.app.action.run`.

## Files

| File                             | Role                                                                                                                                |
| -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `ops.ts`                         | Op names and param/result types of `cmux.cloud`, camelCase like the catalog. Hand-written until the generated client exists.        |
| `store.ts`                       | Page-side state: machine mirror (list once, then `cmux.cloud.machine.watch` events), the pending intent log, create draft, account. |
| `detail.ts`                      | Reads and changes for the selected machine (stats, snapshots, publications, domains, network, firewall).                            |
| `model.ts`                       | Pure logic: events into the mirror, intent settlement, visible rows, labels.                                                        |
| `mockProvider.ts`, `mockData.ts` | In-memory provider for tests and the dev loop, shaped like the server's fixtures. Creates nothing real.                             |
| `Localizable.xcstrings`          | String source (21 languages). `node webviews/scripts/pages/gen-strings.mjs` writes `generated/strings.json`.                        |

## Rules the page keeps

- No polling and no timers. The list changes only from the watch stream; detail sections are read
  on selection and after a confirmed change; stats refresh on selection or Refresh.
- One pending intent log (OWNERSHIP-PRINCIPLES "Clients are projections"): an intent shows on its
  row until the owner's echo or its reject. A machine mutation answers a top-level `revision`; the
  intent settles when the mirror reaches that revision on the watch stream (no refetch). An answer
  without a revision (a native action) settles on the machine's next event.
- Every mutation sends an idempotency key. The create sheet keeps one key for its life, so a double
  submit or a retry creates one machine.
- Create takes `displayName`, `memoryMb` (one of the plan's `memoryOptionsMb`) and `kind`. Create
  from a snapshot, and Restore on a snapshot, call `snapshot.restore {snapshot}`: a new machine.
  Fork calls `snapshot.fork {machine}`: a copy. All three show a pending create row until the echo.
- Machine delete, snapshot delete, publication delete, firewall create and delete, billing and
  connect never call their op from the page. The page calls
  `cmux.app.action.run {action: <op name>, args}`; the host shows the native confirmation, stamps
  origin user and runs the op. A declined sheet answers `{confirmed: false}`.
- No Cmd or Ctrl chord handling. Plain Up/Down/Return/Escape in a focused list or field only.

## Ops the server does not serve yet

Domains, publications, network, firewall, team list and select, sign-in and sign-out, billing and
the idle policy. The server answers `cmux.cloud.unsupported` or an unknown-op error; the page
records the op in `unavailable` and shows "Not available yet" for it, never the error banner. The
mock answers the same way (`SERVER_GAPS`); `/cloud/?mock=all` serves them all for design work.

## Platform gaps

- The host does not yet map the server's `cloud.machine.watch` event lines to page subscriptions
  of `cmux.cloud.machine.watch`, and does not yet move `idempotency_key` from the params to the op
  request's key.
- The Cloud API has no account-wide snapshot list: the create sheet offers the selected machine's
  snapshots only.
- The record has no size or idle policy: the size shows from the stats; resize and idle intents
  settle by revision only.

## Machine list layout (prototype variants)

Two layouts: `rows` (dense rows, default) and `cards`. The page reads the choice from its init:

- In the app: the host sets `data-cloud-machines-layout="rows|cards"` on `<html>` from the Debug
  setting **`cloud.machines.layout`**.
- In the dev loop: `/cloud/?mock&layout=cards`.

## Dev loop

`cd webviews && bun run dev`, then open `/cloud/?mock` (or `/cloud/?mock=all`).
