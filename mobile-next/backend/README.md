# cmux-next-mobile-native backend

Cloudflare Worker for the native cmux-next iOS app: accounts, Mac pairing,
ICE servers and WebRTC signaling. Storage is PlanetScale MySQL. The contract is
[`../docs/API.md`](../docs/API.md).

- Worker: `cmux-next-mobile-native`, account `0c1675e0def6de1ab3a50a4e17dc5656`
  (pinned by `account_id` in `wrangler.jsonc`).
- URL: https://cmux-next-mobile-native.debussy.workers.dev
- Database: PlanetScale org `cmux`, database `cmux-next-mobile-native`, branch
  `main`, AWS `us-west` (us-west-2), size PS-10.

## Layout

| Path | What |
| --- | --- |
| `src/index.ts` | Worker entry; wires the database and the `SignalRoom` stub. |
| `src/app.ts` | Routes and handlers (auth, me, pairing, hosts, ICE, signal upgrade). |
| `src/signal.ts` | `SignalRoom` Durable Object, one per user, WebSocket hibernation. |
| `src/jwt.ts`, `src/apple.ts`, `src/crypto.ts` | Access tokens, Apple identity tokens, codes and hashing. |
| `src/db.ts` | PlanetScale driver plus `sql-escaper` (the v2 driver does not bind parameters). |
| `src/email.ts`, `src/ice.ts` | Login code email and Cloudflare TURN credentials. |
| `migrations/` | Ordered SQL migrations. |
| `scripts/migrate.ts`, `scripts/smoke.ts` | Migration runner and live smoke test. |
| `test/` | vitest unit tests. |

## Develop and test

```bash
bun install
bun run typecheck
bun run test
```

## Deploy

```bash
bunx wrangler@4 deploy
```

## Migrations

Migrations run with the fetch driver, so no local `mysql` client is needed.
Use a short-lived admin password (the Worker's password is `readwriter` and
cannot run DDL), then delete it:

```bash
pscale password create cmux-next-mobile-native main migrate --org cmux --role admin --ttl 1h --format json
DATABASE_HOST=... DATABASE_USERNAME=... DATABASE_PASSWORD=... bun scripts/migrate.ts
pscale password delete cmux-next-mobile-native main <password-id> --org cmux --force
```

Applied files are recorded in `schema_migrations`.

## Secrets

Set with `bunx wrangler@4 secret put NAME` (value on stdin). Never commit values.

| Name | Required | Notes |
| --- | --- | --- |
| `JWT_SECRET` | yes | HS256 key for access tokens. |
| `DATABASE_HOST` | yes | PlanetScale host. |
| `DATABASE_USERNAME` | yes | `readwriter` password for the Worker. |
| `DATABASE_PASSWORD` | yes | |
| `TEST_LOGIN_CODE` | for test accounts | Code for the addresses in `TEST_LOGIN_EMAILS`. A local copy lives in `~/.secrets/cmux-next-mobile-native-test-login`. |
| `TURN_KEY_ID` | optional | Cloudflare Realtime TURN key. Without it `/v1/ice` returns STUN only. |
| `TURN_KEY_API_TOKEN` | optional | Picked up on the next request after it is set. |

Plain vars in `wrangler.jsonc`: `APPLE_AUDIENCE` (comma list of bundle ids),
`EMAIL_FROM`, `TEST_EMAIL_DOMAIN`, `TEST_LOGIN_EMAILS` (comma list of exact test
addresses allowed to use `TEST_LOGIN_CODE`; other test-domain addresses get
`503 email_unavailable`).

## Email

Codes are sent through the Cloudflare Email Service `send_email` binding
(`SEND_EMAIL`). The account has no onboarded sending domain yet, so the binding
is commented out in `wrangler.jsonc` and `/v1/auth/email/start` returns
`503 email_unavailable` for non-test addresses. To enable it, onboard a domain
(`bunx wrangler@4 email sending enable <domain>` and its DNS records), set
`EMAIL_FROM` to an address on that domain, uncomment the binding and deploy.

## Smoke test

```bash
bun scripts/smoke.ts                     # default URL above
bun scripts/smoke.ts http://localhost:8787
```

It signs in as `smoke-native@test.cmux.dev` (must be in `TEST_LOGIN_EMAILS`),
exercises `/v1/me`, refresh rotation and reuse detection, pairing start, claim,
Mac approval and rejection, one-time token delivery, `/v1/hosts` (offline and online),
`/v1/hosts/register`, `/v1/ice`, a two-peer WebSocket relay with presence,
`peer_offline` and ping, then deletes the host and the account (and checks the
deleted account cannot connect to signaling).
