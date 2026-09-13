import { describe, expect, test } from "bun:test";
import { Freestyle } from "freestyle";
import { FreestyleProvider } from "../services/vms/drivers/freestyle";

function fixture(options: {
  states?: string[];
  output?: string;
  exitCode?: number | null;
  execStatus?: number;
} = {}) {
  const calls: { path: string; body: Record<string, unknown> | null }[] = [];
  let reads = 0;
  const client = new Freestyle({
    apiKey: "test-only",
    fetch: (async (input, init) => {
      const path = new URL(String(input)).pathname;
      const body = init?.body ? JSON.parse(String(init.body)) : null;
      calls.push({ path, body });
      if (path === "/v5/vms/vm-stats" && init?.method === "GET") {
        const states = options.states ?? ["running"];
        return Response.json({
          state: states[Math.min(reads++, states.length - 1)],
          resources: { cpu: 2, memory: 4096, storage: 16384 },
        });
      }
      if (path === "/v5/vms/vm-stats/exec-await") {
        if (options.execStatus) {
          return Response.json({ code: "CONFLICT", message: "VM is not running" }, { status: options.execStatus });
        }
        return Response.json({
          statusCode: options.exitCode === undefined ? 0 : options.exitCode,
          stdout: options.output ?? JSON.stringify({ cpuPercent: 37.5, memoryUsedMb: 1234, diskUsedMb: 5678 }),
        });
      }
      throw new Error(`Unexpected provider request: ${path}`);
    }) as typeof fetch,
  });
  const provider = new FreestyleProvider({
    client: () => client,
    resolveDaemonSource: async () => { throw new Error("Stats must not install a daemon"); },
  });
  return { provider, calls };
}

describe("Freestyle live machine stats", () => {
  test("returns sampled usage with the provider's provisioned dimensions", async () => {
    const { provider, calls } = fixture();
    expect(await provider.getStats("vm-stats")).toMatchObject({
      state: "awake", cpus: 2, cpuPercent: 37.5,
      memoryTotalMb: 4096, memoryUsedMb: 1234,
      diskTotalMb: 16384, diskUsedMb: 5678,
    });
    expect(calls.map((call) => call.path)).toEqual(["/v5/vms/vm-stats", "/v5/vms/vm-stats/exec-await"]);
    expect(calls[1].body?.timeoutMs).toBeLessThanOrEqual(5000);
  });

  test.each(["paused", "pausing", "stopped", "starting"])("does not touch a %s guest", async (state) => {
    const { provider, calls } = fixture({ states: [state] });
    const stats = await provider.getStats("vm-stats");
    expect(stats.state).toBe(state === "starting" ? "unknown" : "asleep");
    expect(stats.cpuPercent).toBeUndefined();
    expect(stats.memoryUsedMb).toBeUndefined();
    expect(stats.diskUsedMb).toBeUndefined();
    expect(calls).toHaveLength(1);
  });

  test("a concurrent pause rechecks state without retrying or resuming", async () => {
    const { provider, calls } = fixture({ states: ["running", "paused"], execStatus: 409 });
    const stats = await provider.getStats("vm-stats");
    expect(stats.state).toBe("asleep");
    expect(stats.cpuPercent).toBeUndefined();
    expect(calls.map((call) => call.path)).toEqual([
      "/v5/vms/vm-stats", "/v5/vms/vm-stats/exec-await", "/v5/vms/vm-stats",
    ]);
  });

  test.each(["not json", "null", "[]", '{"cpuPercent":101,"memoryUsedMb":-1,"diskUsedMb":"20"}'])(
    "invalid readings remain unavailable: %s", async (output) => {
      const { provider } = fixture({ output });
      const stats = await provider.getStats("vm-stats");
      expect(stats.cpuPercent).toBeUndefined();
      expect(stats.memoryUsedMb).toBeUndefined();
      expect(stats.diskUsedMb).toBeUndefined();
      expect(stats.diskTotalMb).toBe(16384);
    },
  );

  test.each([127, null])("a failed or timed-out probe does not invent idle readings (%s)", async (exitCode) => {
    const { provider } = fixture({ exitCode });
    const stats = await provider.getStats("vm-stats");
    expect(stats.cpuPercent).toBeUndefined();
    expect(stats.memoryUsedMb).toBeUndefined();
    expect(stats.diskUsedMb).toBeUndefined();
  });

  test("partial readings preserve zero and discard unrelated guest fields", async () => {
    const { provider } = fixture({ output: '{"cpuPercent":0,"diskUsedMb":0,"diskTotalMb":1,"state":"asleep"}' });
    expect(await provider.getStats("vm-stats")).toMatchObject({
      state: "awake", cpuPercent: 0, diskUsedMb: 0, diskTotalMb: 16384,
    });
  });
});
