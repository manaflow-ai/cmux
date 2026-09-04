# coderouter operations

This is the private-beta runbook for billing convergence, webhook replay,
latency evidence, and privacy-safe observability. Never paste route tokens,
OAuth credentials, request bodies, email addresses, model credentials, or
account labels into tickets, logs, Sentry, PostHog, or ClickHouse. Bounded,
server-minted account IDs may appear only in closed telemetry fields.

## Rust Cloud client boundary

CodeRouter is the model plane. The machine, workspace, and agent adapter are
the compute plane. Rust must expose both through stable IDs and receipts, but
must not combine their credentials or failure states.

## Shared client and package boundary

The standalone `coderouter` binary and `cmux coderouter` use the same public
`coderouter-core` artifacts: a versioned schema, generated Rust protocol,
transport-neutral async client, secure handoff library, and a reusable command
engine. The command engine owns the canonical noun-action parser fragment,
validation, action dispatch, normalized results, and human, JSON, and JSONL
renderers. The shared layers also own action IDs, envelopes, auth traits,
retries, deadlines, redaction, and usage fixtures. They do not own a keyring,
config file, terminal selection, or process lifecycle.

The npm and PyPI CodeRouter packages are native-binary launchers, not SDKs.
cmux links released Rust crates and never imports an npm package, searches
`PATH`, or depends on a private source repository. The standalone frontend
keeps local keyring and TTY behavior. cmux keeps its Cloud profile, team,
session, and terminal context. Both frontends call the same command engine. A
one-release legacy delegation requires an explicit flag and reports the
delegated binary and contract version.

Both frontends map to the same actions:

~~~text
coderouter status                         = cmux coderouter status
coderouter account list                   = cmux coderouter account list
coderouter session open|close|status      = cmux coderouter session open|close|status
coderouter usage team|machine|agent       = cmux coderouter usage team|machine|agent
coderouter run <agent>                    = cmux coderouter run <agent>
coderouter auth login                     = cmux coderouter auth login
~~~

The standalone `accounts`, `add`, `remove`, and direct agent spellings remain
aliases during migration. New verbs are identical after the optional `cmux`
prefix. This lets one parser fragment, help tree, fixture set, and renderer
serve both binaries.

`cmux auth login` is an ergonomic alias for `cmux coderouter auth login`
because the cmux Cloud profile supplies CodeRouter auth.

`cmux cloud agent run --agent <agent>` composes machine selection, a remote
session, and the same `coderouter run` action. It is a compute workflow, not a
second CodeRouter parser.

CodeRouter cannot create machines, change network policy, or own terminal
processes. `cmux cloud agent run` composes those compute actions with a model
route and a handoff plan.

The Rust command contract is defined in
[docs/cloud-rust-system-design.md](cloud-rust-system-design.md) and staged in
[plans/feat-cloud-rust-cli/DESIGN.md](../plans/feat-cloud-rust-cli/DESIGN.md):

~~~text
cmux coderouter status
cmux coderouter session open|close|status
cmux coderouter account list|add|enable|disable|remove|clear
cmux coderouter usage team|machine|agent
cmux cloud agent run|get|wait|logs|stop|resume
~~~

The existing Swift commands remain compatibility entrypoints until these Rust
commands produce equivalent JSON, authorization, retry, and usage behavior.
The guest calls a VM-local model endpoint. The managed edge binds each request
to source machine and session identity, then adds short-lived model authority
outside guest control. A guest never receives a reusable route bearer, a user
refresh token, or infrastructure credentials. Model access cannot grant
machine creation, destruction, snapshot, billing, or team-account authority.
VM root can spend its machine allowance or relay work through that machine. It
cannot replay the authority from another machine.

## Access

Hosted coderouter and Subrouter are open to every signed-in user in every
team they belong to, including the personal team. Membership is the only
requirement: there is no Stack permission, team allow-list, or paid-plan
gate, and no connected-account cap. Route sessions and upstream accounts are
scoped to the team the caller selects; a non-member gets `team_not_found`.

## Stripe webhook replay

1. Identify the failed Stripe event and the production `cmux.com` webhook
   endpoint in Stripe Workbench. Verify the event belongs to `app=cmux`.
