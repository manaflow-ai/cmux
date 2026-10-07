# cmux next: automations billing and the Workers for Platforms check

Status: proposal, 2026-10-02 (lane 5, WfP verify + billing). Research only: no Cloudflare resources were created or changed, nobody outside was contacted. Builds on plans/cmux-next/automations-runtime.md (round 2, commit 6620725970c), which holds our prototype evidence. Spec owner: the coordinator. Proposed spec text is in the appendix.

Every claim cites a URL and a date. "Updated" is the page's own "Last updated" date. "Fetched" means read on 2026-10-02. Our prototype results are marked "ours".

## 0. Verdict

| Feature in a WfP user Worker | Status today | Announced? | Workaround |
| --- | --- | --- | --- |
| Workflows | Not supported | No | The platform owns the Workflow. For us: Dynamic Workers + Dynamic Workflows (verified, ours). |
| Cron Triggers | Not supported | No (open issue) | The platform owns the schedule (our SchedulerDO), or DO alarms in the user Worker. |
| Queue consumers | Not supported (ours; undocumented) | No | The platform Worker is the consumer and dispatches by tenant. |

Billing: our own ledger is the source of truth. Tails of each Dynamic Worker give CPU, wall time and outcome per invocation, tagged with team and run. The wrapped step gives exact step counts. Cloudflare GraphQL and the invoice are used only to reconcile.

## 1. Workers for Platforms: purpose and limits

