# cmux iOS App Review Access Setup

How App Review reaches the official cmux iOS app, Apple ID `6783338052`, and how
the App Store Connect Review Information is kept. Do not commit passwords,
one-time codes, or live pairing secrets.

## Review path

The reviewer needs no Mac, VPN or network setup. The review account is
server-flagged for demonstration mode (below), so after sign-in onboarding
reports "Your Mac is connected", **Open Workspaces** goes to Computers, and a
local "Demo Mac" offers sample workspaces, interactive canned terminals and
notifications through the same views as a live Mac. The connection-method
picker is hidden for this account (#39981), so the notes describe no manual
pairing fallback.

## App Store Connect Review Information

The notes are **not pasted by hand**. `ios/AppStoreReview/review-notes-asc.txt`
is the single source; every `ios-app-store.yml` run renders it and writes it to
the version's App Review notes (`ios/scripts/asc_review_package.py sync-notes`).
Its placeholders are filled from fields App Store Connect already holds, so the
live values never enter git:

| Placeholder | Source in App Store Connect |
| --- | --- |
| `{{DEMO_ACCOUNT_EMAIL}}` | demo account name |
| `{{MAILINATOR_PUBLIC_INBOX_URL}}` | the inbox URL already in the notes, else derived from a `@mailinator.com` demo account |
| `{{REVIEW_CONTACT_EMAIL}}`, `{{REVIEW_CONTACT_PHONE}}` | App Review contact |

The run fails, naming the field, if one of them is empty. Keep in App Store
Connect only: the demo account email (no password: the app emails a one-time
code to the public inbox) and a monitored contact name, email and phone.

The same step sets the Support URL of every locale of the version to the one in
`metadata/version/<version>/en-US.json` (`https://cmux.com/support`), reads them
back, and fails on any locale that still differs (`sync-support-url`).

## Subscriptions in the submission

`ios/AppStoreReview/subscriptions.json` names the subscriptions that go to App
Review with this version (Pro and Max, which the review account sees on
Settings > Account > Plan) and the ones that do not (Go, release-gated; the Pro
trial, not offered by this app). The readiness gate accepts `READY_TO_SUBMIT`
for the submitted ones, and after a submission `verify-submission` checks that
exactly those entered review, cancelling the submission otherwise. The first
subscriptions of an app ride on the version's submission and the public API
cannot select them, so if that check fails it prints the one-time fix: the
version page > In-App Purchases and Subscriptions > select exactly the manifest's
products > Save.

## Demonstration Mode (server-flagged demo account)

Apple's Guideline 2.1(a) rejections invited "a demonstration mode that
exhibits the app's full features and functionality." The app ships one:
when the signed-in account's Stack `clientReadOnlyMetadata` carries
`cmuxReviewDemoContent: true`, a local "Demo Mac" appears in Computers with
sample developer workspaces (agent task rows with statuses), sample
notifications, and interactive canned terminals that echo typed input and
answer common commands. It renders through exactly the same views and stores
as a live Mac. Real computers on the account still
appear and connect alongside it. No live infrastructure (device registry,
relay, presence) is needed for the demonstration content itself; only Stack
sign-in is required.

Flag the review account before submission (from `web/`, with production Stack
server credentials in the environment):

```bash
bun scripts/set-review-demo-content.ts <demo-account-email> on
```

Turn it off after review with `off`. The flag is read at sign-in; an
already-signed-in device picks it up on its next launch or sign-in. Only the
exact flagged account sees demonstration content, and the flag key is
server-writable only (`client_read_only_metadata`), so no client can enable
it for itself.

The review account has no registered Mac, so the Demo Mac is the review path.


## Pre-Submission Check

`ios-app-store.yml` runs these on every dispatch; a person checks only what the
API cannot:

1. The review account is flagged (`bun scripts/set-review-demo-content.ts <email> on`
   from `web/`) and a fresh install signed in as it reaches the Demo Mac through
   onboarding, then Settings > Account > Plan shows Pro and Max with prices.
2. An email code requested for the demo account arrives in the public inbox.
3. The Privacy Policy URL in App Store Connect is `https://cmux.com/privacy-policy`
   and App Privacy is published (the API cannot read its publish state).
