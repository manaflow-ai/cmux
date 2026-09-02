import { describe, expect, test } from "bun:test";

import { PRO_PRICING_USD, TEAM_PRICING_USD } from "../services/billing/plans";
import { assertPriceMatchesPlan } from "../services/billing/priceGuard";

function price(overrides: Partial<{
  id: string;
  active: boolean;
  currency: string;
  unit_amount: number | null;
  recurring: { interval: "month" | "year"; interval_count?: number } | null;
  product: string | { id: string; metadata: Record<string, string> } | { id: string; deleted: true };
}> = {}) {
  return {
    id: "price_pro_50",
    active: true,
    currency: "usd",
    unit_amount: 5000,
    recurring: { interval: "month" as const, interval_count: 1 },
    product: { id: "prod_pro", metadata: { app: "cmux", plan: "pro" } },
    ...overrides,
  } as Parameters<typeof assertPriceMatchesPlan>[0];
}

describe("Stripe price override guard", () => {
  test("accepts a Price that charges the advertised amount and interval", () => {
    expect(() =>
      assertPriceMatchesPlan(price(), PRO_PRICING_USD.month, "month", "STRIPE_PRO_MONTHLY_50_PRICE_ID", "pro"),
    ).not.toThrow();
    expect(() =>
      assertPriceMatchesPlan(
        price({
          id: "price_team_576",
          unit_amount: 57600,
          recurring: { interval: "year" },
          product: { id: "prod_team", metadata: { app: "cmux", plan: "team" } },
        }),
        TEAM_PRICING_USD.year,
        "year",
        "STRIPE_TEAM_YEARLY_576_PRICE_ID",
        "team",
      ),
    ).not.toThrow();
  });

  test("refuses a grandfathered $30 Price behind the $50 override", () => {
    expect(() =>
      assertPriceMatchesPlan(
        price({ id: "price_legacy_30", unit_amount: 3000 }),
        PRO_PRICING_USD.month,
        "month",
        "STRIPE_PRO_MONTHLY_50_PRICE_ID",
        "pro",
      ),
    ).toThrow(/price_legacy_30.*cmux-pro-monthly-50.*unit_amount 3000 \(expected 5000\)/);
  });

  test("refuses the wrong interval, cadence, currency, or an inactive Price", () => {
    expect(() =>
      assertPriceMatchesPlan(price({ recurring: { interval: "year" } }), PRO_PRICING_USD.month, "month", "x", "pro"),
    ).toThrow(/interval 1×year \(expected 1×month\)/);
    expect(() =>
      assertPriceMatchesPlan(
        price({ recurring: { interval: "month", interval_count: 3 } }),
        PRO_PRICING_USD.month,
        "month",
        "x",
        "pro",
      ),
    ).toThrow(/interval 3×month/);
    expect(() =>
      assertPriceMatchesPlan(price({ currency: "eur" }), PRO_PRICING_USD.month, "month", "x", "pro"),
    ).toThrow(/currency eur/);
    expect(() =>
      assertPriceMatchesPlan(price({ active: false }), PRO_PRICING_USD.month, "month", "x", "pro"),
    ).toThrow(/inactive/);
  });

  test("refuses a Price from another product, even at the right amount", () => {
    expect(() =>
      assertPriceMatchesPlan(
        price({ product: { id: "prod_team", metadata: { app: "cmux", plan: "team" } } }),
        PRO_PRICING_USD.month,
        "month",
        "x",
        "pro",
      ),
    ).toThrow(/product prod_team is not the cmux pro product/);
    expect(() =>
      assertPriceMatchesPlan(price({ product: "prod_pro" }), PRO_PRICING_USD.month, "month", "x", "pro"),
    ).toThrow(/product not expanded/);
    expect(() =>
      assertPriceMatchesPlan(
        price({ product: { id: "prod_gone", deleted: true } }),
        PRO_PRICING_USD.month,
        "month",
        "x",
        "pro",
      ),
    ).toThrow(/deleted/);
  });
});
