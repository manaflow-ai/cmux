import { createHash } from "node:crypto";

import { checkRateLimit } from "@vercel/firewall";
import { NextResponse } from "next/server";

import "../../env";
import { readBoundedJsonObject } from "../../../services/apns/routePolicy";
import { reportMissingRateLimitRule } from "../../../services/rateLimitObservability";
import {
  CLIENT_CONFIG_FLAGS_TIMEOUT_MS,
  MAX_CLIENT_CONFIG_REQUEST_BYTES,
  isPostHogFlagsResponseAvailable,
  isPostHogFlagsResponseComplete,
  normalizeClientConfigEvaluationContext,
  normalizeDistinctId,
  normalizePostHogFlagsResponse,
  postHogFlagsBody,
  postHogFlagsUrl,
} from "../../../services/client-config/posthogFlags";
import { rateLimitDeploymentPartition } from "../../../services/rateLimitPartition";
import {
  clientConfigCacheKey,
  readCachedClientConfig,
  writeCachedClientConfig,
} from "../../../services/client-config/runtimeCache";
import type { ClientConfig } from "../../../services/client-config/types";

type ClientConfigResult =
  | { readonly kind: "config"; readonly config: ClientConfig; readonly cacheStatus?: "hit" | "miss" | "coalesced" }
  | { readonly kind: "response"; readonly body: Record<string, unknown>; readonly status: number; readonly headers?: HeadersInit };

type PendingClientConfigLoad = {
  readonly operation: Promise<ClientConfigResult>;
};

const CLIENT_CONFIG_LOAD_TIMEOUT_MS = 6_000;
const MAX_IN_FLIGHT_CLIENT_CONFIG_LOADS = 128;
const pendingClientConfigLoads = new Map<string, PendingClientConfigLoad>();

export async function POST(request: Request): Promise<Response> {
  const rateLimitRequest = request.clone();
  const body = await readBoundedJsonObject(request, MAX_CLIENT_CONFIG_REQUEST_BYTES);
  if (!body.ok) {
    return json({ error: body.error }, body.error === "request_too_large" ? 413 : 400);
  }
  const distinctId = normalizeDistinctId(body.value.distinctId);
  // Admission applies to each caller, including cache hits and callers that
  // join an in-flight evaluation. Only PostHog work is shared and cached.
  const rateLimitResponse = await checkClientConfigRateLimit(rateLimitRequest, distinctId);
  if (rateLimitResponse?.kind === "response") {
    return json(rateLimitResponse.body, rateLimitResponse.status, rateLimitResponse.headers);
  }
  const context = normalizeClientConfigEvaluationContext(body.value.context);
  const cacheKey = clientConfigCacheKey(distinctId, context);
  const result = cacheKey
    ? await loadClientConfigOnce(cacheKey, async () => {
      const config = isVercelRuntime() ? await readCachedClientConfig(cacheKey) : undefined;
      // Reuse the exact evaluation after this request passes admission.
      if (config) return { kind: "config", config, cacheStatus: "hit" };
      return await fetchClientConfig(cacheKey, distinctId, context);
    })
    : await fetchClientConfig(cacheKey, distinctId, context);
  return result.kind === "config"
    ? json(result.config, 200, { "x-cmux-client-config-cache": result.cacheStatus ?? "miss" })
    : json(result.body, result.status, result.headers);
}

async function loadClientConfigOnce(
  key: string,
  load: () => Promise<ClientConfigResult>,
): Promise<ClientConfigResult> {
  const pending = pendingClientConfigLoads.get(key);
  if (pending) {
    const result = await withClientConfigDeadline(pending.operation);
    return result.kind === "config" ? { ...result, cacheStatus: "coalesced" } : result;
  }
  if (pendingClientConfigLoads.size >= MAX_IN_FLIGHT_CLIENT_CONFIG_LOADS) {
    return { kind: "response", body: { error: "client_config_unavailable" }, status: 503 };
  }

  const operation = Promise.resolve().then(load);
  const entry = { operation } satisfies PendingClientConfigLoad;
  pendingClientConfigLoads.set(key, entry);
  void operation.then(
    () => finishClientConfigLoad(key, entry),
    () => finishClientConfigLoad(key, entry),
  );

  return await withClientConfigDeadline(operation);
}

