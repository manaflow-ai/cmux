# cmux-next machine to coderouter, through the Freestyle edge (development first)

Status: design, 2026-10-07. Owner: hq-6d (cmux-next Chief/backend).

## Gap

The image bakes `/etc/cmux/model-plane.env` (`ANTHROPIC_BASE_URL=https://coderouter.cmux.internal`,
placeholder key). Old cmux Cloud makes that name work with an inline Freestyle TLS rule at create
(`web/services/coderouter/vmModelPlane.ts`). `backend/apps/api` (CloudDO, `cloud-driver.ts`) sends no
`tls` block, so the name has no `/etc/hosts` entry and Claude Code fails with ENOTFOUND.

## Name resolution

CloudDO's create body gets an inline `tls.rules` entry: `domain: coderouter.cmux.internal`,
`source: {}` (this VM only), `destination: { host: <coderouter host>, port: 443 }`, one header
transform. Freestyle writes the hosts block and installs its egress CA at create (rules added after
boot never reach the guest). Rules cascade-delete with the VM.

## Credential (no personal credential on the VM)

The VM never holds a credential; the edge injects it (header values are write-only at Freestyle).
The backend signs a per-machine ES256 JWT with its existing `JWT_PRIVATE_JWK` (public at
`/.well-known/jwks.json`): `iss https://cmux-api/<env>`, `aud coderouter`, `sub vm:<provider vm id>`,
`team_id` and `owner_id` = the creator's Stack user id (coderouter personal scope), `role dev`,
`jti`, lifetime 1 hour. The backend's own verifier requires `aud api`, so this token cannot act on the
backend, and an access token cannot act on coderouter.

coderouter already verifies this exact shape: the chatmux machine verifier
(`chatmuxVmToken.ts`, header `x-chatmux-vm-authorization`, JWKS URL + issuer list from env). Access
is `team-machine`: only accounts the scope shares (`visibility = team`), never private imports, no
account management.

## Lifetime and revoke

The token lives 1 hour. CloudDO refreshes it (`PUT /v5/tls/{ruleId}`, rule found by vmId and domain)
on machine start and when a VM status report arrives and the token is older than 30 minutes. A
paused VM gets no refresh. Delete removes the VM, which deletes the rule; the last token expires
within 1 hour and was never visible to the guest. There is no per-token revocation list.

## Limits and logs

No new per-machine budget in this slice: coderouter account limits apply, and usage is attributed
per machine in coderouter's ledger (`vmId`). The Chief plan's $20/user/day cap is separate work.
Logs carry machine id, rule id, outcome and expiry, never the token or header value
(`redactReason` on every provider error).

## Gate

Development only: on when `ENVIRONMENT` is `development` (or `test`) and `CLOUD_CODEROUTER_EDGE_HOST`
is set. Staging and production send no rule.

## Decisions that need approval

1. coderouter side: set `CODEROUTER_CHATMUX_JWKS_URL` and `CODEROUTER_CHATMUX_ISSUERS` on the
   `cmux-staging` Vercel project (dev Stack project, public, no chatmux config today), so the dev
   backend's machines route there. Shortcut: reuses the chatmux slot (one JWKS URL per deployment,
   ledger labels `chatmux:`). The correct follow-up is a generic machine-issuer verifier in web,
   which needs a main PR.
2. Key reuse instead of a dedicated machine-token key (a dedicated key adds a secret and a protocol
   route).
3. Proof needs one shared (`visibility = team`) Claude account in Lawrence's dev personal scope on
   staging coderouter.
