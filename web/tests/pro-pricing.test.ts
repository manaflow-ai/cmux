import { describe, expect, test } from "bun:test";

import {
  LEGACY_PRO_MONTHLY_LOOKUP_KEY,
  LEGACY_PRO_YEARLY_288_LOOKUP_KEY,
  LEGACY_PRO_YEARLY_LOOKUP_KEY,
  LEGACY_TEAM_MONTHLY_LOOKUP_KEY,
  LEGACY_TEAM_YEARLY_336_LOOKUP_KEY,
  PRO_PRICING_USD,
  TEAM_PRICING_USD,
  proBillingInterval,
} from "../services/billing/plans";

describe("pricing plans", () => {
  test("prices annual Pro at $432 with a 20% discount", () => {
    expect(PRO_PRICING_USD.year).toEqual({
      billedAmount: 432,
      monthlyEquivalent: 36,
      discountPercent: 20,
      lookupKey: "cmux-pro-yearly-432",
    });
    expect(PRO_PRICING_USD.month.billedAmount * 12).toBe(540);
    expect(PRO_PRICING_USD.year.billedAmount).toBe(
      PRO_PRICING_USD.month.billedAmount *
        12 *
        (1 - PRO_PRICING_USD.year.discountPercent / 100),
    );
  });

  test("keeps grandfathered lookup keys distinct from the live catalog", () => {
    expect(LEGACY_PRO_YEARLY_LOOKUP_KEY).toBe("cmux-pro-yearly");
    expect(LEGACY_PRO_MONTHLY_LOOKUP_KEY).toBe("cmux-pro-monthly");
    expect(LEGACY_PRO_YEARLY_288_LOOKUP_KEY).toBe("cmux-pro-yearly-288");
    expect(LEGACY_TEAM_MONTHLY_LOOKUP_KEY).toBe("cmux-team-monthly");
    expect(LEGACY_TEAM_YEARLY_336_LOOKUP_KEY).toBe("cmux-team-yearly-336");
    const live = [
      PRO_PRICING_USD.month.lookupKey,
      PRO_PRICING_USD.year.lookupKey,
      TEAM_PRICING_USD.month.lookupKey,
      TEAM_PRICING_USD.year.lookupKey,
    ];
    for (const legacy of [
      LEGACY_PRO_YEARLY_LOOKUP_KEY,
      LEGACY_PRO_MONTHLY_LOOKUP_KEY,
      LEGACY_PRO_YEARLY_288_LOOKUP_KEY,
      LEGACY_TEAM_MONTHLY_LOOKUP_KEY,
      LEGACY_TEAM_YEARLY_336_LOOKUP_KEY,
    ]) {
      expect(live).not.toContain(legacy);
    }
  });

  test("prices annual Team at $480 per user with a 20% discount", () => {
    expect(TEAM_PRICING_USD.month).toEqual({
      billedAmount: 50,
      monthlyEquivalent: 50,
      discountPercent: 0,
      lookupKey: "cmux-team-monthly-50",
    });
    expect(TEAM_PRICING_USD.year).toEqual({
      billedAmount: 480,
      monthlyEquivalent: 40,
      discountPercent: 20,
      lookupKey: "cmux-team-yearly-480",
    });
    expect(TEAM_PRICING_USD.year.billedAmount).toBe(
      TEAM_PRICING_USD.month.billedAmount *
        12 *
        (1 - TEAM_PRICING_USD.year.discountPercent / 100),
    );
  });

  test("defaults unknown intervals to monthly", () => {
    expect(proBillingInterval("year")).toBe("year");
    expect(proBillingInterval("month")).toBe("month");
    expect(proBillingInterval("annual")).toBe("month");
    expect(proBillingInterval(null)).toBe("month");
  });
});
