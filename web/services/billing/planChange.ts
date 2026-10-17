// In-app switch between paid personal plans (Go, Pro, Max). The switch keeps
// the subscription's billing interval (Pro yearly becomes Max yearly), so the
// billing period and its renewal date do not move. An upgrade takes effect
// now and charges the prorated difference now; a downgrade takes effect now
// and credits the unused time to later invoices. The preview and the change
// use the same proration date, so the amount shown is the amount charged.

import type Stripe from "stripe";
import type { BillingInterval } from "./plans";
import { planTierRank } from "./planTier";
import { stripeBillingStatusForUser, type StripeBillingStatus } from "./pro";
import { applySubscriptionUpdate } from "./purchase";
import { resolveMaxPrice, resolveProPrice, stripe } from "./stripe";
import { personalPlanIdForSubscription } from "./subscriptionPlan";
import { planItem } from "./subscriptionItems";

export type SwitchTargetPlan = "pro" | "max";

export type PlanChangeRefusal =
  | "no_subscription"
  | "cancel_scheduled"
  | "same_plan"
  | "not_switchable"
  | "payment_failed"
  | "preview_unavailable";

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
  /** How often the renewal charges; a switch keeps the subscription's interval. */
  readonly interval: BillingInterval;
  /** Unix seconds; pass back to the change so Stripe prorates the same way. */
  readonly prorationDate: number;
};

type StripeClient = Pick<Stripe, "subscriptions" | "invoices">;

export type PlanChangeDependencies = {
  readonly billingStatus: (stackUserId: string) => Promise<StripeBillingStatus>;
  /** The current catalog price of `plan` billed every `interval`. */
  readonly priceFor: (plan: SwitchTargetPlan, interval: BillingInterval) => Promise<string>;
  readonly stripe: () => StripeClient;
  readonly now: () => number;
  /** Stores the updated subscription the way the Stripe webhook would. */
  readonly syncSubscription: (subscription: Stripe.Subscription) => Promise<unknown>;
};

const defaultDependencies: PlanChangeDependencies = {
  billingStatus: stripeBillingStatusForUser,
  priceFor: (plan, interval) => (plan === "max" ? resolveMaxPrice(interval) : resolveProPrice(interval)),
  stripe,
  now: () => Math.floor(Date.now() / 1000),
  syncSubscription: (subscription) => applySubscriptionUpdate(subscription),
};

/** A preview older than this, or from the future, is not reused for the charge. */
const PRORATION_DATE_MAX_AGE_SECONDS = 3_600;

type Switch = {
  readonly customerId: string;
  readonly subscription: Stripe.Subscription;
  readonly itemId: string;
  readonly price: string;
  readonly interval: BillingInterval;
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
  const item = planItem(subscription);
  if (!item) throw new PlanChangeError("no_subscription");
  const current = personalPlanIdForSubscription(subscription);
  if (!current) throw new PlanChangeError("not_switchable");
  if (current === target) throw new PlanChangeError("same_plan");
  const customerId = typeof subscription.customer === "string" ? subscription.customer : subscription.customer?.id;
  if (!customerId) throw new PlanChangeError("no_subscription");
  const interval: BillingInterval = item.price?.recurring?.interval === "year" ? "year" : "month";
  return {
    customerId,
    subscription,
    itemId: item.id,
    price: await deps.priceFor(target, interval),
    interval,
    direction: planTierRank(target) > planTierRank(current) ? "upgrade" : "downgrade",
    periodEnd: typeof item.current_period_end === "number" ? item.current_period_end : null,
  };
}

function prorationBehavior(direction: Switch["direction"]) {
  return direction === "upgrade" ? ("always_invoice" as const) : ("create_prorations" as const);
}

type PreviewLine = {
  readonly amount: number;
  readonly parent?: {
    readonly subscription_item_details?: { readonly proration?: boolean; readonly subscription_item?: string | null } | null;
  } | null;
  readonly proration?: boolean;
  readonly discount_amounts?: readonly { readonly amount: number }[] | null;
  readonly taxes?: readonly { readonly amount: number; readonly tax_behavior?: string }[] | null;
};

function previewLines(invoice: Stripe.Invoice): readonly PreviewLine[] {
  return (invoice.lines?.data ?? []) as unknown as readonly PreviewLine[];
}

const sumAmounts = (values: readonly { readonly amount: number }[] | null | undefined) =>
  (values ?? []).reduce((total, value) => total + value.amount, 0);