2. Inspect without printing the complete payload:

   ```sh
   stripe events retrieve "$EVENT_ID" --live |
     jq '{id,type,created,pending_webhooks,livemode}'
   stripe webhook_endpoints list --live |
     jq '.data[] | {id,url,status}'
   ```

3. Redeliver the immutable signed event:

   ```sh
   stripe events resend "$EVENT_ID" \
     --webhook-endpoint "$CMUX_WEBHOOK_ENDPOINT_ID" \
     --live --confirm
   ```

4. Confirm `pending_webhooks=0`, the corresponding
   `stripe_webhook_events.error` is null, RDS matches Stripe, and an existing
   coderouter route token is accepted or rejected according to the resulting
   entitlement.

Webhook event IDs are idempotency keys. Never fabricate an event, manually
edit entitlement rows, or retry a different mutation as a substitute.

## Stripe/RDS reconciliation

The Vercel cron calls `/api/cron/billing-reconcile` at minute 23 every hour.
It requires `Authorization: Bearer $CRON_SECRET`, checks Stripe subscriptions
with bounded concurrency, and reuses the webhook's principal lock,
entitlement update, Stack metadata update, and route-token revocation path.
Stripe is authoritative.

For an operator run from a production-configured shell:

```sh
bun run coderouter:reconcile-billing --dry-run
bun run coderouter:reconcile-billing
```

The command prints counts only. Any failed or truncated run exits nonzero and
must be investigated. Do not expose the cron endpoint publicly or place
`CRON_SECRET` in command history.

## Latency evidence

```sh
bun run coderouter:benchmark --samples 30 > coderouter-benchmark.json
CODEROUTER_ROUTE_TOKEN=... \
  bun run coderouter:benchmark --samples 30 > coderouter-auth-benchmark.json
```

The checked-in harness drains responses, records status counts, reports
p50/p95/p99 client-to-edge latency, and parses every `Server-Timing` phase. A
route token belongs in an ephemeral environment variable only; never commit
the authenticated output if it contains a principal identifier.

## Observability

- Sentry project: `coderouter-web`; alert on new coderouter errors,
  reconciliation failure, refresh failure, and sustained model-route failure.
- PostHog project: the main cmux project (`244066`) for account and session
  lifecycle plus operational exceptions. It is not a CodeRouter usage ledger.
- CodeRouter model usage uses the ClickHouse `usage_events` ledger. It contains
  token counts, model and route categories, and the API-equivalent estimate.
  Authenticated rows carry the Stack user ID and billing team.
- PostHog must never contain prompts, outputs, bodies, credentials, route
  tokens, emails, payment-method details, or model-account labels. The
  canonical trace may carry a bounded opaque account ID for routing diagnosis.
  It is not a credential or an account label.
- Person-level product analytics live in the main cmux PostHog project through
  `web/services/coderouter/analytics.ts`. It records closed account, session,
  upstream lifecycle, and operational exception events. Route outcomes and
  token usage stay in ClickHouse. See
  `docs/posthog/cloud-product-analytics.md` for the catalog and query shapes.
- The former dedicated CodeRouter project (`549394`) is no longer a runtime
  sink. Treat its dashboards and environment keys as legacy, and remove keys
  only after checking operator tooling.

### Usage ledger (ClickHouse)

Every model completion writes one `usage_events` row and every routed request
one `route_events` row to our own ClickHouse Cloud database, from the same
deferred `after()` path as the PostHog capture. Schema:
`web/db/clickhouse/001_coderouter_events.sql`. Rows hold token counts, the
rate-card estimate (`api_equivalent_usd`, `priced`, `rate_card_version`), the
raw team and Stack user IDs, the optional `vm_id`, route kind, agent, model,
status, and a per-request `request_id` shared by the usage and route rows.
No prompt, output, header, or credential is ever written.

- Runtime env (Vercel production and preview, `~/.secrets/cmuxterm-dev.env`
  for local dev): `CLICKHOUSE_URL` (HTTPS interface, for example
  `https://<host>.clickhouse.cloud:8443`), `CLICKHOUSE_USER`,
  `CLICKHOUSE_PASSWORD`, `CLICKHOUSE_DATABASE` (`coderouter` in production,
  `coderouter_dev` in preview and local dev). Unset means the ledger is
  disabled: writes are silent no-ops reported once as
  `coderouter.usage_ledger`, and usage panels show as unavailable.
