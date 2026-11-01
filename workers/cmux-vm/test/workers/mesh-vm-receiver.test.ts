import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { ALL_SCOPES, bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";
import { addressBody, enrollBody, makeInstallKey, rotateBody } from "../support/mesh-signing.ts";

const TEAM = "team_alpha";
type Harness = Awaited<ReturnType<typeof makeHarness>>;
let h: Harness;
let admin: string;
let mesh: string;
let vm: string;
let keyIndex: number;
const record = (v: unknown): Record<string, unknown> => typeof v === "object" && v !== null ? Object.fromEntries(Object.entries(v)) : {};
const json = async (r: Response) => record(await r.json());
const call = (path: string, key = admin, method = "GET", body?: unknown) => h.request(path, bearer(key), { method, body });
const policy = (key = admin, target = vm, network = mesh) => call(`/v1/meshes/${network}/vms/${target}/receiver-policy`, key);
const apply = (rules: unknown[], expectedVersion = 0) => call(`/v1/meshes/${mesh}/acl`, admin, "PUT", { expectedVersion, rules });
const enroll = async (owner = admin) => {
  const install = await makeInstallKey();
  const wg = btoa(String.fromCharCode(++keyIndex).repeat(32));
  const response = await call(`/v1/meshes/${mesh}/devices`, owner, "POST", await enrollBody(install, mesh, { name: "client", wgPublicKey: wg }));
  expect(response.status).toBe(201);
  const id = record((await json(response))["device"])["id"];
  if (typeof id !== "string") throw new Error("enrollment returned no public id");
  return { id, install, wg };
};

beforeEach(async () => {
  h = await makeHarness();
  admin = await h.addKey(TEAM, ALL_SCOPES);
  keyIndex = 0;
  const response = await call("/v1/meshes", admin, "POST", {});
  const id = (await json(response))["id"];
  if (typeof id !== "string") throw new Error("mesh creation returned no public id");
  mesh = id;
  vm = h.addVm(TEAM).vmId;
  expect((await call(`/v1/meshes/${mesh}/vms/${vm}`, admin, "PUT")).status).toBe(200);
});
afterEach(async () => { await h.dispose(); });

describe("VM receiver policy", () => {
  it("keeps the existing owned member read working", async () => {
    const response = await call(`/v1/meshes/${mesh}/vms/${vm}`);
    expect(response.status).toBe(200);
    expect(await json(response)).toMatchObject({ vmId: vm, meshId: mesh, ipv4: expect.stringMatching(/^10\./u) });
  });

  it("defaults to deny with a bounded current policy and no provider mutation", async () => {
    const before = h.upstreamRequests.length, started = Date.now();
    const response = await policy();
    expect(response.status).toBe(200);
    const body = await json(response);
    expect(body).toMatchObject({ schemaVersion: 1, tenantId: TEAM, vmId: vm, meshId: mesh, aclVersion: 0, peers: [], policyDigest: expect.stringMatching(/^[0-9a-f]{64}$/u) });
    expect(Number(body["checkedAt"])).toBeGreaterThanOrEqual(started);
    expect(Number(body["expiresAt"]) - Number(body["checkedAt"])).toBe(30_000);
    expect(h.upstreamRequests.slice(before).every((r) => r.method === "GET")).toBe(true);
  });

  it("returns only the exact VM's incoming service permissions and current public identities", async () => {
    const client = await enroll(), other = await enroll(), hidden = h.addVm(TEAM).vmId;
    expect((await call(`/v1/meshes/${mesh}/vms/${hidden}`, admin, "PUT")).status).toBe(200);
    expect((await apply([{ src: [client.id], dst: [vm], allow: ["tcp:22", "tcp:4100"] }, { src: [other.id], dst: [hidden], allow: ["*"] }])).status).toBe(200);
    const response = await policy();
    expect(response.status).toBe(200);
    expect((await json(response))["peers"]).toEqual([{
      deviceId: client.id, wgPublicKey: client.wg, installPublicKey: client.install.publicKey,
      allow: [{ protocol: "tcp", port: 22 }, { protocol: "tcp", port: 4100 }],
    }]);
    expect(h.audit).toContainEqual(expect.objectContaining({ action: "mesh.vm.receiver_policy", cmuxId: vm, outcome: "ok" }));
  });

  it("never promotes a public-address transport rule into a service grant", async () => {
    const client = await enroll();
    expect((await apply([{ src: [client.id], dst: [vm], allow: ["tcp:22"] }])).status).toBe(200);
    expect((await h.request(`/v1/devices/${client.id}/signed/address`, {}, { method: "POST", body: await addressBody(client.install, client.id, "2606:4700:1234::1") })).status).toBe(200);
    const response = await policy();
    expect(response.status).toBe(200);
    expect((await json(response))["peers"]).toEqual([expect.objectContaining({ allow: [{ protocol: "tcp", port: 22 }] })]);
  });

  it("updates a rotated peer and removes revoked owners at the same ACL version", async () => {
    const owner = await h.addKey(TEAM, ["mesh:join"]), client = await enroll(owner);
    expect((await apply([{ src: [client.id], dst: [vm], allow: ["tcp:22"] }])).status).toBe(200);
    const firstResponse = await policy(); expect(firstResponse.status).toBe(200);
    const first = await json(firstResponse), key = btoa("z".repeat(32));
    expect((await call(`/v1/devices/${client.id}/rotate-key`, owner, "POST", await rotateBody(client.install, client.id, key))).status).toBe(200);
    const rotated = await json(await policy());
    expect(rotated["aclVersion"]).toBe(first["aclVersion"]);
    expect(rotated["policyDigest"]).not.toBe(first["policyDigest"]);
    expect(rotated["peers"]).toEqual([expect.objectContaining({ wgPublicKey: key })]);
    await h.revokeKey(owner);
    const revoked = await json(await policy());
    expect(revoked["aclVersion"]).toBe(first["aclVersion"]);
    expect(revoked["peers"]).toEqual([]);
    expect(revoked["policyDigest"]).not.toBe(rotated["policyDigest"]);
  });

  it("never leases a peer past its original Native owner key expiry", async () => {
    const expiresAt = new Date(Date.now() + 20_000);
    const owner = await h.addKey(TEAM, ["mesh:join"], { expiresAt });
    const client = await enroll(owner);
    expect((await apply([{ src: [client.id], dst: [vm], allow: ["tcp:22"] }])).status).toBe(200);
    const response = await policy();expect(response.status).toBe(200);
    const body = await json(response);
    expect(body["peers"]).toHaveLength(1);
    expect(body["expiresAt"]).toBe(expiresAt.getTime());
  });

  it("does not infer permission from a detached or different VM", async () => {
    expect((await call(`/v1/meshes/${mesh}/vms/${vm}`, admin, "DELETE")).status).toBe(204);
    const before = h.upstreamRequests.length;
    expect((await policy()).status).toBe(404);
    expect((await policy(admin, h.addVm(TEAM).vmId)).status).toBe(404);
    expect(h.upstreamRequests).toHaveLength(before);
  });

  it("requires both scopes, visibility, tenant ownership and authentication", async () => {
    const before = h.upstreamRequests.length;
    expect((await policy(await h.addKey(TEAM, ["mesh:read"]))).status).toBe(403);
    expect((await policy(await h.addKey(TEAM, ["vm:read"]))).status).toBe(403);
    expect((await policy(await h.addKey("team_bravo", ALL_SCOPES))).status).toBe(404);
    expect((await policy(await h.addKey(TEAM, ALL_SCOPES, { allowlist: [] }))).status).toBe(404);
    expect((await h.request(`/v1/meshes/${mesh}/vms/${vm}/receiver-policy`, {})).status).toBe(401);
    expect(h.upstreamRequests).toHaveLength(before);
  });

  it.each(["wgPublicKey", "installPublicKey"] as const)("omits an ambiguous %s even when the other device has no VM grant", async (field) => {
    const client = await enroll(), shadow = await enroll();
    expect((await apply([{ src: [client.id], dst: [vm], allow: ["tcp:22"] }])).status).toBe(200);
    const row = h.mesh.store.devices.find((d) => d.deviceId === shadow.id)!;
    Object.assign(row, { [field]: field === "wgPublicKey" ? client.wg : client.install.publicKey });
    const response = await policy(); expect(response.status).toBe(200);
    expect((await json(response))["peers"]).toEqual([]);
  });

  it("omits a deleted device even while the stored ACL still names it", async () => {
    const client = await enroll();
    expect((await apply([{ src: [client.id], dst: [vm], allow: ["tcp:22"] }])).status).toBe(200);
    expect((await call(`/v1/devices/${client.id}`, admin, "DELETE")).status).toBe(204);
    const response = await policy(); expect(response.status).toBe(200);
    expect((await json(response))["peers"]).toEqual([]);
  });

  it("uses fresh membership and refuses a membership dependency failure", async () => {
    h.addMember(TEAM, "user_vm_client");
    const owner = { ...bearer(await h.sessionToken("user_vm_client")), "x-cmux-team-id": TEAM };
    const install = await makeInstallKey(), wg = btoa("m".repeat(32));
    const created = await h.request(`/v1/meshes/${mesh}/devices`, owner, { method: "POST", body: await enrollBody(install, mesh, { name: "member", wgPublicKey: wg }) });
    expect(created.status).toBe(201);
    const id = record((await json(created))["device"])["id"];
    expect((await apply([{ src: [id], dst: [vm], allow: ["tcp:22"] }])).status).toBe(200);
    expect((await json(await policy()))["peers"]).toHaveLength(1);
    h.failStackFor("user_vm_client");
    expect((await policy()).status).toBe(503);
    h.failStackFor("user_vm_client", false);h.removeMember(TEAM, "user_vm_client");
    const response = await policy();expect(response.status).toBe(200);
    expect((await json(response))["peers"]).toEqual([]);
  });

  it("refuses an identity changed across the snapshot boundary", async () => {
    const client = await enroll();
    expect((await apply([{ src: [client.id], dst: [vm], allow: ["tcp:22"] }])).status).toBe(200);
    let reads = 0;
    h.mesh.onDeviceInventoryRead(() => {
      if (++reads === 2) Object.assign(h.mesh.store.devices.find((d) => d.deviceId === client.id)!, { wgPublicKey: btoa("n".repeat(32)) });
    });
    expect((await policy()).status).toBe(503);
  });
});
