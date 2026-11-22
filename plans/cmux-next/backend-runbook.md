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
