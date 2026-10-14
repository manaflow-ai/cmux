# cmux-next mobile backend

Cloudflare Worker `cmux-next-mobile` with a `SignalRoom` Durable Object for
WebRTC signaling and PlanetScale MySQL for storage. The wire contract is
`../PROTOCOL.md` §5 and §6.

Deployed at `https://cmux-next-mobile.debussy.workers.dev` (Cloudflare account
`Lawrencechen2002@gmail.com's Account`, `0c1675e0def6de1ab3a50a4e17dc5656`).
Database: PlanetScale org `cmux`, MySQL database `cmux-next-mobile` (PS_10,
us-west).

## Layout

| Path | What |
| --- | --- |
| `src/index.ts` | Worker entry, exports `SignalRoom` |
| `src/app.ts` | Hono router, `/v1` mount, error envelope, 503 when the DB is missing |
| `src/routes/` | `auth`, `oauth`, `hosts` (pairing), `ice`, `signal` |
| `src/signal/room.ts` | Durable Object per user (WebSocket Hibernation API) |
| `src/signal/frames.ts` | Frame validation and routing rules |
| `src/repo/` | `Repo` interface, `PlanetScaleRepo`, `MemoryRepo` (tests) |
| `migrations/*.sql` | Vitess-compatible schema (no foreign keys) |
| `scripts/migrate.ts` | Applies migrations once each, tracked in `schema_migrations` |
| `scripts/configure-planetscale.sh` | Creates the database, sets Worker secrets, migrates |

## Endpoints (base `/v1`)

All bodies are JSON. Errors are `{error:{code,message}}`.

| Method | Path | Auth | Notes |
| --- | --- | --- | --- |
| GET | `/health` | - | `{ok, db, email, turn, auth, stack, stackDev, apple, oauth:{github,google}}` |
| POST | `/auth/stack` | - | `{accessToken, projectId}` -> `Tokens`. **Primary sign-in**, see Stack Auth below |
| POST | `/auth/email/start` | - | `{email}` -> `{nonce}`; mails a 6-char code (A-Z, 2-9, no 0/O/1/I/L). 10 min expiry, 5 codes per email per hour |
| POST | `/auth/email/verify` | - | `{email, code, nonce}` -> `Tokens`; 5 attempts per code, single use |
| POST | `/auth/test` | - | `{email, secret}` -> `Tokens`; only when `TEST_LOGIN_SECRET` is set (else 404), see below |
| POST | `/auth/apple` | - | `{identityToken, nonce, fullName?}` -> `Tokens`; 501 `unsupported` unless `APPLE_AUDIENCES` is set (off in production) or when `nonce` is missing. RS256 against Apple JWKS; `nonce` (raw) must match the token's `nonce` claim (SHA-256 hex or raw) |
| GET | `/auth/oauth/:provider/start?redirect=&code_challenge=&code_challenge_method=S256` | - | `github` or `google`; 501 `unsupported` without client id/secret. `redirect` must use a scheme in `OAUTH_REDIRECT_SCHEMES`. PKCE S256 required |
| GET | `/auth/oauth/:provider/callback` | - | 302 to `redirect?code=<one-time>` or `redirect?error=` |
| POST | `/auth/oauth/exchange` | - | `{code, codeVerifier}` -> `Tokens` |
| POST | `/auth/refresh` | - | `{refreshToken}` -> `Tokens`; rotates. A retry of the immediately previous token within 30 s returns the same pair (the successor is derived by HMAC from the old token, the access token is signed at the rotation time); any other reuse revokes the whole family |
| POST | `/auth/logout` | user | `{refreshToken}` -> `{}`; revokes its family |
| GET | `/me` | user | `{user}` |
| DELETE | `/me` | user | deletes the user, identities, tokens, hosts; closes their sockets |
| POST | `/hosts/pair/start` | - | `{name, os}` -> `{deviceCode, userCode:"ABCD-EFGH", expiresAt, interval:5}`; 10 min |
| POST | `/hosts/pair/poll` | - | `{deviceCode}` -> `{status:"pending"}` / `{status:"approved", hostId, hostToken, userId, approverEmail}` (token returned once; host should confirm `approverEmail`); 404 unknown, 410 expired or already claimed |
| POST | `/hosts/pair/approve` | user | `{userCode}` (case and dash insensitive) -> `{host}`; 403 `account has no email` when the approver has no email; 10 attempts per user per 10 min |
| GET | `/hosts` | user | `{hosts:[{id,name,os,online,lastSeenAt,createdAt}]}`; `online` comes from the SignalRoom |
| DELETE | `/hosts/:id` | user | `{}`; disconnects the host socket and sends `presence` with `online:false, removed:true` |
| GET | `/ice` | user or host | `{iceServers, ttl:3600}`; Cloudflare STUN always, TURN when configured. Users need at least one paired host (403); 300 per hour per sign-in family (JWT `fam`) and per host |
| GET | `/signal` | user or host | WebSocket; `Authorization: Bearer`. `?token=` still works but is deprecated |

