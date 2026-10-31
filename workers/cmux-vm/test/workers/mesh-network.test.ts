/**
 * Mesh networking parity (cx-0op, src/api/mesh-network.ts): mesh and device
 * renames, the addresses of a mesh, the team's tunnel list, the firewall rules
 * a mesh's ACL compiled to and ACL evaluation. The cross-tenant, cross-team
 * and missing-scope cases run for every route from MESH_ENDPOINTS in
 * mesh.test.ts; this file covers behavior and the within-tenant visibility.
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { ABSENT_RULE_ID, ALL_SCOPES, bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";
import { enrollBody, makeInstallKey, type InstallKey } from "../support/mesh-signing.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;

const A = "team_alpha";
const B = "team_bravo";
const KEY_1 = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDE=";
const KEY_2 = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDI=";
const MEMBER_SCOPES = ["mesh:read", "mesh:join", "acl:read"] as const;

let install: InstallKey;
let h: Harness;
beforeEach(async () => {
  h = await makeHarness();
  install = await makeInstallKey();
});
afterEach(async () => {
  await h.dispose();
});

const record = (value: unknown): Record<string, unknown> => (typeof value === "object" && value !== null ? Object.fromEntries(Object.entries(value)) : {});
const json = async (response: Response): Promise<Record<string, unknown>> => record(await response.json());
const items = (body: Record<string, unknown>): Array<Record<string, unknown>> => (Array.isArray(body["items"]) ? body["items"].map(record) : []);
const str = (value: unknown): string => (typeof value === "string" ? value : "");
const call = (path: string, key: string, method = "GET", body?: unknown) => h.request(path, bearer(key), { method, body });

const createMesh = async (key: string) => {
  const response = await call("/v1/meshes", key, "POST", { displayName: "test mesh" });
  expect(response.status).toBe(201);
  return str((await json(response))["id"]);
};

const enroll = async (key: string, meshId: string, wgPublicKey = KEY_1, name = "laptop") => {
  const response = await call(`/v1/meshes/${meshId}/devices`, key, "POST", await enrollBody(install, meshId, { name, wgPublicKey }));
  expect(response.status).toBe(201);
  const device = record((await json(response))["device"]);
  return { deviceId: str(device["id"]), tunnelId: str(device["tunnelId"]) };
};

const attach = async (key: string, meshId: string, vmId: string) => {
  const response = await call(`/v1/meshes/${meshId}/vms/${vmId}`, key, "PUT");
  expect(response.status).toBe(200);
  return json(response);
};

const putAcl = async (key: string, meshId: string, expectedVersion: number, rules: ReadonlyArray<unknown>) => {
  const response = await call(`/v1/meshes/${meshId}/acl`, key, "PUT", { expectedVersion, rules });
  expect(response.status).toBe(200);
};

/** A mesh with one VM and one device of an admin key, and a second principal of the same tenant. */
const fixture = async () => {
  const admin = await h.addKey(A, ALL_SCOPES);
  const meshId = await createMesh(admin);
  const vm = h.addVm(A);
  const member = await attach(admin, meshId, vm.vmId);
  const device = await enroll(admin, meshId);
  return { admin, meshId, vmId: vm.vmId, vmIpv4: member["ipv4"], ...device };
};

describe("rename a mesh (update_vpc)", () => {
  it("renames and clears the name with no provider call, and audits it", async () => {
    const { admin, meshId } = await fixture();
    const before = h.upstreamRequests.length;
    const renamed = await call(`/v1/meshes/${meshId}`, admin, "PATCH", { displayName: "office" });
    expect(renamed.status).toBe(200);
    expect(await json(renamed)).toMatchObject({ id: meshId, displayName: "office" });
    expect(await json(await call(`/v1/meshes/${meshId}`, admin))).toMatchObject({ displayName: "office" });
    expect(items(await json(await call("/v1/meshes", admin)))[0]).toMatchObject({ id: meshId, displayName: "office" });
    const cleared = await call(`/v1/meshes/${meshId}`, admin, "PATCH", { displayName: null });
    expect(await json(cleared)).toMatchObject({ displayName: null });
    expect(h.upstreamRequests).toHaveLength(before);
    expect(h.audit.filter((row) => row.action === "mesh.update").map((row) => [row.cmuxId, row.outcome])).toEqual([
      [meshId, "ok"],
      [meshId, "ok"],
    ]);
  });

  it("requires a team admin for a session and refuses an empty name", async () => {
    const { admin, meshId } = await fixture();
    h.addMember(A, "user_amy");
    const headers = { ...bearer(await h.sessionToken("user_amy")), "x-cmux-team-id": A };
    expect((await h.request(`/v1/meshes/${meshId}`, headers, { method: "PATCH", body: { displayName: "mine" } })).status).toBe(403);
    expect((await call(`/v1/meshes/${meshId}`, admin, "PATCH", { displayName: "" })).status).toBe(400);
    expect(await json(await call(`/v1/meshes/${meshId}`, admin))).toMatchObject({ displayName: "test mesh" });
  });
});

