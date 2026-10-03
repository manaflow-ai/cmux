# cmux next: automations implementation plan (P12, P13, P14)

Status: plan, 2026-10-03 (automations lead). Sources: spec/automations-runtime.md, spec/automations-billing.md, spec/cloud-and-automations.md, decisions A11-A21, C1, R7 and batch B-ALL (R3, R8, R9, A18 accepted as recommended). Rows: spec-coverage.md P12, P13, P14. Design detail stays in automations-runtime.md and automations-billing.md; this file only orders the work.

## 0. Rules for every slice

- Direct commits to feat-cmux-next after exact-head gates (backend typecheck, vitest for the touched suites, `catalog:check`, `lint:size`), pushed with safe-push.sh. Rust CLI parts wait for a cmux-tui landing window.
- Review subagent before a slice lands that touches protocol, schema, security (tokens, egress, tenant isolation) or billing. That is most slices here; the table says which.
- Staging only. No production deploy, no production schema change, no live Stripe object. Stripe is TEST mode. Cloudflare resources outside the API Worker carry the prefix `cmuxnp-dev-` and are recorded here.
- Crypto and every runtime path must run in workerd (the workerd test file is the check, not Node).
- Never run tenant code without a ledger, a hard cap and abuse limits in front of it. That is why billing slices come before the loader.

## 1. What exists (base 042ed26b56f)

SchedulerDO per team (cron, manual, continue, webhook, integration events), one `AutomationRunWorkflow` per run with `steps` bodies (sleep, note), deadlines, retry backoff, delivery dedupe, projection tables `automations` and `automation_runs`, ConnectionDO integrations. No loader, no ledger, no code.storage client, no run ops beyond `runs.list`, no UI.

## 2. Slices in order

| # | Slice | Lands | Depends on | Review |
| --- | --- | --- | --- | --- |
| 1 | Code refs and deploy | `CodeRef {repo, commit, path, export}` and body `{type: code, ref}` in protocol; `automation.deploy {automation, commit}` (SchedulerDO, bumps version, pins ref, deploy-rate limit 50/day); workerd code.storage client (ES256 JWT from a Worker secret, read file at an exact commit, create repo with a fixed id); team repo id derived as `cmux-<env>-<team id>` (for example `cmux-staging-team_…`) and created lazily, so no new owner record. A `code` run fails with `body.unsupported` until slice 3. | nothing | yes |
| 2 | UsageMeterDO ledger and the hard USD cap | One `UsageMeterDO` per team: append-only ledger keyed by idempotency key, live counters per meter and UTC month, price table (TEST values, staging), hard USD cap per team (A18) with `usage.cap.get/set` (staff only for set) and `usage.summary`; `record(batch)` returns `{allowed, stop_reason}`. SchedulerDO token bucket for run creations (5/s, burst 20) and concurrent runs per team (50). | migration tag v11 (asked) | yes |
| 3 | Tier 1 loader | `worker_loaders` binding; `AutomationRunWorkflow` loads the tenant bundle at the pinned commit (loader id = repo + commit + path) and calls its `run(event, step)` through a wrapped step (step count, steps per run 2,000, retries 5, `cmux:` prefix reserved, budget and cap check at every step boundary through UsageMeterDO); `limits {cpuMs: 10,000, subRequests: 1,000}`; `globalOutbound` = `AutomationEgress` (allowlist, 600 requests/min/team, metered); `tails` = `AutomationTail` (CPU ms, wall ms, outcome per invocation into UsageMeterDO). Vendors the MIT dynamic-workflows adapter with attribution if the binding needs it. | 1, 2 | yes |
| 4 | env.cmux from the catalog | Generator in packages/protocol writes `cmux.d.ts` and the capability map from cloud ops marked for automations; `CmuxCaps` WorkerEntrypoint with run-token claims (team, run, automation, scopes) so tenant code never holds a credential; `env.cmux.op`, `log`, `metric`, `state` first; `model` through CodeRouter, `mux.send` and `machine.run` when their owners exist. The same path gives P13 its `op` step type. | 3 | yes |
| 5 | Run ops and budgets | `run.get`, `run.cancel`, `run.retry` (new run with the same input and a `retry_of` link), `run.approve` (sends the Workflow event), `run.logs`; per-run budgets pause the run in `waiting` at a step boundary instead of terminating; default alerts (failed, dead, 3 consecutive failures, 80% budget or cap, retry storm) go to the notification owner (FeedDO). | 2, 3 | yes |
| 6 | Observability | Log record schema `{ts, team, automation, version, commit, run, step, attempt, level, msg, attrs, trace_id, span_id}`; tail forwards records and spans; R8 store = our ClickHouse, a staging database with per-team row policies, an insert-only Worker user and a read user for `telemetry.query` (fixed schema, run-scoped); run timeline op merges the Workflow instance status, run reports, logs and spans. | 3 | yes (data isolation) |
| 7 | Stripe TEST meters and reconciliation | Hourly job (SchedulerDO-style alarm in UsageMeterDO, no cron poll) sends meter events with key `team:meter:hour` to Stripe TEST; daily reconciliation against Workflows GraphQL (`stepCount`, `cpuTime` by instance id) and the Billable Usage API, drift alert above 5% or $50 unattributed; outbox rows to PlanetScale `usage_events` and `usage_hourly` on the staging branch only. | 2, 3 | yes |
| 8 | Skill and CLI | `skills/cmux-automations` (one prompt: init, test, deploy, run, logs); CLI verbs `cmux automations init/test/deploy/run/logs/runs` in the Rust CLI (request file first, then a cmux-tui landing window); `init` writes `automations/<slug>/{automation.json, index.ts, test.ts}`; `test` runs the bundle in a local workerd harness; `deploy` bundles to `dist/`, pushes to `chief/<slug>` and calls `automation.deploy`. | 1, 3, 4 | CLI owner |
| 9 | Tier 2 host | Harness package (pinned workerd and wrangler as verified, the wake shim, state on local disk) plus the `automations-host` role in the cmux binary; record the open soak results; SchedulerDO sends `host.wake_runs` after a host reconnects. The Rust Workflows-compatible engine (R3 target) starts as a spike with a conformance suite against Cloudflare. | 3; lane 1 image, lane 10 server role | yes |
| 10 | TargetPolicy host and exit receipts | Remote steps go to the host through HostDO; the step waits for a daemon exit receipt (Workflow `waitForEvent`), never a poll; fallback cloud_vm, wait or fail. | HostDO link messages (L12) | yes |
| 11 | agent_prompt and the missing triggers | `agent_prompt` body sends a message to the team's Chief (MuxDO) and waits for the outcome; triggers message (MuxDO), presence (UserDO presence), machine (HostDO), store (Tasks and app stores). | P2 MuxDO, presence owner, L12, Tasks lead | yes |
| 12 | Creation form and run history | Dashboard pages first (one editable form that a Chief chat can fill, run list with loud failures and the timeline); the Mac surface follows as a first-party app on the app platform; projection read path (read-only role and Hyperdrive on staging). | 5, 6; app platform lead for the Mac app | no |
| 13 | Later | Tenant DO classes as facets of `AutomationStateDO` (one more tag); Chief-written apps in the same team repo (`apps/<app>/`, with the app platform lead); R9 note (apps use the automations runtime; graphile-worker with a long poll is the documented Postgres option); import old local rules. | app platform lead | yes |

