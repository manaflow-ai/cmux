# Enterprise implementation plan (MDM, SSO, team policy, audit)

Design: cmux-next-spec `spec/enterprise.md` (4f74223, 4.6 in 59f9f9c) and `research/enterprise.md`. Owner: enterprise lead. Lawrence (2026-10-02): "some orgs will want to customize it. we should build in MDM support from day 1 as well as SSO so cmux-next is enterprise ready."

## Spec status

Spec text pushed before the 2026-10-02 rule change (only the coordinator writes cmux-next-spec): `spec/enterprise.md` (4f74223, 59f9f9c, ea7d8e9), `research/enterprise.md`, decisions E1 to E6 in `decisions.md`, cross-links in `00-overview.md` 7.1 (`DomainDO`) and `identity-and-permissions.md`. The coordinator reviews them. New spec text goes here as "spec proposal" sections.

## Decisions (Lawrence, 2026-10-02, through the coordinator)

- E1: build our own SAML 2.0, OIDC and SCIM 2.0 in our codebase with minimal dependencies, modeled on better-auth's SSO, SAML and SCIM plugins. Copying better-auth code is allowed: record it in LICENSE/NOTICE with better-auth's MIT notice and in the commit message. Hexclave (Stack) sign-in and enterprise SSO work side by side. Test against public SAML attack corpora (signature wrapping, comment injection, replay, audience and recipient checks).
- E2: MDM wins over team enforced; the conflict is reported.
- E3: device keys come only from the managing team (enrollment token or explicit accept).
- E4: Swift and Rust readers with shared vectors now; Rust config crate only later.
- E5 and licensing (Lawrence, 2026-10-02): the app stays GPL-3 and always applies MDM locks; no client DRM. Paid value is server-side: SSO and SCIM, enforced team policy sync, enrollment, audit export, the admin dashboard, support. Official builds show "cmux Enterprise required" to team admins without a plan (dashboard and admin surfaces only). The cmux trademark covers official builds.
- F2: a Worker cron copies the plan flag from the old billing API into TeamDO; every paid op checks it.
- F3: `integration.policy.set` forwards to `team.policy.update` for one release, then is removed (automations lead).
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

Follow-up questions F1 to F3: answered (see Decisions).

## MDM the way enterprises run it (proposal, 2026-10-02)

Lawrence: "make sure we support MDM the way most enterprises do it, like if they have custom MDM app/dashboard". Principle: cmux adds no agent and no proprietary channel. It consumes what every MDM already delivers and reports state in forms their dashboards already read.

### Delivery paths (in)

