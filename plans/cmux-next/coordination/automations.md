# Lane: automations

Plan: plans/cmux-next/automations-plan.md (P12, P13, P14). Lead: the automations lead.

## Active streams
- Slice 2: UsageMeterDO (DO tag taken at landing, max+1), hard USD cap (staging ceiling `AUTOMATION_CAP_CEILING_USD` = 25, Stripe TEST only), SchedulerDO run-creation bucket (5/s, burst 20) and 50 active runs per team.

## Landed
- 2026-10-03 (this push) backend automations slice 1: automation body `{type: code, ref {commit (40 hex), path automations/<slug>, export?}}`; the repository is not a field (one per team, `cmux-<env>-<team id>`); op `automation.deploy {automation, commit, expected_version?}`; 50 code changes per team per UTC day (create, update, deploy; reducer state `deploys`); the SchedulerDO checks the commit and `<path>/dist/index.js` in code.storage before the reducer (`SchedulerDO.submitCode`, Worker secret `CODE_STORAGE_PRIVATE_KEY`, var `CODE_STORAGE_ORG`, both unset = `code.unavailable`); new `OwnerEngine.gate(principal, frame)` in @cmux/ownership (replay / authorize refusal / undefined) for owners with async checks outside the reducer; code runs fail with `body.unsupported` until the Tier 1 loader (slice 3)
