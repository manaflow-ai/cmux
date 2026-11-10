# cmux iOS App Review Access Setup

How App Review reaches the official cmux iOS app, Apple ID `6783338052`, and how
the App Store Connect Review Information is kept. Do not commit passwords,
one-time codes, or live pairing secrets.

## Review path

The reviewer needs no Mac, VPN or network setup. They sign in with the demo
account by email code, and Home lists that account's conversations through the
cmux cloud (the default Chat Server). One of them is a Chief running on a review
Mac we keep online; the reviewer opens it, sends a message and reads the reply.

No demonstration mode is wired in this app, so the Chief the notes name answers
only while the review Mac runs it. Keep the review Mac up for the whole review.

## Required review Mac

Before submission, keep a review Mac online and signed in to the demo account
entered in App Store Connect. It must:

- Run the production cmux macOS app that matches the submitted iOS backend.
- Stay awake, unlocked after reboot, and online for the whole review.
- Run one Chief whose name is the repository variable
  `IOS_APPSTORE_REVIEW_CHIEF_NAME` (the notes name it), answering harmless
  messages such as "Reply with app-review-ok".
- Use a dedicated review-only macOS user on a dedicated review Mac or VM, with
  fictional account, workspace, file and device names. Do not sign in with
  personal Apple IDs, GitHub accounts, production developer credentials,
  password managers, SSH keys, cloud drives, Messages, or other private
  services.
- Reach the reviewer only through the cmux cloud. The Self-Hosted chat server
  needs the reviewer to join a tailnet, so the notes never ask for it.

After review, sign the review Mac out of the demo account, reset the review
macOS user, and delete any files created during review.

## App Store Connect Review Information

The notes are **not pasted by hand**. `ios/AppStoreReview/review-notes-asc.txt`
is the single source; every `ios-app-store.yml` run renders it and writes it to
the version's App Review notes (`ios/scripts/asc_review_package.py sync-notes`).
Its placeholders are filled at run time, so the live values never enter git:

| Placeholder | Source |
| --- | --- |
| `{{DEMO_ACCOUNT_EMAIL}}` | App Store Connect demo account name |
| `{{MAILINATOR_PUBLIC_INBOX_URL}}` | derived from a `@mailinator.com` demo account, else the inbox URL already in the notes |
| `{{REVIEW_CONTACT_EMAIL}}`, `{{REVIEW_CONTACT_PHONE}}` | App Store Connect App Review contact |
| `{{REVIEW_CHIEF_NAME}}` | repository variable `IOS_APPSTORE_REVIEW_CHIEF_NAME` (App Store Connect has no field for it) |

The run fails before writing anything, naming each empty placeholder and where
to fill it. Keep in App Store Connect only: the demo account email (no password:
the app emails a one-time code to the public inbox) and a monitored contact
name, email and phone.

The same step sets the Support URL of every locale of the version to the one in
`metadata/version/<version>/en-US.json` (`https://cmux.com/support`), reads them
back, and fails on any locale that still differs (`sync-listing`).

## Pre-Submission Check

1. Sign in to the iOS App Store build with the review account by email code,
   reading the code from the public inbox the notes name.
2. Confirm Home lists the Chief named by `IOS_APPSTORE_REVIEW_CHIEF_NAME`, send
   it "Reply with app-review-ok", and confirm the reply arrives.
3. Confirm the Privacy Policy URL in App Store Connect is
   `https://cmux.com/privacy-policy`.
