// In-app switch between paid personal plans (Go, Pro, Max). The switch keeps
// the subscription's billing interval (Pro yearly becomes Max yearly), so the
// billing period and its renewal date do not move. An upgrade takes effect
// now and charges the prorated difference now; a downgrade takes effect now
// and credits the unused time to later invoices. The preview and the change
// use the same proration date, so the amount shown is the amount charged.

import type Stripe from "stripe";
import { MAX_PRICING_USD, PRO_PRICING_USD, type BillingInterval } from "./plans";
import { captureBillingError } from "../errors";
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

/** The subscription a switch to `target` changes, or the refusal from the stored status. */
function switchableSubscriptionId(status: StripeBillingStatus, target: SwitchTargetPlan): string {
  const active = ["active", "trialing"].includes(status.subscriptionStatus ?? "");
  if (!status.hasRecurringSubscription || !status.subscriptionId || !active) {
    throw new PlanChangeError("no_subscription");
  }
  if (status.cancelAtPeriodEnd) throw new PlanChangeError("cancel_scheduled");
  if (status.activePlanId === target) throw new PlanChangeError("same_plan");
  // Founder's Edition already includes Pro for life; a founder leaves Max by
  // cancelling it, never by paying for Pro.
  if (status.hasFoundersEdition === true && target === "pro") throw new PlanChangeError("not_switchable");
  return status.subscriptionId;
}

async function resolveSwitch(
  userId: string,
  target: SwitchTargetPlan,
  deps: PlanChangeDependencies,
): Promise<Switch> {
  const subscriptionId = switchableSubscriptionId(await deps.billingStatus(userId), target);
  const subscription = await deps.stripe().subscriptions.retrieve(subscriptionId);
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
 * is not part of the plan's price.
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

/**
 * The catalog price the switch moves the subscription to. It quotes the
 * renewal when Stripe's renewal preview cannot: that figure is display-only,
 * and a payable upgrade must not fail on it. It is the list price, before any
 * coupon or tax, so the fallback is reported.
 */
function catalogRenewalAmount(target: SwitchTargetPlan, interval: BillingInterval): number {
  return (target === "max" ? MAX_PRICING_USD : PRO_PRICING_USD)[interval].billedAmount * 100;
}

async function planRenewalAmount(
  client: StripeClient,
  renewal: Promise<Stripe.Invoice>,
  change: Pick<Switch, "itemId" | "interval">,
  target: SwitchTargetPlan,
): Promise<number> {
  try {
    const lines = await completePlanRenewalLines(client, await renewal, change.itemId);
    if (lines.length > 0) {
      return lines.reduce((total, line) =>
        total + line.amount - sumAmounts(line.discount_amounts) +
        sumAmounts(line.taxes?.filter((tax) => tax.tax_behavior === "exclusive")), 0);
    }
  } catch (error) {
    captureBillingError(error, { operation: "plan_change_renewal_preview", targetPlan: target });
    return catalogRenewalAmount(target, change.interval);
  }
  captureBillingError(new Error("Stripe renewal preview has no plan line"), {
    operation: "plan_change_renewal_preview",
    targetPlan: target,
  });
  return catalogRenewalAmount(target, change.interval);
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
  const renewal = upgrade
    ? client.invoices.createPreview({
        customer: change.customerId,
        subscription: change.subscription.id,
        subscription_details: { items, proration_behavior: "none" },
      })
    : null;
  // Only the renewal quote may fail without failing the preview.
  renewal?.catch(() => undefined);
  const invoice = await client.invoices.createPreview({
    customer: change.customerId,
    subscription: change.subscription.id,
    subscription_details: {
      items,
      proration_behavior: prorationBehavior(change.direction),
      proration_date: prorationDate,
    },
  });
  return {
    plan: input.target,
    direction: change.direction,
    currency: invoice.currency,
    amountDueToday: upgrade ? invoice.amount_due : 0,
    credit: upgrade ? 0 : prorationCredit(invoice),
    // The interval is kept, so the billing period (and its end) is unchanged.
    nextRenewalAt: change.periodEnd === null ? null : new Date(change.periodEnd * 1000).toISOString(),
    nextInvoiceAmount: renewal ? await planRenewalAmount(client, renewal, change, input.target) : invoice.amount_due,
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
