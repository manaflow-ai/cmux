/**
 * The per-device IPv6 firewall rule (transport.md sections 7 and 13.6; bead
 * cx-wb5.45). A device that has a global IPv6 address publishes it with its
 * install-key signature; the reconciler then opens each VM the ACL lets the
 * device reach, on the overlay port (UDP 4101) only, to that one /128:
 * `{cidr: <address>/128} -> {vmId, udp, 4101}`. A new address creates the new
 * rule before it deletes the old one; clearing the address deletes it; closing
 * the device deletes it at the provider (a cidr rule names no tunnel, so the
 * tunnel delete does not take it along).
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { ALL_SCOPES, bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";
import { addressBody, enrollBody, makeInstallKey, type InstallKey } from "../support/mesh-signing.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;

const A = "team_alpha";
const KEY_1 = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDE=";
const KEY_2 = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDI=";
const MEMBER_SCOPES = ["mesh:read", "mesh:join", "acl:read"] as const;
const ADDRESS_1 = "2600:1700:abcd:1::5";
const ADDRESS_2 = "2600:1700:abcd:2::9";

let h: Harness;
beforeEach(async () => {
  // No minimum interval between address changes, except in the test of that budget.
  h = await makeHarness({ mesh: { budgets: { addressChangeIntervalMs: 0 } } });
});
afterEach(async () => {
  await h.dispose();
});

const json = async (response: Response): Promise<Record<string, unknown>> => {
  const body: unknown = await response.json();
  return typeof body === "object" && body !== null ? Object.fromEntries(Object.entries(body)) : {};
};
const field = (value: unknown, key: string): unknown => (typeof value === "object" && value !== null ? Object.fromEntries(Object.entries(value))[key] : undefined);
const str = (value: unknown): string => (typeof value === "string" ? value : "");
const call = (path: string, key: string, method = "GET", body?: unknown) => h.request(path, bearer(key), { method, body });
const anonymous = (path: string, body?: unknown) => h.request(path, {}, { method: "POST", body });

/** A mesh with two VMs; the ACL lets every device ping the first only. */
const meshWithVms = async () => {
  const admin = await h.addKey(A, ALL_SCOPES);
  const created = await call("/v1/meshes", admin, "POST", { displayName: "ipv6" });
  expect(created.status).toBe(201);
  const meshId = str((await json(created))["id"]);
  const allowed = h.addVm(A);
  const other = h.addVm(A);
  for (const vm of [allowed, other]) expect((await call(`/v1/meshes/${meshId}/vms/${vm.vmId}`, admin, "PUT")).status).toBe(200);
  const acl = await call(`/v1/meshes/${meshId}/acl`, admin, "PUT", { expectedVersion: 0, rules: [{ src: ["device:*"], dst: [allowed.vmId], allow: ["icmp"] }] });
  expect(acl.status).toBe(200);
  const creator = await h.addKey(A, MEMBER_SCOPES);
  return { admin, meshId, allowed, other, creator };
};

const enroll = async (meshId: string, creator: string, install: InstallKey, wgPublicKey: string) => {
  const code = await call(`/v1/meshes/${meshId}/enrollment-codes`, creator, "POST", {});
  expect(code.status).toBe(201);
  const response = await anonymous(`/v1/meshes/${meshId}/device-enrollments`, await enrollBody(install, meshId, { name: "laptop", wgPublicKey, code: str((await json(code))["code"]) }));
  expect(response.status).toBe(201);
  return str(field(field(await json(response), "device"), "id"));
};

const publish = async (install: InstallKey, deviceId: string, address: string | null, headers: Record<string, string> = {}) =>
  h.request(`/v1/devices/${deviceId}/signed/address`, headers, { method: "POST", body: await addressBody(install, deviceId, address) });

/** The provider rules whose source is a cidr. */
const cidrRules = () => [...h.mesh.rules.values()].filter((rule) => typeof rule.source["cidr"] === "string");

