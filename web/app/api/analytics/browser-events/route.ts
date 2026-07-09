import { checkRateLimit } from "@vercel/firewall";

import { jsonResponse } from "../../../../services/vms/routeHelpers";
import { readBoundedJsonObject } from "../../../../services/apns/routePolicy";
import {
  WAITLIST_EARLY_ACCESS_FLAGS,
  WAITLIST_PLATFORMS,
  type WaitlistPlatform,
} from "../../../lib/download";
import {
  type BrowserAnalyticsEvent,
  MAX_BROWSER_ANALYTICS_REQUEST_BYTES,
  POSTHOG_HOST,
  POSTHOG_PROJECT_KEY,
  parseBrowserAnalyticsEvent,
} from "../../../../services/analytics/browserEventPolicy";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const BROWSER_ANALYTICS_FORWARD_TIMEOUT_MS = 3_000;
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export async function POST(request: Request): Promise<Response> {
  if (process.env.VERCEL === "1") {
    const rateLimitId = process.env.CMUX_BROWSER_ANALYTICS_RATE_LIMIT_ID?.trim();
    if (!rateLimitId) {
      console.error("browser-events.route.rate_limit_not_configured");
      return jsonResponse({ error: "analytics_unavailable" }, 503);
    }

    const { error, rateLimited } = await checkRateLimit(rateLimitId, { request });
    if (rateLimited || error === "blocked") {
      return jsonResponse({ error: "rate_limited" }, 429);
    }
    if (error === "not-found") {
      console.error("browser-events.route.rate_limit_not_found", rateLimitId);
      return jsonResponse({ error: "analytics_unavailable" }, 503);
    } else if (error) {
      console.error("browser-events.route.rate_limit_error", error);
      return jsonResponse({ error: "analytics_unavailable" }, 503);
    }
  }

  const body = await readBoundedJsonObject(request, MAX_BROWSER_ANALYTICS_REQUEST_BYTES);
  if (!body.ok) {
    return jsonResponse({ error: body.error }, body.error === "request_too_large" ? 413 : 400);
  }

  const event = parseBrowserAnalyticsEvent(body.value);
  if (!event.ok) {
    return jsonResponse({ error: event.error }, 400);
  }

  const prepared = prepareBrowserEvent(event.value);
  if (!prepared.ok) {
    return jsonResponse({ error: prepared.error }, 400);
  }

  const forwarded = await forwardBrowserEvent(prepared.value);
  if (!forwarded.ok) {
    return jsonResponse({ error: "forward_failed" }, forwarded.status);
  }
  return jsonResponse({ ok: true });
}

async function forwardBrowserEvent(event: {
  readonly event: string;
  readonly distinctId: string;
  readonly properties: Record<string, unknown>;
  readonly timestamp?: string;
}): Promise<{ readonly ok: true } | { readonly ok: false; readonly status: number }> {
  try {
    const response = await fetch(`${POSTHOG_HOST}/batch/`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        api_key: POSTHOG_PROJECT_KEY,
        batch: [
          {
            event: event.event,
            distinct_id: event.distinctId,
            properties: event.properties,
            timestamp: event.timestamp,
          },
        ],
      }),
      signal: AbortSignal.timeout(BROWSER_ANALYTICS_FORWARD_TIMEOUT_MS),
    });
    if (!response.ok) {
      return { ok: false, status: response.status >= 500 ? 502 : 400 };
    }
    return { ok: true };
  } catch {
    return { ok: false, status: 502 };
  }
}

function prepareBrowserEvent(
  event: BrowserAnalyticsEvent,
): { readonly ok: true; readonly value: BrowserAnalyticsEvent }
  | { readonly ok: false; readonly error: string } {
  if (event.event === "cmuxterm_waitlist_signup") {
    return prepareWaitlistSignupEvent(event);
  }

  return {
    ok: true,
    value: {
      ...event,
      properties: {
        ...event.properties,
        $process_person_profile: false,
      },
    },
  };
}

function prepareWaitlistSignupEvent(
  event: BrowserAnalyticsEvent,
): { readonly ok: true; readonly value: BrowserAnalyticsEvent }
  | { readonly ok: false; readonly error: string } {
  const email = waitlistEmail(event.properties.email);
  if (!email || event.distinctId !== email) {
    return { ok: false, error: "invalid_waitlist_signup" };
  }

  const platforms = waitlistPlatforms(event.properties.platforms);
  if (!platforms) {
    return { ok: false, error: "invalid_waitlist_signup" };
  }

  const location = waitlistLocation(event.properties.location);
  const enrollment = Object.fromEntries(
    platforms.map((platform) => [
      `$feature_enrollment/${WAITLIST_EARLY_ACCESS_FLAGS[platform]}`,
      true,
    ]),
  );

  return {
    ok: true,
    value: {
      ...event,
      properties: {
        email,
        platforms,
        ...(location ? { location } : {}),
        $set: { email, ...enrollment },
        $set_once: { waitlist_email: email },
      },
    },
  };
}

function waitlistEmail(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const email = value.trim();
  return email.length <= 320 && EMAIL_PATTERN.test(email) ? email : null;
}

function waitlistLocation(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const location = value.trim();
  return location ? location.slice(0, 64) : null;
}

function waitlistPlatforms(value: unknown): WaitlistPlatform[] | null {
  if (!Array.isArray(value)) return null;
  const platforms = Array.from(new Set(value));
  if (platforms.length < 1 || platforms.length > WAITLIST_PLATFORMS.length) return null;
  return platforms.every(isWaitlistPlatform) ? platforms : null;
}

function isWaitlistPlatform(value: unknown): value is WaitlistPlatform {
  return typeof value === "string" && WAITLIST_PLATFORMS.includes(value as WaitlistPlatform);
}
