import { Schema } from "effect";
import { afterEach, expect, it } from "vitest";
import { Mesh } from "../../src/api/mesh.ts";
import { bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";
import { enrollBody, makeInstallKey } from "../support/mesh-signing.ts";

// cmux#34244: in production, cmux-platform's entitled service key makes a member's personal team mesh
// (CMUX_VM_ENTITLED_SERVICE_IDS). The member's Mac app then enrolls its device with the member's own session,
// which is on no tenant list. A device joining a mesh an entitled service made is entitled; the member must still
// belong to the team and the team must own the mesh.

const SERVICE = "cloud-platform-production";
const OTHER_SERVICE = "cloud-platform-staging";
const TEAM = "team_personal_member";
type Harness = Awaited<ReturnType<typeof makeHarness>>;
let h: Harness | undefined;
afterEach(async () => { await h?.dispose(); h = undefined; });

const start = async (entitledServiceIds: ReadonlyArray<string> = [SERVICE]) => {
  h = await makeHarness({
    environment: "production",
    policyEntitlements: { entitledServiceIds, manaflowTenantIds: [] },
    mesh: { tenants: [], services: [SERVICE, OTHER_SERVICE] },
  });
  return h;
};
const as = (secret: string, extra: Record<string, string> = {}) => ({ ...bearer(secret), "x-cmux-team-id": TEAM, ...extra });

const serviceMesh = async (harness: Harness) => {
  const key = await harness.addServiceKey({ id: SERVICE, scopes: ["mesh:read", "mesh:write", "mesh:join"], labels: { role: "cloud" } });
  const created = await harness.request("/v1/mesh-creations", as(key, { "idempotency-key": "cloud-team-network" }), {
    method: "POST",
    body: { displayName: "Cloud network", labels: { role: "cloud" } },
  });
  expect(created.status).toBe(201);
  return Schema.decodeUnknownSync(Mesh)(await created.json()).id;
};

const enrollAs = async (harness: Harness, headers: Record<string, string>, mesh: string, name: string, byte: string) =>
  harness.request(`/v1/meshes/${mesh}/devices`, headers, {
    method: "POST",
    body: await enrollBody(await makeInstallKey(), mesh, { name, wgPublicKey: btoa(byte.repeat(32)) }),
  });

it("lets a member's session enroll a device into the mesh the entitled service made, under production policy", async () => {
  const harness = await start();
  const mesh = await serviceMesh(harness);
  const user = "user_personal_member";
  harness.addMember(TEAM, user);
  const enrolled = await enrollAs(harness, as(await harness.sessionToken(user)), mesh, "member-mac", "a");
  expect(enrolled.status).toBe(201);
});

it("refuses a member's session on a mesh made by a service that is not entitled", async () => {
  const harness = await start();
  const mesh = await serviceMesh(harness);
  // Another mesh-experiment service (on CMUX_VM_MESH_SERVICE_IDS but not CMUX_VM_ENTITLED_SERVICE_IDS) made it.
  const row = harness.resources.find((resource) => resource.kind === "mesh" && resource.cmuxId === mesh);
  if (row === undefined) throw new Error("service mesh was not recorded");
  Object.assign(row, { createdBy: `service:${OTHER_SERVICE}` });
  const user = "user_personal_member";
  harness.addMember(TEAM, user);
  const refused = await enrollAs(harness, as(await harness.sessionToken(user)), mesh, "member-mac", "b");
  expect(refused.status).toBe(402);
});

it("refuses a session of someone who is not a member of the team", async () => {
  const harness = await start();
  const mesh = await serviceMesh(harness);
  const outsider = "user_not_in_team";
  harness.addMember("team_other", outsider);
  const refused = await enrollAs(harness, as(await harness.sessionToken(outsider)), mesh, "outsider-mac", "c");
  expect(refused.status).toBe(403);
});

it("keeps the service itself refused when it is not entitled", async () => {
  const harness = await start([]);
  const key = await harness.addServiceKey({ id: SERVICE, scopes: ["mesh:read", "mesh:write", "mesh:join"], labels: { role: "cloud" } });
  const created = await harness.request("/v1/mesh-creations", as(key, { "idempotency-key": "cloud-team-network" }), {
    method: "POST",
    body: { labels: { role: "cloud" } },
  });
  expect(created.status).toBe(402);
});
