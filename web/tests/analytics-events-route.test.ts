import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";
import { checkRateLimit as checkVercelRateLimit } from "@vercel/firewall";

import { makeAnalyticsEventsHandler } from "../app/api/analytics/events/route";
import type { cloudDb } from "../db/client";
import { accountDeletionUserHash } from "../services/account/deletionLock";

const deletedUserID = "3241a285-8329-4d69-8f3d-316e08cf140c";
const originalVercel = process.env.VERCEL;
const originalRateLimitId = process.env.CMUX_CLIENT_CONFIG_RATE_LIMIT_ID;
let tombstoneRows: Array<{
  readonly userIdHash: string;
  readonly status: string;
  readonly updatedAt: Date | null;
  readonly analyticsDeletedAt?: Date | null;
}> = [];

const postHogFetch = mock(async () => new Response(null, { status: 200 }));
let rateLimitCalls = 0;
let rateLimitResult: Awaited<ReturnType<typeof checkVercelRateLimit>> = { rateLimited: false };
const checkRateLimit: typeof checkVercelRateLimit = async () => {
  rateLimitCalls += 1;
  return rateLimitResult;
};
const verifyRequest = mock(async () => null);
const selectRows = mock(() => ({
  from: () => ({
    where: async () => tombstoneRows,
  }),
}));
const transaction = mock(async (...args: unknown[]) => {
  const operation = args[0] as (tx: unknown) => Promise<unknown>;
  return await operation({
    execute: async () => undefined,
    select: selectRows,
  });
});
const db = {
  select: selectRows,
  transaction,
} as unknown as ReturnType<typeof cloudDb>;
const POST = makeAnalyticsEventsHandler({
  verifyRequest,
  db: () => db,
  postHogFetch,
  checkRateLimit,
});

beforeEach(() => {
  delete process.env.VERCEL;
  process.env.CMUX_CLIENT_CONFIG_RATE_LIMIT_ID = "cmux-client-config-test";
  tombstoneRows = [];
  verifyRequest.mockClear();
  selectRows.mockClear();
  transaction.mockClear();
  rateLimitCalls = 0;
  rateLimitResult = { rateLimited: false };
  postHogFetch.mockClear();
  postHogFetch.mockResolvedValue(new Response(null, { status: 200 }));
});

afterAll(() => {
  restoreEnv("VERCEL", originalVercel);
  restoreEnv("CMUX_CLIENT_CONFIG_RATE_LIMIT_ID", originalRateLimitId);
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
    rateLimitResult = { rateLimited: true };

    const response = await POST(new Request("https://cmux.test/api/analytics/events", {
      method: "POST",
      body: "{not-json",
    }));

    expect(response.status).toBe(429);
    expect(rateLimitCalls).toBe(1);
    expect(verifyRequest).not.toHaveBeenCalled();
    expect(selectRows).not.toHaveBeenCalled();
    expect(postHogFetch).not.toHaveBeenCalled();
  });

  test("forwards a legitimate anonymous install identity", async () => {
    const response = await POST(analyticsRequest("8cb40ef2-af25-49ff-88e8-3ffcc9308174"));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, forwarded: 1 });
    expect(postHogFetch).toHaveBeenCalledTimes(1);
  });

  test("releases the database transaction while an analytics forward is in flight", async () => {
    let transactionTail = Promise.resolve();
    let transactionActive = false;
    let releaseForward: (() => void) | undefined;
    let markForwardStarted: (() => void) | undefined;
    const forwardStarted = new Promise<void>((resolve) => {
      markForwardStarted = resolve;
    });
    const forwardReleased = new Promise<void>((resolve) => {
      releaseForward = resolve;
    });
    const transactionDb = {
      select: selectRows,
      transaction: async (operation: (tx: unknown) => Promise<unknown>) => {
        const previousTransaction = transactionTail;
        let releaseTransaction: (() => void) | undefined;
        transactionTail = new Promise<void>((resolve) => {
          releaseTransaction = resolve;
        });
        await previousTransaction;
        transactionActive = true;
        try {
          return await operation({
            execute: async () => undefined,
            select: selectRows,
          });
        } finally {
          transactionActive = false;
          releaseTransaction?.();
        }
      },
    } as unknown as ReturnType<typeof cloudDb>;
    const handler = makeAnalyticsEventsHandler({
      verifyRequest,
      db: () => transactionDb,
      postHogFetch: async () => {
        markForwardStarted?.();
        await forwardReleased;
        return new Response(null, { status: 200 });
      },
      checkRateLimit,
    });

    const analyticsResponse = handler(analyticsRequest(deletedUserID));
    await forwardStarted;
    const transactionWasReleased = !transactionActive;

    releaseForward?.();
    expect((await analyticsResponse).status).toBe(200);
    expect(transactionWasReleased).toBe(true);
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

function restoreEnv(name: string, value: string | undefined): void {
  if (value === undefined) delete process.env[name];
  else process.env[name] = value;
}
