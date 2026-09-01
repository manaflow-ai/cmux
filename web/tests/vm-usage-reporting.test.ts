import { describe, expect, mock, test } from "bun:test";

import {
  isStripeUsageReportingEnabled,
  overageComputeHours,
  reportVmUsageForSubscription,
  VM_USAGE_METER_EVENT_NAME,
} from "../services/billing/vmUsageReporting";

describe("VM usage reporting", () => {
  test("requires the explicit rollout flag", () => {
    expect(isStripeUsageReportingEnabled({})).toBe(false);
    expect(isStripeUsageReportingEnabled({ STRIPE_USAGE_REPORTING: "0" })).toBe(false);
    expect(isStripeUsageReportingEnabled({ STRIPE_USAGE_REPORTING: "1" })).toBe(true);
    expect(isStripeUsageReportingEnabled({ STRIPE_USAGE_REPORTING: "true" })).toBe(false);
  });

  test("calculates only hours above the allowance", () => {
    expect(overageComputeHours(19.9)).toBe(0);
    expect(overageComputeHours(22.25)).toBe(2.25);
  });

  test("sends cumulative overage as a meter event", async () => {
    const create = mock(async () => ({}));
    const now = new Date("2026-08-15T12:34:56Z");
    const result = await reportVmUsageForSubscription(subscription(), {
      enabled: true,
      activeHours: 22.25,
      now,
      stripeClient: {
        billing: { meterEvents: { create } },
      },
    });

    expect(result.status).toBe("reported");
    expect(result.overageComputeHours).toBe(2.25);
    // Stripe meter values are whole units. The meter is configured with Last
    // aggregation so each report replaces the cumulative period value.
    const calls = (create as unknown as { mock: { calls: unknown[][] } }).mock.calls;
    expect(calls.length).toBe(1);
    const event = calls[0]?.[0] as {
      event_name: string;
      payload: { stripe_customer_id: string; value: string };
      identifier: string;
      timestamp: number;
    };
    expect(event.event_name).toBe(VM_USAGE_METER_EVENT_NAME);
    expect(event.payload).toEqual({ stripe_customer_id: "cus_usage", value: "3" });
    expect(event.identifier.startsWith("cmux-vm-usage:sub_usage:")).toBe(true);
    expect(event.timestamp).toBe(Math.floor(now.getTime() / 1_000));

    await reportVmUsageForSubscription(subscription(), {
      enabled: true,
      activeHours: 22.25,
      now,
      stripeClient: { billing: { meterEvents: { create } } },
    });
    const repeatCalls = (create as unknown as { mock: { calls: unknown[][] } }).mock.calls;
    const firstCall = repeatCalls[0]?.[0] as { identifier?: string } | undefined;
    const secondCall = repeatCalls[1]?.[0] as { identifier?: string } | undefined;
    expect(secondCall?.identifier).toBe(firstCall?.identifier);
  });

  test("does not call Stripe when reporting is disabled or below allowance", async () => {
    const create = mock(async () => ({}));
    const disabled = await reportVmUsageForSubscription(subscription(), {
      activeHours: 25,
      enabled: false,
      stripeClient: { billing: { meterEvents: { create } } },
    });
    expect(disabled.status).toBe("disabled");

    const noOverage = await reportVmUsageForSubscription(subscription(), {
      activeHours: 20,
      enabled: true,
      stripeClient: { billing: { meterEvents: { create } } },
    });
    expect(noOverage.status).toBe("no_overage");
    expect(create).not.toHaveBeenCalled();
  });

  test("does not apply the Pro allowance to Team subscriptions", async () => {
    const create = mock(async () => ({}));
    const result = await reportVmUsageForSubscription({
      ...subscription(),
      stackTeamId: "team-usage",
      scope: "team",
      plan: "team",
    }, {
      activeHours: 25,
      enabled: true,
      stripeClient: { billing: { meterEvents: { create } } },
    });

    expect(result.status).toBe("unsupported_subscription");
    expect(create).not.toHaveBeenCalled();
  });
});

function subscription() {
  return {
    id: "sub_usage",
    customerId: "cus_usage",
    stackUserId: "user-usage",
    stackTeamId: null,
    scope: "user",
    plan: "pro",
    currentPeriodEnd: new Date("2026-09-01T00:00:00Z"),
    raw: {
      current_period_start: Math.floor(new Date("2026-08-01T00:00:00Z").getTime() / 1_000),
      current_period_end: Math.floor(new Date("2026-09-01T00:00:00Z").getTime() / 1_000),
    },
  };
}
