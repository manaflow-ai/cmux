# Backend runbook

Operator procedures for the cmux-next API Worker (backend/apps/api). Each section names the decision
it implements. Never print a secret; keep new secret files in ~/.secrets with mode 600 and set Worker
secrets from stdin (`wrangler secret put NAME --env <env> < file`). Staging and production signing
keys are Lawrence's.

## Link signing key rotation (CLOUD-LINK-FOLLOWUPS 1 and 2, accepted 2026-10-05)

`CLOUD_LINK_SIGNING_KEYS` is `{active, keys: {kid: private Ed25519 JWK}, published_at?: {kid: ms}}`,
at most 2 kids. Bound VMs hold the public keyset from bind and refetch it from the public
`GET /v1/cloud/keyset` on an unknown kid and once a day. A kid signs only 24 h after its
`published_at` (backend/apps/api/src/link-token.ts `signingKid`), so every VM holds a kid before the
first token signed with it arrives.

Rotation (two deploys, at least 24 h apart):

1. Make the new private key and a new kid in a mode-600 file. Never reuse a kid.
2. Write the two-kid secret: keep the old kid as `active`, add the new kid, and set `published_at`
   for both kids. The new kid's `published_at` is the time of THIS deploy (when the secret that first
   holds the kid goes live), never earlier. The old kid's value is any past time.
3. `wrangler secret put CLOUD_LINK_SIGNING_KEYS --env <env>` from stdin. Check
   `GET /v1/cloud/keyset` shows both kids and a new version.
4. At least 24 h later: set `active` to the new kid (same two kids, same `published_at`) and put the
   secret again. Mint uses the new kid; until its 24 h pass it falls back to the old kid by itself.
5. After the longest link-token lifetime (5 minutes) plus VM refetch slack (1 day), remove the old
   kid: write the one-kid secret (keep the new kid's `published_at`) and put it.

Do not:

- Replace a lone kid with another lone kid. A lone kid without `published_at` signs at once, and
  bound VMs refuse its tokens until they refetch (up to a day). Always rotate through the two-kid step.
- Set `published_at` before the deploy that publishes the kid. The 24 h lead is then lost.

When no kid is ready (both kids published less than 24 h ago, or a future `published_at`), every
`cloud.machine.link_token` answers `owner.unreachable` (retryable) and nothing is minted. Fix the
secret; clients retry by themselves.

Check after each step: `GET /v1/cloud/keyset` (200, the expected kids and version), one link_token
mint on development, and the Worker logs show no `owner.unreachable` from mint.

## Cloudflare Realtime TURN credentials (cmux-next iOS B2)

The API Worker mints short-lived Cloudflare Realtime ICE credentials for an authenticated
install. The credentials are Worker secrets, never `vars` in `backend/apps/api/wrangler.jsonc`,
and the deploy helper does not copy them from the local environment. Configure each environment
explicitly before asking a tagged Mac/phone pair to exercise a relayed path.

### Configure an environment

Use the Cloudflare Realtime TURN key id and the API token authorized to mint credentials for that
key. Keep each value in a mode-600 file under `~/.secrets`; do not put either value in git, a
wrangler config, CI logs, or an iOS build. The account is the cmux Cloudflare account used by the
API Worker (`CLOUDFLARE_ACCOUNT_ID` is set by `backend/scripts/deploy-worker.sh`).

For each target (`development`, then `staging` after development passes, and `production` only
after the normal release authorization), set both secrets from stdin:

```bash
cd backend/apps/api
umask 077
read -r turn_key_id < ~/.secrets/cmux-turn-key-id-<env>
read -r turn_api_token < ~/.secrets/cmux-turn-api-token-<env>
printf '%s' "$turn_key_id" | bunx wrangler secret put CLOUDFLARE_TURN_KEY_ID --env <env>
printf '%s' "$turn_api_token" | bunx wrangler secret put CLOUDFLARE_TURN_KEY_API_TOKEN --env <env>
unset turn_key_id turn_api_token
```

Replace `<env>` with one complete environment name before running a command; do not use a
production key in development. Confirm only the secret names (never values):

```bash
bunx wrangler secret list --env <env> | jq -r '.[].name' | grep -E '^CLOUDFLARE_TURN_KEY_(ID|API_TOKEN)$'
```

If either secret is missing, the endpoint deliberately returns `503 signal.turn_unavailable` and
the carrier falls back to credential-free Cloudflare STUN. This fallback is useful for local P2P
tests but is not TURN deployment evidence.

### Probe the Worker without printing credentials

Use a short-lived authenticated install bearer for the selected environment. The probe prints only
the status, expiry, and URL schemes; it never prints the username or credential returned by
Cloudflare:

```bash
api_origin='https://cmux-api-development.debussy.workers.dev'
curl --fail-with-body -sS -X POST "$api_origin/v1/realtime/turn" \
  -H "Authorization: Bearer $CMUX_INSTALL_TOKEN" \
  -H 'content-type: application/json' -d '{}' |
  jq '{ok, expires_at: .value.expires_at, schemes: [.value.ice_servers[]?.urls[]? | split(":")[0]] | unique}'
```

Pass criteria are `ok: true`, an `expires_at` roughly 900 seconds ahead, and both `stun` and
`turn`/`turns` schemes. A `401` means the bearer or environment is wrong; `429` means the per-
identity `MOBILE_TURN_LIMIT` was reached; `503 signal.turn_unavailable` means the secrets or the
Cloudflare provider response are unavailable. Repeat the same probe against staging and production
only with their own authenticated install and approved origin.

### Verify the actual B2 relay path

The HTTP probe proves minting only. B2's carrier obtains the same credentials through the HostDO
`read signal.turn_credentials` path, so the tagged pair must also verify that path:

1. Start the tagged Mac host and iPhone build from the exact same source tag; confirm the Mac's
   `WebRTCAcceptor` is attached to its host socket and the phone is paired to that host.
2. On the phone's development menu, force `iceTransportPolicy = relay`, open a terminal, and
   confirm the route badge is `turn`. Capture the path classification and a small echo result;
   do not treat a `p2p` badge as relay evidence.
3. Clear the force-relay switch, repeat on the same LAN, and confirm `p2p`. Then move the phone to
   cellular (or shape UDP) and verify a TURN candidate is selected or that the session reconnects
   after ICE restart. Record the carrier's `pathChanged`/resume result and the Worker probe's
   timestamp in the B2/D2 device artifact.
4. Revoke or remove the development TURN secrets after an isolated test only if the environment is
   not shared; otherwise leave them in place and rotate the API token through the Cloudflare key
   procedure. Never paste credentials into bug reports or artifacts.

The focused Worker tests exercise request authentication, identity rate limiting, response
normalization, and the missing-secret failure. They cannot prove Cloudflare reachability or an ICE
relay. The remaining B2 blockers are therefore a real development deployment with both secrets,
the HTTP and HostDO probes above, and tagged Mac/iPhone relay/roam evidence (see
`plans/cmux-next/ios-next/b2-webrtc.md` section 12 and `d3-dogfood.md` section 2.1).
