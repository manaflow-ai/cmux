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

const egress = (t: Harness, vm: string, key: string, method: "GET" | "PUT" | "DELETE" = "GET") =>
  t.request(`/v1/vms/${vm}/public-egress`, bearer(key), { method });
const create = async (t: Harness, key: string, body: unknown) => {
  const response = await t.request("/v1/vms", bearer(key), { method: "POST", body });
  expect(response.status).toBe(201);
  return (await response.json<{ id: string }>()).id;
};

const ruleOf = (vmId: string, id: string, destination: Record<string, unknown>) =>
  ({ vmId, rule: { id, action: "allow", source: { vmId }, destination } });
/** `count` narrower rules of `vmId`, so a later rule sits on the list's second page (64 a page). */
const narrowRules = (t: Harness, vmId: string, count: number) => {
  for (let index = 0; index < count; index += 1) t.upstream.firewallRules.set(`narrow-${index}`, ruleOf(vmId, `narrow-${index}`, { cidr: "203.0.113.0/24" }));
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

  it("reads a rule on the second page as on even when an earlier rule goes between pages", async () => {
    const t = await harness();
    const vm = t.addVm(TENANT);
    const key = await t.addKey(TENANT, ["vm:network"]);
    narrowRules(t, vm.upstreamId, 64);
    t.upstream.firewallRules.set("open", ruleOf(vm.upstreamId, "open", { public: true }));
    // After the first page, a rule before "open" is deleted: a plain next-offset read lands past it.
    t.upstream.afterRuleList.push(() => t.upstream.firewallRules.delete("narrow-0"));
    expect(await (await egress(t, vm.vmId, key)).json()).toEqual({ id: vm.vmId, publicEgress: true });
    // And the allow adds no second rule.
    expect((await egress(t, vm.vmId, key, "PUT")).status).toBe(200);
    expect(t.upstream.callsTo("POST", /^\/v5\/firewall\/rules$/)).toHaveLength(0);
  });

  it("reads past 256 rules up to the first egress rule, as before", async () => {
    const t = await harness();
    const vm = t.addVm(TENANT);
    const key = await t.addKey(TENANT, ["vm:network"]);
    t.upstream.firewallRules.set("open", ruleOf(vm.upstreamId, "open", { public: true }));
    narrowRules(t, vm.upstreamId, 300);
    expect(await (await egress(t, vm.vmId, key)).json()).toEqual({ id: vm.vmId, publicEgress: true });
    expect((await egress(t, vm.vmId, key, "PUT")).status).toBe(200);
    expect(t.upstream.callsTo("POST", /^\/v5\/firewall\/rules$/)).toHaveLength(0);
  });
});

