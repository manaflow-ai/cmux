# Auth provider load

Every authenticated request used to cost one `GET /users/me` call to Stack
Auth. At device-registry volume that reached millions of calls a day and
exhausted the project-wide rate limit, which surfaced as unrelated 429s on
billing and sign-in.

Three paths now answer without calling Stack:

| Path | Used by | What it proves |
| --- | --- | --- |
| `verifyRequestIdentity` | iroh broker, `/api/relay/token` | The caller's user id, from a locally verified access token |
| `verifyRequestFromSnapshot` | `/api/devices` GET and POST | User id plus team membership, from `stack_identity_snapshots` |
| `verifyRequest` | billing, VM mutations, account, admin, `/api/devices` DELETE | Live Stack session, no caching of the decision |

A snapshot is refreshed from Stack at most once per `CMUX_STACK_IDENTITY_
SNAPSHOT_TTL_MS` (default ten minutes) per user,
and is deleted on sign-out. Account deletion is enforced on read instead: the
snapshot path checks the deletion tombstone directly on every request, so a
tombstone takes effect immediately rather than after the TTL.

The TTL is the security parameter here. When a user is removed from a team,
Stack's `team_membership.deleted` webhook (`app/api/webhooks/stack`, secret
`STACK_WEBHOOK_SECRET`) deletes their snapshot and detaches their tunnels from
the team's network. The TTL bounds exposure only when that delivery is missed
or still retrying. Ten minutes costs one Stack call per active user per ten
minutes, under 7 a second fleet-wide.

## Hexclave mirror

The same webhook receives every Hexclave event type and keeps the `hexclave_*`
tables (users, teams, memberships, direct team and project permissions) equal
to Hexclave. Code is in `hexclave/`. Each verified body is validated against
the Hexclave package's own yup schema for its type (`webhookEvents.ts`): a
schema failure answers 400 and is never processed, and an unknown type answers
200 and is logged. A valid event is only a signal: the named user or team is
re-read from the Hexclave server API under a per-entity advisory lock and the
mirror is rewritten from that read, so Svix's unordered and repeated delivery
cannot write stale state. Deleted users and teams leave a tombstone that stops
a reconcile that read before the deletion from writing them back. Removals
still call `revokeTeamMemberAccess` / `revokeTeamAccess`, and every user change
deletes that user's identity snapshot. `hexclave_webhook_events` records svix
ids; a processed id is acknowledged without work.

Fill or repair the mirror with `bun run hexclave:backfill-mirror -- --dry-run`,
then without `--dry-run`, with `DATABASE_URL`, `NEXT_PUBLIC_STACK_PROJECT_ID`
and `STACK_SECRET_SERVER_KEY` set (see `scripts/hexclave/backfill-mirror.ts`).

## Measuring it

Auth resolution is stamped on the request span the tracer already emits, so
there is no second event stream to pay for. The app-wide 2% head sample is
ample for a rate in the hundreds per second.

```kusto
['cmux-prod-otel-traces']
| where _time > ago(1h)
| where isnotempty(['attributes.custom']['cmux.auth.source'])
| summarize c=count() by
    source=tostring(['attributes.custom']['cmux.auth.source']),
    called=tostring(['attributes.custom']['cmux.auth.provider_called'])
```

The ground truth for provider load is the outbound span itself, which is what
Stack Auth sees:

```kusto
['cmux-prod-otel-traces']
| where _time > ago(6h)
| where name contains 'users/me'
| summarize c=count() by bin(_time, 10m)
```

Multiply by 50 for the real rate: `users/me` spans hang off request traces that
are head-sampled at 2%, except under `/api/vm*`, which is kept in full.

# Surviving clients that never update

The auth-provider fix above holds for every client version, because it changes
what the server does with a request rather than what the client sends. Two more
defenses exist for the same reason.

**Redundant registrations skip the write.** `POST /api/devices` compares the
incoming registration against the stored rows, under the per-team advisory
lock so a concurrent registration cannot slip between the read and the answer,
and returns success without either upsert when the only difference would be a
presence timestamp refreshed within `CMUX_DEVICE_PRESENCE_TOUCH_INTERVAL_MS`
(one minute). This matters because the Mac's own dedupe compares route hints
carrying observation timestamps, which `sanitizeServerPublishedRoutes` strips
before storing. A shipped Mac therefore re-registers identical rows for as long
as it runs, and no client update can change that.

**Throttles name a delay.** Native ingress 429s carry `Retry-After`. The iroh
broker client already shipped honors it and persists an account-scoped cooldown
across relaunch, so this is the one backpressure signal that reaches builds we
cannot update. A 429 without the header tells that client nothing and it falls
back to its own retry cadence.

The client user agent is `cmux/102` for every build, stable and nightly alike,
so traffic cannot currently be attributed to a version. Assume the worst case:
whatever is storming will still be storming after the next release.
