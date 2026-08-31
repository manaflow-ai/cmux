import { describe, expect, test } from "bun:test";

import {
  billingPeriodThrough,
  calculateActiveComputeHours,
} from "../services/vms/usageMath";

const period = {
  start: new Date("2026-08-01T00:00:00.000Z"),
  end: new Date("2026-09-01T00:00:00.000Z"),
};

describe("VM active compute-hour aggregation", () => {
  test("clips current-period reads at now instead of future period end", () => {
    const clipped = billingPeriodThrough(period, new Date("2026-08-15T12:00:00Z"));
    expect(clipped?.start.toISOString()).toBe("2026-08-01T00:00:00.000Z");
    expect(clipped?.end.toISOString()).toBe("2026-08-15T12:00:00.000Z");
    expect(calculateActiveComputeHours([
      event("vm-1", "provisioning", "running", "2026-08-01T00:00:00Z"),
    ], clipped!)).toBe(348);
  });

  test("counts pause and resume cycles independently", () => {
    expect(calculateActiveComputeHours([
      event("vm-1", "provisioning", "running", "2026-08-01T01:00:00Z"),
      event("vm-1", "running", "paused", "2026-08-01T05:00:00Z"),
      event("vm-1", "paused", "running", "2026-08-01T07:30:00Z"),
      event("vm-1", "running", "destroyed", "2026-08-01T09:00:00Z"),
    ], period)).toBe(5.5);
  });

  test("clips a machine that starts before and ends after the period", () => {
    expect(calculateActiveComputeHours([
      event("vm-1", "provisioning", "running", "2026-07-20T12:00:00Z"),
      event("vm-1", "running", "paused", "2026-08-10T00:00:00Z"),
      event("vm-1", "paused", "running", "2026-08-20T00:00:00Z"),
      event("vm-1", "running", "destroyed", "2026-09-10T12:00:00Z"),
    ], period)).toBe(504);
  });

  test("charges a machine still running at period end", () => {
    expect(calculateActiveComputeHours([
      event("vm-1", "provisioning", "running", "2026-08-31T12:00:00Z"),
    ], period)).toBe(12);
  });

  test("sums independent machines and accepts provider state aliases", () => {
    expect(calculateActiveComputeHours([
      event("vm-1", "created", "started", "2026-08-02T00:00:00Z"),
      event("vm-1", "started", "stopped", "2026-08-02T02:00:00Z"),
      event("vm-2", "provisioning", "active", "2026-08-02T01:00:00Z"),
      event("vm-2", "active", "destroyed", "2026-08-02T04:30:00Z"),
    ], period)).toBe(5.5);
  });

  test("uses the recorded source state when a legacy stream starts active", () => {
    expect(calculateActiveComputeHours([
      event("vm-1", "running", "paused", "2026-08-01T02:00:00Z"),
    ], period)).toBe(2);
  });

  test("normalizes state names and Unix-second timestamps", () => {
    expect(calculateActiveComputeHours([
      event("vm-1", "PROVISIONING", "RUNNING", "2026-08-01T01:00:00Z"),
      {
        vmId: "vm-1",
        fromState: "RUNNING",
        toState: "PAUSED",
        createdAt: Math.floor(new Date("2026-08-01T03:00:00Z").getTime() / 1_000),
      },
    ], period)).toBe(2);
  });

  test("accepts Unix-second timestamps encoded in JSON strings", () => {
    expect(calculateActiveComputeHours([
      event("vm-1", "provisioning", "running", "2026-08-01T01:00:00Z"),
      {
        vmId: "vm-1",
        fromState: "running",
        toState: "paused",
        createdAt: String(Math.floor(new Date("2026-08-01T03:00:00Z").getTime() / 1_000)),
      },
    ], period)).toBe(2);
  });

  test("follows a same-timestamp state chain instead of UUID order", () => {
    expect(calculateActiveComputeHours([
      {
        ...event("vm-1", "created", "provisioning", "2026-08-01T01:00:00Z"),
        id: "z-create",
      },
      {
        ...event("vm-1", "provisioning", "running", "2026-08-01T01:00:00Z"),
        id: "a-start",
      },
      event("vm-1", "running", "paused", "2026-08-01T03:00:00Z"),
    ], period)).toBe(2);
  });
});

function event(
  vmId: string,
  fromState: string,
  toState: string,
  createdAt: string,
) {
  return { vmId, fromState, toState, createdAt };
}
