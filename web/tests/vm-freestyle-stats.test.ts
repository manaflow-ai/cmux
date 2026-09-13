import { describe, expect, test } from "bun:test";
import { Effect, Layer } from "effect";
import { Freestyle } from "freestyle";
import { FreestyleProvider } from "../services/vms/drivers/freestyle";
import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type VmRepositoryShape } from "../services/vms/repository";
import { getVmStats } from "../services/vms/workflows";
import { VM_RESOURCE_USAGE_KEY, applyVmResourceUsage, parseVmResourceUsage } from "../services/vms/resourceUsage";

const gauges = { cpuPercent: 37.5, memoryUsedMb: 1234, diskUsedMb: 5678 };

async function readStats(state: string, sample: Record<string, unknown> | undefined) {
  const calls: string[] = [];
  const client = new Freestyle({
    apiKey: "test-only",
    fetch: (async (input, init) => {
      const path = new URL(String(input)).pathname;
      calls.push(path);
      if (path !== "/v5/vms/vm-stats" || init?.method !== "GET") throw new Error(`Guest touched: ${path}`);
      return Response.json({ state, resources: { cpu: 2, memory: 4096, storage: 16384 } });
    }) as typeof fetch,
  });
  const provider = new FreestyleProvider({ client: () => client, resolveDaemonSource: async () => { throw new Error("Unexpected install"); } });
  const repo = {
    findUserVm: () => Effect.succeed({ provider: "freestyle", providerVmId: "vm-stats", billingTeamId: null,
      providerMetadata: sample ? { [VM_RESOURCE_USAGE_KEY]: sample } : {} }),
  } as unknown as VmRepositoryShape;
  const providers = {
    getStats: () => Effect.promise(() => provider.getStats("vm-stats")),
  } as unknown as VmProviderGatewayShape;
  const layer = Layer.mergeAll(
    Layer.succeed(VmRepository, repo), Layer.succeed(VmProviderGateway, providers),
    Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
  );
  const result = await Effect.runPromise(getVmStats({ userId: "user", providerVmId: "vm-stats" }).pipe(Effect.provide(layer)));
  expect(calls).toEqual(["/v5/vms/vm-stats"]);
  return result;
}

describe("Freestyle live machine stats", () => {
  test("existing stats workflow returns the guest sample without executing in the VM", async () => {
    const receivedAt = Date.now();
    const result = await readStats("running", { ...gauges, receivedAt, providerVmId: "vm-stats", diskTotalMb: 1 });
    expect(result).toEqual({ state: "awake", sampledAt: receivedAt, cpus: 2, memoryTotalMb: 4096, diskTotalMb: 16384, ...gauges });
  });

  test.each(["paused", "pausing", "stopped", "starting"])("a %s machine never exposes an old reading or touches the guest", async (state) => {
    const result = await readStats(state, { ...gauges, receivedAt: Date.now(), providerVmId: "vm-stats" });
    expect(result.state).toBe(state === "starting" ? "unknown" : "asleep");
    expect(result.cpuPercent).toBeUndefined();
    expect(result.memoryUsedMb).toBeUndefined();
    expect(result.diskUsedMb).toBeUndefined();
  });

  test.each([undefined, { ...gauges, receivedAt: 0, providerVmId: "vm-stats" },
    { ...gauges, receivedAt: Date.now(), providerVmId: "replaced-vm" }])("missing, stale, and replaced-VM samples remain unavailable", async (sample) => {
    const result = await readStats("running", sample);
    expect(result.cpuPercent).toBeUndefined();
    expect(result.diskTotalMb).toBe(16384);
  });

  test("freshness boundary uses server time and retains partial zero readings", () => {
    const base = { state: "awake" as const, sampledAt: 100000, diskTotalMb: 16384 };
    const metadata = { [VM_RESOURCE_USAGE_KEY]: { cpuPercent: 0, diskUsedMb: 0, receivedAt: 10000, providerVmId: "vm-stats" } };
    expect(applyVmResourceUsage(base, metadata, "vm-stats", 100000).cpuPercent).toBe(0);
    expect(applyVmResourceUsage(base, metadata, "vm-stats", 100001).cpuPercent).toBeUndefined();
    expect(applyVmResourceUsage(base, metadata, "vm-stats", 9999).cpuPercent).toBeUndefined();
  });

  test.each([null, [], {}, { cpuPercent: NaN }, { cpuPercent: 101 }, { memoryUsedMb: -1 }, { diskUsedMb: "20" }].map((value) => ({ value })))(
    "rejects invalid gauges: %j", ({ value }) => expect(parseVmResourceUsage(value)).toBeNull(),
  );
  test("guest fields cannot overwrite identity, capacity, or server time", () => {
    expect(parseVmResourceUsage({ ...gauges, providerVmId: "other", receivedAt: 1, diskTotalMb: 1 })).toEqual(gauges);
  });
});
