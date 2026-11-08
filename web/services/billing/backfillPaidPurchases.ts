import type Stripe from "stripe";
import { canonicalizeEmailForMatching } from "./emailMatching";
import {
  findPaidBillingPurchaseByEmail,
  provisionPaidBillingPurchase,
  type PaidBillingPurchase,
} from "./recovery";
import { stripe } from "./stripe";

/**
 * Rebuild paid ownership rows for purchases that carry no `stackUserId`
 * metadata, which is every Founder's Edition payment-link purchase and the
 * oldest Pro subscriptions. The webhook path cannot map those, so this walks
 * the customer emails behind every Stripe subscription and routes each one
 * through the same recovery recorder that `/api/billing/recover` uses. That
 * recorder finds the Stack account for the email, writes the customer and
 * subscription rows, and syncs the plan metadata on the Stack user.
 *
 * By default a purchase whose email has no Stack account is reported and
 * skipped, because the recorder would create a shell account for it. Pass
 * `createMissingUsers` to allow that, which is what the checkout webhook does
 * at purchase time.
 */
export type PaidPurchaseBackfillResult = {
  readonly customers: number;
  readonly found: number;
  readonly provisioned: number;
  readonly skipped: number;
  readonly noStackUser: number;
  readonly failed: number;
  readonly failures: readonly { readonly email: string; readonly message: string }[];
};

export type PaidPurchaseBackfillDependencies = {
  /** Distinct customer emails behind Stripe subscriptions, any status. */
  readonly emails?: () => AsyncIterable<string>;
  readonly find?: (email: string) => Promise<PaidBillingPurchase | null>;
  readonly hasStackUser?: (email: string) => Promise<boolean>;
  readonly provision?: (purchase: PaidBillingPurchase) => Promise<unknown>;
  readonly mode?: "dry-run" | "apply";
  readonly createMissingUsers?: boolean;
  readonly log?: (line: string) => void;
};

export async function backfillPaidPurchasesByEmail(
  dependencies: PaidPurchaseBackfillDependencies = {},
): Promise<PaidPurchaseBackfillResult> {
  const emails = dependencies.emails ?? defaultEmails;
  const find = dependencies.find ?? ((email) => findPaidBillingPurchaseByEmail(email));
  const hasStackUser = dependencies.hasStackUser ?? defaultHasStackUser;
  const provision = dependencies.provision ?? ((purchase) => provisionPaidBillingPurchase(purchase));
  const mode = dependencies.mode ?? "dry-run";
  const log = dependencies.log ?? (() => undefined);

  let customers = 0;
  let found = 0;
  let provisioned = 0;
  let skipped = 0;
  let noStackUser = 0;
  const failures: { email: string; message: string }[] = [];
  const seen = new Set<string>();

  for await (const rawEmail of emails()) {
    const email = rawEmail.trim().toLowerCase();
    const canonical = canonicalizeEmailForMatching(email);
    if (!canonical || seen.has(canonical)) continue;
    seen.add(canonical);
    customers += 1;
    try {
      const purchase = await find(email);
      if (!purchase) continue;
      found += 1;
      const label = `${purchase.kind} ${redact(email)}`;
      if (!dependencies.createMissingUsers && !(await hasStackUser(email))) {
        noStackUser += 1;
        log(`no stack user ${label}`);
        continue;
      }
      if (mode === "dry-run") {
        log(`would provision ${label}`);
        continue;
      }
      const result = await provision(purchase);
      if (result && typeof result === "object" && "skipped" in result) {
        skipped += 1;
        log(`skipped ${label}: ${String((result as { skipped: unknown }).skipped)}`);
      } else {
        provisioned += 1;
        log(`provisioned ${label}`);
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      failures.push({ email: redact(email), message });
      log(`failed ${redact(email)}: ${message}`);
    }
  }

  return {
    customers,
    found,
    provisioned,
    skipped,
    noStackUser,
    failed: failures.length,
    failures,
  };
}

/** Keep operator logs free of full addresses. */
function redact(email: string): string {
  const [local, domain] = email.split("@");
  if (!domain) return "<invalid>";
  return `${local.slice(0, 2)}***@${domain}`;
}

async function* defaultEmails(): AsyncIterable<string> {
  const client = stripe();
  for await (const subscription of client.subscriptions.list({
    status: "all",
    limit: 100,
    expand: ["data.customer"],
  })) {
    const customer = subscription.customer;
    if (typeof customer === "string" || customer.deleted) continue;
    if (customer.email) yield customer.email;
  }
}

async function defaultHasStackUser(email: string): Promise<boolean> {
  const { getStackServerApp } = await import("../../app/lib/stack");
  const canonical = canonicalizeEmailForMatching(email);
  const literal = email.trim().toLowerCase();
  const queries = literal === canonical ? [canonical] : [canonical, literal];
  for (const query of queries) {
    const users = await getStackServerApp().listUsers({
      query,
      limit: 50,
      includeAnonymous: false,
    });
    if (
      users.some((user) =>
        user.primaryEmail && canonicalizeEmailForMatching(user.primaryEmail) === canonical
      )
    ) return true;
  }
  return false;
}
