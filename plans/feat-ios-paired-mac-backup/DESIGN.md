# Don't lose saved hosts/IPs on iOS upgrade (paired-Mac backup + restore)

Status: in progress. Builds on the local-first sync substrate from
`plans/feat-do-device-list/DESIGN.md` (read that first). This document is the
deliverable for the durability work; the code proves it.

## 1. Problem

The iOS app remembers paired Macs in `paired-macs.sqlite3`
(`MobilePairedMacStore`): identity, display name, and the routes (IPs/ports) used
to attach. We must not lose those saved hosts and their IPs when a user upgrades.
"Upgrade" has three distinct shapes, and they fail differently:

1. **Same bundle id, version bump** (TestFlight → next TestFlight build, or App
   Store → App Store). The app container is preserved, so the SQLite files
   survive. The only risk is a future schema migration that strands the store.
2. **Bundle id change** (external founders/beta `dev.cmux.app.beta` → a future
   production bundle id) and **reinstall / new device**. The app container is
   NOT shared across bundle ids, and a delete+reinstall wipes it, so the local
   SQLite + the UserDefaults device id are gone. Recovery must come from a
   server-side copy.

Registry-backed Macs already self-report their routes to the server on every
presence heartbeat, so they are recoverable. The gap is **manually added hosts**:
`MobileShellComposite.connectManualHost` stores a synthetic, local-only id
(`manual-<host>:<port>`) whose routes live ONLY in `paired-macs.sqlite3`. Nothing
ever uploads them, so a bundle-id change or reinstall loses them permanently.

## 2. Requirements (confirmed with Lawrence, 2026-06-17)

- Protect all three transitions above.
- **Hybrid model:** local SQLite stays authoritative; continuously mirror saved
  hosts to the Durable Object and restore from it when local is empty.
- Manual host/IP entries are first-class and must be backed up (they can't be
  reconstructed from the device registry).
- Restore may be **sign-in-gated** (account-scoped recovery is acceptable; a
  signed-out blank install need not show hosts until the user signs in).
- It is OK to upload the user's hand-typed host/IPs (LAN/Tailscale addresses) to
  the DO for the first time. Scope them per signed-in user.

## 3. Design: a user-owned `pairedMacs` sync collection

The sync substrate (`plans/feat-do-device-list/DESIGN.md` §7, §10) already
designed a client-write path (`sync.mutate` + server-authoritative LWW) and
explicitly **deferred building it** because the only collection so far
(`devices`) is read-only on the phone and server-derived. This feature builds the
first client-owned collection: `pairedMacs`, a per-user backup of the local
paired-Mac store.

Crucially, `pairedMacs` is **owned by the user, not by a Mac**, so the owner-pin
concern that kept the phone from writing the `devices` collection does not apply.
A user backing up their own saved-host list cannot forge anyone else's device.

### 3.1 Per-user scoping (privacy)

The `devices` collection is team-wide: every member sees every device. Saved-host
backups must NOT be: one member must never see another member's hand-typed IPs.

The DO is per-team. We scope per user by **physical collection name**: the logical
client collection `pairedMacs` maps server-side to the physical collection
`pairedMacs:<ownerUserId>`, where `ownerUserId` is the DO connection's *verified*
Stack user id (never client-supplied). This reuses 100% of the generic
snapshot/delta/tombstone/GC/epoch machinery (all keyed by an opaque collection
string) with zero changes to the generic layer:

- A client subscribes by sending logical `pairedMacs` in `sync.hello`.
- The DO serves it from `pairedMacs:<connUserId>` and **relabels** outgoing frames'
  `collection` field back to `pairedMacs`, so the client stays oblivious to the
  user-id suffix and stores everything under `pairedMacs`.
- A client can only ever read/write its own physical collection because the suffix
  is derived from its verified identity, not from any client input.

### 3.2 Write path: trusted worker RPC, not a WS mutate

`devices` is written by the trusted Mac heartbeat RPC (`POST
/v1/presence/heartbeat` → `TeamPresence.heartbeat(teamId, userId, beat)`). We
mirror that exact pattern rather than expanding the live WS inbound surface:

- New worker route `POST /v1/sync/paired-macs` (auth via the existing
  `resolveTeamOr403`, yielding `team.user.id`).
- New DO RPC `backupPairedMacs(teamId, userId, ops)` that, for each op, calls the
  existing `upsertRecord` / `tombstoneRecord` against `pairedMacs:<userId>`, then
  broadcasts each resulting delta (relabeled to `pairedMacs`) to that user's
  sockets subscribed to `pairedMacs`.

This keeps the WS message handler (the hot, hibernation-bound path) unchanged
except for serving `pairedMacs` on `sync.hello`. The §10 WS `sync.mutate` + outbox
is still the right model for a future offline-write collection; for a
backup-on-change + restore-on-sign-in feature an idempotent HTTP upsert is
sufficient and matches the codebase's existing RPC pattern.

