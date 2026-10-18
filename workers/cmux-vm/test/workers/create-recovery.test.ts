import { Effect, Layer } from "effect";
import { afterEach, expect, it } from "vitest";
import { LimitsUnavailable, memoryLimitsLayer, TenantLimits } from "../../src/limits/service.ts";
import { bearer } from "../support/endpoints.ts";
import { makeHarness, type HarnessOptions } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;
let current: Harness | undefined;
afterEach(async () => { await current?.dispose(); current = undefined; });
const harness = async (options: HarnessOptions = {}) => { current = await makeHarness(options); return current; };
const create = (t: Harness, key: string, idempotency = "recover-create") => t.request("/v1/vms", { ...bearer(key), "idempotency-key": idempotency }, { method: "POST", body: { displayName: "persistent agent", labels: { role: "team-vm" } } });
const allocation = (t: Harness) => t.upstream.callsTo("POST", /^\/v5\/vms$/);
const failCompletion = async (loseAbandon = false) => {
  const base = await Effect.runPromise(Effect.provide(TenantLimits, memoryLimitsLayer()));
  const faults = { remaining: 1 };
  return { faults, layer: Layer.succeed(TenantLimits, { ...base, abandon: loseAbandon ? () => Effect.void : base.abandon, advance: (tenant, key, progress) => {
    if (progress.phase === "done" && faults.remaining > 0) { faults.remaining--; return Effect.fail(new LimitsUnavailable({ cause: "lost durable completion" })); }
    return base.advance(tenant, key, progress);
  } }) };
};

it("recovers a provider create whose response was lost, with one physical VM and no account listing", async () => {
  const t = await harness(), key = await t.addKey("team_alpha", ["vm:write"]);
  t.upstream.faults.lostCreateResponses = 1;
  const first = await create(t, key);
  expect([201, 503]).toContain(first.status);
  const second = await create(t, key);
  expect(second.status).toBe(201);
  expect(t.upstream.vms.size).toBe(1);
  expect(t.resources.filter((r) => r.kind === "vm")).toHaveLength(1);
  expect(t.upstream.callsTo("GET", /^\/v5\/vms$/)).toHaveLength(0);
});

it("does not report success until idempotency completion is durable, then repairs the same allocation", async () => {
  const completion = await failCompletion(), t = await harness({ limits: completion.layer }), key = await t.addKey("team_alpha", ["vm:write"]);
  expect((await create(t, key)).status).toBe(503);
  expect(t.resources).toHaveLength(1);
  const retry = await create(t, key);
  expect(retry.status).toBe(201);
  expect(await retry.json()).toMatchObject({ id: t.resources[0]!.cmuxId });
  expect(allocation(t)).toHaveLength(1);
  expect(t.upstream.vms.size).toBe(1);
});

it("settles a committed allocation without waiting for the lease when completion and abandon both fail", async () => {
  const completion = await failCompletion(true), t = await harness({ limits: completion.layer }), key = await t.addKey("team_alpha", ["vm:write"]);
  expect((await create(t, key)).status).toBe(503);
  expect((await create(t, key)).status).toBe(201);
  expect(allocation(t)).toHaveLength(1);
  expect(t.resources).toHaveLength(1);
});

it.each(["before", "after"] as const)("repairs an ownership write failure %s commit without deleting or duplicating the VM", async (when) => {
  const t = await harness(), key = await t.addKey("team_alpha", ["vm:write"]);
  t.recordFault[when] = 1;
  expect((await create(t, key)).status).toBe(503);
  expect(t.upstream.vms.size).toBe(1);
  const retry = await create(t, key);
  expect(retry.status).toBe(201);
  expect(t.resources.filter((r) => r.kind === "vm")).toHaveLength(1);
  expect(allocation(t)).toHaveLength(1);
  expect(t.upstream.callsTo("DELETE", /^\/v5\/vms\//)).toHaveLength(0);
});

it("retains an uncertain allocation's quota slot while letting its own key recover", async () => {
  const t = await harness({ maxVms: 1 }), key = await t.addKey("team_alpha", ["vm:write"]);
  t.recordFault.before = 1;
  expect((await create(t, key)).status).toBe(503);
  expect((await create(t, key, "another-create")).status).toBe(429);
  expect((await create(t, key)).status).toBe(201);
  expect(allocation(t)).toHaveLength(1);
});

it("keeps a deleted allocation deleted when its completion reply was lost", async () => {
  const completion = await failCompletion(), t = await harness({ limits: completion.layer }), key = await t.addKey("team_alpha", ["vm:write", "vm:read"]);
  expect((await create(t, key)).status).toBe(503);
  const vm = t.resources[0]!.cmuxId;
  expect((await t.request(`/v1/vms/${vm}`, bearer(key), { method: "DELETE" })).status).toBe(204);
  expect((await create(t, key)).status).toBe(404);
  expect(t.upstream.vms.size).toBe(0);
  expect(allocation(t)).toHaveLength(1);
});

it("recovers a fork's lost VM response without taking another snapshot or making another VM", async () => {
  const t = await harness(), source = t.addVm("team_alpha"), key = await t.addKey("team_alpha", ["vm:write"]);
  t.upstream.faults.lostCreateResponses = 1;
  const fork = () => t.request(`/v1/vms/${source.vmId}/fork`, { ...bearer(key), "idempotency-key": "recover-fork" }, { method: "POST", body: { labels: { role: "agent" } } });
  const first = await fork(); expect([201, 503]).toContain(first.status);
  expect((await fork()).status).toBe(201);
  expect(t.upstream.vms.size).toBe(2);
  expect(t.upstream.callsTo("POST", /\/snapshot$/)).toHaveLength(1);
  expect(allocation(t)).toHaveLength(1);
});

it("pins an uncertain create to its provider context and resumes only when that context is restored", async () => {
  const t = await harness(), key = await t.addKey("team_alpha", ["vm:write"]);
  t.recordFault.before = 1;
  expect((await create(t, key)).status).toBe(503);
  const before = t.upstreamRequests.length;
  t.setProviderConfig("https://another-provider.test", "rotated-test-key");
  expect((await create(t, key)).status).toBe(503);
  expect(t.upstreamRequests).toHaveLength(before);
  t.setProviderConfig();
  expect((await create(t, key)).status).toBe(201);
  expect(allocation(t)).toHaveLength(1);
});

it("refuses a conflicting VM at the exact recovery slug without adopting or replacing it", async () => {
  const t = await harness(), key = await t.addKey("team_alpha", ["vm:write"]);
  t.recordFault.before = 1;
  expect((await create(t, key)).status).toBe(503);
  const machine = [...t.upstream.vms.values()][0]!;
  machine.metadata["cmux_tenant"] = "team_bravo";
  expect((await create(t, key)).status).toBe(503);
  expect(t.resources).toHaveLength(0);
  expect(allocation(t)).toHaveLength(1);
  expect(t.upstream.callsTo("DELETE", /^\/v5\/vms\//)).toHaveLength(0);
});

it("preserves the admitted creator when another key in the tenant resumes the same request", async () => {
  const t = await harness(), first = await t.addKey("team_alpha", ["vm:write"]), second = await t.addKey("team_alpha", ["vm:write"]);
  t.recordFault.before = 1;
  expect((await create(t, first)).status).toBe(503);
  const creator = t.audit[0]!.actor;
  expect((await create(t, second)).status).toBe(201);
  expect(t.resources[0]?.createdBy).toBe(creator);
  expect(allocation(t)).toHaveLength(1);
});
