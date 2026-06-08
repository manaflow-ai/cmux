// Behavior-level gate for per-workspace mute: a push for a workspace the user
// muted on their phone must be dropped by the push route BEFORE any APNs traffic
// (no device-token query, no APNs send), so a muted workspace stays silent even
// while the phone is backgrounded or locked. Exercises the real route policy
// through the handler with a mocked DB + auth, mirroring
// `notifications-push-route.test.ts`.

import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";
import { getTableName } from "drizzle-orm";
import { deviceTokens, notificationWorkspaceMutes } from "../db/schema";

const envKeys = ["SKIP_ENV_VALIDATION", "VERCEL", "CMUX_PUSH_RATE_LIMIT_ID"] as const;
const originalEnv = Object.fromEntries(envKeys.map((key) => [key, process.env[key]])) as Record<
  (typeof envKeys)[number],
  string | undefined
>;

process.env.SKIP_ENV_VALIDATION = "1";
// Keep the Vercel firewall path out of this test so it never short-circuits the
// mute decision: the limiter only runs when both VERCEL and the limit id are set.
delete process.env.VERCEL;
delete process.env.CMUX_PUSH_RATE_LIMIT_ID;

const getUser = mock(async () => ({
  id: "user-1",
  displayName: null,
  primaryEmail: null,
  selectedTeam: null,
}));

// Tracks which tables the route touched so we can prove the muted path returns
// before the device-token lookup / APNs send.
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
          // The mute lookup reads notification_workspace_mutes; the device-token
          // path reads device_tokens. Only the former should ever be reached on a
          // muted workspace.
          if (name === mutesTable) {
            return { where: async () => mutedRows };
          }
          return { where: () => ({ limit: async () => [] }) };
        },
      };
    },
  };
}

const cloudDb = mock(() => fakeDb());
const sendApnsNotification = mock(async () => []);

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
}));

mock.module("../db/client", () => ({ cloudDb }));

mock.module("../services/apns/sender", () => ({
  sendApnsNotification,
}));

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
  cloudDb.mockClear();
  sendApnsNotification.mockClear();
  selectedTables.length = 0;
  mutedRows = [];
});

function pushRequest(workspaceId: string): Request {
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
  test("drops the push for a muted workspace before any device-token lookup or APNs send", async () => {
    mutedRows = [{ workspaceId: "ws-muted" }];

    const response = await pushRoute.POST(pushRequest("ws-muted"));

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ muted: true });
    // The mute lookup ran; the device-token lookup and APNs send never did.
    expect(selectedTables).toContain(mutesTable);
    expect(selectedTables).not.toContain(deviceTokensTable);
    expect(sendApnsNotification).not.toHaveBeenCalled();
  });

  test("delivers (reaches the device-token lookup) for a workspace that is not muted", async () => {
    mutedRows = [{ workspaceId: "ws-other" }];

    const response = await pushRoute.POST(pushRequest("ws-active"));

    expect(response.status).toBe(200);
    expect(await response.json()).not.toMatchObject({ muted: true });
    // Not muted => the route proceeds to look up device tokens (none here, so it
    // no-ops without sending), proving the mute gate did not suppress it.
    expect(selectedTables).toContain(mutesTable);
    expect(selectedTables).toContain(deviceTokensTable);
    expect(sendApnsNotification).not.toHaveBeenCalled();
  });
});
