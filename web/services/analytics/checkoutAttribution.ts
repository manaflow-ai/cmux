// Where a paid checkout came from.
//
// Every checkout entrypoint (the /pricing page, the in-app /app-pricing page,
// the dashboard billing page, every "Upgrade" button in the Mac app) tags its
// link with the `cmux_*` query parameters below. The checkout route reads
// them, stores them as Stripe Checkout Session and Subscription metadata, and
// PostHog receives them on `cmux_billing_checkout_started`, on the webhook
// events (`cmux_billing_checkout_completed`, `cmux_billing_subscription_*`),
// and as first-paid person properties. Attribution is analytics only: nothing
// here changes what gets sold or to whom, so unknown values are normalized,
// never rejected.
export const CHECKOUT_SOURCE_PARAM = "cmux_source";
export const CHECKOUT_PLACEMENT_PARAM = "cmux_placement";
export const CHECKOUT_CLIENT_PARAM = "cmux_client";
export const CHECKOUT_CHANNEL_PARAM = "cmux_channel";
export const CHECKOUT_APP_VERSION_PARAM = "cmux_app_version";
export const CHECKOUT_APP_BUILD_PARAM = "cmux_app_build";

/** Query parameters an entrypoint may forward unchanged to the checkout URL. */
export const CHECKOUT_ATTRIBUTION_PARAMS = [
  CHECKOUT_SOURCE_PARAM,
  CHECKOUT_PLACEMENT_PARAM,
  CHECKOUT_CLIENT_PARAM,
  CHECKOUT_CHANNEL_PARAM,
  CHECKOUT_APP_VERSION_PARAM,
  CHECKOUT_APP_BUILD_PARAM,
  "utm_source",
  "utm_medium",
  "utm_campaign",
  "utm_content",
  "utm_term",
] as const;

export type CheckoutAttributionParam = (typeof CHECKOUT_ATTRIBUTION_PARAMS)[number];

/** Web surfaces that link to checkout. Mac surfaces use `mac_*` tokens. */
export const CHECKOUT_SOURCE_PRICING_PAGE = "pricing_page";
export const CHECKOUT_SOURCE_APP_PRICING = "app_pricing";
export const CHECKOUT_SOURCE_DASHBOARD_BILLING = "dashboard_billing";
export const CHECKOUT_SOURCE_UNKNOWN = "unknown";

export const CHECKOUT_CLIENTS = ["web", "mac", "ios", "tui", "cli"] as const;
export type CheckoutClient = (typeof CHECKOUT_CLIENTS)[number];
export const CHECKOUT_CHANNELS = ["stable", "nightly", "dev", "rc", "staging"] as const;
export type CheckoutChannel = (typeof CHECKOUT_CHANNELS)[number];

export type CheckoutAttribution = {
  /** Entry surface, e.g. `pricing_page`, `mac_sidebar_badge`. */
  readonly source: string;
  /** Position inside the surface, e.g. `hero`, `compare`. */
  readonly placement: string | null;
  readonly client: CheckoutClient;
  /** Release channel of the app that opened checkout; `web` clients have none. */
  readonly channel: CheckoutChannel | null;
  readonly appVersion: string | null;
  readonly appBuild: string | null;
  /** Path of the page that linked here (Referer header), no query string. */
  readonly referrerPath: string | null;
  readonly referrerHost: string | null;
  readonly utmSource: string | null;
  readonly utmMedium: string | null;
  readonly utmCampaign: string | null;
  readonly utmContent: string | null;
  readonly utmTerm: string | null;
};

const TOKEN_MAX_LENGTH = 64;
const VERSION_MAX_LENGTH = 32;
const UTM_MAX_LENGTH = 100;
const PATH_MAX_LENGTH = 200;

/** Lowercase `[a-z0-9_.:-]` token; anything else becomes null. */
export function normalizeAttributionToken(
  raw: string | null | undefined,
  maxLength = TOKEN_MAX_LENGTH,
): string | null {
  if (typeof raw !== "string") return null;
  const value = raw.trim().toLowerCase();
  if (value.length === 0 || value.length > maxLength) return null;
  return /^[a-z0-9][a-z0-9_.:-]*$/.test(value) ? value : null;
}

function normalizeVersion(raw: string | null | undefined): string | null {
  if (typeof raw !== "string") return null;
  const value = raw.trim();
  if (value.length === 0 || value.length > VERSION_MAX_LENGTH) return null;
  return /^[A-Za-z0-9][A-Za-z0-9._+-]*$/.test(value) ? value : null;
}

