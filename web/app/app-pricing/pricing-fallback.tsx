import { AppPricingContent, type AppPlanSnapshot } from "./pricing-content";

export const unknownPlan: AppPlanSnapshot = {
  authenticated: false,
  developmentPro: false,
  planId: "free",
  isPro: false,
  billingManagement: "none",
  email: null,
};

/** Prices are immediately available. External purchase actions wait for request context. */
export function AppPricingFallback() {
  return (
    <AppPricingContent
      params={{ cmux_app: "1", cmux_distribution: "appstore" }}
      headersList={new Headers()}
      snapshot={unknownPlan}
      goPlanEnabled={false}
      pending
    />
  );
}
