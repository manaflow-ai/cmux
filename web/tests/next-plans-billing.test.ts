import { afterEach, describe, expect, test } from "bun:test";

import {
  NEXT_PLAN_IDS,
  NEXT_PLAN_OFFERS,
  higherNextPlanId,
  nextPlanCheckoutAvailability,
  nextPlanIdForSubscription,
  nextPlanIdFromMetadata,
  nextPlanPriceId,
} from "../services/billing/nextPlans";
import { nextPlanCards } from "../dashboard-app/screens/billing/next-plan-model";
import { nextPlanMirrorMetadata } from "../services/billing/nextPlanBilling";
import { NextPlanUnavailableError, resolveNextPlanPrice } from "../services/billing/stripe";

function subscription(price: { id: string; lookup_key?: string | null }, plan?: string) {
  const metadata: Record<string, string> = plan ? { plan } : {};
  return { items: { data: [{ price }] }, metadata };
}

afterEach(() => {
  delete process.env.STRIPE_PRICE_NEXT_PLUS_MONTHLY;
  delete process.env.STRIPE_PRICE_NEXT_PRO_MONTHLY;
  delete process.env.STRIPE_PRICE_NEXT_MAX_MONTHLY;
});

describe("cmux NEXT subscription plans", () => {
  test("the configured Price id names the plan, even against stale metadata", () => {
    const env = { STRIPE_PRICE_NEXT_PRO_MONTHLY: "price_np", STRIPE_PRICE_NEXT_MAX_MONTHLY: " price_nm " };
    expect(nextPlanIdForSubscription(subscription({ id: "price_np" }, "next_max"), null, env)).toBe("next_pro");
    expect(nextPlanIdForSubscription(subscription({ id: "price_nm", lookup_key: "anything" }), null, env)).toBe("next_max");
    const plus = { ...env, STRIPE_PRICE_NEXT_PLUS_MONTHLY: "price_nplus" };
    expect(nextPlanIdForSubscription(subscription({ id: "price_nplus" }, "next_pro"), null, plus)).toBe("next_plus");
    // Without its variable the same Price is not NEXT Plus: only stale metadata is left to name a plan.
    expect(nextPlanIdForSubscription(subscription({ id: "price_nplus", lookup_key: "other" }), null, env)).toBeNull();
  });

  test("a Price id two NEXT variables share names no plan: a miscopied Plus id never relabels a Pro subscriber", () => {
    const env = { STRIPE_PRICE_NEXT_PLUS_MONTHLY: "price_np", STRIPE_PRICE_NEXT_PRO_MONTHLY: "price_np", STRIPE_PRICE_NEXT_MAX_MONTHLY: "price_nm" };
    // The shared id decides nothing; the lookup key, then the metadata, still name the plan.
    expect(nextPlanIdForSubscription(subscription({ id: "price_np", lookup_key: "cmux-next-pro-monthly" }), null, env)).toBe("next_pro");
    expect(nextPlanIdForSubscription(subscription({ id: "price_np" }, "next_pro"), null, env)).toBe("next_pro");
    expect(nextPlanIdForSubscription(subscription({ id: "price_np" }), null, env)).toBeNull();
    // An id only one variable holds is as authoritative as before.
    expect(nextPlanIdForSubscription(subscription({ id: "price_nm" }, "next_plus"), null, env)).toBe("next_max");
  });

  test("NEXT Plus is the lowest plan: $20 with 30,000 machine minutes, 1,500 per dollar like the others", () => {
    expect(NEXT_PLAN_IDS).toEqual(["next_plus", "next_pro", "next_max"]);
    expect(NEXT_PLAN_OFFERS.map((offer) => offer.id)).toEqual([...NEXT_PLAN_IDS]);
    expect(NEXT_PLAN_OFFERS[0]).toEqual({
      id: "next_plus",
      priceUsdPerMonth: 20,
      includedMachineMinutes: 30_000,
      includedUsageUsd: 37,
      maxRunningMachines: 8,
      maxKeptMachines: 20,
      maxSnapshots: 20,
      largestMachine: { vcpus: 4, memoryGib: 16 },
      maxDiskGib: 64,
    });
    for (const offer of NEXT_PLAN_OFFERS) expect(offer.includedMachineMinutes / offer.priceUsdPerMonth).toBe(1_500);
    expect(higherNextPlanId("next_plus", null)).toBe("next_plus");
    expect(higherNextPlanId("next_plus", "next_pro")).toBe("next_pro");
    expect(higherNextPlanId("next_max", "next_plus")).toBe("next_max");
    expect(higherNextPlanId("next_pro", "next_max")).toBe("next_max");
    expect(higherNextPlanId(null, null)).toBeNull();
  });

  test("the price id of NEXT Plus comes only from its variable", () => {
    expect(nextPlanPriceId("next_plus", {})).toBeNull();
    expect(nextPlanPriceId("next_plus", { STRIPE_PRICE_NEXT_PRO_MONTHLY: "price_np" })).toBeNull();
    expect(nextPlanPriceId("next_plus", { STRIPE_PRICE_NEXT_PLUS_MONTHLY: "  " })).toBeNull();
    expect(nextPlanPriceId("next_plus", { STRIPE_PRICE_NEXT_PLUS_MONTHLY: " price_nplus " })).toBe("price_nplus");
  });

  test("the dashboard cards: a lower plan is included, a higher one is an upgrade, an unset Price is Coming soon", () => {
    const all = { next_plus: true, next_pro: true, next_max: true };
    const actions = (planId: "next_plus" | "next_pro" | "next_max" | null, checkoutAvailable = all) =>
      nextPlanCards({ planId, source: planId ? "subscription" : null, checkoutAvailable }).map((card) => card.action);
    expect(actions(null)).toEqual([
      { kind: "checkout", label: "subscribe" },
      { kind: "checkout", label: "subscribe" },
      { kind: "checkout", label: "subscribe" },
    ]);
    expect(actions(null, { ...all, next_plus: false })[0]).toEqual({ kind: "comingSoon" });
    expect(actions("next_plus")).toEqual([
      { kind: "current" },
      { kind: "checkout", label: "upgrade" },
      { kind: "checkout", label: "upgrade" },
    ]);
    expect(actions("next_pro")).toEqual([{ kind: "included" }, { kind: "current" }, { kind: "checkout", label: "upgrade" }]);
    expect(actions("next_max")).toEqual([{ kind: "included" }, { kind: "included" }, { kind: "current" }]);
  });

  test("a cmux-next lookup key, then checkout metadata, are the fallbacks", () => {
    expect(nextPlanIdForSubscription(subscription({ id: "p", lookup_key: "cmux-next-max-monthly-200" }), null, {})).toBe("next_max");
    expect(nextPlanIdForSubscription(subscription({ id: "p", lookup_key: "cmux-next-pro-monthly-50" }), null, {})).toBe("next_pro");
    expect(nextPlanIdForSubscription(subscription({ id: "p" }), { plan: "next_pro" }, {})).toBe("next_pro");
    expect(nextPlanIdForSubscription(subscription({ id: "p", lookup_key: "cmux-next-plus-monthly-20" }), null, {})).toBe("next_plus");
    expect(nextPlanIdForSubscription(subscription({ id: "p" }), { plan: "next_plus" }, {})).toBe("next_plus");
  });

  test("classic subscriptions are never NEXT plans", () => {
    expect(nextPlanIdForSubscription(subscription({ id: "p", lookup_key: "cmux-pro-monthly-50" }, "next_pro"), null, {})).toBeNull();
    expect(nextPlanIdForSubscription(subscription({ id: "p", lookup_key: "cmux-max-monthly-200" }), null, {})).toBeNull();
    expect(nextPlanIdForSubscription(subscription({ id: "p" }, "pro"), null, {})).toBeNull();
    expect(nextPlanIdForSubscription(subscription({ id: "p" }, "max"), null, {})).toBeNull();
  });

  test("checkout availability follows each plan's Price env var", () => {
    expect(nextPlanCheckoutAvailability({})).toEqual({ next_plus: false, next_pro: false, next_max: false });
    expect(nextPlanCheckoutAvailability({ STRIPE_PRICE_NEXT_PRO_MONTHLY: "price_np", STRIPE_PRICE_NEXT_MAX_MONTHLY: "  " }))
      .toEqual({ next_plus: false, next_pro: true, next_max: false });
    expect(nextPlanCheckoutAvailability({ STRIPE_PRICE_NEXT_PLUS_MONTHLY: "price_nplus" }))
      .toEqual({ next_plus: true, next_pro: false, next_max: false });
  });

  test("an unset Price makes the plan unavailable without calling the payment provider", async () => {
    await expect(resolveNextPlanPrice("next_plus")).rejects.toBeInstanceOf(NextPlanUnavailableError);
    await expect(resolveNextPlanPrice("next_plus")).rejects.toThrow("STRIPE_PRICE_NEXT_PLUS_MONTHLY is unset");
    await expect(resolveNextPlanPrice("next_pro")).rejects.toBeInstanceOf(NextPlanUnavailableError);
    await expect(resolveNextPlanPrice("next_max")).rejects.toThrow("STRIPE_PRICE_NEXT_MAX_MONTHLY is unset");
  });
});

