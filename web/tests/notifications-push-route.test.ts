import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import postgres, { type Sql } from "postgres";

const envKeys = [
  "SKIP_ENV_VALIDATION",
  "VERCEL",
  "CMUX_PUSH_RATE_LIMIT_ID",
  "CMUX_APNS_KEY_P8",
  "CMUX_APNS_KEY_ID",
  "CMUX_APNS_TEAM_ID",
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

process.env.SKIP_ENV_VALIDATION = "1";
process.env.VERCEL = "1";
process.env.CMUX_PUSH_RATE_LIMIT_ID = "cmux-push-test";
process.env.CMUX_APNS_KEY_P8 = "test-key";
process.env.CMUX_APNS_KEY_ID = "test-key-id";
process.env.CMUX_APNS_TEAM_ID = "test-team-id";

const getUser = mock(async () => ({
  id: "user-1",
  displayName: null,
  primaryEmail: null,
  selectedTeam: null,
}));
const checkRateLimit = mock(async () => ({ rateLimited: true, error: null }));
const cloudDb = mock(() => {
  throw new Error("cloudDb should not be reached for invalid JSON");
});
let useStubDb = false;
let sql: Sql | null = null;
const sendApnsNotificationReliably = mock(
  async (
    _config: unknown,
    targets: readonly { deviceToken: string }[],
  ) => targets.map((target) => ({
    deviceToken: target.deviceToken,
    status: 200,
    prune: false,
  })),
);

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

mock.module("../services/apns/sender", () => ({
  sendApnsNotificationReliably,
}));

const pushRoute = await import("../app/api/notifications/push/route");

beforeAll(() => {
  useStubDb = true;
  if (process.env.CMUX_DB_TEST !== "1") return;
  const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL) {
    throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  }
  sql = postgres(databaseURL, { max: 1 });
});

afterAll(async () => {
  useStubDb = false;
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

beforeEach(() => {
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
  sendApnsNotificationReliably.mockClear();
  useStubDb = true;
});

describe("notifications push route", () => {
  test("uses the database user limiter as the only in-code limiter", async () => {
    checkRateLimit.mockResolvedValue({ rateLimited: true, error: "blocked" });
    const response = await pushRoute.POST(
      new Request("https://cmux.test/api/notifications/push", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
        },
        body: "{",
      }),
    );

    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "invalid_json" });
    expect(checkRateLimit).not.toHaveBeenCalled();
    expect(cloudDb).not.toHaveBeenCalled();
  });

  const dbTest = process.env.CMUX_DB_TEST === "1" ? test : test.skip;
  dbTest("persists partial outcomes and retries only the unresolved token", async () => {
    if (!sql) throw new Error("test database not initialized");
    useStubDb = false;
    await sql`
      truncate device_tokens, notification_send_events restart identity cascade
    `;
    await sql`
      insert into device_tokens (
        user_id, device_token, platform, bundle_id, environment
      ) values
        ('user-1', ${"a".repeat(64)}, 'ios', 'com.cmux.app', 'production'),
        ('user-1', ${"b".repeat(64)}, 'ios', 'com.cmux.app', 'production')
    `;

    sendApnsNotificationReliably
      .mockResolvedValueOnce([
        {
          deviceToken: "a".repeat(64),
          status: 200,
          prune: false,
        },
        {
          deviceToken: "b".repeat(64),
          status: 503,
          reason: "ServiceUnavailable",
          prune: false,
        },
      ])
      .mockResolvedValueOnce([
        {
          deviceToken: "b".repeat(64),
          status: 200,
          prune: false,
        },
      ]);

    const correlationId = "4d02de48-a21d-4ba1-97b5-42e9400ee09b";
    const request = () => new Request(
      "https://cmux.test/api/notifications/push",
      {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
        },
        body: JSON.stringify({
          title: "agent",
          body: "done",
          correlationId,
          expirationEpochSeconds: Math.floor(Date.now() / 1000) + 120,
        }),
      },
    );

    const partial = await pushRoute.POST(request());
    expect(partial.status).toBe(200);
    expect(await partial.json()).toMatchObject({
      sent: 1,
      devices: 2,
      transientFailures: 1,
      correlationId,
    });

    const recovered = await pushRoute.POST(request());
    expect(recovered.status).toBe(200);
    expect(await recovered.json()).toMatchObject({
      sent: 2,
      devices: 2,
      transientFailures: 0,
      correlationId,
    });
    expect(sendApnsNotificationReliably).toHaveBeenCalledTimes(2);
    expect(
      sendApnsNotificationReliably.mock.calls[1]?.[1]
        .map((target: { deviceToken: string }) => target.deviceToken),
    ).toEqual(["b".repeat(64)]);

    const [stored] = await sql<{ total: number }[]>`
      select count(*)::int as total
      from notification_send_events
      where user_id = 'user-1' and correlation_id = ${correlationId}
    `;
    expect(stored?.total).toBe(1);
  });
});