/**
 * What the renewal charges for the plan itself: the plan item's regular
 * (non-proration) line, net of its discounts plus exclusive tax. The preview's
 * total would also spend the customer's balance and pending invoice items,
 * which the immediate upgrade invoice uses up first, and metered usage, which
 * is not part of the plan's price. A preview without the plan line is
 * unavailable rather than safe to quote from its total.
 */
function planRenewalLines(invoice: Stripe.Invoice, itemId: string): readonly PreviewLine[] {
  return previewLines(invoice).filter((line) =>
    line.parent?.subscription_item_details?.subscription_item === itemId &&
    line.parent.subscription_item_details.proration !== true);
}

async function completePlanRenewalLines(
  client: StripeClient,
  invoice: Stripe.Invoice,
  itemId: string,
): Promise<readonly PreviewLine[]> {
  const embedded = planRenewalLines(invoice, itemId);
  if (embedded.length || !invoice.lines?.has_more || !invoice.id) return embedded;

  const found: PreviewLine[] = [];
  let startingAfter: string | undefined;
  for (;;) {
    const listed = await client.invoices.listLineItems(invoice.id, {
      limit: 100,
      ...(startingAfter ? { starting_after: startingAfter } : {}),
    });
    found.push(...planRenewalLines({ ...invoice, lines: listed } as Stripe.Invoice, itemId));
    if (found.length || !listed.has_more) return found;
    const nextStartingAfter = listed.data.at(-1)?.id;
    if (!nextStartingAfter || nextStartingAfter === startingAfter) return found;
    startingAfter = nextStartingAfter;
  }
}

async function planRenewalAmount(
  client: StripeClient,
  invoice: Stripe.Invoice,
  itemId: string,
): Promise<number> {
  let lines: readonly PreviewLine[];
  try {
    lines = await completePlanRenewalLines(client, invoice, itemId);
  } catch {
    throw new PlanChangeError("preview_unavailable");
  }
  if (lines.length === 0) throw new PlanChangeError("preview_unavailable");
  return lines.reduce((total, line) =>
    total + line.amount - sumAmounts(line.discount_amounts) +
    sumAmounts(line.taxes?.filter((tax) => tax.tax_behavior === "exclusive")), 0);
}

/**
 * The credit a downgrade leaves: the unused time on the old plan minus the
 * remaining time charged on the new one (both are proration lines).
 */
function prorationCredit(invoice: Stripe.Invoice): number {
  const net = previewLines(invoice)
    .filter((line) => (line.parent?.subscription_item_details?.proration ?? line.proration) === true)
    .reduce((total, line) => total + line.amount, 0);
  return Math.max(0, -net);
}

export async function previewPersonalPlanChange(
  input: { readonly userId: string; readonly target: SwitchTargetPlan },
  deps: PlanChangeDependencies = defaultDependencies,
): Promise<PlanChangePreview> {
  const change = await resolveSwitch(input.userId, input.target, deps);
  const prorationDate = deps.now();
  const client = deps.stripe();
  const items = [{ id: change.itemId, price: change.price }];
  const upgrade = change.direction === "upgrade";
  // An upgrade invoices its proration now, so the next renewal is a separate
  // invoice: preview it on the new price with no proration and read the plan
  // line from it. A downgrade's prorations land on that renewal, so its one
  // preview is already the renewal.
  const [invoice, renewal] = await Promise.all([
    client.invoices.createPreview({
      customer: change.customerId,
      subscription: change.subscription.id,
      subscription_details: {
        items,
        proration_behavior: prorationBehavior(change.direction),
        proration_date: prorationDate,
      },
    }),
    upgrade
      ? client.invoices.createPreview({
          customer: change.customerId,
          subscription: change.subscription.id,
          subscription_details: { items, proration_behavior: "none" },
        })
      : null,
  ]);
  return {
    plan: input.target,
    direction: change.direction,
    currency: invoice.currency,
    amountDueToday: upgrade ? invoice.amount_due : 0,
    credit: upgrade ? 0 : prorationCredit(invoice),
    // The interval is kept, so the billing period (and its end) is unchanged.
    nextRenewalAt: change.periodEnd === null ? null : new Date(change.periodEnd * 1000).toISOString(),
    nextInvoiceAmount: renewal ? await planRenewalAmount(client, renewal, change.itemId) : invoice.amount_due,
    interval: change.interval,
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
