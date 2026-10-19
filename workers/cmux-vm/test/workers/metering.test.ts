import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { Effect } from "effect";
import { makeHarness } from "../support/harness.ts";

const TENANT_A = "team_alpha";
const TENANT_B = "team_bravo";
const bearer = (secret: string) => ({ authorization: `Bearer ${secret}` });

let harness: Awaited<ReturnType<typeof makeHarness>>;
beforeEach(async () => {
  harness = await makeHarness({ meteringMarkupBps: 1_000 });
});
afterEach(async () => {
  await harness.dispose();
});

describe("metered usage HTTP boundary", () => {
  it("reports compute and storage with markup and keeps tenants isolated", async () => {
    const vm = harness.addVm(TENANT_A);
    const keyA = await harness.addKey(TENANT_A, ["vm:read"]);
    const keyB = await harness.addKey(TENANT_B, ["vm:read"]);
    const started = new Date("2026-10-18T00:00:00Z");
    const stopped = new Date("2026-10-18T01:00:00Z");
    harness.metering.record({ kind: "vm_started", tenantId: TENANT_A, upstreamVmId: vm.upstreamId, at: started, vcpus: 4, memoryMb: 8192, storageMb: 32768 });
    harness.metering.record({ kind: "vm_stopped", tenantId: TENANT_A, upstreamVmId: vm.upstreamId, at: stopped, reason: "pause" });

    const own = await harness.request(`/v1/usage?from=${started.toISOString()}&to=2026-10-18T02:00:00Z`, bearer(keyA));
    expect(own.status).toBe(200);
    const body = await own.json();
    expect(body).toMatchObject({
      items: [{ vmId: vm.vmId, vcpuHours: 4, memoryGibHours: 8, storageGibHours: 64 }],
      total: { vcpuHours: 4, memoryGibHours: 8, storageGibHours: 64 },
    });
    expect(body).toMatchObject({ total: { listCostMicrodollars: 269_984, markedUpCostMicrodollars: 296_982 } });

    const foreign = await harness.request(`/v1/usage?from=${started.toISOString()}&to=2026-10-18T02:00:00Z`, bearer(keyB));
    expect(foreign.status).toBe(200);
    expect(await foreign.json()).toMatchObject({ items: [], total: { vcpuHours: 0, storageGibHours: 0 } });
  });
});

describe("scheduled reconciliation boundary", () => {
  it("switches compute to storage when the provider pauses and back when it runs", async () => {
    const vm = harness.addVm(TENANT_A, "paused");
    const started = new Date("2026-10-18T00:00:00Z");
    harness.metering.record({ kind: "vm_started", tenantId: TENANT_A, upstreamVmId: vm.upstreamId, at: started, vcpus: 4, memoryMb: 8192, storageMb: 32768 });
    await Effect.runPromise(harness.metering.reconcile(new Date("2026-10-18T01:00:00Z"), () =>
      Effect.succeed({ kind: "present" as const, vm: { state: "paused", vcpus: 4, memoryMb: 8192, storageMb: 32768 } }),
    ));
    expect(harness.metering.intervals).toHaveLength(2);
    expect(harness.metering.intervals[1]?.computeBilled).toBe(false);

    await Effect.runPromise(harness.metering.reconcile(new Date("2026-10-18T02:00:00Z"), () =>
      Effect.succeed({ kind: "present" as const, vm: { state: "running", vcpus: 4, memoryMb: 8192, storageMb: 32768 } }),
    ));
    expect(harness.metering.intervals).toHaveLength(3);
    expect(harness.metering.intervals[2]?.computeBilled).toBe(true);
  });
});
