import { beforeEach, describe, expect, test } from "bun:test";
import { PlanChangeError } from "../services/billing/planChange";
import {
  applyTeamPlanChange,
  previewTeamPlanChange,
  type TeamPlanChangeDependencies,
} from "../services/billing/teamPlanChange";

const NOW = 1_790_000_000;
const PERIOD_END = NOW + 20 * 86_400;

type Status = Awaited<ReturnType<TeamPlanChangeDependencies["billingStatus"]>>;
let status: Status;
let subscription: Record<string, unknown>;
let preview: Record<string, unknown>;
let updateError: unknown;
const calls: { method: string; args: unknown[] }[] = [];
const synced: unknown[] = [];
const statusTeams: string[] = [];

function subscriptionOn(lookupKey: string, options: { quantity?: number; cancelAtPeriodEnd?: boolean; interval?: string } = {}) {
  return {
    id: "sub_team",
    customer: "cus_team",
    status: "active",
    cancel_at_period_end: options.cancelAtPeriodEnd ?? false,
    metadata: { app: "cmux", plan: "team", stackTeamId: "team-1", stackUserId: "admin-1" },
    items: {
      data: [{
        id: "si_team",
        quantity: options.quantity ?? 3,
        current_period_end: PERIOD_END,
        price: { id: "price_old", lookup_key: lookupKey, recurring: { interval: options.interval ?? "month" } },
      }],
    },
  };
}

const deps: TeamPlanChangeDependencies = {
  billingStatus: async (teamId) => {
    statusTeams.push(teamId);
    return status;
  },
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
    customerId: "cus_team",
    subscriptionStatus: "active",
    subscriptionId: "sub_team",
    activePlanId: null,
    teamPlanId: "team",
    cancelAtPeriodEnd: false,
    hasCustomer: true,
    hasActiveSubscription: true,
  };
  subscription = subscriptionOn("cmux-team-monthly-60");
  preview = { currency: "usd", amount_due: 31_000, lines: { data: [] } };
  updateError = null;
  calls.length = 0;
  synced.length = 0;
  statusTeams.length = 0;
});

async function refusal(operation: Promise<unknown>) {
  const error = await operation.catch((caught: unknown) => caught);
  expect(error).toBeInstanceOf(PlanChangeError);
  return (error as PlanChangeError).reason;
}

describe("team plan change", () => {
  test("Team to Team Max previews an immediate prorated charge on the same item, leaving Stripe's seat count alone", async () => {
    const result = await previewTeamPlanChange({ teamId: "team-1", target: "team_max" }, deps);

    expect(statusTeams).toEqual(["team-1"]);
    expect(calls.find((call) => call.method === "createPreview")?.args[0]).toEqual({
      customer: "cus_team",
      subscription: "sub_team",
      subscription_details: {
        items: [{ id: "si_team", price: "price_team_max" }],
        proration_behavior: "always_invoice",
        proration_date: NOW,
      },
    });
    expect(result).toEqual({
      plan: "team_max",
      direction: "upgrade",
      currency: "usd",
      amountDueToday: 31_000,
      credit: 0,
      nextRenewalAt: new Date(PERIOD_END * 1000).toISOString(),
      // $220 per seat, three seats.
      nextInvoiceAmount: 66_000,
      prorationDate: NOW,
    });
  });

  test("Team to Team Max swaps the price on the plan item, invoices now, and records the result", async () => {
    await applyTeamPlanChange({ teamId: "team-1", target: "team_max", prorationDate: NOW - 60 }, deps);

    const update = calls.find((call) => call.method === "update");
    expect(update?.args[0]).toBe("sub_team");
    expect(update?.args[1]).toEqual({
      items: [{ id: "si_team", price: "price_team_max" }],
      proration_behavior: "always_invoice",
      proration_date: NOW - 60,
      payment_behavior: "error_if_incomplete",
      metadata: { app: "cmux", plan: "team_max", stackTeamId: "team-1", stackUserId: "admin-1" },
    });
    expect(synced).toHaveLength(1);
  });

  test("Team Max back to Team credits the unused time instead of charging", async () => {
    status = { ...status, teamPlanId: "team_max" };
    subscription = subscriptionOn("cmux-team-max-monthly-220");
    preview = {
      currency: "usd",
      amount_due: 0,
      lines: { data: [
        { amount: -40_000, parent: { subscription_item_details: { proration: true } } },
        { amount: 11_000, parent: { subscription_item_details: { proration: true } } },
      ] },
    };

    const result = await previewTeamPlanChange({ teamId: "team-1", target: "team" }, deps);
    expect(result.direction).toBe("downgrade");
    expect(result.amountDueToday).toBe(0);
    expect(result.credit).toBe(29_000);
    const args = calls.find((call) => call.method === "createPreview")?.args[0] as { subscription_details: unknown };
    expect(args.subscription_details).toMatchObject({
      items: [{ id: "si_team", price: "price_team" }],
      proration_behavior: "create_prorations",
    });
  });

  test("refuses the plan the team already has", async () => {
    expect(await refusal(previewTeamPlanChange({ teamId: "team-1", target: "team" }, deps))).toBe("same_plan");
    subscription = subscriptionOn("cmux-team-max-monthly-220");
    status = { ...status, teamPlanId: "team" };
    expect(await refusal(previewTeamPlanChange({ teamId: "team-1", target: "team_max" }, deps))).toBe("same_plan");
  });

  test("refuses without an active team subscription, or while it is scheduled to cancel", async () => {
    status = { ...status, subscriptionId: null, subscriptionStatus: null, hasActiveSubscription: false };
    expect(await refusal(previewTeamPlanChange({ teamId: "team-1", target: "team_max" }, deps))).toBe("no_subscription");
    status = { ...status, subscriptionId: "sub_team", subscriptionStatus: "active", cancelAtPeriodEnd: true };
    expect(await refusal(previewTeamPlanChange({ teamId: "team-1", target: "team_max" }, deps))).toBe("cancel_scheduled");
  });

  test("a grandfathered annual Team subscription is not switched in place", async () => {
    subscription = subscriptionOn("cmux-team-yearly-576", { interval: "year" });
    expect(await refusal(previewTeamPlanChange({ teamId: "team-1", target: "team_max" }, deps))).toBe("not_switchable");
    expect(calls.some((call) => call.method === "createPreview")).toBe(false);
  });

  test("a personal subscription is never switched by the team path", async () => {
    subscription = { ...subscriptionOn("cmux-pro-monthly-50"), metadata: { app: "cmux", plan: "pro" } };
    expect(await refusal(previewTeamPlanChange({ teamId: "team-1", target: "team_max" }, deps))).toBe("not_switchable");
  });

  test("a declined card fails the change whole", async () => {
    updateError = Object.assign(new Error("declined"), { type: "StripeCardError" });
    expect(await refusal(applyTeamPlanChange({ teamId: "team-1", target: "team_max", prorationDate: NOW }, deps))).toBe("payment_failed");
    expect(synced).toHaveLength(0);
  });
});
