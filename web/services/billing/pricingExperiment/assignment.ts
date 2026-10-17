// Variant assignment for `web-pricing-v1`, run by the proxy on every English
// /pricing request (document, RSC navigation and prefetch alike, so a
// prefetched page never disagrees with the cookie).
//
// The proxy is synchronous and must not wait on the network, so the flag
// definition is evaluated locally: a module cache holds the last definition
// read from PostHog's local-evaluation endpoint and is refreshed in the
// background at most once a minute. Until the first read succeeds (a cold
// instance, a PostHog outage, or a missing key) the experiment is off:
// everyone gets control and nothing counts as an exposure.
//
// Bucketing hashes the PostHog distinct id with PostHog's own algorithm, so a
// visitor PostHog already knows gets the variant PostHog would give them. A
// first-time visitor has no PostHog id yet; a random id is hashed instead.
// Either way the result is pinned in the `cmux_wp1` cookie, so later traffic
// changes by the optimizer never move a visitor to another arm. Pausing the
// experiment (flag inactive) sends everyone to control without clearing the
// pin, so resuming restores each visitor's arm.

import { POSTHOG_PROJECT_KEY } from "../../analytics/iosEventPolicy";
import {
  WEB_PRICING_CONTROL_VARIANT,
  WEB_PRICING_EXPERIMENT,
  renderableWebPricingVariant,
} from "./webPricingV1";

export type WebPricingFlagConfig = {
  readonly active: boolean;
  /** Variant keys with their traffic percentage, in flag order. */
  readonly variants: readonly { readonly key: string; readonly rolloutPercentage: number }[];
  /** Rollout of the single unfiltered condition group, 0-100. */
  readonly rolloutPercentage: number;
};

export type WebPricingAssignment =
  | { readonly inExperiment: false; readonly variant: typeof WEB_PRICING_CONTROL_VARIANT; readonly reason: "bot" | "unconfigured" | "paused" | "unsupported_flag" | "not_in_rollout" }
  | { readonly inExperiment: true; readonly variant: string; readonly sticky: boolean };

const BOT_USER_AGENT = /bot|crawl|spider|slurp|facebookexternalhit|embedly|quora link preview|whatsapp|telegram|discord|preview|headless|lighthouse|pagespeed|gtmetrix|curl\/|wget\/|python-requests|python-urllib|httpx|go-http-client|okhttp|axios\/|node-fetch|undici|java\/|libwww|scrapy|phantomjs|selenium|playwright|puppeteer/i;

/** Crawlers, link unfurlers, monitors and scripts. An empty user agent counts as a bot. */
export function isBotUserAgent(userAgent: string | null | undefined): boolean {
  if (!userAgent || userAgent.trim().length === 0) return true;
  return BOT_USER_AGENT.test(userAgent);
}

// PostHog's local evaluation hash: sha1("<flag>.<distinct id><salt>"), first
// 15 hex digits over 0xfffffffffffffff (posthog-node computes it as a float,
// and so does this).
const LONG_SCALE = 0xfffffffffffffff;

function flagHash(key: string, distinctId: string, salt: string): number {
  return parseInt(sha1Hex(`${key}.${distinctId}${salt}`).slice(0, 15), 16) / LONG_SCALE;
}

/** PostHog's multivariate variant for `distinctId`, or null outside the rollout. */
export function postHogVariant(config: WebPricingFlagConfig, distinctId: string, flagKey = WEB_PRICING_EXPERIMENT): string | null {
  if (flagHash(flagKey, distinctId, "") > config.rolloutPercentage / 100) return null;
  const hash = flagHash(flagKey, distinctId, "variant");
  let low = 0;
  for (const variant of config.variants) {
    const high = low + variant.rolloutPercentage / 100;
    if (hash >= low && hash < high) return variant.key;
    low = high;
  }
  return null;
}

/**
 * The decision for one request. `pinned` is the `cmux_wp1` cookie;
 * `distinctId` is the PostHog id from its cookie, or a fresh random id.
 */
