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
| M2 | `team.device.report_status` (install) and `team.device.compliance` (admins) in TeamDO | reducer tests; landed with the follow-up push |
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

## Follow-ups after PR 16774 merged (7dbf31f1324)

- Lock precedence (coordinator decision, consistent with E2): an SSO- or MDM-managed ConnectionDO lock always wins over TeamPolicy. `integration.policy.apply_managed {source: team_policy}` is a no-op under such a lock; TeamDO copies nothing from it, settles the version without retrying and returns `integration_managed_by` in `team.policy.get`. Tested with a lock committed through ConnectionDO's own system op (nothing writes these locks yet).
- Snapshot cost: hidden events are coalesced into one filtered snapshot per subscriber per batch (250 ms one-shot timer, one view per identity); `OwnerEngine.snapshot` skips the ledger query for an empty pending list.
- M2 device compliance landed in the same push.

## Spec proposal: shared teams (for the coordinator; backend lead reviews)

Needed by SSO just-in-time membership, SCIM and every team-admin op (today every session maps to the user's personal team, and team-admin ops refuse shared teams).

1. Membership rows in `TeamDO`: `members: {user -> {role, joined_at, source: personal | invite | sso | scim, status: active | suspended}}`. TeamDO is the single writer; the outbox projects `memberships` (exists). Roles: `owner | admin | member` (the existing enum). Invariants: every team has at least one active owner; the personal team has exactly its user, as owner; a suspended member's ops are refused by every owner.
2. Ops: `team.create {display_name}` (creates a shared team; the caller is owner), `team.member.invite {email, role}` (admins; Stack team invitation or an invite token), `team.member.provision {user, role, source}` (system: SSO JIT and SCIM, with the source's actor), `team.member.set_role`, `team.member.suspend | remove` (destructive: revokes the member's grants on team resources and team SSH certificates in the same commit; the last owner cannot leave), `team.list` (UserDO read: the user's teams).
3. Team selection in tokens: the short-lived install JWT gets a `team` claim chosen at mint (`/v1/auth/token {team?}`), default the personal team. UserDO checks membership through a `TeamDO.memberRole(user)` RPC at mint and on refresh (revocation within one token lifetime); session tokens select the team with an `x-cmux-team` header checked the same way. Owners keep checking the role from their own state (owner-side check, never the claim alone).
4. UserDO keeps the user's team list (projection of TeamDO membership events, written by a system op from TeamDO), so `team.list` and the dashboard's team switcher need no scan.
5. Migration: personal teams unchanged; the `kind` field (`personal | stack`) gains `shared`; Stack teams mirror into shared teams later through the same `team.member.provision` op.

Strongest objection: a team claim in the token can go stale when a member is removed. Answer: owners check the member row on every op (the claim only routes), and refresh re-checks at mint, so removal takes effect at once for ops and within one token lifetime for routing.

### Backend lead review of the shared-teams proposal (2026-10-02)

Accepted with these changes. These changes align the proposal with spec H5: Contacts, Grants and Team never imply each other, and roles are bundles of default grants.

1. Role set: `guest | member | admin | owner | billing`. This replaces `owner | admin | member`. A role is a named bundle of default grants that TeamDO stores (`team_roles: role -> [grant]`). Ops check grants, never role names. The bundles:
   - `owner`: all grants.
   - `admin`: all grants except owner transfer and team deletion.
   - `member`: the team resources by default.
   - `billing`: billing and invoices only, with no resource access.
   - `guest`: no default grants. A guest reaches only resources that their owners grant one by one.
   An admin cannot grant `owner` and cannot raise anyone above their own role. The invariant becomes "at least one active `owner`". `billing` never counts as an owner.
2. Team is not Contact. Membership never creates a Contact, a DM or reachability to a member's chief. Compose never adds members. `team.member.invite` stays a separate, explicit sheet (H5). Team policy may limit DMs inside the team. It never opens them.
3. Removal and suspension revoke, in the same commit, every grant whose basis is the membership. That covers the default bundle and the team SSH certificates. Explicit Grants have a `basis` field (`team:<id>` or `direct`). A direct grant from a resource owner outlives the membership only when its basis is `direct` and the resource is not a team resource.
4. JIT and SCIM: `team.member.provision` defaults to `member`. An IdP group gives `admin` or `owner` only through a mapping that an admin set in the SSO connection (an audited op). Raw IdP claims never give a role.
5. The token team claim is accepted as proposed: the claim routes, and owners check the member row. The same check applies to `x-cmux-team`. TeamDO stays the source of truth. Stack teams mirror into TeamDO only through `team.member.provision` (D4: Stack is the identity source, not the membership source).
6. Order: after Home stage B and stage C. SSO JIT membership and SCIM wait for it.

Lawrence's decisions (2026-10-02):
- (a) Guests are free: a guest is never a paid seat.
- (b) `billing` reads only billing-related audit entries (an audit read filtered by category).
- (c) Only an `owner` removes or suspends an `admin`. An `admin` removes `member`, `guest` and `billing` only.

Pending verification (the enterprise lead's OIDC callback): the Stack server calls (user search, create user, create session) ran only against a fake. Verify them against the real Stack project on staging the next time auth code changes, before SSO sign-in is enabled for a real connection.

## P17: every policy key has an enforcement point (catalog lane, 2026-10-03)

Source: spec-coverage.md P17 and the enterprise review. Each parsed policy key gets one owner that refuses, with a test. Managed values are read only through `SettingsController.managedPolicy`, the single Swift reader. That reader moves behind the Rust config actor's snapshot (settings-react.md) with no change to these call sites. No slice adds a second MDM reader.

| Slice | Key | Enforcement point | Owner |
| --- | --- | --- | --- |
| P17-1 | `DisabledFeatures` (computerUse, browserAutomation, mcp, cloud, apps, remoteHosts) | `ActionRegistry`: a disabled feature's actions are unavailable with the reason "Turned off by your organization" on every surface (palette, menus, shortcuts, CLI and socket `action.run`), because they all run through the registry. Feature to actions comes from one table keyed by category and id prefix. MCP serve and browser automation ops in the daemon read the same key from the config actor (Rust follow-up). | catalog lane (Swift); Rust half goes to the CLI owner through main |
| P17-2 | `UpdateChannel`, `MinimumVersion` | Updater: a forced channel overrides the user's track, and the channel picker shows it as managed. If the running version is older than `MinimumVersion`, the updater installs an update and does not offer Skip or Later. Sign-in refusal of old clients is server-side (P17-4). | catalog lane |
| P17-3 | `RestrictToManagedTeam`, `AllowedSignInMethods` | Sign-in and team switch: the app offers only the allowed methods and refuses another team with a managed refusal. The server enforces the same rules (P17-4), because client checks are advisory. | catalog lane (client); backend lead (server) |
| P17-4 | Server-side keys: team-enforced sign-in methods and minimum version, `agents.allowedClasses` at grant mint | `authenticate()` and grant mint in UserDO/TeamDO | backend lead, through main |
| P17-5 | Publish the MDM schema with each release | The release and nightly workflows upload `docs/mdm/*` as release assets. A check fails when `docs/mdm` is stale; the golden test from 2a-4 already guards that. | catalog lane (workflow), release owner reviews |
| P17-6 | F3 `integration.policy.set` forwards to `team.policy.update` | ConnectionDO op | automations lead / backend lead |

Order: P17-1, P17-2, P17-3 (Swift client), P17-5, then the backend slices through the backend lead. A review subagent (security) checks each slice before it lands.

### P17-1 and P17-1b (DisabledFeatures), 2026-10-03

Landed in P17-1: the registry gate (palette, context menus, shortcuts, perform, main menu items hidden at validation, the shortcut page, `action.list`, `feature.disabled` from `action.run`, `action.describe` and CLI names), `MachineRegistry.daemon(machine:)`, the root palette's app rows and the Computer Use onboarding step.

P17-1b (coordinator decisions, 2026-10-03):
- When a feature is turned off, this Mac disconnects that feature's live sessions and refuses reconnects (SSH wake and activation, restored hosts, the Cloud list refresh, restored cloud workspaces, the Cloud tunnel hub). Nothing remote is deleted or stopped: Cloud VMs, SSH host processes and remote daemons keep running. Turning the feature on again reconnects what was connecting before.
- Terminal tabs on a turned-off machine show the plain banner "Turned off by your organization", with no reconnect hint. Their endpoint refuses re-attaches. A window of such a machine keeps its blocked daemon, so its commands never land on this Mac.
- `apps`: the app host refuses to start apps and stops running ones, including a start that was in flight. Lifting the policy clears the reason.
- `server.makeThisMacAServer` and `server.addServer` map to `remoteHosts`. `server.stopServing` stays available, so a running server can still be stopped.
- The shortcut and chord index (leader overlay) skips disabled actions.
- `cloud.machines`, `remote.machines` and CodeRouter writes (`coderouter.*.add|set|update|remove|clear`) answer `feature.disabled`. CodeRouter reads stay on. Phone access (`mobile.*`) stays on, because the phone reaches this Mac, not Cloud.
- A malformed `DisabledFeatures` value (not an array of strings) fails closed: every feature is turned off, and a diagnostic says why. An administrator who set the key meant to restrict, so a typo must not leave everything on. An unknown name is reported and ignored, and the known names still apply. A problem never turns a feature on.
- At launch, the forced value applies synchronously before Cloud, SSH and apps start.

Open:
- Rust half (ad349): `cmux mcp serve` and browser automation ops refuse when `mcp` or `browserAutomation` is off, through the config actor.
- After the policy lifts, an SSH terminal keeps the banner until its next attach event (a click or a key press), and an open app page keeps it until the page is reopened.

### P17-4 and P17-6 status (backend lead, 2026-10-03)

P17-4, enforced against the principal's TeamDO policy (TeamDO.signInRules, cached 30 s per Worker isolate):
- `sso.enforce`: a Stack session without the team's SSO claim `cmux_sso_team` (the enterprise OIDC callback stamps it) gets 403 `auth.sso_required` on every API request and wire connect; owners are exempt unless `sso.enforceForOwners`.
- Installs: `install.register` from a session records that session's `sso_team` on the install, and minted install tokens carry it. When the team enforces SSO, token mint, every API call and wire connect refuse installs registered without it, so installs from before enforcement must be registered again through SSO. Requirement for the enterprise lane: `cmux_sso_team` must be a claim users cannot set themselves (Stack server-signed, not client or user metadata); if Stack cannot guarantee that, SSO sessions are recorded server-side instead and the check reads that record.
- `chief.create` is refused on the user socket (it would skip the class gate); it goes through POST /v1/ops.
- `updates.minimumVersion`: `/v1/auth/token` and every wire connect read `x-cmux-client-version`; older, or missing while the key is set, answers 403 `client.too_old` with `minimum_version`. Mac, iOS and CLI send the header (coordinator routes).
- `agents.allowedClasses`, class mapping (enterprise lane checks it):
  - `mux` = chief creation (`chief.create`, which also binds the chief's MuxDO): enforced in the Worker (403 `policy.denied`).
  - `agent` = `install.register` for agent install kinds: no agent install kind exists yet (kinds are mac, ios, cli, daemon, web, vm); enforced when one is added.
  - `run` = automation run grants: NOT yet enforced. Runs start inside SchedulerDO (alarms, webhooks), which has no copy of the team policy; follow-up with the automations lead: TeamDO pushes `agents.allowedClasses` to SchedulerDO as it pushes the integration slice to ConnectionDO, and run creation refuses when `run` is absent.
P17-6 (accepted by the coordinator, replaces the planned ConnectionDO system forward): `integration.policy.set` is a deprecated alias of `team.policy.update`, forwarded by the Worker with the caller's own principal (TeamDO's admin check applies; a system forward would skip it). An SSO or MDM lock on ConnectionDO still answers `policy.locked`. The answer keeps the old shape (the integration slice, source `team_policy`); ConnectionDO receives it through TeamDO's push within seconds. Remove the alias after one release.

### sso.enforce: SSO sessions recorded server-side (enterprise lane, 2026-10-03)

Hexclave/Stack access tokens carry a fixed set of claims (`sub`, `refresh_token_id`, `email`, ...) with no custom claims or metadata (docs.hexclave.com, guides/apps/authentication/jwts). So `cmux_sso_team` could never come from our OIDC callback. The gate trusted it anyway: a Stack-signed token that carried it passed. Fix: the OIDC callback creates the Stack session server-side, reads its `refresh_token_id`, and records (refresh_token_id, stack user, connection, expiry) in the team's TeamDO. `auth.ts` ignores any SSO claim and carries the Stack-signed `refresh_token_id`. `policy-gate.withSsoSession` asks TeamDO, so the record is the only source.
Lifecycle, from Stack's source (apps/backend/src/lib/tokens.tsx): `refresh_token_id` is the refresh-token row id, so it stays the same across access-token refreshes. Sign-out and session revocation delete the row, and Stack then mints no new access token for it. A revoked session therefore keeps working only until its last access token expires (10 minutes) plus our 30 s cache. The record expires at `sso.sessionMaxAgeHours`, or after at most 365 days, and it stops counting at once when its connection is disabled or deleted.
Open (backend lead, blocks turning sso.enforce on): the gate reads the policy of `principal.team`, which is the personal team for every session and install. A member of an SSO team is therefore never checked against that team. sso.enforce also cannot be enabled today, because `team-policy.ts` hard-codes `ssoFacts` to 0 active connections. Lowering `sso.sessionMaxAgeHours` does not shorten records that already exist.

### P17-2: UpdateChannel and MinimumVersion (enterprise lane, 2026-10-03)

The single managed reader (`SettingsController.managedPolicy`) passes both keys to `UpdaterService` through `UpdaterPolicyBridge`.
- `UpdateChannel` (stable or nightly, either case; an unknown name pins nothing) refuses switching to the other channel. The channel switch action shows the localized reason.
- `MinimumVersion` (major.minor.patch, missing parts are 0, a pre-release counts as its release): while the running version is older, the updater checks when the requirement starts, when Sparkle starts and on each app activation. The sheet says "Your organization requires cmux X or newer" and has no Later button. Escape still closes it, and it comes back on the next activation.
- The Mac app sends `x-cmux-client-version` on the feed wire connect. The server answers `client.too_old` (P17-4).
Open: a pinned channel that differs from the running app only refuses the switch; the app does not move to the pinned channel. The Mac has no `/v1/auth/token` client yet (2b-5); iOS sends the header through `InstallAuthClient` when the iOS lane wires it. A 403 `client.too_old` on the wire is not yet shown as a separate state, because URLSessionWebSocketTask exposes no response body.

### P17-3: RestrictToManagedTeam and AllowedSignInMethods on the client (enterprise lane, 2026-10-03)

- `RestrictToManagedTeam` with `ManagedTeam` (forced values only, through `ManagedPolicyBridge`, applied synchronously at launch): `CloudAuth` lists only the managed team and refuses to select any other. CodeRouter socket and app calls refuse any other team (`managed`). When the account does not belong to the managed team, Cloud sends no request at all. The server-side check belongs to the backend lead (P17-4); the client check only guides the user. Backend question: a request without `X-Cmux-Team-Id` must not fall back to the personal team when the device is restricted.
- `AllowedSignInMethods`: not enforced on the Mac. Sign-in is the hosted web page (`handler/native-sign-in`), and the app cannot hide Stack's methods. Enforcement needs the server, which must refuse a session from a method the team does not allow (backend lead, P17-4), and the web sign-in page, which must offer only the allowed methods (web lane). DECISION for the coordinator: route both.

### P17-5: the MDM schema ships with each release (enterprise lane, 2026-10-03)

`release.yml` uploads the files in `docs/mdm` as release assets: the ProfileManifests plist, the Jamf JSON schema, the Intune plist, the example `.mobileconfig`, the DDM declaration and the key table. The upload uses the same resumable, immutable uploader as the DMG, and the dry run lists the files. URL: `https://github.com/manaflow-ai/cmux/releases/download/<tag>/com.manaflow.cmux.plist`. `ManagedPreferencesManifestTests` keeps `docs/mdm` current with the catalog on every CI run. The release owner should review the workflow change. The rolling NIGHTLY release does not carry these assets.
