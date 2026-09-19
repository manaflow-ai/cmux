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

type ReadStatsOptions = {
  readonly directBackend?: boolean;
  readonly concurrent?: boolean;
  readonly resourceExitCode?: number;
  readonly resourceOutput?: unknown;
};

async function readStats(
  state: string,
  sample: Record<string, unknown> | undefined,
  options: ReadStatsOptions = {},
) {
  const calls: string[] = [];
  const resourceCalls: string[] = [];
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
    findUserVm: () => Effect.succeed({ provider: "freestyle", providerVmId: "vm-stats", billingTeamId: null, ownerTeamId: "user",
      providerMetadata: sample ? { [VM_RESOURCE_USAGE_KEY]: sample } : {} }),
  } as unknown as VmRepositoryShape;
  const providers = {
    getStats: () => Effect.promise(() => provider.getStats("vm-stats")),
    getResourceStats: () => {
      resourceCalls.push("probe");
      return Effect.succeed({
        exitCode: options.resourceExitCode ?? 0,
        stdout: typeof options.resourceOutput === "string"
          ? options.resourceOutput
          : JSON.stringify(options.resourceOutput ?? gauges),
        stderr: "",
      });
    },
  } as unknown as VmProviderGatewayShape;
  const layer = Layer.mergeAll(
    Layer.succeed(VmRepository, repo), Layer.succeed(VmProviderGateway, providers),
    Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
  );
  const envKeys = [
    "CMUX_DEV_RESOURCE_STATS_DIRECT",
    "CMUX_DEV_BACKEND_TRANSPORT",
    "CMUX_DEV_BACKEND_TAILSCALE_HOST",
    "CMUX_WWW_ORIGIN",
  ] as const;
  const previousEnvironment = Object.fromEntries(envKeys.map((key) => [key, process.env[key]]));
  for (const key of envKeys) delete process.env[key];
  if (options.directBackend) {
    process.env.CMUX_DEV_BACKEND_TRANSPORT = "direct";
    process.env.CMUX_DEV_BACKEND_TAILSCALE_HOST = "cmux-dev-backend-1.tail137216.ts.net";
    process.env.CMUX_WWW_ORIGIN = "https://cmux-dev-backend-1.tail137216.ts.net:4635/";
  }
  try {
    const run = () => Effect.runPromise(getVmStats({ userId: "user", providerVmId: "vm-stats" }).pipe(Effect.provide(layer)));
    const results = options.concurrent ? await Promise.all([run(), run()]) : [await run()];
    const result = results[0]!;
    expect(calls).toEqual(options.concurrent
      ? ["/v5/vms/vm-stats", "/v5/vms/vm-stats"]
      : ["/v5/vms/vm-stats"]);
    return { result, results, resourceCalls };
  } finally {
    for (const key of envKeys) {
      const value = previousEnvironment[key];
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
}

describe("Freestyle live machine stats", () => {
  test("existing stats workflow returns the guest sample without executing in the VM", async () => {
    const receivedAt = Date.now();
    const { result, resourceCalls } = await readStats("running", { ...gauges, receivedAt, providerVmId: "vm-stats", diskTotalMb: 1 });
    expect(resourceCalls).toHaveLength(0);
    expect(result).toEqual({ state: "awake", sampledAt: receivedAt, resourceSampledAt: receivedAt, cpus: 2, memoryTotalMb: 4096, diskTotalMb: 16384, ...gauges });
  });

  test("direct dev backends sample an awake guest when callback telemetry is unavailable", async () => {
    const { result, resourceCalls } = await readStats("running", undefined, { directBackend: true });
    expect(resourceCalls).toHaveLength(1);
    expect(result).toMatchObject({ state: "awake", ...gauges });
    expect(typeof result.resourceSampledAt).toBe("number");
  });

  test("coalesces concurrent direct probes for one VM", async () => {
    const { results, resourceCalls } = await readStats("running", undefined, { directBackend: true, concurrent: true });
    expect(resourceCalls).toHaveLength(1);
    expect(results).toHaveLength(2);
    expect(results[0]?.cpuPercent).toBe(gauges.cpuPercent);
    expect(results[1]?.diskUsedMb).toBe(gauges.diskUsedMb);
  });

  test.each([
    { label: "a failed probe", resourceExitCode: 1 },
    { label: "malformed output", resourceOutput: "not json" },
    { label: "invalid gauges", resourceOutput: { cpuPercent: 101 } },
  ])("$label keeps provisioned capacity without inventing usage", async ({ resourceExitCode, resourceOutput }) => {
    const { result, resourceCalls } = await readStats("running", undefined, {
      directBackend: true, resourceExitCode, resourceOutput,
    });
    expect(resourceCalls).toHaveLength(1);
    expect(result).toMatchObject({ state: "awake", cpus: 2, memoryTotalMb: 4096, diskTotalMb: 16384 });
    expect(result.cpuPercent).toBeUndefined();
    expect(result.memoryUsedMb).toBeUndefined();
    expect(result.diskUsedMb).toBeUndefined();
    expect(result.resourceSampledAt).toBeUndefined();
  });

  test.each(["paused", "pausing", "stopped", "starting"])("a %s machine never exposes an old reading or touches the guest", async (state) => {
    const { result, resourceCalls } = await readStats(state, { ...gauges, receivedAt: Date.now(), providerVmId: "vm-stats" }, { directBackend: true });
    expect(resourceCalls).toHaveLength(0);
    expect(result.state).toBe(state === "starting" ? "unknown" : "asleep");
    expect(result.cpuPercent).toBeUndefined();
    expect(result.memoryUsedMb).toBeUndefined();
    expect(result.diskUsedMb).toBeUndefined();
  });

  test.each([undefined, { ...gauges, receivedAt: 0, providerVmId: "vm-stats" },
    { ...gauges, receivedAt: Date.now(), providerVmId: "replaced-vm" }])("missing, stale, and replaced-VM samples remain unavailable", async (sample) => {
    const { result } = await readStats("running", sample);
    expect(result.cpuPercent).toBeUndefined();
    expect(result.diskTotalMb).toBe(16384);
  });

  test("a stale guest sample keeps its timestamp without exposing old gauges", async () => {
    const { result } = await readStats("running", { ...gauges, receivedAt: Date.now() - 90_001, providerVmId: "vm-stats" });
    expect(result.cpuPercent).toBeUndefined();
    expect(result.memoryUsedMb).toBeUndefined();
    expect(result.resourceSampledAt).toBeDefined();
  });

  test("a fresh-to-stale transition clears the previously displayed gauges", () => {
    const previous = { state: "awake" as const, sampledAt: 100_000, resourceSampledAt: 100_000,
      cpuPercent: 37.5, memoryUsedMb: 1234, diskUsedMb: 5678 };
    const stale = applyVmResourceUsage(
      previous,
      { [VM_RESOURCE_USAGE_KEY]: { ...gauges, receivedAt: 100_000, providerVmId: "vm-stats" } },
      "vm-stats",
      190_001,
    );
    expect(stale.cpuPercent).toBeUndefined();
    expect(stale.memoryUsedMb).toBeUndefined();
    expect(stale.diskUsedMb).toBeUndefined();
    expect(stale.resourceSampledAt).toBe(100_000);
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
