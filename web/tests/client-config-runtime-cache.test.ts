import { afterEach, describe, expect, test } from "bun:test";

const {
  CLIENT_CONFIG_CACHE_TTL_SECONDS,
  clientConfigCacheKey,
  isCompleteClientConfig,
  readCachedClientConfig,
  writeCachedClientConfig,
} = await import("../services/client-config/runtimeCache");

const originalNodeEnv = process.env.NODE_ENV;
const originalDeploymentId = process.env.VERCEL_DEPLOYMENT_ID;
const mutableEnv = process.env as Record<string, string | undefined>;

afterEach(() => {
  if (originalNodeEnv === undefined) delete mutableEnv.NODE_ENV;
  else mutableEnv.NODE_ENV = originalNodeEnv;
  if (originalDeploymentId === undefined) delete mutableEnv.VERCEL_DEPLOYMENT_ID;
  else mutableEnv.VERCEL_DEPLOYMENT_ID = originalDeploymentId;
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

  test("stores and reads complete results with a five-minute TTL", async () => {
    mutableEnv.NODE_ENV = "production";
    const config = {
      featureFlags: { "pro-upgrade-ui-enabled-release": true },
      featureFlagPayloads: {},
      errorsWhileComputingFlags: false,
    } as const;
    const key = clientConfigCacheKey("install-1", {});

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
      featureFlags: { enabled: "true" },
      featureFlagPayloads: {},
      errorsWhileComputingFlags: false,
    })).toBe(true);
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

    await writeCachedClientConfig(key, complete);
    await writeCachedClientConfig(key, partial);

    expect(await readCachedClientConfig(key)).toEqual(complete);
  });
});
