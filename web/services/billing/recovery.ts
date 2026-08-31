import type Stripe from "stripe";
import { eq } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import {
  billingEmailClaims,
  stripeCustomers,
  stripeSubscriptions,
} from "../../db/schema";
import {
  canonicalizeEmailForMatching,
} from "./emailMatching";
import {
  recordFoundersCheckoutCompletion,
  recordProCheckoutCompletionByEmail,
  type BillingPurchaseDependencies,
  type CheckoutCompletionInput,
} from "./purchase";
import { PRO_PLAN_ID } from "./pro";
import { stripe } from "./stripe";

export type PaidBillingPurchaseKind = "founders_edition" | "pro";

export type PaidBillingPurchase = {
  readonly kind: PaidBillingPurchaseKind;
  readonly input: CheckoutCompletionInput;
};

type RecoveryDb = ReturnType<typeof cloudDb>;
type RecoveryStripeClient = {
  readonly customers: {
    list?(options?: Record<string, unknown>): Promise<{ data: readonly Stripe.Customer[] }>;
    search?(options?: Record<string, unknown>): Promise<{ data: readonly Stripe.Customer[] }>;
  };
  readonly subscriptions: {
    list(options?: Record<string, unknown>): Promise<{
      data: readonly Stripe.Subscription[];
    }>;
  };
  readonly checkout: {
    sessions: {
      list(options?: Record<string, unknown>): Promise<{
        data: readonly Stripe.Checkout.Session[];
      }>;
    };
  };
};

export type RecoveryDependencies = {
  readonly db?: RecoveryDb;
  readonly stripeClient?: () => RecoveryStripeClient;
};

export type RecoveryProvisionDependencies = BillingPurchaseDependencies & {
  readonly recordFounders?: typeof recordFoundersCheckoutCompletion;
  readonly recordPro?: typeof recordProCheckoutCompletionByEmail;
};

export type PaidBillingProvisionResult =
  | Awaited<ReturnType<typeof recordFoundersCheckoutCompletion>>
  | Awaited<ReturnType<typeof recordProCheckoutCompletionByEmail>>;

/**
 * Locate a paid cmux checkout by canonical email.
 *
 * Local ownership rows are checked first because they are the durable record
 * written by the webhook. A bounded Stripe read repairs the case where the
 * webhook never created those rows (including Gmail dotted aliases).
 */
export async function findPaidBillingPurchaseByEmail(
  email: string,
  dependencies: RecoveryDependencies = {},
): Promise<PaidBillingPurchase | null> {
  const matchingEmail = canonicalizeEmailForMatching(email);
  try {
    const local = await findLocalPurchase(
      matchingEmail,
      dependencies.db ?? cloudDb(),
    );
    if (local) return local;
  } catch {
    // Continue to Stripe when the local database is unavailable.
  }

  try {
    const client = dependencies.stripeClient
      ? dependencies.stripeClient()
      : (stripe() as unknown as RecoveryStripeClient);
    let searched: { data: readonly Stripe.Customer[] } | null = null;
    if (client.customers.search && isEmailSearchSafe(email)) {
      try {
        searched = await client.customers.search({
          query: `email:'${escapeStripeSearchValue(email)}'`,
          limit: 100,
        });
      } catch {
        // The bounded list below is an equivalent, slower fallback when the
        // provider's search index or query parser is unavailable.
      }
    }
    const listed = client.customers.list
      ? await client.customers.list({ limit: 100 })
      : { data: [] as readonly Stripe.Customer[] };
    const customers = dedupeCustomers([
      ...(searched?.data ?? []),
      ...listed.data,
    ]);
    for (const customer of customers) {
      if (
        !customer.email ||
        canonicalizeEmailForMatching(customer.email) !== matchingEmail
      ) {
        continue;
      }
      const purchase = await purchaseFromStripeCustomer(client, customer);
      if (purchase) return purchase;
    }
    // Payment-link checkouts can omit a persisted Stripe customer. Inspect a
    // bounded recent session page as a final fallback so a paid Founder's
    // session remains recoverable by email.
    const sessions = await client.checkout.sessions.list({ limit: 100 });
    const session = sessions.data.find((candidate) => {
      const sessionEmail = candidate.customer_details?.email;
      if (
        !sessionEmail ||
        canonicalizeEmailForMatching(sessionEmail) !== matchingEmail ||
        !["paid", "no_payment_required"].includes(candidate.payment_status)
      ) {
        return false;
      }
      if (candidate.metadata?.stackTeamId) return false;
      return (
        candidate.metadata?.founders_edition === "true" ||
        (candidate.metadata?.app === "cmux" && candidate.metadata?.plan === "pro")
      );
    });
    if (session) {
      const isFounder = session.metadata?.founders_edition === "true";
      const customerId = stringID(session.customer) ?? `recovery_${session.id}`;
      const customer = {
        id: customerId,
        deleted: false,
        email: session.customer_details?.email ?? null,
      } as unknown as Stripe.Customer;
      const subscription =
        typeof session.subscription === "object" && session.subscription
          ? session.subscription
          : null;
      return {
        kind: isFounder ? "founders_edition" : "pro",
        input: { session, subscription, customer },
      };
    }
  } catch (error) {
    if (
      error instanceof Error &&
      error.message === "Stripe billing is not configured"
    ) {
      return null;
    }
    // Let the route record one identifier-free provider failure while keeping
    // the public response indistinguishable from every other outcome.
    throw new Error("Billing purchase lookup is unavailable");
  }
  return null;
}

