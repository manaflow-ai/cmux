# Cloud page (`cmux-page://cmux.cloud/`)

The React page of the `cmux/cloud` app (plans/cmux-next/cloud-app.md, layer L7). It talks only
through `PageClient` (`../shared/pageClient.ts`): `call` and `subscribe` on the `cmux.cloud`
namespace, plus the native UI op `cmux.app.action.run`.

## Files

| File                             | Role                                                                                                                                |
| -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `ops.ts`                         | Op names and param/result types of `cmux.cloud`. Hand-written until the generated client exists; swap this one file for it.         |
| `store.ts`                       | Page-side state: machine mirror (list once, then `cmux.cloud.machine.watch` events), the pending intent log, create draft, account. |
| `detail.ts`                      | Reads and changes for the selected machine (stats, snapshots, publications, domains, network, firewall).                            |
| `model.ts`                       | Pure logic: events into the mirror, intent settlement, visible rows, labels.                                                        |
| `mockProvider.ts`, `mockData.ts` | In-memory provider for tests and the dev loop. Creates nothing real.                                                                |
| `Localizable.xcstrings`          | String source (21 languages). `node webviews/scripts/pages/gen-strings.mjs` writes `generated/strings.json`.                        |

## Rules the page keeps

- No polling and no timers. The list changes only from the watch stream; detail sections are read
  on selection and after a confirmed change; stats refresh on selection or Refresh.
- One pending intent log (OWNERSHIP-PRINCIPLES "Clients are projections"): an intent shows on its
  row until the owner's echo (the watch event that shows its effect) or its reject.
- Every mutation sends an idempotency key. The create sheet keeps one key for its life, so a double
  submit or a retry creates one machine.
- Machine delete, snapshot delete, publication delete, firewall create and delete, billing and
  connect never call their op from the page. The page calls
  `cmux.app.action.run {action: <op name>, args}`; the host shows the native confirmation, stamps
  origin user and runs the op. A declined sheet answers `{confirmed: false}`.
- No Cmd or Ctrl chord handling. Plain Up/Down/Return/Escape in a focused list or field only.

## Machine list layout (prototype variants)

Two layouts: `rows` (dense rows, default) and `cards`. The page reads the choice from its init:

- In the app: the host sets `data-cloud-machines-layout="rows|cards"` on `<html>` from the Debug
  setting **`cloud.machines.layout`**.
- In the dev loop: `/cloud/?mock&layout=cards`.

## Dev loop

`cd webviews && bun run dev`, then open `/cloud/?mock`.
