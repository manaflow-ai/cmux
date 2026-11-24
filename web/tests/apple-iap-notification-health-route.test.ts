// The authenticated read the Billing nightly uses to confirm that an App Store
// TEST notification Apple says it delivered landed in apple_notifications.
// It must fail closed, accept only its own token, and answer only booleans
// and timestamps about TEST notifications, never a payload.

import { afterEach, describe, expect, mock, test } from "bun:test";

type Receipt = { receivedAt: Date; processedAt: Date | null; environment: string };

let receipt: Receipt | null = null;
let lookupError: Error | null = null;
const findAppleTestNotification = mock(async (_uuid: string): Promise<Receipt | null> => {
  if (lookupError) throw lookupError;
  return receipt;
});
type CursorRow = {
  nextStartAt: Date; windowStartAt: Date | null; windowEndAt: Date | null;
  paginationToken: string | null; retryableRuns: number; updatedAt: Date;
};
let cursorRow: CursorRow | null = null;
const findAppleHistoryCursor = mock(async (_bundleId: string, _environment: string): Promise<CursorRow | null> => cursorRow);
const captureBillingError = mock(() => {});

// Only the database read is replaced; the route's UUID validator is the real one.
const realHealth = await import("../services/billing/apple/notificationHealth");
const { isAppleNotificationUuid } = realHealth;
mock.module("../services/billing/apple/notificationHealth", () => ({
  ...realHealth,
  findAppleTestNotification,
  findAppleHistoryCursor,
}));
mock.module("../services/errors", () => ({ captureBillingError }));

const { GET } = await import("../app/api/cron/apple-notifications/health/route");

const TOKEN_ENV = "APPLE_NOTIFICATIONS_HEALTH_TOKEN";
const original = { token: process.env[TOKEN_ENV], cron: process.env.CRON_SECRET };
const UUID = "6f2a1b3c-4d5e-4f60-8a7b-9c0d1e2f3a4b";
const HEALTH = "h".repeat(32);

function request(query: string, authorization?: string): Request {
  return new Request(`https://cmux.test/api/cron/apple-notifications/health${query}`, {
    headers: authorization ? { authorization } : {},
  });
}

afterEach(() => {
  receipt = null;
  lookupError = null;
  cursorRow = null;
  findAppleHistoryCursor.mockClear();
  findAppleTestNotification.mockClear();
  captureBillingError.mockClear();
  for (const [key, value] of [[TOKEN_ENV, original.token], ["CRON_SECRET", original.cron]] as const) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
});

describe("Apple notification UUID validator", () => {
  test("accepts only one UUID", () => {
    expect(isAppleNotificationUuid(UUID)).toBe(true);
    expect(isAppleNotificationUuid(UUID.toUpperCase())).toBe(true);
    for (const value of [null, undefined, 42, "", "not-a-uuid", `${UUID}x`, ` ${UUID}`, `${UUID}\n`, `${UUID}'--`, UUID.replaceAll("-", "")]) {
      expect(isAppleNotificationUuid(value)).toBe(false);
    }
  });
});

describe("Apple notification health", () => {
  test("fails closed when the deployment has no health token", async () => {
    delete process.env[TOKEN_ENV];
    process.env.CRON_SECRET = "cron";
    const response = await GET(request(`?uuid=${UUID}`, "Bearer cron"));
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "health_token_missing" });
    expect(findAppleTestNotification).not.toHaveBeenCalled();
  });

  test("treats a token shorter than 32 characters as unset", async () => {
    process.env[TOKEN_ENV] = "short-token";
    const response = await GET(request(`?uuid=${UUID}`, "Bearer short-token"));
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "health_token_missing" });
    expect(findAppleTestNotification).not.toHaveBeenCalled();
  });

  test("rejects a missing, wrong, or cron token", async () => {
    process.env[TOKEN_ENV] = HEALTH;
    process.env.CRON_SECRET = "cron";
    for (const authorization of [undefined, "Bearer wrong", "Bearer cron", HEALTH, `Basic ${HEALTH}`, `Bearer ${HEALTH}x`]) {
      const response = await GET(request(`?uuid=${UUID}`, authorization));
      expect(response.status).toBe(401);
      expect(response.headers.get("cache-control")).toBe("no-store");
      expect(await response.json()).toEqual({ error: "unauthorized" });
    }
    expect(findAppleTestNotification).not.toHaveBeenCalled();
  });

  test("refuses anything but one notification UUID", async () => {
    process.env[TOKEN_ENV] = HEALTH;
    for (const query of ["", "?uuid=", "?uuid=not-a-uuid", `?uuid=${UUID}%27--`, `?uuid=${UUID}x`]) {
      const response = await GET(request(query, `Bearer ${HEALTH}`));
      expect(response.status).toBe(400);
      expect(response.headers.get("cache-control")).toBe("no-store");
      expect(await response.json()).toEqual({ error: "invalid_uuid" });
    }
    expect(findAppleTestNotification).not.toHaveBeenCalled();
  });

  test("reports a TEST notification that has not arrived", async () => {
    process.env[TOKEN_ENV] = HEALTH;
    const response = await GET(request(`?uuid=${UUID}`, `Bearer ${HEALTH}`));
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({
      found: false,
      environment: null,
      receivedAt: null,
      processed: false,
      processedAt: null,
    });
    expect(findAppleTestNotification).toHaveBeenCalledWith(UUID);
  });

  test("reports only booleans, timestamps and the environment of a recorded one", async () => {
    process.env[TOKEN_ENV] = HEALTH;
    receipt = {
      receivedAt: new Date("2026-11-16T09:00:01.000Z"),
      processedAt: new Date("2026-11-16T09:00:02.000Z"),
      environment: "Sandbox",
    };
    const response = await GET(request(`?uuid=${UUID}`, `Bearer ${HEALTH}`));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      found: true,
      environment: "Sandbox",
      receivedAt: "2026-11-16T09:00:01.000Z",
      processed: true,
      processedAt: "2026-11-16T09:00:02.000Z",
    });
  });

  test("answers a retryable 503 without detail when the lookup fails", async () => {
    process.env[TOKEN_ENV] = HEALTH;
    lookupError = new Error("connection refused at 10.0.0.5:5432");
    const response = await GET(request(`?uuid=${UUID}`, `Bearer ${HEALTH}`));
    expect(response.status).toBe(503);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({ error: "lookup_failed", retryable: true });
    expect(captureBillingError).toHaveBeenCalledTimes(1);
  });
});

