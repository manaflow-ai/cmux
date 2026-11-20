// The one-command check after the first App Store release
// (`bun scripts/billing/apple-nightly-check.ts post-release`, or the Billing
// nightly's `post_release_check` dispatch): a Production TEST notification is
// delivered and stored, a Production notification-history call answers, and
// the Production backfill cursor advances. Every step reports pass or fail.

import { describe, expect, test } from "bun:test";
import { APIException } from "@apple/app-store-server-library";

import * as nightly from "../services/billing/apple/nightlyCheck";

type Health = { status: number; body: unknown };
type PostReleaseInput = {
  client: nightly.NightlyAppleClient;
  readHealth: nightly.HealthReader;
  readCursor: () => Promise<Health>;
  productionHistory: () => Promise<number>;
  clock: nightly.NightlyClock;
  cursorTimeoutMs?: number;
  cursorIntervalMs?: number;
  intervalMs?: number;
};
type PostReleaseReport = { ok: boolean; steps: { name: string; ok: boolean; detail: string }[] };

const checkPostRelease = (nightly as unknown as {
  checkPostRelease?: (input: PostReleaseInput) => Promise<PostReleaseReport>;
}).checkPostRelease;

const UUID = "6f2a1b3c-4d5e-4f60-8a7b-9c0d1e2f3a4b";

function jws(payload: object): string {
  const part = (value: object) => Buffer.from(JSON.stringify(value)).toString("base64url");
  return `${part({ alg: "ES256" })}.${part(payload)}.c2ln`;
}

const delivered = {
  signedPayload: jws({ notificationType: "TEST", notificationUUID: UUID }),
  sendAttempts: [{ attemptDate: Date.parse("2026-12-01T09:00:03Z"), sendAttemptResult: "SUCCESS" }],
};

function clock() {
  let now = Date.parse("2026-12-01T09:00:00Z");
  return { now: () => now, wait: async (ms: number) => void (now += ms) };
}

const client = (overrides: Partial<nightly.NightlyAppleClient> = {}): nightly.NightlyAppleClient => ({
  requestTestNotification: async () => "token-1",
  getTestNotificationStatus: async () => delivered,
  subscriptionStatus: async () => null,
  ...overrides,
});

const stored: Health = {
  status: 200,
  body: { found: true, environment: "Production", receivedAt: "2026-12-01T09:00:03.100Z", processed: true, processedAt: "2026-12-01T09:00:03.200Z" },
};

const cursor = (position: string | null, found = true): Health => ({
  status: 200,
  body: { found, position, nextStartAt: "2026-06-06T00:00:00.000Z", pagePending: false, retryableRuns: 0, updatedAt: "2026-12-01T08:47:00.000Z" },
});

function cursors(answers: Health[]) {
  let index = 0;
  return async () => answers[Math.min(index++, answers.length - 1)]!;
}

function stepNamed(report: PostReleaseReport, name: string) {
  return report.steps.find((step) => step.name === name);
}