describe("cmux NEXT metadata mirror", () => {
  test("names the NEXT plan in cmuxPlan unless a classic plan holds it", () => {
    expect(nextPlanMirrorMetadata({}, "next_pro")).toEqual({ cmuxNextPlan: "next_pro", cmuxPlan: "next_pro" });
    expect(nextPlanMirrorMetadata({ cmuxPlan: "max" }, "next_pro")).toEqual({ cmuxPlan: "max", cmuxNextPlan: "next_pro" });
    expect(nextPlanMirrorMetadata({ cmuxPlan: "next_pro", cmuxNextPlan: "next_pro" }, "next_max"))
      .toEqual({ cmuxPlan: "next_max", cmuxNextPlan: "next_max" });
    expect(nextPlanMirrorMetadata({ cmuxPlan: "next_pro", cmuxNextPlan: "next_pro" }, "next_pro")).toBeNull();
  });

  test("a lapse clears only NEXT values and leaves classic plans and grants alone", () => {
    expect(nextPlanMirrorMetadata({ cmuxPlan: "next_max", cmuxNextPlan: "next_max", cmuxVmPlan: "next_pro" }, null))
      .toEqual({ cmuxVmPlan: "next_pro" });
    expect(nextPlanMirrorMetadata({ cmuxPlan: "pro", cmuxNextPlan: "next_pro" }, null)).toEqual({ cmuxPlan: "pro" });
    expect(nextPlanMirrorMetadata({ cmuxPlan: "pro" }, null)).toBeNull();
    expect(nextPlanMirrorMetadata({ cmuxAccountDeleting: true }, "next_pro")).toBeNull();
  });

  test("the NEXT plan in force: a lower grant never hides a higher purchase", () => {
    expect(nextPlanIdFromMetadata({ cmuxVmPlan: "next_pro", cmuxPlan: "pro", cmuxNextPlan: "next_max" })).toBe("next_max");
    expect(nextPlanIdFromMetadata({ cmuxVmPlan: "next_max", cmuxPlan: "next_pro" })).toBe("next_max");
    expect(nextPlanIdFromMetadata({ cmuxVmPlan: "pro", cmuxPlan: "max" })).toBeNull();
    expect(nextPlanIdFromMetadata({ cmuxNextVmPlan: "next_plus", cmuxNextPlan: "next_pro" })).toBe("next_pro");
    expect(nextPlanIdFromMetadata({ cmuxNextVmPlan: "next_pro", cmuxNextPlan: "next_plus" })).toBe("next_pro");
    expect(nextPlanIdFromMetadata({ cmuxNextPlan: "next_plus", cmuxPlan: "pro" })).toBe("next_plus");
    expect(nextPlanIdFromMetadata(null)).toBeNull();
  });
});
