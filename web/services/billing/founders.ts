import { eq } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { stripeCustomers } from "../../db/schema";
import { ACTIVE_STRIPE_SUBSCRIPTION_STATUSES } from "./purchase";
import { stripe as defaultStripe } from "./stripe";

export type FoundersStackUser = {
  readonly id: string;
  readonly primaryEmail?: string | null;
  readonly primaryEmailVerified?: boolean;
  readonly isAnonymous?: boolean;
};

export type FoundersSubscriptionSummary = {
  id: string;
  status: string;
  productName: string | null;
  currentPeriodEnd: Date | null;
  cancelAtPeriodEnd: boolean;
};

export type FoundersBillingResolution =
  | { status: "email-unverified"; email: string | null }
  | { status: "no-subscription"; email: string }
  | {
      status: "ready";
      email: string;
      customerId: string;
      subscriptions: FoundersSubscriptionSummary[];
    };

export type StripeLike = {
  customers: {
    list(params: {
      email: string;
      limit: number;
    }): Promise<{ data: readonly StripeCustomerLike[] }>;
  };
  subscriptions: {
    list(params: {
      customer: string;
      status: "all";
      limit: number;
      expand: readonly string[];
    }): Promise<{ data: readonly StripeSubscriptionLike[] }>;
  };
  billingPortal: {
    sessions: {
      create(params: {
        customer: string;
        return_url: string;
      }): Promise<{ url?: string | null }>;
    };
  };
};

type FoundersBillingDependencies = {
  stripe?: () => StripeLike;
  findMappedStripeCustomerId?: (stackUserId: string) => Promise<string | null>;
};

type StripeCustomerLike = {
  id: string;
  email?: string | null;
  deleted?: boolean;
};

type StripeSubscriptionLike = {
  id: string;
  status: string;
  created?: number | null;
  cancel_at_period_end?: boolean | null;
  items?: {
    data?: readonly StripeSubscriptionItemLike[];
  } | null;
};

type StripeSubscriptionItemLike = {
  current_period_end?: number | null;
  price?: {
    product?: string | StripeProductLike | null;
  } | null;
};

type StripeProductLike = {
  name?: string | null;
};

type CandidateSubscriptions = {
  customerId: string;
  subscriptions: readonly StripeSubscriptionLike[];
};

export async function resolveFoundersBilling(
  user: FoundersStackUser,
  dependencies: FoundersBillingDependencies = {},
): Promise<FoundersBillingResolution> {
  const rawEmail = user.primaryEmail?.trim() ?? "";
  if (
    user.isAnonymous ||
    !rawEmail ||
    user.primaryEmailVerified !== true
  ) {
    return {
      status: "email-unverified",
      email: rawEmail || null,
    };
  }

  const normalizedEmail = rawEmail.toLowerCase();
  const stripe = dependencies.stripe ?? stripeDependency;
  const subscriptionsByCandidate: CandidateSubscriptions[] = [];
  const seenCustomerIds = new Set<string>();
  const mappedCustomerId = await (dependencies.findMappedStripeCustomerId ??
    findMappedStripeCustomerId)(user.id);

  if (mappedCustomerId) {
    seenCustomerIds.add(mappedCustomerId);
    const mappedSubscriptions = await listSubscriptions(stripe(), mappedCustomerId);
    if (hasActiveSubscription(mappedSubscriptions)) {
      return readyResolution(
        normalizedEmail,
        mappedCustomerId,
        mappedSubscriptions,
      );
    }
    if (mappedSubscriptions.length > 0) {
      subscriptionsByCandidate.push({
        customerId: mappedCustomerId,
        subscriptions: mappedSubscriptions,
      });
    }
  }

  const emailCustomers = await listCustomersByEmail(stripe(), {
    rawEmail,
    normalizedEmail,
  });
  for (const customer of emailCustomers) {
    if (seenCustomerIds.has(customer.id)) continue;
    seenCustomerIds.add(customer.id);
    const subscriptions = await listSubscriptions(stripe(), customer.id);
    if (subscriptions.length > 0) {
      subscriptionsByCandidate.push({ customerId: customer.id, subscriptions });
    }
  }

  const activeCandidate = subscriptionsByCandidate.find((candidate) =>
    hasActiveSubscription(candidate.subscriptions),
  );
  const selectedCandidate = activeCandidate ?? subscriptionsByCandidate[0] ?? null;
  if (!selectedCandidate) {
    return { status: "no-subscription", email: normalizedEmail };
  }

  return readyResolution(
    normalizedEmail,
    selectedCandidate.customerId,
    selectedCandidate.subscriptions,
  );
}