async function withClientConfigDeadline(
  operation: Promise<ClientConfigResult>,
): Promise<ClientConfigResult> {
  return await new Promise((resolve) => {
    const timer = setTimeout(() => {
      resolve({ kind: "response", body: { error: "client_config_unavailable" }, status: 503 });
    }, CLIENT_CONFIG_LOAD_TIMEOUT_MS);
    operation.then(
      (result) => {
        clearTimeout(timer);
        resolve(result);
      },
      () => {
        clearTimeout(timer);
        resolve({ kind: "response", body: { error: "client_config_unavailable" }, status: 503 });
      },
    );
  });
}

function finishClientConfigLoad(key: string, entry: PendingClientConfigLoad): void {
  if (pendingClientConfigLoads.get(key) !== entry) return;
  pendingClientConfigLoads.delete(key);
}

async function checkClientConfigRateLimit(
  request: Request,
  distinctId: string,
): Promise<ClientConfigResult | undefined> {
  // An unset rule id means no rate limiting; a deleted rule (not-found) fails
  // open rather than making client config unavailable for every app boot.
  const rateLimitId = process.env.CMUX_CLIENT_CONFIG_RATE_LIMIT_ID?.trim();
  if (process.env.VERCEL === "1" && !rateLimitId) {
    void reportMissingRateLimitRule({ route: "/api/client-config", reason: "unset" });
  }
  if (process.env.VERCEL === "1" && rateLimitId) {
    try {
      const rateLimitKey = clientConfigRateLimitKey(distinctId);
      const { error, rateLimited } = await checkRateLimit(rateLimitId, {
        request,
        rateLimitKey,
        signal: AbortSignal.timeout(1_000),
      });
      if (rateLimited || error === "blocked") {
        return { kind: "response", body: { error: "rate_limited" }, status: 429, headers: { "retry-after": "60" } };
      }
      if (error === "not-found") {
        void reportMissingRateLimitRule({ route: "/api/client-config", reason: "not-found" });
      } else if (error) {
        console.error("client-config.route.rate_limit_error", { failure: "check_error" });
        return { kind: "response", body: { error: "client_config_unavailable" }, status: 503 };
      }
    } catch {
      console.error("client-config.route.rate_limit_error", { failure: "check_failed" });
      return { kind: "response", body: { error: "client_config_unavailable" }, status: 503 };
    }
  }
  return undefined;
}

async function fetchClientConfig(
  cacheKey: string | undefined,
  distinctId: string,
  context: ReturnType<typeof normalizeClientConfigEvaluationContext>,
): Promise<ClientConfigResult> {
  try {
    const response = await fetch(postHogFlagsUrl(), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: postHogFlagsBody(distinctId, context),
      cache: "no-store",
      signal: AbortSignal.timeout(CLIENT_CONFIG_FLAGS_TIMEOUT_MS),
    });
    if (!response.ok) {
      return { kind: "response", body: { error: "client_config_unavailable" }, status: 502 };
    }

    const raw = await response.json() as unknown;
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
      return { kind: "response", body: { error: "client_config_invalid" }, status: 502 };
    }
    if (!isPostHogFlagsResponseAvailable(raw as Record<string, unknown>)) {
      return { kind: "response", body: { error: "client_config_unavailable" }, status: 502 };
    }

    const config = normalizePostHogFlagsResponse(raw as Record<string, unknown>);
    if (cacheKey && isVercelRuntime() && isPostHogFlagsResponseComplete(raw as Record<string, unknown>)) {
      // Hold the shared load until the bounded cache write finishes. A next
      // request can then read the stored value without a second local cache.
      await writeCachedClientConfig(cacheKey, config);
    }
    return { kind: "config", config };
  } catch {
    return { kind: "response", body: { error: "client_config_unavailable" }, status: 502 };
  }
}

function isVercelRuntime(): boolean {
  return process.env.VERCEL === "1" &&
    (process.env.VERCEL_ENV === "production" || process.env.VERCEL_ENV === "preview");
}

function json(
  body: Record<string, unknown>,
  status = 200,
  extraHeaders?: HeadersInit,
): Response {
  return NextResponse.json(body, {
    status,
    headers: {
      "Cache-Control": "no-store",
      ...Object.fromEntries(new Headers(extraHeaders)),
    },
  });
}

function clientConfigRateLimitKey(distinctId: string): string {
  const installPartition = createHash("sha256")
    .update(`cmux/client-config/v1\0${distinctId}`)
    .digest("hex");
  return `${rateLimitDeploymentPartition()}:${installPartition}`;
}
