import { Effect } from "effect";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { makeHarness } from "../support/harness.ts";
import type { UsageEvent } from "../../src/metering/recorder.ts";

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

describe("metered usage over the HTTP boundary", () => {
  it("records a real create/pause lifecycle and isolates the tenant", async () => {
    const keyA = await harness.addKey(TENANT_A, ["vm:read", "vm:write"]);
    const keyB = await harness.addKey(TENANT_B, ["vm:read"]);
    const created = await harness.request("/v1/vms", bearer(keyA), { method: "POST", body: {} });
    expect(created.status).toBe(201);
    const body = await created.json();
    if (typeof body !== "object" || body === null || !("id" in body) || typeof body.id !== "string") throw new Error("create did not return a VM id");
    const vmId = body.id;
    expect((await harness.request(`/v1/vms/${vmId}/pause`, bearer(keyA), { method: "POST" })).status).toBe(200);

    const own = await harness.request("/v1/usage?from=2020-01-01T00:00:00Z&to=2090-01-01T00:00:00Z", bearer(keyA));
    expect(own.status).toBe(200);
    const usageBody = await own.json();
    expect(usageBody).toMatchObject({ items: [{ vmId }], total: { vcpuHours: expect.any(Number), storageGibHours: expect.any(Number) } });

    const foreign = await harness.request("/v1/usage?from=2020-01-01T00:00:00Z&to=2090-01-01T00:00:00Z", bearer(keyB));
    expect(foreign.status).toBe(200);
    expect(await foreign.json()).toMatchObject({ items: [], total: { vcpuHours: 0, storageGibHours: 0 } });
  });
});

describe("live ledger reconciliation", () => {
  it("closes compute at a provider pause and opens it again at a provider resume", async () => {
    const vm = harness.addVm(TENANT_A, "running");
    const started = new Date("2026-10-18T00:00:00Z");
    await harness.metering.record({ kind: "vm_started", tenantId: TENANT_A, upstreamVmId: vm.upstreamId, at: started, vcpus: 4, memoryMb: 8192, storageMb: 32768 });
    await harness.metering.reconcile(new Date("2026-10-18T01:00:00Z"), () => Effect.succeed({ kind: "present" as const, vm: { state: "paused", vcpus: 4, memoryMb: 8192, storageMb: 32768 } }));
    expect(harness.metering.intervals).toHaveLength(2);
    expect(harness.metering.intervals[1]?.compute_billed).toBe(false);
    await harness.metering.reconcile(new Date("2026-10-18T02:00:00Z"), () => Effect.succeed({ kind: "present" as const, vm: { state: "running", vcpus: 4, memoryMb: 8192, storageMb: 32768 } }));
    expect(harness.metering.intervals).toHaveLength(3);
    expect(harness.metering.intervals[2]?.compute_billed).toBe(true);
  });

  it("rejects a cmux id at the recorder boundary", async () => {
    await harness.metering.record({ kind: "vm_started", tenantId: TENANT_A, upstreamVmId: "vm_bad", at: new Date(), vcpus: 4, memoryMb: 8192, storageMb: 32768 });
    expect(harness.metering.intervals).toHaveLength(0);
  });
});

export type MeteringEventForTest = UsageEvent;