- Scoped-user rule: the runtime user holds `SELECT` and `INSERT` on its own
  database only, no DDL. Every read binds values through ClickHouse query
  parameters (`{team_id:String}`); nothing is string-interpolated into SQL.
  Inserts use `async_insert=1&wait_for_async_insert=0` with a 2 s timeout so a
  proxied request never waits on ClickHouse; reads time out after 5 s.
- Migrations use the separate admin credential (`CLICKHOUSE_ADMIN_URL`,
  `CLICKHOUSE_ADMIN_USER`, `CLICKHOUSE_ADMIN_PASSWORD` in
  `~/.secrets/clickhouse.env`, never present in the app). Apply a schema
  change to both databases:

  ```sh
  set -a; source ~/.secrets/clickhouse.env; set +a
  cd web && bun run clickhouse:migrate coderouter_dev && bun run clickhouse:migrate coderouter
  ```

  The script runs each `web/db/clickhouse/*.sql` file in name order, one
  statement per request, with `{db}` substituted. All DDL is `IF NOT EXISTS`,
  so reruns are safe.

### Customer team-usage dashboard

- The dashboard reads the ClickHouse ledger (`web/services/coderouter/teamMetrics.ts`):
  per-day sums of `usage_events` for the last 30 UTC days, filtered by the
  authorized team ID after the server verifies Stack membership and
  CodeRouter permission. `docs/posthog/coderouter-team-usage-30d.hogql` is
  now for the PostHog operations dashboard only; the app no longer calls a
  PostHog Endpoint, and `POSTHOG_CODEROUTER_ENDPOINT_SECRET`,
  `POSTHOG_CODEROUTER_ENVIRONMENT_ID`, and `POSTHOG_CODEROUTER_API_HOST` are
  no longer read.
- Results are aggregate daily token totals and API-equivalent dollars only.
  Model identifiers are used at write time to derive the estimate from the
  versioned rate card in
  `web/services/coderouter/apiEquivalentPricing.ts`; neither model nor route kind
  is returned to the customer.
- The estimate is not actual spend. Unknown models are excluded and surfaced
  through pricing coverage (`priced_tokens` / `unpriced_tokens`).
  Subscription-routed traffic remains `$0` incremental upstream API spend.
- Responses are cached by team ID for five minutes. A disabled ledger,
  malformed rows, more than 30 day rows, timeouts, and query failures fail
  closed to an unavailable panel and never fall back to a cross-team or
  unfiltered query.
- Capture failures, ledger write failures, and ledger read failures emit
  privacy-safe `coderouter.analytics_delivery`, `coderouter.usage_ledger`, and
  `coderouter.analytics_query` Sentry errors. Alert on each in production.
  The report includes only a bounded failure reason and HTTP status, never a
  team ID, credential, SQL with values, request body, prompt, or model output.

### Customer per-machine usage

- `web/services/coderouter/vmMetrics.ts` runs the same 30-day query filtered
  by `vm_id`, and a per-machine query (`GROUP BY vm_id` where `vm_id IS NOT
  NULL`, at most 200 machines) for a team.
- `vm_id` is the cmux `cloud_vms.id` UUID written on every ledger row when the
  route token was bound to a Cloud VM. It is an opaque server-minted
  identifier, not personal data, and is only ever queried after the server
  confirms the machine belongs to the requesting billing team.
- `GET /api/coderouter/vm-usage?vmId=<uuid>` (dashboard or app session auth,
  `404 vm_not_found` for machines outside the team),
  `GET /api/coderouter/vm-usage/team` (same auth, one row per owned machine
  joined with `cloud_vms.display_name`), and
  `GET /api/coderouter/vm-usage/self` (VM-bound route token via the managed
  edge, `403 vm_bound_token_required` for CLI tokens) serve the same
  30-day totals and daily series as the team dashboard. The dashboard
  Machines card reads the per-machine query through the same service.
- Caching, timeout, fail-closed behavior, and the `coderouter.analytics_query`
  Sentry error match the team-usage read. Loads emit
  `coderouter_vm_usage_viewed` with only a surface and outcome.

Hexclave Analytics remains the authorization system around this data, but is
not the metrics store today: its hosted custom-event ingestion currently
accepts only `$page-view` and `$click`. Reconsider it when Hexclave exposes a
server-authenticated, team-scoped custom-event ingestion API.

## Team Claude upstream accounts