export function assignWebPricingVariant(input: {
  readonly config: WebPricingFlagConfig | null | "unsupported";
  readonly userAgent: string | null;
  readonly pinned: string | null;
  readonly distinctId: string;
}): WebPricingAssignment {
  if (isBotUserAgent(input.userAgent)) return { inExperiment: false, variant: WEB_PRICING_CONTROL_VARIANT, reason: "bot" };
  if (input.config === "unsupported") return { inExperiment: false, variant: WEB_PRICING_CONTROL_VARIANT, reason: "unsupported_flag" };
  if (!input.config) return { inExperiment: false, variant: WEB_PRICING_CONTROL_VARIANT, reason: "unconfigured" };
  if (!input.config.active) return { inExperiment: false, variant: WEB_PRICING_CONTROL_VARIANT, reason: "paused" };
  const flagKeys = new Set(input.config.variants.map((variant) => variant.key));
  // A pin survives allocation changes (even to 0%); it is dropped only when
  // the variant leaves the flag or no longer passes the copy validator.
  if (input.pinned && flagKeys.has(input.pinned) && renderableWebPricingVariant(input.pinned)) {
    return { inExperiment: true, variant: input.pinned, sticky: true };
  }
  // Outside the rollout, or drawn into a flag variant this code does not
  // define: not in the experiment at all, so control is not inflated with
  // people the flag never assigned to it.
  const drawn = postHogVariant(input.config, input.distinctId);
  if (!drawn || !renderableWebPricingVariant(drawn)) {
    return { inExperiment: false, variant: WEB_PRICING_CONTROL_VARIANT, reason: "not_in_rollout" };
  }
  return { inExperiment: true, variant: drawn, sticky: false };
}

/** Parse one flag from PostHog's local-evaluation response. */
export function parseWebPricingFlag(body: unknown, flagKey = WEB_PRICING_EXPERIMENT): WebPricingFlagConfig | "unsupported" | null {
  const flags = (body as { flags?: unknown } | null)?.flags;
  if (!Array.isArray(flags)) return null;
  const flag = flags.find((item) => (item as { key?: unknown })?.key === flagKey) as Record<string, unknown> | undefined;
  if (!flag) return null;
  const filters = (flag.filters ?? {}) as Record<string, unknown>;
  const groups = Array.isArray(filters.groups) ? filters.groups as Record<string, unknown>[] : [];
  const variants = ((filters.multivariate as { variants?: unknown } | undefined)?.variants);
  // Only one unfiltered condition group is evaluated here. Anything richer
  // (person properties, cohorts, several groups) fails closed to control.
  if (groups.length !== 1 || (Array.isArray(groups[0]!.properties) && groups[0]!.properties.length > 0) || groups[0]!.variant) {
    return "unsupported";
  }
  if (!Array.isArray(variants) || variants.length === 0) return "unsupported";
  const parsed = variants.map((variant) => ({
    key: String((variant as { key?: unknown }).key ?? ""),
    rolloutPercentage: Number((variant as { rollout_percentage?: unknown }).rollout_percentage ?? 0),
  }));
  if (parsed.some((variant) => !variant.key || !Number.isFinite(variant.rolloutPercentage) || variant.rolloutPercentage < 0)) return "unsupported";
  const rollout = groups[0]!.rollout_percentage;
  return {
    active: flag.active === true && flag.deleted !== true,
    variants: parsed,
    rolloutPercentage: typeof rollout === "number" ? rollout : 100,
  };
}

// --- Background-refreshed flag cache -------------------------------------

const REFRESH_INTERVAL_MS = 60_000;
/** A definition older than this is not trusted: the experiment turns off. */
const MAX_STALE_MS = 15 * 60_000;
const FETCH_TIMEOUT_MS = 3_000;

type CacheState = {
  config: WebPricingFlagConfig | "unsupported" | null;
  readAt: number;
  attemptedAt: number;
  inFlight: Promise<void> | null;
};

const cache: CacheState = { config: null, readAt: 0, attemptedAt: 0, inFlight: null };

function postHogApiHost(env: Record<string, string | undefined>): string {
  return (env.POSTHOG_API_HOST ?? "https://us.posthog.com").replace(/\/$/, "");
}

async function refreshFlagConfig(env: Record<string, string | undefined>, fetchImpl: typeof fetch): Promise<void> {
  const key = env.POSTHOG_PERSONAL_API_KEY?.trim();
  if (!key) return;
  try {
    const response = await fetchImpl(
      `${postHogApiHost(env)}/api/feature_flag/local_evaluation?token=${encodeURIComponent(POSTHOG_PROJECT_KEY)}`,
      { headers: { Authorization: `Bearer ${key}` }, cache: "no-store", signal: AbortSignal.timeout(FETCH_TIMEOUT_MS) },
    );
    if (!response.ok) return;
    cache.config = parseWebPricingFlag(await response.json());
    cache.readAt = Date.now();
  } catch {
    // Keep the last good definition until it is too old.
  }
}

