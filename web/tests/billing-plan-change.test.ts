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
/** The next renewal invoice at the new price (proration_behavior "none"). */
let renewalPreview: Record<string, unknown>;
let renewalLines: Record<string, unknown>[];
let renewalLinePages: Array<{ data: Record<string, unknown>[]; has_more: boolean }> | null;
let renewalLinesError: unknown;
let renewalPreviewError: unknown;
let updateError: unknown;
const calls: { method: string; args: unknown[] }[] = [];
const synced: unknown[] = [];

function subscriptionOn(lookupKey: string, cancelAtPeriodEnd = false, interval: "month" | "year" = "month") {
  return {
    id: "sub_1",
    customer: "cus_1",
    cancel_at_period_end: cancelAtPeriodEnd,
    metadata: { app: "cmux", plan: lookupKey.includes("max") ? "max" : lookupKey.includes("go") ? "go" : "pro" },
    items: {
      data: [{
        id: "si_1",
        current_period_end: PERIOD_END,
        price: { id: "price_old", lookup_key: lookupKey, recurring: { interval, usage_type: "licensed" } },
      }],
    },
  };
}

const deps: PlanChangeDependencies = {
  billingStatus: async () => status,
  priceFor: async (plan, interval) => `price_${plan}_${interval}`,
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
        const details = (args[0] as { subscription_details?: { proration_behavior?: string } }).subscription_details;
        if (details?.proration_behavior !== "none") return preview;
        if (renewalPreviewError) throw renewalPreviewError;
        return renewalPreview;
      },
      listLineItems: async (...args: unknown[]) => {
        calls.push({ method: "listLineItems", args });
        if (renewalLinesError) throw renewalLinesError;
        if (renewalLinePages) {
          const options = args[1] as { starting_after?: string } | undefined;
          return options?.starting_after === "line_100"
            ? renewalLinePages[1]
            : renewalLinePages[0];
        }
        return { data: renewalLines, has_more: false };
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
  renewalPreview = {
    id: "upcoming_1",
    currency: "usd",
    amount_due: 20_000,
    lines: { data: [{ amount: 20_000, parent: { subscription_item_details: { subscription_item: "si_1", proration: false } } }] },
  };
  renewalLines = [];
  renewalLinePages = null;
  renewalLinesError = null;
  renewalPreviewError = null;
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
      interval: "month",
      prorationDate: NOW,
    });
    const previewCall = calls.find((call) => call.method === "createPreview" && (call.args[0] as { subscription_details: { proration_behavior: string } }).subscription_details.proration_behavior !== "none")!;
    expect(previewCall.args[0]).toEqual({
      customer: "cus_1",
      subscription: "sub_1",
      subscription_details: {
        items: [{ id: "si_1", price: "price_max_month" }],
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
        items: [{ id: "si_1", price: "price_max_month" }],
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
  test("a Pro yearly subscriber upgrades to Max yearly, keeping the billing interval", async () => {
    subscription = subscriptionOn("cmux-pro-yearly-480", false, "year");
    preview = { currency: "usd", amount_due: 79_000, lines: { data: [] } };
    renewalPreview = {
      id: "upcoming_1",
      currency: "usd",
      amount_due: 192_000,
      lines: { data: [{ amount: 192_000, parent: { subscription_item_details: { subscription_item: "si_1", proration: false } } }] },
    };
    const result = await previewPersonalPlanChange({ userId: "u1", target: "max" }, deps);
    expect(result).toMatchObject({
      direction: "upgrade",
      amountDueToday: 79_000,
      // The billing period is unchanged, so the renewal date stays and the
      // renewal charges the Max yearly price, not a monthly one.
      nextRenewalAt: new Date(PERIOD_END * 1000).toISOString(),
      nextInvoiceAmount: 192_000,
      interval: "year",
    });
    const items = calls
      .filter((call) => call.method === "createPreview")
      .map((call) => (call.args[0] as { subscription_details: { items: unknown } }).subscription_details.items);
    expect(items.length).toBeGreaterThan(0);
    for (const item of items) expect(item).toEqual([{ id: "si_1", price: "price_max_year" }]);

    await applyPersonalPlanChange({ userId: "u1", target: "max", prorationDate: NOW }, deps);
    const update = calls.find((call) => call.method === "update")!;
    expect((update.args[1] as { items: unknown }).items).toEqual([{ id: "si_1", price: "price_max_year" }]);
  });

  test("a grandfathered Pro yearly price also upgrades to Max yearly", async () => {
    subscription = subscriptionOn("cmux-pro-yearly", false, "year");
    await previewPersonalPlanChange({ userId: "u1", target: "max" }, deps);
    const previewCall = calls.find((call) => call.method === "createPreview")!;
    expect((previewCall.args[0] as { subscription_details: { items: unknown } }).subscription_details.items)
      .toEqual([{ id: "si_1", price: "price_max_year" }]);
  });

  test("a grandfathered Pro monthly price upgrades to the current Max monthly price", async () => {
    subscription = subscriptionOn("cmux-pro-monthly", false, "month");
    await applyPersonalPlanChange({ userId: "u1", target: "max", prorationDate: NOW }, deps);
    const update = calls.find((call) => call.method === "update")!;
    expect((update.args[1] as { items: unknown }).items).toEqual([{ id: "si_1", price: "price_max_month" }]);
  });

  test("a Max yearly subscriber downgrades to Pro yearly", async () => {
    subscription = subscriptionOn("cmux-max-yearly-1920", false, "year");
    status = { ...status, activePlanId: "max" };
    await applyPersonalPlanChange({ userId: "u1", target: "pro", prorationDate: NOW }, deps);
    const update = calls.find((call) => call.method === "update")!;
    expect((update.args[1] as { items: unknown }).items).toEqual([{ id: "si_1", price: "price_pro_year" }]);
  });

  test("an upgrade's next invoice amount is Stripe's renewal preview, not a list price", async () => {
    // A discount on the subscription lowers the renewal; the preview says so.
    renewalPreview = {
      id: "upcoming_1",
      currency: "usd",
      amount_due: 15_000,
      lines: { data: [{ amount: 15_000, parent: { subscription_item_details: { subscription_item: "si_1", proration: false } } }] },
    };
    const result = await previewPersonalPlanChange({ userId: "u1", target: "max" }, deps);
    expect(result.nextInvoiceAmount).toBe(15_000);
  });

  test("the renewal amount is the plan line, not credits or usage the upgrade invoice settles first", async () => {
    const planLine = (amount: number, extra: Record<string, unknown> = {}) => ({
      amount,
      parent: { subscription_item_details: { subscription_item: "si_1", proration: false } },
      ...extra,
    });
    renewalPreview = {
      currency: "usd",
      // A pending downgrade credit and metered usage both move the total.
      amount_due: 11_500,
      lines: {
        data: [
          planLine(20_000, { discount_amounts: [{ amount: 2_000 }], taxes: [{ amount: 900, tax_behavior: "exclusive" }] }),
          { amount: -10_000, parent: { subscription_item_details: { subscription_item: "si_1", proration: true } } },
          { amount: 1_500, parent: { subscription_item_details: { subscription_item: "si_usage", proration: false } } },
        ],
      },
    };
    const result = await previewPersonalPlanChange({ userId: "u1", target: "max" }, deps);
    expect(result.nextInvoiceAmount).toBe(18_900);
  });

  test("the renewal preview asks Stripe for the next invoice on the new price", async () => {
    await previewPersonalPlanChange({ userId: "u1", target: "max" }, deps);
    const renewalCall = calls.find((call) =>
      call.method === "createPreview" &&
      (call.args[0] as { subscription_details: { proration_behavior: string } }).subscription_details.proration_behavior === "none")!;
    expect(renewalCall.args[0]).toEqual({
      customer: "cus_1",
      subscription: "sub_1",
      subscription_details: {
        items: [{ id: "si_1", price: "price_max_month" }],
        proration_behavior: "none",
      },
    });
  });

  test("loads the complete renewal lines before quoting a plan price", async () => {
    renewalPreview = { id: "upcoming_1", currency: "usd", amount_due: 11_500, lines: { data: [], has_more: true } };
    renewalLines = [{
      amount: 20_000,
      parent: { subscription_item_details: { subscription_item: "si_1", proration: false } },
      discount_amounts: [{ amount: 2_000 }],
      taxes: [{ amount: 900, tax_behavior: "exclusive" }],
    }];
    const result = await previewPersonalPlanChange({ userId: "u1", target: "max" }, deps);
    expect(result.nextInvoiceAmount).toBe(18_900);
    expect(calls.find((call) => call.method === "listLineItems")?.args).toEqual(["upcoming_1", { limit: 100 }]);
  });

  test("paginates renewal lines until it finds the subscription plan", async () => {
    renewalPreview = { id: "upcoming_1", currency: "usd", amount_due: 11_500, lines: { data: [], has_more: true } };
    renewalLinePages = [
      {
        data: [{ id: "line_100", amount: 1_500, parent: { subscription_item_details: { subscription_item: "si_usage", proration: false } } }],
        has_more: true,
      },
      {
        data: [{ id: "line_101", amount: 20_000, parent: { subscription_item_details: { subscription_item: "si_1", proration: false } } }],
        has_more: false,
      },
    ];

    const result = await previewPersonalPlanChange({ userId: "u1", target: "max" }, deps);

    expect(result.nextInvoiceAmount).toBe(20_000);
    expect(calls.filter((call) => call.method === "listLineItems").map((call) => call.args)).toEqual([
      ["upcoming_1", { limit: 100 }],
      ["upcoming_1", { limit: 100, starting_after: "line_100" }],
    ]);
  });

  // The renewal figure is display-only; a payable upgrade must not be blocked
  // by it. Without Stripe's renewal plan line, the dialog quotes the catalog
  // price the switch moves the subscription to.
  test("quotes the target's catalog price when Stripe cannot provide the renewal plan line", async () => {
    renewalPreview = { id: "upcoming_1", currency: "usd", amount_due: 11_500, lines: { data: [], has_more: true } };
    renewalLinesError = new Error("Stripe unavailable");
    const result = await previewPersonalPlanChange({ userId: "u1", target: "max" }, deps);
    expect(result.amountDueToday).toBe(10_000);
    expect(result.nextInvoiceAmount).toBe(20_000);
  });

  test("quotes the catalog price when the renewal preview has no plan line", async () => {
    renewalPreview = { id: "upcoming_1", currency: "usd", amount_due: 11_500, lines: { data: [], has_more: false } };
    expect((await previewPersonalPlanChange({ userId: "u1", target: "max" }, deps)).nextInvoiceAmount).toBe(20_000);
  });

  test("quotes the yearly catalog price when the renewal preview itself fails", async () => {
    subscription = subscriptionOn("cmux-pro-yearly-480", false, "year");
    renewalPreviewError = new Error("Stripe unavailable");
    const result = await previewPersonalPlanChange({ userId: "u1", target: "max" }, deps);
    expect(result.amountDueToday).toBe(10_000);
    expect(result.nextInvoiceAmount).toBe(192_000);
    expect(result.interval).toBe("year");
  });

  // Founder's Edition already includes Pro for life. Moving a founder's Max
  // subscription to a paid Pro price would bill them for a plan they own; they
  // leave Max by cancelling it instead.
  test("refuses to move a Founder's Edition Max subscription onto paid Pro", async () => {
    status = { ...status, activePlanId: "max", hasFoundersEdition: true };
    subscription = subscriptionOn("cmux-max-monthly-200");
    expect(await refusal(previewPersonalPlanChange({ userId: "u1", target: "pro" }, deps))).toBe("not_switchable");
    expect(await refusal(applyPersonalPlanChange({ userId: "u1", target: "pro", prorationDate: NOW }, deps))).toBe("not_switchable");
    expect(calls.some((call) => call.method === "update")).toBe(false);
  });

  test("a founder with a paid Pro subscription can still upgrade it to Max", async () => {
    status = { ...status, hasFoundersEdition: true };
    expect((await previewPersonalPlanChange({ userId: "u1", target: "max" }, deps)).direction).toBe("upgrade");
  });
});
