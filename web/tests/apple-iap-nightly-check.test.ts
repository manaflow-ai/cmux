// The Billing nightly's Apple checks (scripts/billing/apple-nightly-check.ts):
// request a TEST notification, wait for Apple to report it delivered, then
// confirm our server recorded it; and look up one known subscription. Every
// dependency is a fake, so this runs without Apple or a network.

import { describe, expect, test } from "bun:test";
import { APIException } from "@apple/app-store-server-library";

import * as nightly from "../services/billing/apple/nightlyCheck";
import {
  appleClientForNightly,
  checkAppleDelivery,
  checkServerApi,
  type NightlyAppleClient,
} from "../services/billing/apple/nightlyCheck";

const UUID = "6f2a1b3c-4d5e-4f60-8a7b-9c0d1e2f3a4b";

function jws(payload: object): string {
  const part = (value: object) => Buffer.from(JSON.stringify(value)).toString("base64url");
  return `${part({ alg: "ES256" })}.${part(payload)}.c2ln`;
}

function clock() {
  let now = Date.parse("2026-11-16T09:00:00Z");
  const waits: number[] = [];
  return {
    waits,
    now: () => now,
    wait: async (ms: number) => {
      waits.push(ms);
      now += ms;
    },
  };
}

type Status = Awaited<ReturnType<NightlyAppleClient["getTestNotificationStatus"]>>;

function client(statuses: Status[], overrides: Partial<NightlyAppleClient> = {}): NightlyAppleClient {
  let index = 0;
  return {
    requestTestNotification: async () => "token-1",
    getTestNotificationStatus: async () => statuses[Math.min(index++, statuses.length - 1)]!,
    subscriptionStatus: async () => null,
    ...overrides,
  };
}

const delivered: Status = {
  signedPayload: jws({ notificationType: "TEST", notificationUUID: UUID }),
  sendAttempts: [{ attemptDate: Date.parse("2026-11-16T09:00:03Z"), sendAttemptResult: "SUCCESS" }],
};

function health(bodies: { status: number; body: unknown }[]) {
  const seen: string[] = [];
  let index = 0;
  return {
    seen,
    read: async (uuid: string) => {
      seen.push(uuid);
      return bodies[Math.min(index++, bodies.length - 1)]!;
    },
  };
}

const recorded = {
  status: 200,
  body: {
    found: true,
    environment: "Sandbox",
    receivedAt: "2026-11-16T09:00:03.100Z",
    processed: true,
    processedAt: "2026-11-16T09:00:03.200Z",
  },
};
const notYet = {
  status: 200,
  body: { found: false, environment: null, receivedAt: null, processed: false, processedAt: null },
};