describe("addresses of a mesh (list_vpc_ips)", () => {
  it("lists each VM's and device's mesh address in one provider read, with no provider id", async () => {
    const { admin, meshId, vmId, vmIpv4, deviceId } = await fixture();
    const before = h.upstreamRequests.length;
    const response = await call(`/v1/meshes/${meshId}/addresses`, admin);
    expect(response.status).toBe(200);
    const body = await json(response);
    expect(body["meshId"]).toBe(meshId);
    const deviceIpv4 = [...h.mesh.tunnels.values()][0]?.ipv4;
    expect(items(body)).toEqual([
      { kind: "vm", id: vmId, ipv4: vmIpv4 },
      { kind: "device", id: deviceId, ipv4: deviceIpv4 },
    ]);
    expect(h.upstreamRequests.slice(before).map((entry) => `${entry.method} ${entry.path.replace(/vpc-[^/]+/u, "VPC")}`)).toEqual(["GET /v5/vpcs/VPC/tunnels"]);
    expect(JSON.stringify(body)).not.toMatch(/vpc-|tun-/u);
  });

  it("shows another principal of the tenant the VMs but only its own devices", async () => {
    const { meshId, vmId } = await fixture();
    const member = await h.addKey(A, MEMBER_SCOPES);
    const own = await enroll(member, meshId, KEY_2, "bravo");
    const body = await json(await call(`/v1/meshes/${meshId}/addresses`, member));
    expect(items(body).map((item) => item["id"])).toEqual([vmId, own.deviceId]);
  });
});

describe("tunnels (list_tunnels, update_tunnel)", () => {
  it("lists the team's tunnels without keys, only its own to a non-admin, and none to another tenant", async () => {
    const { admin, meshId, deviceId, tunnelId } = await fixture();
    const member = await h.addKey(A, MEMBER_SCOPES);
    const own = await enroll(member, meshId, KEY_2, "bravo");
    const all = items(await json(await call("/v1/tunnels", admin)));
    expect(all.map((item) => item["id"]).sort()).toEqual([tunnelId, own.tunnelId].sort());
    expect(all.find((item) => item["id"] === tunnelId)).toEqual({ id: tunnelId, deviceId, meshId, name: "laptop", createdAt: expect.any(String) });
    expect(items(await json(await call("/v1/tunnels", member))).map((item) => item["id"])).toEqual([own.tunnelId]);
    const keyB = await h.addKey(B, ALL_SCOPES);
    expect(items(await json(await call("/v1/tunnels", keyB)))).toEqual([]);
  });

  it("renames a device with no provider call; its tunnel config does not change", async () => {
    const { admin, deviceId, tunnelId } = await fixture();
    const config = await json(await call(`/v1/tunnels/${tunnelId}`, admin));
    const before = h.upstreamRequests.length;
    const renamed = await call(`/v1/devices/${deviceId}`, admin, "PATCH", { name: "work laptop" });
    expect(renamed.status).toBe(200);
    expect(await json(renamed)).toMatchObject({ id: deviceId, name: "work laptop", tunnelId });
    expect(h.upstreamRequests).toHaveLength(before);
    expect(await json(await call(`/v1/devices/${deviceId}`, admin))).toMatchObject({ name: "work laptop" });
    expect(items(await json(await call("/v1/tunnels", admin)))[0]).toMatchObject({ name: "work laptop" });
    expect(await json(await call(`/v1/tunnels/${tunnelId}`, admin))).toEqual(config);
    expect(h.audit.filter((row) => row.action === "device.update").map((row) => [row.cmuxId, row.outcome])).toEqual([[deviceId, "ok"]]);
  });

  it("another principal of the same tenant cannot rename a device it did not enroll", async () => {
    const { admin, deviceId } = await fixture();
    const member = await h.addKey(A, MEMBER_SCOPES);
    const response = await call(`/v1/devices/${deviceId}`, member, "PATCH", { name: "taken" });
    expect(response.status).toBe(404);
    expect(await json(await call(`/v1/devices/${deviceId}`, admin))).toMatchObject({ name: "laptop" });
  });
});

