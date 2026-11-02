import { Schema } from "effect";
import { afterEach, expect, it } from "vitest";
import { Mesh, MeshList } from "../../src/api/mesh.ts";
import { ALL_SCOPES, bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

// CMUX_VM_MESH_SERVICE_IDS: a listed service has the mesh experiment for every team it acts for (a personal
// tenant cmux Cloud provisioned a moment ago is on no tenant list), for its own requests only. Everyone else
// on that team, and every other service, still sees no mesh route.

const SERVICE = "cloud-platform-dev";
const TEAM = "team_personal_new";
type Harness = Awaited<ReturnType<typeof makeHarness>>;
let h: Harness | undefined;
afterEach(async () => { await h?.dispose(); h = undefined; });

// Staging treats every tenant as dev/test, so the new tenant may create (entitlementsFromPolicyLayer).
const start = async () => {
  h = await makeHarness({ mesh: { tenants: ["team_alpha"], services: [SERVICE] } });
  h.setBilling(TEAM, true);
  return h;
};
const service = (harness: Harness, id = SERVICE) =>
  harness.addServiceKey({ id, scopes: ["mesh:read", "mesh:write", "mesh:join"], labels: { role: "cloud" } });
const as = (secret: string, extra: Record<string, string> = {}) => ({ ...bearer(secret), "x-cmux-team-id": TEAM, ...extra });

it("gives a listed service an empty mesh list for a new tenant, then creates its mesh", async () => {
  const harness = await start();
  const key = await service(harness);
  const list = await harness.request("/v1/meshes", as(key));
  expect(list.status).toBe(200);
  expect(await list.json()).toEqual({ items: [] });
  const created = await harness.request("/v1/mesh-creations", as(key, { "idempotency-key": "cloud-team-network" }), {
    method: "POST",
    body: { displayName: "Cloud network", labels: { role: "cloud" } },
  });
  expect(created.status).toBe(201);
  const mesh = Schema.decodeUnknownSync(Mesh)(await created.json()).id;
  const after = await harness.request("/v1/meshes", as(key));
  expect(after.status).toBe(200);
  expect(Schema.decodeUnknownSync(MeshList)(await after.json()).items.map((item) => item.id)).toEqual([mesh]);
  expect((await harness.request(`/v1/meshes/${mesh}`, as(key))).status).toBe(200);
  expect(harness.upstreamRequests.filter((r) => r.method === "POST" && r.path === "/v5/vpcs")).toHaveLength(1);
});

it("keeps the 404 for another service and for the tenant's own keys", async () => {
  const harness = await start();
  const other = await service(harness, "cloud-chief");
  const list = await harness.request("/v1/meshes", as(other));
  expect(list.status).toBe(404);
  const create = await harness.request("/v1/mesh-creations", as(other, { "idempotency-key": "other-service" }), {
    method: "POST",
    body: { labels: { role: "cloud" } },
  });
  expect(create.status).toBe(404);
  const tenantKey = await harness.addKey(TEAM, ALL_SCOPES);
  expect((await harness.request("/v1/meshes", bearer(tenantKey))).status).toBe(404);
  expect(harness.upstreamRequests).toHaveLength(0);
});

it("keeps CMUX_VM_MESH_TENANT_IDS as it was", async () => {
  const harness = await start();
  const key = await harness.addKey("team_alpha", ALL_SCOPES);
  expect((await harness.request("/v1/meshes", bearer(key))).status).toBe(200);
});

it("stays off for a listed service while the experiment itself is off", async () => {
  h = await makeHarness({ mesh: { experiment: false, tenants: [], services: [SERVICE] } });
  const key = await service(h);
  expect((await h.request("/v1/meshes", as(key))).status).toBe(404);
});
