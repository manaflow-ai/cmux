/**
 * Mesh experiment (cx-0op, workers/cmux-vm/mesh/M1-PLAN.md M1a): the flag,
 * meshes, device enrollment with the device's own key, VM membership, the ACL
 * and its provider rules, the peer map, budgets, audit rows, and tenant
 * isolation on every mesh endpoint.
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { ALL_SCOPES, allScopesExcept, bearer, MESH_ENDPOINTS } from "../support/endpoints.ts";
import { makeHarness, type HarnessOptions } from "../support/harness.ts";
import { enrollBody, makeInstallKey, rotateBody, type InstallKey } from "../support/mesh-signing.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;

const A = "team_alpha";
const B = "team_bravo";
/** A Curve25519 public key, base64 (any 32 bytes do for the fake provider). */
const KEY_1 = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDE=";
const KEY_2 = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDI=";
const KEY_3 = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDM=";

/** One install key per test file run; each enroll signs with it (M2: the device proves it holds its install key). */
let install: InstallKey;
const signedEnroll = async (meshId: string, name: string, wgPublicKey: string) => enrollBody(install ?? (install = await makeInstallKey()), meshId, { name, wgPublicKey });

let h: Harness;
const setup = async (options: HarnessOptions = {}) => {
  h = await makeHarness(options);
};
beforeEach(async () => {
  await setup();
});
afterEach(async () => {
  await h.dispose();
});

const json = async (response: Response): Promise<Record<string, unknown>> => {
  const body: unknown = await response.json();
  return typeof body === "object" && body !== null ? Object.fromEntries(Object.entries(body)) : {};
};
const str = (value: unknown): string => (typeof value === "string" ? value : "");
const call = (path: string, key: string, method = "GET", body?: unknown) => h.request(path, bearer(key), { method, body });

const createMesh = async (key: string) => {
  const response = await call("/v1/meshes", key, "POST", { displayName: "test mesh" });
  expect(response.status).toBe(201);
  return str((await json(response))["id"]);
};

const enroll = async (key: string, meshId: string, wgPublicKey = KEY_1, name = "laptop") => {
  const response = await call(`/v1/meshes/${meshId}/devices`, key, "POST", await signedEnroll(meshId, name, wgPublicKey));
  expect(response.status).toBe(201);
  const body = await json(response);
  const device = Object.fromEntries(Object.entries(typeof body["device"] === "object" && body["device"] !== null ? body["device"] : {}));
  const tunnel = Object.fromEntries(Object.entries(typeof body["tunnel"] === "object" && body["tunnel"] !== null ? body["tunnel"] : {}));
  return { deviceId: str(device["id"]), tunnelId: str(device["tunnelId"]), tunnel };
};

const attach = async (key: string, meshId: string, vmId: string) => {
  const response = await call(`/v1/meshes/${meshId}/vms/${vmId}`, key, "PUT");
  expect(response.status).toBe(200);
  return json(response);
};

const putAcl = (key: string, meshId: string, expectedVersion: number, rules: ReadonlyArray<unknown>) =>
  call(`/v1/meshes/${meshId}/acl`, key, "PUT", { expectedVersion, rules });

describe("the experiment flag", () => {
  it("answers 404 on every mesh route when the experiment is off, and calls nothing upstream", async () => {
    await h.dispose();
    await setup({ mesh: { experiment: false } });
    const key = await h.addKey(A, ALL_SCOPES);
    for (const endpoint of MESH_ENDPOINTS) {
      const path = endpoint.template
        .replace("{meshId}", "mesh_00000000000000000000000000")
        .replace("{deviceId}", "dev_00000000000000000000000000")
        .replace("{tunnelId}", "tun_00000000000000000000000000")
        .replace("{vmId}", "vm_00000000000000000000000000");
      const body =
        endpoint.name === "enrollDevice"
          ? await signedEnroll("mesh_00000000000000000000000000", "laptop", KEY_1)
          : endpoint.name === "rotateDeviceKey"
            ? await rotateBody(install ?? (install = await makeInstallKey()), "dev_00000000000000000000000000", KEY_3)
          : endpoint.name === "putMeshAcl"
            ? { expectedVersion: 0, rules: [] }
            : endpoint.method === "POST"
              ? {}
              : undefined;
      const response = await call(path, key, endpoint.method, body);
      expect(response.status, endpoint.name).toBe(404);
      expect(await json(response)).toEqual({ _tag: "NotFound", message: "Not found" });
    }
    expect(h.upstreamRequests).toHaveLength(0);
  });

  it("answers 404 to a tenant that is not on the allowlist, before the scope check", async () => {
    await h.dispose();
    await setup({ mesh: { tenants: [B] } });
    const key = await h.addKey(A, ["vm:read"]);
    const response = await call("/v1/meshes", key, "POST", {});
    expect(response.status).toBe(404);
    expect(h.upstreamRequests).toHaveLength(0);
  });
});

