# Home messaging: reaching people by email, message requests, and an always-on cloud Home

Status: design + first slice, 2026-10-19 (a113). Extends `plans/cmux-next/home-messaging.md`
(sections 4.1, 9, 16.4, 16.10 item 9) and does not replace it.

## 0. The report that started this

Lawrence typed `austin@manaflow.ai` in the Home compose sheet and sent "hi". Home showed a raw
`addr_…` string, and Austin saw nothing.

What happened, from the code and the cached Home mirror on Lawrence's Mac:

1. `dm.open {peer: {email}}` in `backend/apps/api/src/home-routes.ts` always takes the address
   path when the peer is typed as an email. It never checks whether the address belongs to a
   cmux user, even though section 4.1 says "a typed address resolves to a related user's profile".
   The reason: `AddressDO.linked_user` exists (`address.link` in home-core) but no route ever
   calls `address.link`, so no address is ever linked to its account.
2. So the DM `conv_dm_0Y05MEWEFMQQB63VDHQB9MXAJS` (created 2026-10-13, 8 messages by 2026-10-19)
   has two participants: Lawrence and `addr_ABREQ2MXXDJ3CH86MMYYKA0FPC` (kind `address`, shown
   as `a***@manaflow.ai`, membership `invited`). Austin's own account (production Stack user,
   personal team `team_7648bed712529f7a64fa`) is not a participant, so nothing reaches his Home,
   his phone or his notifications.
3. The only way in for Austin is the invite email (`HOME_INVITES_SEND=on` in production; it is
   sent to anyone in production, only to the allow list in staging) with a console link that
   runs `invite.accept`. The invite expires 14 days after it was made (about 2026-10-27).
   Whether that email went out is recorded only in the conversation's `invites[].delivery`
   and the AddressDO ledger, which this design could not read from the Mac (the daemon's cloud
   lease belongs to the app connection, by design).
4. The `addr_…` text: the raw participant id reaches the UI where a participant has no display
   name (section 5 below lists the exact paths found).

## 1. Goals

- G1. Never show an internal id or code (`addr_…`, `user_…`, `not_reachable`,
  `owner.unreachable`, delivery states) to a person. Every state has a human, localized string.
- G2. Typing a teammate's (or a contact's) email opens a real DM with them: they see it at once.
- G3. A person you are not connected to gets a **message request**, like iMessage "Unknown
  Senders": it waits in a Requests section, makes no sound, and offers Accept / Decline / Block.
  An email tells them about it (R2), and the same request is visible in Home if they already
  have an account, with no email link needed.
- G4. Spam control: per-sender limits, block, report, and an optional "trust my email domain"
  setting.
- G5. Cloud Home always works: messaging and sync never depend on a Mac being awake.

Non-goals for this slice: SMS requests, org invites (16.5), a global directory.

## 2. Model

### 2.1 Address ownership (fixes G2's root cause)

- On every successful `user.ensure` with a Stack-verified email, the Worker links that email's
  AddressDO to the user (`address.ensure` + `address.link {user}`), best effort, after the
  personal team. An unverified email never links (home-core already refuses ownership without
  `email_verified`).
- A later `user.ensure` with another verified email links the new address; the old link stays
  until the address is claimed by someone else (relinking is a plain overwrite; only a verified
  owner can trigger it).

### 2.2 `dm.open` by address

```
address -> AddressDO.linked_user
  none                       -> invite flow (today): address participant + invite email
  linked, == caller          -> refuse invalid_participant (a DM with yourself)
  linked, reachable          -> the pair's user DM (same as dm.open {peer: user_id})
  linked, not reachable      -> invite flow (same answer as an unknown address, 16.4)
                                + the invite shows as a message request in their Home
```

"Reachable" is the existing rule (shared team or connected, and the target's
`allow_requests_from`). A stranger gets the exact answer an unknown address gets, so the sender
cannot probe whether an account exists.

### 2.3 Message requests (G3)

The pending invite **is** the request; no second store is needed:

- The AddressDO ledger already records `{invite, conversation, inviter}` for every invite to the
  address. A signed-in user whose verified email maps to that address can read them:
  `home.requests.list` (read, session only, verified email required) returns, per open invite,
  the conversation id, the inviter's display name, the first message preview, the time, and a
  `trusted` flag (2.4).
