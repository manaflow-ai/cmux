import { describe, expect, test } from "bun:test";
import { PgDialect } from "drizzle-orm/pg-core";
import type { SQL } from "drizzle-orm";

import { cloudVmRuntimeIntervals, cloudVms, vmProvider } from "../db/schema";
import { FREESTYLE_COST_USD, sandboxHourUsd } from "../services/billing/chiefPricing";
import { readVmRunningSince, vmCostFields, vmHourlyRateUsd } from "../services/vms/machineCost";

/**
 * The Cloud machine cost line (rate, running time, estimate) reads two server
 * facts per machine. These pin where they come from: the rate from the shared
 * provider rate table, the start from the open runtime interval.
 */

type RunningSinceDb = NonNullable<NonNullable<Parameters<typeof readVmRunningSince>[1]>["db"]>;

type Captured = { calls: number; table?: unknown; joined?: unknown; where?: SQL };

function fakeDb(rows: readonly { providerVmId: string | null; startedAt: Date }[], captured: Captured) {
  return {
    select: () => {
      captured.calls += 1;
      return {
        from: (table: unknown) => {
          captured.table = table;
          return {
            innerJoin: (joined: unknown) => {
              captured.joined = joined;
              return {
                where: (condition: SQL) => {
                  captured.where = condition;
                  return Promise.resolve([...rows]);
                },
              };
            },
          };
        },
      };
    },
  } as unknown as RunningSinceDb;
}

describe("cloud machine hourly rate", () => {
  test("a 4 vCPU / 8 GB Freestyle machine is about $0.26 an hour", () => {
    const rate = vmHourlyRateUsd("freestyle", { vcpus: 4, memoryMb: 8192 });
    expect(rate).toBe(0.2645);
    expect(rate?.toFixed(2)).toBe("0.26");
  });

  test("the rate is the shared Freestyle rate table, not a second copy", () => {
    const expected = sandboxHourUsd({ vcpu: 8, gib: 16 }, FREESTYLE_COST_USD);
    expect(vmHourlyRateUsd("freestyle", { vcpus: 8, memoryMb: 16384 })).toBeCloseTo(expected, 4);
  });

  test("a GCP machine gets an approximate shape rate", () => {
    expect(vmHourlyRateUsd("gcp", { vcpus: 2, memoryMb: 8192 })).toBe(0.103);
  });

  test("an unknown shape or provider has no rate", () => {
    expect(vmHourlyRateUsd("freestyle", null)).toBeNull();
    expect(vmHourlyRateUsd("freestyle", { vcpus: 0, memoryMb: 8192 })).toBeNull();
    expect(vmHourlyRateUsd("other", { vcpus: 4, memoryMb: 8192 })).toBeNull();
  });
});

describe("cloud machine cost fields", () => {
  const shape = { vcpus: 4, memoryMb: 8192 };
  const started = new Date("2026-10-21T10:00:00Z");

  test("a running machine carries its rate and start", () => {
    expect(vmCostFields({ provider: "freestyle", status: "running", resourceReservation: shape }, started))
      .toEqual({ hourlyRateUsd: 0.2645, runningSince: started.getTime() });
  });

  test("a paused machine keeps its rate but has no running start", () => {
    expect(vmCostFields({ provider: "freestyle", status: "paused", resourceReservation: shape }, started))
      .toEqual({ hourlyRateUsd: 0.2645, runningSince: null });
  });

  test("a live machine whose start did not load has no running start", () => {
    expect(vmCostFields({ provider: "freestyle", status: "running", resourceReservation: shape }, undefined).runningSince)
      .toBeNull();
  });
});

describe("readVmRunningSince", () => {
  test("reads only open intervals and keys them by provider VM id", async () => {
    const captured: Captured = { calls: 0 };
    const since = await readVmRunningSince(["vm-a", "vm-b", "vm-a"], {
      db: fakeDb([{ providerVmId: "vm-a", startedAt: new Date(1_000) }, { providerVmId: null, startedAt: new Date(2_000) }], captured),
    });
    expect([...since.entries()]).toEqual([["vm-a", new Date(1_000)]]);
    expect(captured.table).toBe(cloudVmRuntimeIntervals);
    expect(captured.joined).toBe(cloudVms);
    const where = new PgDialect().sqlToQuery(captured.where!);
    expect(where.sql).toContain(`"cloud_vm_runtime_intervals"."ended_at" is null`);
    expect(where.sql).toContain(`"cloud_vms"."provider" in`);
    expect(where.sql).toContain(`"cloud_vms"."provider_vm_id" in`);
    expect(where.params).toEqual([...vmProvider.enumValues, "vm-a", "vm-b"]);
  });

  test("no ids means no query", async () => {
    const captured: Captured = { calls: 0 };
    expect((await readVmRunningSince([" "], { db: fakeDb([], captured) })).size).toBe(0);
    expect(captured.calls).toBe(0);
  });

  test("a failed read answers empty and reports", async () => {
    const errors: unknown[] = [];
    const since = await readVmRunningSince(["vm-a"], {
      db: { select: () => { throw new Error("db down"); } } as unknown as RunningSinceDb,
      onFailure: (error) => errors.push(error),
    });
    expect(since.size).toBe(0);
    expect(errors).toHaveLength(1);
  });

  test("a stalled read answers empty at the deadline", async () => {
    const stalled = {
      select: () => ({ from: () => ({ innerJoin: () => ({ where: () => new Promise(() => {}) }) }) }),
    } as unknown as RunningSinceDb;
    const errors: unknown[] = [];
    const since = await readVmRunningSince(["vm-a"], { db: stalled, timeoutMs: 20, onFailure: (e) => errors.push(e) });
    expect(since.size).toBe(0);
    expect(errors).toHaveLength(1);
  });
});