describe("meshes", () => {
  it("creates one network per mesh with a unique /20, and lists and reads it", async () => {
    const key = await h.addKey(A, ALL_SCOPES);
    const meshId = await createMesh(key);
    expect(meshId).toMatch(/^mesh_[0-9a-z]{26}$/u);
    const [vpcCreate] = h.upstream.callsTo("POST", /^\/v5\/vpcs$/u);
    const cidr = Object.fromEntries(Object.entries(typeof vpcCreate?.json === "object" && vpcCreate.json !== null ? vpcCreate.json : {}))["cidr"];
    expect(cidr).toMatch(/^10\.(1[2-9][0-9]|2[0-5][0-9])\.[0-9]{1,3}\.0\/20$/u);
    const got = await json(await call(`/v1/meshes/${meshId}`, key));
    expect(got).toMatchObject({ id: meshId, displayName: "test mesh", ipv4Cidr: cidr });
    const list = await json(await call("/v1/meshes", key));
    expect(list["items"]).toHaveLength(1);
    // The provider id never appears in a response.
    expect(JSON.stringify(got)).not.toContain("vpc-");
  });

  it("refuses a second mesh with the mesh.perTenant budget and creates nothing upstream", async () => {
    const key = await h.addKey(A, ALL_SCOPES);
    await createMesh(key);
    const before = h.upstreamRequests.length;
    const second = await call("/v1/meshes", key, "POST", {});
    expect(second.status).toBe(429);
    expect(await json(second)).toMatchObject({ _tag: "QuotaExceeded", budget: "mesh.perTenant" });
    expect(h.upstreamRequests).toHaveLength(before);
  });

  it("requires a team admin for a session", async () => {
    h.addMember(A, "user_amy");
    const token = await h.sessionToken("user_amy");
    const headers = { ...bearer(token), "x-cmux-team-id": A };
    const refused = await h.request("/v1/meshes", headers, { method: "POST", body: {} });
    expect(refused.status).toBe(403);
    h.addAdmin(A, "user_amy");
    const created = await h.request("/v1/meshes", headers, { method: "POST", body: {} });
    expect(created.status).toBe(201);
  });

  it("refuses to delete a mesh with devices, then deletes it once empty", async () => {
    const key = await h.addKey(A, ALL_SCOPES);
    const meshId = await createMesh(key);
    const { deviceId } = await enroll(key, meshId);
    expect((await call(`/v1/meshes/${meshId}`, key, "DELETE")).status).toBe(409);
    expect((await call(`/v1/devices/${deviceId}`, key, "DELETE")).status).toBe(204);
    expect((await call(`/v1/meshes/${meshId}`, key, "DELETE")).status).toBe(204);
    expect((await call(`/v1/meshes/${meshId}`, key)).status).toBe(404);
    expect(h.mesh.vpcs.size).toBe(0);
  });
});

