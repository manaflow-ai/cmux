# Plan: device-list type-safety + iOS first-touch rework (on current main)

Status: proposed (2026-06-24). Branch `feat-ios-device-list-v2`, cut fresh from
main `047e260b3`.

## STAGE 1 STATUS: COMPLETE + SELF-VERIFIED (2026-06-25)

Implemented and verified:
- 5 golden fixtures + `_expected.json` + `device-record.fields.json` lock under
  `Packages/Shared/CmuxSyncStore/Fixtures/devices/`.
- Swift `DeviceRecordFixtureContractTests` (appended to `SyncFrameAndProtocolTests.swift`)
  loads fixtures via `#filePath` and asserts vs `_expected.json`. PASSES
  (`swift test --package-path Packages/Shared/CmuxSyncStore`).
- Worker `workers/presence/test/deviceRecord.test.ts` loads the SAME fixtures,
  asserts values at runtime + enforces field names at compile time via a typed
  `asDeviceRecord` reconstruction. PASSES (`bun test` + `bun run typecheck`).
- `scripts/lint-sync-contract.sh` + field lock: coverage (both directions) +
  additive-only-vs-base. PASSES. Wired into `ci.yml` `workflow-guard-tests`.
- `CmuxSyncStore` added to the `swift-package-tests` allowlist; `presence.yml`
  path filter widened to include the shared fixtures dir.
- DRIFT-DETECTION PROVEN: TS typecheck catches rename/retype/optional->required;
  Swift test catches value + route-kind drift; lint catches undeclared fixture
  field, optional-never-absent, and schemaVersion/source-constant drift; Swift
  `Mirror` + TS exhaustive key map tie each source record type to the lock (a new
  source field without a lock+fixture fails). All restored green afterward.
- AUTOREVIEW: converged clean over 6 rounds (Codex `patch is correct`, Aziz
  policy clean). Hardening added across rounds: TS retype pin, optional->required
  pin + a no-optionals fixture, runtime route-kind pin, schemaVersion<->substrate
  tie with hard-fail on unreadable constants, source<->lock ties (Mirror / keyof),
  and split the suite into its own file per Aziz file-org.
- Note: the repo's Swift file-length budget guard reports pre-existing debt on
  `Sources/Workspace.swift` + `Sources/Panels/BrowserPanel.swift` (NOT in this
  diff); out of scope for this contract PR.

Original notes (kept for reference):

DONE (durable on disk):
- `Packages/Shared/CmuxSyncStore/Fixtures/devices/` created with 5 fixtures +
  `_expected.json` (the cross-language contract): `device-tailscale.json`,
  `device-iroh.json`, `device-multi-instance.json`, `device-future-field.json`,
  `device-tombstone.json`.

Key shape facts (verified from main; do not re-derive):
- `DeviceRecord` payload JSON = `{ deviceId, platform, displayName?, ownerUserId?,
  lastSeenAtAtRev (epoch ms, number), instances: [{ tag, lastSeenAtAtRev, routes:
  [CmxAttachRoute] }] }`. Swift mirror: `SyncedDeviceRecord` in
  `Packages/Shared/CmuxSyncStore/Sources/CmuxSyncStore/DeviceSyncFacade.swift`;
  TS: `DeviceRecord` in `workers/presence/src/syncDevices.ts`.
- `CmxAttachRoute` JSON = `{ id, kind, endpoint, priority? (default 0) }`.
  tailscale endpoint = `{ "type":"host_port", "host", "port" }`; iroh endpoint =
  `{ "type":"peer", "id", "direct_addrs":[...], "relay_url"? }`. Defined in
  `Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/CmxTransport.swift`.
- Tombstone payload = `{}` → does NOT decode as SyncedDeviceRecord (facade uses
  `try?` and drops it). Unknown route kinds are dropped by failable per-route
  decode; unknown record fields are ignored (forward-compat).

REMAINING Stage 1 steps (next):
1. Wire Swift `Packages/Shared/CmuxSyncStore/Tests/CmuxSyncStoreTests/SyncFrameAndProtocolTests.swift`
   to load each fixture (Bundle.module resources — add `resources: [.copy("Fixtures")]`
   to the test target in `Packages/Shared/CmuxSyncStore/Package.swift`), decode via
   `JSONDecoder().decode(SyncedDeviceRecord.self,...)`, and assert against
   `_expected.json` (decodes flag, deviceId, platform, instanceCount, per-instance
   tag + routeKinds). Tombstone asserts decode throws/!decodes.