describe("Apple delivery round trip", () => {
  test("passes once Apple delivered it and our ledger has it", async () => {
    const reads = health([notYet, recorded]);
    const report = await checkAppleDelivery({
      client: client([{ sendAttempts: [] }, delivered]),
      readHealth: reads.read,
      clock: clock(),
      environment: "Sandbox",
    });
    expect(report).toMatchObject({
      ok: true,
      failure: null,
      notificationUuid: UUID,
      appleDelivered: true,
      recorded: true,
      receivedAt: "2026-11-16T09:00:03.100Z",
      attempts: [{ at: "2026-11-16T09:00:03.000Z", result: "SUCCESS" }],
    });
    expect(reads.seen).toEqual([UUID, UUID]);
  });

  test("keeps polling while Apple has not made an attempt yet", async () => {
    const notFound = new APIException(404, 4040008, "Test notification not found");
    let calls = 0;
    const c = clock();
    const report = await checkAppleDelivery({
      client: appleClientForNightly({
        requestTestNotification: async () => ({ testNotificationToken: "token-1" }),
        getTestNotificationStatus: async () => {
          calls += 1;
          if (calls < 3) throw notFound;
          return delivered;
        },
        getAllSubscriptionStatuses: async () => ({}),
      }),
      readHealth: health([recorded]).read,
      clock: c,
      environment: "Sandbox",
    });
    expect(report.ok).toBe(true);
    expect(calls).toBe(3);
    expect(c.waits.length).toBe(2);
  });

  test("fails with Apple's own result when the delivery attempt failed", async () => {
    const report = await checkAppleDelivery({
      client: client([{
        signedPayload: delivered.signedPayload,
        sendAttempts: [{ attemptDate: Date.parse("2026-11-16T09:00:03Z"), sendAttemptResult: "TLS_ISSUE" }],
      }]),
      readHealth: health([recorded]).read,
      clock: clock(),
      environment: "Sandbox",
    });
    expect(report.ok).toBe(false);
    expect(report.appleDelivered).toBe(false);
    expect(report.failure).toContain("TLS_ISSUE");
  });

  test("fails when Apple never attempts within the deadline", async () => {
    const c = clock();
    const report = await checkAppleDelivery({
      client: client([{ sendAttempts: [] }]),
      readHealth: health([recorded]).read,
      clock: c,
      environment: "Sandbox",
      timeoutMs: 60_000,
      intervalMs: 10_000,
    });
    expect(report.ok).toBe(false);
    expect(report.failure).toContain("no delivery attempt");
    expect(c.now() - Date.parse("2026-11-16T09:00:00Z")).toBeLessThanOrEqual(60_000);
  });

  test("fails when Apple delivered but our ledger never shows it", async () => {
    const report = await checkAppleDelivery({
      client: client([delivered]),
      readHealth: health([notYet]).read,
      clock: clock(),
      environment: "Sandbox",
      ledgerTimeoutMs: 30_000,
      intervalMs: 10_000,
    });
    expect(report).toMatchObject({ ok: false, appleDelivered: true, recorded: false });
    expect(report.failure).toContain("not recorded");
  });

  test("gives the ledger its own budget however late Apple attempted", async () => {
    const c = clock();
    const reads = health([notYet, notYet, recorded]);
    const report = await checkAppleDelivery({
      client: client([{ sendAttempts: [] }, { sendAttempts: [] }, delivered]),
      readHealth: reads.read,
      clock: c,
      environment: "Sandbox",
      timeoutMs: 20_000,
      ledgerTimeoutMs: 20_000,
      intervalMs: 10_000,
    });
    expect(report.ok).toBe(true);
    expect(reads.seen.length).toBe(3);
  });

  test("fails when the ledger has it under the other environment", async () => {
    const report = await checkAppleDelivery({
      client: client([delivered]),
      readHealth: health([recorded]).read,
      clock: clock(),
      environment: "Production",
    });
    expect(report.ok).toBe(false);
    expect(report.failure).toContain("as Sandbox, not Production");
  });

  test("stops at once on a health endpoint configuration error", async () => {
    const reads = health([{ status: 401, body: { error: "unauthorized" } }]);
    const report = await checkAppleDelivery({
      client: client([delivered]),
      readHealth: reads.read,
      clock: clock(),
      environment: "Sandbox",
    });
    expect(report.ok).toBe(false);
    expect(report.failure).toContain("401");
    expect(reads.seen.length).toBe(1);
  });

  test("names the request failure when Apple refuses the key", async () => {
    const report = await checkAppleDelivery({
      client: appleClientForNightly({
        requestTestNotification: async () => {
          throw new APIException(401, null, "Unauthenticated");
        },
        getTestNotificationStatus: async () => delivered,
        getAllSubscriptionStatuses: async () => ({}),
      }),
      readHealth: health([recorded]).read,
      clock: clock(),
      environment: "Sandbox",
    });
    expect(report.ok).toBe(false);
    expect(report.failure).toContain("HTTP 401");
  });

  test("fails when the signed payload carries no notification UUID", async () => {
    const report = await checkAppleDelivery({
      client: client([{ ...delivered, signedPayload: "not-a-jws" }]),
      readHealth: health([recorded]).read,
      clock: clock(),
      environment: "Sandbox",
    });
    expect(report.ok).toBe(false);
    expect(report.failure).toContain("UUID");
  });
});

