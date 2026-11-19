# Cloud self-test: one command surface for Cloud multiplayer

Goal (user, 2026-11-07): "find ways to self test. Using the CLI and MCP as the structure, we can probably
close the loop on most functionality." An agent drives and checks every Cloud multiplayer behavior end to end,
as several people at once, with no GUI, and gets PASS, FAIL (with the code and why) or PENDING per scenario.

## 1. The command

```
bun scripts/cmux-next/cloud-selftest.ts list [--json]
bun scripts/cmux-next/cloud-selftest.ts run --backend dev|preview-N|local|--api URL \
    --fixtures worker|stack|accounts [--credentials FILE] --cmux PATH \
    [--scenario a,b | --tag fast | all] [--driver auto|cli|api] [--no-machines] [--out DIR] [--json]
```

It builds on `scripts/cmux-next/cloud-journey.ts` (backend names, scrubbing, the model stub path, the Stack
constants) and never runs against production. `--out DIR` writes `journey.json` (each scenario, each step with its
actor, action, transport, error code, tries and latency) and `summary.md`. Exit 0 when nothing failed; PENDING
and SKIP do not fail unless `--fail-on-pending`.

## 2. Actors

Seven names, each one role for the whole catalogue: `owner` (team owner), `admin`, `member`, `member2`,
`leaver` (a member removed mid-run), `guest` (signed in, outside the team, joins by link) and `outsider` (signed
in, no relation). Each actor is its own sign-in identity with its own `HOME`, XDG folders and control-socket path
(nothing listens there, so an app-only verb fails fast instead of reaching the person's cmux). A child `cmux` gets
only `PATH`, locale and the actor's own `CMUX_CLOUD_API_URL`, `CMUX_CLOUD_ACCESS_TOKEN` and `CMUX_CLOUD_TEAM`.
No caller `CMUX_*` variable is passed on (a test checks this). The run provisions each actor once, the owner first.

## 3. Test identities and teams (fixtures)

- `worker`: `POST /v1/dev/fixtures` in the cmux-api Worker (`backend/apps/api/src/dev-fixtures.ts`). It is a 404
  unless `ENVIRONMENT` is development (previews deploy as development), local or test and the Worker is not named
  `cmux-api` or `cmux-api-staging`. It also needs the secrets `DEV_FIXTURES_TOKEN` (header `x-cmux-dev-fixtures`,
  compared in constant time) and `STACK_SECRET_SERVER_KEY`. Ops: `user`, `team`, `member.set` (member, admin,
  billing or guest, as the `cmux:<role>` team permissions that `team-roles.ts` maps), `member.remove`,
  `sessions.revoke` and `cleanup`. The route acts only on users and teams that carry this run's mark (server
  metadata `cmuxSelftest: <run>`, emails `selftest-<run>-<actor>@selftest.cmux.invalid`). It runs the TeamDO
  sync (`stackWebhook`, as a webhook delivery would) before it answers, so a member removed live is refused on
  their next request.
- `stack`: the same calls, made from the runner to the sign-in service's server API for the dev project only
  (the production project id is refused), with `STACK_SECRET_SERVER_KEY` from `--credentials`. TeamDO hears of a
  change from the service's webhook or from the member's own `user.teams.list` heal, so steps that need a live
  revoke wait for it (`within_ms`). This path needs no deploy.
- `accounts`: pre-made accounts (`CMUX_SELFTEST_ACCOUNTS`, JSON `{actor: {email, password}}`), read-only.
  Scenarios that need `fixtures.mutate` are skipped.

## 4. Deterministic model plane

The shared model stub (`tests/fixtures/model-stub`, version 3) gains error steps
(`{"error": {status, type, message, retry_after}}`), a `delay_ms` on any step (to hold a turn open while someone
steers, transfers or loses access) and run-time faults (`POST/GET/DELETE /__stub/faults`: queued 429, 401, 529 or
delays, per path, counted, side requests exempt). It runs in two places:
- on the machine's loopback, with Claude Code pointed at it (`vm.stub`), as `cloud-journey --model stub` does;
- on this computer, behind real `cmux inference gateway --upstream <stub> --token-file F [--team T]` processes
  (`gateway.start` / `gateway.stop`). These drive the gateway being offline, reconnecting and two gateways for
  one owner, and the provider errors that come back through coderouter.

## 5. Scenarios and actions

A scenario is data: `{name, summary, covers[], tags[], actors[], needs[], steps[], finally[]}`. A step is
`{actor, action, args, expect, save?, concurrent?}`. Args take `${team}`, `${vm}`, `${session}`, `${owner.user}`
and saved values. `expect` is `{ok}` or `{error: code | codes}` plus a JSON subset with `$contains`, `$not`,
`$re`, `$gte`, `$len`, `$oneOf`, `$absent` and `$exists`. `within_ms` is a bounded wait that only the harness
does, for state that converges. `concurrent: true` steps run at once (simultaneous prompts).

