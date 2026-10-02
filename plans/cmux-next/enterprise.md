# Enterprise implementation plan (MDM, SSO, team policy, audit)

Design: cmux-next-spec `spec/enterprise.md` (4f74223, 4.6 in 59f9f9c) and `research/enterprise.md`. Owner: enterprise lead. Lawrence (2026-10-02): "some orgs will want to customize it. we should build in MDM support from day 1 as well as SSO so cmux-next is enterprise ready."

## Spec status

Spec text pushed before the 2026-10-02 rule change (only the coordinator writes cmux-next-spec): `spec/enterprise.md` (4f74223, 59f9f9c, ea7d8e9), `research/enterprise.md`, decisions E1 to E6 in `decisions.md`, cross-links in `00-overview.md` 7.1 (`DomainDO`) and `identity-and-permissions.md`. The coordinator reviews them. New spec text goes here as "spec proposal" sections.

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
| 2b | `audit_events` projection + hash chain (migration `NNNN_audit_events.sql` through `backend:apply-migrations`, coordinate numbering with automations and app store), enrollment tokens, Rust config crate reader with shared vectors | | planned |
| 2c | SSO connection model (OIDC first), `DomainDO`, DNS TXT verify, enforced SSO in `authenticate()`, Stack session create with `expiresInMillis` | | planned |
| 2d | SAML (E1), SCIM endpoints, group map to team-vm hierarchy nodes | | planned |

## Coordination

- Automations lead: `github.repoScope` (`linking_user_repos` default, `installation`), `github.requireOrgAdmin`, `github.repoAllowList`, `integrations.allowedProviders` are TeamPolicy keys. ConnectionDO's `TeamIntegrationPolicy` is their enforcement projection, written only by TeamDO through `integration.policy.apply_managed {source: team_policy}`. Open for the automations lead: make `integration.policy.set` forward to `team.policy.update` (or remove it) and point the /integrations policy card at /policy.
- App Store lead: `apps.install`, `apps.allowedTiers`, `apps.allowList`, `apps.forcedInstalls` live in TeamPolicy (app-platform.md section 10/11 "team app policy"); `app.install` in `TeamDO`/`UserDO` enforces them.
- Network policy lead: egress stays in the network policy document (D39); TeamPolicy has no egress key. The dashboard policy page links to the network policy editor.
- Backend lead: new ops in `cloudOps`; no new DO class in 2a; `DomainDO` in 2c needs a wrangler class migration.

## Gaps and follow-ups

- `ManagedUpdatePolicy` (CmuxNextUpdater) still reads `DisableAutoUpdate` itself; move it to `SettingsController.managedPolicy` so there is one reader.
- The App does not call `setTeamPolicy` yet: it needs the managing team (enrollment, phase 2b) and a `team.policy.get` subscription.
- No review subagent ran on 2a (session subagent limit); run one before PR 16774 merges.
