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

The token lives 1 hour. CloudDO keeps a due time per machine (`cloud_coderouter_edge`, times only)
and its alarm replaces the token (`PUT /v5/tls/{ruleId}`, rule found by vmId and domain) 30 minutes
after each mint while the machine runs; a failure retries after 60 s. A paused machine is parked
(no refresh); a start replaces the token at once. Delete removes the VM, which deletes the rule;
the last token expires within 1 hour and was never visible to the guest. There is no per-token
revocation list.

## Limits and logs

No new per-machine budget in this slice: coderouter account limits apply, and usage is attributed
per machine in coderouter's ledger (`vmId`). The Chief plan's $20/user/day cap is separate work.
Logs carry machine id, outcome and expiry, never the token, the rule or a provider body
(`cloud coderouter edge` log lines; driver errors carry only step, status and provider code).

## Gate

Development only: on when `ENVIRONMENT` is `development` (or `test`) and `CLOUD_CODEROUTER_EDGE_HOST`
is set. Staging and production send no rule.

## Decisions (hq-6d chief, 2026-10-07)

1. Approved: coderouter staging trusts the development issuer through the chatmux verifier slot.
   The verifier checks alg ES256, issuer, `aud coderouter`, exp, max age 1 hour and the claims
   (`web/services/coderouter/chatmuxVmToken.ts:84-93`, same on main). A backend access token
   (`aud api`) fails there.
2. Approved: key reuse and the `chatmux:` ledger label for this slice. Follow-up bead cx-5lp:
   a generic machine-issuer verifier on main, a dedicated machine-token key, owner private imports
   for personal-scope machines, and a per-machine budget.
3. Proof needs one shared (`visibility = team`) Claude account in Lawrence's dev personal scope on
   staging coderouter. If none exists, the proof stays UNVERIFIED. Nobody creates one or uses
   another person's account.

## Staging configuration record

Project `cmux-staging` (`prj_804LTAUdOwulMvEfcmfnU8bvGo3T`, team `team_KndpHsJ15gO2OoAP2SO0thYn`),
Production target only, type plain, set through the Vercel API. The `cmux` project is unchanged.

- Before: 111 variables, no `CODEROUTER_CHATMUX_*`. Alias `cmux-staging.vercel.app` ->
  `dpl_BT8XHyvazgGZ7xh1YFc5u2PirTd7` (commit 3cab11d06dac), then
  `dpl_HBhMhE42Q73Qz23xjgsY99qmcxPk` (commit 7a5ff8674d11, a normal main deploy).
- After: 113 variables.
  `CODEROUTER_CHATMUX_JWKS_URL=https://cmux-api-development.debussy.workers.dev/.well-known/jwks.json`
  (id `CNGmaJ3lLPdPas3u`), `CODEROUTER_CHATMUX_ISSUERS=https://cmux-api/development`
  (id `LUUl1GTT5AzwLrkI`).
- A same-commit redeploy is skipped by `web/tools/vercel-ignore-build.sh` (equal SHAs exit 0), so
  the variables go live with the next main deploy that changes web inputs.
- Rollback: delete both variables, then let the next main web deploy pick up the removal:

  ```bash
  for id in CNGmaJ3lLPdPas3u LUUl1GTT5AzwLrkI; do
    vercel api "/v10/projects/prj_804LTAUdOwulMvEfcmfnU8bvGo3T/env/$id?teamId=team_KndpHsJ15gO2OoAP2SO0thYn" -X DELETE --dangerously-skip-permissions
  done
  ```

  To stop new development machines from getting the rule at once, remove
  `CLOUD_CODEROUTER_EDGE_HOST` from the development vars in `backend/apps/api/wrangler.jsonc` and
  redeploy development.