Revoked sign-ins: an access token whose `fam` family is revoked (logout,
refresh reuse) is refused on every route (401 "session revoked"). Each Worker
isolate caches family liveness for 30 s and learns its own revocations
immediately; `/signal` and `/ice` also check the SignalRoom's revocation list,
which is immediate. Every 429 sends `Retry-After`.

Tokens: access token is an HS256 JWT (15 min, `sub`=userId, `typ`="user",
`iss`="cmux-next-mobile", secret `JWT_SECRET`). Refresh tokens (`rt_...`,
60 days), host tokens (`ht_...`), device codes, OAuth one-time codes are opaque
and stored as SHA-256. Email codes are stored as HMAC-SHA256 keyed by
`JWT_SECRET`. Sign-ins with a verified email link to an existing user with
the same email.

### Signaling details

One `SignalRoom` per user id. Behaviour beyond PROTOCOL.md:

- `from` is stamped by the server: the host id for frames from a host, the
  peer id for frames from a phone. Phones address hosts by `hostId`, hosts
  address phones by `peerId`.
- Offers go phone -> host only, answers host -> phone only; candidates and
  byes go either way. Violations get `{"type":"error","code":"forbidden"}`.
- Error codes: `host_offline`, `peer_offline`, `forbidden`, `bad_request`.
  Errors echo `sessionId` when the frame had one.
- Every phone -> host frame is stamped with the phone's sign-in `family`
  (JWT `fam`, or `null`); phone-supplied values are overwritten.
- Revocations are stored in the room for 30 min and replayed to hosts in
  `welcome.revokedFamilies`. Revoked phones cannot connect, and a frame from
  one closes it with 4005.
  Revoking a family (logout, refresh reuse, account delete) sends hosts
  `{"type":"revoked","family"}` and closes that family's phones with 4005
  (account delete closes everything with 4004 instead).
- Phone sockets close with 4002 when their access token expires (the room
  keeps an alarm at the earliest expiry); refresh and reconnect.
- `{"type":"ping"}` gets `{"type":"pong"}` without waking the object.
- A host reconnecting replaces its old socket (close code 4001). Deleted
  hosts are closed with 4003, deleted accounts with 4004.
- `presence` goes to phones when a host connects or its last socket closes.
- `hosts.last_seen_at` is written on connect, on disconnect and at most once
  a minute while the host sends frames.
- Frames are JSON text up to 64 KiB.

## Secrets and vars

| Name | Kind | Purpose |
| --- | --- | --- |
| `JWT_SECRET` | secret | Access tokens, OAuth state, email code HMAC. Set. Without it auth routes return 503 |
| `DATABASE_HOST`, `DATABASE_USERNAME`, `DATABASE_PASSWORD` | secret | PlanetScale. Without them DB routes return 503 `database not configured` |
| `TURN_KEY_ID`, `TURN_KEY_API_TOKEN` | secret | Cloudflare Realtime TURN |
| `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` | secret | GitHub OAuth |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | secret | Google OAuth |
| `TEST_LOGIN_SECRET` | secret | Enables `POST /v1/auth/test` |
| `TEST_LOGIN_EMAIL_DOMAINS` | var | Domains `/auth/test` may sign in (default `test.cmux.dev`) |
| `EMAIL_FROM` | var | Sender address for codes; empty disables email sign-in (503) |
| `STACK_PROJECT_ID` | var | Stack Auth prod project (always accepted, links by verified email) |
| `STACK_DEV_PROJECT_ID`, `DEV_STACK_ENABLED` | var | Stack dev project, accepted only when `DEV_STACK_ENABLED = "true"`. Production: `"false"`, dev project unset; only for a separate dev deployment |
| `APPLE_AUDIENCES` | var | Empty in production (direct Apple sign-in off); to enable: `dev.cmux.next.drawer,dev.cmux.next.tabs` |
| `OAUTH_REDIRECT_SCHEMES` | var | App schemes OAuth may redirect to |

Bindings: `SIGNAL_ROOM` (Durable Object, SQLite class), `EMAIL`
(`send_email`), `AUTH_LIMITER` (30 requests/min per IP on unauthenticated
auth and pairing routes).

Set a secret without echoing it:

```sh
printf '%s' "$VALUE" | npx wrangler secret put NAME
```

### Stack Auth (primary)

