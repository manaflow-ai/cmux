import { createHash } from "node:crypto";

import { getCache } from "@vercel/functions";

import type {
  ClientConfig,
  ClientConfigEvaluationContext,
} from "./posthogFlags";

export const CLIENT_CONFIG_CACHE_TTL_SECONDS = 5 * 60;

const CACHE_NAMESPACE = "cmux-client-config";
const CACHE_VERSION = "v1";

export function clientConfigCacheKey(
  distinctId: string,
  context: ClientConfigEvaluationContext,
): string {
  const evaluation = JSON.stringify({
    environment: process.env.VERCEL_ENV ?? "development",
    deployment: process.env.VERCEL_DEPLOYMENT_ID ?? process.env.VERCEL_URL ?? "local",
    distinctId,
    context: sortRecord(context),
  });
  const digest = createHash("sha256").update(evaluation).digest("hex");
  return `${CACHE_VERSION}:${digest}`;
}

export async function readCachedClientConfig(
  key: string,
): Promise<ClientConfig | undefined> {
  if (process.env.NODE_ENV === "test") return undefined;
  try {
    const value = await getCache({ namespace: CACHE_NAMESPACE }).get(key);
    return isCompleteClientConfig(value) ? value : undefined;
  } catch {
    return undefined;
  }
}

export async function writeCachedClientConfig(
  key: string,
  config: ClientConfig,
): Promise<void> {
  if (!isCompleteClientConfig(config)) return;
  if (process.env.NODE_ENV === "test") return;
  try {
    await getCache({ namespace: CACHE_NAMESPACE }).set(key, config, {
      name: "client-config",
      ttl: CLIENT_CONFIG_CACHE_TTL_SECONDS,
    });
  } catch {
    // Cache writes are best effort. The PostHog response is already valid.
  }
}

export function isCompleteClientConfig(value: unknown): value is ClientConfig {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const config = value as Partial<ClientConfig>;
  return config.errorsWhileComputingFlags === false &&
    isRecord(config.featureFlags) &&
    Object.values(config.featureFlags).every(
      (flag) => typeof flag === "boolean" || typeof flag === "string",
    ) &&
    isRecord(config.featureFlagPayloads);
}

function sortRecord(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortRecord);
  if (!value || typeof value !== "object") return value;
  return Object.fromEntries(
    Object.entries(value)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, entry]) => [key, sortRecord(entry)]),
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}
