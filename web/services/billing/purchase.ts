import { and, desc, eq, sql } from "drizzle-orm";
import type Stripe from "stripe";

import { stackServerApp } from "../../app/lib/stack";
import { cloudDb } from "../../db/client";
import {
  billingEmailClaims,
  stripeCustomers,
  stripeSubscriptions,
} from "../../db/schema";
import { PRO_PLAN_ID, syncProPlanMetadata } from "./pro";

export const ACTIVE_STRIPE_SUBSCRIPTION_STATUSES = new Set([
  "active",
  "trialing",
  "past_due",
]);

type BillingDb = ReturnType<typeof cloudDb>;

type StackBillingUser = {
  readonly id: string;
  readonly primaryEmail?: string | null;
  readonly clientReadOnlyMetadata?: unknown;
  update(options: {
    primaryEmail?: string | null;
    primaryEmailAuthEnabled?: boolean;
    clientReadOnlyMetadata?: unknown;
  }): Promise<unknown>;
};

type StackBillingApp = {
  getUser(id: string): Promise<StackBillingUser | null>;
};

type BillingPurchaseDependencies = {
  db?: BillingDb;
  stackApp?: StackBillingApp | null;
};

export type CheckoutCompletionInput = {
  session: Stripe.Checkout.Session;
  subscription?: Stripe.Subscription | null;
  customer?: Stripe.Customer | Stripe.DeletedCustomer | null;
};

export async function recordCheckoutCompletion(
  input: CheckoutCompletionInput,
  dependencies: BillingPurchaseDependencies = {},
): Promise<{ stackUserId: string; subscriptionId: string }> {
  const subscription = input.subscription ?? expandedSubscription(input.session);
  if (!subscription) {
    throw new Error("Stripe checkout session is missing an expanded subscription");
  }
  const customerId = customerIdFromSession(input.session, input.customer);
  if (!customerId) {
    throw new Error("Stripe checkout session is missing a customer id");
  }
  const stackUserId = stackUserIdFromSession(input.session, subscription);
  if (!stackUserId) {
    throw new Error("Stripe checkout session is missing stackUserId");
  }

  const email = checkoutEmail(input.session, input.customer);
  const db = dependencies.db ?? cloudDb();
  await upsertStripeCustomer(db, {
    customerId,
    stackUserId,
    email,
  });
  await upsertStripeSubscription(db, {
    subscription,
    customerId,
    stackUserId,
  });

  const user = await loadStackUser(stackUserId, dependencies.stackApp);
  if (email) {
    await attachPurchaseEmailOrRecordClaim(db, {
      user,
      email,
      stripeCustomerId: customerId,
      stackUserId,
    });
  }
  await syncProPlanMetadata(user, true);

  return { stackUserId, subscriptionId: subscription.id };
}

export async function applySubscriptionUpdate(
  subscription: Stripe.Subscription,
  dependencies: BillingPurchaseDependencies = {},
): Promise<{ stackUserId: string; isActive: boolean } | { skipped: true }> {
  if (subscription.metadata?.app !== "cmux") return { skipped: true };

  const db = dependencies.db ?? cloudDb();
  const customerId = customerIdFromSubscription(subscription);
  if (!customerId) return { skipped: true };

  const stackUserId =
    subscription.metadata?.stackUserId ??
    (await stackUserIdForStripeCustomer(db, customerId));
  if (!stackUserId) return { skipped: true };

  await upsertStripeSubscription(db, {
    subscription,
    customerId,
    stackUserId,
  });

  const isActive = isActiveStripeSubscriptionStatus(subscription.status);
  const user = await loadStackUser(stackUserId, dependencies.stackApp);
  await syncProPlanMetadata(user, isActive);
  return { stackUserId, isActive };
}

export async function latestStripeSubscriptionForSession(
  session: Stripe.Checkout.Session,
  db: BillingDb = cloudDb(),
) {
  const subscription = expandedSubscription(session);
  const subscriptionId = subscription?.id ?? stringId(session.subscription);
  if (!subscriptionId) return null;
  const rows = await db
    .select()
    .from(stripeSubscriptions)
    .where(eq(stripeSubscriptions.id, subscriptionId))
    .limit(1);
  return rows[0] ?? null;
}