describe("a device's public IPv6 address", () => {
  it("opens UDP 4101 on each VM the ACL allows to the device's /128, and nothing else", async () => {
    const mesh = await meshWithVms();
    const install = await makeInstallKey();
    const deviceId = await enroll(mesh.meshId, mesh.creator, install, KEY_1);
    expect(cidrRules()).toEqual([]);

    const published = await publish(install, deviceId, "2600:1700:ABCD:0001:0:0:0:5");
    expect(published.status).toBe(200);
    expect(await json(published)).toMatchObject({ deviceId, publicIpv6: ADDRESS_1 });

    const rules = cidrRules();
    expect(rules).toHaveLength(1);
    expect(rules[0]?.source).toEqual({ cidr: `${ADDRESS_1}/128` });
    expect(rules[0]?.destination).toEqual({ vmId: mesh.allowed.upstreamId, protocol: "udp", port: 4101 });
    // The device's tunnel rule to the allowed VM is still there.
    expect([...h.mesh.rules.values()].filter((rule) => typeof rule.source["tunnelId"] === "string")).toHaveLength(1);
  });

  it("follows a new address: the new rule exists before the old one is deleted", async () => {
    const mesh = await meshWithVms();
    const install = await makeInstallKey();
    const deviceId = await enroll(mesh.meshId, mesh.creator, install, KEY_1);
    expect((await publish(install, deviceId, ADDRESS_1)).status).toBe(200);
    const before = h.upstreamRequests.length;

    expect((await publish(install, deviceId, ADDRESS_2)).status).toBe(200);
    expect(cidrRules().map((rule) => rule.source["cidr"])).toEqual([`${ADDRESS_2}/128`]);
    const order = h.upstreamRequests
      .slice(before)
      .filter((request) => request.path.startsWith("/v5/firewall/rules"))
      .map((request) => request.method);
    expect(order).toEqual(["POST", "DELETE"]);

    // Publishing the same address again changes nothing at the provider.
    const settled = h.upstreamRequests.length;
    expect((await publish(install, deviceId, ADDRESS_2)).status).toBe(200);
    expect(h.upstreamRequests.slice(settled).filter((request) => request.path.startsWith("/v5/firewall/rules"))).toEqual([]);
  });

  it("clearing the address deletes its rule", async () => {
    const mesh = await meshWithVms();
    const install = await makeInstallKey();
    const deviceId = await enroll(mesh.meshId, mesh.creator, install, KEY_1);
    expect((await publish(install, deviceId, ADDRESS_1)).status).toBe(200);
    const cleared = await publish(install, deviceId, null);
    expect(cleared.status).toBe(200);
    expect((await json(cleared))["publicIpv6"]).toBeNull();
    expect(cidrRules()).toEqual([]);
  });

  it("deleting the device deletes its address rule at the provider", async () => {
    const mesh = await meshWithVms();
    const install = await makeInstallKey();
    const deviceId = await enroll(mesh.meshId, mesh.creator, install, KEY_1);
    expect((await publish(install, deviceId, ADDRESS_1)).status).toBe(200);
    expect(cidrRules()).toHaveLength(1);

    expect((await call(`/v1/devices/${deviceId}`, mesh.creator, "DELETE")).status).toBe(204);
    expect(cidrRules()).toEqual([]);
  });

  it("an ACL change that drops the device's access deletes its address rule", async () => {
    const mesh = await meshWithVms();
    const install = await makeInstallKey();
    const deviceId = await enroll(mesh.meshId, mesh.creator, install, KEY_1);
    expect((await publish(install, deviceId, ADDRESS_1)).status).toBe(200);
    const acl = await call(`/v1/meshes/${mesh.meshId}/acl`, mesh.admin, "PUT", { expectedVersion: 1, rules: [] });
    expect(acl.status).toBe(200);
    expect(cidrRules()).toEqual([]);
  });

  it("the signature covers the address: a body with another address is refused and nothing reaches the provider", async () => {
    const mesh = await meshWithVms();
    const install = await makeInstallKey();
    const deviceId = await enroll(mesh.meshId, mesh.creator, install, KEY_1);
    const body = await addressBody(install, deviceId, ADDRESS_1);
    const before = h.upstreamRequests.length;
    expect((await anonymous(`/v1/devices/${deviceId}/signed/address`, { ...body, publicIpv6: ADDRESS_2 })).status).toBe(404);
    expect(h.upstreamRequests.slice(before)).toEqual([]);
  });

  it("refuses an address that is not one global unicast IPv6 address with 400", async () => {
    const mesh = await meshWithVms();
    const install = await makeInstallKey();
    const deviceId = await enroll(mesh.meshId, mesh.creator, install, KEY_1);
    for (const bad of ["fd7c:6d78::1", "fe80::1", "2001:db8::1", "::ffff:192.0.2.1", "2600::/64", "192.0.2.1"]) {
      expect((await publish(install, deviceId, bad)).status, bad).toBe(400);
    }
    expect(cidrRules()).toEqual([]);
  });

  it("one device's signature cannot publish an address for another device", async () => {
    const mesh = await meshWithVms();
    const mine = await makeInstallKey();
    const theirs = await makeInstallKey();
    await enroll(mesh.meshId, mesh.creator, mine, KEY_1);
    const theirId = await enroll(mesh.meshId, mesh.creator, theirs, KEY_2);
    const forged = await addressBody(theirs, theirId, ADDRESS_1, { signWith: mine });
    expect((await anonymous(`/v1/devices/${theirId}/signed/address`, forged)).status).toBe(404);
    expect(cidrRules()).toEqual([]);
  });
});

