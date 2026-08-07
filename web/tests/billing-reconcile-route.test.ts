import { afterEach, describe, expect, mock, test } from "bun:test";

let reconcileError: Error | null = null;
const reconcileStripeSubscriptions = mock(async () => {
  if (reconcileError) throw reconcileError;
  return {
    checked: 2,
    drifted: 1,
    repaired: 1,
    failed: 0,
    truncated: false,
  };
});
const captureCoderouterError = mock(() => {});

mock.module("../services/billing/reconcile", () => ({
  reconcileStripeSubscriptions,
}));
mock.module("../services/errors", () => ({ captureCoderouterError }));

const { GET } = await import("../app/api/cron/billing-reconcile/route");
const originalSecret = process.env.CRON_SECRET;

afterEach(() => {
  reconcileStripeSubscriptions.mockClear();
  reconcileError = null;
  captureCoderouterError.mockClear();
  if (originalSecret === undefined) delete process.env.CRON_SECRET;
  else process.env.CRON_SECRET = originalSecret;
});

describe("billing reconciliation cron", () => {
  test("fails closed without configured bearer authentication", async () => {
    delete process.env.CRON_SECRET;
    expect((await GET(new Request("https://cmux.test/api/cron/billing-reconcile"))).status)
      .toBe(401);
    expect(reconcileStripeSubscriptions).not.toHaveBeenCalled();
  });

  test("runs reconciliation with a valid cron secret", async () => {
    process.env.CRON_SECRET = "expected";
    const response = await GET(new Request(
      "https://cmux.test/api/cron/billing-reconcile",
      { headers: { authorization: "Bearer expected" } },
    ));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      ok: true,
      checked: 2,
      drifted: 1,
      repaired: 1,
      failed: 0,
      truncated: false,
    });
  });

  test("returns retry guidance when reconciliation cannot start", async () => {
    process.env.CRON_SECRET = "expected";
    reconcileError = new Error("database unavailable");
    const response = await GET(new Request(
      "https://cmux.test/api/cron/billing-reconcile",
      { headers: { authorization: "Bearer expected" } },
    ));
    expect(response.status).toBe(503);
    expect(response.headers.get("retry-after")).toBe("60");
    expect(await response.json()).toEqual({
      error: "billing_reconcile_failed",
      message: "Billing reconciliation failed; retry the cron run.",
      retryable: true,
    });
    expect(captureCoderouterError).toHaveBeenCalledTimes(1);
  });
});
