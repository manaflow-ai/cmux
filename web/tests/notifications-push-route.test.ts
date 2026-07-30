import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import postgres, { type Sql } from "postgres";

const envKeys = [
  "SKIP_ENV_VALIDATION",
  "VERCEL",
  "CMUX_PUSH_RATE_LIMIT_ID",
] as const;
const originalEnv = Object.fromEntries(envKeys.map((key) => [key, process.env[key]])) as Record<
  (typeof envKeys)[number],
  string | undefined
>;
// Capture real implementations BY VALUE: bun's mock.module can mutate an
// already-loaded namespace in place, so calling through a captured namespace
// object at delegation time can recurse into the mock itself.
const dbClientModule = await import("../db/client");
const realCloudDb = dbClientModule.cloudDb;
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const realCreateAwsRdsIamPool = dbClientModule.createAwsRdsIamPool;
const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;

process.env.SKIP_ENV_VALIDATION = "1";
process.env.VERCEL = "1";
process.env.CMUX_PUSH_RATE_LIMIT_ID = "cmux-push-test";

const getUser = mock(async () => ({
  id: "user-1",
  displayName: null,
  primaryEmail: null,
  selectedTeam: null,
}));
const checkRateLimit = mock(async () => ({ rateLimited: true, error: null }));
const cloudDb = mock(() => {
  throw new Error("cloudDb should not be reached after a push rate-limit block");
});
let useStubDb = false;

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  stackServerApp: { getUser },
}));

mock.module("@vercel/firewall", () => ({
  checkRateLimit,
}));

mock.module("../db/client", () => ({
  createAwsRdsIamPool: realCreateAwsRdsIamPool,
  closeCloudDbForTests: realCloseCloudDbForTests,
  cloudDb: (() =>
    useStubDb
      ? (cloudDb() as unknown as ReturnType<typeof realCloudDb>)
      : realCloudDb()) as typeof realCloudDb,
}));

const pushRoute = await import("../app/api/notifications/push/route");
let sql: Sql | null = null;

beforeAll(() => {
  useStubDb = true;
  if (!runDbTests) return;
  const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL) {
    throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  }
  sql = postgres(databaseURL, { max: 1 });
});

afterAll(async () => {
  useStubDb = false;
  await realCloseCloudDbForTests();
  await sql?.end();
  for (const key of envKeys) {
    const value = originalEnv[key];
    if (typeof value === "undefined") {
      delete process.env[key];
    } else {
      process.env[key] = value;
    }
  }
});

beforeEach(async () => {
  // Re-assert the env each test rather than relying only on the module-top-level
  // assignment. bun runs every test file in one process, and other suites
  // (e.g. vm-route-auth) capture+restore process.env.VERCEL, so depending on
  // file load order they can delete VERCEL before these tests run — which made
  // the route skip rate-limiting and flaked this suite in CI.
  process.env.SKIP_ENV_VALIDATION = "1";
  process.env.VERCEL = "1";
  process.env.CMUX_PUSH_RATE_LIMIT_ID = "cmux-push-test";
  getUser.mockClear();
  checkRateLimit.mockClear();
  checkRateLimit.mockResolvedValue({ rateLimited: true, error: null });
  cloudDb.mockClear();
  if (sql) {
    await sql`truncate device_tokens restart identity cascade`;
  }
});

describe("notifications push route", () => {
  test("uses the exact-bundle device limit", () => {
    expect(pushRoute.notificationPushTargetLimit()).toBe(10);
  });

  test("applies the Vercel user limiter before body parsing or DB access", async () => {
    const response = await pushRoute.POST(
      new Request("https://cmux.test/api/notifications/push", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "content-length": "9000",
        },
        body: "{}",
      }),
    );

    expect(response.status).toBe(429);
    expect(await response.json()).toEqual({ error: "rate_limited" });
    expect(checkRateLimit).toHaveBeenCalledTimes(1);
    const calls = (checkRateLimit as unknown as {
      mock: { calls: Array<[string, { rateLimitKey: string }]> };
    }).mock.calls;
    expect(calls[0]?.[0]).toBe("cmux-push-test");
    expect(calls[0]?.[1]).toMatchObject({
      rateLimitKey: "user-1",
    });
    expect(cloudDb).not.toHaveBeenCalled();
  });

  test("rejects an invalid target namespace before DB access", async () => {
    checkRateLimit.mockResolvedValue({ rateLimited: false, error: null });
    const response = await pushRoute.POST(
      new Request("https://cmux.test/api/notifications/push", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-ios-target-namespace": "dev.cmux.ios.invalid_target",
        },
        body: JSON.stringify({ title: "Agent", body: "Done" }),
      }),
    );

    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({
      error: "invalid_target_namespace",
    });
    expect(cloudDb).not.toHaveBeenCalled();
  });

  test("rejects a missing target namespace before DB access", async () => {
    checkRateLimit.mockResolvedValue({ rateLimited: false, error: null });
    const response = await pushRoute.POST(
      new Request("https://cmux.test/api/notifications/push", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
        },
        body: JSON.stringify({ title: "Agent", body: "Done" }),
      }),
    );

    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({
      error: "missing_target_namespace",
    });
    expect(cloudDb).not.toHaveBeenCalled();
  });

  dbTest("selects one exact namespace", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`
      insert into device_tokens (
        user_id,
        device_token,
        bundle_id,
        environment,
        platform
      )
      values
        (
          'user-1',
          ${"a".repeat(64)},
          'dev.cmux.app.internal',
          'production',
          'ios'
        ),
        (
          'user-1',
          ${"b".repeat(64)},
          'dev.cmux.app.demo',
          'production',
          'ios'
        ),
        (
          'other-user',
          ${"c".repeat(64)},
          'dev.cmux.app.internal',
          'production',
          'ios'
        )
    `;

    const targets = await pushRoute.selectNotificationPushTargets(
      realCloudDb(),
      "user-1",
      "dev.cmux.app.internal",
    );

    expect(targets).toEqual([
      {
        deviceToken: "a".repeat(64),
        bundleId: "dev.cmux.app.internal",
        environment: "production",
      },
    ]);

  });
});