describe("address rules: review findings", () => {
  it("deleting the device while its address rule is being created leaves no address rule at the provider", async () => {
    const mesh = await meshWithVms();
    const install = await makeInstallKey();
    const deviceId = await enroll(mesh.meshId, mesh.creator, install, KEY_1);
    const release = h.mesh.holdRuleCreates();
    const published = publish(install, deviceId, ADDRESS_1);
    await h.mesh.ruleCreateHeld();
    const deleted = call(`/v1/devices/${deviceId}`, mesh.creator, "DELETE");
    await new Promise((resolve) => setTimeout(resolve, 100));
    release();
    await published;
    expect((await deleted).status).toBe(204);
    expect(cidrRules()).toEqual([]);
  });

  it("an address rule whose row could not be recorded is deleted at the provider", async () => {
    const mesh = await meshWithVms();
    const install = await makeInstallKey();
    const deviceId = await enroll(mesh.meshId, mesh.creator, install, KEY_1);
    h.mesh.failRuleRecords(1);
    expect((await publish(install, deviceId, ADDRESS_1)).status).toBe(503);
    expect(cidrRules()).toEqual([]);
  });

  it("publishing the same address again takes no lock and makes no provider call", async () => {
    const mesh = await meshWithVms();
    const install = await makeInstallKey();
    const deviceId = await enroll(mesh.meshId, mesh.creator, install, KEY_1);
    expect((await publish(install, deviceId, ADDRESS_1)).status).toBe(200);
    const before = h.upstreamRequests.length;
    const release = h.mesh.holdRuleCreates();
    // A held provider call elsewhere does not matter: an unchanged address does nothing.
    expect((await publish(install, deviceId, ADDRESS_1)).status).toBe(200);
    release();
    expect(h.upstreamRequests.slice(before)).toEqual([]);
  });

  it("refuses an address outside the /64 the request came from when it came over IPv6", async () => {
    const mesh = await meshWithVms();
    const install = await makeInstallKey();
    const deviceId = await enroll(mesh.meshId, mesh.creator, install, KEY_1);
    expect((await publish(install, deviceId, ADDRESS_1, { "cf-connecting-ip": "2600:1700:abcd:9::1" })).status).toBe(400);
    expect(cidrRules()).toEqual([]);
    expect((await publish(install, deviceId, ADDRESS_1, { "cf-connecting-ip": "2600:1700:abcd:1:aaaa::7" })).status).toBe(200);
    expect(cidrRules()).toHaveLength(1);
    // Over IPv4 the address cannot be checked against the source.
    expect((await publish(install, deviceId, ADDRESS_2, { "cf-connecting-ip": "198.51.100.7" })).status).toBe(200);
  });
});

describe("address change budget", () => {
  it("a second change within the interval is 429 with a retry time; publishing the same address is not a change", async () => {
    await h.dispose();
    h = await makeHarness({ mesh: { budgets: { addressChangeIntervalMs: 60_000 } } });
    const mesh = await meshWithVms();
    const install = await makeInstallKey();
    const deviceId = await enroll(mesh.meshId, mesh.creator, install, KEY_1);
    expect((await publish(install, deviceId, ADDRESS_1)).status).toBe(200);
    expect((await publish(install, deviceId, ADDRESS_1)).status).toBe(200);
    const refused = await publish(install, deviceId, ADDRESS_2);
    expect(refused.status).toBe(429);
    expect(Number((await json(refused))["retryAfterSeconds"])).toBeGreaterThan(0);
    expect(cidrRules().map((rule) => rule.source["cidr"])).toEqual([`${ADDRESS_1}/128`]);
  });
});

describe("address rules: re-review findings", () => {
  it("a device close whose address rule delete fails can be retried, and the retry deletes the rule", async () => {
    const mesh = await meshWithVms();
    const install = await makeInstallKey();
    const deviceId = await enroll(mesh.meshId, mesh.creator, install, KEY_1);
    expect((await publish(install, deviceId, ADDRESS_1)).status).toBe(200);
    h.mesh.failRuleDeletes(503);
    expect((await call(`/v1/devices/${deviceId}`, mesh.creator, "DELETE")).status).toBe(503);
    h.mesh.failRuleDeletes(null);
    expect((await call(`/v1/devices/${deviceId}`, mesh.creator, "DELETE")).status).toBe(204);
    expect(cidrRules()).toEqual([]);
  });

  it("publishing the same address again restores an address rule that is missing", async () => {
    const mesh = await meshWithVms();
    const install = await makeInstallKey();
    const deviceId = await enroll(mesh.meshId, mesh.creator, install, KEY_1);
    expect((await publish(install, deviceId, ADDRESS_1)).status).toBe(200);
    // The rule and its row are lost (an isolate died between storing the address and applying it).
    for (const [id, rule] of h.mesh.rules) if (typeof rule.source["cidr"] === "string") h.mesh.rules.delete(id);
    for (const row of h.mesh.store.rules) if (row.key.includes(":from:")) row.deletedAt = new Date();
    expect((await publish(install, deviceId, ADDRESS_1)).status).toBe(200);
    expect(cidrRules().map((rule) => rule.source["cidr"])).toEqual([`${ADDRESS_1}/128`]);
  });

  it("a refused change keeps the time of the last applied change", async () => {
    await h.dispose();
    h = await makeHarness({ mesh: { budgets: { addressChangeIntervalMs: 60_000 } } });
    const mesh = await meshWithVms();
    const install = await makeInstallKey();
    const deviceId = await enroll(mesh.meshId, mesh.creator, install, KEY_1);
    h.mesh.failRuleCreates(500);
    expect((await publish(install, deviceId, ADDRESS_1)).status).toBe(503);
    h.mesh.failRuleCreates(null);
    // The failed first publish left no address, so the next one is the first change, not a 429.
    expect((await publish(install, deviceId, ADDRESS_1)).status).toBe(200);
  });
});