describe("revoking a VM's public egress", () => {
  it("deletes the VM's whole-Internet rules, keeps narrower ones, and reads back off", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT, ["vm:write", "vm:network"]);
    const vm = await create(t, key, { initialNetwork: { publicEgress: true } });
    const upstreamVm = [...t.upstream.vms.keys()][0]!;
    // A second whole-Internet rule (an allow after create) and a narrower one that must stay.
    expect((await t.request(`/v1/vms/${vm}/public-egress`, bearer(key), { method: "PUT" })).status).toBe(200);
    t.upstream.firewallRules.set("narrow", { vmId: upstreamVm, rule: { id: "narrow", action: "allow", source: { vmId: upstreamVm }, destination: { cidr: "203.0.113.0/24" } } });
    t.upstream.firewallRules.set("dup", { vmId: upstreamVm, rule: { id: "dup", action: "allow", source: { vmId: upstreamVm }, destination: { public: true } } });

    const revoked = await egress(t, vm, key, "DELETE");
    expect(revoked.status).toBe(200);
    const body = await revoked.text();
    expect(JSON.parse(body)).toEqual({ id: vm, publicEgress: false });
    expect(body).not.toContain(upstreamVm);
    expect(t.upstream.callsTo("DELETE", /^\/v5\/firewall\/rules\/.+$/)).toHaveLength(2);
    expect([...t.upstream.firewallRules.keys()]).toEqual(["narrow"]);
    expect(await (await egress(t, vm, key)).json()).toEqual({ id: vm, publicEgress: false });
    expect(t.audit.map((row) => row.action)).toContain("vm.public_egress.revoke");

    // Idempotent: nothing left to delete. Then allow again works.
    expect((await egress(t, vm, key, "DELETE")).status).toBe(200);
    expect((await egress(t, vm, key, "PUT")).status).toBe(200);
    expect(await (await egress(t, vm, key)).json()).toEqual({ id: vm, publicEgress: true });
  });

  it("answers 503, not off, when a delete leaves a rule behind", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT, ["vm:network"]);
    const vm = t.addVm(TENANT);
    t.upstream.firewallRules.set("open", { vmId: vm.upstreamId, rule: { id: "open", action: "allow", source: { vmId: vm.upstreamId }, destination: { public: true } } });
    t.upstream.fail("deleteFirewallRule", 500);
    expect((await egress(t, vm.vmId, key, "DELETE")).status).toBe(503);
    expect(t.upstream.firewallRules.has("open")).toBe(true);
  });

  it("answers 503, not off, when the list moves under the read-back and hides a rule", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT, ["vm:network"]);
    const vm = t.addVm(TENANT);
    narrowRules(t, vm.upstreamId, 64);
    t.upstream.firewallRules.set("open", ruleOf(vm.upstreamId, "open", { public: true }));
    // The revoke's list (two pages) finds "open"; a concurrent allow then adds "late", which takes "open"'s place
    // once it is deleted. During the read-back, after the first page, a narrower rule goes and "late" moves back
    // onto the first page's range: a plain next-offset read finds nothing on the second page and calls it off.
    t.upstream.afterRuleList.push(undefined, () => t.upstream.firewallRules.set("late", ruleOf(vm.upstreamId, "late", { public: true })), () => t.upstream.firewallRules.delete("narrow-0"));
    expect((await egress(t, vm.vmId, key, "DELETE")).status).toBe(503);
    expect(t.upstream.firewallRules.has("late")).toBe(true);
  });

  it("answers 503, not off, when an allow lands at the front during the read-back", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT, ["vm:network"]);
    const vm = t.addVm(TENANT);
    narrowRules(t, vm.upstreamId, 65);
    // The revoke's list is two pages with nothing to delete. After the read-back's first page, an allow lands first in
    // the list (the provider lists newest first) and the first narrower rule goes: the total and the overlap rule stay.
    t.upstream.afterRuleList.push(undefined, undefined, () => {
      const rest = [...t.upstream.firewallRules.entries()].filter(([ruleId]) => ruleId !== "narrow-0");
      t.upstream.firewallRules.clear();
      t.upstream.firewallRules.set("late", ruleOf(vm.upstreamId, "late", { public: true }));
      for (const [ruleId, entry] of rest) t.upstream.firewallRules.set(ruleId, entry);
    });
    expect((await egress(t, vm.vmId, key, "DELETE")).status).toBe(503);
    expect(t.upstream.firewallRules.has("late")).toBe(true);
  });

  it("does not touch another VM's rule, and needs the network scope", async () => {
    const t = await harness();
    const vm = t.addVm(TENANT);
    const other = t.addVm(TENANT);
    t.upstream.firewallRules.set("other", { vmId: other.upstreamId, rule: { id: "other", action: "allow", source: { vmId: other.upstreamId }, destination: { public: true } } });
    const weak = await t.addKey(TENANT, ["vm:write", "vm:read"]);
    expect((await egress(t, vm.vmId, weak, "DELETE")).status).toBe(403);
    expect(t.upstreamRequests).toHaveLength(0);
    const key = await t.addKey(TENANT, ["vm:network"]);
    expect((await egress(t, vm.vmId, key, "DELETE")).status).toBe(200);
    expect(t.upstream.firewallRules.has("other")).toBe(true);
    const hidden = t.addVm("team_bravo");
    expect((await egress(t, hidden.vmId, key, "DELETE")).status).toBe(404);
  });
});
