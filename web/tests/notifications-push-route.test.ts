import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import { accountDeletionTombstones, deviceTokens, notificationSendEvents } from "../db/schema";

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

process.env.SKIP_ENV_VALIDATION = "1";
process.env.VERCEL = "1";
process.env.CMUX_PUSH_RATE_LIMIT_ID = "cmux-push-test";
process.env.CMUX_APNS_KEY_P8 = "dummy-key";
process.env.CMUX_APNS_KEY_ID = "dummy-key-id";
process.env.CMUX_APNS_TEAM_ID = "dummy-team-id";

// Capture real implementations BY VALUE: bun's mock.module can mutate an
// already-loaded namespace in place, so calling through a captured namespace
// object at delegation time can recurse into the mock itself.
const dbClientModule = await import("../db/client");
const realCloudDb = dbClientModule.cloudDb;
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const realCreateAwsRdsIamPool = dbClientModule.createAwsRdsIamPool;
const apnsSenderModule = await import("../services/apns/sender");
const realNormalizeP8 = apnsSenderModule.normalizeP8;
const realSendApnsNotification = apnsSenderModule.sendApnsNotification;
const realSignApnsJwt = apnsSenderModule.signApnsJwt;

const getUser = mock(async () => ({
  id: "user-1",
  displayName: null,
  primaryEmail: null,
  selectedTeam: null,
}));
const checkRateLimit = mock(async () => ({ rateLimited: true, error: null }));
let cloudDbImpl: () => unknown = () => {
  throw new Error("cloudDb should not be reached after a push rate-limit block");
};
const cloudDb = mock(() => cloudDbImpl());
let sendApnsNotificationImpl = async () => [{
  deviceToken: "token-1",
  status: 200,
  prune: false,
}];
const sendApnsNotification = mock(async (...args: unknown[]) => {
  if (args.length >= 5) {
    return await realSendApnsNotification(...(args as Parameters<typeof realSendApnsNotification>));
  }
  return await sendApnsNotificationImpl();
});
let useStubDb = false;
let pushDbCalls: string[] = [];
let pushDbTransactionOpen = false;

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  stackServerApp: { getUser },
}));

mock.module("@vercel/firewall", () => ({
  checkRateLimit,
}));

mock.module("../app/env", () => ({
  env: {
    get CMUX_APNS_KEY_ID() {
      return process.env.CMUX_APNS_KEY_ID;
    },
    get CMUX_APNS_KEY_P8() {
      return process.env.CMUX_APNS_KEY_P8;
    },
    get CMUX_APNS_TEAM_ID() {
      return process.env.CMUX_APNS_TEAM_ID;
    },
    get CMUX_PUSH_RATE_LIMIT_ID() {
      return process.env.CMUX_PUSH_RATE_LIMIT_ID;
    },
  },
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
  normalizeP8: realNormalizeP8,
  sendApnsNotification,
  signApnsJwt: realSignApnsJwt,
}));

const pushRoute = await import("../app/api/notifications/push/route");

beforeAll(() => {
  useStubDb = true;
});

afterAll(() => {
  useStubDb = false;
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
  process.env.CMUX_APNS_KEY_P8 = "dummy-key";
  process.env.CMUX_APNS_KEY_ID = "dummy-key-id";
  process.env.CMUX_APNS_TEAM_ID = "dummy-team-id";
  getUser.mockClear();
  checkRateLimit.mockClear();
  checkRateLimit.mockResolvedValue({ rateLimited: true, error: null });
  cloudDb.mockClear();
  cloudDbImpl = () => {
    throw new Error("cloudDb should not be reached after a push rate-limit block");
  };
  sendApnsNotification.mockClear();
  sendApnsNotificationImpl = async () => [{
    deviceToken: "token-1",
    status: 200,
    prune: false,
  }];
  pushDbCalls = [];
  pushDbTransactionOpen = false;
});

describe("notifications push route", () => {
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

  test("sends APNs outside the account deletion transaction and rechecks before pruning", async () => {
    checkRateLimit.mockResolvedValue({ rateLimited: false, error: null });
    cloudDbImpl = () => fakePushDb();
    sendApnsNotificationImpl = async () => {
      expect(pushDbTransactionOpen).toBe(false);
      pushDbCalls.push("send-apns");
      return [{
        deviceToken: "token-1",
        status: 200,
        prune: true,
      }];
    };

    const response = await pushRoute.POST(
      new Request("https://cmux.test/api/notifications/push", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
        },
        body: JSON.stringify({ title: "Build finished", body: "Tests passed" }),
      }),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ sent: 1, devices: 1, pruned: 1 });
    expect(pushDbCalls).toEqual([
      "transaction:start",
      "lock",
      "select:accountDeletionTombstones",
      "select:deviceTokens",
      "rate-limit-lock",
      "delete:notificationSendEvents",
      "select:notificationSendEvents",
      "insert:notificationSendEvents",
      "transaction:end",
      "send-apns",
      "transaction:start",
      "lock",
      "select:accountDeletionTombstones",
      "delete:deviceTokens",
      "transaction:end",
    ]);
  });
});

function fakePushDb() {
  const tx = {
    execute: async () => {
      const activeTransactionCalls = pushDbCalls.slice(pushDbCalls.lastIndexOf("transaction:start") + 1);
      pushDbCalls.push(activeTransactionCalls.includes("lock") ? "rate-limit-lock" : "lock");
      return [];
    },
    select: () => selectBuilder(),
    delete: (table: unknown) => ({
      where: async () => {
        pushDbCalls.push(`delete:${tableLabel(table)}`);
        return [];
      },
    }),
    insert: (table: unknown) => ({
      values: async () => {
        pushDbCalls.push(`insert:${tableLabel(table)}`);
        return [];
      },
    }),
  };
  return {
    ...tx,
    transaction: async <T>(callback: (db: typeof tx) => Promise<T>) => {
      pushDbCalls.push("transaction:start");
      pushDbTransactionOpen = true;
      try {
        return await callback(tx);
      } finally {
        pushDbTransactionOpen = false;
        pushDbCalls.push("transaction:end");
      }
    },
  };
}

function selectBuilder() {
  let table: unknown = null;
  const rows = () => {
    pushDbCalls.push(`select:${tableLabel(table)}`);
    if (table === deviceTokens) {
      return [{
        deviceToken: "token-1",
        bundleId: "dev.cmux.ios.test",
        environment: "sandbox",
      }];
    }
    if (table === notificationSendEvents) {
      return [{ total: 0 }];
    }
    return [];
  };
  const builder = {
    from: (fromTable: unknown) => {
      table = fromTable;
      return builder;
    },
    where: () => builder,
    limit: async () => rows(),
    then: (
      resolve: (value: unknown[]) => unknown,
      reject: (reason: unknown) => unknown,
    ) => Promise.resolve(rows()).then(resolve, reject),
  };
  return builder;
}

function tableLabel(table: unknown): string {
  if (table === accountDeletionTombstones) return "accountDeletionTombstones";
  if (table === deviceTokens) return "deviceTokens";
  if (table === notificationSendEvents) return "notificationSendEvents";
  return "unknown";
}