function normalizeUtm(raw: string | null | undefined): string | null {
  if (typeof raw !== "string") return null;
  const value = raw.trim().slice(0, UTM_MAX_LENGTH);
  return value.length > 0 ? value : null;
}

function normalizeClient(raw: string | null | undefined): CheckoutClient {
  const token = normalizeAttributionToken(raw);
  return (CHECKOUT_CLIENTS as readonly string[]).includes(token ?? "")
    ? (token as CheckoutClient)
    : "web";
}

function normalizeChannel(raw: string | null | undefined): CheckoutChannel | null {
  const token = normalizeAttributionToken(raw);
  return (CHECKOUT_CHANNELS as readonly string[]).includes(token ?? "")
    ? (token as CheckoutChannel)
    : null;
}

function referrerParts(referer: string | null | undefined): {
  host: string | null;
  path: string | null;
} {
  if (!referer) return { host: null, path: null };
  try {
    const url = new URL(referer);
    if (url.protocol !== "http:" && url.protocol !== "https:") return { host: null, path: null };
    return {
      host: url.hostname.toLowerCase().slice(0, PATH_MAX_LENGTH),
      path: url.pathname.slice(0, PATH_MAX_LENGTH),
    };
  } catch {
    return { host: null, path: null };
  }
}

/**
 * Read attribution from a checkout request. Missing or malformed values fall
 * back to `unknown` / `web` so the funnel still counts the checkout.
 */
export function checkoutAttributionFromRequest(input: {
  readonly searchParams: URLSearchParams;
  readonly referer?: string | null;
}): CheckoutAttribution {
  const params = input.searchParams;
  const referrer = referrerParts(input.referer);
  return {
    source: normalizeAttributionToken(params.get(CHECKOUT_SOURCE_PARAM)) ?? CHECKOUT_SOURCE_UNKNOWN,
    placement: normalizeAttributionToken(params.get(CHECKOUT_PLACEMENT_PARAM)),
    client: normalizeClient(params.get(CHECKOUT_CLIENT_PARAM)),
    channel: normalizeChannel(params.get(CHECKOUT_CHANNEL_PARAM)),
    appVersion: normalizeVersion(params.get(CHECKOUT_APP_VERSION_PARAM)),
    appBuild: normalizeVersion(params.get(CHECKOUT_APP_BUILD_PARAM)),
    referrerHost: referrer.host,
    referrerPath: referrer.path,
    utmSource: normalizeUtm(params.get("utm_source")),
    utmMedium: normalizeUtm(params.get("utm_medium")),
    utmCampaign: normalizeUtm(params.get("utm_campaign")),
    utmContent: normalizeUtm(params.get("utm_content")),
    utmTerm: normalizeUtm(params.get("utm_term")),
  };
}

// Stripe metadata keys. Stripe shows them in the dashboard on the Checkout
// Session and the Subscription, and the webhook reads them back so the paid
// events carry the same attribution as the started event.
const METADATA_KEYS = {
  source: "cmuxSource",
  placement: "cmuxPlacement",
  client: "cmuxClient",
  channel: "cmuxChannel",
  appVersion: "cmuxAppVersion",
  appBuild: "cmuxAppBuild",
  referrerHost: "cmuxReferrerHost",
  referrerPath: "cmuxReferrerPath",
  utmSource: "utmSource",
  utmMedium: "utmMedium",
  utmCampaign: "utmCampaign",
  utmContent: "utmContent",
  utmTerm: "utmTerm",
} as const satisfies Record<keyof CheckoutAttribution, string>;

// PostHog property names shared by every billing event.
const PROPERTY_KEYS = {
  source: "checkout_source",
  placement: "checkout_placement",
  client: "checkout_client",
  channel: "checkout_channel",
  appVersion: "checkout_app_version",
  appBuild: "checkout_app_build",
  referrerHost: "checkout_referrer_host",
  referrerPath: "checkout_referrer_path",
  utmSource: "utm_source",
  utmMedium: "utm_medium",
  utmCampaign: "utm_campaign",
  utmContent: "utm_content",
  utmTerm: "utm_term",
} as const satisfies Record<keyof CheckoutAttribution, string>;

type AttributionKey = keyof CheckoutAttribution;
const ATTRIBUTION_KEYS = Object.keys(METADATA_KEYS) as readonly AttributionKey[];

