import { describe, expect, test } from "bun:test";

import {
  LEGACY_PRO_YEARLY_LOOKUP_KEY,
  PRO_PRICING_USD,
  TEAM_PRICING_USD,
  proBillingInterval,
} from "../services/billing/plans";

describe("pricing plans", () => {
  test("prices annual Pro at $288 with a 20% discount", () => {
    expect(PRO_PRICING_USD.year).toEqual({
      billedAmount: 288,
      monthlyEquivalent: 24,
      discountPercent: 20,
      lookupKey: "cmux-pro-yearly-288",
    });
    expect(PRO_PRICING_USD.month.billedAmount * 12).toBe(360);
    expect(PRO_PRICING_USD.year.billedAmount).toBe(
      PRO_PRICING_USD.month.billedAmount *
        12 *
        (1 - PRO_PRICING_USD.year.discountPercent / 100),
    );
  });

  test("keeps the original annual lookup key reserved for grandfathered subscriptions", () => {
    expect(LEGACY_PRO_YEARLY_LOOKUP_KEY).toBe("cmux-pro-yearly");
    expect(PRO_PRICING_USD.year.lookupKey).not.toBe(
      LEGACY_PRO_YEARLY_LOOKUP_KEY,
    );
  });

  test("prices annual Team at $336 per user with a 20% discount", () => {
    expect(TEAM_PRICING_USD.month).toEqual({
      billedAmount: 35,
      monthlyEquivalent: 35,
      discountPercent: 0,
      lookupKey: "cmux-team-monthly",
    });
    expect(TEAM_PRICING_USD.year).toEqual({
      billedAmount: 336,
      monthlyEquivalent: 28,
      discountPercent: 20,
      lookupKey: "cmux-team-yearly-336",
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
