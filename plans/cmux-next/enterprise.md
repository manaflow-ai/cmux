# Enterprise implementation plan (MDM, SSO, team policy, audit)

Design: cmux-next-spec `spec/enterprise.md` (4f74223, 4.6 in 59f9f9c) and `research/enterprise.md`. Owner: enterprise lead. Lawrence (2026-10-02): "some orgs will want to customize it. we should build in MDM support from day 1 as well as SSO so cmux-next is enterprise ready."

## Spec status

Spec text pushed before the 2026-10-02 rule change (only the coordinator writes cmux-next-spec): `spec/enterprise.md` (4f74223, 59f9f9c, ea7d8e9), `research/enterprise.md`, decisions E1 to E6 in `decisions.md`, cross-links in `00-overview.md` 7.1 (`DomainDO`) and `identity-and-permissions.md`. The coordinator reviews them. New spec text goes here as "spec proposal" sections.

## Decisions (Lawrence, 2026-10-02, through the coordinator)

- E1: build our own SAML 2.0, OIDC and SCIM 2.0 in our codebase with minimal dependencies, modeled on better-auth's SSO, SAML and SCIM plugins. Copying better-auth code is allowed: record it in LICENSE/NOTICE with better-auth's MIT notice and in the commit message. Hexclave (Stack) sign-in and enterprise SSO work side by side. Test against public SAML attack corpora (signature wrapping, comment injection, replay, audience and recipient checks).
- E2: MDM wins over team enforced; the conflict is reported.
- E3: device keys come only from the managing team (enrollment token or explicit accept).
- E4: Swift and Rust readers with shared vectors now; Rust config crate only later.
- E5: all enterprise features are paid, MDM included (open follow-up F1 below).
- E6: domain `com.manaflow.cmux` plus the legacy forced `DisableAutoUpdate` in `com.cmuxterm.app`.

## Owners (binding, OWNERSHIP-PRINCIPLES)

| State | Owner | Notes |
| --- | --- | --- |
| `TeamPolicy` (current version + last 100 versions) | `TeamDO` reducer (`backend/apps/api/src/domains/team.ts`) | single writer; ops `team.policy.update`, `team.policy.rollback`; reads `team.policy.get`, `team.policy.history` |
| SSO connections, SCIM directory, enrollment tokens | `TeamDO` | phase 2c/2d |
| Domain claims | `DomainDO` (new class, key = lowercased domain) | phase 2c |
| Managed device preferences | the MDM server; read by the config layer | domain `com.manaflow.cmux`; legacy forced `DisableAutoUpdate` in `com.cmuxterm.app` |
| Effective settings | config layer (`CmuxNextSettings`, later the Rust config crate) | merge order below |
| Audit records | the owner's event log; projection `audit_events` | phase 2b, needs a PlanetScale migration |

Effective value of a device key, highest first: MDM forced, team enforced, cmux.json, MDM recommended (non-forced value in `com.manaflow.cmux`), team default, product default. Team values reach a device only from its managing team (E3, recommended option until Lawrence answers).

## Steps

