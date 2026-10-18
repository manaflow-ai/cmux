import { afterEach, expect, it } from "vitest";
import { bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;
let current: Harness | undefined;
const harness = async () => { current = await makeHarness(); return current; };
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
