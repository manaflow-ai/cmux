# Billing attribution (PostHog)

Answers "how did this paying customer get to Stripe?": which page or app button, from which client (Mac, web, CLI) and release channel (stable, NIGHTLY, DEV), with which campaign tags. Every checkout entrypoint tags its link, the checkout route stores the tags on the Stripe Checkout Session and Subscription, and the webhook copies them onto every PostHog billing event. Attribution never changes what is sold; malformed values normalize to `unknown` / `web` rather than failing checkout.

## Link contract

Query parameters accepted by `/api/billing/checkout`, `/app-pricing` and `/pricing` (both pages forward them to their checkout links):

| parameter | values | set by |
| --- | --- | --- |
| `cmux_source` | `[a-z0-9_.:-]` token, max 64 | the surface that shows the link (table below) |
| `cmux_placement` | same shape | the button inside the surface (`pricing_page`, `pricing_compare_header`, `app_pricing`, `dashboard_billing`) |
| `cmux_client` | `web` `mac` `ios` `tui` `cli` | the app that opened the link; default `web` |
| `cmux_channel` | `stable` `nightly` `dev` `rc` `staging` | Mac `BuildFlavor`; web has none |
| `cmux_app_version`, `cmux_app_build` | `CFBundleShortVersionString`, `CFBundleVersion` | Mac |
| `utm_source` `utm_medium` `utm_campaign` `utm_content` `utm_term` | free text, max 100 | campaigns |

The `Referer` header adds `checkout_referrer_host` and `checkout_referrer_path` on every checkout, tagged or not; for untagged links it is the only origin signal.

Sources today:

| `cmux_source` | where |
| --- | --- |
| `pricing_page` | cmux.com/pricing (default; an inbound `cmux_source` on the page URL wins) |
| `app_pricing` | `/app-pricing` opened by an app build that predates the Mac tags |
| `dashboard_billing` | dashboard billing page |
| `mac_sidebar_badge` | sidebar footer "Upgrade" capsule |
| `mac_sidebar_account_menu` | sidebar account menu item |
| `mac_sidebar_help_menu` | sidebar help (?) menu item |
| `mac_help_menu` | Help menu bar item |
| `mac_command_palette` | command palette |
| `mac_settings_account_card` | Settings > Account card |
| `mac_settings_cloud_machines` | Settings > Cloud machines billing |
| `mac_machines_panel_requires_pro` | machines panel empty state |
| `mac_cloud_welcome` | "Introducing cmux Cloud" welcome window (Free plan) |
| `mac_machines_panel_upgrade_nudge` | nudge under the create button |
| `mac_machines_panel_trial_banner` | free-access countdown / expired banner |
| `mac_machines_panel_machine_action` | row action that needs a paid plan |
| `mac_new_machine_at_limit` | new machine sheet at the free limit |
| `mac_native_pricing_preview` | DEBUG native pricing window |
| `mac_vm_requires_pro_error` | link inside the `vm_requires_pro` error text |
| `cli_free_access_expiry` | link printed by the CLI free-access notice |
| `unknown` | link with no tag (old builds, hand-typed URL) |

The Mac enum is `ProUpgradeSource` in `Sources/PricingPlansScreen.swift`; `ProUpgradePresenter.present(source:)` is the only way to open the upgrade flow, so a new surface must name itself.

## Events

All billing events use the Stack user id as `distinct_id` (teams: `stack-team:<id>` plus the `stack_team` group). Every event below carries `checkout_source`, `checkout_placement`, `checkout_client`, `checkout_channel`, `checkout_app_version`, `checkout_app_build`, `checkout_referrer_host`, `checkout_referrer_path`, `utm_*`.

| event | when | extra properties |
| --- | --- | --- |
| `cmux_billing_checkout_started` | checkout route created a Stripe session | `plan`, `billing_interval`, `signed_in` (false = anonymous Stack user minted for a signed-out visitor), `existing_stripe_customer` (lapsed or canceled before), `stripe_checkout_session_id` |
| `cmux_billing_checkout_completed` | `checkout.session.completed` / `async_payment_succeeded` | `amount_total`, `amount_discount`, `promotion_applied`, `payment_method_types`, `customer_country`, `checkout_duration_seconds` (Stripe form time), `$set.billing_plan`, `$set_once.first_paid_checkout_*` |
| `cmux_billing_checkout_expired` | `checkout.session.expired` (buyer never paid, ~24h) | `plan`, `billing_interval`, `amount_total` |
| `cmux_billing_subscription_created/updated/deleted` | subscription webhooks; attribution read from subscription metadata | `subscription_status`, `cancel_at_period_end`, `cancellation_reason`, `cancellation_feedback` |
| `cmux_billing_invoice_paid`, `cmux_billing_invoice_payment_failed`, `cmux_billing_charge_refunded` | unchanged | |
| `cmux_upgrade_entrypoint_opened` | Mac client, on every upgrade click; the Stack user id when signed in, else the install's anonymous id (linked on sign-in) | `source`, `client`, `plan`, `destination`, `channel`, `app_version`, `app_build`; the rest of the Mac funnel is in [mac-product-analytics.md](mac-product-analytics.md) |

Person properties written on the first paid checkout and never overwritten: `first_paid_checkout_at`, `first_paid_checkout_source`, `first_paid_checkout_placement`, `first_paid_checkout_client`, `first_paid_checkout_channel`, `first_paid_checkout_app_version`, `first_paid_checkout_utm_source`, `first_paid_checkout_utm_campaign`.

Mac events also carry `channel` (`stable`, `nightly`, `dev`) next to `app_version` and `app_build`.

`checkout.session.expired` must be enabled on the production Stripe webhook endpoint (`https://cmux.com/api/stripe/webhook`); the route ignores unknown event types, so enabling it early is safe.

## Questions this answers

- Paid conversions by surface: `cmux_billing_checkout_completed` broken down by `checkout_source`.
- Pricing page vs in-app Upgrade button: `checkout_client = web` vs `mac`, then `checkout_source`.
- Stable vs NIGHTLY buyers: `checkout_channel` on completed events; `first_paid_checkout_channel` on persons.
- Conversion rate per surface: started vs completed vs expired, grouped by `checkout_source`.
- Which CTA on the pricing page converts: `checkout_placement`.
- Signed-in vs signed-out starts and whether lapsed customers come back: `signed_in`, `existing_stripe_customer` on started events.
- Promo usage, payment method, country, form time: the completed event's extra properties.
- Churn feedback by acquisition surface: `cmux_billing_subscription_deleted` keeps the original `checkout_source` from subscription metadata.

Dashboard: cmuxterm-hq `scripts/posthog-billing-dashboard.py` ("Billing attribution").

## Identity of Stripe billing events (2026-10)

Stripe billing events are sent only from production (`VERCEL_ENV=production`,
or `CMUX_SERVER_ANALYTICS_FORCE=1`) and carry `livemode` and `vercel_env`.
User-scope events are keyed by the Stack user. Team checkout events
(`cmux_billing_checkout_started`, `_completed`, `_expired`) are keyed by the
purchasing admin with the `stack_team` group, and the completed event sets
that admin's `billing_plan` to `team`. Every other team event (subscription
changes, invoices, refunds) keeps `distinct_id: stack-team:<team id>` but is
person-less (`$process_person_profile: false`), so it creates no person.
PostHog does not link person-less events to groups: break those down by the
`stack_team_id` property. Funnels built on the old `stack-team:` person for
team checkouts must switch to the admin person or the group.
