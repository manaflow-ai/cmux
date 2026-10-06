import { describe, expect, test } from "bun:test";

import { planStanding } from "../dashboard-app/screens/billing/plan-status";
import {
  stripeAccessEndsAt,
  stripeCancelScheduled,
  stripeResumeParams,
  storedSubscriptionCancellation,
} from "../services/billing/cancellation";

const CANCEL_AT = 1_793_625_720; // 2026-11-02T13:22:00Z
const PERIOD_END = new Date("2026-12-01T00:00:00Z");

describe("Stripe cancellation fields", () => {
  test("a Billing Portal cancel sets only cancel_at, which ends access on that date", () => {
    const portal = { cancel_at_period_end: false, cancel_at: CANCEL_AT };
    expect(stripeCancelScheduled(portal)).toBe(true);
    expect(stripeAccessEndsAt(portal, PERIOD_END)?.toISOString()).toBe("2026-11-02T13:22:00.000Z");
    expect(stripeResumeParams(portal)).toEqual({ cancel_at: "" });
  });

  test("a period-end cancel ends at the current period end", () => {
    const periodEnd = { cancel_at_period_end: true, cancel_at: null };
    expect(stripeCancelScheduled(periodEnd)).toBe(true);
    expect(stripeAccessEndsAt(periodEnd, PERIOD_END)).toBe(PERIOD_END);
    expect(stripeResumeParams(periodEnd)).toEqual({ cancel_at_period_end: false });
  });

  test("a renewing subscription has no end date", () => {
    const renewing = { cancel_at_period_end: false, cancel_at: null };
    expect(stripeCancelScheduled(renewing)).toBe(false);
    expect(stripeAccessEndsAt(renewing, PERIOD_END)).toBeNull();
    expect(stripeCancelScheduled(null)).toBe(false);
    expect(stripeCancelScheduled({ cancel_at: "soon" })).toBe(false);
  });

  test("a stored row counts raw.cancel_at even when the column predates it", () => {
    expect(storedSubscriptionCancellation({
      cancelAtPeriodEnd: false,
      currentPeriodEnd: PERIOD_END,
      raw: { cancel_at_period_end: false, cancel_at: CANCEL_AT },
    })).toEqual({ cancelScheduled: true, endsAt: new Date(CANCEL_AT * 1000) });
    expect(storedSubscriptionCancellation({ cancelAtPeriodEnd: true, currentPeriodEnd: PERIOD_END, raw: {} }))
      .toEqual({ cancelScheduled: true, endsAt: PERIOD_END });
    expect(storedSubscriptionCancellation({ cancelAtPeriodEnd: false, currentPeriodEnd: PERIOD_END, raw: {} }))
      .toEqual({ cancelScheduled: false, endsAt: null });
  });
});

describe("plan standing", () => {
  const paid = { isPro: true, cancelScheduled: false, endsAt: null, paymentPastDue: false };

  test("covers free, active, cancelled-but-active and past due", () => {
    expect(planStanding({ ...paid, isPro: false })).toEqual({ kind: "free" });
    expect(planStanding(paid)).toEqual({ kind: "active" });
    expect(planStanding({ ...paid, endsAt: "2026-11-02T13:22:00.000Z" }))
      .toEqual({ kind: "cancelling", endsAt: "2026-11-02T13:22:00.000Z" });
    expect(planStanding({ ...paid, cancelScheduled: true })).toEqual({ kind: "cancelling", endsAt: null });
    expect(planStanding({ ...paid, paymentPastDue: true })).toEqual({ kind: "pastDue" });
  });

  test("a failed payment outranks a scheduled cancel", () => {
    expect(planStanding({ ...paid, cancelScheduled: true, paymentPastDue: true })).toEqual({ kind: "pastDue" });
  });
});
