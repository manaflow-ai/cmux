/**
 * The Cloud Chief service principal (cx-b4h.13). One service key, configured
 * as a Worker secret, acts for a team only through an explicit
 * X-Cmux-Team-Id, and only on VMs labelled role=chief: it cannot create any
 * other VM, and the team's other VMs and snapshots are 404 and absent from
 * its lists. Every mutation is audited with the service as the actor.
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { bearer, VM_ENDPOINTS, type VmEndpointCase } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;

const TENANT_A = "team_alpha";
const TENANT_B = "team_bravo";
const CHIEF = { role: "chief" };

let h: Harness;
beforeEach(async () => {
  h = await makeHarness();
});
afterEach(async () => {
  await h.dispose();
});

const asTeam = (secret: string, team: string) => ({ ...bearer(secret), "x-cmux-team-id": team });

interface VmBody {
  readonly id: string;
  readonly labels: Readonly<Record<string, string>>;
}

const createChief = async (secret: string, team: string, extra: Record<string, unknown> = {}) => {
  const response = await h.request("/v1/vms", asTeam(secret, team), { method: "POST", body: { labels: CHIEF, ...extra } });
  expect(response.status).toBe(201);
  return response.json<VmBody>();
};

const call = (endpoint: VmEndpointCase, vmId: string, headers: Record<string, string>) =>
  endpoint.bytes === undefined
    ? h.request(endpoint.path(vmId), headers, { method: endpoint.method, body: endpoint.json })
    : h.send(endpoint.path(vmId), headers, endpoint.method, endpoint.bytes);

describe("authentication", () => {
  it("refuses a service key without X-Cmux-Team-Id", async () => {
    const service = await h.addServiceKey();
    const response = await h.request("/v1/vms", bearer(service));
    expect(response.status).toBe(401);
    expect(h.upstreamRequests).toHaveLength(0);
  });

  it("refuses a malformed team id", async () => {
    const service = await h.addServiceKey();
    expect((await h.request("/v1/vms", asTeam(service, "not a team!"))).status).toBe(401);
  });

  it("refuses a team outside the key's team list with 403", async () => {
    const service = await h.addServiceKey({ teams: [TENANT_A] });
    expect((await h.request("/v1/vms", asTeam(service, TENANT_A))).status).toBe(200);
    expect((await h.request("/v1/vms", asTeam(service, TENANT_B))).status).toBe(403);
  });

  it("is not a tenant API key: without the header no tenant's VM is reachable", async () => {
    const service = await h.addServiceKey();
    const { vmId } = h.addVm(TENANT_A, "running", CHIEF);
    expect((await h.request(`/v1/vms/${vmId}`, bearer(service))).status).toBe(401);
  });
});

describe("create", () => {
  it("creates a role=chief VM in the named team, recorded and audited as the service", async () => {
    const service = await h.addServiceKey();
    const vm = await createChief(service, TENANT_A);

    expect(vm.labels).toEqual(CHIEF);
    const row = h.resources.find((resource) => resource.cmuxId === vm.id);
    expect(row).toMatchObject({ tenantId: TENANT_A, kind: "vm", createdBy: "service:cloud-chief" });
    expect(h.audit).toContainEqual(
      expect.objectContaining({ tenantId: TENANT_A, actor: "service:cloud-chief", action: "vm.create", cmuxId: vm.id, outcome: "ok" }),
    );
  });

  it("cannot create a VM without the role=chief label, or with another role", async () => {
    const service = await h.addServiceKey();
    for (const body of [{}, { labels: { role: "dev" } }, { labels: { team: "x" } }]) {
      const response = await h.request("/v1/vms", asTeam(service, TENANT_A), { method: "POST", body });
      expect(response.status).toBe(403);
    }
    expect(h.resources).toHaveLength(0);
    expect(h.upstreamRequests).toHaveLength(0);
  });

  it("cannot boot a VM from the team's snapshots", async () => {
    const service = await h.addServiceKey();
    const { snapshotId } = h.addSnapshot(TENANT_A);
    const response = await h.request("/v1/vms", asTeam(service, TENANT_A), {
      method: "POST",
      body: { labels: CHIEF, snapshotId },
    });
    expect(response.status).toBe(404);
  });

  it("keeps its Idempotency-Keys apart from the team's: the same key never replays a member's VM", async () => {
    const service = await h.addServiceKey();
    const member = await h.addKey(TENANT_A, ["vm:read", "vm:write"]);
    const key = { "idempotency-key": "same-key-0001" };
    const first = await h.request("/v1/vms", { ...bearer(member), ...key }, { method: "POST", body: { labels: CHIEF } });
    expect(first.status).toBe(201);
    const memberVm = await first.json<VmBody>();

    const second = await h.request("/v1/vms", { ...asTeam(service, TENANT_A), ...key }, { method: "POST", body: { labels: CHIEF } });
    expect(second.status).toBe(201);
    expect((await second.json<VmBody>()).id).not.toBe(memberVm.id);
  });
});

describe("other VMs of the team", () => {
  it.each(VM_ENDPOINTS.map((endpoint) => [endpoint.name, endpoint] as const))(
    "%s on a VM without role=chief is refused and calls nothing upstream",
    async (_name, endpoint) => {
      const service = await h.addServiceKey();
      const { vmId } = h.addVm(TENANT_A, "running", { role: "dev" });
      const response = await call(endpoint, vmId, asTeam(service, TENANT_A));
      // 404 where the service holds the scope (the VM is not its to see), 403 where it does not.
      expect(response.status).toBe(endpoint.scope === "vm:read" || endpoint.scope === "vm:write" || endpoint.scope === "vm:exec" ? 404 : 403);
      expect(h.upstreamRequests).toHaveLength(0);
    },
  );

  it("lists only role=chief VMs, and a selector for another role finds nothing", async () => {
    const service = await h.addServiceKey();
    h.addVm(TENANT_A);
    h.addVm(TENANT_A, "running", { role: "dev" });
    const { vmId: chiefVm } = h.addVm(TENANT_A, "running", CHIEF);

    const list = await (await h.request("/v1/vms", asTeam(service, TENANT_A))).json<{ items: ReadonlyArray<VmBody> }>();
    expect(list.items.map((vm) => vm.id)).toEqual([chiefVm]);

    const other = await (await h.request("/v1/vms?label=role%3Ddev", asTeam(service, TENANT_A))).json<{ items: ReadonlyArray<VmBody> }>();
    expect(other.items).toEqual([]);
  });

  it("cannot reach another team's chief VM by naming its own team", async () => {
    const service = await h.addServiceKey();
    const { vmId } = h.addVm(TENANT_B, "running", CHIEF);
    expect((await h.request(`/v1/vms/${vmId}`, asTeam(service, TENANT_A))).status).toBe(404);
  });
});

describe("its own chief VMs", () => {
  it("can read, exec, pause, start, stop and delete them, each mutation audited as the service", async () => {
    const service = await h.addServiceKey();
    // A running VM a member labelled role=chief: the label, not the creator, decides what the service reaches.
    const { vmId } = h.addVm(TENANT_A, "running", CHIEF);
    const vm = { id: vmId };
    const headers = asTeam(service, TENANT_A);

    expect((await h.request(`/v1/vms/${vm.id}`, headers)).status).toBe(200);
    expect((await h.request(`/v1/vms/${vm.id}/exec`, headers, { method: "POST", body: { command: "true" } })).status).toBe(200);
    expect((await h.request(`/v1/vms/${vm.id}/pause`, headers, { method: "POST" })).status).toBe(200);
    expect((await h.request(`/v1/vms/${vm.id}/start`, headers, { method: "POST" })).status).toBe(200);
    expect((await h.request(`/v1/vms/${vm.id}`, headers, { method: "DELETE" })).status).toBe(204);

    const actions = h.audit.filter((row) => row.cmuxId === vm.id).map((row) => [row.actor, row.action, row.outcome]);
    expect(actions).toContainEqual(["service:cloud-chief", "vm.delete", "ok"]);
    expect(h.audit.every((row) => row.actor === "service:cloud-chief")).toBe(true);
  });

  it("forks only into another role=chief VM", async () => {
    const service = await h.addServiceKey();
    const { vmId } = h.addVm(TENANT_A, "running", CHIEF);
    const vm = { id: vmId };
    const headers = asTeam(service, TENANT_A);

    expect((await h.request(`/v1/vms/${vm.id}/fork`, headers, { method: "POST", body: {} })).status).toBe(403);
    const forked = await h.request(`/v1/vms/${vm.id}/fork`, headers, { method: "POST", body: { labels: CHIEF } });
    expect(forked.status).toBe(201);
    expect((await forked.json<VmBody>()).labels).toEqual(CHIEF);
  });
});

describe("scopes", () => {
  it("cannot manage API keys, snapshots or meshes", async () => {
    const service = await h.addServiceKey();
    const headers = asTeam(service, TENANT_A);
    expect((await h.request("/v1/api-keys", headers)).status).toBe(403);
    expect((await h.request("/v1/api-keys", headers, { method: "POST", body: { name: "x", scopes: ["vm:read"] } })).status).toBe(403);
    expect((await h.request("/v1/snapshots", headers)).status).toBe(403);
    expect((await h.request("/v1/meshes", headers)).status).toBe(403);
  });
});
