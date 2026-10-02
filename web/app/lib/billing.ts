import { createHmac, timingSafeEqual } from "node:crypto";

export const EXTERNAL_BROWSER_PARAM = "cmux_external_browser";
export const CHECKOUT_EXTERNAL_BROWSER_PARAM = EXTERNAL_BROWSER_PARAM;
export const CHECKOUT_NATIVE_SCHEME_PARAM = "cmux_scheme";
export const CHECKOUT_PLAN_PARAM = "plan";
export const CHECKOUT_INTERVAL_PARAM = "interval";
export const CHECKOUT_APP_RELAY_PARAM = "cmux_app_checkout";
export const CHECKOUT_RELAY_EXPIRES_PARAM = "cmux_relay_expires";
export const CHECKOUT_RELAY_SIGNATURE_PARAM = "cmux_relay_signature";
export const CHECKOUT_NATIVE_RETURN_SESSION_PARAM = "cmux_checkout_session";
export const CHECKOUT_NATIVE_RETURN_EXPIRES_PARAM = "cmux_native_return_expires";
export const CHECKOUT_NATIVE_RETURN_SIGNATURE_PARAM = "cmux_native_return_signature";
export const APP_PRICING_NATIVE_RETURN_QUERY_PARAMS = [
  CHECKOUT_NATIVE_RETURN_SESSION_PARAM,
  CHECKOUT_NATIVE_RETURN_EXPIRES_PARAM,
  CHECKOUT_NATIVE_RETURN_SIGNATURE_PARAM,
] as const;
export const CHECKOUT_PATH = "/api/billing/checkout";
export type CheckoutPlan = "pro" | "team";
export type CheckoutInterval = "month" | "year";
export type AppPricingCheckoutRelayParameters = {
  plan: CheckoutPlan | null;
  interval: CheckoutInterval | null;
  cmuxScheme: string;
};
export const PRO_CHECKOUT_PATH = withCheckoutPlan(CHECKOUT_PATH, "pro");
export const TEAM_CHECKOUT_PATH = withCheckoutPlan(CHECKOUT_PATH, "team");
export const PRO_CHECKOUT_URL = withExternalBrowserIntent(PRO_CHECKOUT_PATH);
export const TEAM_CHECKOUT_URL = withExternalBrowserIntent(TEAM_CHECKOUT_PATH);

const DEFAULT_APP_PRICING_CHECKOUT_URL = "https://cmux.com/api/billing/checkout";
const APP_PRICING_RELAY_TTL_SECONDS = 5 * 60;
const APP_PRICING_RELAY_CLOCK_SKEW_SECONDS = 30;

type SearchParamValue = string | string[] | null | undefined;

export function withExternalBrowserIntent(href: string): string {
  return withSearchParam(href, EXTERNAL_BROWSER_PARAM, "1");
}

export const withCheckoutExternalBrowserIntent = withExternalBrowserIntent;

export function withCheckoutPlan(href: string, plan: CheckoutPlan): string {
  return withSearchParam(href, CHECKOUT_PLAN_PARAM, plan);
}

export function withCheckoutInterval(
  href: string,
  interval: CheckoutInterval,
): string {
  return withSearchParam(href, CHECKOUT_INTERVAL_PARAM, interval);
}

export function appPricingCheckoutURL(
  plan: CheckoutPlan,
  requestOrigin: string | null,
  cmuxScheme?: string | null,
  interval?: CheckoutInterval,
): string {
  let href = withExternalBrowserIntent(
    withCheckoutPlan(appPricingCheckoutEntryURL(requestOrigin), plan),
  );
  if (configuredAppPricingCheckoutURL()) {
    href = withSearchParam(href, CHECKOUT_APP_RELAY_PARAM, "1");
  }
  if (cmuxScheme) href = withSearchParam(href, CHECKOUT_NATIVE_SCHEME_PARAM, cmuxScheme);
  if (interval) href = withCheckoutInterval(href, interval);
  return href;
}

export function appPricingCheckoutRelayURL(
  requestURL: URL,
  parameters: AppPricingCheckoutRelayParameters,
): URL | null {
  if (requestURL.searchParams.get(CHECKOUT_APP_RELAY_PARAM) !== "1") {
    return null;
  }
  const { plan, interval, cmuxScheme } = parameters;
  if (!plan || !interval) return null;
  const target = configuredAppPricingCheckoutURL();
  if (!target) return null;

  target.searchParams.set(CHECKOUT_PLAN_PARAM, plan);
  target.searchParams.set(CHECKOUT_INTERVAL_PARAM, interval);
  const assertion = appPricingRelayAssertion(target, {
    plan,
    interval,
    cmuxScheme,
  });
  target.searchParams.set(
    CHECKOUT_NATIVE_SCHEME_PARAM,
    assertion?.scheme ?? safeUnassertedRelayScheme(cmuxScheme),
  );
  if (assertion) {
    target.searchParams.set(CHECKOUT_RELAY_EXPIRES_PARAM, assertion.expires);
    target.searchParams.set(CHECKOUT_RELAY_SIGNATURE_PARAM, assertion.signature);
  }
  return target;
}

