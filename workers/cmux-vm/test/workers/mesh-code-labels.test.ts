import { Schema } from "effect";
import { afterEach, beforeEach, expect, it } from "vitest";
import { Mesh } from "../../src/api/mesh.ts";
import { ALL_SCOPES, bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";
import { enrollBody, makeInstallKey } from "../support/mesh-signing.ts";

// Redeeming an enrollment code runs as the code's creator rebuilt from created_by alone, without the creator's
// required labels. So a key confined to labels never makes a code: 403, and no code row. No labelled key holds
// mesh:join and can redeem today (agent keys hold only vm scopes; a service creator is refused at redeem); this keeps
// it closed if one ever does.

const A = "team_alpha";
const LABELS = { role: "cloud" };
const Created = Schema.Struct({ code: Schema.String });
const Enrolled = Schema.Struct({ device: Schema.Struct({ id: Schema.String, tunnelId: Schema.String }) });
type Harness = Awaited<ReturnType<typeof makeHarness>>;
let h: Harness;
beforeEach(async () => { h = await makeHarness(); });
afterEach(async () => { await h.dispose(); });

const labelledMesh = async (admin: string) => {
  const created = await h.request("/v1/mesh-creations", { ...bearer(admin), "idempotency-key": "labelled-mesh" }, { method: "POST", body: { labels: LABELS } });
  expect(created.status).toBe(201);
  return Schema.decodeUnknownSync(Mesh)(await created.json()).id;
};
const createCode = (key: string, mesh: string) => h.request(`/v1/meshes/${mesh}/enrollment-codes`, bearer(key), { method: "POST", body: {} });

it.each(["agent", "admin"])("refuses an enrollment code to a %s key confined to labels, even on a mesh it reaches", async (kind) => {
  const mesh = await labelledMesh(await h.addKey(A, ALL_SCOPES));
  const key = await h.addKey(A, kind === "admin" ? ALL_SCOPES : ["mesh:read", "mesh:join"], { agentLabels: LABELS });
  expect((await h.request(`/v1/meshes/${mesh}`, bearer(key))).status).toBe(200);
  const refused = await createCode(key, mesh);
  expect(refused.status).toBe(403);
  expect(await refused.text()).toContain("confined to labels");
  expect(h.mesh.store.enrollmentCodes()).toHaveLength(0);
});

it("refuses an enrollment code to a service key on its own mesh", async () => {
  await h.dispose();
  h = await makeHarness({ mesh: { tenants: [], services: ["cloud-platform-dev"] } });
  h.setBilling("team_personal_new", true);
  const service = await h.addServiceKey({ id: "cloud-platform-dev", scopes: ["mesh:read", "mesh:write", "mesh:join"], labels: LABELS });
  const headers = { ...bearer(service), "x-cmux-team-id": "team_personal_new" };
  const created = await h.request("/v1/mesh-creations", { ...headers, "idempotency-key": "cloud-team-network" }, { method: "POST", body: { labels: LABELS } });
  expect(created.status).toBe(201);
  const mesh = Schema.decodeUnknownSync(Mesh)(await created.json()).id;
  expect((await h.request(`/v1/meshes/${mesh}/enrollment-codes`, headers, { method: "POST", body: {} })).status).toBe(403);
  expect(h.mesh.store.enrollmentCodes()).toHaveLength(0);
});

it("keeps a labelled key's 404 on a mesh it cannot reach", async () => {
  const admin = await h.addKey(A, ALL_SCOPES);
  const plain = await h.request("/v1/meshes", bearer(admin), { method: "POST", body: {} });
  expect(plain.status).toBe(201);
  const mesh = Schema.decodeUnknownSync(Mesh)(await plain.json()).id;
  const key = await h.addKey(A, ["mesh:read", "mesh:join"], { agentLabels: LABELS });
  expect((await createCode(key, mesh)).status).toBe(404);
});

it("lets an unlabelled key make a code that enrolls a device, as before", async () => {
  const admin = await h.addKey(A, ALL_SCOPES);
  const mesh = await labelledMesh(admin);
  const issued = await createCode(admin, mesh);
  expect(issued.status).toBe(201);
  const { code } = Schema.decodeUnknownSync(Created)(await issued.json());
  const install = await makeInstallKey();
  const enrolled = await h.request(`/v1/meshes/${mesh}/device-enrollments`, {}, {
    method: "POST",
    body: await enrollBody(install, mesh, { name: "headless", wgPublicKey: btoa("a".repeat(32)), code }),
  });
  expect(enrolled.status).toBe(201);
  const { device } = Schema.decodeUnknownSync(Enrolled)(await enrolled.json());
  for (const cmuxId of [device.id, device.tunnelId]) expect(h.resources.find((row) => row.cmuxId === cmuxId)?.labels).toEqual({});
  expect((await h.request(`/v1/devices/${device.id}`, bearer(admin), { method: "DELETE" })).status).toBe(204);
});
