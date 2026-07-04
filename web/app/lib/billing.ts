export const CHECKOUT_EXTERNAL_BROWSER_PARAM = "cmux_external_browser";
export const CHECKOUT_PLAN_PARAM = "plan";
export const CHECKOUT_PATH = "/api/billing/checkout";
export type CheckoutPlan = "pro" | "team";
export const PRO_CHECKOUT_PATH = withCheckoutPlan(CHECKOUT_PATH, "pro");
export const TEAM_CHECKOUT_PATH = withCheckoutPlan(CHECKOUT_PATH, "team");
export const PRO_CHECKOUT_URL = withCheckoutExternalBrowserIntent(PRO_CHECKOUT_PATH);
export const TEAM_CHECKOUT_URL = withCheckoutExternalBrowserIntent(TEAM_CHECKOUT_PATH);

const DEFAULT_APP_PRICING_CHECKOUT_URL = "https://cmux.com/api/billing/checkout";

export function withCheckoutExternalBrowserIntent(href: string): string {
  return withSearchParam(href, CHECKOUT_EXTERNAL_BROWSER_PARAM, "1");
}

export function withCheckoutPlan(href: string, plan: CheckoutPlan): string {
  return withSearchParam(href, CHECKOUT_PLAN_PARAM, plan);
}

export function appPricingCheckoutURL(plan: CheckoutPlan, requestOrigin: string | null): string {
  return withCheckoutExternalBrowserIntent(
    withCheckoutPlan(configuredAppPricingCheckoutURL(requestOrigin), plan),
  );
}

function withSearchParam(href: string, name: string, value: string): string {
  const [withoutHash, hash] = href.split("#", 2);
  const separator = withoutHash.includes("?") ? "&" : "?";
  const nextHref = `${withoutHash}${separator}${encodeURIComponent(name)}=${encodeURIComponent(value)}`;
  return hash === undefined ? nextHref : `${nextHref}#${hash}`;
}

function configuredAppPricingCheckoutURL(requestOrigin: string | null): string {
  const configured = process.env.CMUX_APP_PRICING_CHECKOUT_URL?.trim();
  if (configured && configured.length > 0) return configured;
  if (requestOrigin) {
    try {
      return new URL(CHECKOUT_PATH, requestOrigin).toString();
    } catch {
      return DEFAULT_APP_PRICING_CHECKOUT_URL;
    }
  }
  return DEFAULT_APP_PRICING_CHECKOUT_URL;
}
