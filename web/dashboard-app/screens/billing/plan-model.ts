import { GO_PRICING_USD, MAX_PRICING_USD, PRO_PRICING_USD, TEAM_PRICING_USD } from "@/services/billing/plans";
import { formatUsd, type SubscriptionPrice } from "@/services/billing/subscriptionPrice";

/**
 * Pure rules for the plan picker: which plans show, which one is current,
 * and the single action each card carries. The components render this.
 */

export type PickerPlanId = "free" | "go" | "pro" | "max" | "team";
export type CheckoutPlanId = "go" | "pro" | "max" | "team";
export type SwitchPlanId = "pro" | "max";

export type PlanCardAction =
  | { readonly kind: "current" }
  | { readonly kind: "checkout"; readonly plan: CheckoutPlanId }
  | { readonly kind: "switch"; readonly plan: SwitchPlanId }
  /** Cancel at period end; `keepsPro` when Founder's Edition keeps Pro after it. */
  | { readonly kind: "cancel"; readonly keepsPro?: boolean }
  | { readonly kind: "resume" }
  | {
      readonly kind: "unavailable";
      readonly reason: "cancelScheduled" | "granted" | "grantedNoCancel" | "paymentFailed" | "foundersLifetime" | "adminOnly";
    };

export type PlanCard = {
  readonly id: PickerPlanId;
  readonly current: boolean;
  readonly action: PlanCardAction;
};

type Subscription = { readonly cancelAtPeriodEnd: boolean };
/** `founders`: Founder's Edition (Pro for life) with no subscription on top. */
type PickerState = "free" | "active" | "pastDue" | "cancelling" | "granted" | "founders" | "readOnly";

function paidPersonalPlan(value: string | null | undefined): "go" | "pro" | "max" | null {
  return value === "go" || value === "pro" || value === "max" ? value : null;
}

/** Actions for the non-current cards, from the state of the current plan. */
function otherAction(state: PickerState, card: PickerPlanId, current: PickerPlanId): PlanCardAction {
  switch (state) {
    case "free":
      return card === "free" ? { kind: "current" } : { kind: "checkout", plan: card };
    case "active":
      if (card === "free") return { kind: "cancel" };
      return card === "pro" || card === "max" ? { kind: "switch", plan: card } : { kind: "unavailable", reason: "granted" };
    case "pastDue":
      // A switch needs a paid-up subscription; the payment is fixed first.
      // Cancelling stays available.
      return card === "free" ? { kind: "cancel" } : { kind: "unavailable", reason: "paymentFailed" };
    case "cancelling":
      return { kind: "unavailable", reason: "cancelScheduled" };
    case "granted":
      return grantedAction(card, current);
    case "founders":
      return card === "max" ? { kind: "checkout", plan: "max" } : { kind: "unavailable", reason: "foundersLifetime" };
    case "readOnly":
      return { kind: "unavailable", reason: "adminOnly" };
  }
}

/**
 * A grant has no subscription to switch or cancel, but a granted personal
 * plan below Max can still buy Max: checkout starts a new subscription.
 */
function grantedAction(card: PickerPlanId, current: PickerPlanId): PlanCardAction {
  if (card === "max" && (current === "go" || current === "pro")) return { kind: "checkout", plan: "max" };
  if (card === "free" && current !== "max" && current !== "team") return { kind: "unavailable", reason: "grantedNoCancel" };
  return { kind: "unavailable", reason: "granted" };
}

/**
 * Founder's Edition already includes Pro for life. A founder with a
 * subscription on top returns to Pro by ending that subscription, never by
 * switching it onto a paid Pro price, and has nothing to cancel below Pro.
 */
function foundersSubscriptionAction(state: PickerState, card: PickerPlanId, current: PickerPlanId): PlanCardAction | null {
  if (state !== "active" && state !== "pastDue") return null;
  if (card === "pro") return { kind: "cancel", keepsPro: true };
  if (card !== "free") return null;
  return current === "pro" ? { kind: "cancel", keepsPro: true } : { kind: "unavailable", reason: "foundersLifetime" };
}

function cards(ids: readonly PickerPlanId[], current: PickerPlanId, state: PickerState, founders = false): PlanCard[] {
  return ids.map((id) => ({
    id,
    current: id === current,
    action: id === current
      ? (state === "cancelling" ? { kind: "resume" } : { kind: "current" })
      : (founders ? foundersSubscriptionAction(state, id, current) : null) ?? otherAction(state, id, current),
  }));
}