Purpose. WfP runs customer or AI-written code in isolated user Workers. A platform uploads each user Worker to one dispatch namespace. A dispatch Worker routes requests to it by name. An optional outbound Worker sees its `fetch()` calls. Each customer can get its own hostname. (https://developers.cloudflare.com/cloudflare-for-platforms/workers-for-platforms/, updated 2026-04-21; https://developers.cloudflare.com/cloudflare-for-platforms/workers-for-platforms/how-workers-for-platforms-works/, updated 2026-04-21.) Cloudflare advises one namespace for all customers, not one per customer (same page).

Limits and behavior (all fetched 2026-10-02):

| Item | Value | Source |
| --- | --- | --- |
| Scripts per namespace | unlimited | /workers-for-platforms/reference/limits/ (updated 2026-07-03) |
| Price | $25/month; 20M requests, then $0.30/M; 60M CPU ms, then $0.02/M CPU ms; 1,000 scripts, then $0.02 per script; no duration charge | /workers-for-platforms/reference/pricing/ (updated 2026-04-21) |
| Request counting | one request for the chain dispatch -> user -> outbound; CPU is charged across all three | same pricing page |
| Custom limits | `cpuMs` and `subRequests` per invocation, set by the dispatch Worker; exceeding throws at once | /workers-for-platforms/configuration/custom-limits/ (updated 2026-04-21) |
| Isolation | untrusted mode by default: no `request.cf`, per-Worker cache, `caches.default` disabled | /workers-for-platforms/reference/worker-isolation/ (updated 2026-04-21) |
| Tags | at most 8 per script; list and bulk delete by tag | /workers-for-platforms/configuration/tags/ (updated 2026-04-21) |
| Gradual deployments | not supported for user Workers | reference/limits (updated 2026-07-03) |
| API rate | 1,200 requests per 5 min per user token; GraphQL max 320 per 5 min | reference/limits (updated 2026-07-03) |
| Outbound Workers | do not intercept `fetch()` from Durable Objects or mTLS bindings; block `connect()` sockets | /workers-for-platforms/configuration/outbound-workers/ (updated 2026-04-21); open docs issue https://github.com/cloudflare/workers-sdk/issues/13946 (2026-05-16) |
| Per-request capabilities | dispatch Worker passes `props` and RPC stubs (`ctx.exports.X({props})`); a stub is valid only during that request | /workers-for-platforms/configuration/dynamic-dispatch/ (updated 2026-09-16) |
| Bindings | KV, R2, D1, DOs, Queues, Workflows, Containers, VPC, Hyperdrive, Analytics Engine are listed | /workers-for-platforms/configuration/bindings/ (updated 2026-09-16) |

The WfP changelog has no entry after 2025-12-18 (https://developers.cloudflare.com/changelog/product/workers-for-platforms/, fetched). It announces nothing about cron, queues, Workflows or analytics.

Fit for us: WfP is built for customer HTTP apps on their own hostnames. Our automations need durable runs, schedules and per-tenant metering. Those are weak or missing in WfP (section 2 and 4).

## 2. Workflows, cron and queue consumers in user Workers

### 2.1 Workflows: real limit

- Docs: "Workflows cannot be deployed to Workers for Platforms namespaces, as Workflows do not support Workers for Platforms." (https://developers.cloudflare.com/workflows/reference/limits/, updated 2026-09-21.)
- Ours: the binding uploads, `env.WF.create` returns `workflow.not_found`, and `PUT /workflows/{name}` with the namespaced script returns `workflows.api.error.internal_server`.
- A third party measured the same 500 (code 10001) on 2026-09-27 and showed that the same call returns 200 for an account-level script (https://github.com/skyphusion-labs/vivijure-control-plane/issues/537).
- Why the bindings page lists Workflows: the Workflow binding has `workflow_name` and `script_name` (https://developers.cloudflare.com/api/resources/workers_for_platforms/, fetched). Our reading: a user Worker may bind to a Workflow whose class lives in an account-level script. The class cannot live in the namespaced script. That explains our `workflow.not_found`: the binding pointed at a class in the user Worker itself. UNVERIFIED: that a user Worker can call `create()` on an account-level Workflow.
- Conclusion: not a misconfiguration on our side. Tenant step code cannot be a Workflow class in a dispatch namespace.

### 2.2 Cron Triggers: real limit

- A Cloudflare staff member answered on 2026-05-11: "Cron triggers aren't supported on dispatch namespace workers today. Instead, you can use Durable Objects + alarms as a workaround." They promised a wrangler warning. The issue is still open (https://github.com/cloudflare/workers-sdk/issues/13840, opened 2026-05-07, updated 2026-08-17).
- The same issue shows the cause: wrangler returns early for `--dispatch-namespace` before `triggersDeploy()`, and the namespace scripts API has no `/schedules` subresource. This matches ours exactly.
- Account cap for normal Workers: 250 Cron Triggers per account on Paid (https://developers.cloudflare.com/workers/platform/limits/, updated 2026-09-05). Per-team cron cannot use Cron Triggers in any case.

### 2.3 Queue consumers: not supported (ours), undocumented

- Ours: wrangler skips trigger deploy for namespaced scripts, and `POST /queues/{id}/consumers` with the namespaced script returns `10007 This Worker does not exist on your account`, with and without a `dispatch_namespace` field.
- No Cloudflare doc, changelog entry or issue says user Workers can be consumers (searched docs, changelog and cloudflare/workers-sdk on 2026-10-02). Queues docs have no WfP note (https://developers.cloudflare.com/queues/platform/limits/, updated 2026-04-21).
- Producer bindings work (ours, and the bindings page above).

### 2.4 Workarounds that Cloudflare documents or that we verified

1. **Platform owns the trigger, then dispatches.** One platform Worker owns the cron, the queue consumer or the Workflow. It calls `env.DISPATCHER.get(name, {props}, {limits})` per tenant. Cron fan-out was suggested in #13840 above. Each queue has one consumer, so one platform consumer routes by tenant id in the message.
2. **Durable Objects and alarms in the user Worker.** DOs and alarms work in user Workers (ours). One alarm per object; store a schedule table and re-arm for the next due item. `alarm()` has at-least-once delivery with up to 6 retries (https://developers.cloudflare.com/durable-objects/api/alarms/, updated 2026-04-21). Each `setAlarm()` bills one row written (https://developers.cloudflare.com/workers/platform/pricing/, updated 2026-08-28).
3. **Outbound Worker** for egress control and per-tenant subrequest logs. It misses DO `fetch()` (section 1).
4. **Dynamic Workers (Worker Loader) + Dynamic Workflows + DO facets.** This is Cloudflare's per-tenant durable-execution path. The `@cloudflare/dynamic-workflows` library tags each instance with metadata (for example the tenant id) and reloads the tenant's Dynamic Worker when the engine resumes (https://developers.cloudflare.com/dynamic-workers/usage/dynamic-workflows/, updated 2026-07-22; launch post https://blog.cloudflare.com/dynamic-workflows/, 2026-05-01). Facets give tenant DO classes their own SQLite under our supervisor DO (https://developers.cloudflare.com/dynamic-workers/usage/durable-object-facets/, updated 2026-04-21). Ours, round 1: steps, sleeps, events, facets and tail metering all worked.

Recommendation stays as in automations-runtime.md: Tier 1 runs on Dynamic Workers inside our API Worker. Cron stays in SchedulerDO. Queues stay platform-owned. WfP is not used for automations.

## 3. Current Cloudflare prices (Workers Paid)

All from https://developers.cloudflare.com/workers/platform/pricing/ (updated 2026-08-28) unless noted. Base: $5/month minimum.

| Product | Included per month | Overage |
| --- | --- | --- |
| Workers Standard requests | 10M | $0.30/M |
| Workers CPU | 30M ms | $0.02/M ms; max 5 min CPU per invocation (default 30 s); 15 min per cron or queue consumer invocation |
| Duration (wall clock) | not billed | HTTP has no wall limit; cron, DO alarm and queue consumer 15 min (workers/platform/limits, updated 2026-09-05) |
| Dynamic Workers | 1,000 unique per month | $0.002 per Dynamic Worker per day; unique = id + code; billed since 2026-05-26; startup CPU billed; each `fetch()` or RPC call into a Dynamic Worker is a request (https://developers.cloudflare.com/dynamic-workers/pricing/, updated 2026-06-11) |
| Workflows | requests and CPU as Workers; 1 GB-month; 500,000 steps | $0.20/GB-month; $0.80 per 100,000 steps; steps and storage billed from 2026-08-10; retries and rollback handlers are not counted as steps; a sleeping or waiting instance uses no CPU (https://developers.cloudflare.com/workflows/reference/pricing/, updated 2026-09-21) |
| Durable Objects compute | 1M requests; 400,000 GB-s | $0.15/M requests; $12.50/M GB-s (128 MB billed per active object; hibernation-eligible idle time not billed) |
| DO SQLite storage | 25B rows read; 50M rows written; 5 GB-month | $0.001/M rows read; $1.00/M rows written; $0.20/GB-month |
| KV | 10M reads; 1M writes, deletes, lists; 1 GB | $0.50/M reads; $5.00/M writes, deletes, lists; $0.50/GB-month |
| D1 | 25B rows read; 50M rows written; 5 GB | $0.001/M; $1.00/M; $0.75/GB-month |
| Queues | 1M operations (per 64 KB) | $0.40/M; about 3 operations per message |
| R2 Standard | (free tier on page) | $0.015/GB-month; Class A $4.50/M; Class B $0.36/M; no egress fee (https://developers.cloudflare.com/r2/pricing/, updated 2026-10-01) |
| Workers Logs | 20M events | $0.60/M; 7-day retention |
| Logpush (trace events) | 10M | $0.05/M |
| Analytics Engine | 10M data points; 1M read queries | $0.25/M; $1.00/M; "currently not billed" (https://developers.cloudflare.com/analytics/analytics-engine/pricing/, updated 2026-04-23) |
| Tail Workers | | billed by CPU time only, not per request (https://developers.cloudflare.com/workers/observability/logs/tail-workers/, updated 2026-06-25) |

Subrequest rules (workers/platform/limits, updated 2026-09-05):

- Subrequests are not billed. Only inbound requests are billed.
- Paid: 10,000 subrequests per invocation by default, configurable up to 10M. Calls to Cloudflare services (KV, R2, D1) count. Each hop of a redirect counts.
- 6 connections may wait for response headers at once; more are queued.
- Service binding and RPC calls between our Workers bill one request plus the CPU of both sides. Each counts as a subrequest. One request may make at most 32 Worker invocations (https://developers.cloudflare.com/workers/runtime-apis/bindings/service-bindings/, updated 2026-08-18; pricing page "Service bindings").
- Dynamic Workers: at most 4 distinct Dynamic Workers in flight per Worker request, 10 per Durable Object (https://developers.cloudflare.com/dynamic-workers/platform/limits/, updated 2026-08-27). Custom `limits: {cpuMs, subRequests}` per load or per `getEntrypoint()`; the lower one wins (https://developers.cloudflare.com/dynamic-workers/usage/limits/, updated 2026-08-27).
- Workflows: 10,000 subrequests per instance by default, up to 10M (workflows limits, updated 2026-09-21).

Example cost of one run of 10 `step.do` calls, 50 ms CPU and 20 Dynamic Worker calls, above the included quotas: steps $0.00008, requests $0.000006, CPU $0.000001. Steps dominate. Storage adds $0.20 per GB-month of retained state. A daily automation whose code does not change costs about $0.06 per month in Dynamic Worker creation ($0.002 x 30) once the account is past 1,000 unique per month.

## 4. Where per-tenant usage can come from

### 4.1 Tail events (exact per invocation; our primary source)

- The runtime type `TraceItem` has `cpuTime`, `wallTime`, `outcome`, `executionModel`, `truncated`, `scriptName`, `dispatchNamespace`, `scriptTags`, `entrypoint`, `durableObjectId` and `tailAttributes` (@cloudflare/workers-types 5.20261002.1, `index.d.ts`, fetched from https://unpkg.com/@cloudflare/workers-types@5.20261002.1/index.d.ts).
- Outcomes: `ok`, `exception`, `exceededCpu`, `exceededMemory`, `scriptNotFound`, `canceled`, `responseStreamDisconnected`, `unknown` (https://developers.cloudflare.com/workers/runtime-apis/handlers/tail/, updated 2026-06-15).
- Logpush trace events have `CPUTimeMs`, `WallTimeMs`, `Outcome`, `ScriptName`, `ScriptTags`, `DispatchNamespace`, `EventType` (https://developers.cloudflare.com/logs/logpush/logpush-job/datasets/account/workers_trace_events/, updated 2026-09-14). CPU time appears at the top level of trace events (workers/platform/limits).
- Dynamic Workers: attach `tails: [ctx.exports.Tail({props: {...}})]` at load. The tail reads tenant ids from `this.ctx.props` (https://developers.cloudflare.com/dynamic-workers/usage/observability/, updated 2026-04-21). Ours: per-run CPU 2 ms and wall 48.6 s, tagged with the tenant.
- WfP: a tail on the dispatch Worker gets two items per request, one for the dispatch Worker and one for the user Worker (tail handler page above). A tail on a user Worker is set in that Worker's own config.
- Caveat: the `truncated` flag exists, and no page promises delivery of every tail. Treat tails as complete in normal operation and reconcile (5.4).

### 4.2 Workers Analytics Engine (dashboards, not billing)

- Writes: 20 blobs, 20 doubles and 1 index per point; 16 KB of blobs; 250 points per invocation; 3-month retention (https://developers.cloudflare.com/analytics/analytics-engine/limits/, updated 2026-04-23).
- It samples at write time when one index is written too fast, and again at query time; each row carries `_sample_interval` (https://developers.cloudflare.com/analytics/analytics-engine/sampling/, updated 2026-04-23).
- WfP docs suggest it for per-user analytics by script tag (WfP observability page, updated 2026-09-17).
- Use: cheap per-team charts with `index = team id`. Not billing: a sampled sum is an estimate.

### 4.3 GraphQL Analytics (reconciliation only)

- `workersInvocationsAdaptive` dimensions include `scriptName`, `scriptTag`, `scriptVersion`, `dispatchNamespaceName`, `isDispatcher`, `status`, `usageModel`. Sums include `requests`, `cpuTimeUs`, `wallTime`, `subrequests`, `duration` (GB-s), each with a confidence interval (community mirror of the live schema, https://pages.johnspurlock.com/graphql-schema-docs/cloudflare.html, fetched; the mirror is undated). The confidence fields show the "Adaptive" datasets are sampled estimates.
- WfP docs say: filter `workersInvocationsAdaptive` by `scriptName` for one user Worker, or by `dispatchNamespaceName` for the namespace (WfP observability page, updated 2026-09-17).
- `workflowsAdaptiveGroups` has per-instance sums: `stepCount`, `allStepCount`, `retryCount`, `cpuTime` (ms), `wallTime`, `executionDuration`, `storageRate`, with dimensions `workflowName`, `instanceId`, `eventType` (same mirror; docs https://developers.cloudflare.com/workflows/observability/metrics-analytics/, updated 2026-06-05, 31-day retention). Our instance id is the run id, so these sums can be attributed per team. Good for reconciliation.
- Dynamic Workers count: `workersInvocationsByOwnerAndScriptGroups.uniq.distinctDynamicWorkerCount` (dynamic-workers/pricing).
- Durable Objects: `durableObjectsPeriodicGroups` has `cpuTime`, `activeTime`, `duration`, `rowsRead`, `rowsWritten` by `namespaceId` and `objectId`; `durableObjectsStorageGroups` only by `namespaceIds` (mirror; https://developers.cloudflare.com/durable-objects/observability/metrics-and-analytics/, updated 2026-06-29). Facets share the supervisor's namespace, so storage is not split per tenant by Cloudflare.
- KV by `namespaceId`, R2 by `bucketName`, D1 by `databaseId`, Queues by `queueId` (mirror). None has a script or tenant dimension. Per-tenant attribution needs a resource per tenant or our own counting at the capability.

**Why `__unknown__` appeared (ours).** No Cloudflare page or issue mentions the string (searched 2026-10-02). The docs say a `scriptName` filter works for user Workers (updated 2026-09-17), so the value is not the documented behavior. Hypotheses, in order:

1. Name lookup after deletion. Round 2 deleted all resources "after". If GraphQL resolves names at query time from a script id, a deleted script and namespace would show `__unknown__` for both fields. This is the simplest fit, because both fields failed together.
2. A late or broken name join for namespaced scripts that `scriptTag` would still identify.
3. A defect for this account or region.

Re-test (no account change beyond a test namespace, under $1): keep the namespace and scripts alive, send 100 requests, query at 5, 30 and 120 minutes grouped by `scriptName, scriptTag, dispatchNamespaceName, isDispatcher, status`, then delete and query again. UNVERIFIED until run.

**Why CPU sums looked too high (ours).** Average about 197 ms per request against a 50 ms limit. Candidates: the dataset is a sampled estimate; rows of the dispatch Worker and user Worker were summed together (`isDispatcher` not split); CPU accrued before the kill on `exceededResources` rows; startup CPU. UNVERIFIED. It does not change the design: we bill measured tail CPU and never the configured limit.

### 4.4 Billable Usage API (invoice truth, daily)

`GET /accounts/{id}/billable-usage` returns usage and cost per product and charge period in FOCUS fields (`ServiceName`, `PricingQuantity`, `ConsumedUnit`, `BilledCost`). Data updates daily. It is labeled alpha (https://blog.cloudflare.com/billable-usage-api/, 2026-08-03; https://developers.cloudflare.com/api/typescript/resources/billing/subresources/usage/methods/paygo/, fetched). Budget alerts exist for pay-as-you-go accounts (https://developers.cloudflare.com/changelog/post/2026-04-13-billable-usage-dashboard-and-budget-alerts/, 2026-04-13). The token needs Billing Read.

## 5. Recommended metering design

### 5.1 Source of truth

An append-only usage ledger that we own. One `UsageMeterDO` per team is its only writer (single writer, OWNERSHIP-PRINCIPLES.md). It holds live counters for quota checks and an outbox to PlanetScale (`usage_events`, then `usage_hourly`). Stripe meters, dashboards and the run page are projections. Cloudflare data never writes the ledger; it only reconciles it.

Ledger record: `{key, team, kind, quantity, unit, run?, automation?, step?, attempt?, commit?, source, observed_at}`. `key` is an idempotency key. Examples: `tail:<run>:<step>:<attempt>:<eventTimestamp>:<i>`, `step:<run>:<step>`, `egress:<run>:<request id>`.

### 5.2 What is measured where

| Meter | Source | Exact? |
| --- | --- | --- |
| `automation.cpu_ms`, `automation.wall_ms`, outcome | tail of each Dynamic Worker; props carry team, run, step, attempt, commit | yes (per invocation) |
| `automation.steps`, `retries`, `sleeps`, `events` | wrapped step in the harness (it sees every `step.do`) | yes |
| `automation.state_bytes` | wrapped step measures each serialized step result and event; times retention -> GB-month | estimate; reconcile with `storageRate` per instance |
| `automation.dynamic_workers_per_day` | distinct `(loader id, code hash)` per UTC day from the ledger | yes; UNVERIFIED that Cloudflare's day is UTC |
| `automation.invocations` | run create in SchedulerDO | yes |
| `egress.requests`, `egress.bytes` | egress gateway (`globalOutbound`) | yes |
| `capability.calls` (op, machine.run, state) | `CmuxCaps` entrypoints | yes |
| `model.spend_usd` | CodeRouter ledger | yes |
| `facet.storage_bytes` | daily: a harness wrapper class around the tenant DO class reads `ctx.storage.sql.databaseSize` (no supervisor API for facet size exists in workers-types 5.20261002.1) | UNVERIFIED; tenant code shares the isolate |
| `vm.minutes`, `postgres.storage_gb` | Freestyle and the team-host role | yes |

Platform overhead (API Worker, SchedulerDO, loader harness CPU, `cmux:` steps) goes to a `platform` bucket, not to tenants. We price it into plan margins.

### 5.3 Aggregation path

1. Tail handler (in the API Worker) batches the items of one invocation and calls `UsageMeterDO(team).record(batch)` once. Cost: one DO request ($0.15/M) plus a few rows written per invocation.
2. The wrapped step and capabilities record in the same DO.
3. The DO dedupes by `key`, updates live counters, and checks budget and quota. On a hard cap it marks the run to stop at the next step boundary (spec rule).
4. Outbox drain (existing OwnerDO alarm) writes events and hourly rollups to PlanetScale.
5. An hourly job sends Stripe meter events per team and meter with idempotency key `team:meter:hour`.
6. Analytics Engine gets one point per invocation (`index = team`) for charts only. ClickHouse (R8) gets logs and traces, not billing.

### 5.4 Reconciliation

- **Daily, against Cloudflare analytics.** Per team: tail CPU vs `workflowsAdaptiveGroups.cpuTime` by instance id; ledger steps vs `stepCount`; distinct Dynamic Workers vs `distinctDynamicWorkerCount`. Account-wide: tail CPU plus platform CPU vs `workersInvocationsAdaptive` CPU of our scripts. Alert at more than 5% drift (tails lost or a harness bug).
- **Daily, against the invoice.** Pull the Billable Usage API. For each Cloudflare service: `unattributed = billed - (sum of tenant ledger x Cloudflare unit price) - platform`. Alert when unattributed cost exceeds 10% of the day or $50. Monthly, the closed invoice is the final check.
- Never re-bill a customer from Cloudflare data. Drift is fixed by finding the bug, then by a credit if we overcharged.

### 5.5 Abuse limits per tenant (proposed defaults; plan-configurable)

| Limit | Default | Enforced by |
| --- | --- | --- |
| CPU per Dynamic Worker invocation | 10 s (Cloudflare max 5 min) | loader `limits.cpuMs` |
| Subrequests per invocation | 1,000 | loader `limits.subRequests` |
| Steps per run | 2,000 (Cloudflare 10,000 default) | wrapped step |
| Step retries | 5 | wrapped step |
| Run wall clock | team default 24 h (`agent_run_default_seconds`) | SchedulerDO deadline |
| Concurrent running runs per team | 50 (account limit 50,000; sleeping and waiting do not count) | SchedulerDO |
| Run creations per team | 5/s, burst 20 | SchedulerDO token bucket |
| Distinct deploys (new code) per team per day | 50 | `automation.deploy` |
| Egress requests per team per minute | 600, allowlist | egress gateway |
| Retention of finished instances | 7 days | `retention` on create |
| Budget per team per month | plan quota, then overage up to a hard USD cap | UsageMeterDO |

Account-wide limits we share across all teams (workflows limits, updated 2026-09-21): 300 instance creations per second per account and 100 per second per Workflow; 50,000 concurrent instances; 2,000,000 queued instances. All tenants run through one `AutomationRunWorkflow`, so 100 creations per second is a global ceiling. Per-team buckets keep one team from taking it. Account backstop: a Cloudflare budget alert.

## 6. Decisions (for the coordinator)

- DECISION: Use WfP for automations? RECOMMEND: no; keep it only for future customer HTTP apps, because Workflows, cron and queue consumers do not run in user Workers (docs + ours) and Dynamic Workflows already work.
- DECISION: Billing source of truth? RECOMMEND: our per-team `UsageMeterDO` ledger fed by tails, wrapped steps and capabilities, because GraphQL and Analytics Engine are sampled and the invoice is daily and account-wide.
- DECISION: Bill platform overhead (harness steps, loader CPU) to tenants? RECOMMEND: no, price it into plan margins, because customers cannot see or control it.
- DECISION: One Workflow class for every tenant? RECOMMEND: yes for now, with per-team rate buckets, and shard into N classes if creations near 50/s, because the 100/s per-Workflow limit is shared.
- DECISION: Run the `__unknown__` re-test (a test namespace, under $1)? RECOMMEND: only if WfP returns for HTTP apps, because automations do not depend on it.

## 7. UNVERIFIED

- Cause of `__unknown__` and of the high CPU sums in our WfP prototype (4.3).
- That a WfP user Worker can call an account-level Workflow through a `script_name` binding (2.1).
- That tail `cpuTime` of a Dynamic Worker includes billed startup CPU.
- Tail delivery guarantees and how often `truncated` is set.
- That Cloudflare's "per day" for Dynamic Workers is a UTC day.
- Reading facet SQLite size safely from a harness wrapper (5.2).
- The GraphQL field list comes from an undated community mirror, not live introspection.
- Billable Usage API path and field names (alpha; two paths in the docs).

## Appendix: proposed spec text (spec/cloud-and-automations.md, "Billing")

> ## Automations billing (proposed 2026-10-02, plans/cmux-next/automations-billing.md)
>
> - Workers for Platforms is not used for automations: its user Workers cannot run Workflows, Cron Triggers or queue consumers (Cloudflare docs and our test, 2026-10-02).
> - Source of truth: an append-only usage ledger with one writer per team (`UsageMeterDO`). Records carry an idempotency key, team, meter, quantity, unit and run, step and attempt when they apply. PlanetScale and Stripe are projections.
> - Sources: Dynamic Worker tails (CPU ms, wall ms, outcome per invocation), the wrapped step (steps, retries, state bytes), the egress gateway, capability calls, the CodeRouter ledger, Freestyle VM minutes.
> - Cloudflare GraphQL Analytics and the Billable Usage API reconcile the ledger daily; they never write it.
> - Per-team limits: CPU and subrequests per invocation, steps and retries per run, concurrent runs, creation rate, deploys per day, egress rate, retention, budget with a hard cap that stops a run at a step boundary.
> - Platform overhead is not billed to tenants.