- `invite.accept_verified {conversation}` accepts without the email secret: the ConversationDO
  checks that the caller's verified email maps to the invite's `address` and that the invite is
  pending, then binds the user exactly like `invite.accept` (same `bindUser`, so the address
  participant becomes the user and history since the invite stays visible). This creates the
  connection (16.8: one accepted the other's invite).
- `invite.decline {conversation, block?}`: the invitee closes the invite (status `declined`), the
  address leaves the conversation. `block: true` also records the inviter in the AddressDO
  (`address.block_inviter`): later invites from that user to this address are recorded as
  `suppressed` and never emailed or listed. Decline and block are silent to the sender (the
  sender keeps seeing "Waiting for … to accept" until expiry).
- Report = block + `address.suppress {reason: reported}` is out of scope for the first slice
  (it would suppress all senders); it goes to a trust-and-safety queue later.

Client: a **Requests** row at the top of the Home list when there are requests ("2 message
requests"), opening a list with Accept / Decline / Block. Requests never badge the Dock or post
notifications unless `trusted`.

### 2.4 Trust and spam control (G4)

- `trusted` = the inviter's verified email domain equals the recipient's verified email domain,
  and that domain is not a public mailbox provider (gmail.com, outlook.com, icloud.com, …).
  Setting `home.settings.set {trust_same_domain: true}` (default **on**) lets trusted requests
  notify and sit in the main list (still with Accept / Decline); off sends them to Requests.
- Existing limits stay: `conversation.create` 60/h per sender, AddressDO per-recipient windows
  (section 9). New: at most 20 open requests listed per recipient; older ones expire with their
  invite (14 days).
- Block (2.3) is per sender and per address.

### 2.5 Sender states (G1)

The DM header and the list row show one of (localized, never a code):

| State (from the invite) | Text |
| --- | --- |
| pending, delivery queued/sending | "Sending invite to a***@manaflow.ai…" |
| pending, delivery sent/delivered, or the address is linked | "Waiting for a***@manaflow.ai to accept" |
| delivery refused_env / disabled / suppressed / failed / bounced | "a***@manaflow.ai is not on cmux yet. Share this invite link instead." + Copy link |
| expired | "Invite expired. Send again" |
| accepted | the person's name, no banner |

The masked address stays (the sender typed it; other members of a group see only the mask).

## 3. Cloud Home always works (G5)

What is already true: cloud conversations (`owner: cloud`) live in Cloudflare Durable Objects
(ConversationDO, UserDO inbox, AddressDO). Messages between people never pass through a Mac, so
a sleeping or offline Mac does not stop delivery. The Mac and the iPhone both read the same
inbox.

What was not true, and its state on 2026-10-19:

1. Production served a stub (d638a15758ab) where the Chief brain route answered 404. Fixed:
   production serves 675e043722ea since 09:49Z (hosted-chief-REPORT.md step 2).
2. A production Chief created by `chief.create` starts with its brain disabled, and the four
   allowed owner teams have $0 Cloud credits, so a Chief reply in the cloud can be a credits
   refusal. Decision for Lawrence (money): grant credits or keep refusals.
3. No health check alerts when cloud Home is down.

Plan:

- H1 (built). A Worker cron (`*/5 * * * *`, `backend/apps/api/src/home-health.ts`, wired in
  `index.ts` `scheduled`) sends one message between two probe users (`user_homeprobesender`,
  `user_homeprobepeer`: not Stack-derived ids, no email, no device) through the real owners:
  `dm.open` by id on the pair's ConversationDO, `message.send`, then the message must reach the
  peer's UserDO inbox within 20 s. The DM keeps 30 days of history (the shortest retention), so it
  stays bounded. Each run logs `home.health.ok` / `home.health.failed` (step, latency, code) and
  sends one Sentry Cron check-in (monitor `cloud-home-<environment>`, secret `SENTRY_DSN`; without
  it the run only logs). Sentry opens one issue after 2 failed check-ins in a row
  (`failure_issue_threshold: 2`), also when check-ins stop (Worker or cron down, which an
  in-Worker counter cannot report), and resolves it on the next good one (`recovery_threshold: 1`).
  The cron runs on development, staging and production (Lawrence approved the production deploy 2026-10-19).
- H2. Client: the Home list shows "Offline. Messages send when you're back" instead of an error
  when the Worker is unreachable; sends stay in the intent log (already true) and retry with
  backoff (already true for ops; add jitter and a cap of 5 min).
- H3. The app's daemon keeps the inbox subscription alive across sleep: on wake it resubscribes
  and reads `inbox.list` since its last revision (exists as `cloud-inbox-reset`; verify on wake).

## 4. Rollout

1. Backend slice behind no flag (it only adds paths that were refused or silent before). Deploy
   staging first; production needs Lawrence's approval (prod deploy).
2. The client slice ships in the next nightly.
3. Backfill: none needed. Austin's existing invite becomes visible to him in Requests as soon as
   his app calls `user.ensure` after the backend deploy (his address gets linked; the ledger
   already has the invite).

## 5. Where raw ids reached the UI

See the slice report in `REPORT.md` next to this file for the exact paths and fixes.
