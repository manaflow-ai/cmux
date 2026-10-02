# cmux next: automations runtime (where chief-written automation code runs)

Status: round 2, 2026-10-02 (automations runtime researcher). Spec owner: the coordinator (only the coordinator edits the spec repo; proposals in the appendix). Related: PR https://github.com/manaflow-ai/cmux/pull/16762 (SchedulerDO + Workflows + integrations), spec/team-vm.md, decisions N1 (chief, working name) and C1 (code.storage).

Decided by Lawrence (2026-10-02): R2 authoring API = Cloudflare Workflows API + `env.cmux`; R4 = subscription plans with included quotas plus metered overage; R5 = one code.storage repo per team; R6 superseded (Workers for Platforms purchased). Still open: R1 (now answered by the WfP prototype below), R3 (Lawrence leans pinned workerd, unsure), and the new questions in Section 8.

## 1. Findings

Verified means run by this lane on 2026-10-02; the rest cites primary docs.

### 1.1 Workers for Platforms (WfP), real prototype (round 2)

Resources: dispatch namespace `cmuxnp-dev-ns-exp1791193822`, user Worker `cmuxnp-dev-t1-exp1791193822` (deployed with `wrangler deploy --dispatch-namespace`), dispatch Worker `cmuxnp-dev-dispatch-exp1791193822` (custom limits `cpuMs: 50, subRequests: 20`), queue `cmuxnp-dev-q-exp1791193822`, all on account 0c1675e0, deleted after.

| Binding or feature in a dispatch-namespace user Worker | Result |
| --- | --- |
| Durable Objects (SQLite class, migration in upload) | **works** (counter state kept across requests) |
| Durable Object alarms | **works** (alarm armed for 5 s fired once; propagation after deploy took a few seconds) |
| Queues producer | **works** (`send` accepted) |
| Queues consumer | **does not attach**: wrangler skips trigger deploy for namespaced scripts (`deployWfpUserWorker` returns before `triggersDeploy`), and `POST /queues/{id}/consumers` with the script name returns `10007 This Worker does not exist on your account` (also with a `dispatch_namespace` field) |
| Cron Triggers (`scheduled`) | **does not attach**: no schedules subresource for namespaced scripts (the path is treated as a script upload); no `scheduled` run after 5+ minutes |
| Workflows | **does not work**: the binding uploads, but `env.WF.create` returns `(workflow.not_found)`; creating the Workflow with `PUT /workflows/{name}` and the namespaced script name returns `workflows.api.error.internal_server` (with and without `dispatch_namespace`). Matches the Workflows limits page ("Workflows do not support Workers for Platforms"); the WfP bindings page claiming Workflows is wrong for us today |
| Custom limits | **enforced**: a heavy loop failed with `Worker exceeded CPU time limit.` (analytics status `exceededResources`) |
| Per-tenant usage (GraphQL `workersInvocationsAdaptive`) | **not attributable yet**: 30+ minutes after the traffic, every namespaced invocation reports `scriptName: "__unknown__"` and `dispatchNamespaceName: "__unknown__"` (requests, status and `cpuTimeUs` are present). Filtering by our script name returns nothing. The CPU sums (about 197 ms average per request for a loop that should take a few ms, and above the 50 ms limit) do not match the custom limit, so they are not billing-grade without explanation |

Conclusion: WfP gives isolated user Workers with Durable Objects (including alarms) and queue producers, but no Workflows, no cron and no queue consumers through the public API, and its per-script analytics did not attribute our usage. For durable runs it is strictly weaker than the Dynamic Workers path below. Keep it only as a later option for user apps that serve their own HTTP hostnames.

### 1.2 Dynamic Workers (Worker Loader) + Dynamic Workflows + DO facets (round 1, verified)

Cloudflare's purpose-built path for per-tenant code (https://developers.cloudflare.com/dynamic-workers/): one loader Worker loads tenant code at runtime, one Workflow class serves every tenant (`@cloudflare/dynamic-workflows` 0.1.1, MIT, about 150 lines), and a supervisor DO runs a tenant `DurableObject` class as a facet with its own SQLite. Workers Paid, which we have. Pricing: 1,000 unique Dynamic Workers per month included, then $0.002 per Dynamic Worker per day (unique = id plus code); requests and CPU at Workers Standard rates; startup CPU billed. Limits: 4 distinct Dynamic Workers in flight per request, 10 per DO.