/** Stripe metadata (strings only; null fields are omitted). */
export function checkoutAttributionMetadata(
  attribution: CheckoutAttribution,
): Record<string, string> {
  const metadata: Record<string, string> = {};
  for (const key of ATTRIBUTION_KEYS) {
    const value = attribution[key];
    if (typeof value === "string" && value.length > 0) metadata[METADATA_KEYS[key]] = value;
  }
  return metadata;
}

/**
 * Attribution as stored on a Stripe object. Sessions created before this
 * contract existed have no keys and read back as `unknown`/`web`, which keeps
 * old and new checkouts in the same breakdown.
 */
export function checkoutAttributionFromMetadata(
  metadata: Record<string, string | null | undefined> | null | undefined,
): CheckoutAttribution {
  const read = (key: AttributionKey): string | null => {
    const value = metadata?.[METADATA_KEYS[key]];
    return typeof value === "string" && value.length > 0 ? value : null;
  };
  return {
    source: normalizeAttributionToken(read("source")) ?? CHECKOUT_SOURCE_UNKNOWN,
    placement: normalizeAttributionToken(read("placement")),
    client: normalizeClient(read("client")),
    channel: normalizeChannel(read("channel")),
    appVersion: normalizeVersion(read("appVersion")),
    appBuild: normalizeVersion(read("appBuild")),
    referrerHost: read("referrerHost"),
    referrerPath: read("referrerPath"),
    utmSource: normalizeUtm(read("utmSource")),
    utmMedium: normalizeUtm(read("utmMedium")),
    utmCampaign: normalizeUtm(read("utmCampaign")),
    utmContent: normalizeUtm(read("utmContent")),
    utmTerm: normalizeUtm(read("utmTerm")),
  };
}

/** PostHog event properties. Every key is always present so breakdowns on a
 * missing value show `null` instead of silently dropping the event. */
export function checkoutAttributionProperties(
  attribution: CheckoutAttribution,
): Record<string, string | null> {
  const properties: Record<string, string | null> = {};
  for (const key of ATTRIBUTION_KEYS) {
    properties[PROPERTY_KEYS[key]] = attribution[key];
  }
  return properties;
}

/**
 * Person properties written once, on the first paid checkout, so "which
 * surface converted this customer" survives later portal visits and renewals.
 */
export function firstPaidCheckoutPersonProperties(
  attribution: CheckoutAttribution,
  paidAt: Date,
): Record<string, string | null> {
  return {
    first_paid_checkout_at: paidAt.toISOString(),
    first_paid_checkout_source: attribution.source,
    first_paid_checkout_placement: attribution.placement,
    first_paid_checkout_client: attribution.client,
    first_paid_checkout_channel: attribution.channel,
    first_paid_checkout_app_version: attribution.appVersion,
    first_paid_checkout_utm_source: attribution.utmSource,
    first_paid_checkout_utm_campaign: attribution.utmCampaign,
  };
}

/** Append attribution to a checkout link. `null` values are skipped. */
export function withCheckoutAttribution(
  href: string,
  attribution: Partial<Record<CheckoutAttributionParam, string | null | undefined>>,
): string {
  const [withoutHash, hash] = href.split("#", 2);
  const [path, query = ""] = withoutHash.split("?", 2);
  const params = new URLSearchParams(query);
  for (const name of CHECKOUT_ATTRIBUTION_PARAMS) {
    const value = attribution[name];
    if (typeof value !== "string" || value.length === 0) continue;
    params.set(name, value);
  }
  const nextQuery = params.toString();
  const nextHref = nextQuery ? `${path}?${nextQuery}` : path;
  return hash === undefined ? nextHref : `${nextHref}#${hash}`;
}

/** Copy every attribution parameter present on `from` onto `to`. */
export function forwardCheckoutAttribution(from: URLSearchParams, to: URL): void {
  for (const name of CHECKOUT_ATTRIBUTION_PARAMS) {
    const value = from.get(name);
    if (value) to.searchParams.set(name, value);
  }
}

/** Attribution parameters from a page's search params, for link building. */
export function checkoutAttributionParamsFrom(
  params: Record<string, string | string[] | undefined>,
): Partial<Record<CheckoutAttributionParam, string>> {
  const result: Partial<Record<CheckoutAttributionParam, string>> = {};
  for (const name of CHECKOUT_ATTRIBUTION_PARAMS) {
    const raw = params[name];
    const value = Array.isArray(raw) ? raw[0] : raw;
    if (typeof value === "string" && value.length > 0) result[name] = value;
  }
  return result;
}
