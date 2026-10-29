import { describe, expect, test } from "bun:test";

import {
  CHIEF_MODELS,
  CHIEF_PLANS,
  DEFAULT_CHIEF_USAGE,
  FREESTYLE_COST_USD,
  SANDBOX_LIST_USD,
  blendedUsdPerMillion,
  chiefModel,
  chiefPlan,
  estimateChiefBill,
  recommendChiefPlan,
  sandboxHourUsd,
  worstCaseGrossMargin,
} from "../services/billing/chiefPricing";

describe("cmux-next Chief pricing (proposal)", () => {
  test("blends a Chief token mix of 10% fresh, 85% cached input and 5% output", () => {
    // Kimi K2.7 Code: 0.1 x 1.00 + 0.85 x 0.20 + 0.05 x 4.00 = 0.47
    expect(blendedUsdPerMillion(chiefModel("kimi-k2.7-code"))).toBeCloseTo(0.47, 6);
    // Opus 5.5 writes the 1h cache for fresh input: 0.1 x 8 + 0.85 x 0.2 + 0.05 x 20 = 1.97
    expect(blendedUsdPerMillion(chiefModel("claude-opus-5-5"))).toBeCloseTo(1.97, 6);
  });

  test("every open model is cheaper per blended token than every frontier model", () => {
    const open = CHIEF_MODELS.filter((m) => m.kind === "open");
    const frontier = CHIEF_MODELS.filter((m) => m.kind === "frontier");
    expect(open.length).toBeGreaterThan(0);
    expect(frontier.length).toBeGreaterThan(0);
    const maxOpen = Math.max(...open.map(blendedUsdPerMillion));
    const minFrontier = Math.min(...frontier.map(blendedUsdPerMillion));
    expect(maxOpen).toBeLessThan(minFrontier);
  });

  test("prices a 2 vCPU / 4 GiB sandbox at about $0.15 an hour, above Freestyle cost", () => {
    const size = { vcpu: 2, gib: 4 };
    expect(sandboxHourUsd(size)).toBeCloseTo(0.148, 6);
    const cost = sandboxHourUsd(size, FREESTYLE_COST_USD);
    expect(cost).toBeCloseTo(0.132, 3);
    expect(sandboxHourUsd(size, SANDBOX_LIST_USD)).toBeGreaterThan(cost);
  });

  test("estimates the default Pro month: 52.8M Kimi tokens plus 44 sandbox hours", () => {
    const bill = estimateChiefBill("pro", DEFAULT_CHIEF_USAGE);
    expect(bill.tokensMillions).toBeCloseTo(52.8, 6);
    expect(bill.openTokenUsd).toBeCloseTo(24.816, 6);
    expect(bill.frontierTokenUsd).toBe(0);
    expect(bill.sandboxHours).toBe(44);
    expect(bill.sandboxUsd).toBeCloseTo(6.512, 6);
    expect(bill.includedUsd).toBe(25);
    expect(bill.includedAppliedUsd).toBe(25);
    expect(bill.overageUsd).toBeCloseTo(6.328, 6);
    expect(bill.planUsd).toBe(50);
    expect(bill.totalUsd).toBeCloseTo(56.328, 6);
  });

  test("included credits pay for any model, so open models stretch them about 4x", () => {
    const usage = { ...DEFAULT_CHIEF_USAGE, modelId: "claude-opus-5-5", sandboxHoursPerDay: 0 };
    const pro = estimateChiefBill("pro", usage);
    expect(pro.frontierTokenUsd).toBeCloseTo(52.8 * 1.97, 6);
    expect(pro.includedAppliedUsd).toBe(25);
    expect(pro.overageUsd).toBeCloseTo(pro.frontierTokenUsd - 25, 6);
    const ratio =
      blendedUsdPerMillion(chiefModel("claude-opus-5-5")) /
      blendedUsdPerMillion(chiefModel("kimi-k2.7-code"));
    expect(ratio).toBeGreaterThan(4);
  });

  test("Free is a hard stop at its included credits and has no frontier models", () => {
    const free = chiefPlan("free");
    expect(free.hardStop).toBe(true);
    expect(free.frontierModels).toBe(false);
    const bill = estimateChiefBill("free", DEFAULT_CHIEF_USAGE);
    expect(bill.fits).toBe(false);
    const tiny = estimateChiefBill("free", { ...DEFAULT_CHIEF_USAGE, turnsPerDay: 2, sandboxHoursPerDay: 0 });
    expect(tiny.fits).toBe(true);
    expect(tiny.totalUsd).toBe(0);
    const opus = estimateChiefBill("free", { ...DEFAULT_CHIEF_USAGE, turnsPerDay: 1, modelId: "claude-opus-5-5", sandboxHoursPerDay: 0 });
    expect(opus.fits).toBe(false);
  });

  test("never applies more included credit than the usage it covers", () => {
    const light = { ...DEFAULT_CHIEF_USAGE, turnsPerDay: 1, sandboxHoursPerDay: 0 };
    const bill = estimateChiefBill("max", light);
    expect(bill.includedAppliedUsd).toBeCloseTo(bill.openTokenUsd, 6);
    expect(bill.overageUsd).toBe(0);
    expect(bill.totalUsd).toBe(bill.planUsd);
  });

  test("Team multiplies price and pooled included credits by seats", () => {
    const usage = { ...DEFAULT_CHIEF_USAGE, seats: 5 };
    const bill = estimateChiefBill("team", usage);
    expect(bill.planUsd).toBe(chiefPlan("team").monthlyUsd! * 5);
    expect(bill.includedUsd).toBe(chiefPlan("team").includedCreditsUsd * 5);
    // Usage scales with seats: every seat runs the per-person usage.
    expect(bill.tokensMillions).toBeCloseTo(52.8 * 5, 6);
  });

  test("recommends the cheapest self-serve plan for the usage", () => {
    expect(recommendChiefPlan({ ...DEFAULT_CHIEF_USAGE, turnsPerDay: 2, sandboxHoursPerDay: 0 })).toBe("free");
    expect(recommendChiefPlan(DEFAULT_CHIEF_USAGE)).toBe("pro");
    // Ten sandboxes at once is above Pro's 5, so only Max fits.
    expect(
      recommendChiefPlan({ ...DEFAULT_CHIEF_USAGE, turnsPerDay: 200, modelId: "claude-opus-5-5", parallelSandboxes: 10 }),
    ).toBe("max");
  });

  test("keeps at least 30% gross margin on every paid plan and billing interval when included credits are used up", () => {
    for (const plan of CHIEF_PLANS) {
      if (plan.monthlyUsd === null || plan.monthlyUsd === 0) continue;
      expect(worstCaseGrossMargin(plan)).toBeGreaterThanOrEqual(0.3);
    }
  });

  test("offers Free, Pro, Max, Team and Enterprise in that order", () => {
    expect(CHIEF_PLANS.map((p) => p.id)).toEqual(["free", "pro", "max", "team", "enterprise"]);
    expect(chiefPlan("free").monthlyUsd).toBe(0);
    expect(chiefPlan("enterprise").monthlyUsd).toBeNull();
  });
});
