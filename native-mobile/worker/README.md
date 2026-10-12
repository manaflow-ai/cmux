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
| `POST /v1/push/register` `{apns_token, environment?, bundle_id?, push_to_start_token?, live_activities?, notifications?}` | session | `{ok, device_id}` |
| `GET /v1/push/status` | session | `{configured, key_id, team_id}` (APNs key present) |
| `POST /v1/hosts/:id/events` | host secret | attention event → APNs alert per device; `kind:"activity"` → Live Activity start/update/end. `{ok, sent, devices, apns}` or `{duplicate:true}` |
| `POST /v1/push/live-activity` `{device_token, host_id, surface, activity_id, push_token?, started_at?, ended?}` | session | `{ok}` (the app reports a Live Activity's update token or its end) |
| `POST /v1/push/action` `{host_id, event_id, action: reply\|option\|allow\|deny, text?, key?}` | session | `202 {delivered}`; `409 host_offline`. Relayed to the host socket as `{"t":"action","user_id","action":{event_id,surface,type,text,key}}` |
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

## Push

The host (`AttentionPublisher`, in `cmux-native-host run` and the Mac app)
posts attention events `{id, kind: question|permission|done|error|notice,
title, body, surface, workspace, agent, options[{key,label}], quote,
created_at}` and Live Activity updates `{kind:"activity", state:
working|needs_input|done, surface, agent, workspace, started_at}`.

- Alerts: APNs `alert` push to every device of the host's owner with
  `notifications` on. `aps.category` is `FEED_QUESTION`, `FEED_PERMISSION`,
  `FEED_DONE` or `FEED_GENERIC`; `thread-id` is `host-<id>-surface-<n>`;
  `mutable-content: 1` so the Notification Service Extension adds the agent,
  workspace and prompt quote and, for a numbered menu, a per-menu category
  with one button per choice. The `cmux` block carries `host_id`,
  `event_id`, `kind`, `surface`, `workspace`, `agent`, `options`, `quote`.
- Live Activities (iOS 17.2+): `working` sends push-to-start
  (`attributes-type: AgentActivityAttributes`, topic
  `<bundle>.push-type.liveactivity`) when the device has a push-to-start
  token and no live activity for that surface; later states update or end it
  through the token the app reports to `/v1/push/live-activity`.
- Per-user push state (push-to-start tokens, switches, started activities,
  posted event ids for answering) lives in the `UserPush` Durable Object;
  device tokens stay in PlanetScale `devices`.
- Provider auth: ES256 JWT (`kid` = `APNS_KEY_ID`, `iss` = `APNS_TEAM_ID`),
  reused for 40 minutes. Without `APNS_KEY_P8`/`APNS_KEY_ID` every send is a
  logged no-op (`apns not configured ...`) and `/v1/push/status` reports
  `configured: false`. Dead tokens (410, BadDeviceToken) are dropped.

## Secrets (names only)

Set with `wrangler secret put`, values piped and never printed.

| Name | Source |
| --- | --- |
| `DB_HOST`, `DB_USERNAME`, `DB_PASSWORD` | PlanetScale password `cmux-next-native-worker` (role readwriter, branch `main`) |
| `TURN_KEY_ID` | 1Password `Cloudflare TURN Server API Key` (Shared vault), "Turn Token ID" in notes |
| `TURN_KEY_API_TOKEN` | same item, `credential` field |
| `DEV_LOGIN_SECRET` | generated; local copy at `~/.secrets/cmux-next-native-dev-login` (mode 600) |
| `APNS_KEY_P8` | APNs auth key (.p8 PEM) for team 7WLXT3NR37 with the Apple Push Notifications service capability (1Password) |
| `APNS_KEY_ID` | that key's 10-character key id |

Vars: `APPLE_AUDIENCES` (comma list, default
`dev.cmux.next.native,dev.cmux.next.native.dev`), `APNS_TEAM_ID`
(`7WLXT3NR37`).

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
npm test                     # APNs JWT signing and payload builders (no network)
node test/e2e.mjs            # Node 22+, against the deployed URL
BASE_URL=https://... DEV_LOGIN_SECRET=... node test/e2e.mjs
```

It runs dev login, register host, pairing-code rotation, pair (single use),
host list and presence, `/v1/ice` (asserts a `turn:` URL), host/phone
WebSockets with offer/answer/ice round trip, `host_offline`, `unknown_sid`,
ownership checks and unpair.
