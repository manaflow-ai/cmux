import { afterEach, expect, it } from "vitest";
import { bearer } from "../support/endpoints.ts";
import { makeHarness, type HarnessOptions } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;
let current: Harness | undefined;
const harness = async (options?: HarnessOptions) => { current = await makeHarness(options); return current; };
afterEach(async () => { await current?.dispose(); current = undefined; });
const resize = (t: Harness, key: string, id: string, resources: object, retry?: string) =>
  t.request(`/v1/vms/${id}/resize`, { ...bearer(key), ...(retry === undefined ? {} : { "Idempotency-Key": retry }) }, { method: "POST", body: { resources } });

it("grows the owned VM in place and returns its public resources", async () => {
  const t = await harness();
  const owned = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:write"]);
  const response = await resize(t, key, owned.vmId, { diskMib: 65536 });
  expect(response.status).toBe(200);
  const body = await response.text();
  expect(JSON.parse(body)).toMatchObject({ id: owned.vmId, resources: { diskMib: 65536 } });
  expect(body).not.toContain(owned.upstreamId);
  expect(t.upstream.callsTo("POST", /\/resize$/)[0]?.json).toEqual({ storage: 65536 });
  expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)).toHaveLength(0);
  expect(t.upstream.callsTo("DELETE", /./)).toHaveLength(0);
});

it("requires VM write permission before any provider request", async () => {
  const t = await harness();
  const owned = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:read"]);
  expect((await resize(t, key, owned.vmId, { vcpus: 8 })).status).toBe(403);
  expect(t.upstreamRequests).toHaveLength(0);
});

it("does not grow another tenant's VM", async () => {
  const t = await harness();
  const owned = t.addVm("team_alpha");
  const key = await t.addKey("team_bravo", ["vm:write"]);
  expect((await resize(t, key, owned.vmId, { vcpus: 8 })).status).toBe(404);
  expect(t.upstreamRequests).toHaveLength(0);
});

it("requires the existing VM plan before provider access", async () => {
  const t = await harness();
  const owned = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:write"]);
  t.setBilling("team_alpha", false);
  expect((await resize(t, key, owned.vmId, { vcpus: 8 })).status).toBe(402);
  expect(t.upstreamRequests).toHaveLength(0);
});

it("replays the same resize key and rejects changed intent", async () => {
  const t = await harness();
  const owned = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:write"]);
  expect((await resize(t, key, owned.vmId, { vcpus: 8 }, "resize-retry")).status).toBe(200);
  expect((await resize(t, key, owned.vmId, { vcpus: 8 }, "resize-retry")).status).toBe(200);
  expect((await resize(t, key, owned.vmId, { vcpus: 16 }, "resize-retry")).status).toBe(409);
  expect(t.upstream.callsTo("POST", /\/resize$/)).toHaveLength(1);
});


it("keeps larger axes and sends only axes that need growth", async () => {
  const t = await harness();
  const owned = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:write"]);
  const response = await resize(t, key, owned.vmId, { vcpus: 2, diskMib: 65536 });
  expect(response.status).toBe(200);
  expect(await response.json()).toMatchObject({ resources: { vcpus: 4, diskMib: 65536 } });
  expect(t.upstream.callsTo("POST", /\/resize$/)[0]?.json).toEqual({ storage: 65536 });
});

it("does not mutate resources that already satisfy every floor", async () => {
  const t = await harness();
  const owned = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:write"]);
  expect((await resize(t, key, owned.vmId, { vcpus: 2, memoryMib: 4096, diskMib: 16384 })).status).toBe(200);
  expect(t.upstream.callsTo("POST", /./)).toHaveLength(0);
  expect(t.audit).toContainEqual(expect.objectContaining({ action: "vm.resize", cmuxId: owned.vmId, outcome: "ok" }));
});

it("does not reserve a new VM quota slot for an existing VM", async () => {
  const t = await harness({ maxVms: 0 });
  const owned = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:write"]);
  expect((await resize(t, key, owned.vmId, { vcpus: 8 })).status).toBe(200);
});

it("confirms a fully applied resize after the provider loses its answer", async () => {
  const t = await harness();
  const owned = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:write"]);
  t.upstream.resizeReplies.set(owned.upstreamId, () => new Response(null, { status: 503 }));
  const response = await resize(t, key, owned.vmId, { vcpus: 8 }, "lost-answer");
  expect(response.status).toBe(200);
  expect(await response.json()).toMatchObject({ resources: { vcpus: 8 } });
  expect((await resize(t, key, owned.vmId, { vcpus: 8 }, "lost-answer")).status).toBe(200);
  expect(t.upstream.callsTo("POST", /\/resize$/)).toHaveLength(1);
  expect(t.upstream.callsTo("DELETE", /./)).toHaveLength(0);
});

it("retains partial growth and retries only the unfinished axis", async () => {
  const t = await harness();
  const owned = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:write"]);
  const real = t.upstream.vms.get(owned.upstreamId);
  if (real === undefined) throw new Error("missing fixture");
  t.upstream.resizeReplies.set(owned.upstreamId, () => {
    real.resources.memory = 8192;
    return new Response(null, { status: 503 });
  });
  expect((await resize(t, key, owned.vmId, { vcpus: 8, memoryMib: 16384 }, "partial")).status).toBe(503);
  expect(real.resources.cpu).toBe(8);
  expect(t.isDeleted(owned.vmId)).toBe(false);
  t.upstream.resizeReplies.delete(owned.upstreamId);
  expect((await resize(t, key, owned.vmId, { vcpus: 8, memoryMib: 16384 }, "partial")).status).toBe(200);
  expect(t.upstream.callsTo("POST", /\/resize$/).map((call) => call.json)).toEqual([
    { cpu: 8, memory: 16384 }, { memory: 16384 },
  ]);
  expect(t.upstream.callsTo("DELETE", /./)).toHaveLength(0);
});

