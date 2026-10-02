# cmux next: automations runtime (where chief-written automation code runs)

Status: research and proposal, 2026-10-02 (automations runtime researcher). Spec owner: the coordinator (spec/cloud-and-automations.md, section "Runtime tiers" proposed below; only the coordinator edits the spec repo). Related: PR https://github.com/manaflow-ai/cmux/pull/16762 (SchedulerDO + Workflows + integrations), spec/team-vm.md, decisions N1 (chief, working name) and C1 (code.storage).

Lawrence asked for a featureful Cloudflare tier and a minimal self-host tier (team "softwares" VM on Freestyle, or the user's own machine), with a default setup that a coding agent can do from one prompt, and coderouter on the team VM. This document answers which runtime, with one authoring API for both tiers.

## 1. Findings

Verified means run by this lane on 2026-10-02; the rest cites primary docs.

### 1.1 Cloudflare

- **Workers for Platforms (WfP).** The bindings page lists Durable Objects, Workflows, Queues, Containers, KV, R2, D1, Hyperdrive, VPC and Analytics Engine for user Workers (https://developers.cloudflare.com/cloudflare-for-platforms/workers-for-platforms/configuration/bindings/, updated 2026-09-16). The Workflows limits page says the opposite: "Workflows cannot be deployed to Workers for Platforms namespaces, as Workflows do not support Workers for Platforms" (https://developers.cloudflare.com/workflows/reference/limits/). UNVERIFIED which is current: our account 0c1675e0 has no WfP subscription (`[10121] You do not have access to dispatch namespaces`), so no dispatch namespace could be created. Other facts: $25/month, 20M requests and 60M CPU ms included, 1,000 scripts then $0.02 per script, unlimited DO namespaces, `caches.default` disabled, no gradual deployments, 8 tags per script, custom limits (`cpuMs`, `subRequests`) set by the dispatch Worker, outbound Workers for egress, per-script usage from GraphQL `workersInvocationsAdaptive` filtered by `scriptName` (requests, errors, CPU quantiles) (pricing, limits, observability pages under the same docs tree).
- **Dynamic Workers (Worker Loader) plus Dynamic Workflows plus Durable Object Facets.** Cloudflare's purpose-built path for per-tenant code: one loader Worker loads tenant code at runtime (`env.LOADER.get(id, () => ({modules, env, globalOutbound, tails, limits}))`), one Workflow class serves every tenant (`@cloudflare/dynamic-workflows`, MIT, about 150 lines: tags each instance with metadata and reloads the tenant's code on every resume), and a supervisor DO runs a tenant `DurableObject` class as a facet with its own SQLite (https://developers.cloudflare.com/dynamic-workers/). Available on Workers Paid, which we have. Pricing: 1,000 unique Dynamic Workers per month included, then $0.002 per Dynamic Worker per day (unique = id plus code); requests and CPU at Workers Standard rates, startup CPU billed. Limits: 4 distinct Dynamic Workers in flight per request, 10 per DO. Capabilities are `WorkerEntrypoint` stubs with `props` the tenant cannot read; `globalOutbound` blocks or intercepts every `fetch`/`connect`; `tails` deliver logs and per-invocation `cpuTime`/`wallTime`.
- **Verified prototype** (Worker `cmuxnp-dev-dynwf-exp1791192478` on account 0c1675e0, deleted after; source kept at `/tmp/cmuxnp-dynwf`): one loader Worker with `LOADER`, one `DynamicWorkflow` class, a `TenantSupervisor` DO with a facet, a `CmuxCaps` capability entrypoint, an `Egress` gateway and a `MeterTail`. The platform (not tenant code) created instances with caller-chosen ids and the tenant metadata pinned to `{tenant, version}`. Results: `step.do`, `step.sleep("3 seconds")` and `waitForEvent("approval")` ran tenant code on real Workflows; a duplicate id returned `(instance.already_exists)`; the facet kept per-tenant SQLite state (tenant t2 counted 1, 2 independently of t1); the egress allowlist served example.com and refused other hosts; the tail reported 2 ms CPU and 48.6 s wall for the run invocation, so per-run CPU metering works without WfP analytics. Create to first step: 0.3 s to 3.3 s (three samples).
- **Workflows limits and price** (https://developers.cloudflare.com/workflows/reference/limits/, /pricing/): sleep up to 365 days; 10,000 steps per instance (configurable to 25,000); 1 MiB per step result and event payload; 1 GB state per instance; 30-day retention (settable per instance); 50,000 concurrent instances per account, and sleeping or waiting instances do not count; instance id up to 100 characters; 300 creations per second per account. Steps and storage are billed since 2026-08-10: 500,000 steps included then $0.80 per 100,000; 1 GB-month then $0.20 per GB-month. Workflow `schedules` (cron) are capped at 100 per account, so per-team cron stays in SchedulerDO (#16762 already does this).

### 1.2 Self-host candidates

| | Verified result or official numbers |
| --- | --- |
| workerd running the identical prototype (`wrangler dev --persist-to`) | Verified locally and in a Linux container: same tenant code, Worker Loader, facets and Workflows ran unchanged; killing the process during `waitForEvent` and restarting resumed the instance and completed it. Idle: workerd about 110 MB RSS (a second helper workerd 57 MB); the whole `wrangler dev` stack 412 MB and 0.41 CPU s per idle minute. Docs call the local engine "an emulated version of Workflows" (https://developers.cloudflare.com/workflows/build/local-development/); workerd is Apache-2.0, "not a hardened sandbox", and documents systemd production serving (https://github.com/cloudflare/workerd). Workers Cron is not emulated as a scheduler (local `__scheduled` test hook only). |
| DBOS Transact TS 5.0.2 + Postgres 17 | Verified in containers: start, step, sleep, `recv` wait, `send`, SUCCESS. Idle: DBOS process 0.74 CPU s per minute (about 1.2% of a core, it polls Postgres) and 90 MB; Postgres 0.12 CPU s per minute and 58 MB. TS needs Postgres (Python also accepts SQLite). Transact is MIT; Conductor (recovery across executors, UI) is proprietary, free self-host license allows one executor per app (https://docs.dbos.dev/conductor/self-hosting/hosting-conductor.md, /faq.md). |
| trigger.dev v4 | Apache-2.0. Official minimums: webapp machine 3+ vCPU and 6+ GB, worker machine 4+ vCPU and 8+ GB; compose runs webapp, Postgres, Redis, Electric, ClickHouse, registry, MinIO, S2, supervisor and a Docker socket proxy (https://trigger.dev/docs/self-hosting/docker.md, repo hosting/docker). Not measured: it does not fit a small team VM. |
| Temporal | MIT. `temporal server start-dev` is a single SQLite binary for development; production is four server roles plus Postgres, MySQL or Cassandra. Activity/worker model, not step closures. Not measured. |
| Inngest | SSPL with an Apache-2.0 future license. `inngest start` is one binary; default persistence is an in-memory Redis with periodic SQLite snapshots (https://www.inngest.com/docs/self-hosting.md), so a crash can lose acknowledged state unless external Redis and Postgres are configured. Not measured. |
| Restate | BSL 1.1; the additional use grant forbids a "Public Restate Platform Service" where third parties register deployments through Restate's APIs, which a hosted cmux tier could become. Single binary. Not measured. |
| Hatchet | MIT, Postgres-backed. Not measured. |
| Postgres queues (pg-boss, graphile-worker) | Job queues, not durable step replay; a workflow engine on top would be ours to write. |
| Vercel Workflow SDK | Apache-2.0; worlds `local`, `postgres`, `vercel`, plus community worlds; no Cloudflare world listed (https://useworkflow.dev). Directive-and-compiler API (`"use workflow"`), different from the Cloudflare API. |

### 1.3 code.storage (decision C1)

Verified with the dev org key (`~/.secrets/pierre-code-storage.pem`, org from `~/.secrets/chatmux.env`): created repo `cmuxnp-dev-automations-exp1791192478` in 363 ms, committed an automation in 205 ms, read the file at the first commit SHA after a second commit in 89 ms (pinned content intact), and `expectedHeadSha` rejected a stale write. Repo deleted after. Useful features: ref policies in the JWT (limit which refs a token may update), ephemeral namespace (previews), push webhooks (HMAC), git notes, commit signing, `getFileStream({ref: sha})` (https://code.storage/docs/llms.txt).

## 2. Comparison

| Option | Runs the same chief code as the other tier | Idle footprint | Durable state | License | Sleeps, waits, cron | Tenant isolation | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- |
| CF Dynamic Workers + Workflows in our API Worker | native | none (serverless) | Workflows engine, DO facets | proprietary service | 365 d sleep, waitForEvent; cron in SchedulerDO | V8 isolate per tenant, no network unless granted, props-hidden capabilities | **Tier 1** |
| CF Workers for Platforms | native, if Workflows are supported (docs conflict) | none | same | proprietary, +$25/mo | same | isolate per script, untrusted mode | later, only for user-facing HTTP apps |
| workerd on the team VM or own machine | native (verified) | about 110 MB, near-zero CPU for workerd itself (stack measured 0.41 CPU s/min) | local SQLite under workerd | Apache-2.0 | same API; cron from our scheduler | isolates, not a hardened sandbox (VM is the boundary) | **Tier 2** |
| DBOS + Postgres | no (different API) | 150 MB, 0.86 CPU s/min with Postgres | Postgres | MIT; Conductor proprietary | sleep, recv, cron | none in-process | fallback for Python-only users |
| trigger.dev v4 | no | 7+ vCPU, 14+ GB official | Postgres, Redis, ClickHouse, object store | Apache-2.0 | yes | container per run | rejected for the team VM |
| Temporal | no | server + DB, not measured | Postgres/MySQL/Cassandra | MIT | yes | none | rejected (weight, model) |
| Inngest | no | one binary | in-memory Redis + SQLite snapshots by default | SSPL | yes | none | rejected (license, default durability) |
| Restate | no | one binary | embedded | BSL with platform clause | yes | none | rejected (license) |
| Hatchet / pg queues / Vercel WDK | no | Postgres-based | Postgres | MIT / various / Apache | partial | none | not needed |

## 3. Strongest expert objection per option

- **Tier 1 on Dynamic Workers.** "Dynamic Workers and `@cloudflare/dynamic-workflows` are new (library 0.1.1, April 2026), the concurrency limit is 4 distinct Dynamic Workers per request, and a code change under a running instance breaks deterministic replay." Answer: the run calls exactly one tenant Worker, so the limit is not reached; every instance pins its commit SHA in metadata and the loader id includes the SHA, so resumes reload the same code; the library is small enough to vendor into `backend/` if it stalls.
- **WfP.** "It is the documented multi-tenant product, with per-script analytics and untrusted mode." Answer: the docs disagree on Workflows support, it adds a subscription and a deploy step per tenant script, and tails already give per-run CPU. Keep it for a later need: user apps that serve their own HTTP hostnames.
- **workerd for Tier 2.** "Cloudflare calls the local Workflows engine an emulation for development; nobody guarantees its persistence format across versions." Answer: pin the workerd and wrangler versions in the team VM image, run a soak test (Section 9), and keep the replacement ready: a Workflows-compatible engine in the Rust daemon (SQLite journal of step results, timers, events) with workerd only executing steps. That engine is small and matches "move into Rust, no polling".
- **DBOS.** "Library-only, Postgres you already know, MIT; preinstall it and stop." Answer: a second authoring API means chief writes two dialects and tests two runtimes; it polls (1.2% of a core idle, against our 0% idle rule); TS needs Postgres on a small VM; multi-executor recovery needs the proprietary Conductor.
- **trigger.dev.** "Best developer experience and dashboard." Answer: official minimums are 7 vCPU and 14 GB across two machines and ten services; the team VM is small and long-lived (team-vm.md non-goals).
- **Temporal / Inngest / Restate.** Weight and a different model / SSPL and lossy defaults / BSL clause that forbids exactly a hosted multi-tenant registration API.

## 4. Recommendation: two tiers, one authoring API

### 4.1 The authoring API

chief writes plain Cloudflare Workflows code plus one capability binding:

```ts
// automations/daily-digest/index.ts (in the team's code.storage repo)
import { WorkflowEntrypoint } from "cloudflare:workers"
export class Automation extends WorkflowEntrypoint<CmuxEnv, TriggerPayload> {
  async run(event, step) {
    const issues = await step.do("fetch issues", () => this.env.cmux.op("linear.issue.list", { team: "web", state: "open" }))
    const summary = await step.do("summarize", () => this.env.cmux.model({ prompt: `Summarize: ${JSON.stringify(issues)}` }))
    await step.sleep("wait for morning", "2 hours")
    const ok = await step.waitForEvent("approve", { type: "approval", timeout: "1 day" })
    await step.do("post", () => this.env.cmux.op("slack.post_as_bot", { channel: "#web", text: summary }))
  }
}
```

- `step.do / sleep / sleepUntil / waitForEvent` are Cloudflare's API unchanged. LLMs already know it, Tier 1 runs it natively, workerd runs it unchanged (verified).
- `env.cmux` is generated from the operation catalog (D7): `op(name, params)` (catalog ops the automation's grant allows, integration ops through the external-effect ledger), `model(...)` (CodeRouter), `mux.send(...)` (message chief), `machine.run(...)` (a remote step through the link with a durable exit receipt), `state` (a facet-backed key value and SQL store). Types ship as `cmux.d.ts` pinned to the catalog version.
- Optional `export class State extends DurableObject` for richer state; Tier 1 runs it as a facet, Tier 2 as a local DO.
- `fetch` goes through the egress gateway (per-automation allowlist; credentials injected by the integration gateway, D39, never visible to the code).
- Reserved: step names starting `cmux:` (the harness uses them for progress reports).

### 4.2 Tier 1: cmux cloud (default)

Inside the existing API Worker of #16762, no WfP: SchedulerDO fires (cron, webhook, integration event, manual, continue) with the existing dedupe keys, deadlines and backoff; `AutomationRunWorkflow` starts with the run id as instance id; for a `code` body it loads the tenant module through `LOADER` at the pinned commit (`id = <team>:<commit>:<path>`), and calls `run(event, wrappedStep)`. The wrapped step counts steps, checks the budget before each step, prefixes harness steps, and reports progress to SchedulerDO. Capabilities are `WorkerEntrypoint` stubs whose `props` carry the run token claims (run, automation version, op set, expiry; identity-and-permissions.md). `globalOutbound` is the egress gateway; `tails` meter CPU; `limits: {cpuMs, subRequests}` from the plan.

### 4.3 Tier 2: self-host (team VM on Freestyle, or own machine)

- The `cmux` binary gains an `automations-host` role that supervises a pinned `workerd` running the same harness module as Tier 1 (one TypeScript source, two entry configs), with workerd state on local disk.
- Placement: on a cloud-connected team VM, SchedulerDO stays the scheduler and dispatches the run to the VM through the link (`target: {kind: host, host: <team VM>}`); the VM reports back with the same `run.report` keys. On an offline own machine, the daemon runs a local scheduler over the same Automation schema (cron, local webhooks).
- Durability: in-flight run state lives on the VM disk, not the zero-loss tier (SQLite on JuiceFS is not proven), plus Freestyle snapshots. Losing the VM loses in-flight runs, which SchedulerDO marks `dead` at their deadline and retries by dedupe key. Code lives in code.storage, so nothing else is lost.
- coderouter: the team VM image preinstalls the `coderouter` client and the `cmux` binary; model calls use edge-injected credentials (the `vmModelPlane.ts` pattern), never a token in the guest. `env.cmux.model` on an own machine uses the user's CodeRouter login. Open risk from cloud-and-automations.md: Freestyle edge rules may be create-time only.
- Image contents: `cmux` (with automations-host), pinned `workerd`, `coderouter` client, Node for `cmux automations test`. Nothing else (no Postgres, no Redis).

### 4.4 Code in code.storage

- One repo per team (`team-<team id>`; a personal account is a team of one): `automations/<slug>/automation.json` (triggers, target, budget, concurrency: the Automation shape minus body), `automations/<slug>/index.ts`, `automations/<slug>/test.ts`, `lib/`, generated `cmux.d.ts`.
- chief's tokens carry a ref policy limited to `chief/*` and the ephemeral namespace; `main` changes only through `automation.deploy {slug, commit}`, which validates, bundles to a module map, and bumps the automation version bound to that commit. Humans may push to `main` directly; the push webhook then proposes the deploy (no silent activation).
- Every run stores `code_ref {repo, commit, path, export}`; deploy records go to git notes (`refs/notes/cmux-deploys`) for audit.
- Bundling location is open (backend esbuild-wasm vs the CLI bundling and committing `dist/`); UNVERIFIED that esbuild-wasm fits a Worker.

### 4.5 Billing metering

- Tier 1 per run, recorded by the harness and rolled to PlanetScale through the outbox: steps (our counter; Cloudflare bills $0.80 per 100,000), CPU ms (tail `cpuTime`; $0.02 per million), invocations, state bytes (retention set to 7 days per instance), unique Dynamic Workers per day (one per team and commit; $0.002), egress requests, model spend (CodeRouter ledger), VM minutes for remote steps.
- Scale check: a daily 10-step automation with 50 ms CPU costs Cloudflare far under a cent per month. Model spend and VMs dominate.
- Proposal: plans include automation quotas (runs, steps, CPU); bill model spend and VM minutes as today; budgets stop a run at a step boundary into `waiting` (spec rule, no silent kill).
- Tier 2: no Cloudflare cost; meter Freestyle minutes for the team VM; own machine is free.

## 5. Fit with #16762

- Keep: SchedulerDO (triggers, cron, dedupe keys, deadlines, persisted backoff, webhooks), ConnectionDO and the external-effect ledger, the Run shape, op names, the projection, `AutomationRunWorkflow` as the only Workflow class per environment.
- Adapt: add body `{type: "code", ref: {repo, path, commit, export}}`; in `AutomationRunWorkflow`, load and run the tenant module with the wrapped step (do not import the library's entrypoint; inline its tag-and-reload logic so our run keeps its reports); add `worker_loaders`, exported `CmuxCaps`, `AutomationEgress`, `AutomationTail`, and an `AutomationStateDO` supervisor (migration v4); per-run tokens.
- Replace: nothing. Do not add WfP.

## 6. Default setup prompt and skill

User prompt to their coding agent: "Set up cmux automations for my team and make a daily digest of open Linear issues posted to #web." The `cmux-automations` skill (shipped with the CLI, vendor/cmux-skills) tells the agent:

1. `cmux automations init --json` (links or creates the team code.storage repo, writes `cmux.d.ts` and one example; tier `cloud` unless `--host team-vm` or `--host this-machine`).
2. Write `automations/<slug>/automation.json`, `index.ts` and `test.ts` against `cmux.d.ts`.
3. `cmux automations test <slug> --json` (runs in the local workerd harness with recorded capability calls and fake triggers; fails on type errors and missing grants).
4. `cmux automations deploy <slug> --wait --json` (commit on `chief/<slug>`, `automation.deploy`; an approval request if the grant grows, D48 pattern).
5. `cmux automations run <slug> --wait --json` (one manual run; prints the run row and `next_run_at`).
6. For self-host: `cmux automations host install` on the team VM (preinstalled) or this machine.

Every step is a catalog op with CLI, MCP and chief tool surfaces (cmux-next-feature rules): `automation.init`, `automation.test`, `automation.deploy`, `automation.code.get`, `automation.host.install`, plus the existing ops.

## 7. Decisions for Lawrence (coordinator relays)

- **R1. Tier 1 runtime.** Rec: Dynamic Workers + Dynamic Workflows + DO facets inside our API Worker. Alternatives: WfP dispatch namespace ($25/month, Workflows support contradicted in docs); WfP later only for user apps with HTTP hostnames.
- **R2. Authoring API.** Rec: the Cloudflare Workflows API plus `env.cmux` generated from the catalog. Alternatives: our own neutral `defineAutomation` API compiled to both tiers (more work, no native tooling); DBOS API (different on Cloudflare).
- **R3. Tier 2 engine.** Rec: pinned workerd with the same harness, soak test, Rust daemon engine as the planned replacement if the soak fails. Alternatives: DBOS + Postgres preinstalled (second API, polls); trigger.dev (too heavy).
- **R4. Pricing.** Rec: automation compute included in plans with quotas; meter model spend and VM minutes. Alternative: pass-through metering of steps and CPU.
- **R5. Code layout.** Rec: one code.storage repo per team with `automations/<slug>/`. Alternative: one repo per automation.
- **R6. WfP subscription to settle the docs conflict.** Rec: not now ($25/month, no Tier 1 dependency).

## 8. UNVERIFIED

- Workflows support in WfP dispatch namespaces (docs conflict; no subscription).
- workerd's local Workflows engine under long sleeps (days), upgrades of workerd with in-flight instances, and running it from a plain `workerd serve` config without wrangler or Miniflare's Node process (Miniflare as a library still needs Node, about 150 to 200 MB total).
- Hibernation and resume of a Dynamic Workflow after the isolate is evicted during a long sleep (the prototype's waits were seconds).
- Tail `cpuTime` precision for billing (2 ms reported for the test run; compare with Cloudflare's invoice data).
- esbuild-wasm bundling inside a Worker; Freestyle edge rules being reconfigurable after create; Hatchet, Temporal and Restate footprints (not measured).

## 9. Next steps

1. Soak: the prototype on the team VM image under workerd for 7 days with sleeps of 1 h and 1 d, a workerd upgrade mid-run, and a VM pause/resume.
2. #16762 follow-up PR: `code` body, wrapped step, capabilities, egress, tail metering, `AutomationStateDO`.
3. `cmux automations` CLI/MCP ops and the skill; `cmux.d.ts` generator from the catalog.
4. Team VM image: `cmux`, pinned workerd, coderouter client.

## Appendix: proposed spec section "Runtime tiers" (for spec/cloud-and-automations.md)

Sent to the coordinator as "spec proposal: automations runtime" on 2026-10-02.

> ## Runtime tiers (proposed 2026-10-02, plans/cmux-next/automations-runtime.md)
>
> - Authoring API: chief writes automations as Cloudflare Workflows code (`WorkflowEntrypoint.run(event, step)`, `step.do/sleep/sleepUntil/waitForEvent`) plus one capability binding `env.cmux` generated from the operation catalog (`op`, `model`, `mux.send`, `machine.run`, `state`). `fetch` goes through an egress gateway; secrets never reach the code. Step names starting `cmux:` are reserved.
> - Code: one code.storage repo per team (C1); `automations/<slug>/{automation.json, index.ts, test.ts}`. chief pushes only to `chief/*`; `automation.deploy {slug, commit}` activates a commit and bumps the version. Every run pins `code_ref {repo, commit, path, export}`, so a resumed run reloads the same code.
> - Body type added: `{type: code, ref: {repo, path, commit, export}}`.
> - Tier 1 (cloud, default): the API Worker loads the tenant module with Dynamic Workers (Worker Loader) inside the single `AutomationRunWorkflow`; capabilities are `WorkerEntrypoint` stubs carrying run-token claims; tenant `DurableObject` classes run as facets of a per-team `AutomationStateDO`; tails meter CPU. No Workers for Platforms.
> - Tier 2 (self-host): the `automations-host` role of the `cmux` binary supervises a pinned `workerd` running the same harness on the team VM or the user's own machine. Cloud-connected hosts are scheduled by SchedulerDO through the link (`target {kind: host}`); offline machines use a local scheduler over the same schema. In-flight run state is on local disk; a lost VM turns runs `dead` at their deadline and they retry by dedupe key. A Workflows-compatible engine in the Rust daemon replaces workerd's emulated engine if the soak test fails.
> - Team VM image: `cmux`, pinned `workerd`, `coderouter` client with edge-injected credentials.
> - Metering: per run steps, CPU ms (tails), invocations, state bytes, Dynamic Workers per day, egress, model spend, VM minutes; quotas per plan; budgets pause a run at a step boundary.
> - Rejected: trigger.dev (official minimum 7 vCPU and 14 GB), DBOS (second API, polling), Inngest (SSPL, lossy defaults), Restate (BSL platform clause), Temporal (weight).
> - Open: R1 to R6 in decisions.md.
