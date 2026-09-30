// In-app switch between paid personal plans (Go, Pro, Max). An upgrade takes
// effect now and charges the prorated difference now; a downgrade takes
// effect now and credits the unused time to later invoices. The preview and
// the change use the same proration date, so the amount shown is the amount
// charged.

import type Stripe from "stripe";
import { MAX_PRICING_USD, PRO_PRICING_USD } from "./plans";
import { stripeBillingStatusForUser, type StripeBillingStatus } from "./pro";
import { applySubscriptionUpdate } from "./purchase";
import { resolveMaxPrice, resolveProPrice, stripe } from "./stripe";
import { personalPlanIdForSubscription } from "./subscriptionPlan";

export type SwitchTargetPlan = "pro" | "max";
type PaidPersonalPlan = "go" | "pro" | "max";

export type PlanChangeRefusal =
  | "no_subscription"
  | "cancel_scheduled"
  | "same_plan"
  | "not_switchable"
  | "payment_failed";

export class PlanChangeError extends Error {
  override readonly name = "PlanChangeError";
  constructor(readonly reason: PlanChangeRefusal) {
    super(reason);
  }
}

export type PlanChangePreview = {
  readonly plan: SwitchTargetPlan;
  readonly direction: "upgrade" | "downgrade";
  readonly currency: string;
  /** Minor units charged when the change applies (0 for a downgrade). */
  readonly amountDueToday: number;
  /** Minor units credited for unused time (0 for an upgrade). */
  readonly credit: number;
  readonly nextRenewalAt: string | null;
  /** Minor units of the next renewal invoice. */
  readonly nextInvoiceAmount: number;
  /** Unix seconds; pass back to the change so Stripe prorates the same way. */
  readonly prorationDate: number;
};

type StripeClient = Pick<Stripe, "subscriptions" | "invoices">;

export type PlanChangeDependencies = {
  readonly billingStatus: (stackUserId: string) => Promise<StripeBillingStatus>;
  readonly priceFor: (plan: SwitchTargetPlan) => Promise<string>;
  readonly stripe: () => StripeClient;
  readonly now: () => number;
  /** Stores the updated subscription the way the Stripe webhook would. */
  readonly syncSubscription: (subscription: Stripe.Subscription) => Promise<unknown>;
};

const defaultDependencies: PlanChangeDependencies = {
  billingStatus: stripeBillingStatusForUser,
  priceFor: (plan) => (plan === "max" ? resolveMaxPrice() : resolveProPrice("month")),
  stripe,
  now: () => Math.floor(Date.now() / 1000),
  syncSubscription: (subscription) => applySubscriptionUpdate(subscription),
};

const PLAN_RANK: Readonly<Record<PaidPersonalPlan, number>> = { go: 1, pro: 2, max: 3 };
const MONTHLY_AMOUNT: Readonly<Record<SwitchTargetPlan, number>> = {
  pro: PRO_PRICING_USD.month.billedAmount * 100,
  max: MAX_PRICING_USD.month.billedAmount * 100,
};
/** A preview older than this, or from the future, is not reused for the charge. */
const PRORATION_DATE_MAX_AGE_SECONDS = 3_600;

type Switch = {
  readonly customerId: string;
  readonly subscription: Stripe.Subscription;
  readonly itemId: string;
  readonly price: string;
  readonly direction: "upgrade" | "downgrade";
  readonly periodEnd: number | null;
};