describe("Apple notification history cursor read (post-release check)", () => {
  test("refuses anything but an accepted bundle and a signed environment", async () => {
    process.env[TOKEN_ENV] = HEALTH;
    for (const query of ["?cursor=Xcode&bundle=com.cmux.app", "?cursor=Production&bundle=com.example.app", "?cursor=Production", "?cursor=&bundle=com.cmux.app"]) {
      const response = await GET(request(query, `Bearer ${HEALTH}`));
      expect(response.status).toBe(400);
      expect(await response.json()).toEqual({ error: "invalid_cursor" });
    }
    expect(findAppleHistoryCursor).not.toHaveBeenCalled();
  });

  test("needs the health token like the UUID read", async () => {
    process.env[TOKEN_ENV] = HEALTH;
    const response = await GET(request("?cursor=Production&bundle=com.cmux.app", "Bearer wrong"));
    expect(response.status).toBe(401);
    expect(findAppleHistoryCursor).not.toHaveBeenCalled();
  });

  test("reports where the cursor is, with an opaque position and never Apple's pagination token", async () => {
    process.env[TOKEN_ENV] = HEALTH;
    cursorRow = {
      nextStartAt: new Date("2026-06-06T00:00:00.000Z"),
      windowStartAt: new Date("2026-06-06T00:00:00.000Z"),
      windowEndAt: new Date("2026-06-07T00:00:00.000Z"),
      paginationToken: "apple-secret-token",
      retryableRuns: 2,
      updatedAt: new Date("2026-12-01T08:47:00.000Z"),
    };
    const response = await GET(request("?cursor=Production&bundle=com.cmux.app", `Bearer ${HEALTH}`));
    expect(response.status).toBe(200);
    const body = await response.json() as Record<string, unknown>;
    expect(findAppleHistoryCursor).toHaveBeenCalledWith("com.cmux.app", "Production");
    expect(body).toMatchObject({
      found: true,
      nextStartAt: "2026-06-06T00:00:00.000Z",
      windowStartAt: "2026-06-06T00:00:00.000Z",
      windowEndAt: "2026-06-07T00:00:00.000Z",
      pagePending: true,
      retryableRuns: 2,
      updatedAt: "2026-12-01T08:47:00.000Z",
    });
    expect(typeof body.position).toBe("string");
    expect(JSON.stringify(body)).not.toContain("apple-secret-token");

    // A new page moves the position even when the window stays the same.
    cursorRow = { ...cursorRow, paginationToken: "apple-next-token" };
    const next = await (await GET(request("?cursor=Production&bundle=com.cmux.app", `Bearer ${HEALTH}`))).json() as Record<string, unknown>;
    expect(next.position).not.toBe(body.position);
  });

  test("reports a cursor that does not exist yet", async () => {
    process.env[TOKEN_ENV] = HEALTH;
    const response = await GET(request("?cursor=Production&bundle=com.cmux.app", `Bearer ${HEALTH}`));
    expect(await response.json()).toEqual({
      found: false, position: null, nextStartAt: null, windowStartAt: null, windowEndAt: null,
      pagePending: false, retryableRuns: 0, updatedAt: null,
    });
  });
});
