# cmux-next-native Worker

Signaling, auth, pairing and ICE credentials for the native cmux-next iOS
client. The contract is the "Signaling (Worker)" section of
`native-mobile/ARCHITECTURE.md`.

| | |
| --- | --- |
| URL | https://cmux-next-native.debussy.workers.dev |
| Cloudflare account | Lawrencechen2002@gmail.com's Account, `0c1675e0def6de1ab3a50a4e17dc5656` (pinned in `wrangler.jsonc`) |
| Worker / DO | `cmux-next-native`, Durable Object `HostSignal` (one per `host_id`, WebSocket hibernation) |
| Database | PlanetScale org `cmux`, MySQL database `cmux-next-native`, branch `main`, region `us-west`, PS-10 |
| Schema | `schema.sql` (users, sessions, hosts, pairing_codes, devices) |

## Endpoints

| Method and path | Auth | Result |
| --- | --- | --- |
| `GET /healthz` | none | `{ok}` |
| `POST /v1/auth/apple` `{identity_token, display_name?}` | none | `{user, session_token, expires_at}` |
| `POST /v1/auth/dev` `{email, secret}` | `DEV_LOGIN_SECRET`, `@test.cmux.dev` emails only | `{user, session_token, expires_at}` |
| `GET /v1/me` | session | `{user}` |
| `POST /v1/hosts/register` `{name, platform}` | none (a session token, if sent, pairs immediately) | `{host_id, host_secret, pairing_code, pairing_expires_at}` |
| `POST /v1/hosts/pairing-code` | host secret | `{pairing_code, expires_at}` (invalidates older codes) |
| `POST /v1/pair` `{code}` | session | `{host}` |
| `GET /v1/hosts` | session | `{hosts:[{id,name,platform,created_at,paired_at,online,last_seen}]}` |
| `DELETE /v1/hosts/:id` | session (owner) | `{ok}`; closes that user's phone sockets |
| `GET /v1/ice` | session or host secret | `{iceServers, ttl, expires_at}` (Cloudflare TURN, 24h, plus `stun:stun.cloudflare.com:3478`) |
| `POST /v1/push/register` `{apns_token, environment?, bundle_id?}` | session | `{ok}` (stored only; no sending yet) |
| `GET /v1/signal/:host_id` | WebSocket; `Authorization: Bearer` or `?token=` | host uses `host_secret`, phone uses a session token and must own the host |

Auth is `Authorization: Bearer <token>`. Errors are
`{"error":{"code","message"}}` with a matching HTTP status.

Ids are random 128-bit hex. Session tokens are 256-bit opaque bearers with a
30-day expiry. Only SHA-256 hashes of session tokens and host secrets are
stored. Pairing codes are 8 Crockford base32 symbols shown as `XXXX-XXXX`,
10-minute TTL, single use; input is case-insensitive, dash optional, `O`→`0`,
`I`/`L`→`1`.

### Signal messages

Clients send `{"t":"offer"|"answer"|"ice"|"bye","sid","sdp"?,"candidate"?}`.

- Phone → host: the DO records the `sid` against the phone socket and forwards
  with `from:"phone"` and `user_id`. With no host socket the phone gets
  `{"t":"error","code":"host_offline","sid"}`.
- Host → phone: routed by `sid`, stamped `from:"host"`. An unknown sid returns
  `{"t":"error","code":"unknown_sid","sid"}`.
- The DO sends phones `{"t":"presence","online"}` on connect and when the host
  connects or drops; on host drop each phone also gets `bye` for its sids, and
  on phone drop the host gets `bye` with `reason:"phone_disconnected"`.
- A newer host socket replaces the older one (close code 4000). Unpair closes
  phone sockets with 4003.
- Keepalive: send exactly `{"t":"ping"}`; the hibernation auto-response
  replies `{"t":"pong"}` without waking the DO.

## Secrets (names only)

Set with `wrangler secret put`, values piped and never printed.

| Name | Source |
| --- | --- |
| `DB_HOST`, `DB_USERNAME`, `DB_PASSWORD` | PlanetScale password `cmux-next-native-worker` (role readwriter, branch `main`) |
| `TURN_KEY_ID` | 1Password `Cloudflare TURN Server API Key` (Shared vault), "Turn Token ID" in notes |
| `TURN_KEY_API_TOKEN` | same item, `credential` field |
| `DEV_LOGIN_SECRET` | generated; local copy at `~/.secrets/cmux-next-native-dev-login` (mode 600) |

Var: `APPLE_AUDIENCES` (comma list, default
`dev.cmux.next.native,dev.cmux.next.native.dev`).

## Develop and deploy

```bash
cd native-mobile/worker
npm install
npm run typecheck
npx wrangler deploy
```

Schema changes need DDL rights, which the Worker password does not have.
Create a short-lived admin password, run `scripts/apply-schema.mjs` with
`DB_HOST`/`DB_USERNAME`/`DB_PASSWORD` from it, then delete the password:

```bash
pscale password create cmux-next-native main schema-apply-tmp --role admin --ttl 1h --org cmux --format json > /tmp/admin.json
DB_HOST=$(jq -r .access_host_url /tmp/admin.json) DB_USERNAME=$(jq -r .username /tmp/admin.json) \
  DB_PASSWORD=$(jq -r .plain_text /tmp/admin.json) node scripts/apply-schema.mjs
pscale password delete cmux-next-native main "$(jq -r .id /tmp/admin.json)" --org cmux --force && rm /tmp/admin.json
```

## Test

```bash
node test/e2e.mjs            # Node 22+, against the deployed URL
BASE_URL=https://... DEV_LOGIN_SECRET=... node test/e2e.mjs
```

It runs dev login, register host, pairing-code rotation, pair (single use),
host list and presence, `/v1/ice` (asserts a `turn:` URL), host/phone
WebSockets with offer/answer/ice round trip, `host_offline`, `unknown_sid`,
ownership checks and unpair.
