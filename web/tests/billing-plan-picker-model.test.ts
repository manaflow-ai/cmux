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
  const base = { canManageBilling: true, granted: false, subscription: null, planId: "free" } as const;

  test("a Free team's admin upgrades through Team or Team Max checkout", () => {
    expect(summary(teamPlanCards(base))).toEqual(["free*:current", "team:checkout/team", "team_max:checkout/team_max"]);
  });

  test("a member sees the plans but cannot change them", () => {
    expect(summary(teamPlanCards({ ...base, canManageBilling: false }))).toEqual([
      "free*:current",
      "team:unavailable/adminOnly",
      "team_max:unavailable/adminOnly",
    ]);
  });

  test("an active Team subscription switches to Team Max in place and cancels from the Free card", () => {
    expect(summary(teamPlanCards({ ...base, planId: "team", subscription: { cancelAtPeriodEnd: false } }))).toEqual([
      "free:cancel",
      "team*:current",
      "team_max:switch/team_max",
    ]);
    expect(summary(teamPlanCards({ ...base, planId: "team", subscription: { cancelAtPeriodEnd: true } }))).toEqual([
      "free:unavailable/cancelScheduled",
      "team*:resume",
      "team_max:unavailable/cancelScheduled",
    ]);
  });

  test("an active Team Max subscription switches back down to Team in place", () => {
    expect(summary(teamPlanCards({ ...base, planId: "team_max", subscription: { cancelAtPeriodEnd: false } }))).toEqual([
      "free:cancel",
      "team:switch/team",
      "team_max*:current",
    ]);
  });

  test("a granted Team or Team Max plan has nothing to change", () => {
    expect(summary(teamPlanCards({ ...base, planId: "team", granted: true }))).toEqual([
      "free:unavailable/granted",
      "team*:current",
      "team_max:unavailable/granted",
    ]);
    expect(summary(teamPlanCards({ ...base, planId: "team_max", granted: true }))).toEqual([
      "free:unavailable/granted",
      "team:unavailable/granted",
      "team_max*:current",
    ]);
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
    expect(sharedUnavailableReason(teamPlanCards({ canManageBilling: true, granted: false, subscription: null, planId: "free" }))).toBeNull();
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
    expect(planCardPrice("team_max", false, undefined)).toEqual({ amount: "$220", unit: "perSeatMonth", annual: false });
    expect(planCardPrice("pro", true, null)).toBeNull();
  });
});