describe("device enrollment", () => {
  it("creates the tunnel with the device's own key, routes limited to the mesh, and returns no private key", async () => {
    const key = await h.addKey(A, ALL_SCOPES);
    const meshId = await createMesh(key);
    const { deviceId, tunnelId, tunnel } = await enroll(key, meshId);
    expect(deviceId).toMatch(/^dev_/u);
    expect(tunnelId).toMatch(/^tun_/u);
    const [create] = h.upstream.callsTo("POST", /^\/v5\/tunnels$/u);
    const body = Object.fromEntries(Object.entries(typeof create?.json === "object" && create.json !== null ? create.json : {}));
    expect(body["clientPublicKey"]).toBe(KEY_1);
    const mesh = await json(await call(`/v1/meshes/${meshId}`, key));
    // The provider refuses a tunnel whose routes do not cover the network's IPv6 range too (measured live in M1c).
    expect(body["routes"]).toEqual([mesh["ipv4Cidr"], "fd00:1::/64"]);
    expect(tunnel).toMatchObject({
      id: tunnelId,
      meshId,
      deviceId,
      endpointHost: "203.0.113.30",
      endpointPort: 51820,
      mtu: 1280,
      persistentKeepaliveSeconds: 25,
      allowedIps: [mesh["ipv4Cidr"], "fd00:1::/64"],
    });
    const text = JSON.stringify(tunnel);
    expect(text).not.toMatch(/private/iu);
    expect(text).not.toContain("tun-");
    const read = await json(await call(`/v1/tunnels/${tunnelId}`, key));
    expect(read).toMatchObject({ id: tunnelId, mtu: 1280, persistentKeepaliveSeconds: 25 });
  });

  it("fails closed when the provider mints a private key: the tunnel is deleted and nothing is recorded", async () => {
    const key = await h.addKey(A, ALL_SCOPES);
    const meshId = await createMesh(key);
    h.mesh.mintKeys(true);
    const response = await call(`/v1/meshes/${meshId}/devices`, key, "POST", await signedEnroll(meshId, "laptop", KEY_1));
    expect(response.status).toBe(503);
    expect(h.mesh.tunnels.size).toBe(0);
    const list = await json(await call(`/v1/meshes/${meshId}/devices`, key));
    expect(list["items"]).toEqual([]);
  });

  it("refuses a malformed key and a key already in the mesh", async () => {
    const key = await h.addKey(A, ALL_SCOPES);
    const meshId = await createMesh(key);
    expect((await call(`/v1/meshes/${meshId}/devices`, key, "POST", await signedEnroll(meshId, "x", "not-a-key"))).status).toBe(400);
    await enroll(key, meshId);
    expect((await call(`/v1/meshes/${meshId}/devices`, key, "POST", await signedEnroll(meshId, "y", KEY_1))).status).toBe(409);
  });

  it("refuses a device past the device.perMesh budget before any provider call", async () => {
    await h.dispose();
    await setup({ mesh: { budgets: { devicesPerMesh: 1 } } });
    const key = await h.addKey(A, ALL_SCOPES);
    const meshId = await createMesh(key);
    await enroll(key, meshId);
    const before = h.upstreamRequests.length;
    const refused = await call(`/v1/meshes/${meshId}/devices`, key, "POST", await signedEnroll(meshId, "second", KEY_2));
    expect(refused.status).toBe(429);
    expect(await json(refused)).toMatchObject({ _tag: "QuotaExceeded", budget: "device.perMesh" });
    expect(h.upstreamRequests).toHaveLength(before);
  });

  it("deleting a device deletes exactly its tunnel", async () => {
    const key = await h.addKey(A, ALL_SCOPES);
    const meshId = await createMesh(key);
    const one = await enroll(key, meshId, KEY_1, "one");
    await enroll(key, meshId, KEY_2, "two");
    expect(h.mesh.tunnels.size).toBe(2);
    expect((await call(`/v1/devices/${one.deviceId}`, key, "DELETE")).status).toBe(204);
    expect(h.mesh.tunnels.size).toBe(1);
    expect((await call(`/v1/devices/${one.deviceId}`, key)).status).toBe(404);
    expect((await call(`/v1/tunnels/${one.tunnelId}`, key)).status).toBe(404);
  });
});

