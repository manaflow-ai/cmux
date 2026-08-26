# cmux newsletter (Resend segments + broadcasts)

How to keep the two cmux Resend segments in sync and ship a product-update or
Founder's Edition feedback email. All commands run from `web/`.

## The data model

Resend stores one global Contact per email address. On top of that the
tooling manages, all resolved by NAME at runtime (never hardcoded ids):

- **Segment "cmux Users"**: the union of every Stack Auth user with a
  verified primary email AND every Stripe Founder's Edition buyer,
  deduplicated by case-insensitive email. Founders belong here too; a
  founder who bought through the payment link without ever creating a Stack
  account would be silently dropped if this list were Stack-only.
- **Segment "cmux Founder's Edition"**: only the Stripe
  `founders_edition=true` buyers. A strict subset, for founder-only
  announcements.
- **Topic "cmux Updates"** and **Topic "cmux Founder's Edition"**: the
  user-facing unsubscribe lanes. Every broadcast is created with both a
  `segment_id` (who is targeted) and a `topic_id` (which preference governs
  suppression), so opting out of general updates does not silence founder
  announcements and vice versa. Topics are created opt-in-by-default.

Founder purchases are read from the Stripe Checkout Sessions API (sessions
with `metadata.founders_edition === "true"`, status `complete`, payment
settled). Stripe is authoritative: the `stripe_customers` /
`billing_email_claims` tables are Pro/Team billing projections keyed by
Stack user id and miss payment-link buyers who never signed up.

### Unsubscribe safety

Subscription state is a one-way door and this tooling never writes it:

- A contact's global `unsubscribed` flag suppresses every broadcast. The
  sync reads it first and a globally-unsubscribed contact gets NO writes of
  any kind (no create, no segment add, no name backfill).
- Per-topic opt-outs are managed by recipients on Resend's preference page.
  The tooling never writes topic preferences (topics are opt-in-by-default,
  so contacts who never touched preferences still receive mail), which
  means an explicit opt-out can never be undone by a sync.
- The sync only adds; it never removes contacts or segment memberships, and
  it only backfills name fields that are missing.

## Environment

Load env for local runs either way:

```bash
source scripts/load-dev-env.sh          # from ~/.secrets/cmuxterm-dev.env
# or
vercel env pull .env.newsletter --environment production && set -a && source .env.newsletter && set +a
```

Required: `RESEND_API_KEY`, `NEXT_PUBLIC_STACK_PROJECT_ID`,
`STACK_SECRET_SERVER_KEY`, `STRIPE_SECRET_KEY`. Optional:
`CMUX_NEWSLETTER_FROM_EMAIL` (defaults to `Austin Wang <austin@manaflow.ai>`).

**Key permission**: segment/contact/topic/broadcast management needs a
Resend API key with **Full access**. A "Sending access" restricted key
(what some dev env files carry) fails loudly with instructions;
`email:test` is the only command that works with a sending-only key. The
production `RESEND_API_KEY` already has full access.

## Before the first --apply: privacy disclosure

The "cmux Users" source requires an explicit `newsletter_opt_in=true` field
from Stack Auth; a verified account email alone is never enough. Before the
first apply, update the Resend bullet in the privacy policy (every locale) to
cover product-update email for opted-in account holders. The CLI also requires
`--confirm-privacy-disclosure` as a visible acknowledgement before a users/all
apply. If the Stack opt-in field is not populated, the users segment stays
empty and the run is safe to repeat after the consent source is ready.

Related known limitations (identity is by email address, by design of the
current data flow):

- The sync is additive and account deletion does not propagate to Resend.
  A deleted account's contact stays in the segment until pruned by hand
  (the `staleMembers` count in the sync summary is the signal).
- A user who unsubscribes and later changes their verified primary email
  in Stack will be synced under the new address as a fresh subscribed
  contact; the old address's opt-out does not follow them, because Resend
  contacts carry no Stack identity today.

