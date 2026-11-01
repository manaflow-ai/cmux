# Mac product analytics (PostHog)

The macOS app's activation, Cloud conversion and retention events. They go to
the main cmux project (`244066`), alongside `cmux_daily_active`, the web and
the server's `cmux_billing_*` and `cloud_vm_*` events.

Source of truth: `ProductAnalyticsEvent` in
`Packages/macOS/CmuxProductAnalytics`. `ProductAnalyticsEventCatalogTests` pins
every name and property key. When you rename one, change this page and the
saved insights in the same PR.

## Pipeline and privacy

- `ProductAnalytics` enqueues each call and returns immediately. An off-main
  actor deduplicates, merges the shared properties and hands events to the
  PostHog SDK the app already embeds. The SDK owns batching, retries and the
  on-disk queue that survives offline launches. No call site waits, and none
  sits on the typing, terminal output or drag paths.
- Nothing is sent when **Settings > Send anonymous telemetry** is off, when the
  managed `DisableTelemetry` policy is set, under XCTest, or in debug builds
  without `CMUX_POSTHOG_ENABLE=1`. In those launches the emitter is disabled
  and enqueues nothing.
- Properties are enums, counts, booleans, version strings and duration
  buckets. Free-text values collapse to `other`. Events never carry terminal
  content, paths, commands, prompts, hostnames, repository names, emails or
  error messages. Agent session ids are used only for dedupe, in memory.

## Identity

