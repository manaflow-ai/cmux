export const CHECKOUT_EXTERNAL_BROWSER_PARAM = "cmux_external_browser";
export const PRO_CHECKOUT_PATH = "/api/billing/checkout";
export const PRO_CHECKOUT_URL = withCheckoutExternalBrowserIntent(PRO_CHECKOUT_PATH);

const DEFAULT_APP_PRICING_CHECKOUT_URL = "https://cmux.com/api/billing/checkout";

export const APP_PRICING_CHECKOUT_URL = withCheckoutExternalBrowserIntent(
  configuredAppPricingCheckoutURL(),
);

export function withCheckoutExternalBrowserIntent(href: string): string {
  const [withoutHash, hash] = href.split("#", 2);
  const separator = withoutHash.includes("?") ? "&" : "?";
  const nextHref = `${withoutHash}${separator}${CHECKOUT_EXTERNAL_BROWSER_PARAM}=1`;
  return hash === undefined ? nextHref : `${nextHref}#${hash}`;
}

function configuredAppPricingCheckoutURL(): string {
  const configured = process.env.CMUX_APP_PRICING_CHECKOUT_URL?.trim();
  return configured && configured.length > 0
    ? configured
    : DEFAULT_APP_PRICING_CHECKOUT_URL;
}
