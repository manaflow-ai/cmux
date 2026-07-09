export const CHECKOUT_EXTERNAL_BROWSER_PARAM = "cmux_external_browser";
export const CHECKOUT_NATIVE_SCHEME_PARAM = "cmux_scheme";
export const CHECKOUT_PLAN_PARAM = "plan";
export const CHECKOUT_PATH = "/api/billing/checkout";
export type CheckoutPlan = "pro" | "team";
export const PRO_CHECKOUT_PATH = withCheckoutPlan(CHECKOUT_PATH, "pro");
export const TEAM_CHECKOUT_PATH = withCheckoutPlan(CHECKOUT_PATH, "team");
export const PRO_CHECKOUT_URL = withCheckoutExternalBrowserIntent(PRO_CHECKOUT_PATH);
export const TEAM_CHECKOUT_URL = withCheckoutExternalBrowserIntent(TEAM_CHECKOUT_PATH);

const DEFAULT_APP_PRICING_CHECKOUT_URL = "https://cmux.com/api/billing/checkout";

type SearchParamValue = string | string[] | null | undefined;

export function withCheckoutExternalBrowserIntent(href: string): string {
  return withSearchParam(href, CHECKOUT_EXTERNAL_BROWSER_PARAM, "1");
}

export function withCheckoutPlan(href: string, plan: CheckoutPlan): string {
  return withSearchParam(href, CHECKOUT_PLAN_PARAM, plan);
}

export function appPricingCheckoutURL(
  plan: CheckoutPlan,
  requestOrigin: string | null,
  cmuxScheme?: string | null,
): string {
  let href = withCheckoutExternalBrowserIntent(
    withCheckoutPlan(configuredAppPricingCheckoutURL(requestOrigin), plan),
  );
  if (cmuxScheme) href = withSearchParam(href, CHECKOUT_NATIVE_SCHEME_PARAM, cmuxScheme);
  return href;
}

export function isAppStoreDistributionMode(params: {
  cmux_distribution?: SearchParamValue;
  cmux_ios_app_store?: SearchParamValue;
}): boolean {
  const distribution = firstSearchParam(params.cmux_distribution)?.trim().toLowerCase();
  if (distribution === "appstore" || distribution === "app-store") return true;
  return firstSearchParam(params.cmux_ios_app_store) === "1";
}

function withSearchParam(href: string, name: string, value: string): string {
  const [withoutHash, hash] = href.split("#", 2);
  const separator = withoutHash.includes("?") ? "&" : "?";
  const nextHref = `${withoutHash}${separator}${encodeURIComponent(name)}=${encodeURIComponent(value)}`;
  return hash === undefined ? nextHref : `${nextHref}#${hash}`;
}

function firstSearchParam(value: SearchParamValue): string | null {
  if (Array.isArray(value)) return value[0] ?? null;
  return value ?? null;
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
