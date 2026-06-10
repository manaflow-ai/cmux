import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";
import { getTableName } from "drizzle-orm";
import { deviceTokens, notificationWorkspaceMutes } from "../db/schema";

const envKeys = [
  "SKIP_ENV_VALIDATION",
  "VERCEL",
  "CMUX_PUSH_RATE_LIMIT_ID",
] as const;
const originalEnv = Object.fromEntries(envKeys.map((key) => [key, process.env[key]])) as Record<
  (typeof envKeys)[number],
  string | undefined
>;

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

// `cloudDb` delegates to a swappable factory: the rate-limit-first test leaves it
// throwing (DB must never be reached), the mute tests point it at a fake DB.
let cloudDbFactory: () => unknown = () => {
  throw new Error("cloudDb should not be reached after a push rate-limit block");
};
const cloudDb = mock((): unknown => cloudDbFactory());

// Mute-test DB scaffolding: records which tables the route touched so we can
// prove the muted path returns before the device-token lookup / APNs send.
const selectedTables: string[] = [];
let mutedRows: { workspaceId: string }[] = [];
const mutesTable = getTableName(notificationWorkspaceMutes);
const deviceTokensTable = getTableName(deviceTokens);

function fakeDb() {
  return {
    select() {
      return {
        from(table: unknown) {
          const name = getTableName(table as Parameters<typeof getTableName>[0]);
          selectedTables.push(name);
          if (name === mutesTable) {
            return { where: async () => mutedRows };
          }
          return { where: () => ({ limit: async () => [] }) };
        },
      };
    },
  };
}

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
}));

mock.module("@vercel/firewall", () => ({
  checkRateLimit,
}));

mock.module("../db/client", () => ({
  cloudDb,
}));

// The sender is NOT mocked (mock.module is process-global in bun and would break
// `apns.test.ts`'s real-sender transport tests). The mute tests prove no send by
// asserting the route never reaches the device-token lookup, and the no-token
// path returns before any APNs traffic on its own.

const pushRoute = await import("../app/api/notifications/push/route");

afterAll(() => {
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
  getUser.mockClear();
  checkRateLimit.mockClear();
  checkRateLimit.mockResolvedValue({ rateLimited: true, error: null });
  cloudDb.mockClear();
  cloudDbFactory = () => {
    throw new Error("cloudDb should not be reached after a push rate-limit block");
  };
  selectedTables.length = 0;
  mutedRows = [];
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
});

// Behavior-level gate for per-workspace mute: a push for a muted workspace must
// be dropped BEFORE any device-token lookup or APNs send. The rate limiter is
// allowed through here (mockResolvedValue) so the route reaches the mute gate.
function mutePushRequest(workspaceId: string): Request {
  return new Request("https://cmux.test/api/notifications/push", {
    method: "POST",
    headers: {
      authorization: "Bearer access-token",
      "x-stack-refresh-token": "refresh-token",
      "content-type": "application/json",
    },
    body: JSON.stringify({ title: "Agent done", body: "Build finished", workspaceId }),
  });
}

describe("notifications push route per-workspace mute", () => {
  beforeEach(() => {
    checkRateLimit.mockResolvedValue({ rateLimited: false, error: null });
    cloudDbFactory = () => fakeDb();
  });

  test("drops the push for a muted workspace before any device-token lookup or APNs send", async () => {
    mutedRows = [{ workspaceId: "ws-muted" }];

    const response = await pushRoute.POST(mutePushRequest("ws-muted"));

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ muted: true });
    // The mute lookup ran; the device-token lookup (and thus any APNs send) did not.
    expect(selectedTables).toContain(mutesTable);
    expect(selectedTables).not.toContain(deviceTokensTable);
  });

  test("delivers (reaches the device-token lookup) for a workspace that is not muted", async () => {
    mutedRows = [{ workspaceId: "ws-other" }];

    const response = await pushRoute.POST(mutePushRequest("ws-active"));

    expect(response.status).toBe(200);
    expect(await response.json()).not.toMatchObject({ muted: true });
    // Not muted => the route proceeds to the device-token lookup (no tokens here,
    // so it no-ops without sending), proving the mute gate did not suppress it.
    expect(selectedTables).toContain(mutesTable);
    expect(selectedTables).toContain(deviceTokensTable);
  });
});
