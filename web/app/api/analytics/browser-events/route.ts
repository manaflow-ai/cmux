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

export async function POST(request: Request): Promise<Response> {
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
            properties: event.properties,
            timestamp: event.timestamp,
          },
        ],
      }),
    });
    if (!response.ok) {
      return { ok: false, status: response.status >= 500 ? 502 : 400 };
    }
    return { ok: true };
  } catch {
    return { ok: false, status: 502 };
  }
}
