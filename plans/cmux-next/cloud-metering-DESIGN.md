# Cloud metering: VM time and tokens on ClickHouse

Status: prototype landed behind `CMUX_VM_METERING_CLICKHOUSE=1` (off). Owner: Cloud.
Date: 2026-10-28.

## Decision

- **ClickHouse is the billing source of truth** for usage-based pricing:
  VM time from the new `vm_runtime_events` table, tokens from the existing
  coderouter `usage_events` ledger. Both are on our ClickHouse Cloud service
  (`~/.secrets/clickhouse.env`, databases `coderouter` for prod and
  `coderouter_dev` for dev). We own the data and can run any SQL query or
  export it.
- **PostHog gets the product-analytics mirror only.** That mirror already exists:
  `cloud_vm_usage_hourly` (`web/services/vms/usageAnalytics.ts`) and the
  `cloud_vm_paused`/`cloud_vm_resumed` events. PostHog does not invoice.
- **Stripe gets only totals per team or user per period.** The a619 paid-plans
  work reports usage from `usageForPeriod()`. Stripe never receives raw events.
- **VM usage is the time between recorded resume and pause.** Paused time never
  counts. The machine count is not a factor.

## What already existed (and why the prototype builds on it)

The pause and resume points are already recorded transactionally. The
`cmux_vm_runtime` trigger on `cloud_vms` (migration
`20260912080000_go_runtime_limits`) works like this:

- It opens a `cloud_vm_runtime_intervals` row when a machine enters
  `provisioning` or `running`.
- It closes the row on any other status.
- It runs in the same transaction as the status change.

Every path that pauses or resumes a VM goes through that status column: a306
idle auto-pause (`idlePause.ts` → `workflows.ts pauseVm`), the Pause and Resume
actions, a466 Freestyle create, the reaper, and the status reconcile. So we do
not add hooks at each call site. We copy the intervals. Adding a new pause path
cannot skip the meter.

The Go plan's 40-hour limit already reads these intervals (`goUsage.ts`,
`planUsage.ts`).

## Prototype (`web/services/vms/metering/`)

| file | what |
| --- | --- |
| `web/db/clickhouse/007_vm_runtime_events.sql` | `vm_runtime_events` ReplacingMergeTree(version) + `vm_runtime_intervals` view |
| `vmMeterEvents.ts` | interval → `<interval id>:start` / `:stop` rows, version rule |
| `vmMeterReconcile.ts` | pure three-way diff Postgres / ClickHouse / provider |
| `vmMeterJob.ts` | the cron: sync, then reconcile; flag gate |
| `vmMeterPostgres.ts` | production loaders (drizzle) and provider `getStatus` |
| `vmMeterUsage.ts` | monthly / per-period query (VM seconds, vCPU seconds, tokens) |
| `app/api/cron/vm-metering/route.ts` | every 5 min (`vercel.json`); answers `enabled:false` without the flag |
| `web/tests/vm-metering.test.ts` | 16 tests (red commit first, then green) |

### Idempotency and late events

- The event id is deterministic (`<interval id>:start|stop`). A replayed sync
  or an overlapping window writes the same key again.
- `ORDER BY (stack_user_id, vm_id, event_id)` is the dedup key.
- The partition is the **interval's** start month, not the event's time. So the
  two rows of one key always share a partition and can merge. If the table were
  partitioned by event time, a reconcile stop and a Postgres stop on two sides
  of a month boundary would never deduplicate.
- Readers do not depend on merges. The view picks `argMax(..., version)` per
  event id. PostHog's events table has the same merge-only dedup and no
  query-time correction. Its own handbook calls that a mistake.
- Stop version = `2^53 − stop_ms`, so **the earliest proven stop wins**. A
  reconcile stop observed at Freestyle beats the later Postgres stop that the
  status cron writes. A stop never moves later, so we never overbill.
- Late events: the sync re-reads a 30-minute window every 5 minutes. A run can
  fail 5 times in a row without losing a row. Inserts use
  `wait_for_async_insert=1`, so a failed write fails the run and alerts through
  the cron monitor. Request telemetry keeps the old fire-and-forget behavior.
- No TTL on the table. The rows back invoices.

### Reconciliation (Freestyle has no webhooks)

On each run the cron compares three sources and applies only safe fixes:

| Postgres | ClickHouse | Freestyle `vms.get` state | action |
| --- | --- | --- | --- |
| open | open | `paused` / `destroyed` (404) | stop at observation time, `source=reconcile` |
| open | missing | any | replay the start |
| closed | open | any | replay the stop from Postgres |
| open | open | `creating` or read failed | nothing (never stop on doubt) |
| no open interval | — | running | not billed here. This is our cost. The existing `vm-reconcile` cron repauses or fixes the status. |

