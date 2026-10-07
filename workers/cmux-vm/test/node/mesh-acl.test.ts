/** The mesh ACL compiler (src/mesh/acl.ts) and the address plan (src/mesh/config.ts). Pure functions. */
import { describe, expect, it } from "vitest";
import { compileAcl, parseAllow, peersOf, planApply } from "../../src/mesh/acl.ts";
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