export function verifiedAppPricingRelayScheme(requestURL: URL): string | null {
  const scheme = requestURL.searchParams
    .get(CHECKOUT_NATIVE_SCHEME_PARAM)
    ?.trim()
    .toLowerCase();
  if (!scheme || !isProtectedRelayScheme(scheme)) return null;
  const plan = requestURL.searchParams.get(CHECKOUT_PLAN_PARAM);
  const interval = requestURL.searchParams.get(CHECKOUT_INTERVAL_PARAM);
  const expires = requestURL.searchParams.get(CHECKOUT_RELAY_EXPIRES_PARAM);
  const signature = requestURL.searchParams.get(CHECKOUT_RELAY_SIGNATURE_PARAM);
  const secret = appPricingRelaySecret();
  if (
    (plan !== "pro" && plan !== "team") ||
    (interval !== "month" && interval !== "year") ||
    !expires ||
    !signature ||
    !secret
  ) {
    return null;
  }
  if (!validRelayExpiry(expires)) return null;
  const expected = relaySignature(
    requestURL,
    { plan, interval, cmuxScheme: scheme },
    expires,
    secret,
  );
  if (!constantTimeHexEqual(signature, expected)) return null;
  return scheme;
}

export function isProtectedAppPricingRelayScheme(
  rawScheme: string | null | undefined,
): boolean {
  return isProtectedRelayScheme(rawScheme?.trim().toLowerCase() ?? "");
}

export function appPricingNativeReturnURL(
  target: URL,
  nativeReturnTo: string,
  checkoutSessionId: string,
): URL {
  const result = new URL(target);
  result.searchParams.set("native_app_return_to", nativeReturnTo);
  if (!protectedNativeReturnTo(nativeReturnTo)) return result;
  const secret = appPricingRelaySecret();
  if (!secret || !validCheckoutSessionId(checkoutSessionId)) return result;
  const expires = String(
    Math.floor(Date.now() / 1000) + APP_PRICING_RELAY_TTL_SECONDS,
  );
  result.searchParams.set(CHECKOUT_NATIVE_RETURN_SESSION_PARAM, checkoutSessionId);
  result.searchParams.set(CHECKOUT_NATIVE_RETURN_EXPIRES_PARAM, expires);
  result.searchParams.set(
    CHECKOUT_NATIVE_RETURN_SIGNATURE_PARAM,
    nativeReturnSignature(
      result,
      nativeReturnTo,
      checkoutSessionId,
      expires,
      secret,
    ),
  );
  return result;
}

export function verifiedAppPricingNativeReturnTo(
  requestURL: URL,
): string | null {
  const nativeReturnTo = requestURL.searchParams.get("native_app_return_to");
  const checkoutSessionId = requestURL.searchParams.get(
    CHECKOUT_NATIVE_RETURN_SESSION_PARAM,
  );
  const expires = requestURL.searchParams.get(
    CHECKOUT_NATIVE_RETURN_EXPIRES_PARAM,
  );
  const signature = requestURL.searchParams.get(
    CHECKOUT_NATIVE_RETURN_SIGNATURE_PARAM,
  );
  const secret = appPricingRelaySecret();
  if (
    !nativeReturnTo ||
    !protectedNativeReturnTo(nativeReturnTo) ||
    !checkoutSessionId ||
    !validCheckoutSessionId(checkoutSessionId) ||
    !expires ||
    !signature ||
    !secret ||
    !validRelayExpiry(expires)
  ) {
    return null;
  }
  const expected = nativeReturnSignature(
    requestURL,
    nativeReturnTo,
    checkoutSessionId,
    expires,
    secret,
  );
  return constantTimeHexEqual(signature, expected) ? nativeReturnTo : null;
}

export function isAppStoreDistributionMode(params: {
  cmux_distribution?: SearchParamValue;
  cmux_ios_app_store?: SearchParamValue;
}): boolean {
  const distribution = firstSearchParam(params.cmux_distribution)?.trim().toLowerCase();
  if (distribution === "appstore" || distribution === "app-store") return true;
  return firstSearchParam(params.cmux_ios_app_store) === "1";
}

