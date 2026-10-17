import { describe, expect, test } from "bun:test";
import {
  FreestyleHostLeaseAdapter,
  createHugeBlueHostLeaseHttpClient,
  HugeBlueHostLeaseAdapter,
  MemoryVmHostLeaseStore,
  RegisteredHostLeaseAdapter,
  VmHostLeaseError,
  VmHostLeaseTransport,
  type VmHostLeaseProvider,
  type VmHostLeaseProviderClient,
} from "../services/vms/hostLeaseTransport";

const PROVIDERS: readonly VmHostLeaseProvider[] = ["huge-blue", "freestyle"];

type FakeClient = VmHostLeaseProviderClient & { readonly calls: string[] };

function fakeClient(): FakeClient {
  const calls: string[] = [];
  return {
    calls,
    async acquire(input) {
      calls.push(`acquire:${input.effectKey}`);
      return { providerLeaseId: `${input.provider}-lease`, expiresAtMs: input.nowMs + input.ttlMs, generation: input.generation };
    },
    async renew(input) {
      calls.push(`renew:${input.effectKey}`);
      return { providerLeaseId: `${input.provider}-lease`, expiresAtMs: input.nowMs + input.ttlMs, generation: input.generation };
    },
    async release(input) {
      calls.push(`release:${input.effectKey}`);
      return { providerLeaseId: `${input.provider}-lease`, expiresAtMs: input.nowMs, generation: input.generation };
    },
  };
}

function transportFor(provider: VmHostLeaseProvider, client: FakeClient): VmHostLeaseTransport {
  const adapter = provider === "huge-blue" ? new HugeBlueHostLeaseAdapter(client) : new FreestyleHostLeaseAdapter(client);
  return new VmHostLeaseTransport(new MemoryVmHostLeaseStore(), new Map([[provider, adapter]]));
}

