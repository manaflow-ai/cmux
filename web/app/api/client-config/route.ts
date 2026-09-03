import { checkRateLimit } from "@vercel/firewall";
import { NextResponse } from "next/server";

import "../../env";
import { readBoundedJsonObject } from "../../../services/apns/routePolicy";
import {
  CLIENT_CONFIG_FLAGS_TIMEOUT_MS,
  MAX_CLIENT_CONFIG_REQUEST_BYTES,
  isPostHogFlagsResponseAvailable,
  normalizeClientConfigEvaluationContext,
  normalizeDistinctId,
  normalizePostHogFlagsResponse,
  postHogFlagsBody,
  postHogFlagsUrl,
} from "../../../services/client-config/posthogFlags";
import { readClientConfigRequestAttribution } from "../../../services/client-config/requestAttribution";


export async function POST(request: Request): Promise<Response> {
  const startedAtMs = Date.now();
  const attribution = readClientConfigRequestAttribution(request.headers);
  const response = await handleClientConfigRequest(request);
  // One structured line per request. This log is the per-client request
  // counter: PostHog billing exposes only a daily project-wide flag-request
  // total, so client/channel/version/reason attribution has to be recorded
  // here, before the request loses its origin. Fields are allowlist-normalized
  // in readClientConfigRequestAttribution; nothing user-identifying is logged.
  console.log("client-config.route.request", {
    ...attribution,
    status: response.status,
    durationMs: Date.now() - startedAtMs,
  });
  return response;
}

async function handleClientConfigRequest(request: Request): Promise<Response> {
  // An unset rule id means no rate limiting; a deleted rule (not-found) fails
  // open rather than making client config unavailable for every app boot.
  const rateLimitId = process.env.CMUX_CLIENT_CONFIG_RATE_LIMIT_ID?.trim();
  if (process.env.VERCEL === "1" && rateLimitId) {
    try {
      const { error, rateLimited } = await checkRateLimit(rateLimitId, { request });
      if (rateLimited || error === "blocked") {
        return json({ error: "rate_limited" }, 429);
      }
      if (error === "not-found") {
        console.warn("client-config.route.rate_limit_not_found; failing open", rateLimitId);
      } else if (error) {
        console.error("client-config.route.rate_limit_error", { failure: "check_error" });
        return json({ error: "client_config_unavailable" }, 503);
      }
    } catch {
      console.error("client-config.route.rate_limit_error", { failure: "check_failed" });
      return json({ error: "client_config_unavailable" }, 503);
    }
  }

  const body = await readBoundedJsonObject(request, MAX_CLIENT_CONFIG_REQUEST_BYTES);
  if (!body.ok) {
    return json({ error: body.error }, body.error === "request_too_large" ? 413 : 400);
  }

  const distinctId = normalizeDistinctId(body.value.distinctId);
  const context = normalizeClientConfigEvaluationContext(body.value.context);
  try {
    const response = await fetch(postHogFlagsUrl(), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: postHogFlagsBody(distinctId, context),
      cache: "no-store",
      signal: AbortSignal.timeout(CLIENT_CONFIG_FLAGS_TIMEOUT_MS),
    });
    if (!response.ok) {
      return json({ error: "client_config_unavailable" }, 502);
    }

    const raw = await response.json() as unknown;
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
      return json({ error: "client_config_invalid" }, 502);
    }
    if (!isPostHogFlagsResponseAvailable(raw as Record<string, unknown>)) {
      return json({ error: "client_config_unavailable" }, 502);
    }

    return json(normalizePostHogFlagsResponse(raw as Record<string, unknown>));
  } catch {
    return json({ error: "client_config_unavailable" }, 502);
  }
}

function json(body: Record<string, unknown>, status = 200): Response {
  return NextResponse.json(body, {
    status,
    headers: {
      "Cache-Control": "no-store",
    },
  });
}
