import { checkRateLimit } from "@vercel/firewall";

import { jsonResponse } from "../../../../services/vms/routeHelpers";
import { readBoundedJsonObject } from "../../../../services/apns/routePolicy";
import {
  MAX_BROWSER_ANALYTICS_REQUEST_BYTES,
  POSTHOG_HOST,
  POSTHOG_PROJECT_KEY,
  parseBrowserAnalyticsEvent,
} from "../../../../services/analytics/browserEventPolicy";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const BROWSER_ANALYTICS_FORWARD_TIMEOUT_MS = 3_000;

export async function POST(request: Request): Promise<Response> {
  if (process.env.VERCEL === "1") {
    const rateLimitId = process.env.CMUX_CLIENT_CONFIG_RATE_LIMIT_ID?.trim();
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

  const forwarded = await forwardBrowserEvent(event.value);
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
            properties: postHogProperties(event),
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

function postHogProperties(event: {
  readonly event: string;
  readonly properties: Record<string, unknown>;
}): Record<string, unknown> {
  if (event.event === "cmuxterm_waitlist_signup") {
    return event.properties;
  }

  return {
    ...event.properties,
    $process_person_profile: false,
  };
}
