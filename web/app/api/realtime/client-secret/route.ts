import { checkRateLimit } from "@vercel/firewall";
import * as Effect from "effect/Effect";

import {
  enforceRealtimeRateLimit,
  mintRealtimeClientSecret,
  type RealtimeProviderFetch,
  type RealtimeRateLimitCheck,
} from "../../../../services/realtime/clientSecret";
import type { RealtimeServiceError } from "../../../../services/realtime/errors";
import {
  unauthorized,
  verifyRequest,
  type AuthedUser,
} from "../../../../services/vms/auth";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export interface RealtimeClientSecretRouteDeps {
  readonly verifyRequest: (request: Request) => Promise<AuthedUser | null>;
  readonly providerFetch: RealtimeProviderFetch;
  readonly checkRateLimit: RealtimeRateLimitCheck;
  readonly apiKey: () => string | undefined;
  readonly rateLimitRuleID: () => string | undefined;
  readonly isVercel: () => boolean;
  readonly nowSeconds: () => number;
}

const productionDeps: RealtimeClientSecretRouteDeps = {
  verifyRequest: (request) => verifyRequest(request, { allowCookie: false }),
  providerFetch: fetch,
  checkRateLimit,
  apiKey: () => process.env.OPENAI_API_KEY,
  rateLimitRuleID: () => process.env.CMUX_REALTIME_SESSION_RATE_LIMIT_ID,
  isVercel: () => process.env.VERCEL === "1",
  nowSeconds: () => Math.floor(Date.now() / 1_000),
};

export async function handleRealtimeClientSecretRequest(
  request: Request,
  deps: RealtimeClientSecretRouteDeps,
): Promise<Response> {
  const user = await deps.verifyRequest(request);
  if (!user) return unauthorized();

  const program = Effect.gen(function* () {
    yield* enforceRealtimeRateLimit({
      request,
      userID: user.id,
      ruleID: deps.rateLimitRuleID(),
      isVercel: deps.isVercel(),
      check: deps.checkRateLimit,
    });
    return yield* mintRealtimeClientSecret({
      apiKey: deps.apiKey(),
      userID: user.id,
      nowSeconds: deps.nowSeconds(),
      fetch: deps.providerFetch,
    });
  });
  const result = await Effect.runPromise(Effect.either(program));
  if (result._tag === "Left") return realtimeErrorResponse(result.left);
  return jsonResponse({
    value: result.right.value,
    expires_at: result.right.expiresAt,
    model: result.right.model,
  });
}

function realtimeErrorResponse(error: RealtimeServiceError): Response {
  switch (error._tag) {
  case "RealtimeRateLimitError":
    return jsonResponse(
      { error: error.code },
      error.code === "rate_limited" ? 429 : 503,
      error.retryAfterSeconds
        ? { "retry-after": String(error.retryAfterSeconds) }
        : undefined,
    );
  case "RealtimeConfigurationError":
    console.error("realtime.client_secret.configuration", {
      code: error.code,
    });
    return jsonResponse({ error: "voice_unavailable" }, 503);
  case "RealtimeProviderError":
    console.error("realtime.client_secret.provider", {
      code: error.code,
      status: error.status,
    });
    return jsonResponse({ error: "voice_unavailable" }, 502);
  }
}

function jsonResponse(
  data: unknown,
  status = 200,
  extraHeaders?: HeadersInit,
): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "content-type": "application/json",
      "cache-control": "no-store",
      ...Object.fromEntries(new Headers(extraHeaders)),
    },
  });
}

export function POST(request: Request): Promise<Response> {
  return handleRealtimeClientSecretRequest(request, productionDeps);
}
