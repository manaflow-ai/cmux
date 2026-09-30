# Device presence service

Realtime device presence for cmux: every team member sees which of the team's
devices (Macs, iPhones, and their tagged cmux app instances) are online or
offline, live. Source: `workers/presence/`. Deploy: `.github/workflows/presence.yml`.

## Backend decision: Cloudflare Durable Objects (not RivetKit)

Presence needs a tiny per-team actor with serialized state, a timer for
missed-heartbeat expiry, and realtime fan-out. Both Cloudflare Durable Objects
and RivetKit model that well, so the decision came down to the stated hard
requirements (migrations wired into deploy, CI/CD, deploy-on-push) plus
operational cost.

DO wins on boring: the team already runs a Workers + DO service in production
(the regatta subrouter), so the account, tooling, billing, dashboards, and
failure modes are all known quantities, while RivetKit would introduce a new
runtime platform (Rivet Cloud or self-hosted runners) to operate for one small
service. The hard requirements are first-class with wrangler: one GitHub
Actions job runs `wrangler deploy` on push to main, and that deploy applies
the Durable Object migrations declared in `wrangler.toml` atomically with the
code upload, which is exactly the property the Aurora migration-lag incident
taught us to demand. RivetKit's actor model (alarms, sleep/wake, KV state) is
equivalent for this workload, so it offers no capability we need that DO
lacks, and "equivalent but new to operate" loses to "equivalent and already
operated".

## Architecture

```
Mac/iOS client                 Cloudflare Worker                Durable Object
--------------                 -----------------                --------------
POST /v1/presence/heartbeat -> verify Stack token  ----RPC----> TeamPresence (one per team,
GET  /v1/presence/snapshot     resolve team scope               idFromName(teamId))
GET  /v1/presence/subscribe -> forward w/ verified team ------> WS (hibernation) / SSE
                                                                storage: instance map
                                                                alarm: timeout-offline + prune
```

- **State machine** (`src/core.ts`): pure and synchronous. A team's presence
  is a map of app instances keyed by `(deviceId, tag)`, the same identity as
  the PlanetScale Postgres registry (`devices.device_uuid` + `device_app_instances.tag`).
  Online is set by a heartbeat; offline is an explicit event, produced either
  by a goodbye heartbeat (`stopping: true`, clean shutdown) or by the DO alarm
  when heartbeats stop.
- **Cadence**: hosts heartbeat every 15s; an instance is declared offline 45s
  after its last heartbeat (3x the interval, so one lost packet or a slow
  request never flaps a healthy host, while a dead host is declared offline
  within 45-60s, the freshness a phone needs for "is my Mac reachable"). The
  interval is returned in every heartbeat response so the cadence is
  server-owned and can change without shipping new host builds.
- **Auth** (`src/auth.ts`): `Authorization: Bearer <Stack access token>`,
  verified against Stack's REST API (the same backend the web SDK wraps), with
  team scoping via `X-Cmux-Team-Id` / `?teamId=` and a membership check,
  mirroring `web/services/vms/auth.ts` + the device-registry route.
  Verification results are cached in isolate memory for at most 60s, bounded
  by the token's own expiry. The worker derives the DO id from the verified
  team id, so cross-team access is impossible by construction. Within a team,
  devices are owner-bound like the registry: the first authenticated user to
  announce a `deviceId` owns it, and another member's heartbeat for that
  device is rejected with `403 device_owner_mismatch` (so presence cannot be
  spoofed or force-cleared by a co-member). Owner pins are durable DO state,
  never pruned with the 24h presence tail, so idle devices cannot be
  re-claimed. Known accepted residual until the registry's per-device
  key-pinning phase: the very first claim of a deviceId is
  first-authenticated-writer-wins, because presence deliberately has no
  synchronous registry dependency and the registry does not yet issue
  verifiable device credentials; blast radius is presence display only.
- **Subscribe**: WebSocket (primary; DO hibernation API, so idle teams cost
  nothing) or SSE (fallback, curl-friendly). Both deliver a `snapshot` first,
  then `online` / `offline` (with `reason: "timeout" | "goodbye"`) / `seen`
  transition events on one shared broadcast path. Streams are deadline-bounded
  by the verified token's expiry (capped at 15 minutes): the DO stops
  delivering and closes the stream at the deadline, so a revoked token or a
  removed team member cannot keep an old stream alive; clients reconnect with
  a fresh token and get a fresh snapshot. Per-team subscribers are capped (64)
  and a stalled SSE reader is dropped instead of buffered.