describe("ACL", () => {
  const meshWithPeers = async () => {
    const key = await h.addKey(A, ALL_SCOPES);
    const meshId = await createMesh(key);
    const vm = h.addVm(A);
    await attach(key, meshId, vm.vmId);
    const device = await enroll(key, meshId);
    return { key, meshId, vm, device };
  };

  it("compiles one provider rule per device, VM and port, from the device's tunnel to the VM", async () => {
    const { key, meshId, vm, device } = await meshWithPeers();
    const applied = await putAcl(key, meshId, 0, [{ src: [device.deviceId], dst: [vm.vmId], allow: ["tcp:8080", "icmp"] }]);
    expect(applied.status).toBe(200);
    expect(await json(applied)).toMatchObject({ version: 1, ruleCount: 2, rulesCreated: 2, rulesDeleted: 0 });
    const rules = [...h.mesh.rules.values()];
    expect(rules).toHaveLength(2);
    const tunnelUpstream = [...h.mesh.tunnels.keys()][0];
    for (const rule of rules) {
      expect(rule.source).toEqual({ tunnelId: tunnelUpstream });
      expect(rule.destination["vmId"]).toBe(vm.upstreamId);
      expect(rule.description).toBe(`cmux:mesh:${meshId}`);
    }
    expect(rules.map((rule) => rule.destination).sort((a, b) => String(a["protocol"]).localeCompare(String(b["protocol"])))).toEqual([
      { vmId: vm.upstreamId, protocol: "icmp" },
      { vmId: vm.upstreamId, protocol: "tcp", port: 8080 },
    ]);
  });

  it("creates new rules before deleting old ones, and blocks then re-allows a port", async () => {
    const { key, meshId, vm, device } = await meshWithPeers();
    await putAcl(key, meshId, 0, [{ src: ["device:*"], dst: ["vm:*"], allow: ["tcp:8080", "icmp"] }]);
    const mark = h.upstreamRequests.length;
    const blocked = await putAcl(key, meshId, 1, [{ src: [device.deviceId], dst: [vm.vmId], allow: ["icmp", "tcp:9090"] }]);
    expect(await json(blocked)).toMatchObject({ version: 2, rulesCreated: 1, rulesDeleted: 1 });
    const order = h.upstreamRequests.slice(mark).map((request) => `${request.method} ${request.path.split("/").slice(0, 4).join("/")}`);
    expect(order).toEqual(["POST /v5/firewall/rules", "DELETE /v5/firewall/rules"]);
    expect([...h.mesh.rules.values()].map((rule) => rule.destination["port"] ?? null).sort()).toEqual([9090, null]);
    const allowed = await putAcl(key, meshId, 2, [{ src: [device.deviceId], dst: [vm.vmId], allow: ["icmp", "tcp:8080"] }]);
    expect(await json(allowed)).toMatchObject({ version: 3, rulesCreated: 1, rulesDeleted: 1 });
  });

  it("refuses a stale expectedVersion with 409 and changes nothing", async () => {
    const { key, meshId } = await meshWithPeers();
    await putAcl(key, meshId, 0, [{ src: ["device:*"], dst: ["vm:*"], allow: ["icmp"] }]);
    const before = h.upstreamRequests.length;
    const stale = await putAcl(key, meshId, 0, [{ src: ["device:*"], dst: ["vm:*"], allow: ["*"] }]);
    expect(stale.status).toBe(409);
    expect(h.upstreamRequests).toHaveLength(before);
  });

  it("refuses names that are not members of this mesh, including another tenant's VM", async () => {
    const { key, meshId, device } = await meshWithPeers();
    const foreign = h.addVm(B);
    const response = await putAcl(key, meshId, 0, [{ src: [device.deviceId], dst: [foreign.vmId], allow: ["tcp:22"] }]);
    expect(response.status).toBe(400);
    expect(h.mesh.rules.size).toBe(0);
  });

  it("refuses more than the per-resource rule budget before any provider call", async () => {
    await h.dispose();
    await setup({ mesh: { budgets: { rulesPerResource: 2 } } });
    const { key, meshId } = await meshWithPeers();
    const before = h.upstreamRequests.length;
    const response = await putAcl(key, meshId, 0, [{ src: ["device:*"], dst: ["vm:*"], allow: ["tcp:1", "tcp:2", "tcp:3"] }]);
    expect(response.status).toBe(429);
    expect(await json(response)).toMatchObject({ _tag: "QuotaExceeded", budget: "firewallRule.perResource" });
    expect(h.upstreamRequests).toHaveLength(before);
  });

  it("limits applies per mesh per minute", async () => {
    await h.dispose();
    await setup({ mesh: { budgets: { aclAppliesPerMinute: 2 } } });
    const { key, meshId } = await meshWithPeers();
    expect((await putAcl(key, meshId, 0, [])).status).toBe(200);
    expect((await putAcl(key, meshId, 1, [])).status).toBe(200);
    const third = await putAcl(key, meshId, 2, []);
    expect(third.status).toBe(429);
    expect(await json(third)).toMatchObject({ budget: "aclApply.perMeshPerMinute", retryAfterSeconds: expect.any(Number) });
  });

  it("maps the provider's account rule limit to firewallRule.account", async () => {
    const { key, meshId } = await meshWithPeers();
    h.mesh.failRuleCreates(409);
    const response = await putAcl(key, meshId, 0, [{ src: ["device:*"], dst: ["vm:*"], allow: ["icmp"] }]);
    expect(response.status).toBe(429);
    expect(await json(response)).toMatchObject({ budget: "firewallRule.account" });
  });

  it("applies the current ACL to a device that enrolls later", async () => {
    const { key, meshId } = await meshWithPeers();
    await putAcl(key, meshId, 0, [{ src: ["device:*"], dst: ["vm:*"], allow: ["tcp:22"] }]);
    expect(h.mesh.rules.size).toBe(1);
    await enroll(key, meshId, KEY_2, "second");
    expect(h.mesh.rules.size).toBe(2);
  });

  it("the peer map lists only what the ACL allows this device", async () => {
    const { key, meshId, vm, device } = await meshWithPeers();
    const other = await enroll(key, meshId, KEY_2, "other");
    const empty = await json(await call(`/v1/devices/${device.deviceId}/peers`, key));
    expect(empty).toMatchObject({ deviceId: device.deviceId, meshId, aclVersion: 0, peers: [] });
    await putAcl(key, meshId, 0, [{ src: [device.deviceId], dst: [vm.vmId], allow: ["tcp:8080", "icmp"] }]);
    const peers = await json(await call(`/v1/devices/${device.deviceId}/peers`, key));
    expect(peers).toMatchObject({ aclVersion: 1, peers: [{ kind: "vm", id: vm.vmId, address: expect.stringMatching(/^10\./u) }] });
    const allowList = JSON.stringify(peers["peers"]);
    expect(allowList).toContain('"protocol":"icmp"');
    expect(allowList).toContain('"port":8080');
    const none = await json(await call(`/v1/devices/${other.deviceId}/peers`, key));
    expect(none["peers"]).toEqual([]);
  });

  it("detaching a VM deletes its rules first", async () => {
    const { key, meshId, vm } = await meshWithPeers();
    await putAcl(key, meshId, 0, [{ src: ["device:*"], dst: ["vm:*"], allow: ["icmp"] }]);
    expect(h.mesh.rules.size).toBe(1);
    expect((await call(`/v1/meshes/${meshId}/vms/${vm.vmId}`, key, "DELETE")).status).toBe(204);
    expect(h.mesh.rules.size).toBe(0);
    expect(h.mesh.vmNetworks.has(vm.upstreamId)).toBe(false);
  });
});

