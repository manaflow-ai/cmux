/** The mesh ACL compiler (src/mesh/acl.ts) and the address plan (src/mesh/config.ts). Pure functions. */
import { describe, expect, it } from "vitest";
import { ADDRESS_RULE_PORT, compileAcl, parseAllow, parseDeviceIpv6, peersOf, planApply } from "../../src/mesh/acl.ts";
import { slotCidr } from "../../src/mesh/config.ts";

const D1 = "dev_aaaaaaaaaaaaaaaaaaaaaaaaaa";
const D2 = "dev_bbbbbbbbbbbbbbbbbbbbbbbbbb";
const V1 = "vm_aaaaaaaaaaaaaaaaaaaaaaaaaa";
const V2 = "vm_bbbbbbbbbbbbbbbbbbbbbbbbbb";

const compile = (rules: ReadonlyArray<{ src: string[]; dst: string[]; allow: string[] }>, limits = { rulesPerResource: 180, rulesPerMesh: 500 }) =>
  compileAcl({ document: { rules }, deviceIds: [D1, D2], vmIds: [V1, V2], ...limits });

describe("parseAllow", () => {
  it("accepts tcp/udp ports, protocol wildcards, icmp and *", () => {
    expect(parseAllow("tcp:8080")).toEqual({ protocol: "tcp", port: 8080 });
    expect(parseAllow("udp:53")).toEqual({ protocol: "udp", port: 53 });
    expect(parseAllow("tcp:*")).toEqual({ protocol: "tcp", port: null });
    expect(parseAllow("icmp")).toEqual({ protocol: "icmp", port: null });
    expect(parseAllow("*")).toEqual({ protocol: null, port: null });
  });
  it("refuses everything else", () => {
    for (const bad of ["tcp:0", "tcp:65536", "tcp", "icmp:1", "sctp:1", "tcp:80-90", ""]) expect(parseAllow(bad), bad).toBeNull();
  });
});

describe("compileAcl", () => {
  it("expands one rule per device, VM and port, deduplicated and sorted", () => {
    const result = compile([
      { src: [D1], dst: [V1], allow: ["tcp:8080", "icmp"] },
      { src: ["device:*"], dst: [V1], allow: ["tcp:8080"] },
    ]);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.rules.map((rule) => rule.key)).toEqual([
      `${D1}>${V1}:icmp:*`,
      `${D1}>${V1}:tcp:8080`,
      `${D2}>${V1}:tcp:8080`,
    ]);
  });

  it("default deny: an empty document compiles to no rules", () => {
    expect(compile([])).toEqual({ ok: true, rules: [] });
  });

  it("refuses ids that are not members and selectors of the wrong kind", () => {
    expect(compile([{ src: ["dev_zzzzzzzzzzzzzzzzzzzzzzzzzz"], dst: [V1], allow: ["icmp"] }])).toMatchObject({ ok: false, reason: "invalid" });
    expect(compile([{ src: [V1], dst: [V2], allow: ["icmp"] }])).toMatchObject({ ok: false, reason: "invalid" });
    expect(compile([{ src: [D1], dst: [D2], allow: ["icmp"] }])).toMatchObject({ ok: false, reason: "invalid" });
    expect(compile([{ src: [D1], dst: [V1], allow: ["tcp:99999"] }])).toMatchObject({ ok: false, reason: "invalid" });
  });

  it("refuses more rules on one resource than the per-resource limit", () => {
    const result = compile([{ src: ["device:*"], dst: [V1], allow: ["tcp:1", "tcp:2"] }], { rulesPerResource: 3, rulesPerMesh: 500 });
    expect(result).toMatchObject({ ok: false, reason: "perResource", resourceId: V1, count: 4 });
  });

  it("refuses more rules on the mesh than the mesh limit", () => {
    const result = compile([{ src: ["device:*"], dst: ["vm:*"], allow: ["tcp:1"] }], { rulesPerResource: 180, rulesPerMesh: 3 });
    expect(result).toMatchObject({ ok: false, reason: "perMesh", count: 4 });
  });
});

describe("planApply", () => {
  it("creates what is missing and deletes what is surplus, keeping what both have", () => {
    const desired = compile([{ src: [D1], dst: [V1], allow: ["tcp:8080", "icmp"] }]);
    if (!desired.ok) throw new Error("compile failed");
    const current = [{ key: `${D1}>${V1}:icmp:*` }, { key: `${D1}>${V1}:tcp:22` }];
    const plan = planApply(current, desired.rules);
    expect(plan.create.map((rule) => rule.key)).toEqual([`${D1}>${V1}:tcp:8080`]);
    expect(plan.remove).toEqual([{ key: `${D1}>${V1}:tcp:22` }]);
  });
});

describe("peersOf", () => {
  it("groups one device's rules by VM", () => {
    const result = compile([{ src: ["device:*"], dst: ["vm:*"], allow: ["icmp"] }]);
    if (!result.ok) throw new Error("compile failed");
    const peers = peersOf(D1, result.rules);
    expect([...peers.keys()].sort()).toEqual([V1, V2]);
  });
});

