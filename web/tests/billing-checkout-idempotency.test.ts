import { describe, expect, test } from "bun:test";

import {
  CHECKOUT_IDEMPOTENCY_WINDOW_MS,
  checkoutIdempotencyKey,
} from "../services/billing/checkoutIdempotency";

const base = {
  scope: "user" as const,
  subjectId: "user-1",
  plan: "pro",
  interval: "month",
  params: { mode: "subscription", line_items: [{ price: "price_month", quantity: 1 }] },
  now: 10 * CHECKOUT_IDEMPOTENCY_WINDOW_MS + 1,
};

describe("checkoutIdempotencyKey", () => {
  test("is the same for a repeated identical request inside one window", () => {
    expect(checkoutIdempotencyKey(base)).toBe(
      checkoutIdempotencyKey({ ...base, params: structuredClone(base.params), now: base.now + 60_000 }),
    );
  });

  test("differs by subject, scope, plan, interval and window", () => {
    const key = checkoutIdempotencyKey(base);
    for (const other of [
      { subjectId: "user-2" },
      { scope: "team" as const },
      { plan: "max" },
      { interval: "year" },
      { now: base.now + CHECKOUT_IDEMPOTENCY_WINDOW_MS },
    ]) expect(checkoutIdempotencyKey({ ...base, ...other })).not.toBe(key);
  });

  test("differs when the session parameters differ, so Stripe never sees one key with two bodies", () => {
    expect(checkoutIdempotencyKey({ ...base, params: { ...base.params, cancel_url: "https://cmux.test/x" } }))
      .not.toBe(checkoutIdempotencyKey(base));
  });

  test("fits Stripe's 255-character key limit", () => {
    expect(checkoutIdempotencyKey({ ...base, subjectId: "u".repeat(64), plan: "p".repeat(32) }).length)
      .toBeLessThanOrEqual(255);
  });
});