The app signs in with Stack Auth exactly like cmux iOS on TestFlight, then
calls `POST /v1/auth/stack {accessToken, projectId}` with the Stack access
token. Production accepts only the prod project
`9790718f-14cd-4f7e-824d-eaf527a82b82`. A separate dev deployment can also
accept the dev project `454ecd03-1db2-4050-845e-4ce5b0cd9895` with
`STACK_DEV_PROJECT_ID` and `DEV_STACK_ENABLED = "true"`. It verifies the ES256 (or RS256) signature against
`https://api.stack-auth.com/api/v1/projects/<projectId>/.well-known/jwks.json`
(cached 10 min, refetched on an unknown `kid`), requires
`iss = https://api.stack-auth.com/api/v1/projects/<projectId>`,
`aud = <projectId>`, an unexpired `exp` (60 s skew) and `is_anonymous != true`.
The identity is `("stack:<projectId>", <Stack user id>)`; email and name come
from the claims, or from `GET /api/v1/users/me` (headers `x-stack-access-token`,
`x-stack-project-id`, `x-stack-access-type: client`) when missing. Only the prod
project links to an existing account by verified email.

Why production keeps `DEV_STACK_ENABLED = "false"`: anyone can create users in the dev Stack
project, so dev sign-ins get their own accounts with no email (never linked to
or claiming a prod account by email). They can still pair hosts and use
TURN under the `/ice` limits. Set it to `"false"` and redeploy once Debug
builds use the prod project. Email code, Apple and OAuth
sign-in remain in the code but are disabled until configured.

### Test sign-in

`POST /v1/auth/test {email, secret}` issues normal tokens. It exists only
while `TEST_LOGIN_SECRET` is set, compares in constant time, and accepts only
emails in `TEST_LOGIN_EMAIL_DOMAINS` (default `test.cmux.dev`), so a leaked
secret cannot take over real accounts. Enable it for automated simulator
runs. It is set on the deployed Worker; the value is stored on Aziz's Mac at
`~/.secrets/cmux-next-mobile-test-login` (mode 600). Rotate or remove:

```sh
(umask 077; openssl rand -base64 32 | tr -d '\n' > ~/.secrets/cmux-next-mobile-test-login)
npx wrangler secret put TEST_LOGIN_SECRET < ~/.secrets/cmux-next-mobile-test-login
npx wrangler secret delete TEST_LOGIN_SECRET
```

### TURN

Cloudflare dashboard > Realtime > TURN Server > Create (or pick) a TURN key.
Copy the key id and its API token, then:

```sh
printf '%s' "<turn key id>"    | npx wrangler secret put TURN_KEY_ID
printf '%s' "<turn api token>" | npx wrangler secret put TURN_KEY_API_TOKEN
```

`/v1/ice` then calls `POST https://rtc.live.cloudflare.com/v1/turn/keys/{TURN_KEY_ID}/credentials/generate-ice-servers`
with `{ttl:86400}` and appends the returned TURN servers. A TURN API failure
falls back to STUN only.

### Email

Email sign-in uses Cloudflare Email Sending (beta, Workers Paid plan) through
the `EMAIL` `send_email` binding. The sender must be on a domain that uses
Cloudflare DNS and is onboarded in the dashboard: Compute > Email Service >
Email Sending > Onboard Domain (adds `cf-bounce` MX/SPF, DKIM and DMARC
records). Then set the sender in `wrangler.toml` and deploy:

```toml
EMAIL_FROM = "login@your-domain.example"
```

### PlanetScale

```sh
/opt/homebrew/bin/pscale auth login
scripts/configure-planetscale.sh --org cmux --dry-run
scripts/configure-planetscale.sh --org cmux --yes
```

The script creates database `cmux-next-mobile` (MySQL, `us-west`, the
cheapest MySQL cluster size unless `PSCALE_CLUSTER_SIZE` is set; this is
billed), creates a `readwriter` password for the Worker and stores it in the
three secrets, then migrates with a 1-hour `admin` password. To migrate by
hand: `DATABASE_HOST=... DATABASE_USERNAME=... DATABASE_PASSWORD=... npm run migrate`.

## Logging

Invocation logs are off (`[observability.logs] invocation_logs = false`), so
request URLs, including a deprecated `/v1/signal?token=`, are never recorded.
Console logs carry only error messages, never tokens or request bodies.

## Develop, test, deploy

```sh
npm install          # .npmrc sets legacy-peer-deps (npm arborist bug with vitest peers)
npm test             # vitest in the Workers runtime (@cloudflare/vitest-plugin)
npm run typecheck
npm run types        # regenerate worker-configuration.d.ts after wrangler.toml changes
npx wrangler deploy
curl -s https://cmux-next-mobile.debussy.workers.dev/v1/health
```

Tests use `REPO_BACKEND=memory` (set only in `vitest.config.ts`) and cover
Stack, email, test, Apple and OAuth sign-in, refresh rotation and reuse, `/me`,
pairing, `/ice` with and without TURN, and signaling between real phone and
host WebSockets through the Durable Object, including presence.