function dedupeCustomers(
  customers: readonly Stripe.Customer[],
): readonly Stripe.Customer[] {
  const seen = new Set<string>();
  return customers.filter((customer) => {
    if (seen.has(customer.id)) return false;
    seen.add(customer.id);
    return true;
  });
}

/** Run the shared checkout recorder for a located purchase. */
export async function provisionPaidBillingPurchase(
  purchase: PaidBillingPurchase,
  dependencies: RecoveryProvisionDependencies = {},
): Promise<PaidBillingProvisionResult> {
  if (purchase.kind === "founders_edition") {
    return await (dependencies.recordFounders ?? recordFoundersCheckoutCompletion)(
      purchase.input,
      dependencies,
    );
  }
  return await (dependencies.recordPro ?? recordProCheckoutCompletionByEmail)(
    purchase.input,
    dependencies,
  );
}

async function findLocalPurchase(
  matchingEmail: string,
  db: RecoveryDb,
): Promise<PaidBillingPurchase | null> {
  try {
    const rows = await db
      .select({
        customerId: stripeCustomers.id,
        email: stripeCustomers.email,
        stackUserId: stripeCustomers.stackUserId,
        stackTeamId: stripeCustomers.stackTeamId,
      })
      .from(stripeCustomers)
      .limit(500);
    for (const row of rows) {
      if (
        !row.email ||
        row.stackTeamId != null ||
        canonicalizeEmailForMatching(row.email) !== matchingEmail
      ) {
        continue;
      }
      const subscriptionRows = await db
        .select()
        .from(stripeSubscriptions)
        .where(eq(stripeSubscriptions.customerId, row.customerId))
        .limit(100);
      const candidate = subscriptionRows.find((subscription) => {
        if (
          subscription.customerId !== row.customerId ||
          subscription.plan !== PRO_PLAN_ID ||
          (subscription.scope && subscription.scope !== "user") ||
          subscription.stackTeamId != null
        ) {
          return false;
        }
        const raw = isRecord(subscription.raw) ? subscription.raw : {};
        const isFounder =
          isRecord(raw.metadata) && raw.metadata.founders_edition === "true";
        const app = isRecord(raw.metadata) ? raw.metadata.app : undefined;
        if (app && app !== "cmux" && !isFounder) return false;
        return isFounder || ["active", "trialing", "past_due"].includes(subscription.status);
      });
      if (!candidate) continue;
      const raw = isRecord(candidate.raw) ? candidate.raw : {};
      const kind: PaidBillingPurchaseKind =
        raw.metadata &&
        isRecord(raw.metadata) &&
        raw.metadata.founders_edition === "true"
          ? "founders_edition"
          : "pro";
      const subscription = {
        ...raw,
        id: candidate.id,
        customer: candidate.customerId,
        status: candidate.status,
        metadata: isRecord(raw.metadata) ? raw.metadata : {},
        cancel_at_period_end: candidate.cancelAtPeriodEnd,
        items: raw.items ?? { data: [] },
      } as unknown as Stripe.Subscription;
      const customer = {
        id: row.customerId,
        deleted: false,
        email: row.email,
      } as unknown as Stripe.Customer;
      const session = {
        id: `recovery_${candidate.id}`,
        client_reference_id: row.stackUserId,
        customer: row.customerId,
        customer_details: { email: row.email },
        metadata: isRecord(raw.metadata) ? raw.metadata : {},
        subscription,
        payment_status: "paid",
      } as unknown as Stripe.Checkout.Session;
      return { kind, input: { session, subscription, customer } };
    }

    // Older claim rows may exist without a customer email row. Resolve them
    // by canonical email and the durable Stripe customer id.
    const claims = await db
      .select()
      .from(billingEmailClaims)
      .limit(500);
    const claim = claims.find(
      (candidate) =>
        canonicalizeEmailForMatching(candidate.email) === matchingEmail,
    );
    if (claim) {
      const subscriptionRows = await db
        .select()
        .from(stripeSubscriptions)
        .where(eq(stripeSubscriptions.customerId, claim.stripeCustomerId))
        .limit(100);
      const candidate = subscriptionRows.find(
        (subscription) =>
          subscription.plan === PRO_PLAN_ID &&
          (!subscription.scope || subscription.scope === "user") &&
          subscription.stackTeamId == null &&
          (["active", "trialing", "past_due"].includes(subscription.status) ||
            (isRecord(subscription.raw) &&
              isRecord(subscription.raw.metadata) &&
              subscription.raw.metadata.founders_edition === "true")),
      );
      if (candidate) {
        const raw = isRecord(candidate.raw) ? candidate.raw : {};
        const subscription = {
          ...raw,
          id: candidate.id,
          customer: candidate.customerId,
          status: candidate.status,
          metadata: isRecord(raw.metadata) ? raw.metadata : {},
          cancel_at_period_end: candidate.cancelAtPeriodEnd,
          items: raw.items ?? { data: [] },
        } as unknown as Stripe.Subscription;
        const customer = {
          id: claim.stripeCustomerId,
          deleted: false,
          email: claim.email,
        } as unknown as Stripe.Customer;
        const session = {
          id: `recovery_${candidate.id}`,
          client_reference_id: claim.stackUserId,
          customer: claim.stripeCustomerId,
          customer_details: { email: claim.email },
          metadata: isRecord(raw.metadata) ? raw.metadata : {},
          subscription,
          payment_status: "paid",
        } as unknown as Stripe.Checkout.Session;
        return {
          kind:
            isRecord(raw.metadata) && raw.metadata.founders_edition === "true"
              ? "founders_edition"
              : "pro",
          input: { session, subscription, customer },
        };
      }
    }
  } catch {
    // A missing/unavailable local database should fall through to Stripe.
  }
  return null;
}

