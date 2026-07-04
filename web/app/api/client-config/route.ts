import { checkRateLimit } from "@vercel/firewall";
import { NextResponse } from "next/server";

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

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request): Promise<Response> {
  if (process.env.VERCEL === "1") {
    const rateLimitId = process.env.CMUX_CLIENT_CONFIG_RATE_LIMIT_ID?.trim();
    if (!rateLimitId) {
      console.error("client-config.route.rate_limit_not_configured");
      return json({ error: "client_config_unavailable" }, 503);
    }

    const { error, rateLimited } = await checkRateLimit(rateLimitId, { request });
    if (rateLimited || error === "blocked") {
      return json({ error: "rate_limited" }, 429);
    }
    if (error === "not-found") {
      console.error("client-config.route.rate_limit_not_found", rateLimitId);
      return json({ error: "client_config_unavailable" }, 503);
    } else if (error) {
      console.error("client-config.route.rate_limit_error", error);
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