it("does not accept a successful provider status without the requested resources", async () => {
  const t = await harness();
  const owned = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:write"]);
  const real = t.upstream.vms.get(owned.upstreamId);
  if (real === undefined) throw new Error("missing fixture");
  t.upstream.resizeReplies.set(owned.upstreamId, () => {
    real.resources.cpu = 4;
    return Response.json({ state: "running", resources: real.resources, createdAt: "fixture", updatedAt: "fixture" });
  });
  expect((await resize(t, key, owned.vmId, { vcpus: 8 })).status).toBe(503);
  expect(t.upstream.callsTo("DELETE", /./)).toHaveLength(0);
});

it("accepts provider rounding above the requested floors", async () => {
  const t = await harness();
  const owned = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:write"]);
  const real = t.upstream.vms.get(owned.upstreamId);
  if (real === undefined) throw new Error("missing fixture");
  t.upstream.resizeReplies.set(owned.upstreamId, () => {
    real.resources.memory = 16384;
    return Response.json({ state: "running", resources: real.resources, createdAt: "fixture", updatedAt: "fixture" });
  });
  const response = await resize(t, key, owned.vmId, { memoryMib: 12288 });
  expect(response.status).toBe(200);
  expect(await response.json()).toMatchObject({ resources: { memoryMib: 16384 } });
});

it("allows CPU growth while paused but leaves failed disk growth intact", async () => {
  const t = await harness();
  const owned = t.addVm("team_alpha", "paused");
  const key = await t.addKey("team_alpha", ["vm:write"]);
  expect((await resize(t, key, owned.vmId, { vcpus: 8 })).status).toBe(200);
  expect((await resize(t, key, owned.vmId, { diskMib: 65536 })).status).toBe(409);
  expect(t.isDeleted(owned.vmId)).toBe(false);
  expect(t.upstream.callsTo("DELETE", /./)).toHaveLength(0);
});

it.each([400, 404, 409, 429, 503])("reports provider failure %s without deleting the VM or reflecting its body", async (status) => {
  const t = await harness();
  const owned = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:write"]);
  t.upstream.fail("resize", status, 1, { message: "private-provider-fixture" });
  const response = await resize(t, key, owned.vmId, { vcpus: 8 });
  expect(response.status).toBe(status === 400 ? 409 : status);
  expect(await response.text()).not.toContain("private-provider-fixture");
  expect(t.upstream.callsTo("DELETE", /./)).toHaveLength(0);
});

it("enforces resource allowlists and service labels before provider reads", async () => {
  const t = await harness();
  const owned = t.addVm("team_alpha");
  const other = t.addVm("team_alpha");
  const limited = await t.addKey("team_alpha", ["vm:write"], { allowlist: [other.vmId] });
  expect((await resize(t, limited, owned.vmId, { vcpus: 8 })).status).toBe(404);
  const service = await t.addServiceKey({ scopes: ["vm:write"] });
  const denied = await t.request(`/v1/vms/${owned.vmId}/resize`, { ...bearer(service), "x-cmux-team-id": "team_alpha" }, { method: "POST", body: { resources: { vcpus: 8 } } });
  expect(denied.status).toBe(404);
  expect(t.upstreamRequests).toHaveLength(0);
  const admitted = await t.addKey("team_alpha", ["vm:write"], { allowlist: [owned.vmId] });
  expect((await resize(t, admitted, owned.vmId, { vcpus: 8 })).status).toBe(200);
});

it("does not reuse a completed resize key for another VM", async () => {
  const t = await harness();
  const a = t.addVm("team_alpha");
  const b = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:write"]);
  expect((await resize(t, key, a.vmId, { vcpus: 8 }, "one-target")).status).toBe(200);
  expect((await resize(t, key, b.vmId, { vcpus: 8 }, "one-target")).status).toBe(409);
  expect(t.upstream.callsTo("POST", /\/resize$/)).toHaveLength(1);
});

it.each([{}, { vcpus: 0 }, { memoryMib: 65537 }, { diskMib: 20000.5 }, { vcpus: 8, providerId: "unsafe" }])(
  "rejects empty, invalid or unknown resource fields before provider access", async (resources) => {
    const t = await harness();
    const owned = t.addVm("team_alpha");
    const key = await t.addKey("team_alpha", ["vm:write"]);
    expect((await resize(t, key, owned.vmId, resources)).status).toBe(400);
    expect(t.upstreamRequests).toHaveLength(0);
  },
);

it("does not replay success when the provider no longer confirms the floors", async () => {
  const t = await harness();
  const owned = t.addVm("team_alpha");
  const key = await t.addKey("team_alpha", ["vm:write"]);
  expect((await resize(t, key, owned.vmId, { vcpus: 8 }, "verify-replay")).status).toBe(200);
  const real = t.upstream.vms.get(owned.upstreamId);
  if (real === undefined) throw new Error("missing fixture");
  real.resources.cpu = 4;
  expect((await resize(t, key, owned.vmId, { vcpus: 8 }, "verify-replay")).status).toBe(503);
  expect(t.upstream.callsTo("POST", /\/resize$/)).toHaveLength(1);
});