/**
 * Personal plans. Go shows only to a Free account with the Go plan enabled,
 * or to a Go subscriber; paid subscribers switch between Pro and Max in place.
 */
export function personalPlanCards(input: {
  readonly planId: string;
  readonly isPro: boolean;
  readonly subscription: (Subscription & { readonly plan: string | null; readonly status?: string }) | null;
  /** The account owns Founder's Edition (Pro for life, not a subscription). */
  readonly foundersEdition?: boolean;
  readonly goPlanEnabled: boolean;
}): PlanCard[] {
  const subscribed = input.subscription ? paidPersonalPlan(input.subscription.plan) ?? paidPersonalPlan(input.planId) : null;
  const current: PickerPlanId = subscribed ?? (input.isPro ? paidPersonalPlan(input.planId) ?? "pro" : "free");
  const showGo = current === "go" || (current === "free" && input.goPlanEnabled);
  const ids: PickerPlanId[] = ["free", ...(showGo ? (["go"] as const) : []), "pro", "max"];
  const founders = input.foundersEdition === true;
  const state = personalState(input.subscription, subscribed !== null, current);
  return cards(ids, current, founders && state === "granted" && current === "pro" ? "founders" : state, founders);
}

function personalState(
  subscription: (Subscription & { readonly status?: string }) | null,
  subscribed: boolean,
  current: PickerPlanId,
): PickerState {
  if (!subscribed) return current === "free" ? "free" : "granted";
  if (subscription!.cancelAtPeriodEnd) return "cancelling";
  // Only an active or trialing subscription can switch; any other status
  // (past_due) has a payment to fix first. An older client without a status
  // keeps the switch.
  const status = subscription!.status;
  return status === undefined || status === "active" || status === "trialing" ? "active" : "pastDue";
}

/** A team's plans: Free and Team. Only team admins change them. */
export function teamPlanCards(input: {
  readonly canManageBilling: boolean;
  readonly granted: boolean;
  readonly subscription: Subscription | null;
}): PlanCard[] {
  const current: PickerPlanId = input.subscription || input.granted ? "team" : "free";
  const state = !input.canManageBilling
    ? "readOnly"
    : input.subscription
      ? input.subscription.cancelAtPeriodEnd ? "cancelling" : "active"
      : input.granted ? "granted" : "free";
  return cards(["free", "team"], current, state);
}

/**
 * The reason every non-current card shares, when they all have one, so the
 * picker says it once under the cards instead of on each card.
 */
export function sharedUnavailableReason(cards: readonly PlanCard[]): Extract<PlanCardAction, { kind: "unavailable" }>["reason"] | null {
  const others = cards.filter((card) => !card.current);
  const reasons = new Set(others.map((card) => (card.action.kind === "unavailable" ? card.action.reason : null)));
  const [only] = [...reasons];
  return reasons.size === 1 && only ? only : null;
}

const LIST_MONTHLY_USD: Readonly<Record<PickerPlanId, number>> = {
  free: 0,
  go: GO_PRICING_USD.month.billedAmount,
  pro: PRO_PRICING_USD.month.billedAmount,
  max: MAX_PRICING_USD.month.billedAmount,
  team: TEAM_PRICING_USD.month.billedAmount,
};

export type PlanCardPrice = {
  readonly amount: string;
  readonly unit: "perMonth" | "perSeatMonth";
  readonly annual: boolean;
};

/**
 * One price shape for every card: the list price, or for the current card
 * the subscription's own Stripe price (grandfathered or annual), shown per
 * month. Null when the current plan has no price to show (granted).
 * `currentPrice` undefined means "use the list price".
 */
export function planCardPrice(
  id: PickerPlanId,
  current: boolean,
  currentPrice: SubscriptionPrice | null | undefined,
): PlanCardPrice | null {
  const unit = id === "team" ? "perSeatMonth" : "perMonth";
  if (!current || currentPrice === undefined) return { amount: `$${formatUsd(LIST_MONTHLY_USD[id])}`, unit, annual: false };
  if (currentPrice === null) return null;
  const annual = currentPrice.interval === "year";
  return { amount: `$${formatUsd(annual ? currentPrice.amountUsd / 12 : currentPrice.amountUsd)}`, unit, annual };
}

