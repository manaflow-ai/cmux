import { describe, expect, test } from "bun:test";
import { personalPlanCards, sharedUnavailableReason, teamPlanCards } from "../dashboard-app/screens/billing/plan-model";

const summary = (cards: ReturnType<typeof personalPlanCards>) =>
  cards.map((card) => `${card.id}${card.current ? "*" : ""}:${card.action.kind}${"plan" in card.action ? `/${card.action.plan}` : ""}${"reason" in card.action ? `/${card.action.reason}` : ""}`);

describe("personal plan picker", () => {
  test("a Free user upgrades to any paid plan through checkout", () => {
    expect(summary(personalPlanCards({ planId: "free", isPro: false, subscription: null, goPlanEnabled: false }))).toEqual([
      "free*:current",
      "pro:checkout/pro",
      "max:checkout/max",
    ]);
  });

  test("Go appears for Free users only when the Go plan is enabled", () => {
    expect(summary(personalPlanCards({ planId: "free", isPro: false, subscription: null, goPlanEnabled: true }))).toEqual([
      "free*:current",
      "go:checkout/go",
      "pro:checkout/pro",
      "max:checkout/max",
    ]);
  });

  test("a Pro subscriber switches to Max in place, and Free means cancel", () => {
    expect(summary(personalPlanCards({
      planId: "pro",
      isPro: true,
      subscription: { plan: "pro", cancelAtPeriodEnd: false },
      goPlanEnabled: true,
    }))).toEqual(["free:cancel", "pro*:current", "max:switch/max"]);
  });

  test("a Max subscriber switches down to Pro in place", () => {
    expect(summary(personalPlanCards({
      planId: "max",
      isPro: true,
      subscription: { plan: "max", cancelAtPeriodEnd: false },
      goPlanEnabled: false,
    }))).toEqual(["free:cancel", "pro:switch/pro", "max*:current"]);
  });

  test("a scheduled cancellation offers Resume and blocks switching", () => {
    expect(summary(personalPlanCards({
      planId: "pro",
      isPro: true,
      subscription: { plan: "pro", cancelAtPeriodEnd: true },
      goPlanEnabled: false,
    }))).toEqual(["free:unavailable/cancelScheduled", "pro*:resume", "max:unavailable/cancelScheduled"]);
  });

  test("granted Pro has nothing to change", () => {
    expect(summary(personalPlanCards({ planId: "pro", isPro: true, subscription: null, goPlanEnabled: false }))).toEqual([
      "free:unavailable/granted",
      "pro*:current",
      "max:unavailable/granted",
    ]);
  });
});

describe("team plan picker", () => {
  const base = { canManageBilling: true, granted: false, subscription: null } as const;

  test("a Free team's admin upgrades through Team checkout", () => {
    expect(summary(teamPlanCards(base))).toEqual(["free*:current", "team:checkout/team"]);
  });

  test("a member sees the plans but cannot change them", () => {
    expect(summary(teamPlanCards({ ...base, canManageBilling: false }))).toEqual(["free*:current", "team:unavailable/adminOnly"]);
  });

  test("an active Team subscription cancels from the Free card; a scheduled one resumes", () => {
    expect(summary(teamPlanCards({ ...base, subscription: { cancelAtPeriodEnd: false } }))).toEqual(["free:cancel", "team*:current"]);
    expect(summary(teamPlanCards({ ...base, subscription: { cancelAtPeriodEnd: true } }))).toEqual([
      "free:unavailable/cancelScheduled",
      "team*:resume",
    ]);
  });

  test("a granted Team plan has nothing to change", () => {
    expect(summary(teamPlanCards({ ...base, granted: true }))).toEqual(["free:unavailable/granted", "team*:current"]);
  });
});

describe("a reason every other card shares", () => {
  test("shows once when all other cards are unavailable for the same reason", () => {
    const cancelling = personalPlanCards({ planId: "pro", isPro: true, subscription: { plan: "pro", cancelAtPeriodEnd: true }, goPlanEnabled: false });
    expect(sharedUnavailableReason(cancelling)).toBe("cancelScheduled");
    const granted = personalPlanCards({ planId: "pro", isPro: true, subscription: null, goPlanEnabled: false });
    expect(sharedUnavailableReason(granted)).toBe("granted");
  });

  test("is null when the other cards have actions", () => {
    expect(sharedUnavailableReason(personalPlanCards({ planId: "free", isPro: false, subscription: null, goPlanEnabled: false }))).toBeNull();
    expect(sharedUnavailableReason(teamPlanCards({ canManageBilling: true, granted: false, subscription: null }))).toBeNull();
  });
});

// Regression: the current card said "$50/mo" while the others said
// "$50 per month". Every card now shares one price shape.
describe("plan card price", () => {
  test("list prices and the current subscription's price use the same shape", async () => {
    const { planCardPrice } = await import("../dashboard-app/screens/billing/plan-model");
    expect(planCardPrice("max", false, undefined)).toEqual({ amount: "$200", unit: "perMonth", annual: false });
    expect(planCardPrice("pro", true, { amountUsd: 50, interval: "month" })).toEqual({ amount: "$50", unit: "perMonth", annual: false });
    expect(planCardPrice("pro", true, { amountUsd: 500, interval: "year" })).toEqual({ amount: "$41.67", unit: "perMonth", annual: true });
    expect(planCardPrice("team", true, { amountUsd: 60, interval: "month" })).toEqual({ amount: "$60", unit: "perSeatMonth", annual: false });
    expect(planCardPrice("pro", true, null)).toBeNull();
  });
});
