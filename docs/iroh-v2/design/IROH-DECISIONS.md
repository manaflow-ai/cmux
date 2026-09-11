# IROH v2 decisions

Updated 10 September 2026, revision 21. Accepted directions are recorded here; unresolved implementation details are listed at the end. This workspace changes architecture documents. The independent pairing implementation runs in **iOS Pairing Opt-in, workspace:51**.

## Backend and scope

- Rebuild the IROH backend and storage from scratch using inspected main behavior as a reference. Move IROH backend work to Cloudflare Workers; every new endpoint is under `/v2/`. Use new production storage and isolated development storage.
- **One Durable Object per Stack Auth team and environment**, with Stack project included in the routing identity. The Worker authenticates the user, verifies the selected team and required permission, then routes to that team’s object. Never trust a client-supplied team ID or forwarded internal authority header.
- Use **Drizzle with Durable Object SQLite** for team-local persistent state. **PlanetScale** is the primary shared database for global ownership, cross-team queries, reporting and records used by other services. Each record has one authoritative home.
- **Request and product usage allowances remain per user**, shared across that user’s devices/builds and teams within an environment. They are not divided between teammates. No application IP quota. Physical resource bounds still apply to individual payloads/connections and the shared DO.
- **Development isolation.** The shared development Worker follows the latest main branch. A developer or agent can deploy a suffixed Worker with its own Durable Object namespaces and matching build origin using `workers/iroh-v2/scripts/deploy-dev.sh <slug>`.

| Area | Scope |
| --- | --- |
| Durable Object and SQLite | One per Stack Auth team in each environment; include Stack project in routing identity. |
| Directory and device records | Team-owned directory, filtered by the caller’s permissions; each device keeps its owner user and unique EndpointID. |
| Permissions and revocations | Team membership plus explicit device/connect/manage permission. Membership alone never grants terminal access. |
| Control sockets and live updates | Join the verified team object; team revisions and permission-filtered broadcasts. |
| Tickets, challenges and signed peer permissions | Bind environment, Stack project, team, user, device/build, generation and allowed actions. |
| Relay settings, caches and Dashboard | Team-scoped shared settings, cached directory and Dashboard selection. User UI preferences and local pairing opt-in stay individual. |
| Global EndpointID map and reports | PlanetScale stores team ownership plus owner user. Global uniqueness remains global. |
| Request and product usage limits | Per verified user and operation, shared across their devices and teams within an environment; no IP quota. |
| Physical safety bounds | Payload/socket limits and finite DO memory still apply. These protect resources; they are not a shared team request allowance. |

Team membership alone does not grant terminal access. Device discovery and connection require the applicable permissions; management actions require management authority. Preserve device-specific grants where needed. Known membership or permission removal closes affected sessions and prevents future minting. Fresh team-ticket issuance rechecks Stack authority; do not query Stack for every message or relay renewal. The mechanism delivering membership changes and the maximum stale-permission window remain open.

Team changes isolate cached credentials, directory revisions, pending work and key storage. Do not silently publish a Mac to a different team or broaden access when the user selects a team. A device record retains its owner user ID. The proposed complete key includes environment, Stack project, team, owner user, device ID, app namespace and dev tag; exact field names remain open.

## Client replacement scope

**Accepted: this implementation retires and removes all client behavior incompatible with v2.** This applies to Mac, iOS, their IROH integration, shared networking code and generated contracts. Existing main is a behavior reference; the new release runs the accepted v2 design.

- Remove IROH calls and fallback paths to Vercel, pre-v2 endpoints and the older relay-minter integration. Recovery uses the accepted `/v2` HTTP equivalents and the same authorization rules.
- Remove scheduled application presence messages, presence-based connection gates, periodic re-registration, redundant renewal/reconnect owners, and backend publication of direct addresses. Keep native transport keepalives and local/peer direct connection support.
- Remove incompatible identity/team assumptions and networking that starts before pairing is enabled. Old cached credentials or unscoped identities cannot establish v2 trust or silently publish a Mac into a team. Any upgrade-state handling must obey the new identity and permission rules.
- Delete obsolete adapters, flags, configuration, models and tests whose sole purpose is to retain a removed behavior. Adapt useful coverage to the v2 requirements. Do not leave an old path available through an error fallback or hidden flag.
- Verify launch, upgrade, wake, reconnect, failed renewal and server-error paths use only the new lifecycle and permitted routes. Check both platforms for retired routes, unwanted listeners/timers and delayed callbacks that could restart old work.

**Version support remains required within v2.** Keep supported request/response schemas and their behavior for released v2 apps, including the long `client_upgrade_required` backoff. Removing incompatible code from the new release does not set the production shutdown date for already-shipped pre-v2 clients; release cutover and service retirement timing remain deployment decisions.

