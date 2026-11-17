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
const captureBillingError = mock(() => {});

mock.module("../services/billing/apple/notificationHealth", () => ({
  findAppleTestNotification,
  isAppleNotificationUuid: (value: unknown) =>
    typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value),
}));
mock.module("../services/errors", () => ({ captureBillingError }));

const { GET } = await import("../app/api/cron/apple-notifications/health/route");

const TOKEN_ENV = "APPLE_NOTIFICATIONS_HEALTH_TOKEN";
const original = { token: process.env[TOKEN_ENV], cron: process.env.CRON_SECRET };
const UUID = "6f2a1b3c-4d5e-4f60-8a7b-9c0d1e2f3a4b";

function request(query: string, authorization?: string): Request {
  return new Request(`https://cmux.test/api/cron/apple-notifications/health${query}`, {
    headers: authorization ? { authorization } : {},
  });
}

afterEach(() => {
  receipt = null;
  lookupError = null;
  findAppleTestNotification.mockClear();
  captureBillingError.mockClear();
  for (const [key, value] of [[TOKEN_ENV, original.token], ["CRON_SECRET", original.cron]] as const) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
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

  test("rejects a missing, wrong, or cron token", async () => {
    process.env[TOKEN_ENV] = "health";
    process.env.CRON_SECRET = "cron";
    for (const authorization of [undefined, "Bearer wrong", "Bearer cron", "health", "Basic health"]) {
      const response = await GET(request(`?uuid=${UUID}`, authorization));
      expect(response.status).toBe(401);
      expect(await response.json()).toEqual({ error: "unauthorized" });
    }
    expect(findAppleTestNotification).not.toHaveBeenCalled();
  });

  test("refuses anything but one notification UUID", async () => {
    process.env[TOKEN_ENV] = "health";
    for (const query of ["", "?uuid=", "?uuid=not-a-uuid", `?uuid=${UUID}%27--`, `?uuid=${UUID}x`]) {
      const response = await GET(request(query, "Bearer health"));
      expect(response.status).toBe(400);
      expect(await response.json()).toEqual({ error: "invalid_uuid" });
    }
    expect(findAppleTestNotification).not.toHaveBeenCalled();
  });

  test("reports a TEST notification that has not arrived", async () => {
    process.env[TOKEN_ENV] = "health";
    const response = await GET(request(`?uuid=${UUID}`, "Bearer health"));
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
    process.env[TOKEN_ENV] = "health";
    receipt = {
      receivedAt: new Date("2026-11-16T09:00:01.000Z"),
      processedAt: new Date("2026-11-16T09:00:02.000Z"),
      environment: "Sandbox",
    };
    const response = await GET(request(`?uuid=${UUID}`, "Bearer health"));
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
    process.env[TOKEN_ENV] = "health";
    lookupError = new Error("connection refused at 10.0.0.5:5432");
    const response = await GET(request(`?uuid=${UUID}`, "Bearer health"));
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "lookup_failed", retryable: true });
    expect(captureBillingError).toHaveBeenCalledTimes(1);
  });
});
