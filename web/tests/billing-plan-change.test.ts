import { beforeEach, describe, expect, test } from "bun:test";
import {
  applyPersonalPlanChange,
  PlanChangeError,
  type PlanChangeDependencies,
  previewPersonalPlanChange,
} from "../services/billing/planChange";

const NOW = 1_790_000_000;
const PERIOD_END = NOW + 20 * 86_400;

type Status = Awaited<ReturnType<PlanChangeDependencies["billingStatus"]>>;
let status: Status;
let subscription: Record<string, unknown>;
let preview: Record<string, unknown>;
let updateError: unknown;
const calls: { method: string; args: unknown[] }[] = [];
const synced: unknown[] = [];

function subscriptionOn(lookupKey: string, cancelAtPeriodEnd = false) {
  return {
    id: "sub_1",
    customer: "cus_1",
    cancel_at_period_end: cancelAtPeriodEnd,
    metadata: { app: "cmux", plan: lookupKey.includes("max") ? "max" : "pro" },
    items: { data: [{ id: "si_1", current_period_end: PERIOD_END, price: { id: "price_old", lookup_key: lookupKey } }] },
  };
}

const deps: PlanChangeDependencies = {
  billingStatus: async () => status,
  priceFor: async (plan) => `price_${plan}`,
  now: () => NOW,
  stripe: () => ({
    subscriptions: {
      retrieve: async (...args: unknown[]) => {
        calls.push({ method: "retrieve", args });
        return subscription;
      },
      update: async (...args: unknown[]) => {
        calls.push({ method: "update", args });
        if (updateError) throw updateError;
        return { ...subscription, updated: true };
      },
    },
    invoices: {
      createPreview: async (...args: unknown[]) => {
        calls.push({ method: "createPreview", args });
        return preview;
      },
    },
  }) as never,
  syncSubscription: async (updated) => {
    synced.push(updated);
  },
};

beforeEach(() => {
  status = {
    customerId: "cus_1",
    subscriptionStatus: "active",
    subscriptionId: "sub_1",
    activePlanId: "pro",
    hasRecurringSubscription: true,
    cancelAtPeriodEnd: false,
    hasCustomer: true,
    hasActiveSubscription: true,
  };
  subscription = subscriptionOn("cmux-pro-monthly-50");
  preview = { currency: "usd", amount_due: 10_000, lines: { data: [] } };
  updateError = null;
  calls.length = 0;
  synced.length = 0;
});

async function refusal(operation: Promise<unknown>) {
  const error = await operation.catch((caught: unknown) => caught);
  expect(error).toBeInstanceOf(PlanChangeError);
  return (error as PlanChangeError).reason;
}

describe("personal plan change", () => {
  test("refuses without an active recurring subscription", async () => {
    status = { ...status, hasRecurringSubscription: false, subscriptionId: null, hasActiveSubscription: false };
    expect(await refusal(previewPersonalPlanChange({ userId: "u1", target: "max" }, deps))).toBe("no_subscription");
  });

  test("refuses while the subscription is scheduled to cancel", async () => {
    status = { ...status, cancelAtPeriodEnd: true };
    expect(await refusal(previewPersonalPlanChange({ userId: "u1", target: "max" }, deps))).toBe("cancel_scheduled");
  });

  test("refuses a switch to the plan already in force", async () => {
    expect(await refusal(previewPersonalPlanChange({ userId: "u1", target: "pro" }, deps))).toBe("same_plan");
  });

  test("an upgrade previews the immediate prorated invoice and passes Stripe's amounts through", async () => {
    preview = { currency: "usd", amount_due: 9_987, lines: { data: [] } };
    const result = await previewPersonalPlanChange({ userId: "u1", target: "max" }, deps);
    expect(result).toEqual({
      plan: "max",
      direction: "upgrade",
      currency: "usd",
      amountDueToday: 9_987,
      credit: 0,
      nextRenewalAt: new Date(PERIOD_END * 1000).toISOString(),
      nextInvoiceAmount: 20_000,
      prorationDate: NOW,
    });
    const previewCall = calls.find((call) => call.method === "createPreview")!;
    expect(previewCall.args[0]).toEqual({
      customer: "cus_1",
      subscription: "sub_1",
      subscription_details: {
        items: [{ id: "si_1", price: "price_max" }],
        proration_behavior: "always_invoice",
        proration_date: NOW,
      },
    });
  });

  test("a downgrade charges nothing today and credits the unused time net of the new plan's remaining time", async () => {
    subscription = subscriptionOn("cmux-max-monthly-200");
    status = { ...status, activePlanId: "max" };
    preview = {
      currency: "usd",
      amount_due: 1_500,
      lines: {
        data: [
          { amount: -13_000, parent: { subscription_item_details: { proration: true } } },
          { amount: 4_000, parent: { subscription_item_details: { proration: true } } },
          { amount: 5_000, parent: { subscription_item_details: { proration: false } } },
        ],
      },
    };
    const result = await previewPersonalPlanChange({ userId: "u1", target: "pro" }, deps);
    // -13,000 unused Max, +4,000 for Pro's remaining time; the plain renewal line is not proration.
    expect(result).toMatchObject({ direction: "downgrade", amountDueToday: 0, credit: 9_000, nextInvoiceAmount: 1_500 });
    const previewCall = calls.find((call) => call.method === "createPreview")!;
    expect((previewCall.args[0] as { subscription_details: { proration_behavior: string } }).subscription_details.proration_behavior)
      .toBe("create_prorations");
  });

  test("applying an upgrade swaps the price with the previewed proration date, then syncs the snapshot", async () => {
    await applyPersonalPlanChange({ userId: "u1", target: "max", prorationDate: NOW - 60 }, deps);
    const update = calls.find((call) => call.method === "update")!;
    expect(update.args).toEqual([
      "sub_1",
      {
        items: [{ id: "si_1", price: "price_max" }],
        proration_behavior: "always_invoice",
        proration_date: NOW - 60,
        payment_behavior: "error_if_incomplete",
        metadata: { app: "cmux", plan: "max" },
      },
    ]);
    expect(synced).toEqual([{ ...subscription, updated: true }]);
  });

  test("a stale or future proration date falls back to now", async () => {
    await applyPersonalPlanChange({ userId: "u1", target: "max", prorationDate: NOW - 7_200 }, deps);
    const update = calls.find((call) => call.method === "update")!;
    expect((update.args[1] as { proration_date: number }).proration_date).toBe(NOW);
  });

  test("a declined card is a payment_failed refusal and nothing syncs", async () => {
    updateError = Object.assign(new Error("Your card was declined."), { type: "StripeCardError" });
    expect(await refusal(applyPersonalPlanChange({ userId: "u1", target: "max", prorationDate: NOW }, deps))).toBe("payment_failed");
    expect(synced).toEqual([]);
  });
});