export function isActiveStripeSubscriptionStatus(status: string): boolean {
  return ACTIVE_STRIPE_SUBSCRIPTION_STATUSES.has(status);
}

export function isCmuxCheckoutSession(
  session: Pick<Stripe.Checkout.Session, "client_reference_id" | "metadata">,
): boolean {
  if (session.metadata?.app === "cmux") return true;
  if (session.metadata?.app) return false;
  return Boolean(session.client_reference_id && session.metadata?.plan === "pro");
}

async function loadStackUser(
  stackUserId: string,
  stackApp: StackBillingApp | null | undefined,
): Promise<StackBillingUser> {
  const app = stackApp ?? stackServerApp;
  if (!app) throw new Error("Stack Auth is not configured");
  const user = await app.getUser(stackUserId);
  if (!user) throw new Error(`Stack user not found for Stripe purchase: ${stackUserId}`);
  return user;
}

async function upsertStripeCustomer(
  db: BillingDb,
  input: { customerId: string; stackUserId: string; email: string | null },
): Promise<void> {
  const [existingForStackUser] = await db
    .select({ id: stripeCustomers.id })
    .from(stripeCustomers)
    .where(eq(stripeCustomers.stackUserId, input.stackUserId))
    .limit(1);
  if (existingForStackUser) {
    await db
      .update(stripeCustomers)
      .set({
        id: input.customerId,
        email: input.email,
        updatedAt: sql`now()`,
      })
      .where(eq(stripeCustomers.stackUserId, input.stackUserId));
    return;
  }

  try {
    await db
      .insert(stripeCustomers)
      .values({
        id: input.customerId,
        stackUserId: input.stackUserId,
        email: input.email,
      })
      .onConflictDoUpdate({
        target: stripeCustomers.id,
        set: {
          stackUserId: input.stackUserId,
          email: input.email,
          updatedAt: sql`now()`,
        },
      });
  } catch (error) {
    if (!isStackUserUniqueConflict(error)) throw error;
    await db
      .update(stripeCustomers)
      .set({
        id: input.customerId,
        email: input.email,
        updatedAt: sql`now()`,
      })
      .where(eq(stripeCustomers.stackUserId, input.stackUserId));
  }
}

async function upsertStripeSubscription(
  db: BillingDb,
  input: {
    subscription: Stripe.Subscription;
    customerId: string;
    stackUserId: string;
  },
): Promise<void> {
  const { subscription } = input;
  await db
    .insert(stripeSubscriptions)
    .values({
      id: subscription.id,
      customerId: input.customerId,
      stackUserId: input.stackUserId,
      status: subscription.status,
      priceId: subscriptionPriceId(subscription),
      plan: PRO_PLAN_ID,
      currentPeriodEnd: subscriptionCurrentPeriodEnd(subscription),
      cancelAtPeriodEnd: subscription.cancel_at_period_end,
      raw: JSON.parse(JSON.stringify(subscription)) as Record<string, unknown>,
    })
    .onConflictDoUpdate({
      target: stripeSubscriptions.id,
      set: {
        customerId: input.customerId,
        stackUserId: input.stackUserId,
        status: subscription.status,
        priceId: subscriptionPriceId(subscription),
        plan: PRO_PLAN_ID,
        currentPeriodEnd: subscriptionCurrentPeriodEnd(subscription),
        cancelAtPeriodEnd: subscription.cancel_at_period_end,
        raw: JSON.parse(JSON.stringify(subscription)) as Record<string, unknown>,
        updatedAt: sql`now()`,
      },
    });
}

