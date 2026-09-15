import { createHash } from "node:crypto";

import { waitUntil } from "@vercel/functions";
import { checkRateLimit } from "@vercel/firewall";
import { NextResponse } from "next/server";

import "../../env";
import { readBoundedJsonObject } from "../../../services/apns/routePolicy";
import { reportMissingRateLimitRule } from "../../../services/rateLimitObservability";
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
import { rateLimitDeploymentPartition } from "../../../services/rateLimitPartition";
import { checkAbortableRateLimit } from "../../../services/client-config/abortableRateLimit";
import {
  clientConfigCacheKey,
  isCompleteClientConfig,
  readCachedClientConfig,
  writeCachedClientConfig,
} from "../../../services/client-config/runtimeCache";
import type { ClientConfig } from "../../../services/client-config/types";

type ClientConfigResult =
  | { readonly kind: "config"; readonly config: ClientConfig; readonly cacheStatus?: "miss" | "coalesced" }
  | { readonly kind: "response"; readonly body: Record<string, unknown>; readonly status: number; readonly headers?: HeadersInit };

type PendingClientConfigLoad = {
  readonly operation: Promise<ClientConfigResult>;
};

const CLIENT_CONFIG_LOCAL_CACHE_TTL_MS = 5 * 60 * 1000;
const CLIENT_CONFIG_LOAD_TIMEOUT_MS = 5_000;
const MAX_COMPLETED_CLIENT_CONFIGS = 256;
const MAX_IN_FLIGHT_CLIENT_CONFIG_LOADS = 128;
const completedClientConfigLoads = new Map<string, { readonly config: ClientConfig; readonly expiresAt: number }>();
const pendingClientConfigLoads = new Map<string, PendingClientConfigLoad>();
let inFlightClientConfigLoads = 0;

export async function POST(request: Request): Promise<Response> {
  const rateLimitRequest = request.clone();
  const body = await readBoundedJsonObject(request, MAX_CLIENT_CONFIG_REQUEST_BYTES);
  if (!body.ok) {
    return json({ error: body.error }, body.error === "request_too_large" ? 413 : 400);
  }
  const distinctId = normalizeDistinctId(body.value.distinctId);
  const context = normalizeClientConfigEvaluationContext(body.value.context);
  const cacheKey = clientConfigCacheKey(distinctId, context);
  const localConfig = cacheKey && isVercelRuntime()
    ? readLocalClientConfig(cacheKey)
    : undefined;
  if (localConfig) return json(localConfig, 200, { "x-cmux-client-config-cache": "hit" });
  const cachedConfig = cacheKey ? await readCachedClientConfig(cacheKey) : undefined;
  // A complete, exact-evaluation hit has no downstream work left to protect.
  // Return it before Firewall so repeated polls do not consume the durable
  // limiter budget or call PostHog again.
  if (cachedConfig) {
    return json(cachedConfig, 200, { "x-cmux-client-config-cache": "hit" });
  }

  const result = cacheKey
    ? await loadClientConfigOnce(cacheKey, () => fetchClientConfig(rateLimitRequest, cacheKey, distinctId, context))
    : await fetchClientConfig(rateLimitRequest, cacheKey, distinctId, context);
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
  if (inFlightClientConfigLoads >= MAX_IN_FLIGHT_CLIENT_CONFIG_LOADS) {
    return { kind: "response", body: { error: "client_config_unavailable" }, status: 503 };
  }

  const operation = Promise.resolve().then(load);
  const entry = { operation } satisfies PendingClientConfigLoad;
  pendingClientConfigLoads.set(key, entry);
  inFlightClientConfigLoads += 1;
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
  inFlightClientConfigLoads = Math.max(0, inFlightClientConfigLoads - 1);
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
      const { error, rateLimited } = process.env.NODE_ENV === "production" &&
        !("mock" in checkRateLimit)
        ? await checkAbortableRateLimit(rateLimitId, request, rateLimitKey)
        : await checkRateLimit(rateLimitId, { request, rateLimitKey });
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
  request: Request,
  cacheKey: string | undefined,
  distinctId: string,
  context: ReturnType<typeof normalizeClientConfigEvaluationContext>,
): Promise<ClientConfigResult> {
  const rateLimitResponse = await checkClientConfigRateLimit(request, distinctId);
  if (rateLimitResponse) return rateLimitResponse;
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
    if (cacheKey && isVercelRuntime()) {
      rememberLocalClientConfig(cacheKey, config);
      scheduleClientConfigCacheWrite(cacheKey, config);
    }
    return { kind: "config", config };
  } catch {
    return { kind: "response", body: { error: "client_config_unavailable" }, status: 502 };
  }
}

function scheduleClientConfigCacheWrite(key: string, config: ClientConfig): void {
  const write = writeCachedClientConfig(key, config);
  try {
    waitUntil(write);
  } catch {
    void write;
  }
}

function readLocalClientConfig(key: string): ClientConfig | undefined {
  const entry = completedClientConfigLoads.get(key);
  if (!entry) return undefined;
  if (entry.expiresAt <= Date.now()) {
    completedClientConfigLoads.delete(key);
    return undefined;
  }
  return entry.config;
}

function rememberLocalClientConfig(key: string, config: ClientConfig): void {
  if (!isCompleteClientConfig(config)) return;
  completedClientConfigLoads.delete(key);
  completedClientConfigLoads.set(key, {
    config,
    expiresAt: Date.now() + CLIENT_CONFIG_LOCAL_CACHE_TTL_MS,
  });
  while (completedClientConfigLoads.size > MAX_COMPLETED_CLIENT_CONFIGS) {
    const oldest = completedClientConfigLoads.keys().next().value;
    if (typeof oldest !== "string") break;
    completedClientConfigLoads.delete(oldest);
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
