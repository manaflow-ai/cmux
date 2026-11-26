# IROH v2 limits and expected usage

Updated 10 September 2026, revision 21. **Shared state is team-based; request allowances are user-based.** Registration 300/hour with burst 50 and generous finite output bounds are accepted. Other numerical rate thresholds remain starting recommendations. [Decisions](IROH-DECISIONS.md) · [Interactive tables](index.html#rate-limits) · [Observability](IROH-OBSERVABILITY.md).

## Scope and enforcement

Rate key: **environment, Stack project, verified user ID, operation**. All of a user’s devices, builds, Dashboard sessions and teams share that user’s operation allowance. Different users do not consume each other’s allowance. Development and production are independent; no application IP quota or additional per-device request quota.

The team DO owns device state and permissions. It must coordinate with the authoritative user rate state when the user operates in multiple teams. The exact counter owner, batching strategy and internal request/storage costs remain open. Independent counters in each team DO would reset the user’s allowance on team changes and do not satisfy this policy.

Each logical operation has its own allowance. HTTP fallback, socket messages, aliases and schema versions share it. A target device ID cannot create a new allowance. Count only operations actually performed inside setup/batches; valid-ticket reuse does not mint another ticket or consume unused issuance allowances. Unknown input uses one bounded rejected-input policy.

Allowances refill at the stated rate and accumulate up to the burst size. Two iPhones and five Macs need **seven** initial registrations within burst 50. Normal launches, wake, relay changes and credential renewals require **zero**. At seven continuously active instances, the model has about **7.64 ticket renewals/hour** and **16.8 relay renewals/hour**, within the proposed 1,200/hour allowance for each. Extra simultaneous app channels/dev tags add identities.

## Operation limits and resource bounds

| Operation | Who shares the limit | Allowance / rule | Handling / purpose |
| --- | --- | --- | --- |
| Mac with iOS pairing disabled | Local Mac app/build setting | Zero IROH backend requests and listeners | Default off until explicitly enabled. Do not initialize the IROH endpoint, contact relays, start the control socket, enroll, fetch the directory, or schedule credential refresh. |
| Stack sign-in / session refresh | Verified user when available; provider owns sign-in | Provider limits apply; one refresh in flight per app | Our user budget begins only after authentication. Provider quota and pricing are not assumed here. |
| Unauthenticated setup / failed authentication | No user budget until verified | No application IP quota; bounded shared authentication work | Reject missing/malformed credentials cheaply. Never charge a claimed user ID. Remote auth checks need concurrency bounds and timeouts; reject overload before allocating device state. |
| GET /v2/control/socket | User within environment | 300/min, burst 100 | Opening or reconnecting consumes this user allowance. Embedded ticket issuance or challenge work also uses its own operation allowance only when performed. |
| Unknown or malformed control input | User within environment | 6,000/min, burst 1,000 | Shared rejected-input guard for authenticated users, not a general cap on recognized operations. Known message types use their own allowance even when their payload is invalid. Never create counters from arbitrary client-supplied type strings. |
| ticket.request ↔ POST /v2/tickets | User within environment | 1,200/hour, burst 100 | One logical issuance allowance across socket requests, HTTP fallback, and issuance during setup. Reusing a valid ticket does not consume another issuance. |
| session.reauthenticate | User within environment | 1,200/hour, burst 100 | Used when an existing socket must adopt a ticket issued elsewhere. This does not mint another ticket. Renewal through that socket can update its authorization in the same exchange. Message name remains provisional. |
| challenge.request ↔ POST /v2/challenges | User within environment | 300/hour, burst 50 | Same challenge-issuance allowance when setup includes the operation. Retain one pending 30-minute challenge per identity; no new challenge on ordinary resume. |
| device.register ↔ POST /v2/devices/register | User within environment | 300/hour, burst 50 | Accepted allowance: 300/hour, burst 50 per user. Two iPhones and five Macs need seven initial registrations, then normally zero. Separate builds add identities; retries share the allowance. |
| Key replacement / recovery approval (name TBD) | User within environment | 120/hour, burst 20 | Explicit authorization remains mandatory. If approval is a separate method, it has this allowance; the subsequent challenge and proof use their respective operation allowances. |
| relay.token.request ↔ POST /v2/relay/token | User within environment | 1,200/hour, burst 100 | One relay-token issuance allowance across both transports and setup. Independent of API-ticket issuance. Accepted token lifetime remains 30 minutes. |
| directory.request (snapshot or revision resume) | User within environment | 600/min, burst 200 | One directory-method allowance shared across Mac, iOS, and Dashboard. Resume revision and snapshot selection are parameters, not new quota keys. A future separate permission-refresh method needs its own policy. |
| device.metadata.update | User within environment | 600/min, burst 200 | Independent of directory reads and preferences. Coalesce unchanged metadata before work. Direct addresses remain local or between peers. |
| Scheduled DO presence heartbeat (removed) | User within environment | No message, no quota | Accepted removal: no periodic application presence message, presence-only expiry alarm, or presence checkpoint. Use the authorized usable IROH session for connection state. |
| WebSocket protocol ping/pong | Cloudflare/native transport | No application request quota or custom handler | Native clients can initiate protocol pings; Cloudflare automatically sends pong without running the DO handler. No mirrored application heartbeat timer. Exact cadence and failure policy remain open. |
| session.goodbye | User within environment | 600/min, burst 200 | Optional clean end of this control session, not an online/offline lease. Only the matching session can end itself. Actual socket-close cleanup always proceeds even when this message allowance is exhausted. |
| device.revoke ↔ POST /v2/devices/{id}/revoke | User within environment | 120/min, burst 50 | One allowance per user and operation, not per target device ID. Other methods cannot exhaust it. Enforcement of an already-known revocation is never rate limited. |
| preferences.update | User within environment | 300/min, burst 100 | Separate preference-message allowance. Dashboard directory reads and device metadata edits use directory.request and device.metadata.update respectively. Names remain provisional. |
| Concurrent control sockets (capacity, not request rate) | User within environment | 500 current sockets, plus reserved temporary replacements | One current socket per native identity and one replacement is a lifecycle rule. Allow replacement even at the user cap; retire the old socket after the new one is ready, with a proposed 10-second overlap. |
| Control frame size / output backlog (memory bounds) | User total, with per-connection safety bounds | 16 KiB incoming; 64 KiB snapshot chunks; backlog 1,024 messages / 2 MiB per connection; 4,096 / 8 MiB per user | These generous starting bounds are accepted, with tuning after payload/load tests. Stop at either frame or byte bound. Count transport-buffered bytes, allocate on demand, and resume slow sockets safely. No delivered-message or terminal-output quota. Shared DO physical safety and fair handling remain necessary. |
| Server replies / device-change pushes | Authorized subscribers in the team; backlog attributed to recipient user | No separate request quota; bounded output queues | No cap on total replies delivered. Bound unsent bytes so a slow/offline client cannot grow server memory indefinitely. Resync a slow control socket without silently losing revocations; peer terminal traffic is separate. |
| IROH dial / peer admission | Local connection coordinator | One coordinator per peer; no requests-per-minute limit | Deduplicate callers. IROH may try direct and relay paths concurrently; different peers connect independently. Keep a healthy connection during a coordinated replacement. Never wait for the backend before a usable cached attempt. |
| Relay connection / token verification | Verified user within environment, separately at each relay | 600/min, burst 200 per user per relay | Proposed signed token field carries an opaque user quota key. Validate locally before counting. This is not a fleet-wide exact quota; no DO lookup per relay handshake. |
| IROH packets / terminal and artifact streams | Peer connection and relay capacity | Transport flow control; user bandwidth and stream ceilings still to measure | No backend request quota per keystroke or packet. Keep bulk transfers from starving terminal control. |
| Local key lookup / credential installation / direct-path change | Local app / lib IROH | One state owner; deduplicate repeated callbacks | No backend quota. Private direct routes stay local or between peers. |
| Worker to DO routing / auth checks | Verified user within environment | Inherit the originating operation allowance | Verify user and team; route shared state to the team DO. Cross-team user rate-state coordination is required; exact mechanism remains open. Internal routing does not spend another logical allowance. |
| DO SQLite reads / durable mutations | Team DO; initiating user owns the operation allowance | Inherit originating user operation limits | Accepted database constraints/triggers enforce payload, record, binding and user-attributed usage changes atomically. Use indexed bounded reads. Shared physical guards and cross-team user quota coordination need their own explicit implementation. |
| PlanetScale EndpointID map / shared records | Verified user within environment | Inherit enrollment, replacement, and management allowances | Global map stores team plus device owner user. No periodic lookup per relay renewal. Cross-team admin queries need a concrete policy. |
| Challenge / issued-credential cleanup | Device/build identity within team | No scheduled job, no extra quota | One pending challenge slot: replace on request, consume on success, reject after expiry. API/relay credentials need no row per issuance. No cleanup scan or alarm for these records. |
| Error / unsupported schema response | Original user operation; client retry coordinator | Inherit input allowance; upgrade backoff 1h, 6h, then 24h with jitter | User retry remains available. A server error must not permanently strand the client. |
| Metrics / diagnostic logs | User, team, environment, and error fingerprint | Aggregate counts; sample repetitive failures | Log sampling is not a device request quota. Exclude credentials and private payloads; retention and log-volume caps remain open. |
| Development / branch environments | User within each environment | Same generous allowances, independently tracked | Development does not consume production budgets. Devices, builds, or team switches within an environment do not reset the user allowance. |
| DO schema activation / migrations | Team DO | Applied-version check; bounded missing migrations; no client request quota | Accepted Drizzle activation gate. Apply schema and version markers transactionally before requests; schema readiness cost is measured separately. |
| Build / deployment checks | Environment and worker release | Required boundary, schema, contract and workerd checks; development then team canary | No user request quota. Never edit shipped migrations; roll back code only with schema compatibility. Large backfills run separately from traffic cutover. |

The output bounds are generous accepted starting values: **2 MiB or 1,024 waiting messages per connection; 8 MiB or 4,096 total per user**. Stop at either bound, count transport-buffered bytes, allocate on demand, and tune after tests. No quota on successfully delivered messages or terminal output. Slow recipients can pause/resume or resync; never silently lose permission removals. Team DO physical memory must also stay bounded, with fair treatment under shared pressure.

User-attributed product storage/device allowances remain user-based. The SQLite file and DO memory are physically shared by a team, so they also require system safety guards. Do not copy Lawrence’s 32-binding or 8-MiB account-storage threshold onto an entire team. Attribute user-owned records to their owner; the policy for team-wide shared metadata and physical guard sizes remains open.

## Accepted backend storage and release rules

Shared HTTP/socket operations use the team-local broker. Drizzle schema readiness gates requests; shipped migrations are append-only. Database constraints/triggers enforce usage in the same mutation transaction. Challenges use one pending slot per identity, checked when used and replaced on the next request. There is no challenge cleanup job or per-issued-credential deletion. Future retained-history cleanup requires a concrete policy. Real workerd tests, generated-contract/schema checks and the no-Vercel boundary check are required release checks. Development verification precedes a team canary and promotion of the same build. [Full implementation rules](IROH-DECISIONS.md#accepted-backend-implementation-rules).

## Required handling

- HTTP limits return 429 plus Retry-After. Socket limits return requestId, rate_limited, retryAfterMs and the operation. Share that operation’s cooldown across callers; preserve unrelated work and healthy authorized IROH sessions.
- Record every operation outcome and rate-limit decision as specified in observability. Unknown/unauthenticated users are not charged to a claimed user ID. Bound authentication work before allocating device state.
- User budgets survive reconnect, hibernation and team changes. Tokens/keys/devices/schema IDs cannot reset them. Enforcing a known revocation and socket-close cleanup always proceeds.
- Mutation retries use the original request ID and reconcile uncertain results. Repeated metadata is coalesced. Fresh enrollment proof cannot bypass revocation.
- IROH has one coordinator per peer, with parallel direct/relay paths and make-before-break replacement. It has no local attempts-per-minute quota.
- Local key/cache reads, credential installation, server replies, internal routing and database calls behind a request receive no extra logical request allowance. They still incur real compute/storage costs.
- No scheduled DO presence heartbeat, presence-only alarm or presence checkpoint. Keep native protocol ping/pong without DO handler work, IROH failure detection and request deadlines.
- Mac pairing off means zero IROH listeners/backend/relay/renewal work. The application lifecycle diagram shows gating and cancellation.
- Remove incompatible legacy Mac/iOS routes, fallbacks, timers and supporting code. Verify upgrade and failure paths use v2 only; keep supported v2 schemas and the agreed v2 HTTP recovery path.

## Expected usage

The client owns renewal timing; the DO validates authority and returns the replacement. The DO has no per-client renewal timer. Proposed timing is ticket minute 55 and relay minute 25, while accepted lifetimes remain one hour and 30 minutes.

Default: **100,000 enabled app instances**, 24 active hours/day, one socket opening and two metadata changes/app/day, 30-day month. One user with two phones and five Macs has seven instances; 100,000 such users means 700,000 instances if all are enabled. Actual iOS active time will be lower and must be measured. Team fanout depends on authorized recipients, not just the initiating user’s devices.

For H active hours/day, S openings/day and M metadata changes/day: ticket requests = 60H/55; relay requests = 60H/25; openings = S; metadata = M; scheduled DO presence = 0. Counts are long-run averages; setup issuance replaces a due renewal in this estimate. Add real first enrollments, expired startup state, retries, permission refresh, team changes and user actions. Replies and internal work are related work and must not be summed as extra incoming client requests.

| Operation / unit counted | Per app / day | 100,000 apps / 30 days | Trigger / backend work |
| --- | --- | --- | --- |
| Control socket upgrades | 1 openings | 3,000,000 openings | First backend operation. One Worker request and one routed DO request per attempt. |
| HMAC ticket issue / renewal | 26.18 requests | 78,545,454.55 requests | Scheduled around minute 55; included setup issuance replaces a due renewal. No new ticket for every valid-ticket reconnect. |
| Stack authentication checks | 26.18 logical checks | 78,545,454.55 logical checks | Conservative one fresh team-auth check per ticket issuance. Provider SDK caching/network calls and client session refresh are additional variables. |
| Enrollment challenge | 0 requests | 0 requests | Zero in normal operation; add one per first enrollment, approved replacement, or recovery. Initial handshake may bundle it. |
| Signed device registration | 0 messages | 0 messages | Zero on normal restart or renewal; add one accepted submission per enrollment. Retries add traffic. |
| Key replacement / recovery | 0 operations | 0 operations | User-driven; add approved cases, proof attempts, and global ownership updates. |
| Relay credential renewal | 57.6 messages | 172,800,000 messages | One renewal request around minute 25. Uses existing control socket and team authorization; no ordinary Stack call. |
| Directory snapshot / revision resume | 1 deliveries | 3,000,000 deliveries | One per socket opening in this model, bundled with setup when possible. Revisions avoid unnecessary full lists; gap requests are extra. |
| Signed peer-permission refresh | event-driven | Not yet measured | May share directory delivery. Additional cadence cannot be estimated until the offline permission lifetime is chosen. |
| Changed device metadata | 2 messages | 6,000,000 messages | Illustrative user-set count, not telemetry. Each accepted change commits state, acknowledges, and may broadcast. |
| Scheduled DO presence | 0 messages | 0 messages | Removed. Keep transport keepalives, connection failure handling, and request deadlines. No periodic DO presence work. |
| WebSocket protocol ping/pong | transport-dependent | Not yet measured | Runtime/native transport timing. No custom application ping; protocol pings do not add DO request charges. |
| Clean goodbye / transport close | event-driven | Not yet measured | End the control session when it closes. No presence lease; sudden network loss is detected by the transport, with delay. |
| Dashboard listing / device edits / revocations | user-driven | Not yet measured | Count per active Dashboard session or action, not per Mac/iOS instance. Shares the corresponding operations above. |
| Server replies to requests | responses | Not yet measured | Normally one per accepted request, with setup replies able to combine results. Outgoing frames add no DO request charge. |
| Directory / control-session / revocation pushes | event-driven | Not yet measured | Committed changes or observed control-session transitions × recipients. Backend connectivity is not proof of peer reachability. |
| IROH dial / encrypted peer handshake | connection-driven | Not yet measured | One successful admission per new peer connection; retries depend on network. Uses cached data immediately. No backend request per handshake. |
| Relay token verification | connection-driven | Not yet measured | Once per authenticated relay handshake or relay-required reauthentication. Verified locally, without a backend lookup. |
| IROH keepalive / terminal / artifact traffic | bytes / streams | Not yet measured | Depends on active peers, session length, direct-path share, and transferred bytes. Relay bandwidth needs separate measurement. |
| Local credential / key / route updates | 0 backend requests | 0 backend requests | One local install per fresh credential. No server request for private direct-path changes. |
| HTTP fallback operations | 0 extra requests | 0 extra requests | Zero with a healthy control socket. Each fallback adds a Worker request and a routed DO request instead of the socket message. |
| DO activation / schema upgrade | activations / migrations | Not yet measured | Read applied versions on activation; apply only missing bounded migrations. Runtime tests and actual activation metrics establish cost. |
| Build / deployment verification | runs / duration | Not yet measured | Required schema, contract, boundary and workerd checks; development dry run, team canary, then same-build promotion. |
| DO SQLite trust / directory / metadata work | rows | Not yet measured | Reads depend on query and cache behavior; writes on enrollment, changes, and revocation. Steady modeled metadata mutations equal the metadata row above. |
| DO SQLite presence writes | 0 writes | 0 writes | No scheduled application presence mechanism. Separate rate counters and real device mutations still have storage costs. |
| PlanetScale EndpointID ownership work | 0 steady operations | 0 steady operations | Add enrollment, replacement, or ownership-management events. No periodic heartbeat or relay-renewal query. |
| Challenge / issued-credential cleanup | 0 scheduled invocations | 0 scheduled invocations | No cleanup job. Challenge slot changes happen inside enrollment requests; signed credentials expire through validation without a row per issuance. |
| User rate-limit state checkpoints | writes | Not yet measured | User allowances must survive reconnect, hibernation and team switches. No presence checkpoints. Persistence frequency remains an implementation decision. |
| Retries / errors / schema-upgrade checks | 0 extra attempts | 0 extra attempts | Healthy baseline only. Add observed failures and long-backoff checks; preserve existing healthy peer connections. |
| Cross-team user quota coordination | internal requests / writes | Not yet measured | Separate team objects must share a user budget. Mechanism, batching and request/storage costs remain unmeasured. |
| Backend operation completion events | 86.78 records | 260,345,454.55 records | One compact completion event per modeled logical operation, including successes and limit denials. Major state events and internal jobs add records; export/retention costs remain unmeasured. |
| Metrics / logs / reporting / branch cleanup | events / bytes | Not yet measured | All backend operation/event categories are covered. Debug detail alone may be sampled; retention, batching, provider export cost, and cleanup need measurement. |

## Request-only illustration

Modeled incoming messages = ticket + relay renewal + metadata = **257,345,454.55/month**. Add **3,000,000 upgrades**. At 20 incoming socket messages per billed DO request, this is **15,867,272.73 DO request equivalents/month**. With the full 1-million included allowance and current invoice rounding, this single request dimension is approximately **$2.25/month**.

This is an incomplete request subtotal. **Cross-team user quota coordination, observability export/retention, team fanout, Worker charges, DO duration, storage/index work, Stack authentication, PlanetScale, relays and logs are additional and unmeasured.** Do not describe this number as the backend bill. Internal DO RPC calls are not automatically eligible for the WebSocket message billing ratio.

All logical operations now generate compact completion records, so observability volume must be modeled independently. No sampling of normal operation outcomes is assumed. Export batching and retention materially affect cost; never claim logs are free because the DO request subtotal is small.

[Cloudflare DO pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/). Billing allowances are shared across the Cloudflare billing account, independent of product users or Stack teams.

## Remaining measurements

Team sizes and active devices; per-user counter coordination; authorized recipient fanout; DO active time; storage/index growth and user attribution; physical memory limits; transport keepalive intervals; offline peer-permission lifetime; retries; relay bytes; Stack calls; observability record sizes/exports/retention; branch cleanup and spend alerts.

Dictionary: A burst permits several requests together. Jitter spreads retries over a small random delay. A buffer holds unsent data. Fanout is delivery of one event to multiple recipients. A request equivalent is the provider’s billing unit after its socket-message ratio.