Abuse defaults (A18, accepted): CPU 10 s and 1,000 subrequests per invocation, 2,000 steps and 5 retries per run, 24 h run wall clock, 50 concurrent runs, 5 creations/s burst 20, 50 deploys a day, 600 egress requests a minute, 7-day instance retention, and the hard USD cap. Included quotas and overage prices come later from dogfood cost data and must exist before any paid launch.

## 3. Who I need

- Backend lead (via main): migration tag v11 for `UsageMeterDO` now and a later tag for `AutomationStateDO`; new wrangler bindings (`worker_loaders`, egress and tail entrypoints, a rate-limit namespace block for run creations); staging secrets for code.storage, ClickHouse and Stripe TEST.
- Lane 10 a07ed15c10e36f8c8 (server and store): the `automations-host` role in `cmux server` and the server's Postgres for R9.
- Lane 1 a62c42237cb5703d4 (VM image): pinned workerd and the harness in the image (slice 9).
- L12 (HostDO and the link): host messages for remote steps, exit receipts and `host.wake_runs` (slices 9, 10).
- P2 owner (MuxDO): the send path for `agent_prompt` and message triggers (slice 11).
- Rust CLI pin owner and the landing-window queue: the `automations` verbs (slice 8).
- App platform lead: apps in the team repo and the Mac run history app (slices 12, 13).

## 4. Open questions (sent to main)

- Hard USD cap default per team during dogfood. Recommendation: $25 per team per UTC month, staff-adjustable per team, because it bounds a runaway loop at a cost we accept without blocking normal use.
- code.storage org per environment. Recommendation: one org for staging and development now with repo ids prefixed by environment, a separate production org before any production deploy, so a staging key can never read production code.
- PlanetScale schema for `usage_events` and `usage_hourly`. Recommendation: apply to the staging branch after review, production only with explicit approval, because direct commits on feat-cmux-next have no label flow.
- Bundling location. Recommendation: the CLI bundles to `dist/` in the same commit, because a Worker-side bundler costs CPU on every deploy and adds a large wasm module; the deploy op refuses a commit without the bundle.

## 5. Resources

None created yet. Every Cloudflare, code.storage, ClickHouse or Stripe TEST resource gets a line here with its id and its deletion.
