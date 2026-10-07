/**
 * Tenant isolation and scopes for every endpoint. For each endpoint on one VM:
 * another tenant gets 404 (never 403) and nothing reaches upstream, and a key
 * without the endpoint's scope gets 403. The table must cover openapi.json.
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import openapiText from "../../openapi.json?raw";
import { ALL_SCOPES, allScopesExcept, bearer, MESH_ENDPOINTS, SNAPSHOT_ENDPOINTS, TENANT_ENDPOINTS, VM_ENDPOINTS, type VmEndpointCase } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;

const TENANT_A = "team_alpha";
const TENANT_B = "team_bravo";

let h: Harness;
beforeEach(async () => {
  h = await makeHarness();
});
afterEach(async () => {
  await h.dispose();
});

const call = (endpoint: VmEndpointCase, vmId: string, headers: Record<string, string>) =>
  endpoint.bytes === undefined
    ? h.request(endpoint.path(vmId), headers, { method: endpoint.method, body: endpoint.json })
    : h.send(endpoint.path(vmId), headers, endpoint.method, endpoint.bytes);

describe("the endpoint table", () => {
  it("covers every operation in openapi.json", () => {
    const spec: unknown = JSON.parse(openapiText);
    const paths = typeof spec === "object" && spec !== null && "paths" in spec ? spec.paths : {};
    const published = Object.entries(typeof paths === "object" && paths !== null ? paths : {}).flatMap(([path, item]) =>
      Object.keys(typeof item === "object" && item !== null ? item : {}).map((method) => `${method.toUpperCase()} ${path}`),
    );
    const covered = [
      "GET /healthz",
      // No credential (the one-time code is one); test/workers/mesh-m2.test.ts covers it.
      "POST /v1/meshes/{meshId}/device-enrollments",
      // No credential (the device's install-key signature is one); test/workers/mesh-m3.test.ts covers them.
      "POST /v1/devices/{deviceId}/signed/peers",
      "POST /v1/devices/{deviceId}/signed/tunnel",
      "POST /v1/devices/{deviceId}/signed/rotate-key",
      ...VM_ENDPOINTS.map((endpoint) => `${endpoint.method} ${endpoint.template}`),
      ...TENANT_ENDPOINTS.map((endpoint) => `${endpoint.method} ${endpoint.template}`),
      ...SNAPSHOT_ENDPOINTS.map((endpoint) => `${endpoint.method} ${endpoint.template}`),
      ...MESH_ENDPOINTS.map((endpoint) => `${endpoint.method} ${endpoint.template}`),
    ];
    expect([...published].sort()).toEqual([...covered].sort());
  });
});

describe.each(VM_ENDPOINTS)("$name", (endpoint) => {
  it("answers 404 to another tenant's key, even with every scope, and calls nothing upstream", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const keyB = await h.addKey(TENANT_B, ALL_SCOPES);

    const response = await call(endpoint, vmId, bearer(keyB));

    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ _tag: "NotFound", message: "VM not found" });
    expect(h.upstreamRequests).toHaveLength(0);
  });

  it("answers 404 to a signed-in member of another team", async () => {
    const { vmId } = h.addVm(TENANT_A);
    h.addMember(TENANT_B, "user_bob");
    const token = await h.sessionToken("user_bob");

    const response = await call(endpoint, vmId, { ...bearer(token), "x-cmux-team-id": TENANT_B });

    expect(response.status).toBe(404);
    expect(h.upstreamRequests).toHaveLength(0);
  });

  it("answers 404 when the VM is outside the key's resource allowlist", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const other = h.addVm(TENANT_A);
    const key = await h.addKey(TENANT_A, ALL_SCOPES, { allowlist: [other.vmId] });

    const response = await call(endpoint, vmId, bearer(key));

    expect(response.status).toBe(404);
    expect(h.upstreamRequests).toHaveLength(0);
  });

  it(`refuses a key without ${endpoint.scope} with 403 before looking at the VM`, async () => {
    const { vmId } = h.addVm(TENANT_A);
    const key = await h.addKey(TENANT_A, allScopesExcept(endpoint.scope));

    const own = await call(endpoint, vmId, bearer(key));
    const missing = await call(endpoint, "vm_00000000000000000000000000", bearer(key));

    expect(own.status).toBe(403);
    expect(await own.json()).toEqual({
      _tag: "Forbidden",
      message: `This credential lacks the ${endpoint.scope} scope`,
      missingScope: endpoint.scope,
    });
    expect(missing.status).toBe(403);
    expect(h.upstreamRequests).toHaveLength(0);
  });
});

describe("tenant-wide endpoints", () => {
  it("createVm needs vm:write", async () => {
    const key = await h.addKey(TENANT_A, allScopesExcept("vm:write"));
    const response = await h.request("/v1/vms", bearer(key), { method: "POST", body: {} });
    expect(response.status).toBe(403);
    expect(h.upstreamRequests).toHaveLength(0);
  });

  it("listVms needs vm:read", async () => {
    const key = await h.addKey(TENANT_A, allScopesExcept("vm:read"));
    const response = await h.request("/v1/vms", bearer(key));
    expect(response.status).toBe(403);
  });

  it("createVm answers 404 for another tenant's snapshot and creates nothing", async () => {
    const { snapshotId } = h.addSnapshot(TENANT_A);
    const keyB = await h.addKey(TENANT_B, ["vm:write"]);

    const response = await h.request("/v1/vms", bearer(keyB), { method: "POST", body: { snapshotId } });

    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ _tag: "NotFound", message: "Snapshot not found" });
    expect(h.upstreamRequests).toHaveLength(0);
  });

  it("listVms shows only the caller's own VMs and never reads the upstream list", async () => {
    const a1 = h.addVm(TENANT_A);
    const a2 = h.addVm(TENANT_A);
    const b1 = h.addVm(TENANT_B);
    const keyA = await h.addKey(TENANT_A, ["vm:read"]);
    const keyB = await h.addKey(TENANT_B, ["vm:read"]);

    const listA = await (await h.request("/v1/vms", bearer(keyA))).json();
    const listB = await (await h.request("/v1/vms", bearer(keyB))).json();

    const ids = (list: unknown) =>
      typeof list === "object" && list !== null && "items" in list && Array.isArray(list.items)
        ? list.items.map((item: unknown) => (typeof item === "object" && item !== null && "id" in item ? item.id : null)).sort()
        : null;
    expect(ids(listA)).toEqual([a1.vmId, a2.vmId].sort());
    expect(ids(listB)).toEqual([b1.vmId]);
    expect(h.upstream.callsTo("GET", /^\/v5\/vms$/)).toHaveLength(0);
  });

  it("listVms with an allowlisted key shows only the allowlisted VMs", async () => {
    h.addVm(TENANT_A);
    const allowed = h.addVm(TENANT_A);
    const key = await h.addKey(TENANT_A, ["vm:read"], { allowlist: [allowed.vmId] });

    const body: unknown = await (await h.request("/v1/vms", bearer(key))).json();

    expect(body).toMatchObject({ items: [{ id: allowed.vmId }], nextCursor: null });
  });

  it("createVm and forkVm refuse a key limited to a resource allowlist", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const key = await h.addKey(TENANT_A, ["vm:read", "vm:write"], { allowlist: [vmId] });

    const created = await h.request("/v1/vms", bearer(key), { method: "POST", body: {} });
    const forked = await h.request(`/v1/vms/${vmId}/fork`, bearer(key), { method: "POST", body: {} });

    expect(created.status).toBe(403);
    expect(forked.status).toBe(403);
    expect(h.upstream.callsTo("POST", /^\/v5\/vms/)).toHaveLength(0);
  });
});
