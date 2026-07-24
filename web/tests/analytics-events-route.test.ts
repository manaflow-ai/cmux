import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";
import { checkRateLimit as checkVercelRateLimit } from "@vercel/firewall";

import { makeAnalyticsEventsHandler } from "../app/api/analytics/events/route";
import type { cloudDb } from "../db/client";
import { accountDeletionUserHash } from "../services/account/deletionLock";

const deletedUserID = "3241a285-8329-4d69-8f3d-316e08cf140c";
const originalVercel = process.env.VERCEL;
const originalRateLimitId = process.env.CMUX_CLIENT_CONFIG_RATE_LIMIT_ID;
const originalAnalyticsRateLimitId = process.env.CMUX_ANALYTICS_RATE_LIMIT_ID;
let tombstoneRows: Array<{
  readonly userIdHash: string;
  readonly status: string;
  readonly updatedAt: Date | null;
  readonly analyticsDeletedAt?: Date | null;
}> = [];
let activeLeaseRows = 0;
let leaseInsertCalls = 0;
let leaseDeleteCalls = 0;
let leaseDeleteConditions: unknown[] = [];
let leaseCleanupError: unknown = null;

let postHogFetchError: unknown = null;
let postHogRequestInit: RequestInit | undefined;
const postHogFetch = mock(async (...args: unknown[]) => {
  postHogRequestInit = (args as Parameters<typeof fetch>)[1];
  if (postHogFetchError) throw postHogFetchError;
  return new Response(null, { status: 200 });
});
let rateLimitCalls = 0;
let rateLimitIDs: string[] = [];
let rateLimitResult: Awaited<ReturnType<typeof checkVercelRateLimit>> = { rateLimited: false };
const checkRateLimit: typeof checkVercelRateLimit = async (rateLimitID) => {
  rateLimitCalls += 1;
  rateLimitIDs.push(rateLimitID);
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
  return await operation(analyticsTransactionContext());
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
  process.env.CMUX_ANALYTICS_RATE_LIMIT_ID = "cmux-analytics-test";
  tombstoneRows = [];
  activeLeaseRows = 0;
  leaseInsertCalls = 0;
  leaseDeleteCalls = 0;
  leaseDeleteConditions = [];
  leaseCleanupError = null;
  verifyRequest.mockClear();
  verifyRequest.mockResolvedValue(null);
  selectRows.mockClear();
  transaction.mockClear();
  rateLimitCalls = 0;
  rateLimitIDs = [];
  rateLimitResult = { rateLimited: false };
  postHogFetchError = null;
  postHogRequestInit = undefined;
  postHogFetch.mockClear();
});

