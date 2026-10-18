import { describe, expect, test } from "bun:test";
import { createHostLeaseAdapters } from "./host-lease-adapters";

function env(overrides: Record<string, string | undefined> = {}) {
  return {
    HUGE_BLUE_HOST_LEASE_URL: "https://huge-blue.example",
    HUGE_BLUE_HOST_LEASE_TOKEN: "huge-token",
    HUGE_BLUE_HOST_ID: "huge-blue:01",
    FREESTYLE_HOST_LEASE_URL: "https://freestyle.example",
    FREESTYLE_HOST_LEASE_TOKEN: "freestyle-token",
    FREESTYLE_HOST_ID: "freestyle:01",
    ...overrides,
  };
}

function input(hostClass: string, operation = "acquire") {
  return {
    protocolVersion: 1 as const,
    jobId: "job-1",
    tenantId: "tenant-1",
    owner: "worker-1",
    hostClass,
    effectKey: "lease-effect-1",
    attempt: 1,
    leaseGeneration: 1,
    payload: { operation, leaseId: "lease-1", generation: 1, ttlMs: 10_000 },
  };
}

describe("independently deployed host lease adapters", () => {
  test("registers real Huge Blue and Freestyle gateway adapters only when configured", async () => {
    const requests: Array<{ url: string; authorization: string; body: Record<string, unknown> }> = [];
    const fetcher: typeof fetch = async (url, init) => {
      requests.push({
        url: String(url),
        authorization: String(new Headers(init?.headers).get("authorization")),
        body: JSON.parse(String(init?.body)) as Record<string, unknown>,
      });
      return new Response(JSON.stringify({ leaseId: "provider-lease", expiresAtMs: 20_000, generation: 1, metadata: { safe: true, secret: "drop" } }), { status: 200 });
    };
    const adapters = createHostLeaseAdapters({ env: env(), fetch: fetcher });
    expect(adapters.map((adapter) => adapter.hostClass)).toEqual(["huge-blue", "freestyle", "freestyle-vm"]);
    const hugeResult = await adapters[0]!.execute(input("huge-blue"));
    const freestyleResult = await adapters[1]!.execute(input("freestyle"));
    expect(hugeResult).toMatchObject({ provider: "huge-blue", providerLeaseId: "provider-lease", metadata: { safe: true } });
    expect(hugeResult).not.toHaveProperty("secret");
    expect(freestyleResult).toMatchObject({ provider: "freestyle" });
    expect(requests).toEqual([
      { url: "https://huge-blue.example/v1/hosts/huge-blue%3A01/leases/acquire", authorization: "Bearer huge-token", body: { leaseId: "lease-1", ownerId: "worker-1", generation: 1, ttlMs: 10_000, effectKey: "lease-effect-1" } },
      { url: "https://freestyle.example/v1/hosts/freestyle%3A01/leases/acquire", authorization: "Bearer freestyle-token", body: { leaseId: "lease-1", ownerId: "worker-1", generation: 1, ttlMs: 10_000, effectKey: "lease-effect-1" } },
    ]);
  });

  test("fails closed when a provider secret or gateway is missing", () => {
    expect(createHostLeaseAdapters({ env: env({ FREESTYLE_HOST_LEASE_TOKEN: undefined }) }).map((adapter) => adapter.hostClass)).toEqual(["huge-blue"]);
    expect(createHostLeaseAdapters({ env: {} })).toEqual([]);
  });

  test("rejects non-lease payloads before provider I/O", async () => {
    let calls = 0;
    const adapters = createHostLeaseAdapters({
      env: env(),
      fetch: async () => { calls += 1; return new Response("{}", { status: 200 }); },
    });
    await expect(adapters[0]!.execute({ ...input("huge-blue"), payload: { operation: "workspace.create" } })).rejects.toThrow("operation");
    expect(calls).toBe(0);
  });
});