Prototype `cmuxnp-dev-dynwf-exp1791192478` (deleted): `step.do`, `step.sleep`, `waitForEvent` ran tenant code on real Workflows; duplicate instance id refused (`instance.already_exists`); per-tenant facet SQLite; egress allowlist gateway; a tail reported per-run CPU (2 ms) and wall time (48.6 s) tagged with the tenant, which is billing data we own (no `__unknown__` problem). Create to first step 0.3 s to 3.3 s.

| | Dynamic Workers in our API Worker | WfP dispatch namespace |
| --- | --- | --- |
| Workflows (durable steps, sleeps, events) | yes, verified | no, verified |
| Cron | SchedulerDO (#16762) | not on user Workers (DO alarms only) |
| Durable state | DO facets, verified | DOs, verified |
| Queues | platform queues via capability | producer only |
| Per-tenant usage | tails tagged by tenant, verified | GraphQL attributed `__unknown__`, verified |
| Deploy per tenant change | none (new commit = new loader id) | script upload per tenant |
| Cost | Workers Paid + $0.002 per Dynamic Worker per day above 1,000/month | $25/month + $0.02 per script above 1,000 |

Workflows limits and price (https://developers.cloudflare.com/workflows/reference/limits/, /pricing/): sleep up to 365 days; 10,000 steps per instance (25,000 configurable); 1 MiB per step result and event; 1 GB state per instance; 30-day retention (settable per instance); 50,000 concurrent instances per account (sleeping and waiting instances do not count); instance id up to 100 characters; 300 creations per second per account. Steps and storage billed since 2026-08-10: 500,000 steps included then $0.80 per 100,000; 1 GB-month then $0.20 per GB-month. Workflow `schedules` are capped at 100 per account, so per-team cron stays in SchedulerDO.

### 1.3 In-VM tier on a real Freestyle VM (round 2)

VM `cmuxnp-dev-wd-exp1791194030` (vm-061a221488794ee1bfdac85dd8926169) on the shared cmux Freestyle account: Ubuntu 24.04, x86_64, 4 vCPU, 8 GB, created in 256 ms, `ttlSeconds` 3 days (self-deletes at exp), metadata `owner=cmuxnp-automations-runtime`. Harness: the round-1 loader (Worker Loader, `DynamicWorkflow`, facets, egress gateway, tail meter) under `wrangler 4.137.0` (bundles workerd 1.20260921.1) as systemd unit `cmux-automations-host`, state in `/var/lib/cmux-automations`. `npm install` took 9 s.

- Functional: the same tenant code ran (`step.do`, facet counter, egress, `sleep`, `waitForEvent`).
- **Bug found: sleeps are not re-armed after a process restart.** After `systemctl restart` or a VM reboot, every sleeping instance stayed `running` past its wake time (two instances 2 to 3 minutes overdue, one 100 s overdue) until something touched it. Any `sendEvent` to the instance re-armed the timer and the overdue sleep finished immediately. Events (waitForEvent) already survived restarts in round 1. The local engine is documented as an emulation (https://developers.cloudflare.com/workflows/build/local-development/), and this is where it shows.
- **Shim that fixes it (verified):** the harness records every instance id it creates in a DO table; `POST /wake-all` sends a no-op `cmux-wake` event to every non-terminal instance; systemd `ExecStartPost` calls it. With the shim, a 40-second sleep spanning a VM poweroff (Freestyle booted the VM again about 6 s later) completed at 40.02 s, and a 3-minute sleep spanning the earlier reboot completed as soon as the shim ran.
- Freestyle behavior: `systemctl poweroff` in the guest stopped the VM and Freestyle booted it again about 6 to 12 s later, although the SDK comment says `poweroff` leaves it off (`automaticRestart` defaults to true). UNVERIFIED which is intended.
- Idle cost of the harness (systemd cgroup, 2-minute windows, 5 to 9 sleeping instances): 0.85 to 1.1 CPU s per minute (1.4% to 1.8% of a core) and 332 to 458 MB. Per process: workerd under 0.1 CPU s per minute and about 200 MB (two processes, 78 + 127 MB); the rest is wrangler's Node dev server (about 0.4 CPU s/min, 220 MB) and its esbuild service (about 0.5 CPU s/min). The dev toolchain, not workerd, costs the idle CPU.
- Soak started 2026-10-02 09:55 UTC (re-armed by the shim after the 10:02 and 10:04 restarts): `soak_1h`, `soak_3h`, `soak_6h`, `soak_24h` (sleep 1, 3, 6 and 24 hours). Due about 10:55, 12:55, 15:55 UTC today and 09:55 UTC on 2026-10-03, before the VM's TTL. Check: `curl -s 127.0.0.1:8787/status?id=soak_6h` inside the VM (Freestyle exec as root). Results go into this document when they land.

### 1.4 Postgres on the team VM (round 2, verified on the same VM)

`apt-get install postgresql` (16) took 26 s. Per-app isolation that matches team-vm.md's Linux mapping (`app-<app>` users): role `app_<app>` with `LOGIN CONNECTION LIMIT 20`, `statement_timeout 30s`, `idle_in_transaction_session_timeout 60s`, `temp_file_limit 1GB`; database `app_<app>` owned by it, `REVOKE ALL ... FROM PUBLIC`; `pg_hba` line `local sameuser all peer map=cmuxapps` with `pg_ident` entries `cmuxapps app-<app> app_<app>`. Verified: `app-notes` reaches only `app_notes`; it can neither log in as `app_crm` nor open database `app_crm` as `app_notes` (two independent refusals). No passwords exist. Idle: 63 ms CPU per minute and 47 MB.

### 1.5 TypeScript durable or queue libraries on Postgres (round 2)

Idle measured in containers on this Mac (Postgres 17, cgroup CPU, 90-second window, one job queued for later and one completed). Postgres alone idles at 12 ms per minute.

| Library (version, license) | Model | Wake-up mechanism (source) | Idle CPU per minute, app + Postgres | Memory, app + Postgres |
| --- | --- | --- | --- | --- |
| graphile-worker 0.18.0 (MIT), `pollInterval` 60 s | job queue, cron via crontab | `LISTEN "jobs:insert"` wakes on new jobs; future `run_at` jobs are found by the poll timer (`worker.ts` `setTimeout(doNext, pollInterval)`), so they can start up to `pollInterval` late | 6 + 17 ms | 23 + 29 MB |
| graphile-worker 0.18.0, default `pollInterval` 2 s | same | same | 28 + 19 ms | 33 + 33 MB |
| pg-boss 12.35.1 (MIT), `useListenNotify: true` | job queue, cron, `startAfter` | NOTIFY plus a backstop poll of at least 30 s; maintenance timers | 60 + 72 ms | 48 + 38 MB |
| Absurd 0.5.0 (Apache-2.0, "early experiment, not for production") | durable tasks: steps, sleeps, events | polls every 0.25 s when idle (`startWorker` `pollInterval = 0.25`) | 149 + 240 ms | 38 + 36 MB |
| DBOS Transact TS 5.0.2 (MIT; Conductor proprietary) | durable workflows: steps, sleep, send/recv | polls Postgres | 744 + 122 ms (round 1) | 90 + 58 MB |
| pgflow (Apache-2.0) | DAG flows on pgmq + Supabase Edge Functions | pgmq `read_with_poll` (long poll in the database) | not measured (needs Supabase functions) | |
| Hatchet (MIT) | Go engine + Postgres, workers over gRPC | engine process | not measured (heavier: separate engine) | |

None of these is fully event-driven: each keeps at least a timer for future work. graphile-worker with a long `pollInterval` comes closest (LISTEN/NOTIFY for new jobs, 23 ms per minute in total) but delays scheduled jobs by up to the interval. Only DBOS and Absurd give Workflows-style step replay, and both poll.

### 1.6 Other self-host engines (round 1, docs)

trigger.dev v4 (Apache-2.0): official minimums 3+ vCPU / 6+ GB for the webapp machine and 4+ vCPU / 8+ GB for the worker machine, ten services (https://trigger.dev/docs/self-hosting/docker.md). Temporal (MIT): four server roles plus a SQL or Cassandra store in production. Inngest: SSPL with an Apache future license; default in-memory Redis with periodic SQLite snapshots. Restate: BSL 1.1 whose use grant forbids a public platform where third parties register deployments through Restate's APIs. Vercel Workflow SDK (Apache-2.0): worlds `local`, `postgres`, `vercel`; a different directive-based API.

### 1.7 code.storage (round 1, verified)

Dev org: repo create 363 ms, commit 205 ms, file read at an exact commit 89 ms, stale `expectedHeadSha` rejected. Ref policies, ephemeral namespace, push webhooks, git notes, commit signing (https://code.storage/docs/llms.txt).

## 2. Comparison

| Option | Same chief code as the other tier | Idle footprint | Durable state | License | Sleeps, waits, cron | Tenant isolation | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- |
| CF Dynamic Workers + Workflows in our API Worker | native | none (serverless) | Workflows engine, DO facets | service | yes; cron in SchedulerDO | isolate per tenant, no network unless granted | **Tier 1** |
| CF WfP | no Workflows (verified) | none | DOs, alarms | service, $25/mo | no Workflows, no cron, no consumers (verified) | isolate per script | later, user HTTP apps only |
| workerd harness on a VM (wrangler-hosted today) | native (verified on Freestyle) | 0.85 to 1.1 CPU s/min, 330 to 460 MB (dev toolchain); workerd alone under 0.1 CPU s/min, 200 MB | local engine SQLite; timers need the wake shim (verified) | Apache-2.0 | yes after the shim | isolates; the VM is the boundary | **Tier 2 now** |
| Rust Workflows-compatible engine + workerd executor | native (planned) | target 0 CPU idle, workerd 200 MB | SQLite in the daemon | ours | ours | same | **Tier 2 target** |
| DBOS + Postgres | no | 866 ms CPU/min, 150 MB | Postgres | MIT / proprietary Conductor | yes | none | not for automations |
| trigger.dev / Temporal / Inngest / Restate | no | heavy / heavy / one binary / one binary | various | Apache / MIT / SSPL / BSL | yes | none | rejected |

## 3. Strongest expert objection per option

- **Tier 1 on Dynamic Workers.** "New library (0.1.1), 4 distinct Dynamic Workers in flight per request, and changed code under a running instance breaks replay." Answer: one tenant Worker per run; every instance pins its commit in metadata and the loader id includes the commit; the library is small enough to vendor.
- **WfP.** "It is Cloudflare's documented multi-tenant product." Answer: verified today it cannot run Workflows, cron or queue consumers for user Workers, and its usage analytics did not attribute our tenant.
- **workerd on the VM.** "The local Workflows engine is an emulation, and you just proved it drops timers on restart." Answer: correct, which is why Tier 2 ships with the wake shim now and replaces the engine with our own Rust engine; workerd stays as the step executor, where it is near-idle.
- **Rust engine.** "You are writing a workflow engine." Answer: the scope is the Workflows step protocol only (journal of step results keyed by instance and step name, timers on one-shot wakeups, event delivery, retries with backoff), stored in SQLite in the daemon that already owns durable state, with conformance tests run against Cloudflare's engine. It removes Node and esbuild from the VM (about 0.9 CPU s/min and 250 MB) and the restart bug class.
- **DBOS / Postgres queues on the VM.** "Postgres is already there for apps; use it." Answer: a second authoring API, and every library measured keeps a poll timer (graphile-worker with a 60 s interval is closest and delays scheduled work by up to 60 s).

## 4. Recommendation: two tiers, one authoring API

### 4.1 Authoring API (decided, R2)

chief writes Cloudflare Workflows code plus `env.cmux` generated from the operation catalog (`op`, `model` through CodeRouter, `mux.send`, `machine.run`, `state`, `log`, `metric`). `fetch` goes through the egress gateway; secrets never reach the code; step names starting `cmux:` are reserved. Example in round 1 (unchanged).

### 4.2 Tier 1: cmux cloud (default)

Inside the API Worker of #16762, no WfP: SchedulerDO fires; `AutomationRunWorkflow` (run id = instance id) loads the tenant module through `LOADER` at the pinned commit and calls `run(event, wrappedStep)`; the wrapped step counts steps, checks budget and quota, prefixes harness steps and reports progress. Capabilities are `WorkerEntrypoint` stubs whose props carry run-token claims; `globalOutbound` is the egress gateway; `tails` feed logs and metering; `limits` come from the plan.

### 4.3 Tier 2: self-host (team VM or own machine)

- Now: the `automations-host` role in the `cmux` binary supervises the pinned harness (wrangler 4.137.0 + workerd 1.20260921.1, as verified) with the wake shim, state on local disk. Cloud-connected hosts are scheduled by SchedulerDO through the link (`target {kind: host}`); SchedulerDO also re-sends wake to open runs after a host reconnects, a second guard besides `ExecStartPost`. Offline machines use a local scheduler over the same schema.
- Target: a Workflows-compatible engine in the Rust daemon (SQLite journal, one-shot timers, events, retries), with workerd run directly (`workerd serve`, no Node) as the step executor. Conformance suite: the same tenant programs run against Cloudflare and the Rust engine, comparing step journals.
- In-flight run state is on local disk, not the zero-loss tier; a lost VM turns runs `dead` at their deadline and they retry by dedupe key.
- Team VM image: `cmux`, pinned workerd (and the wrangler harness until the Rust engine lands), `coderouter` client with edge-injected credentials, Postgres 16 for apps (Section 5).

### 4.4 Code in code.storage (R5 decided)

One repo per team: `automations/<slug>/{automation.json, index.ts, test.ts}`, `apps/<app>/…`, `lib/`, generated `cmux.d.ts`. chief's tokens are limited to `chief/*` and the ephemeral namespace by ref policy; `automation.deploy {slug, commit}` activates a commit and bumps the version; every run pins `code_ref`; deploy records in git notes. Bundling location is open (backend esbuild-wasm vs CLI-built `dist/`).

### 4.5 Billing (R4 decided: plans with included quotas plus metered overage)

- Meters, one ledger row per run (harness), rolled to PlanetScale through the outbox: `automation.steps`, `automation.cpu_ms` (tail `cpuTime`, ours, tenant-tagged), `automation.invocations`, `automation.state_gb_month` (instance retention 7 days), `automation.dynamic_workers_per_day`, `egress.requests`, `model.spend_usd` (CodeRouter ledger), `vm.minutes` (Freestyle, team VM and remote steps), `postgres.storage_gb` (team VM, for apps).
- Plans include a quota per meter (for example runs, steps and CPU per month); usage above quota is billed per unit at a price above Cloudflare's cost (Cloudflare: steps $0.80 per 100,000, CPU $0.02 per million ms). Stripe meters per customer with the existing subscription; the ledger is the source of truth and Stripe receives aggregated meter events hourly with idempotency keys.
- Budgets and hard caps per team stop a run at a step boundary into `waiting` with a notification (spec rule); quota exhaustion on plans without overage does the same.
- Tier 2 on Freestyle bills `vm.minutes` and `model.spend_usd`; own machine bills model spend only.

## 5. Default Postgres on the team VM (new, a)

- One Postgres 16 cluster per team VM, data on local disk (Postgres on a FUSE object-store filesystem means each `fsync` waits on R2; not attempted).
- chief creates apps through ops, never raw `createdb`: `team_vm.db.create {app}` makes the Linux user `app-<app>`, role and database exactly as verified in 1.4, and returns a Unix-socket URL (`postgresql:///app_<app>?host=/var/run/postgresql`). `team_vm.db.list`, `team_vm.db.drop {app}` (destructive policy at the owner: snapshot first, approval), `team_vm.db.limits.set`.
- Limits: connection limit, statement and idle-in-transaction timeouts, `temp_file_limit` per role; database size is not enforceable in Postgres, so the team-host role reports `pg_database_size` per app as a metric and alerts at 80% of the plan's storage, and `team_vm.db.limits` can make an app read-only (`ALTER DATABASE … SET default_transaction_read_only = on`) when it exceeds the hard cap.
- Backups: continuous WAL archiving to the team's R2 prefix (WAL-G or pgBackRest, S3 API), `archive_timeout` 60 s, nightly base backup, point-in-time restore. This is not zero-loss (up to 60 s of commits), unlike JuiceFS for files; Freestyle snapshots are the second line. For an app that needs zero loss, synchronous commit to a managed database (PlanetScale Postgres per team) is the upgrade path. Decision in Section 8.
- Agents never get superuser; humans' break-glass follows team-vm.md.

## 6. Observability chief sets up by default (new, c)

Every automation and app gets the same four things without chief writing them, on both tiers.

- **Structured logs.** `console.*` and `env.cmux.log(level, msg, attrs)` become JSON records `{ts, team, app|automation, version, commit, run, step, attempt, level, msg, attrs, trace_id, span_id}`. Tier 1: the tail of each Dynamic Worker (and Workers Logs on the loader) ships records to the team log store; Tier 2: the harness tail writes them to a local SQLite ring buffer and forwards them over the link when connected.
- **Traces.** One trace per run: a root span for the run, a span per `step.do` attempt (name, attempt, retries, duration, error), child spans for capability calls (`op`, `model`, `machine.run`) and egress requests. Apps on the team VM get OpenTelemetry Node auto-instrumentation preconfigured by `team_vm.app.deploy` with an OTLP endpoint on the team-host role, which forwards to the same store. Propagation uses W3C `traceparent` on egress and capability calls.
- **Run timeline.** The run page and `cmux automations runs show <run> --json` merge the Workflow step journal (Cloudflare instance status API on Tier 1, the local engine on Tier 2) with our `run.report` events, logs and spans: sleeps and waits are visible as gaps with their wake time, retries as repeated attempts with errors, and the code commit links to code.storage.
- **Alerts and error handling.** Default rules per automation (editable in `automation.json`): notify the owner on `failed` or `dead`; escalate after 3 consecutive failures; notify at 80% of budget or quota; notify when a step retries more than 5 times. Default step policy that the wrapped step applies unless the code overrides it: 3 retries with exponential backoff for unknown errors, no retry for `NonRetryableError` and for capability errors marked permanent (`grant.denied`, `budget.exceeded`), and `mutation.indeterminate` from integrations surfaces as a waiting step for a human. Apps get an uncaught-exception and 5xx-rate alert. Notifications go through the notification owner (spec), so they reach cmux clients and mobile.
- **Store.** Proposal: one team telemetry store in ClickHouse (we already run ClickHouse Cloud for the CodeRouter ledger) with per-team row policies, 14-day log and trace retention, run-scoped queries for chief (`telemetry.query` op with a fixed schema, never raw SQL from apps). Alternatives in Section 8.

## 7. Fit with #16762

Keep: SchedulerDO, ConnectionDO and the external-effect ledger, the Run shape, op names, the projection, `AutomationRunWorkflow` as the only Workflow class. Adapt: body `{type: code, ref}`; wrapped step; `worker_loaders`, `CmuxCaps`, `AutomationEgress`, `AutomationTail`, `AutomationStateDO` (migration v4); per-run tokens; a `host.wake_runs` message to hosts on reconnect. Replace: nothing. Do not use WfP.

## 8. Decisions for Lawrence (coordinator relays)

- **R1. Tier 1 runtime.** Rec: Dynamic Workers + Dynamic Workflows in our API Worker. Evidence: WfP user Workers cannot run Workflows, cron or queue consumers, and their analytics did not attribute usage (1.1). WfP stays a later option for user HTTP apps; cancel the subscription if no such need appears.
- **R3. Tier 2 engine.** Rec: ship the pinned workerd harness with the wake shim now (verified on Freestyle), and build the Rust Workflows-compatible engine with workerd as executor as the target (removes the emulated engine's restart bug and about 0.9 CPU s/min of Node and esbuild idle). Alternatives: keep the wrangler harness indefinitely; DBOS on Postgres (second API, polls).
- **R7. Team VM app database.** Rec: Postgres 16 on the VM with per-app roles via peer auth, WAL archiving to R2 (up to 60 s loss), managed PlanetScale Postgres as the zero-loss upgrade per app. Alternatives: SQLite per app on the JuiceFS zero-loss tier (zero loss, slower commits, no extra service); managed Postgres for every team from day one (zero loss, cost per team).
- **R8. Telemetry store.** Rec: our ClickHouse with per-team row policies. Alternatives: Workers Logs + Analytics Engine on Tier 1 only (no Tier 2 story); a third party such as Axiom (per-GB cost, data leaves our stack).
- **R9. Job queue for apps on the team VM.** Rec: apps use the same automations runtime (`env.cmux` and Workflows API) for background work; graphile-worker with a long poll interval is the documented option for apps that want a Postgres queue. Alternative: preinstall pg-boss.

## 9. UNVERIFIED

- WfP: whether usage attribution fills in later than 30 minutes, why CPU sums exceed the 50 ms custom limit, and whether Workflows or cron for user Workers exist behind an enterprise flag.
- Soak results for 1 h, 3 h, 6 h and 24 h sleeps (running; due times in 1.3).
- A workerd upgrade with in-flight instances; running the harness with plain `workerd serve` (no wrangler); Dynamic Workflow resume after eviction during a long sleep on Cloudflare.
- Freestyle restarting a VM after a guest `poweroff` (observed) against the SDK comment.
- pgflow and Hatchet idle cost; WAL-G to R2 restore time; OpenTelemetry auto-instrumentation overhead on the team VM; esbuild-wasm in a Worker.

## 10. Next steps

1. Record the soak results (1.3) and delete the VM if the TTL has not.
2. #16762 follow-up PR: `code` body, wrapped step, capabilities, egress, tail metering, `AutomationStateDO`, `host.wake_runs`.
3. Rust engine spike: journal schema, timers, events, conformance tests against Cloudflare.
4. Team VM image: `cmux`, workerd, coderouter client, Postgres 16 with the `team_vm.db.*` ops.
5. Telemetry: log record schema, trace spans, ClickHouse tables, default alert rules.

## Appendix: proposed spec text (for spec/cloud-and-automations.md "Runtime tiers"; round 2 replaces round 1)

> ## Runtime tiers (proposed 2026-10-02, plans/cmux-next/automations-runtime.md)
>
> - Authoring API (decided): Cloudflare Workflows code (`WorkflowEntrypoint.run(event, step)`, `step.do/sleep/sleepUntil/waitForEvent`) plus `env.cmux` generated from the operation catalog (`op`, `model`, `mux.send`, `machine.run`, `state`, `log`, `metric`). `fetch` goes through an egress gateway; secrets never reach the code. Step names starting `cmux:` are reserved.
> - Code (decided): one code.storage repo per team; `automations/<slug>/{automation.json, index.ts, test.ts}`; chief pushes only to `chief/*`; `automation.deploy {slug, commit}` activates a commit. Every run pins `code_ref {repo, commit, path, export}`. Body type added: `{type: code, ref}`.
> - Tier 1 (cloud, default): Dynamic Workers (Worker Loader) inside the single `AutomationRunWorkflow`; capabilities are `WorkerEntrypoint` stubs with run-token claims; tenant `DurableObject` classes run as facets of a per-team `AutomationStateDO`; tails provide logs and tenant-tagged CPU. Workers for Platforms is not used: verified 2026-10-02 that its user Workers cannot run Workflows, cron or queue consumers and that its analytics did not attribute usage per script.
> - Tier 2 (self-host): the `automations-host` role of the `cmux` binary runs the same harness on the team VM or the user's machine. Now: pinned workerd under wrangler with a wake-on-start shim (the local engine does not re-arm sleeps after a restart; verified on Freestyle, fixed by the shim). Target: a Workflows-compatible engine in the Rust daemon with workerd as step executor. SchedulerDO schedules cloud-connected hosts through the link and re-wakes open runs on reconnect; offline machines use a local scheduler over the same schema.
> - Team VM image: `cmux`, pinned workerd, `coderouter` client with edge-injected credentials, Postgres 16 for apps (per-app role and database, peer auth from `app-<app>` Linux users, WAL archiving to R2).
> - Observability by default: structured JSON logs with run, step and trace ids; one trace per run with a span per step attempt and capability call; a run timeline merging the step journal, reports, logs and spans; default alerts (failure, 3 consecutive failures, 80% budget or quota, retry storms); one team telemetry store.
> - Billing (decided): plans with included quotas plus metered overage on steps, CPU ms, invocations, state, egress, model spend, VM minutes and app database storage; budgets and caps pause a run at a step boundary.
> - Rejected: Workers for Platforms for automations, trigger.dev, DBOS, Inngest, Restate, Temporal.
> - Open: R1 confirm, R3, R7, R8, R9.
