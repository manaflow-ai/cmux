import { POSTHOG_HOST, POSTHOG_PROJECT_KEY } from "./iosEventPolicy";

export { POSTHOG_HOST, POSTHOG_PROJECT_KEY };

export const MAX_BROWSER_ANALYTICS_REQUEST_BYTES = 32 * 1024;
export const MAX_BROWSER_ANALYTICS_PROPERTIES = 64;
export const MAX_BROWSER_ANALYTICS_ARRAY_ITEMS = 20;
export const MAX_BROWSER_ANALYTICS_DEPTH = 3;
export const MAX_BROWSER_ANALYTICS_STRING_CHARS = 2048;

const ALLOWED_BROWSER_EVENTS: ReadonlySet<string> = new Set([
  "$pageview",
  "cmuxterm_download_clicked",
  "cmuxterm_github_clicked",
  "cmuxterm_pricing_nav_clicked",
  "cmuxterm_pro_cta_clicked",
  "cmuxterm_waitlist_opened",
  "cmuxterm_waitlist_signup",
  "compare_back_clicked",
  "compare_link_clicked",
  "guide_link_clicked",
]);

export type BrowserAnalyticsValue =
  | string
  | number
  | boolean
  | null
  | readonly BrowserAnalyticsValue[]
  | { readonly [key: string]: BrowserAnalyticsValue };

export type BrowserAnalyticsEvent = {
  readonly event: string;
  readonly distinctId: string;
  readonly properties: Record<string, BrowserAnalyticsValue>;
  readonly timestamp?: string;
};

export type BrowserAnalyticsEventResult =
  | { readonly ok: true; readonly value: BrowserAnalyticsEvent }
  | { readonly ok: false; readonly error: string };

export function parseBrowserAnalyticsEvent(
  body: Record<string, unknown>,
): BrowserAnalyticsEventResult {
  if (!isAllowedBrowserAnalyticsEvent(body.event)) {
    return { ok: false, error: "unknown_event" };
  }

  const distinctId = boundedString(body.distinctId, 512);
  if (!distinctId) {
    return { ok: false, error: "missing_distinct_id" };
  }

  const rawProperties =
    body.properties && typeof body.properties === "object" && !Array.isArray(body.properties)
      ? (body.properties as Record<string, unknown>)
      : {};
  const properties = sanitizeProperties(rawProperties);
  const timestamp = boundedString(body.timestamp, 64);

  return {
    ok: true,
    value: {
      event: body.event,
      distinctId,
      properties,
      timestamp: timestamp || undefined,
    },
  };
}

export function isAllowedBrowserAnalyticsEvent(name: unknown): name is string {
  return typeof name === "string" && ALLOWED_BROWSER_EVENTS.has(name);
}

function sanitizeProperties(
  rawProperties: Record<string, unknown>,
): Record<string, BrowserAnalyticsValue> {
  const properties: Record<string, BrowserAnalyticsValue> = {};
  let count = 0;
  for (const [key, value] of Object.entries(rawProperties)) {
    if (count >= MAX_BROWSER_ANALYTICS_PROPERTIES) break;
    const sanitizedKey = boundedString(key, 128);
    if (!sanitizedKey) continue;
    const sanitizedValue = sanitizeValue(value, 0);
    if (sanitizedValue === undefined) continue;
    properties[sanitizedKey] = sanitizedValue;
    count += 1;
  }
  return properties;
}

function sanitizeValue(
  value: unknown,
  depth: number,
): BrowserAnalyticsValue | undefined {
  if (value === null) return null;
  if (typeof value === "boolean") return value;
  if (typeof value === "number") return Number.isFinite(value) ? value : undefined;
  if (typeof value === "string") return value.slice(0, MAX_BROWSER_ANALYTICS_STRING_CHARS);
  if (depth >= MAX_BROWSER_ANALYTICS_DEPTH) return undefined;
  if (Array.isArray(value)) {
    const items: BrowserAnalyticsValue[] = [];
    for (const item of value.slice(0, MAX_BROWSER_ANALYTICS_ARRAY_ITEMS)) {
      const sanitized = sanitizeValue(item, depth + 1);
      if (sanitized !== undefined) items.push(sanitized);
    }
    return items;
  }
  if (typeof value === "object") {
    const result: Record<string, BrowserAnalyticsValue> = {};
    for (const [key, nested] of Object.entries(value as Record<string, unknown>)) {
      const sanitizedKey = boundedString(key, 128);
      if (!sanitizedKey) continue;
      const sanitized = sanitizeValue(nested, depth + 1);
      if (sanitized !== undefined) result[sanitizedKey] = sanitized;
    }
    return result;
  }
  return undefined;
}

function boundedString(value: unknown, maxChars: number): string | null {
  if (typeof value !== "string") return null;
  const text = value.trim();
  if (!text || text.length > maxChars) return null;
  return text;
}