Cloud machines send `claude` traffic to `https://coderouter.dev/v1/messages`. coderouter
forwards each request to one of the team's Claude upstream accounts (`coderouter_claude_accounts`):
any number, any mix of Anthropic API keys, Claude Code OAuth tokens, and Bedrock credentials.
Routing: a machine (its `cloud_vms.id`, else the route token) is pinned to one healthy account by
rendezvous hashing so Anthropic's per-organization prompt cache keeps hitting; a 429 cools that
account down for `retry-after` (else the earliest `anthropic-ratelimit-*-reset`, else 60 s), a 401/403
for 15 minutes (`invalid_credential`), a 5xx/529 or transport failure for 20 s, and the same request
is replayed on the next healthy account (up to `MAX_UPSTREAM_ATTEMPTS`, 4). Disabled accounts are
skipped. When every account is cooling down the client gets 503 `overloaded_error` with the soonest
`retry-after`; when none exists, 503 with the add instructions. `usage_events.upstream_account_id`
and `route_events.upstream_account_id` (ClickHouse migration `002`) name the account that served a
request. PostHog does not receive request-level LLM or token events.

The cmux CLI manages the list through the app's session, so no credential is typed into a browser
or argv:

```bash
claude setup-token                                    # mints a long-lived sk-ant-oat01-... token
cmux coderouter claude add oauth-token --label work   # runs claude setup-token; or CLAUDE_CODE_OAUTH_TOKEN / --stdin
cmux coderouter claude add oauth-token --label personal
cmux coderouter claude list                           # id, kind, masked identifier, label, health
cmux coderouter claude disable work                   # out of routing, keeps the credential
cmux coderouter claude remove personal                # by id, label, or identifier
cmux coderouter machines                              # 30-day spend per Cloud machine
```

`add api-key` takes `ANTHROPIC_API_KEY`; `add bedrock` takes `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY`, optional `AWS_SESSION_TOKEN`, `--region`, and `--model
<claude-id>=<bedrock-id>`. HTTP: `GET/POST/DELETE /api/coderouter/claude-upstream` (list, add,
remove all; `PUT` is an alias of `POST`) and `PATCH/DELETE /api/coderouter/claude-upstream/<id>`
(label, state; remove one). The dashboard's Claude upstream section lists the same accounts with
add, enable/disable, and remove. Rows migrated from the single-upstream table keep their
`aad_version 1` ciphertext binding and get a masked identifier on first read.

## Verifying the edge model plane locally

`web/scripts/coderouter/local-edge.mjs` stands in for the managed TLS egress edge: a
private CA, TLS termination on `127.0.0.1:8443`, the two edge headers overwritten on every
request (the real edge does the same), and re-origination to any coderouter origin. Real
agent CLIs then run with placeholder keys exactly as a Cloud machine does, against a local
`bun dev` with a scratch Postgres and the `coderouter_dev` ClickHouse database:

```bash
# origin: cd web && bun dev on <port> with a local DB (docs/cloud-vm-local-dev.md)
node scripts/coderouter/local-edge.mjs --origin http://127.0.0.1:<port> \
  --route-token <crt_ bound to a cloud_vms.id> --vm-id <cloud_vms.id>
eval "$(...)"                                   # the exports it prints: CA bundle + base URLs
curl -sS "$CMUX_CODEROUTER_URL/api/coderouter/vm-usage/self" -H "authorization: Bearer $OPENAI_API_KEY"
codex exec 'Reply with exactly pong.'           # rustls trusts SSL_CERT_FILE
claude -p 'Reply with exactly pong.'            # Node trusts NODE_EXTRA_CA_CERTS
```

What to check: `--no-inject` (or a raw request with the placeholder) returns 401, a token
bound to another `cloud_vms.id` returns 403 `vm_mismatch`, a forged `x-cmux-vm-id` from the
client is overwritten and logged by the edge, `usage_events` rows in ClickHouse carry the
`vm_id`, `agent`, `upstream_kind`, and cost, and `vm-usage/self` reflects them. For the real
edge against local code, expose the dev server through a quick tunnel, set
`CMUX_CODEROUTER_EDGE_ORIGIN` to it, and run `scripts/cloud-vm/smoke-vm-api.mjs --create
--paid --edge-check`, which creates a Cloud VM whose inline rule points at the tunnel.