If either becomes a requirement, the follow-up is to stamp the Stack user
id onto Resend contact `properties` at create time and hook the account
deletion / email-change flows into removal and suppression-migration
helpers.

## (a) Sync the segments

```bash
bun run newsletter:sync                      # DRY RUN (default): prints the diff, writes nothing
# required for the users/all audience after the privacy review
bun run newsletter:sync --apply --confirm-privacy-disclosure
bun run newsletter:sync --apply --audience founders # create founder segment/topic
bun run newsletter:sync --audience founders  # limit to one segment (users|founders|all)
bun run newsletter:sync --json               # machine-readable summary only
```

The dry run prints, per segment: contacts to create, existing contacts to
add to the segment, names to backfill, already present, and
skipped-because-unsubscribed, plus per-source counts (including users
skipped for missing/unverified email). Re-running after `--apply` is a
no-op. Only counts are printed, never addresses.

The sync also populates `first_name` / `last_name` on each contact (Stack
display name preferred over the Stripe checkout name when both exist and
are equally complete), which powers greeting personalization.

Ongoing freshness: every paid Founder's Edition purchase is also upserted
into both segments at webhook time by `/api/stripe/founders-welcome`
(best-effort and deadline-bounded; the manual sync is the reconciliation
catch-up). Delayed payment methods are handled on
`checkout.session.async_payment_succeeded`, which requires the Stripe
webhook endpoint to be subscribed to that event type. New Stack signups
only land in the segment when the sync script runs, so run it before
drafting a broadcast.

## (b) Write a product-update email

Templates are React Email components in `web/emails/`. Every template
composes `emails/components/email-layout.tsx`, which owns the branding and
always renders the `{{{RESEND_UNSUBSCRIBE_URL}}}` merge tag plus the
company's physical postal address in the footer (both CAN-SPAM
requirements; templates cannot opt out). Greetings use
`{{{contact.first_name|there}}}` so contacts without a stored name read
naturally.

```bash
bun run email:dev        # preview server; open the printed localhost URL
```

Edit the `emails.newsletter` copy in `web/messages/en.json` and
`web/messages/ja.json`; the React Email components only own layout and
interpolation. The browser preview live-reloads. To add a new template, create
`web/emails/<name>.tsx` composing `MarketingEmailLayout`, then register it
in `web/emails/render.ts` and `TEMPLATE_CHOICES` in
`web/services/newsletter/cli.ts`.

## (c) Preview it in a real inbox

```bash
bun run email:test --template product-update --locale en
```

Sends ONE email to `austin@manaflow.ai` (subject prefixed `[TEST]`). Any
other `--to` is refused unless you also pass
`--dangerously-email-someone-other-than-austin`. Merge tags are not
substituted in one-off sends: the greeting falls back to "there" (override
with `--greeting-name Austin`) and the unsubscribe link stays a literal
token. Use `--locale ja` for the Japanese catalog; other locales intentionally
fall back to the English newsletter catalog until translated copy is added.

## (d) Send it for real

```bash
bun run email:draft --template product-update --audience users --locale en
# Founder's Edition feedback invite
bun run email:draft --template founders-feedback-call --audience founders --locale ja
```

This creates a Resend Broadcast **draft** against the chosen segment,
scoped to its topic, and prints the `https://resend.com/broadcasts/<id>`
URL. Open it, review the rendered email, and click Send in the Resend
dashboard. That dashboard button is the only send path: the repo tooling
never sets the broadcast `send` flag, has no command that sends a
broadcast, and the draft script rejects unknown flags before making any
API call.

If the dashboard ever refuses to send an API-created draft (older Resend
plans restricted API-created broadcasts to API sending), duplicate the
draft in the dashboard editor and send the copy from there. Do not add a
send flag to the tooling; the human-review-then-click design is
deliberate.

Note on removals: the sync is additive by design and never removes
contacts or segment memberships (an upstream source glitch must not be
able to evacuate an audience). The per-segment summary reports
`staleMembers`, the count of members whose email no longer appears in the
sources; prune them by hand in the Resend dashboard when it matters.