afterAll(() => {
  restoreEnv("VERCEL", originalVercel);
  restoreEnv("CMUX_CLIENT_CONFIG_RATE_LIMIT_ID", originalRateLimitId);
  restoreEnv("CMUX_ANALYTICS_RATE_LIMIT_ID", originalAnalyticsRateLimitId);
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

  test("blocks a deleted identity supplied as a PostHog anonymous alias", async () => {
    tombstoneRows = [
      {
        userIdHash: accountDeletionUserHash(deletedUserID),
        status: "completed",
        updatedAt: new Date("2026-07-10T12:00:00.000Z"),
      },
    ];

    const response = await POST(identifyRequest("fresh-install-id", deletedUserID));

    expect(response.status).toBe(410);
    expect(await response.json()).toEqual({ error: "account_deleted" });
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

  test("uses the analytics-specific Vercel rate-limit rule", async () => {
    process.env.VERCEL = "1";

    const response = await POST(analyticsRequest("new-install-id"));

    expect(response.status).toBe(200);
    expect(rateLimitIDs).toEqual(["cmux-analytics-test"]);
  });

  test("forwards a legitimate anonymous install identity", async () => {
    const response = await POST(analyticsRequest("8cb40ef2-af25-49ff-88e8-3ffcc9308174"));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, forwarded: 1 });
    expect(postHogFetch).toHaveBeenCalledTimes(1);
    expect(postHogRequestInit?.signal).toBeInstanceOf(AbortSignal);
    expect(activeLeaseRows).toBe(0);
  });

  test("does not reserve an account-deletion lease for an untrusted anonymous identity", async () => {
    const response = await POST(analyticsRequest(deletedUserID));

    expect(response.status).toBe(200);
    expect(leaseInsertCalls).toBe(0);
  });

  test("namespaces an unauthenticated distinct id away from account identities", async () => {
    const response = await POST(analyticsRequest(deletedUserID, {
      user_id: deletedUserID,
      email: "deleted@example.com",
      screen: "pairing",
    }));

    expect(response.status).toBe(200);
    const [event] = forwardedPostHogBatch();
    expect(event.distinct_id).not.toBe(deletedUserID);
    expect(event.distinct_id).toStartWith("ios-anon-sha256:");
    expect(event.properties).toEqual({});
  });

  test("namespaces the anonymous alias on an authenticated identify event", async () => {
    const anonymousID = "local-install-id";
    verifyRequest.mockResolvedValue({ id: deletedUserID });

    const response = await POST(identifyRequest(deletedUserID, anonymousID));

    expect(response.status).toBe(200);
    const [event] = forwardedPostHogBatch();
    expect(event.distinct_id).toBe(deletedUserID);
    expect(event.properties.$anon_distinct_id).not.toBe(anonymousID);
    expect(event.properties.$anon_distinct_id).toStartWith("ios-anon-sha256:");
  });

  test("prunes expired leases for every identity before reserving a forward", async () => {
    verifyRequest.mockResolvedValue({ id: deletedUserID });
    const response = await POST(analyticsRequest("new-install-id"));

    expect(response.status).toBe(200);
    expect(conditionColumnNames(leaseDeleteConditions[0])).toEqual(["expires_at"]);
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
          return await operation(analyticsTransactionContext());
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

  test("retains the durable lease when PostHog may accept but the client observes a timeout", async () => {
    verifyRequest.mockResolvedValue({ id: deletedUserID });
    postHogFetchError = new DOMException("timed out", "TimeoutError");

    const response = await POST(analyticsRequest(deletedUserID));

    expect(response.status).toBe(502);
    expect(activeLeaseRows).toBe(1);
  });

  test("leaves a bounded durable lease when cleanup fails after a successful forward", async () => {
    verifyRequest.mockResolvedValue({ id: deletedUserID });
    leaseCleanupError = new Error("database unavailable during cleanup");

    const response = await POST(analyticsRequest(deletedUserID));

    expect(response.status).toBe(200);
    expect(activeLeaseRows).toBe(1);
  });
});

function analyticsTransactionContext(): unknown {
  return {
    execute: async () => undefined,
    select: selectRows,
    delete: () => ({
      where: async (condition: unknown) => {
        leaseDeleteCalls += 1;
        leaseDeleteConditions.push(condition);
        if (leaseCleanupError && leaseDeleteCalls > 1) throw leaseCleanupError;
        activeLeaseRows = 0;
      },
    }),
    insert: () => ({
      values: async (values: readonly unknown[]) => {
        leaseInsertCalls += 1;
        activeLeaseRows = values.length;
      },
    }),
  };
}

function conditionColumnNames(condition: unknown): string[] {
  const names: string[] = [];
  const visit = (value: unknown) => {
    if (!value || typeof value !== "object") return;
    const candidate = value as {
      readonly name?: unknown;
      readonly table?: unknown;
      readonly queryChunks?: readonly unknown[];
    };
    if (typeof candidate.name === "string" && candidate.table) names.push(candidate.name);
    if (Array.isArray(candidate.queryChunks)) {
      for (const chunk of candidate.queryChunks) visit(chunk);
    }
  };
  visit(condition);
  return names;
}

function analyticsRequest(
  distinctID: string,
  properties: Record<string, unknown> = {},
): Request {
  return new Request("https://cmux.test/api/analytics/events", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      batch: [
        {
          event: "ios_app_launched",
          distinct_id: distinctID,
          properties,
        },
      ],
    }),
  });
}

function identifyRequest(distinctID: string, anonymousID: string): Request {
  return new Request("https://cmux.test/api/analytics/events", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      batch: [
        {
          event: "$identify",
          distinct_id: distinctID,
          properties: { $anon_distinct_id: anonymousID },
        },
      ],
    }),
  });
}

function forwardedPostHogBatch(): Array<{
  readonly distinct_id: string;
  readonly properties: Record<string, unknown>;
}> {
  const body = JSON.parse(String(postHogRequestInit?.body)) as {
    readonly batch: Array<{
      readonly distinct_id: string;
      readonly properties: Record<string, unknown>;
    }>;
  };
  return body.batch;
}

function restoreEnv(name: string, value: string | undefined): void {
  if (value === undefined) delete process.env[name];
  else process.env[name] = value;
}
