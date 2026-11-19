import { spawnSync } from "node:child_process";

import { afterEach, describe, expect, test } from "bun:test";

import { NEXT_MAX_PRICING_USD, NEXT_PLUS_PRICING_USD, NEXT_PRO_PRICING_USD } from "../services/billing/plans";
import {
  NEXT_PLAN_OFFERS,
  higherNextPlanId,
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
  delete process.env.STRIPE_PRICE_NEXT_PLUS_MONTHLY;
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
    expect(nextPlanIdForSubscription(subscription({ id: "p", lookup_key: "cmux-next-plus-monthly-20" }), null, {})).toBe("next_plus");
    expect(nextPlanIdForSubscription(subscription({ id: "p" }), { plan: "next_plus" }, {})).toBe("next_plus");
  });

  test("classic subscriptions are never NEXT plans", () => {
    expect(nextPlanIdForSubscription(subscription({ id: "p", lookup_key: "cmux-pro-monthly-50" }, "next_pro"), null, {})).toBeNull();
    expect(nextPlanIdForSubscription(subscription({ id: "p", lookup_key: "cmux-max-monthly-200" }), null, {})).toBeNull();
    expect(nextPlanIdForSubscription(subscription({ id: "p" }, "pro"), null, {})).toBeNull();
    expect(nextPlanIdForSubscription(subscription({ id: "p" }, "max"), null, {})).toBeNull();
  });

  test("checkout availability follows the three Price env vars", () => {
    expect(nextPlanCheckoutAvailability({})).toEqual({ next_plus: false, next_pro: false, next_max: false });
    expect(nextPlanCheckoutAvailability({ STRIPE_PRICE_NEXT_PRO_MONTHLY: "price_np", STRIPE_PRICE_NEXT_MAX_MONTHLY: "  " }))
      .toEqual({ next_plus: false, next_pro: true, next_max: false });
    expect(nextPlanCheckoutAvailability({ STRIPE_PRICE_NEXT_PLUS_MONTHLY: "price_npl" }))
      .toEqual({ next_plus: true, next_pro: false, next_max: false });
  });

  test("ranks Plus below Pro below Max", () => {
    expect(higherNextPlanId("next_plus", "next_pro")).toBe("next_pro");
    expect(higherNextPlanId("next_max", "next_plus")).toBe("next_max");
    expect(higherNextPlanId(null, "next_plus")).toBe("next_plus");
    expect(higherNextPlanId("next_plus", null)).toBe("next_plus");
    expect(nextPlanIdFromMetadata({ cmuxNextVmPlan: "next_plus", cmuxNextPlan: "next_pro" })).toBe("next_pro");
  });

  test("the plans sold match the tiers: Plus $20, Pro $50, Max $200", () => {
    expect(NEXT_PLAN_OFFERS.map((o) => [o.id, o.priceUsdPerMonth, o.maxRunningMachines, o.largestMachine.vcpus, o.largestMachine.memoryGib, o.maxDiskGib, o.includedMachineMinutes])).toEqual([
      ["next_plus", 20, 8, 4, 16, 64, 30_000],
      ["next_pro", 50, 32, 8, 32, 128, 75_000],
      ["next_max", 200, 64, 32, 64, 256, 300_000],
    ]);
    expect([NEXT_PLUS_PRICING_USD, NEXT_PRO_PRICING_USD, NEXT_MAX_PRICING_USD].map((p) => [p.month.billedAmount, p.month.lookupKey])).toEqual([
      [20, "cmux-next-plus-monthly-20"],
      [50, "cmux-next-pro-monthly-50"],
      [200, "cmux-next-max-monthly-200"],
    ]);
  });

  test("the Stripe provisioning script sells the same amounts, lookup keys and limits", () => {
    const out = spawnSync("bash", ["scripts/stripe/provision-next-plans.sh", "test"], {
      env: { ...process.env, CMUX_NEXT_PLANS_PRINT: "1" },
      encoding: "utf8",
    });
    expect(out.status).toBe(0);
    const rows: string[][] = out.stdout.trim().split("\n").map((line: string) => line.split("|"));
    expect(rows.map(([plan, , cents, lookup]) => [plan, Number(cents) / 100, lookup])).toEqual(
      [NEXT_PLUS_PRICING_USD, NEXT_PRO_PRICING_USD, NEXT_MAX_PRICING_USD].map((p, i) => [NEXT_PLAN_OFFERS[i]!.id, p.month.billedAmount, p.month.lookupKey]),
    );
    for (const [i, row] of rows.entries()) {
      const offer = NEXT_PLAN_OFFERS[i]!;
      expect(row[4]).toContain(`Up to ${offer.maxRunningMachines} Cloud machines running at once`);
      expect(row[4]).toContain(`${offer.largestMachine.vcpus} vCPU and ${offer.largestMachine.memoryGib} GB RAM with a ${offer.maxDiskGib} GB disk`);
      expect(row[4]).toContain(`${offer.includedMachineMinutes.toLocaleString("en-US")} machine minutes included each month`);
    }
  });

  test("a live write needs the explicit confirmation", () => {
    const out = spawnSync("bash", ["scripts/stripe/provision-next-plans.sh", "live", "--apply"], {
      env: { ...process.env, CMUX_STRIPE_LIVE_CONFIRM: "" },
      encoding: "utf8",
    });
    expect(out.status).toBe(1);
    expect(out.stderr).toContain("CMUX_STRIPE_LIVE_CONFIRM=next-plans");
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
