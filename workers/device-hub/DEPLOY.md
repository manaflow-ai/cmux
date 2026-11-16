# Deploying the device hub

The device hub (`docs/device-hub/PROTOCOL.md`) is one Worker with two SQLite
Durable Object classes, `UserDO` and `SessionDO`. `wrangler.toml` commits no
`account_id`; the deploy shell provides it. The top level of `wrangler.toml`
is production; `[env.dev]` is dev. Bindings, vars and migrations are repeated
under `[env.dev]`, because environments do not inherit them. The two are
separate Workers, so their Durable Objects, storage and secrets are separate
too.

| Environment | Worker |
|---|---|
| dev | `cmux-device-hub-dev` |
| production | `cmux-device-hub` |

The cmux-next app builds both addresses in (`DeviceHubSettings` in
`Packages/macOS/CmuxNext/Sources/CmuxNextSettings`): DEV builds use the dev
hub, every other build the production hub. A DEV build's Settings ›
Development › Device Hub Address overrides it; empty means the built-in hub.

## Normal path: the `device-hub` workflow

`.github/workflows/device-hub.yml` deploys the hub. Nobody runs `wrangler
deploy` by hand for a code change.

- A pull request touching `workers/device-hub/**` runs the checks: `npm ci`,
  typecheck, the vitest suite on workerd, and a `wrangler deploy --dry-run` of
  both environments.
- A push to `feat-cmux-next` touching `workers/device-hub/**` runs the checks,
  deploys dev, then production, each followed by a `/v1/health` check. The run
  summary names the deployed version ids.
- A manual run (Actions > device-hub > Run workflow, branch `feat-cmux-next`,
  target `prod` or `dev`) redeploys one environment.

The deploy uploads code and applies the Durable Object migrations in
`wrangler.toml`; it never reads or writes Worker secrets. It uses the
repository's `CLOUDFLARE_API_TOKEN` in the GitHub environments
`cmux-next-development` and `cmux-next-production`, the ones `backend.yml`
deploys the NEXT API with on the same account.

## Manual setup and keys

Setting up an environment's keys (a new environment, or a key rotation), a
deploy while the workflow cannot run, and local `wrangler dev` are internal
operator steps; they live in the private platform repo's device hub deploy
doc. In short, each environment needs:

- `SESSION_KEY` and `TICKET_KEY`: fresh P-256 private JWKs from
  `node scripts/gen-key.mjs`, piped straight into `wrangler secret put` so the
  value never reaches the terminal or a file. Production generates its own
  keys; never copy the dev keys.
- `TURN_KEY_ID` and `TURN_KEY_API_TOKEN`: the Cloudflare Realtime TURN key.
  Without them the Worker still runs: subscribers get `ice: []`, as free users
  do, and the apps fall back to direct paths and the user's own relays.

Rotating `SESSION_KEY` signs every device out (their hub sessions stop
verifying and their sealed Stack tokens stop opening; the apps exchange their
Stack token again). Rotating `TICKET_KEY` invalidates tickets that are less
than 60 s old. Neither touches stored data.

Check that production refuses a Stack development-project token: POST
`{"token": "<dev access token>"}` to `/v1/auth/stack` returns 401 "access
token is not for an accepted project" (the dev hub returns 200 for the same
token).

### Who gets the cmux relay

cmux billing decides, not the hub. Before each ticket and each
`/v1/sessions/:id/ice`, the hub asks the cmux web backend of the user's Stack
project for the plan (`GET /api/billing/plan`) with the user's own Stack
access token, which the hub session carries sealed (`src/billing.ts`). The
relay goes to a personal Pro or Max plan, or a billing team on Team. Free, Go,
and any failed or timed-out lookup (5 s) get `ice: []`; sessions still connect
directly or through the user's own relays. Logs show only the outcome
(`relay entitlement: paid|free|error`), never a token.

`BILLING_ORIGINS` is a plain var, a comma list of
`<stackProjectId>=<https origin>`: production maps the prod project to
`https://cmux.com`; dev also maps the development project to the staging
backend. A project without an entry never gets the relay. To grant a test
account the relay, give it a plan in that backend's billing (on staging, the
admin plan grant), not a hub setting.

### Stack projects

`STACK_PROJECT_IDS` lists the Stack Auth projects whose tokens the hub
accepts. Dev accepts cmux prod and the Stack development project that
DEBUG/tagged builds sign in to; production accepts prod only. Users are keyed
by project, so the same Stack user id in two projects is two hub users.