describe("audit", () => {
  it("writes one row per mutation with public ids only", async () => {
    const key = await h.addKey(A, ALL_SCOPES);
    const meshId = await createMesh(key);
    const vm = h.addVm(A);
    await attach(key, meshId, vm.vmId);
    const { deviceId } = await enroll(key, meshId);
    await putAcl(key, meshId, 0, [{ src: ["device:*"], dst: ["vm:*"], allow: ["icmp"] }]);
    await call(`/v1/devices/${deviceId}`, key, "DELETE");
    const rows = h.audit.filter((row) => row.tenantId === A);
    expect(rows.map((row) => [row.action, row.outcome])).toEqual([
      ["mesh.create", "ok"],
      ["mesh.vm.attach", "ok"],
      ["device.create", "ok"],
      ["acl.apply", "ok"],
      ["device.delete", "ok"],
    ]);
    expect(rows[0]?.cmuxId).toBe(meshId);
    expect(rows[2]?.cmuxId).toBe(deviceId);
    for (const row of rows) expect(row.cmuxId ?? "").toMatch(/^(mesh|dev|vm)_|^$/u);
  });
});

describe("tenant isolation", () => {
  const fixture = async () => {
    const keyA = await h.addKey(A, ALL_SCOPES);
    const meshId = await createMesh(keyA);
    const vm = h.addVm(A);
    await attach(keyA, meshId, vm.vmId);
    const device = await enroll(keyA, meshId);
    return { meshId, vmId: vm.vmId, deviceId: device.deviceId, tunnelId: device.tunnelId };
  };

  const pathFor = (template: string, ids: { meshId: string; vmId: string; deviceId: string; tunnelId: string }) =>
    template.replace("{meshId}", ids.meshId).replace("{vmId}", ids.vmId).replace("{deviceId}", ids.deviceId).replace("{tunnelId}", ids.tunnelId);

  const bodyFor = async (name: string, ids: { meshId: string; deviceId: string }) =>
    name === "enrollDevice"
      ? await signedEnroll(ids.meshId, "intruder", KEY_2)
      : name === "rotateDeviceKey"
        ? await rotateBody(install ?? (install = await makeInstallKey()), ids.deviceId, KEY_3)
        : name === "putMeshAcl"
          ? { expectedVersion: 0, rules: [] }
          : name === "createEnrollmentCode"
            ? {}
            : undefined;

  describe.each(MESH_ENDPOINTS.filter((endpoint) => endpoint.target !== "tenant"))("$name", (endpoint) => {
    it("answers 404 to another tenant's key with every scope, and calls nothing upstream", async () => {
      const ids = await fixture();
      const keyB = await h.addKey(B, ALL_SCOPES);
      const before = h.upstreamRequests.length;
      const response = await call(pathFor(endpoint.template, ids), keyB, endpoint.method, await bodyFor(endpoint.name, ids));
      expect(response.status).toBe(404);
      expect(h.upstreamRequests).toHaveLength(before);
    });

    it("answers 404 to a signed-in member of another team", async () => {
      const ids = await fixture();
      h.addMember(B, "user_bob");
      h.addAdmin(B, "user_bob");
      const token = await h.sessionToken("user_bob");
      const before = h.upstreamRequests.length;
      const response = await h.request(pathFor(endpoint.template, ids), { ...bearer(token), "x-cmux-team-id": B }, {
        method: endpoint.method,
        body: await bodyFor(endpoint.name, ids),
      });
      expect(response.status).toBe(404);
      expect(h.upstreamRequests).toHaveLength(before);
    });

    it(`refuses a key without ${endpoint.scope} with 403`, async () => {
      const ids = await fixture();
      const key = await h.addKey(A, allScopesExcept(endpoint.scope));
      const before = h.upstreamRequests.length;
      const response = await call(pathFor(endpoint.template, ids), key, endpoint.method, await bodyFor(endpoint.name, ids));
      expect(response.status).toBe(403);
      expect(h.upstreamRequests).toHaveLength(before);
    });
  });

  it("another tenant's mesh list is empty and its create is its own", async () => {
    await fixture();
    const keyB = await h.addKey(B, ALL_SCOPES);
    expect((await json(await call("/v1/meshes", keyB)))["items"]).toEqual([]);
  });

  it("a mesh cannot take another tenant's VM", async () => {
    const keyA = await h.addKey(A, ALL_SCOPES);
    const meshId = await createMesh(keyA);
    const foreign = h.addVm(B);
    const before = h.upstreamRequests.length;
    const response = await call(`/v1/meshes/${meshId}/vms/${foreign.vmId}`, keyA, "PUT");
    expect(response.status).toBe(404);
    expect(h.upstreamRequests).toHaveLength(before);
  });
});

