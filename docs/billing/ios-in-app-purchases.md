# iOS in-app purchases

The iOS app sells cmux personal plans through StoreKit 2. RevenueCat is not used. The web server is the source of truth: it verifies every Apple transaction, records every App Store Server Notification, applies the plan entitlement, and feeds analytics.

## Products

Personal plans only. Team stays web-only (per-seat, invoiced to a team).

| Plan | Web (Stripe) | iOS (App Store, USD base) | Net at 30% | Net at 15% |
| --- | --- | --- | --- | --- |
| Go | $10/mo | $14.99/mo | $10.49 | $12.74 |
| Pro | $50/mo | $74.99/mo | $52.49 | $63.74 |
| Max | $200/mo | $299.99/mo | $209.99 | $254.99 |

The iOS price is the web price divided by 0.7 (Apple's first-year commission), rounded up to the next `.99` price point with a few dollars of margin. This matches what YouTube Premium, Spotify (historically), Tinder, and Bumble do: iOS buyers pay more so net revenue per plan is never below web. After a subscriber's first year, or under the Small Business Program, Apple takes 15% and the margin grows. Other storefronts use Apple's automatic equalization from the US base price.

All products are auto-renewable, monthly, in one subscription group so upgrades and downgrades are Apple-managed (Max > Pro > Go, level 1 highest). No introductory offers or free trials.

Product IDs are prefixed with the bundle ID, so the App Store app and the TestFlight beta app each own their products:

- `<bundleId>.go.monthly`, `<bundleId>.pro.monthly`, `<bundleId>.max.monthly`
- App Store app: bundle `com.cmux.app` (Apple ID 6783338052). Beta: `dev.cmux.app.beta`. Dev builds use a local StoreKit configuration file.

Go is listed only when the server reports it enabled (the Go PostHog flag), same as web.

## Account linking

Every purchase carries `appAccountToken`, a UUID the server mints once per cmux user and stores (`apple_account_tokens`). The app-posted route rejects a transaction whose token maps to a different user than the caller, or that the server never minted, so one account cannot replay another's transaction. This links Apple subscriptions to cmux accounts without trusting the client. A transaction without a token (an offer code redeemed outside the app) may be claimed by the signed-in user only while no other account owns its original transaction.

The token on the newest transaction decides the owner. When the same Apple ID signs into another cmux account and buys again (an upgrade or a resubscribe), the new transaction carries that account's token, and Apple keeps one original transaction ID for the subscription group. A transaction newer than the stored one (a different transaction ID with a later purchase date) whose token maps to a known cmux user other than the row's owner moves the row to that user and updates `app_account_token`, through either the app-posted route or a notification. Both users' plans are then re-derived; the previous owner falls back to Stripe or free. A token-less transaction, an unknown token, or an older transaction never moves a subscription, and an app post that would leave the row owned by someone else gets 403 `account_mismatch`. If re-deriving the previous owner fails, the stale `cmuxPlan` mirror is corrected by the next read-time reconciliation.

## Server API (web/app/api/billing/apple)

All authenticated routes use the same Stack auth as the other `/api/billing/*` routes (cookie or native bearer + refresh token headers).

- `POST /api/billing/apple/account-token` (auth). Response: `{ appAccountToken, eligible, reason, currentPlan: { planId, source: "stripe" | "apple" | "none", manageUrl? }, products: [{ productId, planId }] }`. `eligible` is false when the user already has an active Stripe subscription, is billed through a team, or this build's purchases would grant no plan; `reason` is a stable code (`stripe_subscription_active`, `team_billing`, `purchases_unavailable`, in that precedence) the app localizes. `products` lists only plans currently sold (Go hidden when its flag is off), for the bundle ID in the `x-cmux-bundle-id` header, and is empty for `purchases_unavailable`. The app sends `x-cmux-storekit-environment` (`Sandbox` or `Production`, read from the signed `AppTransaction`); the server applies the Sandbox entitlement policy (see Entitlement) to that bundle and environment and answers `purchases_unavailable` when a purchase would grant nothing, so a TestFlight build against production never shows a completed purchase with no plan. Without the header, the App Store bundle is assumed Production and every other bundle Sandbox (TestFlight builds always buy in the Sandbox).
- `POST /api/billing/apple/transactions` (auth). Body: `{ signedTransactionInfo: string }` (the StoreKit 2 `jwsRepresentation`). Verifies the JWS chain against Apple's root CA, checks bundle ID, environment, and `appAccountToken` ownership, fetches the current subscription status from the App Store Server API, upserts, applies the entitlement. Response: `{ planId, status, expiresAt }`. Idempotent. Errors: 400 `invalid_transaction` (bad signature, unknown bundle, Xcode/LocalTesting environment), `not_subscription`, `unknown_product`; 403 `account_mismatch`; 503 `verification_unavailable` when Apple's OCSP check is unreachable. Without an App Store Server API key, or when Apple is unreachable, the verified client transaction is used as is.

  The app finishes a transaction only after a 2xx. Transport errors, 5xx, and 401 (signed out) are retried at launch, sign-in, foreground, and on the plans screen. 400, 403, 404, 409, and 422 are permanent: the purchase shows a terminal error (403 `account_mismatch` says the subscription belongs to another cmux account and to sign in with it), and the app stops re-posting that transaction automatically until the account changes. It never finishes it, so signing in to the owning account still delivers it. Restore Purchases posts it again because the user asked.
- `POST /api/billing/apple/notifications` (public, called by Apple). Body: `{ signedPayload }` (App Store Server Notifications V2). Verifies the envelope and its nested transaction and renewal JWS, writes the ledger row first (idempotent on `notificationUUID`), then upserts subscription state and applies the entitlement. A notification about an older transaction than the row's latest (`REFUND`, `REFUND_DECLINED`, or `REFUND_REVERSED` for a past period) records only its `apple_transactions` row, with the revocation; the subscription row keeps the current period. With an App Store Server API key, the server instead fetches Apple's current status for the subscription and writes that. A refund of the current transaction revokes the subscription. Returns 200 once the ledger row is durable, even if entitlement application fails (a retry job re-applies). Returns 4xx only for payloads that fail verification, and 503 when the ledger write itself failed so Apple redelivers.
- `GET /api/cron/apple-notifications` (Vercel cron, `CRON_SECRET`, at :17 and :47). Re-applies ledger rows whose `processed_at` is null (failed or never run), then sweeps lapsed grants: rows still `active`, `grace_period`, or `billing_retry` whose access end, `greatest(expires_at, grace_period_expires_at)`, is past and later than the row's `updated_at` (no write or sweep since the lapse), oldest lapse first, 200 per run. For each user it re-derives the plan, then marks that user's rows swept: `active` becomes `expired`, `grace_period` becomes `billing_retry` (Apple may still recover it), and `updated_at` moves to the sweep time, so a row matches once per lapse. A failed re-derive leaves the rows unmarked for the next run.

`GET /api/billing/plan` adds `billingSource` (`stripe` | `apple` | `none`) and `manageUrl` (`https://apps.apple.com/account/subscriptions` for Apple). For an App Store subscriber with no recoverable Stripe subscription, `billingManagement` is `external`, a value every installed client already decodes. Personal Stripe checkout redirects an App Store subscriber to `/dashboard/billing`, and the pricing and billing pages show "Manage in the App Store" instead of Stripe checkout.

The same handler serves Production and Sandbox payloads; the `environment` field selects the App Store Server API host.

## Data (Drizzle, Postgres)

- `apple_account_tokens`: `user_id` (pk), `app_account_token` (uuid, unique), `created_at`.
- `apple_subscriptions`: `original_transaction_id` (pk), `user_id`, `app_account_token`, `bundle_id`, `environment`, `product_id`, `plan_id`, `status` (`active` | `grace_period` | `billing_retry` | `expired` | `revoked`), `auto_renew_enabled`, `auto_renew_product_id`, `purchase_date`, `original_purchase_date`, `expires_at`, `storefront`, `currency`, `price_milliunits`, `last_transaction_id`, `revoked_at`, `revocation_reason`, `grace_period_expires_at` (from renewal info; billing retry grants only before it), `state_signed_at` (Apple `signedDate` of the data the row was built from; an older payload never overwrites the row), `created_at`, `updated_at` (last write or lapse sweep). The row always describes the latest transaction for its original transaction ID: a payload about an older transaction (earlier purchase date, different `last_transaction_id`) never overwrites it, even when it was signed later. `user_id` follows the newest transaction's token (see Account linking).
- `apple_transactions`: `transaction_id` (pk), `original_transaction_id`, `user_id`, `product_id`, `plan_id`, `environment`, `type`, `purchase_date`, `expires_at`, `price_milliunits`, `currency`, `storefront`, `offer_type`, `revoked_at`, `payload` (jsonb, decoded), `created_at`. One row per renewal, refund, and upgrade, which is what revenue analytics read. `type` is Apple's `transactionReason` (`PURCHASE` or `RENEWAL`); a refund sets `revoked_at` on the refunded transaction.
- `apple_notifications`: `notification_uuid` (pk), `notification_type`, `subtype`, `environment`, `original_transaction_id`, `signed_date`, `payload` (jsonb, decoded, nested JWS replaced by their verified decoded values), `received_at`, `processed_at`, `error`. A failed application keeps `processed_at` null and sets `error`. A notification that can never apply (no linked cmux account, an unknown product, `TEST`, `CONSUMPTION_REQUEST`) is closed with `processed_at` and `error` = `skipped: <reason>`.

Migration: `web/db/migrations/20261002120000_apple_in_app_purchases`.

## Entitlement

An Apple subscription in `active`, `grace_period`, or `billing_retry` (Apple keeps access during retry only inside the grace period; follow `gracePeriodExpiresDate`) grants its plan through the same entitlement path Stripe fulfillment uses, with the source recorded as `apple`. When both sources exist, the higher plan wins, and Stripe reconciliation must not remove an Apple-granted plan (and vice versa). Expiry, refund, and revocation remove the Apple grant.

Mechanism: the `cmuxPlan` mirror in Stack `clientReadOnlyMetadata` is the single entitlement. Every write of it (`syncProPlanMetadata` in Stripe fulfillment, read-time reconciliation, and the Apple flows) computes the highest of the active Stripe plan and the granting Apple plan, so neither source can clear or downgrade the other. Grants are time-checked on read (`expires_at`, `grace_period_expires_at`), so a missed notification cannot extend access. An operator `cmuxVmPlan` override still wins and is never rewritten.

Sandbox purchases are free, so in production deployments a Sandbox subscription grants a plan only for the App Store bundle `com.cmux.app` (App Review buys in the Sandbox against production). TestFlight purchases of the beta bundle are recorded but grant nothing in production, so the account-token route answers `purchases_unavailable` and lists no products to those builds. Other deployments grant every Sandbox purchase. `APPLE_IAP_SANDBOX_ENTITLEMENTS` (`all`, `none`, or a bundle list) overrides both.

## Analytics (RevenueCat parity)

Server-side PostHog events, one per App Store Server Notification that changes subscriber-visible state (deduplicated by `notificationUUID`, timestamped at the notification's `signedDate`), keyed by the cmux user id: `subscription_started`, `subscription_renewed`, `subscription_plan_changed`, `subscription_cancel_scheduled` (auto-renew off), `subscription_resubscribed`, `subscription_billing_issue`, `subscription_grace_period_entered`, `subscription_expired`, `subscription_refunded`, `subscription_revoked`. Properties: `source` (`apple` | `stripe`), `plan_id`, `product_id`, `storefront`, `currency`, `price` (gross, local currency), `price_usd_estimate`, `net_usd_estimate` (commission 30%, or 15% after one year of paid service), `environment`, `original_transaction_id`. Apple events also carry `notification_type`, `notification_subtype`, and `auto_renew_product_id`. Mapping: `SUBSCRIBED` (`INITIAL_BUY` started, `RESUBSCRIBE` resubscribed), `DID_RENEW` renewed, `DID_CHANGE_RENEWAL_PREF` plan_changed (`UPGRADE` takes effect now, `DOWNGRADE` at renewal), `DID_CHANGE_RENEWAL_STATUS` `AUTO_RENEW_DISABLED` cancel_scheduled, `DID_FAIL_TO_RENEW` (`GRACE_PERIOD` grace_period_entered, otherwise billing_issue), `EXPIRED` expired, `REFUND` refunded, `REVOKE` revoked. `GRACE_PERIOD_EXPIRED`, `REFUND_REVERSED`, `PRICE_INCREASE`, `RENEWAL_EXTENDED`, auto-renew re-enabled, `CONSUMPTION_REQUEST`, and `TEST` update state (or are only recorded) without an event. The `price_usd_estimate` is exact for USD storefronts and the plan's US list price elsewhere. Stripe does not emit these events yet; it keeps its existing `cmux_billing_*` events.

The cmux-admin app page `/subscriptions` (data from `GET /api/admin/subscriptions/analytics`) shows, filterable by source and plan: active subscriptions, MRR gross and net, new subscriptions, churn, refunds, billing-issue and grace counts, revenue by storefront, and monthly cohort retention. Sandbox data is excluded unless toggled.

The iOS app sends client events (`ios_paywall_viewed`, `ios_purchase_started`, `ios_purchase_cancelled`, `ios_purchase_failed`, `ios_purchase_pending`, `ios_restore_started`, `ios_restore_completed`) through its existing analytics path (`/api/analytics/events`, which accepts only allowlisted `ios_`-prefixed names in `web/services/analytics/iosEventPolicy.ts`) so the paywall funnel joins the server lifecycle events. Properties: `entry_point` (`settings` | `cloud_upgrade`), `product_id`, `plan_id`, and `reason` on failures; `success` and `restored_count` on `ios_restore_completed`.

## Configuration

Server env: `APPLE_IAP_KEY_ID`, `APPLE_IAP_ISSUER_ID`, `APPLE_IAP_PRIVATE_KEY` (In-App Purchase `.p8` contents, for the App Store Server API), `APPLE_IAP_BUNDLE_IDS` (`com.cmux.app,dev.cmux.app.beta`), `APPLE_IAP_APP_APPLE_ID` (`6783338052`, required to verify Production payloads). The bundle IDs and app Apple ID default to these values. Optional: `APPLE_IAP_SANDBOX_ENTITLEMENTS` (see Entitlement), `APPLE_IAP_ONLINE_CHECKS` (`1`/`0`; OCSP revocation checks of Apple's certificates, on by default only when `VERCEL_ENV=production`). Apple's root certificates (G3 and G2) are bundled in `web/services/billing/apple/certs` and inlined in `rootCertificates.ts`; a test checks both against Apple's published SHA-256 fingerprints.

Server env values: `APPLE_IAP_KEY_ID=976787J9XZ` (In-App Purchase key "cmux server IAP"), `APPLE_IAP_ISSUER_ID=94d76068-119d-45cd-8700-86eb7a1a6235`. The `.p8` is kept outside the repo; never commit it.

App Store Connect, set on both apps (`com.cmux.app` 6783338052 and `dev.cmux.app.beta` 6757092429): Server Notifications V2 Production URL `https://cmux.com/api/billing/apple/notifications`, Sandbox URL `https://cmux-staging.vercel.app/api/billing/apple/notifications`.

Subscription group "cmux Plans" (localized name "cmux", en-US and ja) per app, all products monthly, available in all 175 territories with Apple-equalized prices from the US base, no introductory offers:

| Product ID | ASC ID | Level | USD |
| --- | --- | --- | --- |
| `com.cmux.app.max.monthly` | 6818444182 | 1 | 299.99 |
| `com.cmux.app.pro.monthly` | 6818444960 | 2 | 74.99 |
| `com.cmux.app.go.monthly` | 6818445194 | 3 | 14.99 |
| `dev.cmux.app.beta.max.monthly` | 6818446208 | 1 | 299.99 |
| `dev.cmux.app.beta.pro.monthly` | 6818447766 | 2 | 74.99 |
| `dev.cmux.app.beta.go.monthly` | 6818447955 | 3 | 14.99 |

Group IDs: `com.cmux.app` 22433557, `dev.cmux.app.beta` 22433386. Display names "cmux Max", "cmux Pro", "cmux Go" (en-US and ja). Descriptions, en-US / ja: Max "Up to 5 Cloud VMs, up to 16 vCPUs and 32 GB RAM per VM" / "クラウドVM最大5台、1台あたり最大16 vCPU・32 GB RAM"; Pro "Up to 5 Cloud VMs, up to 4 vCPUs and 8 GB RAM per VM" / "クラウドVM最大5台、1台あたり最大4 vCPU・8 GB RAM"; Go "1 Cloud VM with 40 VM-hours a month" / "クラウドVM 1台、月40 VM時間".

The products are in `MISSING_METADATA` until each gets an App Review screenshot of the paywall. The first subscriptions for an app must be submitted with an app version.
