import type Stripe from "stripe";
import { and, eq, inArray, isNull, or, sql } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import {
  billingEmailClaims,
  stripeCustomers,
  stripeSubscriptions,
} from "../../db/schema";
import {
  canonicalizeEmailForMatching,
  emailVariantsForMatching,
} from "./emailMatching";
import {
  recordFoundersCheckoutCompletion,
  recordProCheckoutCompletionByEmail,
  hasConflictingFounderMetadata,
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

// Recovery is reachable without an authenticated session. Keep every Stripe
// read bounded so a customer with a long history cannot hold the request open
// or cause an unbounded provider scan.
const MAX_RECOVERY_STRIPE_PAGES = 20;
const MAX_RECOVERY_STRIPE_RESULTS = 500;
const RECOVERY_STRIPE_DEADLINE_MS = 8_000;

type RecoveryStripeRequestOptions = {
  readonly maxNetworkRetries?: number;
  readonly timeout?: number;
};

class RecoveryBudgetExceeded extends Error {
  constructor(message: string) {
    super(message);
    this.name = "RecoveryBudgetExceeded";
  }
}

class RecoveryReadBudget {
  private readonly deadlineAt = Date.now() + RECOVERY_STRIPE_DEADLINE_MS;
  private pagesRead = 0;
  private resultsRead = 0;

  async read<T extends { readonly data: readonly unknown[] }>(
    operation: (
      options: RecoveryStripeRequestOptions,
    ) => Promise<T>,
  ): Promise<T> {
    if (this.pagesRead >= MAX_RECOVERY_STRIPE_PAGES) {
      throw new RecoveryBudgetExceeded("Stripe recovery page budget exceeded");
    }
    const remainingMs = this.deadlineAt - Date.now();
    if (remainingMs <= 0) {
      throw new RecoveryBudgetExceeded("Stripe recovery deadline exceeded");
    }
    this.pagesRead += 1;

    let timeoutID: ReturnType<typeof setTimeout> | undefined;
    const deadline = new Promise<never>((_, reject) => {
      timeoutID = setTimeout(() => {
        reject(new RecoveryBudgetExceeded("Stripe recovery deadline exceeded"));
      }, remainingMs);
    });
    try {
      const response = await Promise.race([
        operation({
          maxNetworkRetries: 0,
          timeout: remainingMs,
        }),
        deadline,
      ]);
      this.resultsRead += response.data.length;
      if (this.resultsRead > MAX_RECOVERY_STRIPE_RESULTS) {
        throw new RecoveryBudgetExceeded("Stripe recovery result budget exceeded");
      }
      return response;
    } finally {
      if (timeoutID !== undefined) clearTimeout(timeoutID);
    }
  }
}

type RecoveryDb = ReturnType<typeof cloudDb>;
type RecoveryStripeListResult<T> = {
  data: readonly T[];
  has_more?: boolean;
};
type RecoveryStripeClient = {
  readonly customers: {
    list?(
      options?: Record<string, unknown>,
      requestOptions?: RecoveryStripeRequestOptions,
    ): Promise<RecoveryStripeListResult<Stripe.Customer>>;
    search?(
      options?: Record<string, unknown>,
      requestOptions?: RecoveryStripeRequestOptions,
    ): Promise<RecoveryStripeListResult<Stripe.Customer>>;
  };
  readonly subscriptions: {
    list(
      options?: Record<string, unknown>,
      requestOptions?: RecoveryStripeRequestOptions,
    ): Promise<RecoveryStripeListResult<Stripe.Subscription>>;
  };
  readonly checkout: {
    sessions: {
      list(
        options?: Record<string, unknown>,
        requestOptions?: RecoveryStripeRequestOptions,
      ): Promise<RecoveryStripeListResult<Stripe.Checkout.Session>>;
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
  const literalEmail = email.trim().toLowerCase();
  const budget = new RecoveryReadBudget();
  try {
    const local = await findLocalPurchase(
      matchingEmail,
      literalEmail,
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
    const customers = await listStripeCustomersByEmail(client, email, budget);
    for (const customer of customers) {
      if (
        !customer.email ||
        canonicalizeEmailForMatching(customer.email) !== matchingEmail
      ) {
        continue;
      }
      const purchase = await purchaseFromStripeCustomer(client, customer, budget);
      if (purchase) return purchase;
    }
    // Payment-link checkouts can omit a persisted Stripe customer. Inspect a
    // bounded recent session page as a final fallback so a paid Founder's
    // session remains recoverable by email.
    const sessions = await listStripeCheckoutSessionsForCustomer(
      client,
      null,
      budget,
    );
    const session = sessions.find((candidate) => {
      const sessionEmail = candidate.customer_details?.email;
      if (
        !sessionEmail ||
        canonicalizeEmailForMatching(sessionEmail) !== matchingEmail ||
        !["paid", "no_payment_required"].includes(candidate.payment_status)
      ) {
        return false;
      }
      if (candidate.metadata?.stackTeamId) return false;
      const subscription = expandedSubscription(candidate);
      return isRecognizedRecoveryMetadata(candidate.metadata, subscription);
    });
    if (session) {
      const subscription = expandedSubscription(session);
      const isFounder = isFounderRecoveryPurchase(session.metadata, subscription);
      const customerId = stringID(session.customer) ?? `recovery_${session.id}`;
      const customer = {
        id: customerId,
        deleted: false,
        email: session.customer_details?.email ?? null,
      } as unknown as Stripe.Customer;
      if (!isFounder && !isActiveRecoverySubscription(subscription)) {
        return null;
      }
      return {
        kind: isFounder ? "founders_edition" : "pro",
        input: { session, subscription, customer },
      };
    }
  } catch (error) {
    if (error instanceof RecoveryBudgetExceeded) return null;
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
  literalEmail: string,
  db: RecoveryDb,
): Promise<PaidBillingPurchase | null> {
  try {
    const emailPredicate = billingEmailPredicate(
      stripeCustomers.email,
      matchingEmail,
      literalEmail,
    );
    // Keep the ownership lookup in one bounded query. The previous customer
    // loop issued one subscription query per customer, which made a recovery
    // request scale linearly with the number of historical customer rows.
    const rows = await db
      .select({
        customerId: stripeCustomers.id,
        email: stripeCustomers.email,
        stackUserId: stripeCustomers.stackUserId,
        stackTeamId: stripeCustomers.stackTeamId,
        subscriptionId: stripeSubscriptions.id,
        subscriptionCustomerId: stripeSubscriptions.customerId,
        subscriptionStackUserId: stripeSubscriptions.stackUserId,
        subscriptionStackTeamId: stripeSubscriptions.stackTeamId,
        subscriptionStatus: stripeSubscriptions.status,
        subscriptionPlan: stripeSubscriptions.plan,
        subscriptionScope: stripeSubscriptions.scope,
        subscriptionCancelAtPeriodEnd: stripeSubscriptions.cancelAtPeriodEnd,
        subscriptionRaw: stripeSubscriptions.raw,
      })
      .from(stripeCustomers)
      .innerJoin(
        stripeSubscriptions,
        eq(stripeSubscriptions.customerId, stripeCustomers.id),
      )
      .where(
        and(
          emailPredicate,
          isNull(stripeCustomers.stackTeamId),
          isNull(stripeSubscriptions.stackTeamId),
          eq(stripeSubscriptions.plan, PRO_PLAN_ID),
          or(
            eq(stripeSubscriptions.scope, "user"),
            isNull(stripeSubscriptions.scope),
          ),
          or(
            inArray(stripeSubscriptions.status, [
              "active",
              "trialing",
              "past_due",
            ]),
            sql`${stripeSubscriptions.raw}->'metadata'->>'founders_edition' = 'true'`,
          ),
        ),
      )
      .limit(500);
    for (const row of rows) {
      if (
        !row.email ||
        row.stackTeamId != null ||
        canonicalizeEmailForMatching(row.email) !== matchingEmail ||
        row.subscriptionCustomerId !== row.customerId ||
        row.subscriptionStackUserId == null ||
        row.subscriptionStackTeamId != null ||
        row.subscriptionPlan !== PRO_PLAN_ID ||
        (row.subscriptionScope != null && row.subscriptionScope !== "user")
      ) {
        continue;
      }
      const raw = isRecord(row.subscriptionRaw) ? row.subscriptionRaw : {};
      const metadata = isRecord(raw.metadata) ? raw.metadata : {};
      const isFounder = metadata.founders_edition === "true";
      const app = metadata.app;
      if (app && app !== "cmux" && !isFounder) continue;
      if (
        !isFounder &&
        !["active", "trialing", "past_due"].includes(row.subscriptionStatus)
      ) {
        continue;
      }
      const kind: PaidBillingPurchaseKind =
        isFounder ? "founders_edition" : "pro";
      const subscription = {
        ...raw,
        id: row.subscriptionId,
        customer: row.subscriptionCustomerId,
        status: row.subscriptionStatus,
        metadata,
        cancel_at_period_end: row.subscriptionCancelAtPeriodEnd,
        items: raw.items ?? { data: [] },
      } as unknown as Stripe.Subscription;
      const customer = {
        id: row.customerId,
        deleted: false,
        email: row.email,
      } as unknown as Stripe.Customer;
      const session = {
        id: `recovery_${row.subscriptionId}`,
        client_reference_id: row.stackUserId,
        customer: row.customerId,
        customer_details: { email: row.email },
        metadata,
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
      .where(
        billingEmailPredicate(
          billingEmailClaims.email,
          matchingEmail,
          literalEmail,
        ),
      )
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

/**
 * Restrict billing-email reads in SQL while retaining canonical comparison in
 * memory for legacy rows that predate Gmail normalization. The lower-case
 * expression also covers users who type a different case than Stripe stored.
 */
function billingEmailPredicate(
  column: typeof stripeCustomers.email | typeof billingEmailClaims.email,
  matchingEmail: string,
  literalEmail: string,
) {
  const variants = [
    ...new Set([
      ...emailVariantsForMatching(literalEmail),
      matchingEmail,
      literalEmail,
    ]),
  ].filter(Boolean);
  const exact = variants.map((value) => eq(column, value));
  return or(...exact, sql`btrim(lower(${column})) = ${literalEmail}`) ??
    eq(column, matchingEmail);
}

async function purchaseFromStripeCustomer(
  client: RecoveryStripeClient,
  customer: Stripe.Customer,
  budget: RecoveryReadBudget,
): Promise<PaidBillingPurchase | null> {
  const subscriptions = await listStripeSubscriptionsForCustomer(
    client,
    customer.id,
    budget,
  );
  const sessions = await listStripeCheckoutSessionsForCustomer(
    client,
    customer.id,
    budget,
  );
  for (const subscription of subscriptions) {
    const metadata = subscription.metadata ?? {};
    if (hasConflictingFounderMetadata({ metadata: null }, subscription)) {
      // A malformed Founder/Pro or Founder/Team marker must not fall through
      // as an ordinary Pro subscription after the Founder branch rejects it.
      continue;
    }
    const isCmuxPro = metadata.app === "cmux" && metadata.plan === "pro";
    const isFounder = isFounderRecoveryPurchase(undefined, subscription);
    if (metadata.stackTeamId) continue;
    if (!isCmuxPro && !isFounder) continue;
    if (isFounder) {
      // A subscription record alone is not payment proof. Stripe can create
      // an incomplete subscription before the first invoice is paid. Require
      // a settled checkout session that names this exact subscription before
      // recovering a one-time Founder entitlement.
      const settledSession = sessions.find((candidate) =>
        isSettledFounderCheckoutSession(candidate, subscription.id),
      );
      if (!settledSession) continue;
      return {
        kind: "founders_edition",
        input: { session: settledSession, subscription, customer },
      };
    }
    if (!["active", "trialing", "past_due"].includes(subscription.status)) {
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

  const session = sessions.find(
    (candidate) => {
      const subscription = expandedSubscription(candidate);
      return (
        ["paid", "no_payment_required"].includes(candidate.payment_status) &&
        !candidate.metadata?.stackTeamId &&
        !subscription?.metadata?.stackTeamId &&
        isRecognizedRecoveryMetadata(candidate.metadata, subscription)
      );
    },
  );
  if (!session) return null;
  const isFounder = isFounderRecoveryPurchase(
    session.metadata,
    expandedSubscription(session),
  );
  const sessionSubscription =
    typeof session.subscription === "object" && session.subscription
      ? session.subscription
      : subscriptions.find(
          (candidate) => candidate.id === stringID(session.subscription),
        ) ?? null;
  if (!isFounder && !isActiveRecoverySubscription(sessionSubscription)) {
    return null;
  }
  return {
    kind: isFounder ? "founders_edition" : "pro",
    input: {
      session,
      subscription: sessionSubscription,
      customer,
    },
  };
}

function isSettledFounderCheckoutSession(
  session: Stripe.Checkout.Session,
  subscriptionId: string,
): boolean {
  if (!["paid", "no_payment_required"].includes(session.payment_status ?? "")) {
    return false;
  }
  if (stringID(session.subscription) !== subscriptionId) return false;
  if (session.metadata?.stackTeamId) return false;
  if (session.metadata?.app && session.metadata.app !== "cmux") {
    return false;
  }
  return true;
}

/** Walk a customer's complete subscription history without issuing unbounded reads. */
async function listStripeSubscriptionsForCustomer(
  client: RecoveryStripeClient,
  customerId: string,
  budget: RecoveryReadBudget,
): Promise<readonly Stripe.Subscription[]> {
  const subscriptions: Stripe.Subscription[] = [];
  let startingAfter: string | undefined;
  for (;;) {
    const response = await budget.read((requestOptions) =>
      client.subscriptions.list(
        {
          customer: customerId,
          status: "all",
          limit: 100,
          ...(startingAfter ? { starting_after: startingAfter } : {}),
        },
        requestOptions,
      ),
    );
    subscriptions.push(...response.data);
    const lastID = response.data.at(-1)?.id;
    if (!response.has_more || !lastID || lastID === startingAfter) break;
    startingAfter = lastID;
  }
  return subscriptions;
}

/** Walk all checkout-session pages for one customer, with a cursor guard. */
async function listStripeCheckoutSessionsForCustomer(
  client: RecoveryStripeClient,
  customerId: string | null,
  budget: RecoveryReadBudget,
): Promise<readonly Stripe.Checkout.Session[]> {
  const sessions: Stripe.Checkout.Session[] = [];
  let startingAfter: string | undefined;
  for (;;) {
    const response = await budget.read((requestOptions) =>
      client.checkout.sessions.list(
        {
          ...(customerId ? { customer: customerId } : {}),
          limit: 100,
          ...(startingAfter ? { starting_after: startingAfter } : {}),
        },
        requestOptions,
      ),
    );
    sessions.push(...response.data);
    const lastID = response.data.at(-1)?.id;
    if (!response.has_more || !lastID || lastID === startingAfter) break;
    startingAfter = lastID;
  }
  return sessions;
}

function isActiveRecoverySubscription(
  subscription: Stripe.Subscription | null | undefined,
): boolean {
  return Boolean(
    subscription &&
      ["active", "trialing", "past_due"].includes(subscription.status),
  );
}

function expandedSubscription(
  session: Stripe.Checkout.Session,
): Stripe.Subscription | null {
  return typeof session.subscription === "object" && session.subscription
    ? session.subscription
    : null;
}

function isFounderRecoveryPurchase(
  sessionMetadata: Stripe.Metadata | null | undefined,
  subscription: Stripe.Subscription | null | undefined,
): boolean {
  if (hasConflictingFounderMetadata({ metadata: sessionMetadata ?? null }, subscription)) {
    return false;
  }
  if (sessionMetadata?.app && sessionMetadata.app !== "cmux") return false;
  if (
    !sessionMetadata?.app &&
    subscription?.metadata?.app &&
    subscription.metadata.app !== "cmux"
  ) {
    return false;
  }
  return (
    sessionMetadata?.founders_edition === "true" ||
    subscription?.metadata?.founders_edition === "true"
  );
}

function isRecognizedRecoveryMetadata(
  sessionMetadata: Stripe.Metadata | null | undefined,
  subscription: Stripe.Subscription | null | undefined,
): boolean {
  if (hasConflictingFounderMetadata({ metadata: sessionMetadata ?? null }, subscription)) {
    return false;
  }
  if (sessionMetadata?.app) {
    return (
      sessionMetadata.app === "cmux" &&
      (sessionMetadata.plan === "pro" ||
        sessionMetadata.founders_edition === "true")
    );
  }
  if (subscription?.metadata?.app) {
    return (
      subscription.metadata.app === "cmux" &&
      (subscription.metadata.plan === "pro" ||
        subscription.metadata.founders_edition === "true")
    );
  }
  return isFounderRecoveryPurchase(sessionMetadata, subscription);
}

/** Query both literal/canonical spellings and paginate each Stripe result. */
async function listStripeCustomersByEmail(
  client: RecoveryStripeClient,
  email: string,
  budget: RecoveryReadBudget,
): Promise<readonly Stripe.Customer[]> {
  const trimmed = email.trim();
  const variants = emailVariantsForMatching(trimmed);
  const customers: Stripe.Customer[] = [];
  for (const variant of variants) {
    if (client.customers.search && isEmailSearchSafe(variant)) {
      try {
        const response = await budget.read((requestOptions) =>
          client.customers.search!({
            query: `email:'${escapeStripeSearchValue(variant)}'`,
            limit: 100,
          }, requestOptions),
        );
        customers.push(...response.data);
      } catch (error) {
        if (error instanceof RecoveryBudgetExceeded) throw error;
        // Fall through to the exact-email list endpoint when search is
        // unavailable or rejects the provider query syntax.
      }
    }
    if (!client.customers.list) continue;
    let startingAfter: string | undefined;
    for (;;) {
      let response: Awaited<ReturnType<NonNullable<RecoveryStripeClient["customers"]["list"]>>>;
      try {
        response = await budget.read((requestOptions) =>
          client.customers.list!({
            email: variant,
            limit: 100,
            ...(startingAfter ? { starting_after: startingAfter } : {}),
          }, requestOptions),
        );
      } catch (error) {
        if (error instanceof RecoveryBudgetExceeded) throw error;
        // Some Stripe API versions do not expose the email filter. Keep the
        // recovery path fail-closed rather than issuing an unbounded scan.
        break;
      }
      customers.push(...response.data);
      const lastID = response.data.at(-1)?.id;
      if (!response.has_more || !lastID || lastID === startingAfter) break;
      startingAfter = lastID;
    }
  }
  return dedupeCustomers(customers);
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