async function resolveSwitch(
  userId: string,
  target: SwitchTargetPlan,
  deps: PlanChangeDependencies,
): Promise<Switch> {
  const status = await deps.billingStatus(userId);
  const active = ["active", "trialing"].includes(status.subscriptionStatus ?? "");
  if (!status.hasRecurringSubscription || !status.subscriptionId || !active) {
    throw new PlanChangeError("no_subscription");
  }
  if (status.cancelAtPeriodEnd) throw new PlanChangeError("cancel_scheduled");
  if (status.activePlanId === target) throw new PlanChangeError("same_plan");
  const subscription = await deps.stripe().subscriptions.retrieve(status.subscriptionId);
  if (subscription.cancel_at_period_end) throw new PlanChangeError("cancel_scheduled");
  const item = subscription.items?.data?.[0];
  if (!item) throw new PlanChangeError("no_subscription");
  const current = personalPlanIdForSubscription(subscription);
  if (!current) throw new PlanChangeError("not_switchable");
  if (current === target) throw new PlanChangeError("same_plan");
  const customerId = typeof subscription.customer === "string" ? subscription.customer : subscription.customer?.id;
  if (!customerId) throw new PlanChangeError("no_subscription");
  return {
    customerId,
    subscription,
    itemId: item.id,
    price: await deps.priceFor(target),
    direction: PLAN_RANK[target] > PLAN_RANK[current] ? "upgrade" : "downgrade",
    periodEnd: typeof item.current_period_end === "number" ? item.current_period_end : null,
  };
}

function prorationBehavior(direction: Switch["direction"]) {
  return direction === "upgrade" ? ("always_invoice" as const) : ("create_prorations" as const);
}

type PreviewLine = { readonly amount: number; readonly parent?: { readonly subscription_item_details?: { readonly proration?: boolean } | null } | null; readonly proration?: boolean };

function prorationCredit(invoice: Stripe.Invoice): number {
  const lines = (invoice.lines?.data ?? []) as unknown as readonly PreviewLine[];
  return lines
    .filter((line) => (line.parent?.subscription_item_details?.proration ?? line.proration) === true && line.amount < 0)
    .reduce((total, line) => total - line.amount, 0);
}

export async function previewPersonalPlanChange(
  input: { readonly userId: string; readonly target: SwitchTargetPlan },
  deps: PlanChangeDependencies = defaultDependencies,
): Promise<PlanChangePreview> {
  const change = await resolveSwitch(input.userId, input.target, deps);
  const prorationDate = deps.now();
  const invoice = await deps.stripe().invoices.createPreview({
    customer: change.customerId,
    subscription: change.subscription.id,
    subscription_details: {
      items: [{ id: change.itemId, price: change.price }],
      proration_behavior: prorationBehavior(change.direction),
      proration_date: prorationDate,
    },
  });
  const upgrade = change.direction === "upgrade";
  return {
    plan: input.target,
    direction: change.direction,
    currency: invoice.currency,
    amountDueToday: upgrade ? invoice.amount_due : 0,
    credit: upgrade ? 0 : prorationCredit(invoice),
    nextRenewalAt: change.periodEnd === null ? null : new Date(change.periodEnd * 1000).toISOString(),
    nextInvoiceAmount: upgrade ? MONTHLY_AMOUNT[input.target] : invoice.amount_due,
    prorationDate,
  };
}

function isCardError(error: unknown): boolean {
  const type = typeof error === "object" && error !== null ? (error as { type?: unknown }).type : undefined;
  return type === "StripeCardError" || type === "card_error";
}

export async function applyPersonalPlanChange(
  input: { readonly userId: string; readonly target: SwitchTargetPlan; readonly prorationDate: number },
  deps: PlanChangeDependencies = defaultDependencies,
): Promise<{ readonly plan: SwitchTargetPlan }> {
  const change = await resolveSwitch(input.userId, input.target, deps);
  const now = deps.now();
  const fresh = input.prorationDate <= now && now - input.prorationDate <= PRORATION_DATE_MAX_AGE_SECONDS;
  let updated: Stripe.Subscription;
  try {
    updated = await deps.stripe().subscriptions.update(change.subscription.id, {
      items: [{ id: change.itemId, price: change.price }],
      proration_behavior: prorationBehavior(change.direction),
      proration_date: fresh ? input.prorationDate : now,
      // An upgrade that cannot be paid fails whole instead of leaving an
      // unpaid invoice on a changed plan.
      payment_behavior: "error_if_incomplete",
      metadata: { ...change.subscription.metadata, plan: input.target },
    });
  } catch (error) {
    if (isCardError(error)) throw new PlanChangeError("payment_failed");
    throw error;
  }
  await deps.syncSubscription(updated);
  return { plan: input.target };
}