describe("firewall rules (list_firewall_rules, get_firewall_rule)", () => {
  it("lists the rules the ACL compiled to, by stable cmux ids, and reads one", async () => {
    const { admin, meshId, vmId, deviceId } = await fixture();
    await putAcl(admin, meshId, 0, [{ src: [deviceId], dst: [vmId], allow: ["tcp:22", "icmp"] }]);
    const before = h.upstreamRequests.length;
    const list = await json(await call(`/v1/meshes/${meshId}/acl/rules`, admin));
    expect(h.upstreamRequests).toHaveLength(before);
    expect(list).toMatchObject({ meshId, aclVersion: 1 });
    const rules = items(list);
    expect(rules.map((rule) => [rule["protocol"], rule["port"]]).sort()).toEqual([["icmp", null], ["tcp", 22]]);
    for (const rule of rules) {
      expect(rule).toMatchObject({ meshId, deviceId, vmId, source: "tunnel" });
      expect(str(rule["id"])).toMatch(/^fwr_[0-9a-f]{32}$/u);
    }
    expect(JSON.stringify(list)).not.toContain("fwr-");
    const first = rules[0] ?? {};
    const got = await call(`/v1/meshes/${meshId}/acl/rules/${str(first["id"])}`, admin);
    expect(got.status).toBe(200);
    expect(await json(got)).toEqual(first);
    // The same rule keeps its id across reads.
    expect(items(await json(await call(`/v1/meshes/${meshId}/acl/rules`, admin)))).toEqual(rules);
  });

  it("answers 404 for an unknown or malformed rule id, and for another tenant's rule under its own mesh", async () => {
    const { admin, meshId, vmId, deviceId } = await fixture();
    await putAcl(admin, meshId, 0, [{ src: [deviceId], dst: [vmId], allow: ["tcp:22"] }]);
    const ruleId = str(items(await json(await call(`/v1/meshes/${meshId}/acl/rules`, admin)))[0]?.["id"]);
    expect((await call(`/v1/meshes/${meshId}/acl/rules/${ABSENT_RULE_ID}`, admin)).status).toBe(404);
    expect((await call(`/v1/meshes/${meshId}/acl/rules/not-a-rule`, admin)).status).toBe(404);
    const keyB = await h.addKey(B, ALL_SCOPES);
    const meshB = await createMesh(keyB);
    expect((await call(`/v1/meshes/${meshB}/acl/rules/${ruleId}`, keyB)).status).toBe(404);
    expect(items(await json(await call(`/v1/meshes/${meshB}/acl/rules`, keyB)))).toEqual([]);
  });
});

describe("evaluate the ACL (evaluate_firewall)", () => {
  const evaluate = (key: string, meshId: string, body: unknown) => call(`/v1/meshes/${meshId}/acl/evaluate`, key, "POST", body);

  it("answers what an apply would allow, naming the first allowing rule, and calls nothing upstream", async () => {
    const { admin, meshId, vmId, deviceId } = await fixture();
    const second = await enroll(admin, meshId, KEY_2, "desktop");
    await putAcl(admin, meshId, 0, [
      { src: [deviceId], dst: [vmId], allow: ["tcp:22"] },
      { src: ["device:*"], dst: ["vm:*"], allow: ["icmp"] },
      { src: [deviceId], dst: [second.deviceId], allow: ["udp:*"] },
    ]);
    const before = h.upstreamRequests.length;
    const cases: Array<[unknown, Record<string, unknown>]> = [
      [{ src: deviceId, dst: vmId, protocol: "tcp", port: 22 }, { allowed: true, path: "firewall", ruleIndex: 0 }],
      [{ src: deviceId, dst: vmId, protocol: "tcp", port: 23 }, { allowed: false, path: "firewall", ruleIndex: null }],
      [{ src: second.deviceId, dst: vmId, protocol: "icmp" }, { allowed: true, path: "firewall", ruleIndex: 1 }],
      [{ src: deviceId, dst: second.deviceId, protocol: "udp", port: 5353 }, { allowed: true, path: "overlay", ruleIndex: 2 }],
      // Directed: the reverse direction is not granted.
      [{ src: second.deviceId, dst: deviceId, protocol: "udp", port: 5353 }, { allowed: false, path: "overlay", ruleIndex: null }],
    ];
    for (const [body, expected] of cases) {
      const response = await evaluate(admin, meshId, body);
      expect(response.status, JSON.stringify(body)).toBe(200);
      expect(await json(response), JSON.stringify(body)).toEqual({ meshId, aclVersion: 1, ...expected });
    }
    expect(h.upstreamRequests).toHaveLength(before);
  });

  it("refuses ids outside the mesh (another tenant's VM included) and a port that does not fit the protocol", async () => {
    const { admin, meshId, vmId, deviceId } = await fixture();
    const foreign = h.addVm(B);
    const unattached = h.addVm(A);
    const refused = [
      { src: vmId, dst: vmId, protocol: "icmp" },
      { src: deviceId, dst: foreign.vmId, protocol: "icmp" },
      { src: deviceId, dst: unattached.vmId, protocol: "icmp" },
      { src: "dev_00000000000000000000000000", dst: vmId, protocol: "icmp" },
      { src: deviceId, dst: vmId, protocol: "tcp" },
      { src: deviceId, dst: vmId, protocol: "icmp", port: 7 },
    ];
    for (const body of refused) expect((await evaluate(admin, meshId, body)).status, JSON.stringify(body)).toBe(400);
  });

  it("is default deny before any ACL", async () => {
    const { admin, meshId, vmId, deviceId } = await fixture();
    expect(await json(await evaluate(admin, meshId, { src: deviceId, dst: vmId, protocol: "icmp" }))).toEqual({
      meshId,
      aclVersion: 0,
      allowed: false,
      path: "firewall",
      ruleIndex: null,
    });
  });
});