export function appStorePricingUnavailableURL(requestUrl: URL): URL {
  const redirectURL = new URL("/app-pricing", requestUrl);
  redirectURL.searchParams.set("cmux_app", "1");
  redirectURL.searchParams.set("cmux_distribution", "appstore");
  redirectURL.searchParams.set("billing", "unavailable");

  for (const key of ["appearance", "background", "foreground", "accent"]) {
    const value = requestUrl.searchParams.get(key);
    if (value) redirectURL.searchParams.set(key, value);
  }
  const interval = requestUrl.searchParams.get(CHECKOUT_INTERVAL_PARAM);
  if (interval === "month" || interval === "year") {
    redirectURL.searchParams.set(CHECKOUT_INTERVAL_PARAM, interval);
  }

  return redirectURL;
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

function appPricingCheckoutEntryURL(requestOrigin: string | null): string {
  if (requestOrigin) {
    try {
      return new URL(CHECKOUT_PATH, requestOrigin).toString();
    } catch {
      return DEFAULT_APP_PRICING_CHECKOUT_URL;
    }
  }
  return DEFAULT_APP_PRICING_CHECKOUT_URL;
}

function configuredAppPricingCheckoutURL(): URL | null {
  const configured = process.env.CMUX_APP_PRICING_CHECKOUT_URL?.trim();
  if (!configured) return null;
  try {
    const target = new URL(configured);
    if (target.username || target.password || !target.hostname) return null;
    if (target.protocol === "https:") return target;
    if (
      target.protocol === "http:" &&
      ["localhost", "127.0.0.1", "[::1]"].includes(target.hostname.toLowerCase())
    ) {
      return target;
    }
  } catch {
    return null;
  }
  return null;
}

function appPricingRelayAssertion(
  target: URL,
  parameters: AppPricingCheckoutRelayParameters & {
    plan: CheckoutPlan;
    interval: CheckoutInterval;
  },
): { scheme: string; expires: string; signature: string } | null {
  const scheme = parameters.cmuxScheme.trim().toLowerCase();
  if (!isProtectedRelayScheme(scheme)) return null;
  const secret = appPricingRelaySecret();
  if (!secret) return null;
  const expires = String(
    Math.floor(Date.now() / 1000) + APP_PRICING_RELAY_TTL_SECONDS,
  );
  return {
    scheme,
    expires,
    signature: relaySignature(target, parameters, expires, secret),
  };
}

function relaySignature(
  target: URL,
  parameters: AppPricingCheckoutRelayParameters & {
    plan: CheckoutPlan;
    interval: CheckoutInterval;
  },
  expires: string,
  secret: string,
): string {
  const payload = [
    "cmux-app-pricing-relay-v1",
    target.origin,
    target.pathname,
    parameters.plan,
    parameters.interval,
    parameters.cmuxScheme,
    expires,
  ].join("\n");
  return createHmac("sha256", secret).update(payload).digest("hex");
}

function nativeReturnSignature(
  target: URL,
  nativeReturnTo: string,
  checkoutSessionId: string,
  expires: string,
  secret: string,
): string {
  const payload = [
    "cmux-app-pricing-native-return-v1",
    target.origin,
    target.pathname,
    nativeReturnTo,
    checkoutSessionId,
    expires,
  ].join("\n");
  return createHmac("sha256", secret).update(payload).digest("hex");
}

function validRelayExpiry(rawExpires: string): boolean {
  const expiresAt = Number(rawExpires);
  const now = Math.floor(Date.now() / 1000);
  return (
    Number.isSafeInteger(expiresAt)
    && expiresAt >= now - APP_PRICING_RELAY_CLOCK_SKEW_SECONDS
    && expiresAt <= now + APP_PRICING_RELAY_TTL_SECONDS
      + APP_PRICING_RELAY_CLOCK_SKEW_SECONDS
  );
}

function validCheckoutSessionId(value: string): boolean {
  return /^cs_[A-Za-z0-9_]+$/.test(value);
}

function protectedNativeReturnTo(href: string): boolean {
  try {
    const url = new URL(href);
    return isProtectedRelayScheme(url.protocol.replace(":", "").toLowerCase())
      && url.hostname === "auth-callback"
      && (url.pathname === "" || url.pathname === "/");
  } catch {
    return false;
  }
}

function appPricingRelaySecret(): string | null {
  const secret = process.env.CMUX_APP_PRICING_RELAY_SECRET?.trim();
  return secret && secret.length >= 32 ? secret : null;
}

function safeUnassertedRelayScheme(scheme: string): string {
  const normalized = scheme.trim().toLowerCase();
  return isProtectedRelayScheme(normalized) ? "cmux" : normalized;
}

function isProtectedRelayScheme(scheme: string): boolean {
  return scheme === "cmux-dev" || /^cmux-dev-[a-z0-9-]+$/.test(scheme);
}

function constantTimeHexEqual(candidate: string, expected: string): boolean {
  if (!/^[a-f0-9]{64}$/.test(candidate)) return false;
  const candidateBytes = Buffer.from(candidate, "hex");
  const expectedBytes = Buffer.from(expected, "hex");
  return candidateBytes.length === expectedBytes.length
    && timingSafeEqual(candidateBytes, expectedBytes);
}