/**
 * The cached definition, scheduling a background refresh when due. Returns
 * null while nothing fresh enough has been read.
 */
export function cachedWebPricingFlag(options: {
  readonly now?: number;
  readonly env?: Record<string, string | undefined>;
  readonly fetchImpl?: typeof fetch;
  readonly waitUntil?: (promise: Promise<unknown>) => void;
} = {}): WebPricingFlagConfig | "unsupported" | null {
  const now = options.now ?? Date.now();
  const env = options.env ?? process.env;
  if (!cache.inFlight && now - cache.attemptedAt >= REFRESH_INTERVAL_MS && env.NODE_ENV !== "test") {
    cache.attemptedAt = now;
    const refresh = refreshFlagConfig(env, options.fetchImpl ?? fetch).finally(() => {
      cache.inFlight = null;
    });
    cache.inFlight = refresh;
    options.waitUntil?.(refresh);
  }
  return now - cache.readAt <= MAX_STALE_MS ? cache.config : null;
}

/** Test seam: install a definition as if it had just been read. */
export function setWebPricingFlagForTesting(config: WebPricingFlagConfig | "unsupported" | null, readAt = Date.now()): void {
  cache.config = config;
  cache.readAt = config ? readAt : 0;
  cache.attemptedAt = readAt;
}

/** The distinct id posthog-js stored in its cookie (`ph_<key>_posthog`), if any. */
export function postHogDistinctIdFromCookie(cookieValue: string | null | undefined): string | null {
  if (!cookieValue) return null;
  try {
    const parsed = JSON.parse(decodeURIComponent(cookieValue)) as { distinct_id?: unknown };
    return typeof parsed.distinct_id === "string" && parsed.distinct_id.length > 0 && parsed.distinct_id.length <= 200
      ? parsed.distinct_id
      : null;
  } catch {
    return null;
  }
}

export const POSTHOG_PERSISTENCE_COOKIE = `ph_${POSTHOG_PROJECT_KEY}_posthog`;

// --- SHA-1 -----------------------------------------------------------------
// The proxy hashes synchronously and must not depend on a Node built-in, so
// this is a small FIPS 180-4 SHA-1 over UTF-8.

function sha1Hex(message: string): string {
  const bytes = new TextEncoder().encode(message);
  const bitLength = bytes.length * 8;
  const paddedLength = (((bytes.length + 8) >> 6) + 1) << 6;
  const block = new Uint8Array(paddedLength);
  block.set(bytes);
  block[bytes.length] = 0x80;
  const view = new DataView(block.buffer);
  view.setUint32(paddedLength - 8, Math.floor(bitLength / 0x100000000));
  view.setUint32(paddedLength - 4, bitLength >>> 0);
  let h0 = 0x67452301, h1 = 0xefcdab89, h2 = 0x98badcfe, h3 = 0x10325476, h4 = 0xc3d2e1f0;
  const w = new Uint32Array(80);
  for (let offset = 0; offset < paddedLength; offset += 64) {
    for (let i = 0; i < 16; i += 1) w[i] = view.getUint32(offset + i * 4);
    for (let i = 16; i < 80; i += 1) {
      const x = w[i - 3]! ^ w[i - 8]! ^ w[i - 14]! ^ w[i - 16]!;
      w[i] = (x << 1) | (x >>> 31);
    }
    let a = h0, b = h1, c = h2, d = h3, e = h4;
    for (let i = 0; i < 80; i += 1) {
      const [f, k] = i < 20
        ? [(b & c) | (~b & d), 0x5a827999]
        : i < 40
          ? [b ^ c ^ d, 0x6ed9eba1]
          : i < 60
            ? [(b & c) | (b & d) | (c & d), 0x8f1bbcdc]
            : [b ^ c ^ d, 0xca62c1d6];
      const temp = (((a << 5) | (a >>> 27)) + f + e + k + w[i]!) >>> 0;
      e = d;
      d = c;
      c = ((b << 30) | (b >>> 2)) >>> 0;
      b = a;
      a = temp;
    }
    h0 = (h0 + a) >>> 0;
    h1 = (h1 + b) >>> 0;
    h2 = (h2 + c) >>> 0;
    h3 = (h3 + d) >>> 0;
    h4 = (h4 + e) >>> 0;
  }
  return [h0, h1, h2, h3, h4].map((h) => h.toString(16).padStart(8, "0")).join("");
}

/** Exposed for the behavior test that checks PostHog's published hash vectors. */
export const sha1HexForTesting = sha1Hex;