### 3.3 Read path: the existing sync WS

To serve `pairedMacs` over the WS, the DO needs the connection's user id. The
subscribe route already forwards the verified team id + stream deadline as
headers; we additionally forward the verified user id (`x-presence-user-id`) and
stash it on the WS attachment (alongside `expiresAt`/`syncCollections`). The
`handleSyncHello` path, on a `pairedMacs` subscription, resolves frames from
`pairedMacs:<connUserId>` and relabels them. Reads then flow through the existing
`CmuxSyncStore` local-first cache exactly like `devices`.

### 3.4 Record shape

`pairedMacs` payload mirrors the local row so a restore is lossless:

```
PairedMacBackupRecord {
  macDeviceID: String       // = sync record id (incl. synthetic manual-<host>:<port>)
  displayName: String?
  routes: [CmxAttachRoute]  // the IPs/ports — the whole point
  createdAt:  Double        // epoch ms
  lastSeenAt: Double        // epoch ms; also the sort key
  isActive:   Bool
}
```

`ownerUserId` is not in the payload: it is the physical collection suffix.

### 3.5 Backup (phone → DO)

A `PairedMacBackup` facade observes local mutations. After any
`MobilePairedMacStore.upsert`/`remove` for the signed-in user, it POSTs the
changed record (or a tombstone) to `/v1/sync/paired-macs`. Best-effort: a failed
upload is retried and, on sign-in, a full reconcile pushes every local row the DO
is missing. The DO's `upsertRecord` is a no-op when the payload is unchanged, so
re-pushes are cheap and don't churn `rev`.

### 3.6 Restore (DO → phone), sign-in-gated

The mirror image of `PairedMacMigration`. On sign-in, after the `pairedMacs`
snapshot lands in `CmuxSyncStore`, `PairedMacRestore` merges each record into
`MobilePairedMacStore`:

- Insert hosts absent locally (the reinstall / bundle-change / new-device case).
- For hosts present both places, last-writer-wins by `lastSeenAt`: never clobber a
  newer local edit with an older backup. Local stays authoritative.

This is sign-in-gated and account-scoped, matching the confirmed requirement.

## 4. Migration hardening (transition #1)

Independently of the DO work, `MobilePairedMacStore.runMigrations` currently
**throws** `unknownSchemaVersion` when it opens a DB whose `user_version` exceeds
this build's. `ensureReady` then fails and every read throws — so a user who
upgrades, gets a future schema (v2), then for any reason runs an older v1 build
sees **all** their paired Macs as gone, even though the v1 rows are still on disk.

Fix: schema migrations are additive by contract (older builds keep reading the
columns/tables they know — same discipline as `docs/presence-service.md`). On an
unknown-higher version, log and **proceed** against the existing tables instead of
throwing; never reset `user_version` down (no destructive downgrade marker). The
DO backup is the safety net if a future non-additive change ever makes a local
read genuinely fail.

This is the smallest, highest-confidence slice and ships first.

## 5. Security / privacy

- Per-user physical collection name is derived from the **verified** Stack user id
  on both the write RPC and the WS connection; never from client input. One
  member cannot read or write another's `pairedMacs`.
- `team_id` remains in the local cache primary key, so cached data can't leak
  across teams on-device.
- Uploading manual IPs to the DO is new server-side data; it is scoped to the
  owning user and rides the same authenticated, team-scoped transport as presence.
- Caps: a per-user `pairedMacs` record cap (mirroring `MAX_DEVICES_PER_TEAM`)
  bounds storage a client can create.

## 6. Additive / live-safe

All DO storage additions are new collection keys (`synced:pairedMacs:<user>:*`,
etc.), never touching presence keys; no class migration (same `new_sqlite_classes`
object). Old DO instances ignore the new RPC/hello collection during the rollout
window; the phone falls back to its local store, so nothing regresses.

## 7. Phasing

1. **Migration hardening** + test (this slice). Self-contained, no server change.
2. **Server** `pairedMacs` write RPC + per-user read mapping + bun tests.
3. **iOS** backup uploader + restore-on-sign-in + facade + composition wiring +
   en/ja localization + swift tests.
4. **Verify**: bun + swift tests, tagged macOS+iOS reload dogfood (Next.js dev
   server up for the API-backed restore path), PR, iterate CI/reviews.

Dev caveat (memory): dev builds point the registry at `localhost:3000` and the dev
presence worker can report routes=0, so an end-to-end restore demo on a pure dev
build may not yield a *dialable* route. The backup/restore of the saved-host list
itself is still verifiable; route dialability is a separate, known dev-env gap.
