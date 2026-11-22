import { PRO_PRICING_USD } from "../../services/billing/plans";
import type { ProAnnualLabels } from "./pro-plan-card";

/**
 * Pro yearly-billing copy for every pricing surface. `format` fills the
 * `pricing.pro.annual.billedYearlySaving` message; the other labels come from
 * the surface's own catalog.
 */
export function proAnnualLabels(
  format: (values: Record<string, number>) => string,
  shared: Omit<ProAnnualLabels, "billedYearlySaving">,
): ProAnnualLabels {
  const { year } = PRO_PRICING_USD;
  return {
    ...shared,
    billedYearlySaving: format({
      amount: year.billedAmount,
      percent: year.discountPercent,
    }),
  };
}
