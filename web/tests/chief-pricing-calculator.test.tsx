import { describe, expect, test } from "bun:test";
import { renderToString } from "react-dom/server";

import enMessages from "../messages/en.json";
import { ChiefPricingCalculator, type ChiefCalculatorLabels } from "../app/[locale]/(landing)/next/pricing/chief-pricing-calculator";
import { isNextPricingPreviewEnabled } from "../services/billing/nextPricingPreview";

const c = enMessages.nextPricing.calculator;
const labels: ChiefCalculatorLabels = {
  ...c,
  custom: enMessages.nextPricing.custom,
  planNames: {
    free: "Free",
    pro: "Pro",
    max: "Max",
    team: "Team",
    enterprise: "Enterprise",
  },
};

describe("cmux-next Chief pricing page", () => {
  test("the calculator opens on the default month and recommends Pro at $56.33", () => {
    const html = renderToString(<ChiefPricingCalculator labels={labels} />);
    expect(html).toContain("Best fit: Pro");
    expect(html).toContain("52.8M");
    expect(html).toContain("$56.33");
    // Free cannot run the default month: it stops at its included credits.
    expect(html).toContain("Free can&#x27;t run this");
  });

  test("the proposal page is hidden in Vercel production unless an operator opts in", () => {
    expect(isNextPricingPreviewEnabled({ VERCEL_ENV: "production" })).toBe(false);
    expect(isNextPricingPreviewEnabled({ VERCEL_ENV: "production", CMUX_NEXT_PRICING_PREVIEW: "1" })).toBe(true);
    expect(isNextPricingPreviewEnabled({ VERCEL_ENV: "preview" })).toBe(true);
    expect(isNextPricingPreviewEnabled({})).toBe(true);
  });
});
