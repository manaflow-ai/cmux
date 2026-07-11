import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";

import { accountDeletionUserHash } from "../services/account/deletionLock";

const deletedUserID = "3241a285-8329-4d69-8f3d-316e08cf140c";
let authenticatedUser: { readonly id: string } | null = null;
let tombstoneRows: Array<{
  readonly userIdHash: string;
  readonly status: string;
  readonly updatedAt: Date | null;
}> = [];

const verifyRequest = mock(async () => authenticatedUser);
const postHogFetch = mock(async () => new Response(null, { status: 200 }));

mock.module("../services/vms/auth", () => ({
  unauthorized: () => Response.json({ error: "unauthorized" }, { status: 401 }),
  verifyRequest,
}));
mock.module("../db/client", () => ({
  cloudDb: () => ({
    select: () => ({
      from: () => ({
        where: async () => tombstoneRows,
      }),
    }),
  }),
}));

const originalFetch = globalThis.fetch;
globalThis.fetch = postHogFetch as unknown as typeof fetch;
const { POST } = await import("../app/api/analytics/events/route");

beforeEach(() => {
  authenticatedUser = null;
  tombstoneRows = [];
  verifyRequest.mockClear();
  postHogFetch.mockClear();
  postHogFetch.mockResolvedValue(new Response(null, { status: 200 }));
});

afterAll(() => {
  globalThis.fetch = originalFetch;
});

describe("iOS analytics events route", () => {
  test("rejects a queued deleted-account identity after authentication is gone", async () => {
    tombstoneRows = [{
      userIdHash: accountDeletionUserHash(deletedUserID),
      status: "completed",
      updatedAt: new Date("2026-07-10T12:00:00.000Z"),
    }];

    const response = await POST(analyticsRequest(deletedUserID));

    expect(response.status).toBe(410);
    expect(await response.json()).toEqual({ error: "account_deleted" });
    expect(postHogFetch).not.toHaveBeenCalled();
  });

  test("forwards a legitimate anonymous install identity", async () => {
    const response = await POST(
      analyticsRequest("8cb40ef2-af25-49ff-88e8-3ffcc9308174"),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, forwarded: 1 });
    expect(postHogFetch).toHaveBeenCalledTimes(1);
  });
});

function analyticsRequest(distinctID: string): Request {
  return new Request("https://cmux.test/api/analytics/events", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      batch: [{
        event: "ios_app_launched",
        distinct_id: distinctID,
        properties: {},
      }],
    }),
  });
}
