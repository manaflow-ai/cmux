import { createHash } from "node:crypto";

import { getCache } from "@vercel/functions";

import type {
  ClientConfig,
  ClientConfigEvaluationContext,
} from "./types";

export const CLIENT_CONFIG_CACHE_TTL_SECONDS = 5 * 60;

const CACHE_NAMESPACE = "cmux-client-config";
// The SDK otherwise re-hashes our SHA-256 key into only 32 bits.
const CACHE_OPTIONS = { namespace: CACHE_NAMESPACE, keyHashFunction: (key: string) => key };
const CACHE_VERSION = "v1";
const MAX_CACHE_KEY_DEPTH = 32;
const MAX_CACHE_KEY_NODES = 2_048;
const CACHE_READ_TIMEOUT_MS = 100;
const CACHE_WRITE_TIMEOUT_MS = 750;
const CACHE_FAILURE_COOLDOWN_MS = 30_000;
const MAX_IN_FLIGHT_CACHE_OPERATIONS = 32;

let cacheDisabledUntil = 0;
let unresolvedCacheOperations = 0;

export function clientConfigCacheKey(
  distinctId: string,
  context: ClientConfigEvaluationContext,
): string | undefined {
  const deployment = process.env.VERCEL_DEPLOYMENT_ID?.trim() || process.env.VERCEL_URL?.trim();
  if (process.env.VERCEL === "1" && !deployment) return undefined;
  const sortedContext = sortRecord(context, { remainingNodes: MAX_CACHE_KEY_NODES }, 0);
  if (sortedContext === CANONICALIZATION_FAILED) return undefined;
  const evaluation = JSON.stringify({
    environment: process.env.VERCEL_ENV ?? "development",
    deployment: deployment ?? "local",
    distinctId,
    context: sortedContext,
  });
  const digest = createHash("sha256").update(evaluation).digest("hex");
  return `${CACHE_VERSION}:${digest}`;
}

export async function readCachedClientConfig(
  key: string,
): Promise<ClientConfig | undefined> {
  if (process.env.NODE_ENV === "test") return undefined;
  const lease = beginCacheOperation();
  if (!lease) return undefined;
  try {
    const result = await withCacheDeadline(
      getCache(CACHE_OPTIONS).get(key),
      CACHE_READ_TIMEOUT_MS,
      lease.settle,
    );
    if (!result.completed) {
      tripCacheCircuit();
      return undefined;
    }
    return isCompleteClientConfig(result.value) ? result.value : undefined;
  } catch {
    lease.settle();
    tripCacheCircuit();
    return undefined;
  }
}

export async function writeCachedClientConfig(
  key: string,
  config: ClientConfig,
): Promise<void> {
  if (!isCompleteClientConfig(config)) return;
  if (process.env.NODE_ENV === "test") return;
  const lease = beginCacheOperation();
  if (!lease) return;
  try {
    const result = await withCacheDeadline(
      getCache(CACHE_OPTIONS).set(key, config, {
        name: "client-config",
        ttl: CLIENT_CONFIG_CACHE_TTL_SECONDS,
      }),
      CACHE_WRITE_TIMEOUT_MS,
      lease.settle,
    );
    if (!result.completed) tripCacheCircuit();
  } catch {
    lease.settle();
    tripCacheCircuit();
    // Cache writes are best effort. The PostHog response is already valid.
  }
}

async function withCacheDeadline<T>(
  operation: Promise<T>,
  timeoutMs: number,
  onSettled: () => void,
): Promise<{ readonly completed: true; readonly value: T } | { readonly completed: false }> {
  return await new Promise((resolve) => {
    const timer = setTimeout(() => {
      resolve({ completed: false });
    }, timeoutMs);
    operation.then(
      (value) => {
        onSettled();
        clearTimeout(timer);
        resolve({ completed: true, value });
      },
      () => {
        onSettled();
        clearTimeout(timer);
        resolve({ completed: false });
      },
    );
  });
}

function beginCacheOperation(): { settle: () => void } | undefined {
  if (
    Date.now() < cacheDisabledUntil ||
    unresolvedCacheOperations >= MAX_IN_FLIGHT_CACHE_OPERATIONS
  ) return undefined;
  unresolvedCacheOperations += 1;
  let settled = false;
  return {
    settle: () => {
      if (settled) return;
      settled = true;
      unresolvedCacheOperations = Math.max(0, unresolvedCacheOperations - 1);
    },
  };
}

function tripCacheCircuit(): void {
  cacheDisabledUntil = Date.now() + CACHE_FAILURE_COOLDOWN_MS;
}

export function isCompleteClientConfig(value: unknown): value is ClientConfig {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const config = value as Partial<ClientConfig>;
  return config.errorsWhileComputingFlags === false &&
    isRecord(config.featureFlags) &&
    Object.values(config.featureFlags).every(
      (flag) => typeof flag === "boolean" || typeof flag === "string",
    ) &&
    isRecord(config.featureFlagPayloads) &&
    (config.requestId === undefined || typeof config.requestId === "string");
}

const CANONICALIZATION_FAILED = Symbol("canonicalization_failed");

function sortRecord(
  value: unknown,
  budget: { remainingNodes: number },
  depth: number,
): unknown | typeof CANONICALIZATION_FAILED {
  if (depth > MAX_CACHE_KEY_DEPTH || budget.remainingNodes <= 0) {
    return CANONICALIZATION_FAILED;
  }
  if (!value || typeof value !== "object") return value;
  budget.remainingNodes -= 1;
  if (Array.isArray(value)) {
    const sorted = value.map((entry) => sortRecord(entry, budget, depth + 1));
    return sorted.some((entry) => entry === CANONICALIZATION_FAILED)
      ? CANONICALIZATION_FAILED
      : sorted;
  }
  const entries = Object.entries(value)
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([key, entry]) => [key, sortRecord(entry, budget, depth + 1)] as const);
  return entries.some(([, entry]) => entry === CANONICALIZATION_FAILED)
    ? CANONICALIZATION_FAILED
    : Object.fromEntries(entries);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}