describe("VM host lease transport", () => {
  test.each(PROVIDERS)("normalizes acquire/renew/release for %s", async (provider) => {
    const client = fakeClient();
    const transport = transportFor(provider, client);
    const base = { provider, leaseId: "lease-1", hostId: `${provider}:host-1`, ownerId: "worker-1", generation: 1, ttlMs: 1_000 } as const;

    const acquired = await transport.acquire({ ...base, effectKey: "effect-acquire", nowMs: 0 });
    expect(acquired).toMatchObject({ provider, operation: "acquire", state: "active", generation: 1, expiresAtMs: 1_000, replayed: false });
    expect(acquired.providerLeaseId).toBe(`${provider}-lease`);

    const renewed = await transport.renew({ ...base, effectKey: "effect-renew", nowMs: 500 });
    expect(renewed).toMatchObject({ provider, operation: "renew", state: "active", generation: 1, expiresAtMs: 1_500, replayed: false });

    const released = await transport.release({ ...base, effectKey: "effect-release", nowMs: 700 });
    expect(released).toMatchObject({ provider, operation: "release", state: "released", generation: 1, expiresAtMs: 700, replayed: false });
    expect(client.calls).toEqual(["acquire:effect-acquire", "renew:effect-renew", "release:effect-release"]);
  });

  test.each(PROVIDERS)("deduplicates a completed effect for %s", async (provider) => {
    const client = fakeClient();
    const transport = transportFor(provider, client);
    const input = { provider, leaseId: "lease-2", hostId: `${provider}:host-2`, ownerId: "worker-2", generation: 1, ttlMs: 1_000, effectKey: "same-effect", nowMs: 10 } as const;
    const first = await transport.acquire(input);
    const replay = await transport.acquire({ ...input, nowMs: 999 });
    expect(replay.replayed).toBe(true);
    expect(replay).toMatchObject({ expiresAtMs: 1_010, generation: 1, effectKey: "same-effect" });
    expect(first).toEqual({ ...replay, replayed: false });
    expect(client.calls).toEqual(["acquire:same-effect"]);
  });

  test.each(PROVIDERS)("rejects stale generations and permits expiry/reacquire for %s", async (provider) => {
    const client = fakeClient();
    const transport = transportFor(provider, client);
    const base = { provider, leaseId: "lease-3", hostId: `${provider}:host-3`, ownerId: "worker-3", ttlMs: 1_000 } as const;
    await transport.acquire({ ...base, generation: 1, effectKey: "g1", nowMs: 0 });

    await expect(transport.renew({ ...base, generation: 2, effectKey: "stale-renew", nowMs: 100 })).rejects.toMatchObject({ code: "stale_generation" });
    await expect(transport.acquire({ ...base, generation: 1, effectKey: "active-reacquire", nowMs: 100 })).rejects.toMatchObject({ code: "lease_conflict" });

    const reacquired = await transport.acquire({ ...base, generation: 2, effectKey: "g2", nowMs: 1_000 });
    expect(reacquired).toMatchObject({ operation: "acquire", generation: 2, state: "active", expiresAtMs: 2_000 });
    expect(client.calls).toEqual(["acquire:g1", "acquire:g2"]);
  });

  test.each(PROVIDERS)("rejects a different owner from renewing or reacquiring %s", async (provider) => {
    const client = fakeClient();
    const transport = transportFor(provider, client);
    const base = { provider, leaseId: "lease-owner", hostId: `${provider}:host-owner`, ownerId: "worker-owner", generation: 1, ttlMs: 1_000 } as const;
    await transport.acquire({ ...base, effectKey: "owner-acquire", nowMs: 0 });
    await expect(transport.renew({ ...base, ownerId: "other-worker", effectKey: "owner-renew", nowMs: 100 })).rejects.toMatchObject({ code: "owner_mismatch" });
    await expect(transport.acquire({ ...base, ownerId: "other-worker", generation: 2, effectKey: "owner-reacquire", nowMs: 1_000 })).rejects.toMatchObject({ code: "owner_mismatch" });
    expect(client.calls).toEqual(["acquire:owner-acquire"]);
  });

  test("uses the same semantics for a newly registered host class", async () => {
    const client = fakeClient();
    const adapter = new RegisteredHostLeaseAdapter("mac-mini", client);
    const transport = new VmHostLeaseTransport(new MemoryVmHostLeaseStore(), new Map([["mac-mini", adapter]]));
    const input = { provider: "mac-mini", leaseId: "lease-custom", hostId: "mac-mini:host-1", ownerId: "worker", generation: 1, effectKey: "custom-acquire", ttlMs: 1_000, nowMs: 0 } as const;
    const first = await transport.acquire(input);
    const replay = await transport.acquire({ ...input, nowMs: 500 });
    expect(first.provider).toBe("mac-mini");
    expect(replay.replayed).toBe(true);
    expect(client.calls).toEqual(["acquire:custom-acquire"]);
  });

  test("rejects a provider receipt that does not honor the fence", async () => {
    const calls: string[] = [];
    const client: VmHostLeaseProviderClient = {
      async acquire() { calls.push("acquire"); return { generation: 99, expiresAtMs: 2_000 }; },
      async renew() { calls.push("renew"); return {}; },
      async release() { calls.push("release"); return {}; },
    };
    const transport = transportFor("huge-blue", { ...fakeClient(), ...client, calls } as FakeClient);
    await expect(transport.acquire({ provider: "huge-blue", leaseId: "lease-fence", hostId: "huge-blue:host", ownerId: "worker", generation: 1, effectKey: "fence", ttlMs: 1_000, nowMs: 0 })).rejects.toMatchObject({ code: "receipt_mismatch" });
    expect(calls).toEqual(["acquire"]);
  });

  test("Huge Blue HTTP factory sends fenced, idempotent lease requests without embedding credentials", async () => {
    const requests: Array<{ url: string; authorization: string; body: Record<string, unknown> }> = [];
    const client = createHugeBlueHostLeaseHttpClient({
      baseUrl: "https://huge-blue.example",
      token: () => "ephemeral-token",
      fetch: async (input, init) => {
        requests.push({ url: String(input), authorization: String(new Headers(init?.headers).get("authorization")), body: JSON.parse(String(init?.body)) as Record<string, unknown> });
        return new Response(JSON.stringify({ leaseId: "provider-lease", expiresAtMs: 1_000, generation: 1 }), { status: 200, headers: { "content-type": "application/json" } });
      },
    });
    const result = await client.acquire({ provider: "huge-blue", operation: "acquire", leaseId: "lease-http", hostId: "huge-blue:host", ownerId: "worker", generation: 1, effectKey: "effect-http", ttlMs: 1_000, nowMs: 0 });
    expect(result).toMatchObject({ providerLeaseId: "provider-lease", expiresAtMs: 1_000, generation: 1 });
    expect(requests).toEqual([{ url: "https://huge-blue.example/v1/hosts/huge-blue%3Ahost/leases/acquire", authorization: "Bearer ephemeral-token", body: { leaseId: "lease-http", ownerId: "worker", generation: 1, ttlMs: 1_000, effectKey: "effect-http" } }]);
  });

  test("fails closed when an adapter is absent", async () => {
    const transport = new VmHostLeaseTransport(new MemoryVmHostLeaseStore(), new Map());
    await expect(transport.acquire({ provider: "freestyle", leaseId: "lease-missing", hostId: "freestyle:host", ownerId: "worker", generation: 1, effectKey: "missing", ttlMs: 1_000, nowMs: 0 })).rejects.toMatchObject({ code: "provider_mismatch" });
  });

  test("validates lease input", async () => {
    const client = fakeClient();
    const transport = transportFor("freestyle", client);
    await expect(transport.acquire({ provider: "freestyle", leaseId: "lease-invalid", hostId: "freestyle:host", ownerId: "worker", generation: 1, effectKey: "invalid", ttlMs: 10, nowMs: 0 })).rejects.toBeInstanceOf(VmHostLeaseError);
  });
});