async function purchaseFromStripeCustomer(
  client: RecoveryStripeClient,
  customer: Stripe.Customer,
): Promise<PaidBillingPurchase | null> {
  const subscriptions = await client.subscriptions.list({
    customer: customer.id,
    status: "all",
    limit: 100,
  });
  for (const subscription of subscriptions.data) {
    const metadata = subscription.metadata ?? {};
    const isCmuxPro = metadata.app === "cmux" && metadata.plan === "pro";
    const isFounder = metadata.founders_edition === "true";
    if (metadata.stackTeamId) continue;
    if (!isCmuxPro && !isFounder) continue;
    if (!isFounder && !["active", "trialing", "past_due"].includes(subscription.status)) {
      continue;
    }
    const session = {
      id: `recovery_${subscription.id}`,
      client_reference_id: metadata.stackUserId ?? null,
      customer: customer.id,
      customer_details: { email: customer.email },
      metadata,
      subscription,
      payment_status: "paid",
    } as unknown as Stripe.Checkout.Session;
    return {
      kind: isFounder ? "founders_edition" : "pro",
      input: { session, subscription, customer },
    };
  }

  const sessions = await client.checkout.sessions.list({
    customer: customer.id,
    limit: 100,
  });
  const session = sessions.data.find(
    (candidate) =>
      ["paid", "no_payment_required"].includes(candidate.payment_status) &&
      !candidate.metadata?.stackTeamId &&
      (candidate.metadata?.founders_edition === "true" ||
        (candidate.metadata?.app === "cmux" && candidate.metadata?.plan === "pro")),
  );
  if (!session) return null;
  const isFounder = session.metadata?.founders_edition === "true";
  const sessionSubscription =
    typeof session.subscription === "object" && session.subscription
      ? session.subscription
      : subscriptions.data.find(
          (candidate) => candidate.id === stringID(session.subscription),
        ) ?? null;
  return {
    kind: isFounder ? "founders_edition" : "pro",
    input: {
      session,
      subscription: sessionSubscription,
      customer,
    },
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}

function stringID(value: string | { id: string } | null | undefined): string | null {
  if (!value) return null;
  return typeof value === "string" ? value : value.id;
}

function isEmailSearchSafe(email: string): boolean {
  // The route validates this shape before reaching the service. Keep the
  // service safe for operator/library callers too; malformed values fall back
  // to the bounded customer list rather than becoming Stripe query syntax.
  return email.length <= 254 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/u.test(email);
}

function escapeStripeSearchValue(value: string): string {
  return value.replaceAll("\\", "\\\\").replaceAll("'", "\\'");
}
