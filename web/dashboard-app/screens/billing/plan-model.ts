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
  | { readonly kind: "cancel" }
  | { readonly kind: "resume" }
  | { readonly kind: "unavailable"; readonly reason: "cancelScheduled" | "granted" | "adminOnly" };

export type PlanCard = {
  readonly id: PickerPlanId;
  readonly current: boolean;
  readonly action: PlanCardAction;
};

type Subscription = { readonly cancelAtPeriodEnd: boolean };

function paidPersonalPlan(value: string | null | undefined): "go" | "pro" | "max" | null {
  return value === "go" || value === "pro" || value === "max" ? value : null;
}

/** Actions for the non-current cards, from the state of the current plan. */
function otherAction(
  state: "free" | "active" | "cancelling" | "granted" | "readOnly",
  card: PickerPlanId,
): PlanCardAction {
  switch (state) {
    case "free":
      return card === "free" ? { kind: "current" } : { kind: "checkout", plan: card };
    case "active":
      if (card === "free") return { kind: "cancel" };
      return card === "pro" || card === "max" ? { kind: "switch", plan: card } : { kind: "unavailable", reason: "granted" };
    case "cancelling":
      return { kind: "unavailable", reason: "cancelScheduled" };
    case "granted":
      return { kind: "unavailable", reason: "granted" };
    case "readOnly":
      return { kind: "unavailable", reason: "adminOnly" };
  }
}

function cards(ids: readonly PickerPlanId[], current: PickerPlanId, state: Parameters<typeof otherAction>[0]): PlanCard[] {
  return ids.map((id) => ({
    id,
    current: id === current,
    action: id === current ? (state === "cancelling" ? { kind: "resume" } : { kind: "current" }) : otherAction(state, id),
  }));
}

/**
 * Personal plans. Go shows only to a Free account with the Go plan enabled,
 * or to a Go subscriber; paid subscribers switch between Pro and Max in place.
 */
export function personalPlanCards(input: {
  readonly planId: string;
  readonly isPro: boolean;
  readonly subscription: (Subscription & { readonly plan: string | null }) | null;
  readonly goPlanEnabled: boolean;
}): PlanCard[] {
  const subscribed = input.subscription ? paidPersonalPlan(input.subscription.plan) ?? paidPersonalPlan(input.planId) : null;
  const current: PickerPlanId = subscribed ?? (input.isPro ? paidPersonalPlan(input.planId) ?? "pro" : "free");
  const showGo = current === "go" || (current === "free" && input.goPlanEnabled);
  const ids: PickerPlanId[] = ["free", ...(showGo ? (["go"] as const) : []), "pro", "max"];
  const state = subscribed
    ? input.subscription!.cancelAtPeriodEnd ? "cancelling" : "active"
    : current === "free" ? "free" : "granted";
  return cards(ids, current, state);
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
