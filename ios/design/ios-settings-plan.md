# iOS Settings > Account > Plan

The account rows in Settings and the Plan page they lead to (App Store subscriptions). Written
from the code as of this file's commit; a change to the screen updates this file. Rule and
detector: [docs/ios-theme-tokens.md](../../docs/ios-theme-tokens.md).

Code: `MobileSettingsView` (Packages/iOS/CmuxMobileShellUI), a sheet from the workspace list's
Settings button, a `Form` titled "Settings" with Done. Account: `MobileSettingsAccountSection`.
Plan: `MobileSettingsPlanSection` (Packages/iOS/CmuxMobileBilling, CmuxMobileBillingUI), shown
when signed in and a `BillingModel` is present, pushes `MobilePlansView`. The Cloud tab's Upgrade
opens the same view in `MobilePlansSheet`.

App Store reviewer: buys and restores from Settings > Account > Plan (or Cloud > Upgrade); the demo
account has no web subscription, so purchase buttons show. Account deletion is in this section.

## Account section

| State | Shows |
| --- | --- |
| Signed in | name (or "Account") and selectable email; Sign Out; Delete Account; footer about matching the Mac's account |
| Signed out | Sign In to cmux; footer: SSH computers work without an account |
| Deleting | "Deleting Account..." with an hourglass, disabled |
| Delete failed | "Couldn't Delete Account" alert by kind (connection, unauthorized, timed out, …); "Account Deleted" when only server cleanup is left. Unauthorized and cleanup-incomplete sign out after the alert |

Sign Out runs `MobileSignOutHook` and clears billing state.

## Plan row and page

The Plan row shows the plan name (Free, Go, Pro, Max), blank until the account loads.

| State | Shows |
| --- | --- |
| Loading | spinner, "Loading plans" |
| Load failed | the failure message and Try Again |
| Ineligible | one line, no buy button: web subscriber, team-managed, purchases unavailable in this version, or other |
| No offers yet | spinner, or the failure and Try Again |
| Offers | Monthly / Yearly picker (only if a plan has both; Yearly first), one section per plan: name, StoreKit price, "… / month, billed yearly", features, and Current Plan (disabled), Switch to This Plan, or Subscribe |
| Purchasing / restoring | a result section with a spinner ("Completing your purchase", "Restoring purchases"); buy and restore disabled |
| Result | pending approval, "You're on … now", awaiting the server ("You don't need to buy again"), restored or nothing found, or a failure message |
| Offline | no separate view; the network failure message |

Always: Current plan row with "Billed through the App Store" or "Billed on the web", Restore
Purchases, Manage Subscription and Request a Refund for App Store plans, Terms and Privacy, and the
auto-renewal disclosure. Leaving the page clears the result.

## Selected and foreground

Nothing is focused. The current plan reads in the Current plan row and as its disabled Current Plan
button; the same plan's other period stays buyable as a switch.

## Zones

- Stable: account rows, the Plan label, Restore, legal links, disclosure.
- Dynamic: plan name, email, prices and button titles, the result section (only when there is
  something to say), loading, error and ineligible sections.

## Device variants

- iPhone, iPad, foldable folded or unfolded, rotation: system `Form` and inset-grouped `List`, no
  size-class, width or max-width logic; on iPad the rows span the sheet.
- Dynamic Type: text styles throughout.
- Dark mode: system appearance; no override.

## Tokens

- Account: `LabeledContent`, SF Symbol labels, `.secondary` email, `role: .destructive`.
- Plans: `.insetGrouped`, `.headline` names and prices (`monospacedDigit`), `.subheadline`
  `.secondary` details, `.borderedProminent` buy button, `Color.clear` picker row.
- No literal colors or font sizes in the account or billing UI files today. Row padding (4) and
  stack spacing (8) are literals; Settings has no metric tokens.