## Migrations and durability

Presence is deliberately ephemeral. The durable source of device identity is
the PlanetScale Postgres `devices` / `device_app_instances` registry
(https://github.com/manaflow-ai/cmux/pull/5626); this service adds no Postgres
columns and therefore ships no Drizzle migration. DO storage keeps the live
instance map plus a 24h offline tail for "last seen", pruned by the same
alarm, and the durable per-device owner pins. Losing the service's storage
entirely would cost nothing durable beyond the owner pins: hosts re-announce
(and re-pin) within 15s, with the same first-claim caveat noted above.

The service's own schema story is the `[[migrations]]` block in
`wrangler.toml`: Durable Object class migrations are applied by
`wrangler deploy` in the deploy-on-push workflow, atomically with the code, so
storage classes can never lag the deployed code the way the prod Aurora
migrations once lagged the web deploy. If presence ever does need a Postgres
column, the Drizzle migration must land in `web/db/migrations` and is applied
by the `web-db-migrations` CI job and the cloud-vm migrate workflow
(`.github/workflows/cloud-vm-migrate.yml`), per the cloud-vm-ops runbook.

### Upgrading running Durable Objects

There are two distinct "migrations" and they do different jobs. The
`[[migrations]]` tags above are **class migrations**: they manage the DO class
registry (`new_sqlite_classes`, `renamed_classes`, `deleted_classes`,
`transferred_classes`), are append-only (never edit a past tag, add a new
one), and apply atomically with `wrangler deploy`. Deleting or renaming a
class is destructive and not auto-reversible (it drops that class's storage),
so treat those like a database drop; additive class migrations roll back
safely.

Class migrations do not touch the shape of data stored inside an object, and
there is no automatic per-instance data migration. A DO is a single-threaded
actor, so at most one instance per id is alive at once and two code versions of
the same id never run simultaneously. A `wrangler deploy` does not kill running
objects mid-execution: the live instance keeps the old code until it is evicted
(idle eviction, or hibernation for the WebSocket-hibernation path), and the
next hydration (a request, an alarm, or a hibernated socket waking) runs the
new code against the same persisted storage. So "upgrading running instances"
means making new code safely read data the old code wrote: prefer additive
changes (new optional fields with defaults for missing values); for anything
breaking, stamp a `schemaVersion` on the stored record and lazily upgrade it on
first touch in the constructor or alarm; and keep new code tolerant of
old-format reads during the gradual cross-colo rollout window.

For this service that discipline only bites in one place. The live instance map
and the 24h "last seen" tail self-heal because hosts re-announce every 15s, so
a breaking change to those costs nothing in practice. The durable **owner
pins** are never pruned, so a change to their shape is the one case that
genuinely requires the versioned-record plus lazy-upgrade treatment. Most
presence deploys can ship freely; only owner-pin schema changes need care.

## Workspace viewing presence

Workspace viewing is a separate protocol from device reachability. The source
of truth is the `WorkspacePresence` Durable Object selected by a validated
`WorkspacePresenceScope`; the Worker owns authentication and room routing, and
the client that owns the visible workspace owns its viewing lease. A room is
either a Cloud VM workspace scoped to a verified team or an on-device workspace
scoped to the authenticated account, host UUID, app instance tag, and host
workspace UUID. Client messages can only set the connection's active/inactive
view state; identity, profile image, room, and expiry are server-owned.

`GET /v1/workspace-presence?scope=<encoded-scope>` upgrades to a hibernating
WebSocket. The Worker verifies the Stack bearer, checks Cloud team membership,
resolves the DO by a structured room key, and forwards bounded identity and
token-expiry headers. Clients send active-view renewals every 15 seconds and the DO applies them
to the live lease. The DO sends full versioned snapshots, coalesces multiple
devices for one account, expires active leases after 45 seconds, and closes the
connection at the bounded authentication deadline. Disconnects, backgrounding, scope switches, and account changes
therefore remove a viewer without requiring a separate leave mutation.

The shared `CmuxWorkspacePresence` package owns scope validation, the wire
snapshot, WebSocket transport, reconnect/backoff model, and injected-clock
tests. The Mac controller follows the foreground window's selected workspace,
including a Cloud binding that arrives after selection. Mounted Cloud workspace
rows subscribe passively through `WorkspacePresenceRoster`, so a collaborator's
profile head appears on the right of the workspace they are viewing even when
you have selected another workspace. Multiple windows share each room's
connection; detached or hidden rows release it. Four heads fit in the stack,
with an overflow count and all display names available through native row hover
and VoiceOver. The iOS shell publishes its selected, host-owned Mac scope through
the same protocol. Local-only rows, signed-out accounts, and unavailable rooms
have no heads. The surface adds no tab, panel, or empty-state badge.

The Worker adds only the append-only `WorkspacePresence` Durable Object class
migration (`v3`); no Postgres columns or platform entitlements are involved.
Profile names and HTTPS avatar URLs are read from the verified Stack user
record, bounded before they enter a snapshot, and have no localization or
persistence side effects. Focused package tests cover scope and snapshot
validation, independent row rosters, passive subscriptions, selection changes,
inactivity, disconnect publication, account-generation replacement, and teardown.
Native-row tests exercise hover/VoiceOver updates and cell reuse, plus compact
overflow sizing. Worker tests cover room isolation, lease expiry/coalescing,
strict view messages, and bounded profile projection.

## CI/CD

`.github/workflows/presence.yml`, path-filtered to `workers/presence/**`:

- Pull requests: `bun run typecheck`, `bun test` (unit tests over the state
  machine, team resolution, and validation), and a `wrangler deploy --dry-run`
  bundle check.
- Push to main: the same checks, then `wrangler deploy` (serialized by a
  concurrency group). Required repo secrets: `CLOUDFLARE_API_TOKEN`,
  `CLOUDFLARE_ACCOUNT_ID`. One-time Worker secrets (survive deploys):
  `STACK_PROJECT_ID`, `STACK_PUBLISHABLE_CLIENT_KEY`.

A dev/staging instance (`cmux-presence-dev`, dev Stack project) is live at
`https://cmux-presence-dev.debussy.workers.dev` on the team Cloudflare
account; see `workers/presence/README.md` for how to redeploy it and point a
dev Mac build at it. Production deploys serve `https://presence.cmux.dev`
(a `custom_domain` route in `wrangler.toml`; the cmux.dev zone lives on the
same Cloudflare account, so the deploy provisions DNS + TLS). Flipping the
Release clients' default service URL to that domain is a follow-up gated on
the first production deploy and dogfood.

## Clients

- **Mac sender** (`Sources/Cloud/PresenceHeartbeatClient.swift`): Debug builds
  default on against the dev instance (dev Stack identity); Release defaults
  off until the production worker URL ships with its Settings surface. Both
  are explicitly overridable (`presenceHeartbeatEnabled` +
  `presenceServiceURL` / `CMUX_PRESENCE_BASE_URL`). Follows the
  `DeviceRegistryClient` / `PhonePushClient` pattern: same device UUID, same
  tag, best-effort, never disturbs the Mac. Every beat carries the full
  current attach-route set, a route change triggers one immediate
  out-of-cadence beat, and a clean quit sends a goodbye.
- **iOS** (`Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/PresenceClient.swift`):
  typed WebSocket subscribe client. `MobileShellComposite` owns the
  subscription (starts on sign-in, blanks and stops on sign-out, backoff
  reconnect with snapshot-first resync), reduces frames into `PresenceMap`,
  overlays live online/offline on the device tree
  (https://github.com/manaflow-ai/cmux/pull/5648) rows, writes pushed routes
  through to the paired-Mac store, and kicks a reconnect when the active Mac
  comes online while the phone is disconnected.
- **Workspace viewer clients** (`CmuxWorkspacePresence` plus the Mac controller
  and iOS announcer): use the dedicated viewing protocol described above. They
  never add workspace identifiers or collaborator metadata to device heartbeat
  payloads.

## Local development

```bash
cd workers/presence
bun install
bun test
bun run dev          # wrangler dev (needs .dev.vars or --var Stack config)
```

Full lifecycle proof against real dev-Stack auth:

```bash
set -a; source ~/.secrets/cmuxterm-dev.env; set +a
STACK_PROJECT_ID="$NEXT_PUBLIC_STACK_PROJECT_ID" \
STACK_PUBLISHABLE_CLIENT_KEY="$NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY" \
STACK_EMAIL="$CMUX_DOGFOOD_STACK_EMAIL" \
STACK_PASSWORD="$CMUX_DOGFOOD_STACK_PASSWORD" \
workers/presence/scripts/local-proof.sh
```
