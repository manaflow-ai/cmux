import type { AppPlanSnapshot } from "./pricing-content";

export const unknownPlan: AppPlanSnapshot = {
  authenticated: false,
  developmentPro: false,
  planId: "free",
  isPro: false,
  billingManagement: "none",
  email: null,
};

/** The page-level fallback avoids rendering English copy before locale loading. */
export function AppPricingFallback() {
  return <div className="min-h-screen" aria-busy="true" />;
}