export async function createFoundersPortalSession(
  customerId: string,
  returnUrl: string,
  dependencies: Pick<FoundersBillingDependencies, "stripe"> = {},
): Promise<string> {
  const stripe = dependencies.stripe ?? stripeDependency;
  const session = await stripe().billingPortal.sessions.create({
    customer: customerId,
    return_url: returnUrl,
  });
  if (!session.url) {
    throw new Error("Stripe Billing Portal Session did not include a URL");
  }
  return session.url;
}

function stripeDependency(): StripeLike {
  return defaultStripe() as unknown as StripeLike;
}

async function findMappedStripeCustomerId(stackUserId: string): Promise<string | null> {
  const rows = await cloudDb()
    .select({ id: stripeCustomers.id })
    .from(stripeCustomers)
    .where(eq(stripeCustomers.stackUserId, stackUserId))
    .limit(1);
  return rows[0]?.id ?? null;
}

async function listCustomersByEmail(
  stripe: StripeLike,
  input: { rawEmail: string; normalizedEmail: string },
): Promise<StripeCustomerLike[]> {
  const emails = input.rawEmail === input.normalizedEmail
    ? [input.rawEmail]
    : [input.rawEmail, input.normalizedEmail];
  const customers: StripeCustomerLike[] = [];
  const seen = new Set<string>();

  for (const email of emails) {
    const page = await stripe.customers.list({ email, limit: 10 });
    for (const customer of page.data) {
      if (
        customer.deleted ||
        customer.email?.trim().toLowerCase() !== input.normalizedEmail ||
        seen.has(customer.id)
      ) {
        continue;
      }
      seen.add(customer.id);
      customers.push(customer);
      if (customers.length >= 10) return customers;
    }
  }

  return customers;
}

async function listSubscriptions(
  stripe: StripeLike,
  customerId: string,
): Promise<readonly StripeSubscriptionLike[]> {
  const page = await stripe.subscriptions.list({
    customer: customerId,
    status: "all",
    limit: 10,
    expand: ["data.items.data.price.product"],
  });
  return page.data;
}

function readyResolution(
  email: string,
  customerId: string,
  subscriptions: readonly StripeSubscriptionLike[],
): FoundersBillingResolution {
  return {
    status: "ready",
    email,
    customerId,
    subscriptions: sortSubscriptions(subscriptions).map(subscriptionSummary),
  };
}

function sortSubscriptions(
  subscriptions: readonly StripeSubscriptionLike[],
): StripeSubscriptionLike[] {
  return [...subscriptions].sort((left, right) => {
    const activeDelta =
      Number(isActiveSubscription(right)) - Number(isActiveSubscription(left));
    if (activeDelta !== 0) return activeDelta;
    return (right.created ?? 0) - (left.created ?? 0);
  });
}

function subscriptionSummary(
  subscription: StripeSubscriptionLike,
): FoundersSubscriptionSummary {
  const firstItem = subscription.items?.data?.[0];
  const timestamp = firstItem?.current_period_end;
  return {
    id: subscription.id,
    status: subscription.status,
    productName: productName(firstItem?.price?.product),
    currentPeriodEnd: typeof timestamp === "number" ? new Date(timestamp * 1000) : null,
    cancelAtPeriodEnd: subscription.cancel_at_period_end === true,
  };
}

function productName(product: string | StripeProductLike | null | undefined): string | null {
  if (!product || typeof product === "string") return null;
  return typeof product.name === "string" && product.name.trim()
    ? product.name
    : null;
}

function hasActiveSubscription(
  subscriptions: readonly StripeSubscriptionLike[],
): boolean {
  return subscriptions.some(isActiveSubscription);
}

function isActiveSubscription(subscription: StripeSubscriptionLike): boolean {
  return ACTIVE_STRIPE_SUBSCRIPTION_STATUSES.has(subscription.status);
}
