# Chief product analytics (PostHog)

What the Chief (`optchat-chief`, the host behind Home's Chief chat) sends, why, and how to read it.
Events go to the main cmux PostHog project (`244066`), next to the classic Mac app, the web, the
server's `cloud_vm_*` and billing events. Dashboard: **Chief (product)**, built by
`scripts/posthog-chief-dashboard.py` in cmuxterm-hq (run by its `posthog-dashboards` workflow).

Source of truth: `Native/OptChat/optchat-chief/src/analytics/catalog.rs` (`EVENTS`, `MILESTONES`,
`map`). `tests/analytics.rs` `catalog_is_pinned` fails when an event or milestone is missing from
this page; rename one here, in the catalog and in the dashboard script in the same change.

## Pipeline

- Every Chief host writes a local monitoring trace (`trace.rs`) and a usage ledger (`usage.rs`).
  The trace hands each event to `Analytics::observe` and each ledger line to `observe_unit`.
  `catalog::map` makes at most a few closed-schema events of it; they are appended to
  `<mux home>/optchat/analytics/queue.jsonl` (file 0600, folder 0700) and the call returns.
- One thread (`chief-analytics`) posts the queue to `https://us.i.posthog.com/batch/` in batches of
  50: at once when 50 wait, else within a minute. A failed send (offline, timeout, 429, 5xx) keeps
  the batch in `sending.jsonl` and backs off from 1 to 30 minutes; the next host on the same home
  sends it first. A 4xx refusal drops that batch. The queue stops at 2 MB and counts what it
  refused (`chief_analytics_dropped`). Each event has a random `uuid`, so a resend after a lost
  answer is deduplicated by PostHog.
- With nothing queued the thread only wakes every 5 minutes to re-read consent; the first event
  after a quiet spell wakes it, so it goes within a minute. While sends fail, a full batch also
  waits out the backoff. No call site waits on the network.
- A host that starts with telemetry off makes no `analytics/` folder, id or state; when consent
  turns on later it makes them and sends `chief_host_started`.

## Consent (opt-out)

On by default in release builds, the same rule as the cmux CLI's crash reports
([privacy.md](../privacy.md#telemetry)). Off, and the queue deleted at once (read again every 5
minutes), when any of these holds:

| Switch | Who sets it |
| --- | --- |
| Managed `DisableTelemetry` (or a forced `app.sendAnonymousTelemetry: false`) | An admin's profile |
| The app's own `sendAnonymousTelemetry` off | The person (`defaults write <app bundle id> sendAnonymousTelemetry -bool false`); the app passes its bundle id (`CMUX_CHIEF_APP_BUNDLE_ID`) and the host reads that preference itself on every check, so a host that outlives the app sees the change |
| `app.sendAnonymousTelemetry: false` in `~/.config/cmux/cmux-next.json` (`cmux settings set app.sendAnonymousTelemetry false`) | The person |
| `DO_NOT_TRACK=1`, `CMUX_CHIEF_ANALYTICS=off`, or `CI` set | The environment |
| A debug compile, a DEV or tagged app | The build (see Staging) |

## Privacy

- Properties are closed tokens, counts, durations, booleans and costs. A harness, model, effort,
  tool or error that is not on the code's list is sent as `other`.
- Never sent: message, reply, task or report text, tool arguments or results, error messages,
  file paths, URLs, repository or workspace names, user names, emails, subagent ids, session ids,
  hostnames. An error is sent only as its class (`rate_limited`, `overloaded`, `auth`, `timeout`,
  `context_too_long`, `network`, `harness`, `server`, `other`), derived on the Mac.
  `tests/analytics.rs` seeds API keys, a GitHub token, an email, a path, a prompt and an id into
  every trace field and checks that none of them is in the request as sent.
- IP geolocation is off (`$geoip_disable`). The project should also discard client IPs.

## Identity

| Concept | Value |
| --- | --- |
| `distinct_id` | Local Chief: a random UUID made once per Chief home (`analytics/id`), not derived from the machine or the user. Cloud Chief: the signed-in Stack user id, the id the server's `cloud_vm_*` and billing events use. |
| `chief_install_id` | That random UUID on every event, so one person's several Chiefs stay apart. |
| `$groups.stack_team` | Cloud Chiefs: the Stack team id. |
| Cloud consent | A Cloud Chief runs on our servers with no app beside it; it sends by default, like the server's own `cloud_vm_*` events, and stops with `CMUX_CHIEF_ANALYTICS=off` or `DO_NOT_TRACK` in its environment. |
| person `$set_once` | `chief_first_seen_ms` on the first host start. |

## Shared properties

`product: chief`, `schema_version: 1`, `source` (`local`, `cloud`), `channel` (`stable`,
`nightly`, `rc`, `dev`, `cli`, `cloud`), `environment` (`production`, `dev`), `chief_version`,
`chief_build` (12 hex digits), `app_version` (when the app started the host), `os`, `arch`,
`$lib: optchat-chief`.

## Events

| Event | Fires when | Properties |
| --- | --- | --- |
| `chief_host_started` | A Chief host starts with telemetry on | `is_new_install`, `engine` (`acpmux`, `native`) |
| `chief_activation_milestone_reached` | First time per install | `milestone`, `days_since_install` |
| `chief_daily_active` | First finished turn of a UTC day: `ok`, or `stopped` by the Chief after it replied | none |
| `chief_message_received` | A message reaches the Chief (its own chat or a side chat) | `sender` (`human`, `agent`, `other`), `images`, `files`, `remote`, `side` |
| `chief_turn_completed` | A Chief turn ends | `turn_status` (`ok`, `error`, `cancelled`, `stopped`, `owner_stopped`, `superseded`, `refused`), `error_class`, `replied`, `harness`, `harness_kind`, `model`, `effort`, `tier`, `duration_ms`, `start_ms`, `ttft_ms`, `headers_ms`, `first_draft_ms`, `posted_to_first_draft_ms`, `requests`, `tools`, `tool_errors`, `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens`, `cache_hit_rate`, `cost_usd`, `harness_refused` |
| `chief_tool_used` | First use of a tool per UTC day | `tool` (the Chief's tools by name, harness built-ins by name, `mcp_cmux`, `mcp_other`, `other`) |
| `chief_subagents_spawned` | One `spawn` call | `count`, `harness`, `here`, `cloud`, `peer`, `settle_ms` |
| `chief_subagent_started` | A subagent's session starts | `harness`, `harness_kind`, `goal`, `peer`, `start_ms` |
| `chief_subagent_finished` | A subagent reports done | `outcome` (`landed`, `unlanded`, `stopped`, `done`), `landed`, `stopped`, `duration_ms`, `tools`, `tool_errors` |
| `chief_compactor_failed` | A memory summary failed or hit a capacity limit (capped, see below) | `reason` (`node_failed`, `capacity`), `error_class`, `harness`, `http_status`, `failover`, `duration_ms`, `repeats_dropped` |
| `chief_error` | A host-side failure (capped, see below) | `kind` (`harness_refused`, `capacity_wait`, `turn_ttl_refused`, `subagent_stuck`, `subagent_stop_refused`, `tell_undelivered`, `reply_too_long`, `subagent_workspace_failed`), `role`, `harness` |
| `chief_usage_daily` | Once a UTC day is over, at the next unit or host start | `day`, `turns`, `compactor_nodes`, `subagent_prompts`, `turn_cost_usd`, `compactor_cost_usd`, `subagent_cost_usd`, `cost_usd`, the four token counts, `cache_hit_rate` |
| `chief_analytics_dropped` | The full queue refused events | `count` |

`replied` is true when the turn posted a reply: a `reply` on the turn, or a successful `send` or
`reply` tool call in it. The Chief normally answers by `send` and then ends its own turn, so most
good turns have `turn_status: stopped` and `replied: true`; read "good turns" as `ok` plus that.

`chief_compactor_failed` and `chief_error` send at most 10 events per reason or kind, per install
and UTC hour (`catalog::BURST_PER_HOUR`); the next one sent carries `repeats_dropped`, the count
held back before it. Count failures as `count() + sum(repeats_dropped)`.

`landed` comes from the subagent's report on the Mac (`sub_watch::landed`: a commit range such as
`OLD..NEW`, or "landed" next to a sha, and none of the not-landed words); only the flag is sent.

Milestones, in funnel order: `first_host_start`, `first_message` (a person's), `first_reply` (an
ok turn with a reply), `first_subagent`, `first_subagent_done`, `first_landed_work`,
`first_day_7_return` (a turn 7 to 13 days after install).

Costs are what the harness reports (Claude Code's `total_cost_usd`): list price, not what cmux
pays. Latency fields are milliseconds, so insights can use p50/p90/p95 directly. Property names avoid
ones the project already types as numbers for other products (`status` is an HTTP code there),
hence `turn_status`.

## Errors and crashes (Sentry)

A Chief host panic is appended to `<mux home>/optchat/panics.jsonl` (`cmux-panic-log`). The
cmux-next app sends new lines to its Sentry project under the same telemetry choice, scrubbed
like every other report, tagged `process: optchat-chief` (`RustPanicSource.chief`). The panic
message is withheld (a string slice panic can quote chat text): only the location, the thread
and the backtrace are sent. Cloud Chiefs have no app to send them yet. Product-level failures (turn errors, harness refusals, compactor
failures) are PostHog events above, so their rates sit next to the funnel.

## Staging

A DEV or tagged build sends nothing unless `CMUX_CHIEF_ANALYTICS=dev`, which sends to the same
project with `environment: dev`. Every dashboard insight filters `environment = production`; a
dev check looks at `environment = dev`.

## Dashboard insights

1. Activation funnel: `chief_activation_milestone_reached` by `milestone`, in the order above,
   14-day window, by `channel`.
2. Daily and weekly active Chiefs: unique `chief_install_id` on `chief_daily_active`, per day and per week.
3. Week-1 / week-4 retention: start `chief_activation_milestone_reached` (`first_reply`), return
   `chief_daily_active`.
4. Turns per day by `status`; error rate by `error_class`.
5. Turn latency: p50 and p95 of `duration_ms`, `ttft_ms`, `posted_to_first_draft_ms`.
6. Cache hit rate: average `cache_hit_rate` per day, by `harness`.
7. Cost per day: sum of `cost_usd` on `chief_usage_daily`, by kind.
8. Subagents: spawned per day, `chief_subagent_finished` by `outcome`, landed share.
9. Tools: unique installs using each `tool` per day.
10. Errors: `chief_error` by `kind`, `chief_compactor_failed` by `reason`.