| Concept | Value |
| --- | --- |
| `distinct_id` | Signed out: the install's anonymous PostHog id. Signed in: the Stack user id, the same id the server's billing and `cloud_vm_*` events use. |
| Identity owner | `PostHogIdentityObserver` (#20565) identifies on sign-in or restore and resets on sign-out. Product analytics does not call `identify` itself. After a reset, `PostHogAnalytics` restores the product context super properties. |
| Anonymous to signed in | The first `identify` from an anonymous state sends `$anon_distinct_id`, which merges pre-sign-in activity (first launch, first split, upgrade clicks) into the account. |
| Sign-out | `cmux_signed_out` is captured when sign-out starts, before the reset, so it joins the account. |
| `$groups.stack_team` | Not set by the Mac yet. A PostHog group lasts until `reset()`, so it belongs with the identity observer that owns reset (suggested on #20565). Server billing events already carry it. |

Feature flags evaluate against the same distinct id, so a signed-in user's
rollout bucket follows their account across devices.

## Shared properties

These are sent on every event below. They are also registered as super
properties, so `cmux_daily_active`, `cmux_hourly_active` and
`cmux_cloud_vm_request` carry them too.

| Property | Values |
| --- | --- |
| `app_version`, `app_build` | bundle version and build |
| `channel` | `stable`, `nightly`, `rc`, `dev` |
| `os_version` | macOS `major.minor` |
| `account_plan` | `free`, `paid`, `unknown` (signed out or not loaded) |
| `is_signed_in` | bool |
| `cloud_enabled` | bool |
| `workspaces_open` | `0`, `1`, `2_3`, `4_7`, `8_15`, `16_plus` (refreshed on app activation and when a workspace opens or closes) |
| `platform` | `cmuxterm` (existing super property) |

Duration buckets: `lt_1s`, `1s_3s`, `3s_10s`, `10s_30s`, `30s_60s`, `1m_3m`,
`3m_10m`, `10m_60m`, `1h_24h`, `1d_7d`, `gt_7d`.

## Events

### Upgrade funnel

| Event | Fires when | Properties | Answers |
| --- | --- | --- | --- |
| `cmux_upgrade_prompt_shown` | An Upgrade entrypoint becomes visible. Covers the sidebar footer badge, the Cloud welcome card on the Upgrade step, the Cloud panel's nudge, the free-access banner and the create-at-limit screen. At most once per source per launch. | `source` (`ProUpgradeSource` token), `plan` (offered plan) | Click-through rate per surface |
| `cmux_upgrade_entrypoint_opened` | Any Upgrade click (every `ProUpgradeSource`). This is the existing event name; the keys are unchanged plus `destination`. | `source`, `client: mac`, `plan`, `destination` (`pricing_page`, `checkout`) | Upgrade clicks by surface; the first funnel step |
| `cmux_upgrade_badge_dismissed` | The sidebar badge's X | `source` | Badge fatigue |
| `cmux_billing_checkout_started` / `_completed` / `_expired` | Server, see [billing-attribution.md](billing-attribution.md) | `checkout_source` = the same `source` token | Checkout opened, paid, or abandoned |
| `cmux_plan_activated` | The app first sees the signed-in account as paid after it was free, or within 7 days of an upgrade click | `upgrade_source` (last click's source or `none`), `since_upgrade_click` (bucket or `none`) | Plan active in the app; time from click to activation |
| `cmux_plan_deactivated` | Same account went from paid to free | none | Downgrade (churn) |

### Sidebar Cloud button

The cloud icon in the sidebar footer, between Help and Upgrade.

| Event | Fires when | Properties | Answers |
| --- | --- | --- | --- |
| `cmux_cloud_button_shown` | The button becomes visible (Cloud available and the sidebar icon setting on). At most once per launch. | none | Reach, so clicks become a rate |
| `cmux_cloud_button_clicked` | A press | `action` (`open_cloud` when Cloud is on, `introduce_cloud` when it is off or signed out) | How often the button is the way into Cloud |

An `introduce_cloud` press is followed by `cmux_cloud_welcome_shown` with
`trigger = sidebar_cloud_button`, then the card's button and closed events.
That connects the button to Upgrade, checkout and enable.

### Cloud welcome card

| Event | Fires when | Properties | Answers |
| --- | --- | --- | --- |
| `cmux_cloud_welcome_shown` | The "Introducing cmux Cloud" card opens | `trigger` (`launch_announcement`, `new_cloud_workspace`, `new_cloud_machine`, `sidebar_cloud_button`, `debug_menu`), `next_step` (`upgrade`, `enable`, `sign_in`, `open_cloud`) | Reach of the announcement and of the Cloud-off/signed-out gate |
| `cmux_cloud_welcome_button_clicked` | Upgrade, Enable, Sign in, Open Cloud, or Not now (including the card's × and Escape) | `trigger`, `next_step`, `button` | Which choice each trigger leads to |
| `cmux_cloud_welcome_closed` | Exactly once per shown card | `trigger`, `next_step`, `outcome` (a button or `window_closed`), `visible_for` | Outcome and dwell time |

Enable's result is `cmux_cloud_enable_completed`. Upgrade continues as
`cmux_upgrade_entrypoint_opened` with `source = mac_cloud_welcome`.

### Account

| Event | Fires when | Properties |
| --- | --- | --- |
| `cmux_sign_in_started` | The user starts a sign-in (Sign In, pane sign-in, Switch Account) | none |
| `cmux_sign_in_succeeded` | That sign-in completes. A session restore does not count. | none |
| `cmux_sign_in_failed` | That sign-in fails, once per attempt | `reason` (`offline`, `network`, `timed_out`, `server`, `invalid_link`, `browser_unavailable`, `unauthorized`, `rejected`, `cancelled`, `rate_limited`) |
| `cmux_signed_out` | The account signs out (captured before the identity reset) | none |

### Cloud

| Event | Fires when | Properties |
| --- | --- | --- |
| `cmux_cloud_enable_completed` | An Enable attempt settles | `result` (`success`, `requires_paid_plan`, `sign_in_required`, `service_unavailable`, `unavailable`, `cancelled`) |
| `cmux_cloud_disabled` | Cloud turned off | none |
| `cmux_cloud_machine_create_started` | The New Machine sheet submits | `memory_gb` (absent for Base setup and forks, which send no size) |
| `cmux_cloud_machine_create_succeeded` | A create finishes, from any launcher | `duration` |
| `cmux_cloud_machine_create_failed` | A create fails | `error_class` (`plan_limit`, `auth`, `network`, `server`, `client`, `cancelled`), `error_code` (server token or `unknown`), `consecutive_failures` |
| `cmux_cloud_machine_deleted` | A machine delete request succeeds | none |
| `cmux_cloud_machine_attached` | A machine's attach endpoint request finishes | `success`, `latency`, `error_class` on failure |
| `cmux_cloud_workspace_created` | New Cloud Workspace finishes | `machine_choice` (`resolved`, `explicit`), `duration` |
| `cmux_cloud_plan_limit_hit` | A Cloud request is refused by a plan limit | `limit` (`requires_paid_plan`, `active_machines`, `machine_memory`, `resource_pool`, `resize_size`, `credits`, `team_billing`), `operation` (`create`, `resize`, `restore`, `fork`, `machine_action`, `other`) |

The server's `cloud_vm_created` stays the authoritative machine count. The
client events add what the user saw: failures, latency, and the path taken.

### Activation and engagement

| Event | Fires when | Properties |
| --- | --- | --- |
| `cmux_activation_milestone_reached` | First time per install | `milestone` (`first_launch`, `first_workspace`, `first_split`, `first_browser_pane`, `first_agent_session`, `first_sign_in`, `first_upgrade_click`, `first_cloud_enable`, `first_cloud_machine`, `first_cloud_workspace`, `first_paid_plan`), `is_new_install`, `days_since_install` |
| `cmux_agent_session_started` | An agent's SessionStart hook. A session that outlived a relaunch is not started again. | `agent` (`claude_code`, `codex`, `opencode`, `gemini`, `cursor`, `pi`, `other`) |
| `cmux_agent_session_ended` | The SessionEnd hook of a session counted as started | `agent` |
| `cmux_feature_used` | First use per UTC day | `feature` (`command_palette`, `files_explorer`, `git_graph`, `herd`, `find`, `vault`, `feed`, `dock`, `cloud_sidebar`, `custom_sidebar`, `devices`, `cmux_ssh`, `browser_pane`, `split`) |
| `cmux_app_updated` | A launch runs a different version than the previous one | `direction` (`upgrade`, `downgrade`), `from_version`, `to_version` |
| `cmux_daily_active` | Existing: once per UTC day | existing properties plus the shared properties above |

Installs that ran before this catalog shipped get `is_new_install = false` and
never report `first_launch`. Filter activation funnels to
`is_new_install = true`. Every launch opens a terminal, so there is no "first
terminal" milestone; `first_launch` covers it. Uninstall is not observable.
Churn signals are `cmux_cloud_disabled`, `cmux_signed_out`,
`cmux_plan_deactivated`, `consecutive_failures` on
`cmux_cloud_machine_create_failed`, `cmux_app_updated` with `direction =
downgrade`, and absence from `cmux_daily_active`.

Existing events that are unchanged: `cmux_hourly_active`,
`cmux_cloud_vm_request`, `cmux_vm_size_upgrade_prompted`, `$exception`.

## Insights to build

1. **Activation funnel (new installs).** Steps are `cmux_activation_milestone_reached`
   filtered to `milestone` in this order: `first_launch`, then
   `first_split` or `first_agent_session`, then `first_sign_in`, then
   `first_cloud_enable`, then `first_cloud_machine`. Filter
   `is_new_install = true`, use a 14-day window, and break down by
   `channel`.
2. **Cloud upgrade funnel by source.** Steps:
   - `cmux_upgrade_prompt_shown`
   - `cmux_upgrade_entrypoint_opened`
   - `cmux_billing_checkout_started`
   - `cmux_billing_checkout_completed`
   - `cmux_plan_activated`

   Break down by `source` on the client steps, `checkout_source` on the
   server steps and `upgrade_source` on `cmux_plan_activated`; all three carry
   the same `ProUpgradeSource` token. The client and server steps join on the
   Stack user id once the app is signed in.
3. **Sidebar Cloud button.** `cmux_cloud_button_clicked` per `cmux_cloud_button_shown`, by
   `action`; then the funnel `cmux_cloud_button_clicked` (`action = introduce_cloud`),
   `cmux_cloud_welcome_closed` (`trigger = sidebar_cloud_button`), `cmux_upgrade_entrypoint_opened`
   (`source = mac_cloud_welcome`), `cmux_billing_checkout_completed`.
4. **Welcome card outcomes.** Count `cmux_cloud_welcome_closed` broken down by
   `trigger` × `outcome`, plus the funnel `cmux_cloud_welcome_shown`, then
   `cmux_cloud_welcome_button_clicked` (`button = upgrade`), then
   `cmux_billing_checkout_completed`.
5. **Week-1 / week-4 retention by activation event.** Retention insight. The
   start event is `cmux_activation_milestone_reached` for each `milestone`
   (one series per milestone); the return event is `cmux_daily_active`. Use
   weekly periods with week 1 and week 4 highlighted, and filter
   `is_new_install = true`.
6. **Retention by feature.** Use `cmux_feature_used` broken down by `feature`
   as the start event and `cmux_daily_active` as the return event.
7. **Cloud reliability.** `cmux_cloud_machine_create_failed` by `error_class`,
   `cmux_cloud_plan_limit_hit` by `limit`, and
   `cmux_cloud_machine_attached` by `latency`.
8. **Churn signals.** Weekly counts of `cmux_cloud_disabled`,
   `cmux_signed_out`, `cmux_plan_deactivated`, and `cmux_app_updated`
   (`direction = downgrade`).

Known gap: someone who checks out signed out gets an anonymous Stack user at
checkout, so that checkout joins the app's events only through `source`
until they sign in to the app with that account.
