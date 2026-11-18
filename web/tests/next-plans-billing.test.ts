import { afterEach, describe, expect, test } from "bun:test";

import {
  nextPlanCheckoutAvailability,
  nextPlanIdForSubscription,
  nextPlanIdFromMetadata,
} from "../services/billing/nextPlans";
import { nextPlanMirrorMetadata } from "../services/billing/nextPlanBilling";
import { NextPlanUnavailableError, resolveNextPlanPrice } from "../services/billing/stripe";

function subscription(price: { id: string; lookup_key?: string | null }, plan?: string) {
  const metadata: Record<string, string> = plan ? { plan } : {};
  return { items: { data: [{ price }] }, metadata };
}

afterEach(() => {
  delete process.env.STRIPE_PRICE_NEXT_PRO_MONTHLY;
  delete process.env.STRIPE_PRICE_NEXT_MAX_MONTHLY;
});

describe("cmux NEXT subscription plans", () => {
  test("the configured Price id names the plan, even against stale metadata", () => {
    const env = { STRIPE_PRICE_NEXT_PRO_MONTHLY: "price_np", STRIPE_PRICE_NEXT_MAX_MONTHLY: " price_nm " };
    expect(nextPlanIdForSubscription(subscription({ id: "price_np" }, "next_max"), null, env)).toBe("next_pro");
    expect(nextPlanIdForSubscription(subscription({ id: "price_nm", lookup_key: "anything" }), null, env)).toBe("next_max");
  });

  test("a cmux-next lookup key, then checkout metadata, are the fallbacks", () => {
    expect(nextPlanIdForSubscription(subscription({ id: "p", lookup_key: "cmux-next-max-monthly-200" }), null, {})).toBe("next_max");
    expect(nextPlanIdForSubscription(subscription({ id: "p", lookup_key: "cmux-next-pro-monthly-50" }), null, {})).toBe("next_pro");
    expect(nextPlanIdForSubscription(subscription({ id: "p" }), { plan: "next_pro" }, {})).toBe("next_pro");
  });

  test("classic subscriptions are never NEXT plans", () => {
    expect(nextPlanIdForSubscription(subscription({ id: "p", lookup_key: "cmux-pro-monthly-50" }, "next_pro"), null, {})).toBeNull();
    expect(nextPlanIdForSubscription(subscription({ id: "p", lookup_key: "cmux-max-monthly-200" }), null, {})).toBeNull();
    expect(nextPlanIdForSubscription(subscription({ id: "p" }, "pro"), null, {})).toBeNull();
    expect(nextPlanIdForSubscription(subscription({ id: "p" }, "max"), null, {})).toBeNull();
  });

  test("checkout availability follows the two Price env vars", () => {
    expect(nextPlanCheckoutAvailability({})).toEqual({ next_pro: false, next_max: false });
    expect(nextPlanCheckoutAvailability({ STRIPE_PRICE_NEXT_PRO_MONTHLY: "price_np", STRIPE_PRICE_NEXT_MAX_MONTHLY: "  " }))
      .toEqual({ next_pro: true, next_max: false });
  });

  test("an unset Price makes the plan unavailable without calling the payment provider", async () => {
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
    expect(nextPlanIdFromMetadata(null)).toBeNull();
  });
});
