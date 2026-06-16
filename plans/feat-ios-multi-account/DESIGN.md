# iOS multi-account support (Case B)

A user with a WORK Stack account and a PERSONAL Stack account wants both signed in on one phone at the same time. Both accounts' paired Macs show in one unified device tree, pushes arrive for both, and tapping a notification lands in the right account's context. This is account-level multiplexing (two distinct Stack users), not team switching within one account.

All findings below are from reading the code at this branch point (`dcab2aa58`). File references are worktree-relative.

## Ground truth: what the code does today

### Auth runtime is already injectable; the singleton hides in the vendored SDK

`AuthCoordinator` (`Packages/CmuxAuthRuntime/Sources/CmuxAuthRuntime/Coordinator/AuthCoordinator.swift`) is `@MainActor @Observable`, constructed once at the composition root (`ios/cmuxPackage/Sources/cmuxFeature/MobileAuthComposition.swift:86`) with everything injected: client, session/user/team caches, presentation anchor, config, launch options, timeouts, clock, reachability, sign-in hook. The bounded sign-in phases from [PR 5728](https://github.com/manaflow-ai/cmux/pull/5728) (`AuthPhase`: send_code, verify_code, password_sign_in, oauth, fetch_user, validate_session, list_teams, post_sign_in, each deadline-guarded by injected `AuthTimeouts`) and the local-first sign-out from [PR 5776](https://github.com/manaflow-ai/cmux/pull/5776) (bounded teardown hook, best-effort `DELETE /auth/sessions/current`, local state cleared regardless) are all per-instance state. Nothing in our runtime assumes a singleton session.

The actual collision is one layer down. iOS passes `TokenStoreInit.keychain` (device) or `.memory` (simulator DEBUG) into `StackAuthClient` (`MobileAuthComposition.swift:130-136`). Those cases route through the Stack SDK's process-wide `TokenStoreRegistry.shared`, which keys stores by **projectId** (`vendor/stack-auth-swift-sdk-prerelease/Sources/StackAuth/TokenStore.swift:60-96`). Two accounts in the same Stack project would share one `KeychainTokenStore` and clobber each other's tokens. macOS already avoids this: `MacAuthComposition` builds its own `FallbackTokenStore` and passes `.custom(tokenStore)` (`Sources/Auth/MacAuthComposition.swift:36-48`). iOS must do the same, with one store per account.

Current keychain literals (`Packages/CmuxAuthRuntime/Sources/CmuxAuthRuntime/TokenStores/KeychainStackTokenStore.swift`):
- service: `"\(bundleIdentifier).auth"` (fallback `"com.cmuxterm.app.auth"`), line 37-42
- accounts: `"cmux-auth-access-token"` / `"cmux-auth-refresh-token"`, lines 19-20

Other process-wide keys that must become per-account:
- `"cmux.notifications.pushEnabled"` and `"cmux.notifications.deviceTokenHex"` in `PushRegistrationService` (`Packages/CmuxAuthRuntime/Sources/CmuxAuthRuntime/Push/PushRegistrationService.swift:24-25`)
- UserDefaults cache keys `"auth_has_tokens"` / `"auth_cached_user"` / `"auth_selected_team"` are already injected per coordinator (`MobileAuthComposition.swift:64,68,72`), so they just need account-suffixed keys at the composition root.

### Paired-Mac store is already account-scoped

`MobilePairedMacStore` (`Packages/CmuxMobilePairedMac/Sources/CmuxMobilePairedMac/MobilePairedMacStore.swift`) is SQLite (`paired-macs.sqlite3`, schema v1 via `PRAGMA user_version`) and **already has a nullable `stack_user_id` column** with an index, scoped queries (`loadAll(stackUserID:)`, `activeMac(stackUserID:)`), and a NULL-safe scoped `setActive` that deliberately avoids wiping another user's active Mac (lines 199-215). `MobileShellComposite` already loads scoped to `identityProvider?.currentUserID` (`Packages/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite.swift:1701`), and `DeviceRegistryService.shouldApplyRegistryRefresh` already rejects refreshes when the captured user differs from the current user (`Packages/CmuxMobileShell/Sources/CmuxMobileShell/DeviceRegistryService.swift:126-136`). The same-account pairing boundary exists today; multi-account reuses it as-is. What's missing is only: backfill of `stack_user_id = NULL` legacy rows, and a UI that shows more than one account's rows at once.

Server side, the device registry is safe: `devices` is unique on `(teamId, deviceUuid)` (`web/db/schema.ts:221`), so one phone registering under two users/teams does not collide.

### Push is the real blocker, on the server

`device_tokens` has a **global unique index on `deviceToken`** (`web/db/schema.ts:131`), and `POST /api/device-tokens` does `onConflictDoUpdate` that silently rewrites `userId` (`web/app/api/device-tokens/route.ts:70-88`). One phone = one APNs token, so registering under account B unregisters account A. Push delivery queries by `userId` only (`web/app/api/notifications/push/route.ts:88`), which is fine once the table allows one token row per (user, token).

APNs payload carries `cmux: { workspaceId, surfaceId }` only (`web/services/apns/payload.ts:48-52`), no account identity, so a tap cannot be routed to the right account. The pending-deeplink machinery from [PR 5927](https://github.com/manaflow-ai/cmux/pull/5927) (`MobilePushCoordinator.PendingDeeplink`: workspaceId/surfaceId/createdAt, 120s expiry, resolved on `bind(store:)` and topology changes) is the right place to add an account hop. `MobilePushCoordinator` binds one `CMUXMobileShellStore` (`Packages/CmuxMobileShellUI/Sources/CmuxMobileShellUI/MobilePushCoordinator.swift:31,54-56`).

Badge: not implemented client-side today; server has no per-user unread state (only `notificationSendEvents` audit rows). Aggregation is therefore green-field, not a refactor.

### Presence is per-instance already

`PresenceClient` (feat-presence-service branch, `Packages/CmuxMobileShell/Sources/CmuxMobileShell/PresenceClient.swift:34-44`) takes injected `serviceBaseURL`, `tokenSource`, `teamIDProvider`, `session`. One WebSocket per instance, team-scoped via `X-Cmux-Team-Id`. N accounts = N clients with each account's token source. The only change is that `MobileShellComposite` holds a single `presence` field (line ~400); it becomes a collection keyed by account.

### Web API

Every route authenticates one user per request via `Authorization` + `X-Stack-Refresh-Token` headers. That model is untouched: each account's runtime sends its own tokens. The only server change Case B needs is the `device_tokens` uniqueness fix above.

## Design

### Account identity and the session list

An account = a Stack user id. New `MobileAccountsStore` (small, SQLite or a codable file in Application Support) persists the ordered list of signed-in accounts: `account_id` (Stack user id), `email`, `display_name`, `added_at`, `last_active_at`. One account is marked **active** — used only where an action inherently needs a single account context (which account "add pairing" runs as, which account a new sign-in flow belongs to). It is not a Slack-style content switcher; all content renders for all accounts.

Bootstrap problem: the account id is only known *after* sign-in, but the token store namespace must be chosen *before*. Solution: sign-in always runs through a **provisional runtime** with a throwaway namespace (in-memory store is fine; sign-in mints fresh tokens). On `fetchUser` success we know the user id; the composition then copies the token pair into the account-namespaced keychain store (`seed(accessToken:refreshToken:)` already exists on `StackAuthTokenStoreProtocol` for exactly this out-of-band pattern) and builds the durable per-account runtime. Signing into an already-signed-in account just refreshes that account's tokens.

### N token stores in keychain

Namespacing: keep the existing service per app bundle and namespace by account in the service suffix:

- legacy (single-account): service `"\(bundleID).auth"`, accounts `cmux-auth-access-token` / `cmux-auth-refresh-token`
- multi-account: service `"\(bundleID).auth.account.\(stackUserID)"`, same account keys

`KeychainStackTokenStore.serviceName(bundleIdentifier:accountID:)` is the single derivation point; `accountID == nil` returns the legacy literal byte-for-byte (this is the migration-safety invariant, covered by the spike test in this PR). `FileStackTokenStore` (the macOS ad-hoc-Debug fallback) namespaces by directory: `<credentialsDir>/accounts/<stackUserID>/credentials.json`, nil = legacy `<credentialsDir>/credentials.json`. Simulator DEBUG keeps `.memory`, one `MemoryTokenStore` per account held by the composition (NOT via the SDK registry).

Migration from today's single store: on first launch with the flag on, if the legacy service holds a token pair and the accounts list is empty, validate the session, read the user id from the cached user (`auth_cached_user`) or `fetchUser`, copy the pair into the account-namespaced store, write the accounts list, then delete the legacy items. If validation fails offline, leave the legacy store in place and retry next launch (no data loss path). Rollback (flag off) keeps working because the legacy read path is attempted first when the accounts list is empty.

### N CmuxAuthRuntime instances and lifecycle

`MobileAuthComposition` becomes `MobileAccountsComposition`:

- holds `[accountID: MobileAccountSession]`, where each session owns its `AuthCoordinator`, `StackAuthClient` (built with `.custom(accountStore)` — never `.keychain`/`.memory` through the SDK registry), per-account UserDefaults keys (`auth_has_tokens.<id>`, `auth_cached_user.<id>`, `auth_selected_team.<id>`), `PushRegistrationService`, `DeviceRegistryService` token source, and `PresenceClient`.
- each coordinator's lifecycle is independent: session restore (`start()`), token refresh, and the bounded sign-in phases run per account. One account's auth failure (refresh death, server-side revocation) signs out only that account.
- sign-out is per account and stays local-first exactly as in PR 5776: bounded teardown hook (now: unregister push *for that account only*, tear down that account's presence subscription), best-effort `DELETE /auth/sessions/current` with that account's tokens, clear that account's namespaced stores, remove it from the accounts list. Other accounts are untouched — this falls out of the namespacing rather than needing new logic, which is why the store split comes first in the slicing.
- the SDK's `TokenStoreRegistry` is bypassed entirely via `.custom`; no SDK changes needed. (The registry also serializes the refresh lock per store, which we keep per account — two accounts can refresh concurrently, which is correct since they're independent sessions.)

UI binding: the root scene currently injects one coordinator via `@Environment`. It instead injects the accounts composition; views that today read "the" coordinator read the *active* account's coordinator; the device tree and push/presence layers iterate all sessions.

### Account-tagged paired Macs + migration

Schema v1 already has `stack_user_id`. Work remaining:

1. **Backfill (schema v2 is not required; this is a data migration):** on first run with the flag on, rows with `stack_user_id IS NULL` are claimed by the migrated legacy account (the same user id the token migration resolved). This matches reality: every existing pairing was created by the only account that has ever been signed in on that install. Keep the NULL-scope query support for safety, but post-migration NULL rows should not exist.
2. Writes always tag with the owning account's user id (already plumbed through `identityProvider?.currentUserID`; the multi-account shell passes the per-account identity instead of a global one).
3. Registry refresh runs per account (each account's `DeviceRegistryService` with its own token source); `shouldApplyRegistryRefresh`'s captured-vs-current user check generalizes from "the current user" to "the account this refresh was started for is still signed in".

### Unified device tree grouped by account

Not a hard switcher: the tree shows **all accounts' Macs at once**, grouped under account section headers (email or display name), each section containing that account's `RegistryDevice` → instances → routes exactly as today (`Packages/CmuxMobileShellUI/Sources/CmuxMobileShellUI/DeviceTreeView.swift`, `DeviceTreeRows.swift`). With one account signed in, headers are suppressed and the tree renders identically to today (zero visual change for existing users, flag on or off).

Data: the tree model becomes `[AccountSection]` where each section is built from that account's registry fetch + paired-Mac rows. Per-account fetch failures degrade per section (stale data + per-section error row), not whole-tree.

Active-account context: connecting/attaching to a Mac uses the owning account's session (it's on the record, not ambient state). Actions that create new state with no owning record — "pair a new Mac", initiating sign-in — use the active account or explicitly ask, never silently the "first" account. Per-account "active Mac" stays per-scope as the store already enforces.

### Per-account presence subscriptions

One `PresenceClient` per account session, each with that account's token source and team provider. `MobileShellComposite.evaluatePresenceSubscription` generalizes to reconcile the set of subscriptions against the set of signed-in accounts (subscribe on add/sign-in, cancel on sign-out, all torn down on background per existing lifecycle). N is small (2-3 accounts realistically); N WebSockets is acceptable, and the DO infrastructure is per-team anyway.

### Push: multi-registration, account-routed taps, aggregated badge

**Server (schema + route):**
- Replace the global `device_tokens_device_token_unique` with a composite unique on `(userId, deviceToken)` (`web/db/schema.ts:131`). One row per account per physical device.
- `POST /api/device-tokens` upserts on the composite key; the cross-user clobber path (`route.ts:60-88`) disappears. The per-user 10-token cap stays per user.
- APNs delivery: dead-token cleanup (`notifications/push/route.ts:115`) must delete the dead token across **all** users, not just the requesting user, since APNs invalidates the token for the device, not the (user, token) pair.
- Payload gains `cmux.accountId` (the Stack user id the notification targets) and keeps workspaceId/surfaceId. Server knows the target user on every send path already, so this is payload plumbing only.

**Client (registration):** each account's `PushRegistrationService` registers the same APNs token hex under its own auth. The cached-token and opt-in UserDefaults keys become per-account. The AppDelegate receives the device token once and fans it out to all sessions. Push opt-in remains a single OS-level permission; per-account registration is independent of it. Sign-out unregisters only that account's row — the offline-sign-out clobber documented above also disappears because re-registration under another account no longer steals the row.

**Tap routing (extends PR 5927):** `PendingDeeplink` gains `accountId`. Resolution order: (1) if `accountId` names a signed-in account, ensure the shell is operating in that account's context (the "account hop"), then run the existing workspace→surface resolution against that account's store binding; (2) if the account isn't signed in (race with sign-out), drop with the existing `ios_push_deeplink_failed` analytics, reason `"account_signed_out"`; (3) legacy payloads without `accountId` resolve against all signed-in accounts' stores — workspace ids are globally unique (UUIDs), so first match wins; ambiguity is practically impossible and falls back to active account. The 120s expiry, partial workspace-then-surface resolution, and cold-launch parking are unchanged.

**Badge:** today there is no badge logic at all, so define it cleanly: server computes per-user unread/badge contribution per send (extend the APNs payload `badge` field), but because APNs `badge` is absolute per device and the device has N accounts, a per-user number is wrong by construction. Two options:

- (a) **Client-aggregated (chosen):** server sends pushes without `badge`; the client maintains a per-account unread count (incremented in the notification service extension or on receipt, cleared per account when that account's content is viewed) and sets `UNUserNotificationCenter.setBadgeCount` to the **sum across accounts**.
- (b) Server-aggregated: server would need to know all accounts on a device to compute a sum — exactly the cross-account linkage the security section forbids the server from needing. Rejected.

(a) requires a notification service extension (or accepting drift when the app isn't running). The design accepts approximate badge counts in v1 (recompute on foreground), and notes the extension as a follow-up.

### Case A (one account, multiple emails/channels) and when to recommend it

Stack supports multiple contact channels (a second email) on one account. If the user's actual need is "my work email and personal email both reach me" or "sign in with either email", Case A solves it with zero client work: add the second email as a contact channel on the one account, keep one session, one set of pairings, one push registration. Recommend Case A when the user does not need separation of teams/pairings/notification identity. Case B is for genuinely distinct identities: separate Stack users, separate team memberships, typically a company-managed work account that must stay separable (and individually sign-out-able) from the personal one. The settings UI copy for "Add account" should hint at this ("If you just want another email on this account, add it at <account settings> instead").

### Settings UI

Settings gains an **Accounts** section (flag-gated):
- list of signed-in accounts (display name, email, avatar if available), active account marked
- **Add account**: launches the standard sign-in flow on a provisional runtime (all entrypoints — magic link, password, OAuth — unchanged; same `AuthPhase` machinery)
- per-account **Sign out**: local-first per-account teardown as designed above
- tapping an account sets it active (context for account-needing actions only)

Single-account users with the flag on see the same section with one row, "Add account" being the only new affordance.

### Security notes

- **No cross-account token use.** Tokens live in per-account keychain services; each `StackAuthClient`, registry client, push service, and presence client is constructed closed over exactly one account's token source. There is no API that takes (account, token) pairs separately, so cross-wiring is a construction-time bug, not a runtime possibility. Code review rule: nothing outside `MobileAccountSession` may hold a token source.
- **Pairing boundary already enforced.** The same-account pairing checks (`shouldApplyRegistryRefresh` user match; store-scoped active-Mac handling; server-side per-team registry keys) are the existing boundary and are reused unchanged. An account's session can only see and attach to Macs whose records carry its own user id.
- The server never learns that two accounts share a device beyond what it can already infer from the shared APNs token hex — which the composite-unique design stores but never joins across users in any user-facing query.
- Keychain items keep `kSecAttrAccessibleAfterFirstUnlock`; per-account services inherit the bundle's data-protection keychain behavior (tagged dev builds remain isolated by bundle-id prefix).

### Localization

New user-facing strings (Accounts section title, "Add account", per-account "Sign out", active-account label, account-hop failure toasts, settings hint pointing at Case A) all go through `String(localized:defaultValue:)` with keys in `Resources/Localizable.xcstrings`, English + Japanese, per repo policy. Account section headers render user data (email/display name), not literals. The localization audit in each PR enumerates the touched surfaces.

### Migration / rollout

Feature flag `mobileMultiAccount` (default off), read at composition time.
- **Flag off:** exactly today's graph: one runtime, legacy keychain service, no Accounts section. No migration runs. Existing users unaffected.
- **Flag on, first launch:** token migration (legacy → namespaced, validated before legacy delete), paired-Mac NULL backfill to the migrated account, push re-registration under the same account (idempotent upsert). All steps idempotent and ordered so a crash mid-migration resumes cleanly (legacy store is deleted last).
- **Flag rollback:** the legacy-first read path keeps a rolled-back build working for the migrated single account (the composition seeds the legacy store from the first account's namespaced store if the legacy one is empty — cheap insurance, removed when the flag is deleted).
- Server schema change (composite unique) ships first and is backward-compatible with old clients (their upserts now create per-user rows instead of clobbering — strictly better even before any client ships).

### Test plan

- **Token stores (unit, Swift Testing, `CmuxAuthRuntimeTests`):** namespacing derivation (legacy literal preserved for nil account — the spike test in this PR); two stores with distinct namespaces hold independent pairs; clear/sign-out of one leaves the other; migration copy-then-delete including the offline-validation-failure path.
- **Coordinator multiplexing (unit):** two `AuthCoordinator`s over fakes (the package's existing `Fakes.swift` infrastructure) sign in/out independently; one account's refresh failure does not touch the other's state; per-account teardown hook receives only its account's tokens (extends the PR 5776 tests).
- **Paired-Mac store (unit, `MobilePairedMacStoreTests`):** NULL backfill migration; scoped queries return only the owning account's rows; active-Mac flips don't cross scopes (exists; extend for two non-NULL scopes).
- **Push (unit + route tests):** composite-key upsert (two users, one token, two rows); dead-token cleanup across users; payload carries accountId; `PendingDeeplink` account-hop resolution incl. signed-out-account drop and legacy payload fallback (extends PR 5927's tests); badge sum across per-account counters.
- **Presence (unit):** subscription set reconciles with account set (subscribe on add, cancel on per-account sign-out).
- **E2E (XCUITest, CI via test-e2e.yml):** flag-on add-second-account flow with the UI-test fixture credentials; unified tree shows two grouped sections; per-account sign-out removes one section and keeps the other attached. Runs on the AWS M4 Pro runner / GitHub Actions per repo policy.
- **Migration dry-run:** a debug-menu action that reports what migration *would* do (legacy tokens present? NULL paired rows count?) for dogfood verification before flipping the flag by default.

### PR slicing

1. **PR1 — token-store namespacing + runtime multiplexing (flag off):** `serviceName(bundleIdentifier:accountID:)` + file-store directory namespacing (spike in this design PR seeds this); iOS composition moves to `.custom` per-account stores (off-flag: single account, legacy namespace — a no-op refactor for current users); `MobileAccountsStore`; provisional-runtime sign-in + token migration; per-account UserDefaults keys. Unit tests above.
2. **PR2 — paired-Mac tagging + unified tree (flag off):** NULL backfill; per-account registry refresh; device tree account grouping (headers suppressed for one account); per-account active-Mac UX.
3. **PR3 — push/badge/deeplink:** server schema composite unique + route fix + payload accountId (ships first, independently safe); client multi-registration; account-hop deeplink; client-aggregated badge.
4. **PR4 — settings + flag-on:** Accounts settings section (add account, per-account sign-out, active marker, Case A hint); localization audit; E2E; migration dry-run debug action; default the flag on after dogfood.

### Open questions

1. Is the same Stack **project** guaranteed for both accounts (work + personal both on cmux's project)? This design assumes yes. If a future enterprise deployment uses a separate Stack project, `AuthConfig` is already per-runtime, so it extends, but the accounts list would need to store the project id per account.
2. Badge v1 without a notification service extension means counts can drift until next foreground. Acceptable for v1, or should PR3 include the extension?
3. Cap on accounts? Two is the asked-for case; the design is N, but UI (tree headers, settings) is being reviewed at N=2-3. Proposal: soft cap at 5, revisit on demand.
4. Should "active account" be visible anywhere outside Settings (e.g. a subtle indicator near "pair new Mac")? Minimal proposal: only on the screens whose actions consume it.