describe("Production delivery before the first App Store release", () => {
  const refusingProduction = () => appleClientForNightly({
    requestTestNotification: async () => {
      throw new APIException(401, null, null);
    },
    getTestNotificationStatus: async () => delivered,
    getAllSubscriptionStatuses: async () => ({}),
  });

  test("a Production 401 with a working Sandbox is a neutral note while no release is recorded", async () => {
    let probes = 0;
    const report = await checkAppleDelivery({
      client: refusingProduction(),
      readHealth: health([recorded]).read,
      clock: clock(),
      environment: "Production",
      productionLock: { sandboxAccepts: async () => (probes += 1) > 0, released: false },
    } as Parameters<typeof checkAppleDelivery>[0]);
    expect(report).toMatchObject({ ok: true, failure: null, lockedUntilRelease: true, appleDelivered: false });
    expect((report as { note?: string | null }).note).toContain("first App Store release");
    expect(probes).toBe(1);
  });

  test("goes red once the release is recorded (APPLE_IAP_PRODUCTION_RELEASED=1)", async () => {
    const report = await checkAppleDelivery({
      client: refusingProduction(),
      readHealth: health([recorded]).read,
      clock: clock(),
      environment: "Production",
      productionLock: { sandboxAccepts: async () => true, released: true },
    } as Parameters<typeof checkAppleDelivery>[0]);
    expect(report.ok).toBe(false);
    expect(report.failure).toContain("APPLE_IAP_PRODUCTION_RELEASED");
  });

  test("a Sandbox that refuses the key too is a credential failure", async () => {
    const report = await checkAppleDelivery({
      client: refusingProduction(),
      readHealth: health([recorded]).read,
      clock: clock(),
      environment: "Production",
      productionLock: { sandboxAccepts: async () => false, released: false },
    } as Parameters<typeof checkAppleDelivery>[0]);
    expect(report.ok).toBe(false);
    expect(report.failure).toContain("Sandbox refused the key too");
  });

  test("a Sandbox 401 stays a failure whatever the release state", async () => {
    const report = await checkAppleDelivery({
      client: refusingProduction(),
      readHealth: health([recorded]).read,
      clock: clock(),
      environment: "Sandbox",
      productionLock: { sandboxAccepts: async () => true, released: false },
    } as Parameters<typeof checkAppleDelivery>[0]);
    expect(report.ok).toBe(false);
    expect(report.failure).toContain("HTTP 401");
  });

  test("the Sandbox probe reads the notification history: an answer accepts, a 401 refuses, anything else throws", async () => {
    const probe = (nightly as unknown as {
      sandboxAcceptsKey?: (api: { getNotificationHistory(token: string | null, request: object): Promise<unknown> }, nowMs: number) => Promise<boolean>;
    }).sandboxAcceptsKey;
    expect(typeof probe).toBe("function");
    const at = Date.parse("2026-11-16T09:00:00Z");
    expect(await probe!({ getNotificationHistory: async () => ({ notificationHistory: [] }) }, at)).toBe(true);
    expect(await probe!({ getNotificationHistory: async () => {
      throw new APIException(401, null, null);
    } }, at)).toBe(false);
    await expect(probe!({ getNotificationHistory: async () => {
      throw new APIException(500, null, null);
    } }, at)).rejects.toBeInstanceOf(APIException);
  });
});

describe("App Store Server API health", () => {
  test("passes when the known subscription has a status", async () => {
    const report = await checkServerApi({
      client: client([], { subscriptionStatus: async () => ({ status: 2 }) }),
      originalTransactionId: "2000000123456789",
    });
    expect(report).toEqual({ ok: true, status: 2, failure: null });
  });

  test("fails when Apple has no status for it", async () => {
    const report = await checkServerApi({
      client: client([], { subscriptionStatus: async () => null }),
      originalTransactionId: "2000000123456789",
    });
    expect(report.ok).toBe(false);
    expect(report.failure).toContain("no status");
  });

  test("fails with the HTTP status when the lookup throws", async () => {
    const report = await checkServerApi({
      client: appleClientForNightly({
        requestTestNotification: async () => ({}),
        getTestNotificationStatus: async () => ({}),
        getAllSubscriptionStatuses: async () => {
          throw new APIException(401, null, null);
        },
      }),
      originalTransactionId: "2000000123456789",
    });
    expect(report.ok).toBe(false);
    expect(report.failure).toContain("HTTP 401");
  });
});
