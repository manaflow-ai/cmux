import { NEXT_PLAN_OFFERS, nextPlanRank, type NextPlanId, type NextPlanOffer } from "@/services/billing/nextPlans";
import type { NextCloudBillingJson } from "@/services/billing/dashboardBilling";

/**
 * Pure rules for the cmux NEXT Cloud section of Plan & billing: one card per
 * NEXT plan, the current one marked, each with one action.
 */
export type NextPlanCardAction =
  | { readonly kind: "current" }
  /** Checkout for a first NEXT plan, or an upgrade to a higher one. */
  | { readonly kind: "checkout"; readonly label: "subscribe" | "upgrade" }
  /** Its Price is not configured yet. */
  | { readonly kind: "comingSoon" }
  /** Below the current plan: nothing to buy. */
  | { readonly kind: "included" };

export type NextPlanCard = {
  readonly offer: NextPlanOffer;
  readonly current: boolean;
  readonly action: NextPlanCardAction;
};

export function nextPlanCards(next: NextCloudBillingJson): readonly NextPlanCard[] {
  return NEXT_PLAN_OFFERS.map((offer) => ({
    offer,
    current: offer.id === next.planId,
    action: nextPlanCardAction(offer.id, next),
  }));
}

function nextPlanCardAction(plan: NextPlanId, next: NextCloudBillingJson): NextPlanCardAction {
  if (plan === next.planId) return { kind: "current" };
  if (next.planId !== null && nextPlanRank(plan) < nextPlanRank(next.planId)) return { kind: "included" };
  if (!next.checkoutAvailable[plan]) return { kind: "comingSoon" };
  return { kind: "checkout", label: next.planId === null ? "subscribe" : "upgrade" };
}
