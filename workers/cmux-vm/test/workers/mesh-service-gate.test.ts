import { Schema } from "effect";
import { afterEach, expect, it } from "vitest";
import { Mesh, MeshList } from "../../src/api/mesh.ts";
import { ALL_SCOPES, bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";
import { deviceRequestBody, enrollBody, makeInstallKey } from "../support/mesh-signing.ts";

// CMUX_VM_MESH_SERVICE_IDS: a listed service has the mesh experiment for every team it acts for (a personal
// tenant cmux Cloud provisioned a moment ago is on no tenant list), for its own requests only. Everyone else
// on that team, and every other service, still sees no mesh route.

const SERVICE = "cloud-platform-dev";
const TEAM = "team_personal_new";
const EnrolledDeviceResponse = Schema.Struct({ device: Schema.Struct({ id: Schema.String }) });
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

it("admits the tenant's user and an installed device after a listed service makes its mesh", async () => {
  const harness = await start();
  const key = await service(harness);
  const created = await harness.request("/v1/mesh-creations", as(key, { "idempotency-key": "cloud-team-network" }), {
    method: "POST",
    body: { displayName: "Cloud network", labels: { role: "cloud" } },
  });
  expect(created.status).toBe(201);
  const mesh = Schema.decodeUnknownSync(Mesh)(await created.json()).id;

  const user = "user_personal_owner";
  harness.addMember(TEAM, user);
  const userHeaders = { ...bearer(await harness.sessionToken(user)), "x-cmux-team-id": TEAM };
  expect((await harness.request("/v1/meshes", userHeaders)).status).toBe(200);

  const ownerKey = await harness.addKey(TEAM, ALL_SCOPES);
  const install = await makeInstallKey();
  const enrolled = await harness.request(`/v1/meshes/${mesh}/devices`, bearer(ownerKey), {
    method: "POST",
    body: await enrollBody(install, mesh, { name: "personal-device", wgPublicKey: btoa("a".repeat(32)) }),
  });
  expect(enrolled.status).toBe(201);
  const enrolledBody = Schema.decodeUnknownSync(EnrolledDeviceResponse)(await enrolled.json());
  const signed = await harness.request(`/v1/devices/${enrolledBody.device.id}/signed/overlay-policy`, {}, {
    method: "POST",
    body: await deviceRequestBody(install, enrolledBody.device.id, "overlay-policy"),
  });
  expect(signed.status).toBe(200);
});

it("keeps the 404 when the only mesh was made by a tenant caller", async () => {
  const harness = await start();
  const key = await service(harness);
  const created = await harness.request("/v1/mesh-creations", as(key, { "idempotency-key": "cloud-team-network" }), {
    method: "POST",
    body: { labels: { role: "cloud" } },
  });
  expect(created.status).toBe(201);
  const mesh = Schema.decodeUnknownSync(Mesh)(await created.json()).id;
  const row = harness.resources.find((resource) => resource.kind === "mesh" && resource.cmuxId === mesh);
  if (row === undefined) throw new Error("service mesh was not recorded");
  Object.assign(row, { createdBy: "key:tenant-caller" });
  const user = "user_without_service_mesh";
  harness.addMember(TEAM, user);
  const userHeaders = { ...bearer(await harness.sessionToken(user)), "x-cmux-team-id": TEAM };
  expect((await harness.request("/v1/meshes", userHeaders)).status).toBe(404);
});

it("keeps another tenant's user at 404 after a service makes a mesh", async () => {
  const harness = await start();
  const key = await service(harness);
  const created = await harness.request("/v1/mesh-creations", as(key, { "idempotency-key": "cloud-team-network" }), {
    method: "POST",
    body: { labels: { role: "cloud" } },
  });
  expect(created.status).toBe(201);
  const other = "user_other_tenant";
  harness.addMember("team_other", other);
  const otherHeaders = { ...bearer(await harness.sessionToken(other)), "x-cmux-team-id": "team_other" };
  expect((await harness.request("/v1/meshes", otherHeaders)).status).toBe(404);
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

it("lets every listed service through, as staging lists cmux-platform's dev and staging keys", async () => {
  h = await makeHarness({ mesh: { tenants: [], services: [SERVICE, "cloud-platform-staging"] } });
  const dev = await service(h);
  const staging = await service(h, "cloud-platform-staging");
  expect((await h.request("/v1/meshes", as(dev))).status).toBe(200);
  expect((await h.request("/v1/meshes", as(staging))).status).toBe(200);
});

it("lets a listed service write its mesh's ACL only with the acl scopes granted by CMUX_VM_SERVICE_KEY_SCOPE_GRANTS", async () => {
  const create = async (harness: Harness, key: string) => {
    const created = await harness.request("/v1/mesh-creations", as(key, { "idempotency-key": "cloud-team-network" }), {
      method: "POST",
      body: { displayName: "Cloud network", labels: { role: "cloud" } },
    });
    expect(created.status).toBe(201);
    return Schema.decodeUnknownSync(Mesh)(await created.json()).id;
  };
  const rules = [{ src: ["device:*"], dst: ["vm:*"], allow: ["tcp:22", "tcp:4100"] }];

  const without = await start();
  const plainKey = await service(without);
  const plainMesh = await create(without, plainKey);
  expect((await without.request(`/v1/meshes/${plainMesh}/acl`, as(plainKey))).status).toBe(403);
  expect((await without.request(`/v1/meshes/${plainMesh}/acl`, as(plainKey), { method: "PUT", body: { expectedVersion: 0, rules } })).status).toBe(403);
  await without.dispose();
  h = undefined;

  h = await makeHarness({
    mesh: { tenants: ["team_alpha"], services: [SERVICE] },
    serviceScopeGrants: JSON.stringify({ [SERVICE]: ["acl:read", "acl:write"] }),
  });
  h.setBilling(TEAM, true);
  const key = await service(h);
  const mesh = await create(h, key);
  const before = await h.request(`/v1/meshes/${mesh}/acl`, as(key));
  expect(before.status).toBe(200);
  expect(await before.json()).toMatchObject({ version: 0, rules: [] });
  const put = await h.request(`/v1/meshes/${mesh}/acl`, as(key), { method: "PUT", body: { expectedVersion: 0, rules } });
  expect(put.status).toBe(200);
  expect(await put.json()).toMatchObject({ meshId: mesh, version: 1 });
  const after = await h.request(`/v1/meshes/${mesh}/acl`, as(key));
  expect(await after.json()).toMatchObject({ version: 1, rules });
  // A grant names one key: another service with the same labels gets nothing more.
  const other = await service(h, "cloud-chief");
  expect((await h.request(`/v1/meshes/${mesh}/acl`, as(other))).status).toBe(404);
});
