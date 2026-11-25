# Automations: one model, teleport, team automations

Status: design, 2026-11-03 (a908). Ask (Lawrence, chat 19943): automations from first principles,
built into cmux. Local and Cloud, a "teleport" like the Chief's, Durable Object alarms used
properly, every automation controllable from the app, the Chief, the CLI and MCP, and team
automations handled carefully. Builds on `docs/automations-platonic-ideal.md` (the target) and
what landed through 172933a.

## 1. One model, two stores

An automation is one record, the Cloud schema `Automation` in
`backend/packages/protocol/src/automations.ts`. The local store
(`cmux-tui/crates/cmux-automations`) keeps the same fields under the same names. Fixtures in
`docs/automations-fixtures/` are parsed by the Rust tests and the backend tests, so a field that
drifts fails both suites.

Fields every copy has, and what they mean:

| Field | Meaning |
|---|---|
| `id`, `name`, `version`, `enabled` | as today |
| `trigger(s)`, `body`, `catch_up`, budget | when and what; `catch_up` is `latest` (default), `all` or `none` |
| `home` | the one store that fires it: `cloud` or `mac:<machine id>` |
| `epoch` | 1 at create, one more on each teleport; the newer epoch wins everywhere |
| `last_slot` | the newest scheduled time this automation already fired (ms) |
| `owner`, `created_by`, `sharing`, `editors` | team scope (section 4); a local-only automation has no team |

Only the home fires. A store that holds an automation that left keeps a tombstone
`{id, moved_to, moved_id, epoch}` and never fires it. `cmux automation list` shows the tombstone as
"moved to Cloud" for 30 days, so a person who looks in the old place finds the new one.

## 2. Teleport: a single-writer handoff

`cmux automation teleport NAME --to cloud|home|ssh:HOST`, the page's "Move to…" menu, the
`automation_teleport` MCP tool and the Chief's automation tool are one operation. The destination
grammar is the Chief teleport's (`backend/apps/api/src/chief-brain/brain-teleport.ts`,
`destinationError`: `home`, `ssh:<host>[:<dir>]`), plus `cloud`. The handoff id has the same shape
(`tp_<32 hex>`). Session teleport (a964) has no shared code on feat-cmux-next yet; when it lands it
uses the same three steps.

Three steps. At every instant at most one store may fire the automation:

1. **Fence (source).** The source writes `handoff {id, to, epoch: e+1, at}` on the automation. A
   fenced automation never fires: the local runner skips it, and the Cloud alarm skips it
   (`automation.fire` answers stale). `last_slot` is frozen.
2. **Accept (destination).** The destination imports the spec with the handoff id as its idempotency
   key (`automation.import`, ledger key `teleport:<handoff id>`): a retry replays, never makes a
   second copy. The import carries `epoch e+1` and `last_slot`. The destination computes its next
   fire from `last_slot` with the automation's `catch_up` policy, so a slot that fell inside the
   handoff runs once (or not, for `none`), never twice.
3. **Release (source).** The source turns its row into a tombstone that names the destination's id.

A crash between steps leaves a fenced automation that nobody fires, which is safe, and the next
`cmux automation teleport` (or the runner's start) resumes the same handoff id. A refused accept (the
plan limit, a permission, the destination is offline) aborts: the source clears the fence and fires
again. Cloud as the source uses `automation.teleport.begin` (fence, answers the spec and
`last_slot`) and `automation.teleport.complete` (tombstone) or `automation.teleport.abort`.
Another Mac is reached over `ssh HOST cmux automation import --json -`; the spec goes on stdin.

## 3. Cloud scheduling: Durable Object alarms

Already true, kept: one SchedulerDO per team, one alarm per object. `OwnerDO` sets it to
`nextWakeAt` (the earliest of every enabled trigger's `next_at`, the dispatch backlog, run
deadlines and backoffs), and every wake recomputes it from state, never from the old alarm. A fire
is the system op `automation.fire` with ledger key `fire:<automation>:<trigger>:<scheduled_at>`, so
a repeated alarm or a crash after the write replays and starts no second run. Failed steps back off
`1 s · 2^n` to 5 minutes, and the backoff is stored so a restarted object waits it out.

New in this slice:

- **Catch-up policy** per automation: `latest` (default) fires the newest missed slot once if it
  is younger than 24 hours; `all` fires each missed slot, at most 10, oldest first; `none` fires
  nothing late. A fire whose slot is older than the policy allows records a `skipped` run with the
  reason `missed`, so nothing is silently dropped.
- **Time zones.** Cron is five fields in an IANA zone (`croner`). Tests pin the DST cases: a 02:30
  daily job in `America/Los_Angeles` fires once on the spring-forward day and once (not twice) on
  the fall-back day.

## 4. Team automations

The owner team is the SchedulerDO, so another team's automations are never in the same object, and
every read and op is checked against `principal.team`. Inside one team:

- The Worker adds the caller's `team_role` to the principal (`principalForOwner`, from TeamDO's
  `memberRole`, never from a request). The personal team's user is `owner`. Guests and the
  billing role never reach SchedulerDO (they have no `team.resources`).
- `sharing` is `team` (default, and what every older automation is) or `private`.
- Permissions:

| Action | Who |
|---|---|
| view (list, get, runs) | `team`: every member. `private`: the creator, `editors`, admins and owners |
| run now | whoever may view it |
| edit, pause, resume, delete, teleport | the creator, `editors`, admins and owners |
| change `sharing` or `editors` | the creator, admins and owners |

  A refusal is `auth.forbidden` for an action on a visible automation, and `selector.not_found` for
  one the caller may not see, so a private automation's existence does not leak.
- An install, agent or Chief acts as its user with that user's rights; a run's own principal
  (`automation:<id>`) acts as the automation's creator.
- **Audit.** Every change (create, update, enable, disable, delete, run now, teleport, sharing)
  appends `{n, at, actor, op, automation, summary}` to SchedulerDO's private `automation_audit`
  table. `automation.audit.list` gives admins and owners the team's log, and anyone else the entries
  of automations they may view. Bodies and secret values are never in an entry.
- The PlanetScale projection (`automation.upsert`) carries `sharing` and `editors`; nothing reads it
  per member today, and any reader added later must apply the same view rule.
- **Secrets (next slice).** Team automation secrets are named; a body names them
  (`{{secret.NAME}}`), and a run resolves them in its owner team only, after the permission check.
  This slice does not store secret values in the Cloud: the existing `cmux cloud secret` values stay
  in this Mac's Keychain.

## 5. Every surface

| Surface | How |
|---|---|
| App | Automations page: rows show where each runs (This Mac / Cloud). Next slice: its Run now, Pause and Move to… buttons call the CLI below (they are not wired yet) |
| CLI | `cmux automation list|create|update|run|pause|resume|delete|runs|teleport|import` (`--target cloud` for Cloud) |
| MCP | `automation_list`, `automation_get`, `automation_create`, `automation_run`, `automation_pause`, `automation_resume`, `automation_delete`, `automation_runs`, `automation_teleport`; they run the same CLI code |
| Chief | the Mac Chief's automation tool (`cmux automation …`) and the Cloud Chief's jobs, plus `teleport` |

## 6. Proof

`scripts/cmux-next/automations-teleport-proof.py` runs against staging: create on this Mac, fire,
teleport to Cloud, fire in Cloud, teleport back, fire on this Mac, and checks that no slot ran twice.
