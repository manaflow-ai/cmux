import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";

import { makeAnalyticsEventsHandler } from "../app/api/analytics/events/route";
import type { cloudDb } from "../db/client";
import { accountDeletionUserHash } from "../services/account/deletionLock";
import { checkRateLimit } from "./vercel-firewall-mock";

const deletedUserID = "3241a285-8329-4d69-8f3d-316e08cf140c";
let tombstoneRows: Array<{
  readonly userIdHash: string;
  readonly status: string;
  readonly updatedAt: Date | null;
  readonly analyticsDeletedAt?: Date | null;
}> = [];

const postHogFetch = mock(async () => new Response(null, { status: 200 }));
const db = {
  select: () => ({
    from: () => ({
      where: async () => tombstoneRows,
    }),
  }),
} as unknown as ReturnType<typeof cloudDb>;
const POST = makeAnalyticsEventsHandler({
  verifyRequest: async () => null,
  db: () => db,
  postHogFetch,
});

beforeEach(() => {
  delete process.env.VERCEL;
  process.env.CMUX_CLIENT_CONFIG_RATE_LIMIT_ID = "cmux-client-config-test";
  tombstoneRows = [];
  checkRateLimit.mockClear();
  checkRateLimit.mockResolvedValue({ rateLimited: false, error: null });
  postHogFetch.mockClear();
  postHogFetch.mockResolvedValue(new Response(null, { status: 200 }));
});

afterAll(() => {
  delete process.env.VERCEL;
});

describe("iOS analytics events route", () => {
  test("rejects a queued deleted-account identity after authentication is gone", async () => {
    tombstoneRows = [
      {
        userIdHash: accountDeletionUserHash(deletedUserID),
        status: "completed",
        updatedAt: new Date("2026-07-10T12:00:00.000Z"),
      },
    ];

    const response = await POST(analyticsRequest(deletedUserID));

    expect(response.status).toBe(410);
    expect(await response.json()).toEqual({ error: "account_deleted" });
    expect(postHogFetch).not.toHaveBeenCalled();
  });

  test("keeps a failed deletion identity blocked after analytics deletion completed", async () => {
    tombstoneRows = [
      {
        userIdHash: accountDeletionUserHash(deletedUserID),
        status: "failed",
        updatedAt: new Date("2026-07-10T12:00:00.000Z"),
        analyticsDeletedAt: new Date("2026-07-10T11:59:00.000Z"),
      },
    ];

    const response = await POST(analyticsRequest(deletedUserID));

    expect(response.status).toBe(410);
    expect(postHogFetch).not.toHaveBeenCalled();
  });

  test("rate limits Vercel analytics ingress before database access", async () => {
    process.env.VERCEL = "1";
    checkRateLimit.mockResolvedValue({ rateLimited: true, error: null });

    const response = await POST(analyticsRequest("8cb40ef2-af25-49ff-88e8-3ffcc9308174"));

    expect(response.status).toBe(429);
    expect(checkRateLimit).toHaveBeenCalledTimes(1);
    expect(postHogFetch).not.toHaveBeenCalled();
  });

  test("forwards a legitimate anonymous install identity", async () => {
    const response = await POST(analyticsRequest("8cb40ef2-af25-49ff-88e8-3ffcc9308174"));

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
      batch: [
        {
          event: "ios_app_launched",
          distinct_id: distinctID,
          properties: {},
        },
      ],
    }),
  });
}
