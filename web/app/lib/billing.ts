export const CHECKOUT_EXTERNAL_BROWSER_PARAM = "cmux_external_browser";
export const CHECKOUT_PLAN_PARAM = "plan";
export const CHECKOUT_PATH = "/api/billing/checkout";
export const PRO_CHECKOUT_PATH = withCheckoutPlan(CHECKOUT_PATH, "pro");
export const TEAM_CHECKOUT_PATH = withCheckoutPlan(CHECKOUT_PATH, "team");
export const PRO_CHECKOUT_URL = withCheckoutExternalBrowserIntent(PRO_CHECKOUT_PATH);
export const TEAM_CHECKOUT_URL = withCheckoutExternalBrowserIntent(TEAM_CHECKOUT_PATH);

const DEFAULT_APP_PRICING_CHECKOUT_URL = "https://cmux.com/api/billing/checkout";

export const APP_PRICING_CHECKOUT_URL = appPricingCheckoutURL("pro");
export const APP_PRICING_TEAM_CHECKOUT_URL = appPricingCheckoutURL("team");

export function withCheckoutExternalBrowserIntent(href: string): string {
  return withSearchParam(href, CHECKOUT_EXTERNAL_BROWSER_PARAM, "1");
}

export function withCheckoutPlan(href: string, plan: "pro" | "team"): string {
  return withSearchParam(href, CHECKOUT_PLAN_PARAM, plan);
}

function appPricingCheckoutURL(plan: "pro" | "team"): string {
  return withCheckoutExternalBrowserIntent(
    withCheckoutPlan(configuredAppPricingCheckoutURL(), plan),
  );
}

function withSearchParam(href: string, name: string, value: string): string {
  const [withoutHash, hash] = href.split("#", 2);
  const separator = withoutHash.includes("?") ? "&" : "?";
  const nextHref = `${withoutHash}${separator}${encodeURIComponent(name)}=${encodeURIComponent(value)}`;
  return hash === undefined ? nextHref : `${nextHref}#${hash}`;
}

function configuredAppPricingCheckoutURL(): string {
  const configured = process.env.CMUX_APP_PRICING_CHECKOUT_URL?.trim();
  return configured && configured.length > 0
    ? configured
    : DEFAULT_APP_PRICING_CHECKOUT_URL;
}
