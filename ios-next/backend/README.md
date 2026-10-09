# cmux-next mobile backend

Cloudflare Worker `cmux-next-mobile` with a `SignalRoom` Durable Object for
WebRTC signaling and PlanetScale MySQL for storage. The wire contract is
`../PROTOCOL.md` §5 and §6.

Deployed at `https://cmux-next-mobile.cmux-presence-worker.workers.dev`
(account `Aziz@manaflow.ai's Account`, `f6dc2896a972b2d492ec89b1548b74db`).

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
| GET | `/health` | - | `{ok, db, email, turn, auth, oauth:{github,google}}` |
| POST | `/auth/email/start` | - | `{email}` -> `{nonce}`; mails a 6-char code (A-Z, 2-9, no 0/O/1/I/L). 10 min expiry, 5 codes per email per hour |
| POST | `/auth/email/verify` | - | `{email, code, nonce}` -> `Tokens`; 5 attempts per code, single use |
| POST | `/auth/test` | - | `{email, secret}` -> `Tokens`; only when `TEST_LOGIN_SECRET` is set (else 404), see below |
| POST | `/auth/apple` | - | `{identityToken, fullName?}` -> `Tokens`; RS256 against Apple JWKS, `aud` in `APPLE_AUDIENCES` |
| GET | `/auth/oauth/:provider/start?redirect=&code_challenge=` | - | `github` or `google`; 501 `unsupported` without client id/secret. `redirect` must use a scheme in `OAUTH_REDIRECT_SCHEMES`. Optional PKCE S256 challenge |
| GET | `/auth/oauth/:provider/callback` | - | 302 to `redirect?code=<one-time>` or `redirect?error=` |
| POST | `/auth/oauth/exchange` | - | `{code, codeVerifier?}` -> `Tokens`; verifier required when start had a challenge |
| POST | `/auth/refresh` | - | `{refreshToken}` -> `Tokens`; rotates. Reusing a rotated token revokes the whole family |
| POST | `/auth/logout` | user | `{refreshToken}` -> `{}`; revokes its family |
| GET | `/me` | user | `{user}` |
| DELETE | `/me` | user | deletes the user, identities, tokens, hosts; closes their sockets |
| POST | `/hosts/pair/start` | - | `{name, os}` -> `{deviceCode, userCode:"ABCD-EFGH", expiresAt, interval:5}`; 10 min |
| POST | `/hosts/pair/poll` | - | `{deviceCode}` -> `{status:"pending"}` / `{status:"approved", hostId, hostToken, userId}` (token returned once); 404 unknown, 410 expired or already claimed |
| POST | `/hosts/pair/approve` | user | `{userCode}` (case and dash insensitive) -> `{host}` |
| GET | `/hosts` | user | `{hosts:[{id,name,os,online,lastSeenAt,createdAt}]}`; `online` comes from the SignalRoom |
| DELETE | `/hosts/:id` | user | `{}`; disconnects the host socket and sends `presence` with `online:false, removed:true` |
| GET | `/ice` | user or host | `{iceServers, ttl:86400}`; Cloudflare STUN always, TURN when configured |
| GET | `/signal` | user or host | WebSocket; token in `Authorization` or `?token=` |

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
| `APPLE_AUDIENCES` | var | `dev.cmux.next.drawer,dev.cmux.next.tabs` |
| `OAUTH_REDIRECT_SCHEMES` | var | App schemes OAuth may redirect to |

Bindings: `SIGNAL_ROOM` (Durable Object, SQLite class), `EMAIL`
(`send_email`), `AUTH_LIMITER` (30 requests/min per IP on unauthenticated
auth and pairing routes).

Set a secret without echoing it:

```sh
printf '%s' "$VALUE" | npx wrangler secret put NAME
```

### Test sign-in

`POST /v1/auth/test {email, secret}` issues normal tokens. It exists only
while `TEST_LOGIN_SECRET` is set, compares in constant time, and accepts only
emails in `TEST_LOGIN_EMAIL_DOMAINS` (default `test.cmux.dev`), so a leaked
secret cannot take over real accounts. Enable it for automated simulator
runs, and delete it when done:

```sh
openssl rand -base64 32 | tr -d '\n' | npx wrangler secret put TEST_LOGIN_SECRET
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
scripts/configure-planetscale.sh --dry-run
scripts/configure-planetscale.sh --yes
```

The script creates database `cmux-next-mobile` (MySQL, `us-west`, the
cheapest MySQL cluster size unless `PSCALE_CLUSTER_SIZE` is set; this is
billed), creates a `readwriter` password for the Worker and stores it in the
three secrets, then migrates with a 1-hour `admin` password. To migrate by
hand: `DATABASE_HOST=... DATABASE_USERNAME=... DATABASE_PASSWORD=... npm run migrate`.

## Develop, test, deploy

```sh
npm install          # .npmrc sets legacy-peer-deps (npm arborist bug with vitest peers)
npm test             # vitest in the Workers runtime (@cloudflare/vitest-plugin)
npm run typecheck
npm run types        # regenerate worker-configuration.d.ts after wrangler.toml changes
npx wrangler deploy
curl -s https://cmux-next-mobile.cmux-presence-worker.workers.dev/v1/health
```

Tests use `REPO_BACKEND=memory` (set only in `vitest.config.ts`) and cover
email, test, Apple and OAuth sign-in, refresh rotation and reuse, `/me`,
pairing, `/ice` with and without TURN, and signaling between real phone and
host WebSockets through the Durable Object, including presence.
