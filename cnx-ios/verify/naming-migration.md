# Naming migration: cnx → cmux-next iOS (2026-10-13)

The user asked that external resources (servers, databases, keys) use the name
"cmux-next iOS", never the "cnx" abbreviation. This file records what moved, what
still runs under the old names, and what is left.

## Old → new

| Resource | Old | New | State |
| --- | --- | --- | --- |
| Dev Worker | `cnx-ios-api-dev` (https://cnx-ios-api-dev.debussy.workers.dev) | `cmux-next-ios-api-dev` (https://cmux-next-ios-api-dev.debussy.workers.dev) | New deployed. Old still running (installed builds use it) |
| Prod Worker | `cnx-ios-api-prod` | `cmux-next-ios-api` | New deployed. Old still running |
| Prod custom domain | `cnx-ios-api.cmux.dev` → `cnx-ios-api-prod` | `cmux-next-ios-api.cmux.dev` → `cmux-next-ios-api` | Old domain still on the OLD Worker until the new one has secrets (morning step 3) |
| Dev database | PlanetScale `cmux/cnx-ios` (role `cnx-ios-dev`) | `cmux/cmux-next-ios-dev` (PS-5 ARM single node, us-east, role `cmux-next-ios-dev`) | Migrated (0000, 0001), rows copied (206 devices, 4 prefs, 0 push tokens) |
| Prod database | `cmux/cnx-ios-prod` (role `cnx-ios-prod`) | `cmux/cmux-next-ios` (PS-5 ARM single node, us-east, role `cmux-next-ios`) | Migrated, rows copied (0 devices, 1 pref, 0 push tokens) |
| Dev Hyperdrive | `cnx-ios-dev` `e4fd2e88cfcd4f00841ddc5b49c3ee06` | renamed `cmux-next-ios-dev`, same id, repointed to the new DB | Done |
| Prod Hyperdrive | `cnx-ios-prod` `11158756425f41469964743aab2f6319` | renamed `cmux-next-ios`, same id, repointed to the new DB | Done |
| Rate limit namespaces | 4101-4104 (dev), 4201-4204 (prod) | same ids on the new Workers | Shared counters, intended |
| 1Password prod DB role | "cnx-ios prod PlanetScale role" | "cmux-next iOS prod PlanetScale role" (new item for role `cmux-next-ios`) | NOT DONE (op blocked) |
| 1Password prod test account | "cmux Stack production test account (cnx-ios e2e)" | "cmux Stack production test account (cmux-next iOS e2e)" | NOT DONE (op blocked) |
| 1Password APNs key | already "cmux-next iOS APNs Auth Key (dev.cmux.app.internal)" | unchanged | OK |
| iOS Production display name | "cmux cnx" | "cmux next" | In code (project.yml, demo-build.sh) |
| iOS test bundle ids | `dev.cmux.cnx` (Debug), `dev.cmux.cnx.cnx` (demo), `dev.cmux.cnx.<tag>`, `dev.cmux.cnx.prod` | `dev.cmux.next.ios`, `dev.cmux.next.ios.demo` (default demo tag is now `demo`), `dev.cmux.next.ios.<tag>`, `dev.cmux.next.ios.prod` | In code. TestFlight stays `dev.cmux.app.internal` / "cmux INTERNAL" |
| Code URLs | project.yml `CNX_PROD_API_BASE`, Release/Production `CNX_API_BASE`, `CnxAuthModel` dev fallback, `run-host.sh`, `smoke.ts`, `e2e-mac.sh`, docs | new URLs | In code on `feat-cnx-ios-naming` |

Why the Hyperdrive configs were renamed in place: the Cloudflare account is at
its limit of 25 Hyperdrive configs, so new ones could not be created. Renaming
and repointing means the old and new Workers now read and write the same new
databases. Nothing writes to the old databases any more; their rows were
copied before and again after the repoint (newer `updated_at` wins).

Durable Objects are per Worker: a phone on the new dev Worker and a Mac on the
old one share the device registry but not live signaling. Build the Mac and iOS
sides of a pair from the same URLs.

## Secrets

Old Workers have TURN (`TURN_KEY_ID`, `TURN_KEY_API_TOKEN`) and APNs
(`APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID`). The new Workers have NONE:
`op` returned "authorization timeout" (the user was asleep), retried twice,
then stopped. `STACK_SECRET_SERVER_KEY` is not set on any Worker.

## Verification (2026-10-13, 21:30 PT)

- New dev Worker, full `scripts/smoke.ts` with a dev-project test account: all
  checks pass except `ice turn` (no TURN secret yet); notify `configured false`
  (no APNs secret yet).
- Old dev Worker on the new database: all checks pass (TURN 6 urls; notify
  `configured true`, fake production token dropped).
- `/v1/health` answers ok (0.7.0, production Stack project only) on
  https://cmux-next-ios-api.cmux.dev, https://cmux-next-ios-api.debussy.workers.dev,
  https://cnx-ios-api.cmux.dev and https://cnx-ios-api-prod.debussy.workers.dev.
- NOT RUN: the authenticated prod smoke test (old or new prod Worker). The prod
  test account is only in 1Password.
- Backend `tsc` and `vitest` (37 tests) pass.

## Morning steps (in order)

1. `cd cnx-ios/backend && scripts/put-secrets.sh dev && scripts/put-secrets.sh prod`
   (needs `op` approval; it refuses empty values).
2. Smoke tests against the new URLs. Dev:
   `STACK_EMAIL=... STACK_PASSWORD=... bun scripts/smoke.ts` (dev test account,
   1Password `sirnczouv25kkvpzlbhnpxpqo4`). Prod: the same with
   `CNX_BASE_URL=https://cmux-next-ios-api.cmux.dev STACK_PROJECT_ID=9790718f-14cd-4f7e-824d-eaf527a82b82 STACK_PUBLISHABLE_CLIENT_KEY=`
   and the prod test account (1Password `n5aszrw7k5gf5djiypwqatza7y`). Expect
   `ice turn` PASS and notify `configured true`, `dropped 1`. Also run the prod
   smoke once with `CNX_BASE_URL=https://cnx-ios-api.cmux.dev`.
3. Move the old domain to the new Worker: add
   `{ "pattern": "cnx-ios-api.cmux.dev", "custom_domain": true }` to the prod
   `routes` in `backend/wrangler.jsonc`, `bunx wrangler@4 deploy --env prod`,
   then rerun the prod smoke against both domains.
4. 1Password: `op item edit n5aszrw7k5gf5djiypwqatza7y title="cmux Stack production test account (cmux-next iOS e2e)"`.
   Create "cmux-next iOS prod PlanetScale role" from the role file
   `~/.config/cmux-next-ios-private/prod-role.json` (and a dev one from
   `dev-role.json`), then delete the local files.
5. Merge `feat-cnx-ios-naming` into `feat-cnx-ios` (switches builds to the new
   URLs and bundle ids), and the machost owner updates the Mac side (below).
   Then cut a new Mac + iOS build pair.

## Left to delete (after step 5 and a working new build pair)

- Worker `cnx-ios-api-dev` (keep until a Mac+iOS pair on the new dev URL exists).
- Worker `cnx-ios-api-prod` (after step 3 nothing routes to it but
  `cnx-ios-api-prod.debussy.workers.dev`).
- The `cnx-ios-api.cmux.dev` custom domain, once no installed build uses it.
- PlanetScale databases `cmux/cnx-ios` and `cmux/cnx-ios-prod` (no longer
  written; they hold read-only migration roles `cmux-next-ios-migration-ro`).
- 1Password "cnx-ios prod PlanetScale role" (`jnqtfagjg52s2xxzggzsuzm6ju`),
  after step 4.
- `APNS_TOPICS` entries `dev.cmux.cnx`, `dev.cmux.cnx.cnx`, `dev.cmux.cnx.prod`
  in `backend/wrangler.jsonc`, once no old test build is installed.

## For the machost owner (`feat-cnx-ios-machost`)

- `Packages/macOS/CmuxNext/Sources/CmuxNextMobileHost/IPhoneHostService+Wiring.swift`:
  `productionAPI` → `https://cmux-next-ios-api.cmux.dev`, `developmentAPI` →
  `https://cmux-next-ios-api-dev.debussy.workers.dev` (on `feat-cnx-ios` the
  same URL is `AppServices+IPhone.swift` `cnxDevelopmentAPI`). Switch together
  with the iOS side.
- The side-by-side Mac build "cmux NEXT cnx": use a tag without "cnx", e.g.
  "cmux NEXT (iOS test)".
- User-facing strings that name the phone app "cmux cnx" (IPhone.xcstrings,
  IPhoneHostStrings.swift, settings help in `docs/mdm`, `schemas/settings`,
  `webviews/.../strings.json`, `mobileCard.test.tsx`): say "cmux next" or the
  shipped name instead.

## Left to rename in code (later quiet window)

Code identifiers were kept so in-flight branches merge cleanly: directory
`cnx-ios/`, `CnxKit` and its `Cnx*` modules, `CnxApp` target/product,
`cnx-hostd`, `cnx-ffi`, `CNX_*` env vars and build settings (`CNX_API_BASE`,
`CNX_PROD_API_BASE`, `CNX_TAG`, `CNXAPIBase`), Logger subsystem
`dev.cmux.cnx`, keychain service `dev.cmux.cnx.device`, xcframework bundle ids
`dev.cmux.cnx.<name>`, the `cnx.v1` WebSocket subprotocol, `~/.cnx-host*`
state dirs, `~/cnx-ios-builds`, `cnx-<tag>.ipa` artifact names, and every
`feat-cnx-ios*` branch.
