import { afterEach, beforeEach, expect, it } from "vitest";
import { Schema } from "effect";
import { ALL_SCOPES, bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

let h: Awaited<ReturnType<typeof makeHarness>>;
beforeEach(async () => { h = await makeHarness(); });
afterEach(async () => { await h.dispose(); });

const world = async () => {
  const key = await h.addKey("team_alpha", ALL_SCOPES);
  const made = await h.request("/v1/meshes", bearer(key), { method: "POST", body: {} });
  expect(made.status).toBe(201);
  const mesh = Schema.decodeUnknownSync(Schema.Struct({ id: Schema.String, ipv4Cidr: Schema.String }))(await made.json());
  const vm = h.addVm("team_alpha");
  const path = `/v1/meshes/${mesh.id}/vms/${vm.vmId}`;
  expect((await h.request(path, bearer(key), { method: "PUT" })).status).toBe(200);
  const vpc = h.mesh.vmNetworks.get(vm.upstreamId)!;
  const upstream = h.upstream.vms.get(vm.upstreamId)!;
  return { key, mesh, vm, path, vpc, upstream };
};

it.each([null, 28])("reads the current owned member address without attaching again (%s)", async (host) => {
  const f = await world();
  const ipv4 = host === null ? null : `${f.mesh.ipv4Cidr.split(".").slice(0, 3).join(".")}.${host}`;
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

it.each([
  { networks: [{ vpc: "vpc-other", ipv4: "10.128.0.9" }] },
  { networks: [] },
])("clears the address when the provider no longer places the VM on this mesh %#", async ({ networks }) => {
  const f = await world(); f.upstream.vpcs = networks;
  const read = await h.request(f.path, bearer(f.key));
  expect(read.status).toBe(200);
  expect(await read.json()).toMatchObject({ ipv4: null });
});

it.each(["outside", "leading-zero", "network", "broadcast"])("refuses a non-member address instead of caching it (%s)", async (kind) => {
  const f = await world();
  const parts = f.mesh.ipv4Cidr.split(".");
  const base = parts.slice(0, 3).join(".");
  const ipv4 = kind === "outside" ? "11.128.0.9" : kind === "leading-zero" ? `${base}.09`
    : kind === "network" ? `${base}.0` : `${parts[0]}.${parts[1]}.${Number(parts[2]) + 15}.255`;
  const prior = h.mesh.store.members.find((m) => m.vmId === f.vm.vmId)!.ipv4;
  f.upstream.vpcs = [{ vpc: f.vpc, ipv4 }];
  expect((await h.request(f.path, bearer(f.key))).status).toBe(503);
  expect(h.mesh.store.members.find((m) => m.vmId === f.vm.vmId)?.ipv4).toBe(prior);
});

it("refuses ambiguous network identities", async () => {
  const f = await world();
  f.upstream.vpcs = [{ vpc: f.vpc, ipv4: "10.128.0.9" }, { vpc: f.vpc, ipv4: "10.128.0.10" }];
  expect((await h.request(f.path, bearer(f.key))).status).toBe(503);
  f.upstream.vpcs = [{ vpc: f.vpc, vpcId: "vpc-other", ipv4: "10.128.0.9" }];
  expect((await h.request(f.path, bearer(f.key))).status).toBe(503);
});
