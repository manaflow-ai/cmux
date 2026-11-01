import { afterEach, beforeEach, expect, it } from "vitest";
import { ALL_SCOPES, bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

let h: Awaited<ReturnType<typeof makeHarness>>;
beforeEach(async () => { h = await makeHarness(); });
afterEach(async () => { await h.dispose(); });

const world = async () => {
  const key = await h.addKey("team_alpha", ALL_SCOPES);
  const made = await h.request("/v1/meshes", bearer(key), { method: "POST", body: {} });
  expect(made.status).toBe(201);
  const mesh = await made.json() as { id: string };
  const vm = h.addVm("team_alpha");
  const path = `/v1/meshes/${mesh.id}/vms/${vm.vmId}`;
  expect((await h.request(path, bearer(key), { method: "PUT" })).status).toBe(200);
  const vpc = h.mesh.vmNetworks.get(vm.upstreamId)!;
  const upstream = h.upstream.vms.get(vm.upstreamId)!;
  return { key, mesh, vm, path, vpc, upstream };
};

it.each([null, "10.128.0.28"])("reads the current owned member address without attaching again (%s)", async (ipv4) => {
  const f = await world();
  f.upstream.vpcs = [{ vpc: f.vpc, vpcId: f.vpc, ipv4 }];
  const before = h.upstreamRequests.length;
  const read = await h.request(f.path, bearer(f.key));
  expect(read.status).toBe(200);
  expect(await read.json()).toMatchObject({ meshId: f.mesh.id, vmId: f.vm.vmId, ipv4 });
  expect(h.upstreamRequests.slice(before).every((r) => r.method === "GET")).toBe(true);
  expect(h.mesh.store.members.find((m) => m.vmId === f.vm.vmId)?.ipv4).toBe(ipv4);
});

it("keeps an unchanged member's attachment identity", async () => {
  const f = await world();
  const member = h.mesh.store.members.find((m) => m.vmId === f.vm.vmId)!;
  f.upstream.vpcs = [{ vpc: f.vpc, ipv4: member.ipv4 }];
  const read = await h.request(f.path, bearer(f.key));
  expect(read.status).toBe(200);
  expect(await read.json()).toMatchObject({ attachedAt: member.attachedAt.toISOString() });
});
