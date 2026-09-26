import { AppPricingContent, type AppPlanSnapshot } from "./pricing-content";

// The fallback snapshot is consumed by the fallback component and its route
// boundary; keeping the value next to that component makes the loading state
// explicit.
// react-doctor-disable-next-line react-doctor/only-export-components -- colocated fallback snapshot
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
