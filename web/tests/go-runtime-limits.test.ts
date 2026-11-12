import { describe, expect, test } from "bun:test";
import { runtimeSecondsWithinPeriod, subscriptionPeriodStart, goCapacityConstraint } from "../services/vms/goUsage";

const start = new Date("2026-09-11T18:00:00Z");
const end = new Date("2026-10-11T18:00:00Z");
describe("Go runtime accounting", () => {
  test("counts stopped and still-running intervals without charging paused time", () => {
    expect(runtimeSecondsWithinPeriod([
      { startedAt: start, endedAt: new Date("2026-09-11T19:00:00Z") },
      { startedAt: new Date("2026-09-12T18:00:00Z"), endedAt: null },
    ], start, end, new Date("2026-09-12T20:00:00Z"))).toBe(3 * 3600);
  });
  test("clips a running machine to the Stripe renewal boundary", () => {
    expect(runtimeSecondsWithinPeriod([
      { startedAt: new Date("2026-09-10T18:00:00Z"), endedAt: new Date("2026-09-11T20:00:00Z") },
    ], start, end, new Date("2026-09-12T20:00:00Z"))).toBe(2 * 3600);
  });
  test("never counts outside the period or into the future", () => {
    expect(runtimeSecondsWithinPeriod([
      { startedAt: new Date("2026-09-10T18:00:00Z"), endedAt: new Date("2026-09-10T20:00:00Z") },
      { startedAt: new Date("2026-10-11T17:00:00Z"), endedAt: null },
    ], start, end, new Date("2026-10-12T20:00:00Z"))).toBe(3600);
  });
  test("reads item-level and legacy Stripe periods and rejects missing state", () => {
    const seconds = start.getTime() / 1000;
    expect(subscriptionPeriodStart({ items: { data: [{ current_period_start: seconds }] } })).toEqual(start);
    expect(subscriptionPeriodStart({ current_period_start: seconds })).toEqual(start);
    expect(subscriptionPeriodStart({})).toBeNull();
  });
  test("turns nested PostgreSQL quota failures into the specific upgrade guidance", () => {
    expect(goCapacityConstraint({ cause: { constraint_name: "cmux_go_saved_limit" } })).toBe("saved");
    expect(goCapacityConstraint({ cause: { constraint: "cmux_go_hours_limit" } })).toBe("hours");
    expect(goCapacityConstraint({ constraint: "unrelated_check" })).toBeNull();
  });
});
