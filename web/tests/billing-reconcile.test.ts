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
        await new Promise((resolve) => setTimeout(resolve, 5));
        inFlight -= 1;
        return id === "sub_drift"
          ? subscription(id, "canceled")
          : subscription(id);
      },
      apply: async (remote) => {
        applied.push(remote.id);
        return { scope: "user", stackUserId: "ignored", isActive: false };
      },
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
    });
    expect(result.checked).toBe(1);
    expect(result.truncated).toBe(true);
  });
});
