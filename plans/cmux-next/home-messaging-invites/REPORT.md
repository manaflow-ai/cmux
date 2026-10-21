# Home messaging invites: first slice report (2026-10-19, a113)

Design: `DESIGN.md` next to this file.

## What `ADD_R…` was

The raw address participant id `addr_ABREQ2MXXDJ3CH86MMYYKA0FPC` (an HMAC of
`austin@manaflow.ai`). It reached the Home row title through two paths:

1. `cmux-tui/crates/cmux-conversation/src/home.rs` `cloud_row`: an untitled cloud DM was named by
   its `dm_peer`, which is the address id when the peer is an invited email.
2. `Packages/macOS/CmuxNext/Sources/CmuxNextHomeEngine/HomeInboxMapping.swift`: the daemon row
   name overwrote the store title without a check.

The web page (`webviews/src/pages/home-channels/cloudHome.ts`) had the same fallback.

## Why Austin did not see the message

`dm.open {peer: {email}}` never resolved an email to an account: `address.link` existed in
home-core but no route called it. So Austin is an `address` participant with a pending invite
(14 days, expires about 2026-10-27), not a member. His only way in was the invite email link.
The delivery state of that email could not be read from the Mac (the daemon's cloud lease belongs
to the app connection).

## What shipped (backend + display)

- `user.ensure` with a Stack-verified email links that email's AddressDO to the user
  (`linkVerifiedAddress`, best effort).
- `dm.open` by email: linked to the caller = `invalid_participant`; linked and reachable = the
  real user DM; otherwise the invite (same answer as an unknown address).
- Message requests: `home.requests.list` (inviter name, kind, title, preview, times, `trusted`,
  never an id), `invite.accept_verified {conversation}` (accept without the link, only for the
  verified owner of the invited address), `request.dismiss {conversation, block?}` (silent to the
  sender; block suppresses that sender's later invites to the address). At most 20 listed, 14-day TTL.
- `trusted`: same verified email domain, never a public mailbox domain.
- No internal id as a name: `String.isHomeInternalID`, `Participant.visibleName`,
  `ConversationSummary.displayTitle`, `HomeInboxMapping`, daemon `cloud_row`, web `fromEntry`.
- `inviteRefusal` shows "That didn’t work. Try again." (existing localized key) for an unknown
  code instead of the code.

## Tests

- `backend/apps/api/test/home-requests.test.ts` (5, workerd): teammate email opens the real DM;
  own email refused; stranger request listed for the owner only, accepted without the link, no
  `addr_`; dismiss + block; same-domain trust.
- `Packages/Shared/CmuxHomeCore/Tests/CmuxHomeCoreTests/HomeInternalIDTests.swift` (Swift Testing).
- Shared corpus `cmux-tui/crates/cmux-tui/tests/fixtures/home-inbox-cloud-cases.json`: the
  untitled-DM case now expects no name, and a new case for an invited email address.
- Red run on the test commit: the 5 request tests failed. Green gate (Freestyle): typecheck,
  lint:size, catalog/client/rust codegen checks, home-core 361, protocol 9, api 51/51, webviews corpus.

## Not built (next slices)

- Mac Requests section UI (needs a daemon read command for `home.requests.list` and the daemon
  allow list `CLOUD_OP_KINDS` entries for `invite.accept_verified` and `request.dismiss`).
- Sender state strings (DESIGN 2.5) in all locales.
- `trust_same_domain` setting (the flag is computed; nothing reads it yet).
- Report (trust-and-safety queue).
- Cloud Home health check cron and alert (DESIGN 3, H1–H3).
- Production deploy (needs approval).
