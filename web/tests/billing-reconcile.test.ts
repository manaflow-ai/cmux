import { describe, expect, test } from "bun:test";
import type Stripe from "stripe";

import { reconcileStripeSubscriptions } from "../services/billing/reconcile";

function subscription(
  id: string,
  status: Stripe.Subscription.Status = "active",
  overrides: Partial<Stripe.Subscription> = {},
): Stripe.Subscription {
  return {
    id,
    object: "subscription",
    status,
    cancel_at_period_end: false,
    items: {
      object: "list",
      data: [{
        id: "si_test",
        object: "subscription_item",
        current_period_end: 1_800_000_000,
        price: { id: "price_test" },
      }],
      has_more: false,
      url: "/v1/subscription_items",
    },
    metadata: { app: "cmux", stackUserId: "redacted", plan: "pro" },
    ...overrides,
  } as Stripe.Subscription;
}

describe("Stripe subscription reconciliation", () => {
  test("checks remote subscriptions concurrently and repairs only drift", async () => {
    let inFlight = 0;
    let peak = 0;
    let started = 0;
    let releaseBoth!: () => void;
    const bothStarted = new Promise<void>((resolve) => {
      releaseBoth = resolve;
    });
    const applied: string[] = [];
    const result = await reconcileStripeSubscriptions({}, {
      list: async () => [
        {
          id: "sub_equal",
          status: "active",
          cancelAtPeriodEnd: false,
          currentPeriodEnd: new Date(1_800_000_000_000),
        },
        {
          id: "sub_drift",
          status: "active",
          cancelAtPeriodEnd: false,
          currentPeriodEnd: new Date(1_800_000_000_000),
        },
      ],
      concurrency: 2,
      retrieve: async (id) => {
        inFlight += 1;
        peak = Math.max(peak, inFlight);
        started += 1;
        if (started === 2) releaseBoth();
        await bothStarted;
        inFlight -= 1;
        return id === "sub_drift"
          ? subscription(id, "canceled")
          : subscription(id);
      },
      apply: async (remote) => {
        applied.push(remote.id);
        return { scope: "user", stackUserId: "ignored", isActive: false };
      },
      markChecked: async () => {},
    });

    expect(peak).toBe(2);
    expect(applied).toEqual(["sub_drift"]);
    expect(result).toEqual({
      checked: 2,
      drifted: 1,
      repaired: 1,
      failed: 0,
      truncated: false,
    });
  });

  test("dry-run reports drift without mutation", async () => {
    let applied = false;
    const result = await reconcileStripeSubscriptions({ dryRun: true }, {
      list: async () => [{
        id: "sub_drift",
        status: "active",
        cancelAtPeriodEnd: false,
        currentPeriodEnd: null,
      }],
      retrieve: async () => subscription("sub_drift", "canceled"),
      apply: async () => {
        applied = true;
      },
      markChecked: async () => {},
    });
    expect(applied).toBe(false);
    expect(result.drifted).toBe(1);
    expect(result.repaired).toBe(0);
  });

  test("isolates failures and never includes identifiers in error context", async () => {
    const contexts: Record<string, unknown>[] = [];
    const result = await reconcileStripeSubscriptions({}, {
      list: async () => [{
        id: "sub_secret",
        status: "active",
        cancelAtPeriodEnd: false,
        currentPeriodEnd: null,
      }],
      retrieve: async () => {
        throw new Error("provider unavailable");
      },
      captureError: (_error, context) => contexts.push(context),
      markChecked: async () => {},
    });
    expect(result.failed).toBe(1);
    expect(contexts).toEqual([{
      operation: "stripe_subscription_reconcile",
      recoverable: true,
    }]);
    expect(JSON.stringify(contexts)).not.toContain("sub_secret");
  });

  test("bounds each run and reports truncation", async () => {
    const result = await reconcileStripeSubscriptions({ limit: 1 }, {
      list: async () => [
        {
          id: "sub_one",
          status: "active",
          cancelAtPeriodEnd: false,
          currentPeriodEnd: new Date(1_800_000_000_000),
        },
        {
          id: "sub_two",
          status: "active",
          cancelAtPeriodEnd: false,
          currentPeriodEnd: new Date(1_800_000_000_000),
        },
      ],
      retrieve: async (id) => subscription(id),
      markChecked: async () => {},
    });
    expect(result.checked).toBe(1);
    expect(result.truncated).toBe(true);
  });

  test("advances every checked row so a later batch can rotate in", async () => {
    const remaining = ["sub_one", "sub_two"];
    const checked: string[] = [];
    const list = async (limit: number) =>
      remaining.slice(0, limit).map((id) => ({
        id,
        status: "active",
        cancelAtPeriodEnd: false,
        currentPeriodEnd: new Date(1_800_000_000_000),
      }));
    const markChecked = async (ids: readonly string[]) => {
      checked.push(...ids);
      for (const id of ids) remaining.splice(remaining.indexOf(id), 1);
    };
    const dependencies = {
      list,
      retrieve: async (id: string) => subscription(id),
      markChecked,
    };

    expect((await reconcileStripeSubscriptions({ limit: 1 }, dependencies)).truncated)
      .toBe(true);
    expect((await reconcileStripeSubscriptions({ limit: 1 }, dependencies)).truncated)
      .toBe(false);
    expect(checked).toEqual(["sub_one", "sub_two"]);
  });
});