describe("device ownership (M2, cx-0op.4)", () => {
  /** Keys that may join and read but are not tenant admins. */
  const MEMBER_SCOPES = ["mesh:read", "mesh:join", "acl:read"] as const;

  const fixture = async () => {
    const admin = await h.addKey(A, ALL_SCOPES);
    const meshId = await createMesh(admin);
    const vm = h.addVm(A);
    await attach(admin, meshId, vm.vmId);
    await putAcl(admin, meshId, 0, [{ src: ["device:*"], dst: ["vm:*"], allow: ["icmp"] }]);
    const keyA = await h.addKey(A, MEMBER_SCOPES);
    const keyB = await h.addKey(A, MEMBER_SCOPES);
    const device = await enroll(keyA, meshId);
    return { admin, meshId, keyA, keyB, ...device };
  };

  const deviceRoutes = (ids: { deviceId: string; tunnelId: string }) => [
    { method: "GET", path: `/v1/devices/${ids.deviceId}` },
    { method: "GET", path: `/v1/devices/${ids.deviceId}/peers` },
    { method: "GET", path: `/v1/tunnels/${ids.tunnelId}` },
  ];

  it("another principal of the same tenant gets 404 on read, peer map, tunnel config and delete, and nothing reaches upstream", async () => {
    const ids = await fixture();
    const before = h.upstreamRequests.length;
    for (const route of [...deviceRoutes(ids), { method: "DELETE", path: `/v1/devices/${ids.deviceId}` }]) {
      const response = await call(route.path, ids.keyB, route.method);
      expect(response.status, `${route.method} ${route.path}`).toBe(404);
    }
    expect(h.upstreamRequests).toHaveLength(before);
    // The device still exists for its owner.
    expect((await call(`/v1/devices/${ids.deviceId}`, ids.keyA)).status).toBe(200);
  });

  it("another principal's device list leaves out devices it did not enroll", async () => {
    const ids = await fixture();
    const own = await enroll(ids.keyB, ids.meshId, KEY_2, "bravo");
    const listB = await json(await call(`/v1/meshes/${ids.meshId}/devices`, ids.keyB));
    expect((Array.isArray(listB["items"]) ? listB["items"] : []).map((item) => str(Object(item)["id"]))).toEqual([own.deviceId]);
    const listAdmin = await json(await call(`/v1/meshes/${ids.meshId}/devices`, ids.admin));
    expect(listAdmin["items"]).toHaveLength(2);
  });

  it("the enrolling principal and a key with the admin scope can read, fetch peers and config, and delete", async () => {
    const ids = await fixture();
    for (const key of [ids.keyA, ids.admin]) {
      for (const route of deviceRoutes(ids)) {
        expect((await call(route.path, key, route.method)).status, `${route.method} ${route.path}`).toBe(200);
      }
    }
    expect((await call(`/v1/devices/${ids.deviceId}`, ids.keyA, "DELETE")).status).toBe(204);
    const second = await enroll(ids.keyA, ids.meshId, KEY_2, "second");
    expect((await call(`/v1/devices/${second.deviceId}`, ids.admin, "DELETE")).status).toBe(204);
  });

  it("sessions: the owner and a team admin act on the device, another member gets 404", async () => {
    const admin = await h.addKey(A, ALL_SCOPES);
    const meshId = await createMesh(admin);
    h.addMember(A, "user_amy");
    h.addMember(A, "user_bob");
    h.addMember(A, "user_ada");
    h.addAdmin(A, "user_ada");
    const session = async (user: string) => ({ ...bearer(await h.sessionToken(user)), "x-cmux-team-id": A });
    const amy = await session("user_amy");
    const enrolled = await h.request(`/v1/meshes/${meshId}/devices`, amy, { method: "POST", body: await signedEnroll(meshId, "amy-laptop", KEY_1) });
    expect(enrolled.status).toBe(201);
    const deviceId = str(Object((await json(enrolled))["device"])["id"]);
    expect((await h.request(`/v1/devices/${deviceId}`, amy)).status).toBe(200);
    expect((await h.request(`/v1/devices/${deviceId}`, await session("user_bob"))).status).toBe(404);
    expect((await h.request(`/v1/devices/${deviceId}/peers`, await session("user_bob"))).status).toBe(404);
    expect((await h.request(`/v1/devices/${deviceId}`, await session("user_ada"))).status).toBe(200);
    expect((await h.request(`/v1/devices/${deviceId}`, await session("user_bob"), { method: "DELETE" })).status).toBe(404);
    expect((await h.request(`/v1/devices/${deviceId}`, await session("user_ada"), { method: "DELETE" })).status).toBe(204);
  });

  it("a key with every scope except admin is not an admin for another principal's device", async () => {
    const ids = await fixture();
    const wide = await h.addKey(A, allScopesExcept("admin"));
    for (const route of [...deviceRoutes(ids), { method: "DELETE", path: `/v1/devices/${ids.deviceId}` }]) {
      expect((await call(route.path, wide, route.method)).status, `${route.method} ${route.path}`).toBe(404);
    }
  });
});
