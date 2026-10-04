# Cloud page (`cmux-page://cmux.cloud/`)

The React page of the `cmux/cloud` app (plans/cmux-next/cloud-app.md, layer L7). It talks only
through `PageClient` (`../shared/pageClient.ts`): `call` and `subscribe` on the `cmux.cloud`
namespace, plus the native UI op `cmux.app.action.run`.

## Files

| File                                            | Role                                                                                                                                               |
| ----------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ops.ts`                                        | Op names and param/result types of `cmux.cloud`, camelCase like the catalog. Hand-written until the generated client exists.                       |
| `store.ts`                                      | Page-side state: machine mirror (list once, then `cmux.cloud.machine.watch` events), the pending intent log, create draft, account.                |
| `detail.ts`                                     | Reads and changes for the selected machine (stats, snapshots, publications, domains, network, firewall, ports, browser route).                     |
| `files.ts`                                      | The Files section: list on demand, stat then read for a small text preview, mkdir and write; remove, push and pull as native actions.              |
| `model.ts`                                      | Pure logic: events into the mirror, intent settlement, visible rows, labels.                                                                       |
| `mockProvider.ts`, `mockData.ts`, `mockEdge.ts` | In-memory provider for tests and the dev loop, shaped like the server's fixtures; it refuses args the catalog does not list. Creates nothing real. |
| `Localizable.xcstrings`                         | String source (21 languages). `node webviews/scripts/pages/gen-strings.mjs` writes `generated/strings.json`.                                       |

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
- Machine delete, snapshot delete, publication create and delete, firewall create and delete,
  tunnel attach and rotate_key, file remove, push and pull, billing and connect never call their op
  from the page (ops.ts `NATIVE_ACTIONS`). The page calls
  `cmux.app.action.run {action: <op name>, args}`; the host shows the native confirmation (or file
  panel), stamps origin user and runs the op. A declined sheet answers `{confirmed: false}`.
- Publication create always sends the access mode the form shows (default `personal`), so the
  confirmation names the mode that applies; `public` also sends `confirmPublic: true`.
- Files read nothing until Browse. A preview states the file first and reads it only when it is at
  most 256 KiB; larger files show their size. Ports show the `127.0.0.1` port the owner answered.
- No Cmd or Ctrl chord handling. Plain Up/Down/Return/Escape in a focused list or field only.

## Ops the server does not serve yet

Team list and select, sign-in and sign-out, billing and the idle policy. The server answers
`cmux.cloud.unsupported` or an unknown-op error; the page records the op in `unavailable` and shows
"Not available yet" for it, never the error banner. The mock answers the same way (`SERVER_GAPS`);
`/cloud/?mock=all` serves them all for design work. Domains, publications, network, tunnel,
firewall (R71 C6), files, ports and the browser route (R71 C5) are served.

## Host gaps

- `browser.tab.open` (owner: the browser lead) is not served yet. Open in browser calls
  `cmux.app.action.run {action: "browser.tab.open", args: {url, machineStore: {machine,
machineName, proxy: {kind, host, port}}, engine: "cef"}}` with the route from
  `cloud.browser.open`. Only CEF honors a machine store; WebKit refuses a proxied configuration
  with a typed error. A typed refusal shows a message; the page never retries in WebKit and never
  opens the URL without the proxy. Until the host serves the action the URL shows with "Not
  available yet". The host derives the store's `machineKey` from `machine`.
- Tunnel attach and rotate_key: the page sends `{network}` and `{}`. The host adds
  `deviceFingerprint` (and `clientPublicKey` for a rotation) from `cmux link`, which will own them;
  the page never sees a key.
- File push: the page sends `{machine, path: <current folder>}`. The host's file panel picks
  `localPath` and the host appends the file's name to `path`. File pull: the page sends
  `{machine, path}`; the host's save panel picks `localPath`.

## Platform gaps

- The host does not yet map the server's `cloud.machine.watch` event lines to page subscriptions
  of `cmux.cloud.machine.watch`, and does not yet move `idempotency_key` from the params to the op
  request's key.
- The Cloud API has no account-wide snapshot list: the create sheet offers the selected machine's
  snapshots only.
- The watch revision has no server epoch (first-party-apps/cloud/README.md "Gaps"): after a server
  restart the host must restart the page session.
- The mock delivers each echo event before it answers (the server answers first); tests with
  `holdEvents` cover the server's order.
- The record has no size or idle policy: the size shows from the stats; resize and idle intents
  settle by revision only.

## Machine list layout (prototype variants)

Two layouts: `rows` (dense rows, default) and `cards`. The page reads the choice from its init:

- In the app: the host sets `data-cloud-machines-layout="rows|cards"` on `<html>` from the Debug
  setting **`cloud.machines.layout`**.
- In the dev loop: `/cloud/?mock&layout=cards`.

## Dev loop

`cd webviews && bun run dev`, then open `/cloud/?mock` (or `/cloud/?mock=all`).