2. Wire worker `workers/presence/test/deviceRecord.test.ts` (new) to read the same
   files from `../../../Packages/Shared/CmuxSyncStore/Fixtures/devices` (or a shared
   path), JSON.parse, and assert against `_expected.json` identically.
3. Add `scripts/lint-sync-contract.sh` + `Packages/Shared/CmuxSyncStore/Fixtures/devices/device-record.fields.json`
   field-set lock (model on `scripts/lint-pbxproj-test-wiring.sh`); fail on
   non-additive field change + assert every shared field appears in >=1 fixture.
   Wire into the `workflow-guard-tests` job in `.github/workflows/`.
4. Verify: `swift test --package-path Packages/Shared/CmuxSyncStore` (on AWS/cloud,
   NOT locally if it builds the app — package-only swift test is fine locally) +
   `cd workers/presence && bun test` + run the lint script. Induce a rename to
   confirm red.
5. `/autoreview --mode branch --base origin/main` until clean. Commit + push + PR.

Then Stage 2+ per below.

## Why this branch exists (and why not the old one)

The local-first sync substrate (`sync/v1` + `CmuxSyncStore` + presence-DO
device-list projection) is **already on main**, shipped via PR #6120
(https://github.com/manaflow-ai/cmux/pull/6120) plus follow-ups, and evolved
further since. The old dev branch `feat-do-device-list` is 366 commits behind and
fully superseded — every part of it (substrate + epoch/gc-floor/tombstone/
collection-allowlist/queued-delta hardening) is on main, at the post-reorg path.
Back-merging main into it produced 13 conflict hunks on already-merged files, so
that merge was aborted. This branch starts clean from main instead.

## Ground truth on main (audited 2026-06-24)

- Substrate: `Packages/Shared/CmuxSyncStore/` — `DeviceSyncFacade.swift`,
  `MobileDeviceListLocalFirst.swift`, `SyncClient`, `SyncFrameApplier`,
  `SyncProtocol`, `SyncDatabase`, etc. Payload-opaque (`payloadJSON: Data`).
- Worker: `workers/presence/src/` — `sync.ts`, `syncStorage.ts`, `syncDevices.ts`
  (`deriveDeviceRecord` → `DeviceRecord`), `do.ts`, `validate.ts`.
- iOS UI: `Packages/iOS/CmuxMobileShellUI/` — `DeviceTreeView.swift` (already
  wired at `WorkspaceListView.swift:268` with `showAddDevice`/`selectWorkspace`),
  `MobileHostPickerView.swift` (still present, to be cut), `CMUXMobileRootView.swift`.
- Tests: `SyncFrameAndProtocolTests.swift` (Swift) + `workers/presence/test/sync.test.ts`
  (worker) exist. **No shared fixtures, no `lint-sync-contract` guard yet.**
- Transport mode (`iOSTransportMode`/`MobileTransportMode`/`cmuxRelay`): NOT on
  main. It lives on `feat-ios-iroh-dial` / PR #6689
  (https://github.com/manaflow-ai/cmux/pull/6689), still open, awaiting dogfood.

## The two problems this branch solves

1. **Cross-language type safety is drift-blind.** The only shared type is
   `DeviceRecord` (TS, `syncDevices.ts`) ⟷ `SyncedDeviceRecord` (Swift,
   `DeviceSyncFacade.swift`). Linked today only by `"Must match the worker"`
   comments + two independent test suites that share no fixtures, so a field
   rename/retype is caught by nothing and degrades into silent dropped/empty data
   on the phone (defensive JSON decode tolerates it). Compat-tolerant, drift-blind.
2. **iOS first-touch is the add-device screen, not the workspaces.** Returning
   users should land on a unified every-workspace list across all online Macs;
   first-run should land on the computers list (`DeviceTreeView`).

## Decisions (settled 2026-06-24)

- **Type safety: tests + convention + enforcement. No protobuf/buf.** One shared
  struct, read-mostly, sole-writer→read-only-consumer flow (protobuf's
  unknown-field-preservation win doesn't apply), no Cloudflare first-party
  protobuf support, and forward/backward compat already exists via defensive
  decode. The gap is only drift detection. Close it with shared golden fixtures +
  a CI guard, matching the repo's existing mirror+test convention. Revisit buf
  only when a 2nd/3rd cross-language type appears.
- **First-touch:** launch (returning) → every-workspace home; first-run →
  `DeviceTreeView`. Reuse `DeviceTreeView` as the one computers surface.
- **Workspaces = connect-all-and-merge** (phone dials all online Macs, merges
  live workspace lists). NOT a sync collection.
- **Transport: Mac chooses (#6689 picker), phone shows a read-only badge.**
- **Cut `MobileHostPickerView`.**

## Stages (each independently shippable, in order)

### Stage 1 — Lock the device-list contract (no #6689 dependency) ← start here
Close drift-blindness; make `DeviceRecord`/`SyncedDeviceRecord` one enforced
contract.
- Add `Packages/Shared/CmuxSyncStore/Fixtures/devices/*.json`: 5 canonical wire
  records — multi-instance device, tombstone, iroh-route record, tailscale-route
  record, future-unknown-field record.
- Wire `SyncFrameAndProtocolTests.swift` (Swift) to load + decode + value-assert
  each fixture.
- Wire `workers/presence/test/sync.test.ts` (or a new `deviceRecord.test.ts`) to
  load the **same files** + value-assert. Both suites become one contract.
- Add `scripts/lint-sync-contract.sh` (model on `scripts/lint-pbxproj-test-wiring.sh`):
  checks a checked-in field-set lock (`device-record.fields.json`), fails on a
  non-additive change (removed/renamed/retyped field), asserts every shared-type
  field appears in ≥1 fixture (both directions), and ties the lock's
  `schemaVersion` to the substrate constants (worker `SYNC_SCHEMA_VERSION` +
  Swift `syncSchemaVersion`). Wire into the `workflow-guard-tests` job.
- Repoint the `"Must match the worker"` comments at the fixtures as the authority;
  state the additive-only rule.
- Proof: both suites + guard green in CI; locally rename a `DeviceRecord` field →
  the changed side goes red + the guard fails.
- This is the high-leverage 80/20; ship as its own PR. Run `/autoreview` on this
  diff before handoff.

### Stage 2 — `transport_mode` on the record + fix Mac→worker routes=0

STATUS (2026-06-25): `transportMode` HALF COMPLETE + autoreview-clean (commit
`8a36529e2d`). Threaded additively, mirroring `bundleId`: HeartbeatInput +
parseHeartbeat (bounded) → PresenceInstance + both heartbeat-apply paths →
DeviceInstanceRecord + deriveDeviceRecord; `deviceShapeChanged` AND the
`do.ts` hot-path gate `heartbeatMayChangeListShape` both treat a mode change as
list-shape (so a badge change mints a rev and is projected); Swift InstanceRecord
+ TS DeviceInstanceRecord + lock + key map + fixtures; `registryDevice(from:)`
+ `RegistryAppInstance.transportMode` carry it to the UI model. Behavior tests:
parse, derive, shape-change, facade propagation. Additive → no schemaVersion bump.
REMAINING (dogfood-dependent): the Mac SENDING transportMode is PR #6689's job;
the `routes=0` presence fix needs live-presence diagnosis + a tagged dogfood to
verify (root cause is upstream Mac-heartbeat→worker route delivery, memory
`ios-dev-presence-routes-gap`), so it is not headlessly completable here.
- Add `transportMode` (additive) to the instance record + `deriveDeviceRecord`;
  add a fixture + lock entry (additive, so no `schemaVersion` bump per the
  substrate rule).
- Fix the known presence gap (`ios-dev-presence-routes-gap`): online Mac reports
  `routes=0`, so presence-driven attach has no dialable route. Trace
  `Sources/Cloud/PresenceHeartbeatClient.swift` + `DeviceRegistryClient.swift`
  publish → `validate.ts` parse → `core.ts`/`syncDevices.ts` projection; ensure
  the full route set reaches the record. Add a worker test asserting routes
  survive heartbeat → record.
- Note: the iroh route kind itself arrives with #6689; keep this additive and
  tolerant of pre-iroh routes.

### Stage 3 — iOS launch rework (rebase onto #6689 first)

STATUS (2026-07-01): SUPERSEDED BY MAIN. Main shipped multi-Mac workspace
aggregation independently (`WorkspaceListView+MacSelection`,
`WorkspaceMacSelectionScope`, paired-Mac aliases): the workspace list already
merges every paired Mac's workspaces with an "All Computers" scope, sourced
from the paired-Mac backup + registry + presence. The connect-all-and-merge
home this stage described exists; do not rebuild it. Remaining gap (future,
not this branch): presence-driven auto-dial of account Macs the phone never
paired with.
- `CMUXMobileRootView` launch decision: returning user with known/paired Macs →
  subscribe to presence, dial all online Macs, merge workspaces, render the
  every-workspace home. First run / no known Macs → `DeviceTreeView`. Demote the
  add-device sheet to a `+` action.
- Connect-all-and-merge coordinator: bounded concurrency, per-Mac timeout +
  recovery, visible per-Mac error; merge keyed by (deviceId, tag, workspace). No
  ambient effects; explicit lifecycle. Honor the iOS loading-UX review rule.
- Proof: launch with ≥2 online Macs shows merged workspaces; one offline Mac
  degrades gracefully with a visible state.

### Stage 4 — DeviceTree consolidation + cut MobileHostPicker + transport badge

STATUS (2026-07-01): COMPLETE on this branch. Main had already grown
`DeviceTreeView` into the full Computers screen (snapshots, presence, add/
remove, `MacComputerDetailView`), so consolidation reduced to: (a) the
transport badge — `PresenceInstance.transportMode` (phone decode) →
`PresenceMap.DeviceSummary` → aliases rollup → `MacComputerSnapshot` →
`MacComputerRow` pill + `MacComputerDetailView` "Transport" field, via the
shared `MobileTransportModeLabel` (en+ja, unknown modes show raw); and (b)
cutting `MobileHostPickerView` — deleted, the Settings sheet now presents
`DeviceTreeView` (add rides the rescanQR pairing path; contexts without a QR
path hide the add affordance). PresenceMap tests cover the mode rollup +
wire decode (7 pass).
- Fold account + manual/Tailscale Macs into `DeviceTreeView`; remove
  `MobileHostPickerView.swift` and route every computers entry point to
  `DeviceTreeView`.
- Read-only per-instance transport badge (cmux relay / own relay / Tailscale)
  from the published route kind (#6689 shape).
- Localize new strings (en + ja); run the localization audit. Honor the
  snapshot-boundary rule (rows take value snapshots + closures).

### Stage 5 — Onboarding one-pager

STATUS (2026-07-01): SUPERSEDED BY MAIN. Main shipped `OnboardingFlowView` +
`MobileOnboardingStore` (persisted first-run seen flag gating ahead of the
never-paired add-device state, re-enterable from Settings). The Mac-side
transport choice at pairing is #6689's Stage C (its pairing window). No
onboarding work left on this branch.
- First-run = `DeviceTreeView` with an explicit add-Mac affordance; QR/manual
  pairing behind `+`/Advanced. Copy points the user to choose transport on the Mac.

## Dependencies / sequencing

- Stages 1–2: independent of #6689; land now against main.
- Stages 3–5: depend on #6689's transport modes + iroh route shape. Rebase this
  branch onto main after #6689 merges (or onto `feat-ios-iroh-dial` if we need to
  start sooner), then proceed.

## Cross-cutting rules

- Additive-only wire (never remove/rename/retype a field); additive fields do
  NOT bump `schemaVersion` (the additive-only guard is the compat guarantee);
  update fixtures + field lock in the same PR (guard enforces).
- DO changes additive + tolerant of old shape during rollout.
- iOS loading/network UX: bounded timeout, retry/recovery, visible error per state.
- No raw effect-style ambient effects in SwiftUI; explicit lifecycle.
- Snapshot boundary for all list rows.
- Localize every user-facing string (en + ja); audit before handoff.
- Aurora registry stays as fallback throughout.

## Verification

- Stage 1: both suites + guard green in CI; induced-rename goes red; `/autoreview`
  clean on the diff.
- Stage 2: worker route-survival test; live non-zero routes for an online Mac.
- Stages 3–5: iOS dogfood on a tagged build (mac + iOS, same tag, deeplink banner)
  with ≥2 online Macs. Focused XCUITest via cloud/AWS runner + the E2E workflow,
  never locally.