Each action (`scripts/cmux-next/cloud-selftest/actions.ts`) names its CLI verb and its lane. It runs through
the first of these that is available:
1. The `cmux` verb with `--json`, when `cmux VERB --help` answers.
2. The backend route that verb will call, recorded as `via the route; cmux VERB PENDING-<lane>`.
3. Nothing: PENDING-<lane>.

Harness actions (fixtures, the stub, local gateways, and exec-built probes such as `vm.credentials`) belong to
the runner. Renaming a verb when a lane lands means changing one line in `actions.ts`.

Catalogue (`list` prints it with what each scenario waits on):
- `identity.isolated`, `team.list`, `team.role_matrix`, `auth.expired_revoked`, `team.member_removed_live`: the
  routes a client calls (`user.teams.list`, `team.members.list`). No CLI verb lists a headless account's teams;
  `cmux cloud team-members` is the app's.
- `vm.login_free`: no login files on the machine, no real provider keys, base URLs at the edge, by exec, then
  `cmux cloud machine-auth --machine` (lane A).
- `vm.chat_sleep_wake`, `vm.restart_mid_turn` (the agent daemon killed mid-turn: the prompt is kept once, the
  session comes back), `chat.large_transcript` (a 200 KB prompt and 20 turns): base.
- `gateway.admin`, `gateway.admin_personal` (`cmux inference gateway status|mode`, no machine),
  `gateway.route_order` (`cmux inference route`), `gateway.offline_reconnect` (`inference.gateway_offline`),
  `gateway.two_gateways`, `gateway.provider_errors` (rate limit, auth, then a passing retry): lane B.
- `team_keys.shared_path` (`cmux cloud team-keys status|set|remove`: owner-only writes, a replayed set, the
  secret never read back): lane E.
- `cli.usage_errors`: the verbs' stable usage codes, with no account.
- `app.team_read`, `app.session_changes`, `app.transfer_local`: lane D's app actions, as the tagged app's person.
- `link.chat_owner`, `share.guest_held`, `share.member_steer`: lane C's `cmux link chat`.

## 6. The shipped verbs (the contract this runner scripts)

The full table, with each verb's JSON, error codes and Rust tests, is
[cloud-multiplayer-cli-matrix.md](cloud-multiplayer-cli-matrix.md). `cloud-selftest/verbs.ts` reads the offered
verbs from the Rust sources and `cloud-selftest.test.ts` fails when an action names one that is not offered.

Three routes, by what a verb needs:

- Headless (`CMUX_CLOUD_API_URL`, `CMUX_CLOUD_ACCESS_TOKEN`, `CMUX_CLOUD_TEAM`; several actors at once):
  `cloud team-keys`, `inference gateway status|mode`, `inference route`, `cloud machine-auth`,
  `machine access exec`.
- The app's socket (`on: "app"`, the `app` actor): `cloud team-sessions`, `team-session`, `copy-session-link`,
  `follow`, `unfollow`, `reassign`, `archive-session`, `show-team-section`, `team-members`, `group-members`,
  `group-member-set`, `group-member-remove`, `transfer-local`. They answer as the one person signed in to the
  tagged app (`CMUX_TAG` or `--app-socket`, `--cmux` that app's CLI), so they cannot be driven as several actors.
  With no app answering `cmux app ping` their scenarios SKIP with the reason. `--app-session KEY` and
  `--app-tab TAB` name what the run may change.
- This computer's link: `cmux link chat list|read|send|approve|decline --host ID` (`--link-host ID`), as the
  person the link's registration names. A member's steer and a guest's held prompt need a link per actor
  (`link.actors`), which this runner does not make: those scenarios SKIP.

Error codes asserted: `team.not_member`, `auth.forbidden`, `auth.unauthenticated`, `auth.refresh_refused`,
`inference.gateway_offline`, `provider.rate_limited`, `provider.auth`, `usage.invalid`, `cli.invalid_args`,
`chat.bad_usage`, `cloud_session.invalid`, `agent_session.owner_only`, `remote_denied`, `fixtures.*`.

## 7. MCP

No new MCP family. An agent running in a checkout runs the self-test from its shell; the runner is a repository
tool, not something shipped in the app. The actions it drives are already MCP tools:
- Every app action with `cli: .offered` becomes an `app_*` MCP tool generated from the app's action list
  (`cmux-tui/.../cli/mcp/action_tools.rs`). `cmux cloud team-sessions` therefore appears as
  `app_cloud_team_sessions` with no extra work.
- The Cloud repository actions are the existing `cloud_repo_*` family (`cloud_repo_tools.rs`).
- acpmux is the `acpmux_*` family.

A `cloud_selftest_*` family would need the bun runner and a checkout on the machine that runs MCP, which the app
does not ship. Agents call `bun scripts/cmux-next/cloud-selftest.ts run ... --json` and read the JSON report.

## 8. Limits

- `within_ms` exists only to wait for converging state in the harness. The product does not poll.
- The `stack` fixtures depend on the sign-in service's webhook reaching that Worker. When it does not, a live
  revoke shows up only through the paced heal, so `team.member_removed_live` can time out there. `worker` fixtures
  sync TeamDO at once.
