# Lane: automations

Plan: plans/cmux-next/automations-plan.md (P12, P13, P14). Lead: the automations lead.

## Active streams
- Slice 3: Tier 1 loader (Dynamic Workers), wrapped step, egress gateway, tail; calls UsageMeterDO; integer micro-dollar usage; one automation at most 10 of 50 active slots.

## Landed
- 2026-10-03 (this push) backend automations slice 2: new `UsageMeterDO` (DO tag v9, binding `USAGE_METER_DO`, owner `cloud:UsageMeterDO`, stream `usage:<team>`), ops `usage.summary` and `usage.cap.set` (team admin); RPC `record(team, records)` (idempotent by key, month of recording, max 500 per call) and `check(team)` for callers in slice 3; var `AUTOMATION_CAP_CEILING_USD` ("25" on local, development, staging; unset in production = 0 = stop); SchedulerDO limits: 5 run creations/s burst 20 (retryable `rate.limited`, webhook 429), 50 active and 250 open runs per team, rate-limited provider events kept in `deferred_deliveries` and retried; event matching moved to domains/scheduler-events.ts; app-host generated files and CmuxNextApps scopes.json regenerated (automations lead)
- 2026-10-03 (this push) backend automations slice 1: automation body `{type: code, ref {commit (40 hex), path automations/<slug>, export?}}`; the repository is not a field (one per team, `cmux-<env>-<team id>`); op `automation.deploy {automation, commit, expected_version?}`; 50 code changes per team per UTC day (create, update, deploy; reducer state `deploys`); the SchedulerDO checks the commit and `<path>/dist/index.js` in code.storage before the reducer (`SchedulerDO.submitCode`, Worker secret `CODE_STORAGE_PRIVATE_KEY`, var `CODE_STORAGE_ORG`, both unset = `code.unavailable`); new `OwnerEngine.gate(principal, frame)` in @cmux/ownership (replay / authorize refusal / undefined) for owners with async checks outside the reducer; code runs fail with `body.unsupported` until the Tier 1 loader (slice 3)
