# cmux newsletter (Resend audiences + broadcasts)

How to keep the two cmux Resend audiences in sync and ship a product-update
email. All commands run from `web/`.

## The two audiences

Both are resolved by NAME at runtime (never by hardcoded id) and overlap on
purpose:

- **cmux Users**: the union of every Stack Auth user with a verified primary
  email AND every Stripe Founder's Edition buyer, deduplicated by
  case-insensitive email. Founders belong here too; a founder who bought
  through the payment link without ever creating a Stack account would be
  silently dropped if this list were Stack-only.
- **cmux Founder's Edition**: only the Stripe `founders_edition=true` buyers.
  A strict subset, for founder-only announcements.

Founder purchases are read from the Stripe Checkout Sessions API (sessions
with `metadata.founders_edition === "true"`, status `complete`). Stripe is
authoritative: the `stripe_customers` / `billing_email_claims` tables are
Pro/Team billing projections keyed by Stack user id and miss payment-link
buyers who never signed up.

Unsubscribe state lives per-audience in Resend and is a one-way door: the
sync reads existing contact state before writing, never flips
`unsubscribed`, and never removes contacts. Someone who unsubscribed from
the general newsletter stays subscribed to founder announcements unless they
unsubscribed there too.

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

**Key permission**: audience/contact/broadcast management needs a Resend API
key with **Full access**. A "Sending access" restricted key (what some dev
env files carry) fails loudly with instructions; `email:test` is the only
command that works with a sending-only key. The production `RESEND_API_KEY`
already has full access.

## (a) Sync the audiences

```bash
bun run newsletter:sync                      # DRY RUN (default): prints the diff, writes nothing
bun run newsletter:sync --apply              # actually create audiences / add contacts
bun run newsletter:sync --audience founders  # limit to one audience (users|founders|all)
bun run newsletter:sync --json               # machine-readable summary only
```

The dry run prints, per audience: contacts to add, names to backfill,
already present, and skipped-because-unsubscribed, plus per-source counts
(including users skipped for missing/unverified email). Re-running after
`--apply` is a no-op. Only counts are printed, never addresses.

The sync also populates `first_name` / `last_name` on each contact (Stack
display name preferred over the Stripe checkout name when both exist and are
equally complete), which powers greeting personalization.

Ongoing freshness: every Founder's Edition purchase is also upserted into
both audiences at webhook time by `/api/stripe/founders-welcome`
(best-effort; the manual sync is the reconciliation catch-up). New Stack
signups only land in the audience when the sync script runs, so run it
before drafting a broadcast.

## (b) Write a product-update email

Templates are React Email components in `web/emails/`. Every template
composes `emails/components/email-layout.tsx`, which owns the branding and
always renders the `{{{RESEND_UNSUBSCRIBE_URL}}}` merge tag in the footer
(CAN-SPAM; templates cannot opt out). Greetings use
`{{{FIRST_NAME|there}}}` so contacts without a stored name read naturally.

```bash
bun run email:dev        # preview server; open the printed localhost URL
```

Edit `web/emails/product-update.tsx` (content lives in its `PreviewProps`)
and the browser preview live-reloads. To add a new template, create
`web/emails/<name>.tsx` composing `MarketingEmailLayout`, then register it
in `web/emails/render.ts` and `TEMPLATE_CHOICES` in
`web/services/newsletter/cli.ts`.

## (c) Preview it in a real inbox

```bash
bun run email:test --template product-update
```

Sends ONE email to `austin@manaflow.ai` (subject prefixed `[TEST]`). Any
other `--to` is refused unless you also pass
`--dangerously-email-someone-other-than-austin`. Merge tags are not
substituted in one-off sends: the greeting falls back to "there" (override
with `--greeting-name Austin`) and the unsubscribe link stays a literal
token.

## (d) Send it for real

```bash
bun run email:draft --template product-update --audience users
```

This creates a Resend Broadcast **draft** against the chosen audience and
prints its `https://resend.com/broadcasts/<id>` URL. Open it, review the
rendered email, and click Send in the Resend dashboard. That dashboard
button is the only send path: the repo tooling has no command that sends a
broadcast, and the draft script rejects unknown flags before making any API
call.