| Path | Who uses it | cmux support | Status |
| --- | --- | --- | --- |
| Configuration profile, custom settings payload (`PayloadType = com.manaflow.cmux`) | every macOS MDM: Jamf Pro, Kandji (now Iru), Intune, Workspace ONE, Mosyle, Addigy, Fleet, SimpleMDM, Hexnode, Jumpcloud | read through CFPreferences (forced and non-forced); `docs/mdm/cmux-example.mobileconfig` | landed |
| Schema-driven editors | Jamf Pro (Application & Custom Settings JSON schema), iMazing Profile Editor and ProfileCreator (ProfileManifests), Intune (preference file template) | generated from `SettingsSchema` in `docs/mdm/` | landed |
| Apple Declarative Device Management | MDMs on DDM (Jamf, Kandji/Iru, Mosyle, SimpleMDM, Fleet, Intune for some declarations) | The portable DDM path is the legacy-profile declaration (`com.apple.configuration.legacy`) that carries our profile. Whether Apple's managed app configuration declaration covers third-party macOS app preferences is UNVERIFIED; M3 checks Apple's device-management schema and adds it if so. Ship a generated example declaration plus asset. Same read path, no app change | step M3 |
| Enrollment token | any MDM, as the `EnrollmentToken` key in the same profile | hashed on device, `team.device.enroll` | backend in PR 16774; app client blocked on the new-backend client |
| Script-based delivery (`defaults write /Library/Managed Preferences/...` is not supported; admins who push scripts use `profiles install` or their MDM's custom profile) | Fleet scripts, Addigy, Munki shops | document only; non-forced values written by scripts into the domain act as recommended values | docs |
| iOS Managed App Configuration (`com.apple.configuration.managed`) and the AppConfig specfile | every iOS MDM | same keys and precedence; generated AppConfig XML specfile from the catalog's iOS-relevant keys | step M6 (after the iOS app uses cmux-next settings) |
| Linux (team VMs, minis) | Ansible, Fleet, Chef | `/etc/cmux/policy.json` read by the Rust config crate | step M5 |

### Status paths (out), so a custom dashboard can see compliance

| Path | Reader | Content |
| --- | --- | --- |
| Status file `~/Library/Application Support/cmux/managed-status.json` (per user, 0644) | osquery (`parse_json` table or Fleet's `file` + JSON), Jamf extension attributes, Kandji/Addigy custom scripts | schema version, app version and channel, policy domain, keys seen (forced / recommended, names only, never values of `EnrollmentToken`), keys applied and their source, conflicts (MDM forced vs team enforced, E2), managing team id and policy version, enrolled yes/no, last applied time |
| `cmux mdm status --json` (CLI verb, catalog op `mdm.status`) | admin scripts, MDM script runners | the same document; reads the status file, works with the app closed |
| Backend admin API `team.device.compliance` (read, admins) fed by `team.device.report_status` from each install | the cmux dashboard, the customer's own dashboard through an API token, SIEM | per device: install, user, app version, policy version applied, MDM keys present (names), conflicts, last report time; compliant = applied version equals the team's current version and no conflicts |
| Audit export | SIEM | `audit_events` (phase 2b) |

### Steps

| Step | Content | Tests |
| --- | --- | --- |
| M1 | Status file written by the config layer after each applied load (atomic write, only on change), conflicts per E2 | Swift: content, no token value, conflict detection, write only on change; landed in PR 16783 (71a826d67d3) |
| M2 | `team.device.report_status` (install) and `team.device.compliance` (admins) in TeamDO | reducer + workerd |
| M3 | Per-vendor guides `docs/mdm/vendors.md` (Jamf Pro, Kandji/Iru, Intune, Workspace ONE, Mosyle, Addigy, Fleet, SimpleMDM, generic), DDM legacy-profile declaration example, osquery/Fleet query examples | in PR 16783; vendor menu paths and the DDM declaration shape UNVERIFIED against live consoles |
| M4 | `cmux mdm status --json` in the Rust CLI (reads the status file) | testbox |
| M5 | Rust config crate reader (`core-foundation`) and `/etc/cmux/policy.json` with the shared precedence vectors | testbox |
| M6 | iOS managed app config and AppConfig specfile | iOS tests |
| M7 | App reports status to the backend after enrollment (needs the new-backend client) | |

Strongest objection: "A status file the user can edit is not evidence." Answer: it is for admins' own tooling on machines they manage (root-owned profile, non-admin users); the evidence of record is the backend's `team.device.compliance`, written only by the install's authenticated reports, and the app recomputes it on each load. A tampered local file can mislead only local scripts.

## Review findings (2026-10-02) and fixes

Source: worker review of 6aa4a6e1170, PR 16783 and PR 16774. Failing test committed before each backend fix.

| Finding | Fix | Where |
| --- | --- | --- |
| HIGH unreadable cmux.json skipped the merge (MDM forced values not applied) | managed layers always merge, over the last good file or {} | PR 16783 71a826d67d3 |
| HIGH palette/action.run applied live values before the refused write | handlers refuse first via `managedKey(forPath:)`; failed writes reload | PR 16783 71a826d67d3 (test run red first) |
| HIGH first TeamPolicy version widened the ConnectionDO integration policy | seed TeamPolicy from ConnectionDO before the first push; push only on slice change | PR 16774 444bb53c0c8 (test) b4bfd1ef4d2 (fix) |
| MED policy keys read from user-writable non-forced values | forced only | PR 16783 |
| MED E2 conflict not reported | `managedConflict` diagnostic + status file | PR 16783 |
| MED backend device keys were not settings | `device.settings` key (cmux.json paths, per-entry mode); feature keys returned as `features` | PR 16774 aceab46e98d / d72fe94f40f |
| MED team layer could set any path | limited to SettingsSchema ids | PR 16783 |
| MED members saw full TeamDO state | OwnerDO `subscriberView` / `mayReceive`; TeamDO filters history, tokens, other devices, audit head | PR 16774 9632b58405f / 05b1f0be1b4 |
| MED U+0000 could stall the outbox | projection replaces U+0000 | PR 16774 3472280dbe5 / cd0f58e1cf5 |
| MED members and agents could release MDM-enrolled installs | admins only for token-enrolled; agents never | PR 16774 b98349d3a97 / 26aa28a5353 |
| MED deploy order of 0005 | applied to staging 2026-10-02 (`migrate.ts --env staging`, verified 5/5); production through the `backend:apply-migrations` label before merge | staging done |
| LOW stale team policy read | `setTeamPolicy` ignores an older version of the same team | PR 16783 |
| LOW CFPreferencesAppSynchronize without a deadline; settings.get reads the user file | open | |
| LOW one install in several teams; allowed_domains adds little while acceptance exists | open, by design until DomainDO | |