| Step | Content | Tests | Status |
| --- | --- | --- | --- |
| 2a-1 | `TeamPolicy` Effect Schema (`policy.ts`), ops in `policy-ops.ts`, `TeamDO` reducer cases (owners/admins, agents refused), `expected_version` compare-and-swap, bounded history; TeamDO pushes the integration slice to ConnectionDO (`applyTeamPolicy` -> `integration.policy.apply_managed {source: team_policy}`) | reducer tests, seeded sequence, workerd e2e incl. ConnectionDO sync, catalog drift | PR https://github.com/manaflow-ai/cmux/pull/16774 (stacked on #16762; retarget to feat-cmux-next when it merges) |
| 2a-2 | Swift `ManagedPreferences` reader in `CmuxNextSettings` (CFPreferences through an injectable source; DEV-only `CMUX_NEXT_MANAGED_PREFS_FILE`), `EffectiveSettings` merge before `CmuxConfigSnapshot.parse`, `managedKeys` on the snapshot, `setSetting` refuses managed keys with `SettingManaged`, reload on managed-file events and app activation | Swift Testing: precedence table, forced vs recommended, legacy alias, write refusal, reload | landed (see COORDINATION) |
| 2a-3 | Settings window: managed rows disabled, "Managed by your organization" line, Reset hidden; localized in every language | SettingsWindowModel tests | landed (see COORDINATION) |
| 2a-4 | MDM schema generator from `SettingsSchema` (ProfileManifests plist, Jamf JSON schema, example `.mobileconfig`, Intune plist, markdown table), checked in under `docs/mdm/`; golden test fails when the catalog changes without regenerating | golden test, plist parse test | landed (see COORDINATION) |
| 2a-5 | Dashboard `/policy` page: enforced/default/unset per key, save with `expected_version` and reason, history and rollback | typecheck, build; browser check UNVERIFIED | in PR 16774 |
| 2b-1 | Policy history capped at 20 in TeamDO state | reducer tests | PR 16774 (971e4533bb5) |
| 2b-2 | Enrollment: `team.enrollment_token.create/revoke/list`, `team.device.enroll/release`, read `team.device.policy`; client sends base64url(SHA-256(token)); state keeps sha256(token_hash); membership required; `allowed_domains` against the user's email (UserDO `installGrant` returns it) | reducer + workerd e2e, shared hash vector with Swift | PR 16774 (971e4533bb5, 5397cfafba7) |
| 2b-3 | Audit chain: one `audit.append` per admin action in the same commit, `prev_hash`/`hash`, migration `0005_audit_events.sql` (expand) | chain verify + tamper tests, scratch Postgres apply; label `backend:apply-migrations` NOT added yet | PR 16774 |
| 2b-4 | Swift: `TeamPolicyLayer(devicePolicy:)`, `ManagedPreferences.enrollmentTokenHash`, `enrollmentToken` | Swift tests, shared vector | landed (see COORDINATION) |
| 2b-5 | App wiring: enroll with the MDM token after sign-in, subscribe to `team.device.policy`, call `setTeamPolicy` | | blocked: the cmux-next app has no client for the new backend yet (cloud-api.cmux.dev) |
| 2b-6 | Rust config crate reader (`core-foundation`, same keys, shared precedence vectors) | testbox | planned |
| 2c | SSO connection model, OIDC (own client, PKCE, `jose` already a dependency), `DomainDO`, DNS TXT verify over DoH, enforced SSO in `authenticate()`, Stack session create with `expiresInMillis`; sign-in page offers Hexclave and "Sign in with SSO" side by side | | planned |
| 2d | SAML 2.0 SP (own validator modeled on better-auth's SAML plugin; XML signature check on the exact signed element, reject DTDs, comments in signed values, multiple assertions; replay cache per connection), SCIM 2.0 `/Users` `/Groups` modeled on better-auth's SCIM plugin, Okta and Entra quirks, group map to team-vm hierarchy nodes; attack corpora as tests; better-auth MIT notice in NOTICE | | planned |

## Coordination

- Automations lead: `github.repoScope` (`linking_user_repos` default, `installation`), `github.requireOrgAdmin`, `github.repoAllowList`, `integrations.allowedProviders` are TeamPolicy keys. ConnectionDO's `TeamIntegrationPolicy` is their enforcement projection, written only by TeamDO through `integration.policy.apply_managed {source: team_policy}`. Open for the automations lead: make `integration.policy.set` forward to `team.policy.update` (or remove it) and point the /integrations policy card at /policy.
- App Store lead: `apps.install`, `apps.allowedTiers`, `apps.allowList`, `apps.forcedInstalls` live in TeamPolicy (app-platform.md section 10/11 "team app policy"); `app.install` in `TeamDO`/`UserDO` enforces them.
- Network policy lead: egress stays in the network policy document (D39); TeamPolicy has no egress key. The dashboard policy page links to the network policy editor.
- Backend lead: new ops in `cloudOps`; no new DO class in 2a; `DomainDO` in 2c needs a wrangler class migration.

## Gaps and follow-ups

- `ManagedUpdatePolicy` (CmuxNextUpdater) still reads `DisableAutoUpdate` itself; move it to `SettingsController.managedPolicy` so there is one reader.
- The App does not call `setTeamPolicy` yet: it needs the managing team (enrollment, phase 2b) and a `team.policy.get` subscription.
- No review subagent ran on 2a (session subagent limit); run one before PR 16774 merges.

## Spec proposal: enterprise (for the coordinator)

Changes to cmux-next-spec `spec/enterprise.md` that the coordinator should write:

1. Section 3.1 and 3.7, decision E1: replace "WorkOS or SAML Jackson alternative" with "own SAML, OIDC and SCIM in the API Worker, modeled on better-auth's SSO, SAML and SCIM plugins (MIT; copied code is attributed in NOTICE and commit messages), minimal dependencies". Hexclave sign-in and SSO side by side: the sign-in surface asks for the email, `GET /v1/sso/discover` decides, and users outside verified domains keep Hexclave sign-in.
2. Section 5.4, enrollment as built: clients send `token_hash = base64url(SHA-256(token))`; the raw token never reaches the server; TeamDO stores `sha256(token_hash)`; the enroller must already be a member; `allowed_domains` is checked against the user's email; ops `team.enrollment_token.create|revoke|list`, `team.device.enroll|release`, read `team.device.policy`. Exposure model: `token_hash` reaches members in events, which gives a member nothing (members can enroll by acceptance). If tokens ever admit non-members, the token must leave op params.
3. Section 6, audit as built: chain per team (`n`, `prev_hash`, `hash = sha256(prev_hash || canonical record)`), written in the same commit as the change, table `audit_events` (PK `(team_id, n)`). Policy history in TeamDO state is capped at 20 versions.
4. Section 4.4: device keys from the managing team only (E3), MDM wins with conflict report (E2).
5. Section 10: E1 to E6 answered as above.
6. New section, entitlement (E5): see F1.

Follow-up questions (recommendation first):

- F1. How is "MDM is paid" enforced on a Mac? (1, rec.) Managed keys apply only when the device's managing team (enrollment token) has the enterprise plan; otherwise Settings shows "Managed settings need cmux Enterprise" and ignores them, except the legacy `DisableAutoUpdate`, which already shipped. Objection: an admin who deploys a profile before buying gets no locks (fail open). (2) Device keys always apply (fail safe); the paid plan gates enrollment, team policy, SSO, SCIM and audit export only. (3) Device keys always apply, but only for 30 days without a paid managing team.
- F2. Where does the entitlement come from before billing ports to the new backend? (1, rec.) TeamDO reads a team flag mirrored from the old backend's billing API by a Worker cron, and enforces it in every enterprise op. (2) A manual staff flag in TeamDO until billing ports.
- F3. Should the automations lead remove `integration.policy.set` now that TeamPolicy owns the values? (1, rec.) Yes: forward it to `team.policy.update` for one release, then remove it. (2) Keep it for teams without a TeamPolicy version.