## Accepted backend implementation rules

**Adopted from Lawrence Chen’s [PR](https://github.com/manaflow-ai/cmux/pull/12199).** These are required v2 design decisions, with our team/user scopes and credential rules preserved.

- **Shared local broker.** HTTP and socket adapters call the same team-local broker. Keep transport/session handling separate from operation and storage rules. Ordinary IROH operations do not proxy to Vercel.
- **Zod at both boundaries.** Validate every server request and response using the versioned Zod contract. Keep JSON Schema export, quicktype Swift/TS generation, and compatibility checks.
- **Safe object activation.** Check and apply Drizzle durable-sqlite migrations inside blockConcurrencyWhile before serving requests. Use supported synchronous storage transactions; no partial schema is visible.
- **Immutable migration history.** Never edit a shipped migration. Verify migration history and refuse a schema the worker cannot safely serve. Roll back code only when it supports the already-applied schema.
- **Database-enforced quotas.** Use constraints/triggers to update usage and reject writes in the same transaction. Attribute product usage to users; size the shared physical database guard separately.
- **Bounded temporary state.** Keep one pending challenge slot per device/build identity. Reject expired challenges when used, replace the slot on a new challenge request, and clear it on successful consumption. No challenge sweep or scheduled deletion. Any future retained-history cleanup needs an explicit retention policy and bounded work.
- **Real runtime verification.** Require Miniflare/workerd tests for persistence, reactivation, isolation, migrations and rollback/failure. Test real alarms only for features that require them. Add team/user separation, supported v2 client compatibility and interrupted-renewal coverage.
- **Enforced architectural boundary.** Required build checks must invoke the no-Vercel/no-Hyperdrive dependency check. Permit the deliberate PlanetScale global ownership service; keep ordinary team-local reads and renewal local.
- **Staged deployment.** Run generation, schema checks, runtime tests and a Worker dry run in development. Canary one team, then promote the same immutable worker build. Separate large backfills from traffic cutover.
- **Complete, bounded observability.** Use Cloudflare logs/metrics, Axiom structured operation events and Sentry exceptions. Cover all HTTP/socket outcomes and major events. Bound exports and keep telemetry delivery off the response path.

Migrations add compatible structure first. Bounded backfills run separately, with old readers/handlers supported until the cutover is safe; destructive cleanup follows later. A failed migration cannot leave a successful version marker or expose a partial schema. A code rollback never automatically downgrades SQLite. The migration manifest/history and supported-schema policy must be validated in the active runtime path, not only in an unused helper.

Storage errors have explicit protocol codes and retry guidance. Database constraints reject writes atomically, including usage increments. Physical-full recovery may attempt bounded safe expiry cleanup; persistent fullness is reported and alerted, without unsafe online compaction or endless client retries. Exact storage guard sizes and cross-team user-usage coordination remain implementation details. Durable device registration does not expire merely because the device has been offline.

Required checks actually run the no-Vercel boundary script, generated-contract checks, schema checks, real workerd tests and a Worker dry-run build. Include populated upgrade, repeated activation, failed upgrade rollback, unsupported-schema rejection, hibernation, team isolation and separate user allowances. A script existing in the repository is not evidence that the release workflow runs it.

[Flow 6 in the diagram](index.html) expands activation and normal operations, with expiry checks inside the relevant operation. [Source notes](PR-12199-LESSONS.md) retain the distinctions between the inspected PR implementation and our accepted adaptations.

## Credentials and identity

| Item | Accepted lifetime / rule |
| --- | --- |
| HMAC API ticket | 1 hour. Scoped to environment, Stack project, team, user, device/build, generation and permitted operations. |
| Relay credential | 30 minutes. Public-key signed so relays verify locally without calling our backend. It authorizes relay service; terminal access has its own permission check. |
| Enrollment challenge | 30 minutes, single use. At most one pending challenge per identity. Replace the slot on a new request; clear after use. Reject after expiry without a scheduled deletion. |
| EndpointID | Unique for each identity tuple. Never share across different devices/builds/environments. Global ownership map also records team and owner user. |
| Identity generation | Changes on approved key replacement or recovery, not ordinary app updates, launches or renewals. |
| Offline peer permission | Lifetime still undecided. Expired or known-revoked authority cannot be extended by reconnect/renewal overlap. |

**Registration storage.** Keep one current device record per complete device/build identity. Repeating registration with unchanged identity updates that record; request retries do not append device records. New identities add records, subject to the planned device/storage limits whose exact values remain open. Approved key replacement and revocation keep whatever security history is required separately from the current record. The pending challenge occupies one slot on that identity.

**Credential instances.** Each device/build keeps one current API ticket per team authorization scope and one current relay credential per relay audience (the relay or fleet allowed to accept it). Renewal may temporarily retain the previous credential while installing its replacement. Previously issued signed credentials can remain valid until expiry, subject to applicable revocation checks; replacing the cached value does not invalidate them. Keep no database row for every issued credential and run no credential-deletion job. Durable device authority and revocation state remain separate.

First enrollment, approved key replacement and recovery require proof of the EndpointID private key. Key replacement proves continuity with the old key or uses explicit recovery approval. Restarts and ordinary requests reuse the trusted identity. Revocation must never be bypassed through silent re-enrollment.

The global EndpointID map belongs in strongly consistent shared storage; team SQLite stores the full device record. Reservation and enrollment across these stores require retry-safe coordination. Do not claim one SQL transaction spans both databases.

Store **relay URLs only** as server connection details. Direct-mode addresses/ports and optional direct IROH paths remain local or are exchanged between peers.

## Control flow and registration

The first backend operation is a Worker-routed, hibernatable `GET /v2/control/socket`. First setup supplies a Stack session and team context; ordinary resume supplies a valid scoped HMAC ticket plus device proof. The team DO returns session readiness, a ticket when issued, and a challenge only if enrollment requires it. Use typed socket messages for subsequent control operations; HTTP endpoints are fallbacks. Keep `/v2/tickets` and `/v2/challenges` for their separate operations. Do not add a redundant `next` field.

Both Mac and iOS use the registration envelope: version/schema, request ID, team context, device/app/build identity, platform, display name, EndpointID, identity generation, pairing state, capabilities, relay URL list/expiry, challenge ID/nonce and signature over the canonical payload. Include user identity from verified auth context and match any claimed value against it. Exact field names remain provisional.

| Condition | Registration behavior |
| --- | --- |
| First permitted team/user/device/build/environment enrollment | Register once after challenge proof. |
| Approved key replacement or recovery | Register the new key with continuity/recovery authorization. |
| Reinstall, restore, sign-out/sign-in, re-enable pairing | Register only if matching identity/trust is missing or new. Otherwise resume. |
| Lost reply or interrupted enrollment | Retry with the original request ID. Refresh a replaced or expired challenge when needed. |
| Ordinary launch, wake, foreground, reconnect, renewal, relay change, terminal creation or app update | No registration. Reuse the trusted identity and separate update operations. |
| Team change | Require explicit authorization for the new scope. Do not transfer or duplicate an identity silently; detailed UX remains open. |

**Returning enabled apps attempt IROH immediately using usable cached identity, relay credentials and peer permissions**, in parallel with backend setup and refresh. A directory response or new API ticket must not delay that attempt. First setup waits only for its missing prerequisites. Fresh credentials remove credential failures but cannot guarantee an available peer or network.

One client owner coordinates each peer’s connection and retries. Direct/relay paths may race, different peers run independently, and a planned replacement may coexist with a healthy connection. There is no local attempts-per-minute quota.

**Use make-before-break.** The client requests and installs a usable replacement before retiring the previous valid credential/socket/path. The DO checks permission and responds; it has no second per-client renewal timer. Failed refresh backs off while a healthy authorized IROH session continues. Known revocation and compromise override overlap.

## Connection status and pairing activation

- **No scheduled application presence heartbeat to the DO**, presence-only timeout alarm, or presence checkpoint. A usable authorized IROH session establishes the client’s connection status. Saved untested Macs have unknown reachability; backend online status must never hide them or block a cached attempt. Do not connect to every saved Mac solely to label it online.
- Retain IROH transport keepalives/failure detection and application request deadlines. A keepalive probe and acknowledgment use both directions; two custom application timers are unnecessary. Exact intervals remain open.
- Native WebSocket protocol ping gets Cloudflare runtime pong without waking the DO. Preserve hibernation; no custom JSON ping loop. Keep control sockets for credentials, directory updates and permission removals.
- **Each Mac must explicitly enable Enable iOS pairing in cmux Settings.** Before opt-in, do not initialize IROH, bind its listener/port, contact a relay, or start IROH backend/control, enrollment, discovery or renewal work. Sign-in alone does not opt in.
- Disabling pairing stops IROH sessions/listeners and cancels setup, refresh and retries. Invalidate the local run before cancellation so delayed callbacks cannot restart networking. Re-enable an intact identity without new registration. Other cmux features retain their own network behavior.
- iOS onboarding and the empty computer list explain the Mac setting and selecting the appropriate team. A phone cannot prove a remote setting without communication; the Mac gate enforces opt-in. Exact copy and migration from existing settings belong to the independent implementation.

Proposed v2 onboarding: “On your Mac, open cmux Settings and turn on Enable iOS pairing. Select the same team on both devices using accounts allowed to connect.”

Proposed empty list: “No Macs found. Open cmux Settings on your Mac, enable iOS pairing, and select the same team on both devices.”

[Pairing agent task](PAIRING-AGENT-TASK.md). The independent feature works with current main; team backend migration is outside its scope.

## Types, validation and versions

**Use Zod instead of Ajv.** Author the versioned wire contracts once in Zod. Validate server inputs and outputs with Zod. Export JSON Schema during the build; quicktype generates Swift and TypeScript models. Compile-time checks keep generated TypeScript compatible with Zod’s inferred shape. Clients decode generated types and handle server errors; no client schema validator is required.

Use JSON-compatible wire shapes with explicit request and response schemas. Avoid coercions/transforms that change the shared wire type. Custom cross-field, signature and permission checks remain explicit server rules. Fail export for an unrepresentable shape rather than silently replacing it with unrestricted JSON. Custom refinements need documented server errors and shared examples; Swift models do not reproduce those checks. No OpenAPI requirement.

`Zod schemas -> JSON Schema -> quicktype Swift + TypeScript models`, with Zod server validators and shared valid/invalid examples. Pin generator versions; regeneration, both-language compilation and compatibility fixtures run in build checks. This cross-platform pipeline is additional work beyond Lawrence’s PR.

- `/v2/` names the backend generation; each method/message has request and response schema IDs.
- Compatible optional additions preserve old meanings and handlers. Rejecting new unknown fields on old servers must be considered when deciding whether an addition is actually compatible.
- Breaking request/response shapes, changed meanings, or intentionally different behavior for newer clients require a new supported schema/handler version. Keep old behavior for supported v2 App Store clients.
- No separate startup version-reporting step is required. Each method names its version; app version may accompany ordinary requests for diagnostics or rollout rules.
- `client_upgrade_required` starts a long backoff: 1 hour, 6 hours, then 24 hours with jitter. Explicit user retry remains available; reset after success or app update.
- Wire versions, team data revisions and database migrations are separate. Test the oldest supported v2 app against the new server and the new app against the previous supported v2 server.

[Zod export](https://zod.dev/json-schema), [quicktype](https://github.com/glideapps/quicktype).

## Limits and observability

**Registration: 300/hour, burst 50 per verified user.** Two iPhones and five Macs need seven initial registrations and normally zero afterward. Other operation rates are in [capacity planning](IROH-CAPACITY.md); each recognized method has its own allowance, shared by its HTTP/socket equivalents and schema versions.

Rate key: `(environment, Stack project, verified userId, operation)`. Team switching must not reset it. Team DOs need coordinated user counters; exact ownership/batching and its cost remain open. Do not use the selected team as an extra user-budget key.

**Generous finite output is accepted.** Start with 1,024 unsent messages or 2 MiB per connection, and 4,096 messages or 8 MiB total per user, stopping at either bound. Count transport-buffered bytes too and allocate on demand. These are starting values to tune after payload/load tests. Pause production and resume/resync a slow control connection without losing permission removals. No total-delivered-message or terminal-output quota. Shared DO memory and database safety also need finite guards and fair handling.

**Observe all backend activity:** every logical HTTP/socket operation, success/error/response code, rate-limit decision and major state transition, including database work, credential operations, permission changes, alarms and deployments. [Observability coverage](IROH-OBSERVABILITY.md) specifies the events, useful fields, collection boundaries and cost controls. Normal event capture is not sampled away; keep records compact, exclude secrets/terminal content, and aggregate metrics separately. Capture critical authority changes durably with their state revision. Ordinary telemetry delivery is best effort and its failures must be measurable.

Clients handle all statuses and stable errors deliberately. Scope denials stop only affected operations; recoverable failures preserve healthy authorized peer sessions. Deduplicate retries, honor per-operation cooldowns, and reconcile uncertain mutations before replay.

## Development and remaining implementation choices

Development Mac/iOS builds use a backend environment isolated from production data, keys and budgets. Shared development from main plus optional branch-suffixed environments is the recommended deployment layout. Branch expiry, cleanup and spend rules remain to implement; no permanent database server per branch is needed for DO SQLite.

Open details: exact identity/payload names; multi-team device-sharing UX; membership-change delivery and stale-authority window; global EndpointID reservation; cross-team user-counter ownership; physical DO memory/storage guards; transport timing; offline peer-permission lifetime; retained history and backups; observability deployment, retention and alerts; release cutover and pre-v2 service retirement timing.

[Lawrence’s PR lessons](PR-12199-LESSONS.md) distinguish inspected code from accepted adaptations. [HTML sequence diagram](index.html) retains the pinned main baseline separately and now includes application lifecycle handling. Historical baseline remains commit 9b98fb04; newer PR behavior must not be labeled as already deployed.
