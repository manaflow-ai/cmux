// The bill can be checked against the usage: each line's amount in its quoted unit times the list rate the
// server sends is the server's dollars for it (RFD 0163 row 27: show the dollar and the rate, never a credit).
import { describe, expect, test } from "bun:test";
import type { CloudUsage } from "./ops";
import { meterAmount, monthTotal, ratePrice, type UsageMeter } from "./usage";

const usage: CloudUsage = {
  period: "2026-11",
  as_of: Date.UTC(2026, 10, 24, 8, 20),
  metered_since: Date.UTC(2026, 10, 1),
  vcpu_seconds: 412.6 * 3600,
  memory_gib_seconds: 1650.4 * 3600,
  stored_gib_seconds: 12.5 * 730 * 3600,
  usd: { vcpu: 18.567, memory: 23.9308, stored: 1.25, total: 43.7478 },
  rates: { vcpu_hour_usd: 0.045, memory_gib_hour_usd: 0.0145, stored_gib_month_usd: 0.1 },
  gaps: [],
  payment_method: { attached: false },
  stripe_mode: "test",
};
const METERS: UsageMeter[] = ["vcpu", "memory", "stored"];

describe("usage lines", () => {
  test("each line's amount times its rate is the server's dollars for it, to the cent", () => {
    let sum = 0;
    for (const meter of METERS) {
      const { amount, usd, rate } = meterAmount(usage, meter);
      expect(rate).toBeDefined();
      expect(Math.abs(amount * (rate ?? Number.NaN) - usd)).toBeLessThan(0.005);
      sum += usd;
    }
    expect(Math.abs(sum - monthTotal(usage))).toBeLessThan(0.005);
  });

  test("stored is per GiB-month over a 730-hour month", () => {
    const { amount, rate } = meterAmount(usage, "stored");
    expect(amount).toBeCloseTo(12.5, 6);
    expect(rate).toBe(0.1);
  });

  test("a server with no rates gives none, and a line still has its amount and dollars", () => {
    const { rates: _rates, ...unrated } = usage;
    const line = meterAmount(unrated, "vcpu");
    expect(line.rate).toBeUndefined();
    expect(line.amount).toBeCloseTo(412.6, 6);
    expect(line.usd).toBe(18.567);
  });

  test("a rate that is not a finite, non-negative number is not shown", () => {
    const odd = {
      ...usage,
      rates: { vcpu_hour_usd: "NaN" as const, memory_gib_hour_usd: -1, stored_gib_month_usd: 0.1 },
    };
    expect(meterAmount(odd, "vcpu").rate).toBeUndefined();
    expect(meterAmount(odd, "memory").rate).toBeUndefined();
  });

  test("a rate keeps the decimals it needs, two to four", () => {
    expect(ratePrice(0.1, "en")).toBe("$0.10");
    expect(ratePrice(0.045, "en")).toBe("$0.045");
    expect(ratePrice(0.0145, "en")).toBe("$0.0145");
  });
});
