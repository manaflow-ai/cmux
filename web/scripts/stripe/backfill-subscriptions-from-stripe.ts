import { backfillPaidPurchasesByEmail } from "../../services/billing/backfillPaidPurchases";
import { backfillSubscriptionsFromStripe } from "../../services/billing/backfillFromStripe";

// Rebuild stripe_customers, stripe_subscriptions, and Stack plan metadata
// from Stripe. Dry-run by default; `--apply` writes.
//
//   bun scripts/stripe/backfill-subscriptions-from-stripe.ts                       # metadata-tagged subscriptions, report
//   bun scripts/stripe/backfill-subscriptions-from-stripe.ts --apply               # write them
//   bun scripts/stripe/backfill-subscriptions-from-stripe.ts --by-email            # Founder and legacy Pro by customer email, report
//   bun scripts/stripe/backfill-subscriptions-from-stripe.ts --by-email --apply    # write them (existing Stack accounts only)
//   ... --by-email --apply --create-missing-users                                  # also create shell accounts, as checkout does
//
// Needs STRIPE_SECRET_KEY, the Stack server keys, and DATABASE_URL (or the
// aws-rds-iam variables) for the target database.
const args = process.argv.slice(2);
const known = new Set(["--apply", "--by-email", "--create-missing-users"]);
const unknown = args.filter((argument) => !known.has(argument));
if (unknown.length > 0) {
  throw new Error(`Unknown argument: ${unknown[0]}`);
}
const apply = args.includes("--apply");
const mode = apply ? "apply" : "dry-run";
const log = (line: string) => console.log(line);

const result = args.includes("--by-email")
  ? await backfillPaidPurchasesByEmail({
    mode,
    createMissingUsers: args.includes("--create-missing-users"),
    log,
  })
  : await backfillSubscriptionsFromStripe({ apply_mode: mode, log });
console.log(JSON.stringify({ mode, ...result }, null, 2));
if (result.failed > 0) process.exit(1);
