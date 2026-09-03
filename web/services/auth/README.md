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
SNAPSHOT_TTL_MS` (default one hour, the Stack access-token lifetime) per user,
and is deleted on sign-out. Account deletion is enforced on read instead: the
snapshot path checks the deletion tombstone directly on every request, so a
tombstone takes effect immediately rather than after the TTL.

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
