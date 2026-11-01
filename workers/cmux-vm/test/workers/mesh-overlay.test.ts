import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { ALL_SCOPES, bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";
import { deviceRequestBody, enrollBody, makeInstallKey, rotateBody, type InstallKey } from "../support/mesh-signing.ts";

const TEAM = "team_alpha";
const WG = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDE=";
const WG2 = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDI=";
const WG3 = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDM=";
type Harness = Awaited<ReturnType<typeof makeHarness>>;
let h: Harness;
let admin: string;
let mesh: string;
let install: InstallKey;
let keyIndex = 0;
const record = (body: unknown): Record<string, unknown> => typeof body === "object" && body !== null ? Object.fromEntries(Object.entries(body)) : {};
const json = async (response: Response) => record(await response.json());
const call = (path: string, key: string, method = "GET", body?: unknown) => h.request(path, bearer(key), { method, body });
const read = (id: string, key = admin) => call(`/v1/devices/${id}/overlay-policy`, key);
const enroll = async (key = admin, name = "device") => {
  const wgPublicKey = [WG, WG2, WG3][keyIndex++] ?? btoa(String.fromCharCode(...new Uint8Array(32).fill(keyIndex)));
  const response = await call(`/v1/meshes/${mesh}/devices`, key, "POST", await enrollBody(install, mesh, { name, wgPublicKey }));
  expect(response.status).toBe(201);
  const id = record((await json(response))["device"])["id"];
  if (typeof id !== "string") throw new Error("enroll returned no device id");
  return id;
};
const apply = (rules: unknown[], expectedVersion = 0) => call(`/v1/meshes/${mesh}/acl`, admin, "PUT", { expectedVersion, rules });
const signed = async (id: string, body = deviceRequestBody(install, id, "overlay-policy")) =>
  h.request(`/v1/devices/${id}/signed/overlay-policy`, {}, { method: "POST", body: await body });

beforeEach(async () => {
  h = await makeHarness();
  admin = await h.addKey(TEAM, ALL_SCOPES);
  install = await makeInstallKey();
  keyIndex = 0;
  const response = await call("/v1/meshes", admin, "POST", {});
  const id = (await json(response))["id"];
  if (typeof id !== "string") throw new Error("create returned no mesh id");
  mesh = id;
});
afterEach(async () => { await h.dispose(); });

describe("device overlay policy", () => {
  it("includes an explicit default-deny VM projection in the signed identity policy", async () => {
    const id = await enroll();
    const response = await signed(id);
    expect(response.status).toBe(200);
    const body = await json(response);
    expect(body).toMatchObject({ tenantId: TEAM, deviceId: id, wgPublicKey: WG, installPublicKey: install.publicKey });
    expect(body["vms"]).toEqual([]);
  });

  it("binds only this device's current VM ports to the same signed policy and digest", async () => {
    const id = await enroll();
    const other = await enroll(admin, "other");
    const vm = h.addVm(TEAM);
    const hidden = h.addVm(TEAM);
    for (const target of [vm, hidden]) {
      const attached = await call(`/v1/meshes/${mesh}/vms/${target.vmId}`, admin, "PUT");
      expect(attached.status).toBe(200);
    }
    expect((await apply([
      { src: [id], dst: [vm.vmId], allow: ["tcp:22", "tcp:4100"] },
      { src: [other], dst: [hidden.vmId], allow: ["tcp:22"] },
    ])).status).toBe(200);
    const first = await json(await signed(id));
    expect(first["vms"]).toEqual([{
      kind: "vm", id: vm.vmId, address: expect.stringMatching(/^10\./u),
      allow: [{ protocol: "tcp", port: 22 }, { protocol: "tcp", port: 4100 }],
    }]);
    expect(first["peers"]).toEqual([]);
    expect((await call(`/v1/meshes/${mesh}/vms/${vm.vmId}`, admin, "DELETE")).status).toBe(204);
    const removed = await json(await signed(id));
    expect(removed["aclVersion"]).toBe(first["aclVersion"]);
    expect(removed["vms"]).toEqual([]);
    expect(removed["policyDigest"]).not.toBe(first["policyDigest"]);
  });

  it.each(["account", "signed"] as const)("identifies the authoritative tenant for a %s policy read", async (mode) => {
    const id = await enroll();
    const response = mode === "account" ? await read(id) : await h.request(`/v1/devices/${id}/signed/overlay-policy`, { "x-cmux-team-id": "team_bravo" }, {
      method: "POST", body: await deviceRequestBody(install, id, "overlay-policy"),
    });
    expect(response.status).toBe(200);
    expect((await json(response))["tenantId"]).toBe(TEAM);
  });

  it("defaults to deny and exposes only public identity for the requesting device", async () => {
    const id = await enroll();
    const before = h.upstreamRequests.length;
    const response = await read(id);
    expect(response.status).toBe(200);
    const body = await json(response);
    expect(body).toMatchObject({ deviceId: id, meshId: mesh, wgPublicKey: WG, installPublicKey: install.publicKey, aclVersion: 0, peers: [] });
    expect(Object.keys(body).sort()).toEqual(["aclVersion", "deviceId", "installPublicKey", "meshId", "peers", "policyDigest", "tenantId", "vms", "wgPublicKey"]);
    expect(h.upstreamRequests).toHaveLength(before);
  });

  it("projects explicit direction and ports, hides unrelated identities and never creates provider rules", async () => {
    const laptop = await enroll(admin, "laptop");
    const server = await enroll(admin, "server");
    await enroll(admin, "unrelated");
    const before = h.upstreamRequests.length;
    const applied = await apply([{ src: [laptop], dst: [server], allow: ["tcp:4100", "udp:53"] }]);
    expect(applied.status).toBe(200);
    expect(await applied.json()).toMatchObject({ ruleCount: 0, overlayRuleCount: 2 });
    const outbound = await json(await read(laptop));
    const inbound = await json(await read(server));
    const ports = [{ protocol: "tcp", port: 4100 }, { protocol: "udp", port: 53 }];
    expect(outbound["peers"]).toEqual([{ deviceId: server, wgPublicKey: WG2, installPublicKey: install.publicKey, inbound: [], outbound: ports }]);
    expect(inbound["peers"]).toEqual([{ deviceId: laptop, wgPublicKey: WG, installPublicKey: install.publicKey, inbound: ports, outbound: [] }]);
    expect(h.upstreamRequests).toHaveLength(before);
    expect((await json(await call(`/v1/devices/${laptop}/peers`, admin)))["peers"]).toEqual([]);
  });

  it("reads with a device signature and enforces purpose, freshness, replay and revocation", async () => {
    const owner = await h.addKey(TEAM, ["mesh:join"]);
    const id = await enroll(owner);
    expect((await signed(id, deviceRequestBody(install, id, "peers"))).status).toBe(404);
    expect((await signed(id, deviceRequestBody(install, id, "overlay-policy", { signedAt: Date.now() - 180_000 }))).status).toBe(403);
    const request = deviceRequestBody(install, id, "overlay-policy");
    expect((await signed(id, request)).status).toBe(200);
    expect((await signed(id, request)).status).toBe(409);
    await h.revokeKey(owner);
    expect((await signed(id)).status).toBe(404);
    expect((await read(id)).status).toBe(404);
  });

  it("requires device ownership or admin, current scope, tenant and resource visibility", async () => {
    const owner = await h.addKey(TEAM, ["mesh:join"]);
    const id = await enroll(owner);
    const other = await h.addKey(TEAM, ["mesh:join"]);
    expect((await read(id, other)).status).toBe(404);
    expect((await read(id, await h.addKey("team_bravo", ALL_SCOPES))).status).toBe(404);
    expect((await read(id, await h.addKey(TEAM, ["mesh:read"])) ).status).toBe(403);
    expect((await read(id, await h.addKey(TEAM, ALL_SCOPES, { allowlist: [] }))).status).toBe(404);
    expect((await read(id, owner)).status).toBe(200);
    expect((await read(id)).status).toBe(200);
  });

  it("removes revoked or departed peers and updates identity at the same ACL version", async () => {
    const laptop = await enroll();
    const owner = await h.addKey(TEAM, ["mesh:join"]);
    const server = await enroll(owner, "server");
    expect((await apply([{ src: [laptop], dst: [server], allow: ["tcp:4100"] }])).status).toBe(200);
    const initial = await json(await read(laptop));
    const rotated = await call(`/v1/devices/${server}/rotate-key`, owner, "POST", await rotateBody(install, server, WG3));
    expect(rotated.status).toBe(200);
    const updated = await json(await read(laptop));
    expect(updated["aclVersion"]).toBe(initial["aclVersion"]);
    expect(updated["policyDigest"]).not.toBe(initial["policyDigest"]);
    expect(updated["peers"]).toEqual([expect.objectContaining({ wgPublicKey: WG3 })]);
    await h.revokeKey(owner);
    expect((await json(await read(laptop)))["peers"]).toEqual([]);
  });

  it("removes deleted devices even when an old ACL still names them", async () => {
    const laptop = await enroll();
    const server = await enroll();
    expect((await apply([{ src: [laptop], dst: [server], allow: ["*"] }])).status).toBe(200);
    expect((await call(`/v1/devices/${server}`, admin, "DELETE")).status).toBe(204);
    expect((await json(await read(laptop)))["peers"]).toEqual([]);
    expect((await read(server)).status).toBe(404);
  });

  it("refuses overlay expansion before committing an ACL or changing provider rules", async () => {
    await h.dispose();
    h = await makeHarness({ mesh: { budgets: { overlayRulesPerMesh: 1, overlayRulesPerDevice: 1 } } });
    admin = await h.addKey(TEAM, ALL_SCOPES);
    const created = (await json(await call("/v1/meshes", admin, "POST", {})))["id"];
    if (typeof created !== "string") throw new Error("missing mesh");
    mesh = created;
    const laptop = await enroll();
    const server = await enroll();
    const before = h.upstreamRequests.length;
    const refused = await apply([{ src: [laptop], dst: [server], allow: ["tcp:4100", "udp:53"] }]);
    expect(refused.status).toBe(429);
    expect(await json(refused)).toMatchObject({ _tag: "QuotaExceeded" });
    expect((await json(await call(`/v1/meshes/${mesh}/acl`, admin)))["version"]).toBe(0);
    expect((await json(await read(laptop)))["peers"]).toEqual([]);
    expect(h.upstreamRequests).toHaveLength(before);
  });

  it("hides removed user peers and refuses signed reads when the experiment is off", async () => {
    const laptop = await enroll();
    h.addMember(TEAM, "user_server");
    const token = await h.sessionToken("user_server");
    const enrolled = await h.request(`/v1/meshes/${mesh}/devices`, { ...bearer(token), "x-cmux-team-id": TEAM }, {
      method: "POST", body: await enrollBody(install, mesh, { name: "server", wgPublicKey: WG2 }),
    });
    expect(enrolled.status).toBe(201);
    const server = record((await json(enrolled))["device"])["id"];
    if (typeof server !== "string") throw new Error("missing server");
    expect((await apply([{ src: [laptop], dst: [server], allow: ["tcp:4100"] }])).status).toBe(200);
    expect((await json(await read(laptop)))["peers"]).toHaveLength(1);
    h.failStackFor("user_server");
    expect((await read(laptop)).status).toBe(503);
    h.failStackFor("user_server", false);
    h.removeMember(TEAM, "user_server");
    // TeamMembership checks the directory; the signed read and projection
    // must not inherit the credential middleware's cached positive result.
    expect((await json(await read(laptop)))["peers"]).toEqual([]);
    expect((await signed(server)).status).toBe(404);
    await h.dispose();
    h = await makeHarness({ mesh: { experiment: false } });
    expect((await signed(laptop)).status).toBe(404);
    expect(h.upstreamRequests).toHaveLength(0);
  });
});
