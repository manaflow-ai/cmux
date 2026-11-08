/** An existing VM's public egress: read it, or allow it once, for exactly that VM. */
import { afterEach, describe, expect, it } from "vitest";
import { bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;
const TENANT = "team_alpha";
let current: Harness | undefined;
const harness = async () => {
  current = await makeHarness();
  return current;
};
afterEach(async () => {
  await current?.dispose();
  current = undefined;
});

const egress = (t: Harness, vm: string, key: string, method: "GET" | "PUT" = "GET") =>
  t.request(`/v1/vms/${vm}/public-egress`, bearer(key), { method });
const create = async (t: Harness, key: string, body: unknown) => {
  const response = await t.request("/v1/vms", bearer(key), { method: "POST", body });
  expect(response.status).toBe(201);
  return (await response.json<{ id: string }>()).id;
};

describe("existing VM public egress", () => {
  it("lets a private VM out once, and reads it back", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT, ["vm:write", "vm:network"]);
    const vm = await create(t, key, {});
    const upstreamVm = [...t.upstream.vms.keys()][0];

    const before = await egress(t, vm, key);
    expect(before.status).toBe(200);
    expect(await before.json()).toEqual({ id: vm, publicEgress: false });

    const allowed = await egress(t, vm, key, "PUT");
    expect(allowed.status).toBe(200);
    const body = await allowed.text();
    expect(JSON.parse(body)).toEqual({ id: vm, publicEgress: true });
    expect(body).not.toContain(upstreamVm);
    expect(t.upstream.callsTo("POST", /^\/v5\/firewall\/rules$/)).toMatchObject([
      { json: { action: "allow", source: { vmId: upstreamVm }, destination: { public: true } } },
    ]);
    expect(await (await egress(t, vm, key)).json()).toEqual({ id: vm, publicEgress: true });

    // Idempotent: a second allow adds no second rule.
    expect((await egress(t, vm, key, "PUT")).status).toBe(200);
    expect(t.upstream.callsTo("POST", /^\/v5\/firewall\/rules$/)).toHaveLength(1);
    expect(t.audit.map((row) => row.action)).toContain("vm.public_egress.allow");
  });

  it("counts a create's inline egress rule and adds nothing", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT, ["vm:write", "vm:network"]);
    const vm = await create(t, key, { initialNetwork: { publicEgress: true } });

    expect(await (await egress(t, vm, key)).json()).toEqual({ id: vm, publicEgress: true });
    expect((await egress(t, vm, key, "PUT")).status).toBe(200);
    expect(t.upstream.callsTo("POST", /^\/v5\/firewall\/rules$/)).toHaveLength(0);
  });

  it("does not count a narrower rule, or another VM's", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT, ["vm:network"]);
    const vm = t.addVm(TENANT);
    const other = t.addVm(TENANT);
    const rule = (id: string, vmId: string, source: Record<string, unknown>, destination: Record<string, unknown>) =>
      t.upstream.firewallRules.set(id, { vmId, rule: { id, action: "allow", source, destination } });
    rule("port", vm.upstreamId, { vmId: vm.upstreamId }, { public: true, port: 443, protocol: "tcp" });
    rule("cidr", vm.upstreamId, { vmId: vm.upstreamId }, { cidr: "203.0.113.0/24" });
    rule("other", other.upstreamId, { vmId: other.upstreamId }, { public: true });
    rule("inbound", vm.upstreamId, { public: true }, { vmId: vm.upstreamId });

    expect(await (await egress(t, vm.vmId, key)).json()).toEqual({ id: vm.vmId, publicEgress: false });
    expect(t.upstream.callsTo("GET", /^\/v5\/firewall\/rules$/)[0]?.search.get("vmId")).toBe(vm.upstreamId);
  });

  it("requires the network scope before any provider request", async () => {
    const t = await harness();
    const vm = t.addVm(TENANT);
    const key = await t.addKey(TENANT, ["vm:write", "vm:read"]);
    expect((await egress(t, vm.vmId, key)).status).toBe(403);
    expect((await egress(t, vm.vmId, key, "PUT")).status).toBe(403);
    expect(t.upstreamRequests).toHaveLength(0);
  });

  it("keeps another tenant's VM hidden without a provider request", async () => {
    const t = await harness();
    const vm = t.addVm("team_bravo");
    const key = await t.addKey(TENANT, ["vm:network"]);
    expect((await egress(t, vm.vmId, key, "PUT")).status).toBe(404);
    expect(t.upstreamRequests).toHaveLength(0);
  });

  it("answers 503, not a guess, when the provider's list fails", async () => {
    const t = await harness();
    const vm = t.addVm(TENANT);
    const key = await t.addKey(TENANT, ["vm:network"]);
    t.upstream.fail("listFirewallRules", 500);
    expect((await egress(t, vm.vmId, key, "PUT")).status).toBe(503);
    expect(t.upstream.callsTo("POST", /^\/v5\/firewall\/rules$/)).toHaveLength(0);
  });
});