The existing `vm-reconcile` cron already fixes `cloud_vms.status` from
Freestyle. That closes the Postgres interval at *reconcile* time, up to one cron
period late. The metering reconcile caps that at its own observation time, and
the earlier stop wins by version.

## Measured numbers (2026-10-28)

Production Postgres (read-only query):

- 13,098 intervals in total, 280 open now.
- Last 30 days: 12,610 intervals, 11,947 VMs, 3,191 users, 100,078 VM-hours.
- Interval length: p50 3.7 min, p95 127.6 min.

So VM metering is about **25k events a month**. The token ledger is already
424,165 `usage_events` rows across 43 teams in 30 days. Both are tiny for
ClickHouse.

Live check on ClickHouse Cloud `coderouter_dev`: all 12,343 production
intervals that overlap October 2026 (ids md5-anonymized, rows deleted
afterwards):

| check | result |
| --- | --- |
| events | 24,407 (279 open intervals) |
| insert, 3 batches of ≤10k, `wait=1`, from a laptop | 6.2 s / 8.4 s / 6.1 s per full replay |
| replayed 3× + 50 reconcile stops + 50 later Postgres stops | raw rows 48,957 (merges still pending), unique event ids 24,457, intervals in view **12,343** (exact) |
| earliest-stop rule | 50 of 50 intervals ended at the reconcile stop |
| October VM-seconds, ClickHouse SQL | 365,362,019 |
| same, TypeScript `meteredSeconds` | 365,362,027 |
| same, Postgres SQL | 365,362,027 |
| difference | 8 s in 101,489 h (each of the 2,939 team/user rows rounds to whole seconds) |
| monthly query (VM + tokens, 2 parallel queries) | 74–164 ms (5 runs) |

## ClickHouse vs PostHog for metering

| | raw ClickHouse (chosen) | PostHog |
| --- | --- | --- |
| Dedup | Deterministic. Query-time `argMax` plus ReplacingMergeTree, keyed by our own event id. | Merge-only on (uuid, event, distinct_id, **date** of timestamp). Not applied at query time. The handbook calls this "a mistake" ([sharded_events](https://posthog.com/handbook/engineering/clickhouse/schema/sharded-events)). Resends with a new `sent_at` double-count ([posthog-js#5356](https://github.com/PostHog/posthog-js/issues/5356)). |
| Corrections (earliest stop wins) | A version column we control | Only a replace with the same uuid and exact timestamp. No "keep min" rule. |
| Late events | Any time. They land in the interval's partition. | Accepted, but dashboards and insights may already have cached the period |
| SQL access | Full SQL, our users, read-only role for dashboards | HogQL, 2,400 queries/h on the query API ([API docs](https://posthog.com/docs/api)) |
| Export | `SELECT … INTO OUTFILE` / S3 table function, no extra cost | Batch exports: 1M rows/month free, then $0.000015/row ([pricing](https://schematichq.com/blog/posthog-pricing)) |
| Cost at our volume (~25k VM + ~425k token events/month) | Already paid (existing service) | Inside the free 1M events, but we would pay again for the token ledger we already keep |
| Lock-in | None | Closed hosted schema. Self-hosting is possible but not run by us. |

PostHog stays useful for funnels and joining usage to people, so the hourly
mirror stays.

## Rollout

1. Done: `007` applied to ClickHouse `coderouter_dev` and `coderouter` (additive,
   `IF NOT EXISTS`). This keeps the schema-drift alert quiet when the manifest
   change deploys.
2. Set `CMUX_VM_METERING_CLICKHOUSE=1` on Vercel staging. Watch `vm-metering`
   cron results (`drift` counts) for a day.
3. Backfill: a one-off run of `loadIntervals(new Date(0))` (not built yet; about 10 lines).
   Every interval is idempotent, so the backfill is safe to repeat.
4. Turn the flag on in prod. a619 reads `usageForPeriod()` for Stripe meter
   reports (totals only, idempotency key = team + period).

## Open items

- `team_id` on VM rows is `billing_team_id`, else `owner_team_id`. The token
  ledger's `team_id` is the coderouter team. Both are Stack team ids. Verify
  the two match for one real team before invoicing.
- A machine's shape (vCPUs) is copied at sync time. A resize re-rates only the
  intervals that are synced after it. The current Pro/Max allowance re-rates the
  whole period instead (`planUsage.ts`).
- Better stop bound: the idle-pause probe proves "running" every 5 minutes.
  Storing the last successful probe would let the reconcile stop at the last
  probe that saw the machine running, not at the time the reconcile observed the
  stop.
- `cloud_vm_runtime_intervals.ended_at` has no index. Add a partial index past
  about 1M rows.
- The job is plain TypeScript with injected dependencies, the same as
  `services/coderouter/clickhouse.ts`. The backend default is Effect. Port it
  when it leaves prototype.
