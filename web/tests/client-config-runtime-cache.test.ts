import { afterEach, describe, expect, spyOn, test } from "bun:test";
import {
  CLIENT_CONFIG_CACHE_TTL_SECONDS,
  clientConfigCacheKey,
  isCompleteClientConfig,
  readCachedClientConfig,
  writeCachedClientConfig,
} from "../services/client-config/runtimeCache";

const originalNodeEnv = process.env.NODE_ENV;
const originalDeploymentId = process.env.VERCEL_DEPLOYMENT_ID;
const originalVercelEnvironment = process.env.VERCEL_ENV;
const originalVercel = process.env.VERCEL;
const originalVercelUrl = process.env.VERCEL_URL;
const mutableEnv = process.env as Record<string, string | undefined>;

afterEach(() => {
  if (originalNodeEnv === undefined) delete mutableEnv.NODE_ENV;
  else mutableEnv.NODE_ENV = originalNodeEnv;
  if (originalDeploymentId === undefined) delete mutableEnv.VERCEL_DEPLOYMENT_ID;
  else mutableEnv.VERCEL_DEPLOYMENT_ID = originalDeploymentId;
  if (originalVercelEnvironment === undefined) delete mutableEnv.VERCEL_ENV;
  else mutableEnv.VERCEL_ENV = originalVercelEnvironment;
  if (originalVercel === undefined) delete mutableEnv.VERCEL;
  else mutableEnv.VERCEL = originalVercel;
  if (originalVercelUrl === undefined) delete mutableEnv.VERCEL_URL;
  else mutableEnv.VERCEL_URL = originalVercelUrl;
});

describe("client config runtime cache", () => {
  test("uses a stable key when evaluation object keys arrive in a different order", () => {
    const first = clientConfigCacheKey("install-1", {
      groups: { organization: "org-1", team: "team-1" },
      personProperties: { plan: "pro", region: "us" },
    });
    const second = clientConfigCacheKey("install-1", {
      personProperties: { region: "us", plan: "pro" },
      groups: { team: "team-1", organization: "org-1" },
    });

    expect(first).toBe(second);
  });

  test("isolates evaluations between deployments", () => {
    mutableEnv.VERCEL_DEPLOYMENT_ID = "deployment-a";
    const first = clientConfigCacheKey("install-1", {});
    mutableEnv.VERCEL_DEPLOYMENT_ID = "deployment-b";
    const second = clientConfigCacheKey("install-1", {});

    expect(first).not.toBe(second);
  });

  test("bypasses Vercel caching without a deployment scope", () => {
    mutableEnv.VERCEL = "1";
    delete mutableEnv.VERCEL_URL;
    delete mutableEnv.VERCEL_DEPLOYMENT_ID;
    expect(clientConfigCacheKey("identity", {})).toBeUndefined();
  });

  test("keeps different identities separate through the SDK's key transformation", async () => {
    mutableEnv.NODE_ENV = "production";
    mutableEnv.VERCEL_ENV = "preview";
    mutableEnv.VERCEL_DEPLOYMENT_ID = "cache-isolation-test";
    // These identities collide under the SDK's default 32-bit key hash.
    const firstKey = clientConfigCacheKey("cache-person-37326", {});
    const secondKey = clientConfigCacheKey("cache-person-46051", {});
    if (!firstKey || !secondKey) throw new Error("expected cache keys");
    const firstConfig = { featureFlags: { enabled: true }, featureFlagPayloads: {}, errorsWhileComputingFlags: false };
    const secondConfig = { ...firstConfig, featureFlags: { enabled: false } };

    await writeCachedClientConfig(firstKey, firstConfig);
    await writeCachedClientConfig(secondKey, secondConfig);

    expect(await readCachedClientConfig(firstKey)).toEqual(firstConfig);
    expect(await readCachedClientConfig(secondKey)).toEqual(secondConfig);
  });

  test("skips caching when evaluation context nesting exceeds the bound", () => {
    let nested: Record<string, unknown> = {};
    for (let index = 0; index < 40; index += 1) nested = { nested };

    expect(clientConfigCacheKey("deep-context", { personProperties: nested })).toBeUndefined();
  });

  test("stores and reads complete results with a five-minute TTL", async () => {
    mutableEnv.NODE_ENV = "production";
    const config = {
      featureFlags: { enabled: true },
      featureFlagPayloads: {},
      errorsWhileComputingFlags: false,
    } as const;
    const key = clientConfigCacheKey("install-1", {});
    if (!key) throw new Error("expected a cache key");

    await writeCachedClientConfig(key, config);

    expect(await readCachedClientConfig(key)).toEqual(config);
    expect(CLIENT_CONFIG_CACHE_TTL_SECONDS).toBe(300);
  });

  test("rejects partial or malformed cached values", async () => {
    expect(isCompleteClientConfig({
      featureFlags: {},
      featureFlagPayloads: {},
      errorsWhileComputingFlags: true,
    })).toBe(false);
    expect(isCompleteClientConfig({ featureFlags: {}, featureFlagPayloads: {} })).toBe(false);
    expect(isCompleteClientConfig({
      featureFlags: {}, featureFlagPayloads: {}, errorsWhileComputingFlags: false, requestId: 42,
    })).toBe(false);
    expect(isCompleteClientConfig({
      featureFlags: { enabled: "true" },
      featureFlagPayloads: {},
      errorsWhileComputingFlags: false,
    })).toBe(true);
  });

  test("expires stored results after five minutes", async () => {
    mutableEnv.NODE_ENV = "production";
    let now = Date.now();
    const clock = spyOn(Date, "now").mockImplementation(() => now);
    const key = clientConfigCacheKey("expiry-test", {});
    if (!key) throw new Error("expected a cache key");
    const config = { featureFlags: { enabled: true }, featureFlagPayloads: {}, errorsWhileComputingFlags: false };
    try {
      await writeCachedClientConfig(key, config);
      now += 299_000;
      expect(await readCachedClientConfig(key)).toEqual(config);
      now += 1_001;
      expect(await readCachedClientConfig(key)).toBeUndefined();
    } finally {
      clock.mockRestore();
    }
  });

  test("isolates each targeting input while preserving property order equivalence", () => {
    const baseline = clientConfigCacheKey("identity", {});
    const contexts = [
      { groups: { team: "one" } },
      { personProperties: { plan: "pro" } },
      { groupProperties: { team: { plan: "pro" } } },
      { anonDistinctId: "anon" },
      { deviceId: "device" },
      { timezone: "UTC" },
      { evaluationContexts: ["web"] },
    ];
    const keys = contexts.map((context) => clientConfigCacheKey("identity", context));
    expect(new Set([baseline, clientConfigCacheKey("other-identity", {}), ...keys]).size).toBe(9);
  });

  test("does not replace a complete entry with a partial evaluation", async () => {
    mutableEnv.NODE_ENV = "production";
    const complete = {
      featureFlags: { enabled: true },
      featureFlagPayloads: {},
      errorsWhileComputingFlags: false,
    } as const;
    const partial = {
      featureFlags: { enabled: false },
      featureFlagPayloads: {},
      errorsWhileComputingFlags: true,
    } as const;
    const key = clientConfigCacheKey("partial-write-test", {});
    if (!key) throw new Error("expected a cache key");

    await writeCachedClientConfig(key, complete);
    await writeCachedClientConfig(key, partial);

    expect(await readCachedClientConfig(key)).toEqual(complete);
  });
});