describe("device IPv6 address rules (transport.md 7, 13.6)", () => {
  const A1 = "2600:1700:abcd:1::5";
  const A2 = "2600:1700:abcd:2::9";
  const withAddresses = (addresses: ReadonlyMap<string, string>, rules: ReadonlyArray<{ src: string[]; dst: string[]; allow: string[] }>, limits = { rulesPerResource: 180, rulesPerMesh: 500 }) =>
    compileAcl({ document: { rules }, deviceIds: [D1, D2], vmIds: [V1, V2], deviceIpv6: addresses, ...limits });

  it("opens the VM's overlay port to the device's /128 once per (device, VM) pair the policy allows", () => {
    const result = withAddresses(new Map([[D1, A1]]), [{ src: [D1], dst: [V1], allow: ["tcp:8080", "icmp"] }]);
    if (!result.ok) throw new Error("compile failed");
    const address = result.rules.filter((rule) => rule.cidr !== null);
    expect(address).toEqual([
      expect.objectContaining({ deviceId: D1, vmId: V1, protocol: "udp", port: ADDRESS_RULE_PORT, cidr: `${A1}/128` }),
    ]);
    expect(ADDRESS_RULE_PORT).toBe(4101);
    // The tunnel rules stay as they were.
    expect(result.rules.filter((rule) => rule.cidr === null).map((rule) => rule.key)).toEqual([`${D1}>${V1}:icmp:*`, `${D1}>${V1}:tcp:8080`]);
  });

  it("emits no address rule for a device without an address or a pair the policy does not allow", () => {
    const result = withAddresses(new Map([[D2, A2]]), [{ src: [D1], dst: [V1], allow: ["icmp"] }]);
    if (!result.ok) throw new Error("compile failed");
    expect(result.rules.filter((rule) => rule.cidr !== null)).toEqual([]);
  });

  it("a changed address is a new rule plus a delete of the old one", () => {
    const before = withAddresses(new Map([[D1, A1]]), [{ src: [D1], dst: [V1], allow: ["icmp"] }]);
    const after = withAddresses(new Map([[D1, A2]]), [{ src: [D1], dst: [V1], allow: ["icmp"] }]);
    if (!before.ok || !after.ok) throw new Error("compile failed");
    const plan = planApply(before.rules, after.rules);
    expect(plan.create.map((rule) => rule.cidr)).toEqual([`${A2}/128`]);
    expect(plan.remove.map((rule) => rule.cidr)).toEqual([`${A1}/128`]);
  });

  it("counts address rules against the VM's per-resource limit", () => {
    const result = withAddresses(new Map([[D1, A1], [D2, A2]]), [{ src: ["device:*"], dst: [V1], allow: ["icmp"] }], { rulesPerResource: 3, rulesPerMesh: 500 });
    expect(result).toMatchObject({ ok: false, reason: "perResource", resourceId: V1, count: 4 });
  });

  it("keeps address rules out of the peer map's allowed ports", () => {
    const result = withAddresses(new Map([[D1, A1]]), [{ src: [D1], dst: [V1], allow: ["icmp"] }]);
    if (!result.ok) throw new Error("compile failed");
    expect(peersOf(D1, result.rules).get(V1)?.map((rule) => rule.protocol)).toEqual(["icmp"]);
  });
});

describe("parseDeviceIpv6", () => {
  it("accepts a global unicast address and returns its canonical form", () => {
    expect(parseDeviceIpv6("2600:1700:ABCD:0001:0000:0000:0000:0005")).toBe("2600:1700:abcd:1::5");
    expect(parseDeviceIpv6("2a01:4f8::1")).toBe("2a01:4f8::1");
    expect(parseDeviceIpv6("2600:0:0:1:0:0:0:1")).toBe("2600:0:0:1::1");
    expect(parseDeviceIpv6("3fff:ffff:ffff:ffff:ffff:ffff:ffff:ffff")).toBe("3fff:ffff:ffff:ffff:ffff:ffff:ffff:ffff");
  });
  it("refuses every address that is not one device's own global unicast address", () => {
    for (const bad of [
      "",
      "::",
      "::1",
      "fe80::1",
      "fd7c:6d78::1",
      "fc00::1",
      "ff02::1",
      "::ffff:192.0.2.1",
      "2001:db8::1",
      "2001:0:4136:e378:8000:63bf:3fff:fdd2",
      "2002:c000:0201::1",
      "4000::1",
      "2600::1/64",
      "2600::1%en0",
      "2600:::1",
      "2600::1::2",
      "2600:1:2:3:4:5:6:7:8",
      "2600:12345::1",
      "192.0.2.1",
      " 2600::1",
    ]) {
      expect(parseDeviceIpv6(bad), bad).toBeNull();
    }
  });
});

describe("slotCidr", () => {
  it("maps 2048 slots onto distinct /20s inside 10.128.0.0/9", () => {
    expect(slotCidr(0)).toBe("10.128.0.0/20");
    expect(slotCidr(1)).toBe("10.128.16.0/20");
    expect(slotCidr(16)).toBe("10.129.0.0/20");
    expect(slotCidr(2047)).toBe("10.255.240.0/20");
    expect(new Set(Array.from({ length: 2048 }, (_, slot) => slotCidr(slot))).size).toBe(2048);
    expect(() => slotCidr(2048)).toThrow();
  });
});