async function attachPurchaseEmailOrRecordClaim(
  db: BillingDb,
  input: {
    user: StackBillingUser;
    email: string;
    stripeCustomerId: string;
    stackUserId: string;
  },
): Promise<void> {
  if (input.user.primaryEmail) return;
  try {
    await input.user.update({
      primaryEmail: input.email,
      primaryEmailAuthEnabled: true,
    });
  } catch (error) {
    if (!isEmailAlreadyUsedError(error)) throw error;
    const existing = await db
      .select({ id: billingEmailClaims.id })
      .from(billingEmailClaims)
      .where(
        and(
          eq(billingEmailClaims.email, input.email),
          eq(billingEmailClaims.stripeCustomerId, input.stripeCustomerId),
          eq(billingEmailClaims.stackUserId, input.stackUserId),
          eq(billingEmailClaims.plan, PRO_PLAN_ID),
        ),
      )
      .limit(1);
    if (existing.length > 0) return;
    await db.insert(billingEmailClaims).values({
      email: input.email,
      stripeCustomerId: input.stripeCustomerId,
      stackUserId: input.stackUserId,
      plan: PRO_PLAN_ID,
    });
  }
}

async function stackUserIdForStripeCustomer(
  db: BillingDb,
  customerId: string,
): Promise<string | null> {
  const rows = await db
    .select({ stackUserId: stripeCustomers.stackUserId })
    .from(stripeCustomers)
    .where(eq(stripeCustomers.id, customerId))
    .orderBy(desc(stripeCustomers.updatedAt))
    .limit(1);
  return rows[0]?.stackUserId ?? null;
}

function expandedSubscription(
  session: Stripe.Checkout.Session,
): Stripe.Subscription | null {
  return typeof session.subscription === "object" && session.subscription !== null
    ? session.subscription
    : null;
}

function stackUserIdFromSession(
  session: Stripe.Checkout.Session,
  subscription: Stripe.Subscription,
): string | null {
  return session.client_reference_id ?? subscription.metadata?.stackUserId ?? null;
}

function customerIdFromSession(
  session: Stripe.Checkout.Session,
  customer: Stripe.Customer | Stripe.DeletedCustomer | null | undefined,
): string | null {
  return customer && !customer.deleted
    ? customer.id
    : stringId(session.customer);
}

function customerIdFromSubscription(subscription: Stripe.Subscription): string | null {
  return stringId(subscription.customer);
}

function checkoutEmail(
  session: Stripe.Checkout.Session,
  customer: Stripe.Customer | Stripe.DeletedCustomer | null | undefined,
): string | null {
  const email = session.customer_details?.email ?? (customer && !customer.deleted ? customer.email : null);
  return email ? email.trim().toLowerCase() : null;
}

function subscriptionPriceId(subscription: Stripe.Subscription): string | null {
  return subscription.items.data[0]?.price.id ?? null;
}

function subscriptionCurrentPeriodEnd(subscription: Stripe.Subscription): Date | null {
  const timestamp = subscription.items.data[0]?.current_period_end;
  return typeof timestamp === "number" ? new Date(timestamp * 1000) : null;
}

function stringId(value: string | { id: string } | null | undefined): string | null {
  if (!value) return null;
  return typeof value === "string" ? value : value.id;
}

function isEmailAlreadyUsedError(error: unknown): boolean {
  const text = error instanceof Error ? `${error.name} ${error.message}` : String(error);
  return /already.{0,40}(used|taken)|CONTACT_CHANNEL_ALREADY_USED_FOR_AUTH_BY_SOMEONE_ELSE/i.test(text);
}

function isStackUserUniqueConflict(error: unknown): boolean {
  if (isStackUserUniqueConflictCandidate(error)) return true;
  const cause = (error as { cause?: unknown } | null)?.cause;
  if (isStackUserUniqueConflictCandidate(cause)) return true;
  const text = error instanceof Error ? error.message : String(error);
  return /stripe_customers_stack_user_id_unique/.test(text);
}

function isStackUserUniqueConflictCandidate(error: unknown): boolean {
  const candidate = error as { code?: string; constraint?: string } | null;
  return (
    candidate?.code === "23505" &&
    candidate.constraint === "stripe_customers_stack_user_id_unique"
  );
}