describe("post-release check", () => {
  test("is exported", () => {
    expect(typeof checkPostRelease).toBe("function");
  });

  test("passes when delivery, storage, history and the cursor all move", async () => {
    const report = await checkPostRelease!({
      client: client(),
      readHealth: async () => stored,
      readCursor: cursors([cursor("a"), cursor("a"), cursor("b")]),
      productionHistory: async () => 3,
      clock: clock(),
      cursorTimeoutMs: 10 * 60_000,
      cursorIntervalMs: 60_000,
    });
    expect(report.ok).toBe(true);
    expect(report.steps.map((step) => [step.name, step.ok])).toEqual([
      ["delivery", true],
      ["stored", true],
      ["history", true],
      ["cursor", true],
    ]);
    expect(stepNamed(report, "history")?.detail).toContain("3");
  });

  test("a first cursor where there was none counts as moving", async () => {
    const report = await checkPostRelease!({
      client: client(),
      readHealth: async () => stored,
      readCursor: cursors([cursor(null, false), cursor("a")]),
      productionHistory: async () => 0,
      clock: clock(),
    });
    expect(stepNamed(report, "cursor")).toMatchObject({ ok: true });
  });

  test("a Production 401 fails delivery outright: after the release it is never the lock", async () => {
    const report = await checkPostRelease!({
      client: nightly.appleClientForNightly({
        requestTestNotification: async () => {
          throw new APIException(401, null, null);
        },
        getTestNotificationStatus: async () => delivered,
        getAllSubscriptionStatuses: async () => ({}),
      }),
      readHealth: async () => stored,
      readCursor: cursors([cursor("a"), cursor("b")]),
      productionHistory: async () => 0,
      clock: clock(),
    });
    expect(report.ok).toBe(false);
    expect(stepNamed(report, "delivery")).toMatchObject({ ok: false });
    expect(stepNamed(report, "delivery")?.detail).toContain("HTTP 401");
    expect(stepNamed(report, "stored")).toMatchObject({ ok: false });
  });

  test("delivered but not stored fails the stored step only", async () => {
    const report = await checkPostRelease!({
      client: client(),
      readHealth: async () => ({ status: 200, body: { found: false } }),
      readCursor: cursors([cursor("a"), cursor("b")]),
      productionHistory: async () => 1,
      clock: clock(),
      intervalMs: 10_000,
    });
    expect(stepNamed(report, "delivery")).toMatchObject({ ok: true });
    expect(stepNamed(report, "stored")).toMatchObject({ ok: false });
    expect(report.ok).toBe(false);
  });

  test("a failing history call fails the history step", async () => {
    const report = await checkPostRelease!({
      client: client(),
      readHealth: async () => stored,
      readCursor: cursors([cursor("a"), cursor("b")]),
      productionHistory: async () => {
        throw new APIException(401, null, null);
      },
      clock: clock(),
    });
    expect(stepNamed(report, "history")).toMatchObject({ ok: false });
    expect(stepNamed(report, "history")?.detail).toContain("HTTP 401");
    expect(report.ok).toBe(false);
  });

  test("a cursor that does not move within the wait fails, naming the stall count", async () => {
    const c = clock();
    const report = await checkPostRelease!({
      client: client(),
      readHealth: async () => stored,
      readCursor: cursors([{ ...cursor("a"), body: { ...(cursor("a").body as object), retryableRuns: 4 } }]),
      productionHistory: async () => 2,
      clock: c,
      cursorTimeoutMs: 5 * 60_000,
      cursorIntervalMs: 60_000,
    });
    expect(stepNamed(report, "cursor")).toMatchObject({ ok: false });
    expect(stepNamed(report, "cursor")?.detail).toContain("did not move");
    expect(stepNamed(report, "cursor")?.detail).toContain("4");
    expect(report.ok).toBe(false);
  });

  test("a cursor read the server refuses fails the cursor step", async () => {
    const report = await checkPostRelease!({
      client: client(),
      readHealth: async () => stored,
      readCursor: async () => ({ status: 401, body: { error: "unauthorized" } }),
      productionHistory: async () => 2,
      clock: clock(),
    });
    expect(stepNamed(report, "cursor")).toMatchObject({ ok: false });
    expect(stepNamed(report, "cursor")?.detail).toContain("401");
  });
});

describe("post-release check: transient cursor reads", () => {
  test("a retryable 503 or network error mid-wait is read again, not a failure", async () => {
    const report = await checkPostRelease!({
      client: client(),
      readHealth: async () => stored,
      readCursor: cursors([cursor("a"), { status: 503, body: { error: "lookup_failed", retryable: true } }, { status: 0, body: { error: "timeout" } }, cursor("b")]),
      productionHistory: async () => 1,
      clock: clock(),
    });
    expect(stepNamed(report, "cursor")).toMatchObject({ ok: true });
  });

  test("a failed baseline read takes the first good read as the baseline", async () => {
    const report = await checkPostRelease!({
      client: client(),
      readHealth: async () => stored,
      readCursor: cursors([{ status: 503, body: { error: "lookup_failed" } }, cursor("a"), cursor("a"), cursor("b")]),
      productionHistory: async () => 1,
      clock: clock(),
    });
    expect(stepNamed(report, "cursor")).toMatchObject({ ok: true });
  });
});

describe("Production history adapter", () => {
  test("counts the notifications Apple returns for the last day", async () => {
    const historyCount = (nightly as unknown as {
      historyCount?: (api: { getNotificationHistory(token: string | null, request: { startDate: number; endDate: number }): Promise<{ notificationHistory?: unknown[] }> }, nowMs: number) => Promise<number>;
    }).historyCount;
    const seen: { startDate: number; endDate: number }[] = [];
    const at = Date.parse("2026-12-01T09:00:00Z");
    expect(await historyCount!({
      getNotificationHistory: async (_token, request) => {
        seen.push(request);
        return { notificationHistory: [{}, {}] };
      },
    }, at)).toBe(2);
    expect(seen).toEqual([{ startDate: at - 24 * 60 * 60 * 1000, endDate: at }]);
  });
});
