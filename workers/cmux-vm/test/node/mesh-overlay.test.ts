import { describe, expect, it } from "vitest";
import { compileAcl } from "../../src/mesh/acl.ts";

const compile = (dst: readonly string[], allow: readonly string[] = ["tcp:4100"]) => compileAcl({
  document: { rules: [{ src: ["device:*"], dst, allow }] },
  deviceIds: ["dev_a", "dev_b", "dev_c"], vmIds: ["vm_a"],
  rulesPerResource: 180, rulesPerMesh: 500,
});

describe("device overlay policy compilation", () => {
  it("expands device destinations without creating provider rules or self edges", () => {
    const result = compile(["device:*", "dev_b"]);
    expect(result).toMatchObject({ ok: true, rules: [] });
    if (!result.ok) return;
    expect(result).toHaveProperty("overlayRules", [
      { key: "dev_a>dev_b:tcp:4100", sourceDeviceId: "dev_a", destinationDeviceId: "dev_b", protocol: "tcp", port: 4100 },
      { key: "dev_a>dev_c:tcp:4100", sourceDeviceId: "dev_a", destinationDeviceId: "dev_c", protocol: "tcp", port: 4100 },
      { key: "dev_b>dev_a:tcp:4100", sourceDeviceId: "dev_b", destinationDeviceId: "dev_a", protocol: "tcp", port: 4100 },
      { key: "dev_b>dev_c:tcp:4100", sourceDeviceId: "dev_b", destinationDeviceId: "dev_c", protocol: "tcp", port: 4100 },
      { key: "dev_c>dev_a:tcp:4100", sourceDeviceId: "dev_c", destinationDeviceId: "dev_a", protocol: "tcp", port: 4100 },
      { key: "dev_c>dev_b:tcp:4100", sourceDeviceId: "dev_c", destinationDeviceId: "dev_b", protocol: "tcp", port: 4100 },
    ]);
  });

  it("keeps mixed VM and device rules in their enforcement plane", () => {
    const result = compile(["vm:*", "dev_b"], ["udp:53", "icmp", "*", "tcp:*"]);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.rules).toHaveLength(12);
    expect(result.rules.every((r) => r.vmId === "vm_a")).toBe(true);
    expect(result).toHaveProperty("overlayRules", expect.arrayContaining([
      expect.objectContaining({ sourceDeviceId: "dev_a", destinationDeviceId: "dev_b", protocol: "udp", port: 53 }),
      expect.objectContaining({ sourceDeviceId: "dev_c", destinationDeviceId: "dev_b", protocol: null, port: null }),
    ]));
  });

  it("rejects foreign or malformed destinations and never accepts device sources from VMs", () => {
    for (const dst of [["dev_foreign"], ["device:unknown"], ["*"], ["vm_foreign"]]) {
      expect(compile(dst)).toMatchObject({ ok: false, reason: "invalid" });
    }
    expect(compileAcl({ document: { rules: [{ src: ["vm_a"], dst: ["dev_a"], allow: ["*"] }] }, deviceIds: ["dev_a"], vmIds: ["vm_a"], rulesPerResource: 180, rulesPerMesh: 500 })).toMatchObject({ ok: false, reason: "invalid" });
  });

  it("bounds overlay expansion independently of firewall budgets, counting both directions once", () => {
    const input = {
      document: { rules: [{ src: ["device:*"], dst: ["device:*"], allow: ["tcp:4100", "tcp:4100"] }] },
      deviceIds: ["dev_a", "dev_b", "dev_c"], vmIds: [], rulesPerResource: 0, rulesPerMesh: 0,
      overlayRulesPerMesh: 6, overlayRulesPerDevice: 4,
    };
    expect(compileAcl(input)).toMatchObject({ ok: true, rules: [] });
    expect(compileAcl({ ...input, overlayRulesPerMesh: 5 })).toMatchObject({ ok: false, reason: "overlayPerMesh", count: 6 });
    expect(compileAcl({ ...input, overlayRulesPerDevice: 3 })).toMatchObject({ ok: false, reason: "overlayPerDevice", count: 4 });
    expect(compileAcl({ ...input, deviceIds: ["dev_a"], overlayRulesPerMesh: 0, overlayRulesPerDevice: 0 })).toMatchObject({ ok: true, rules: [], overlayRules: [] });
  });

  it("keeps provider address exceptions scoped to VM destinations", () => {
    const result = compileAcl({
      document: { rules: [{ src: ["dev_a"], dst: ["vm_a", "dev_b"], allow: ["tcp:4100"] }] },
      deviceIds: ["dev_a", "dev_b"], vmIds: ["vm_a"], rulesPerResource: 180, rulesPerMesh: 500,
      deviceIpv6: new Map([["dev_a", "2606:4700::1111"]]),
    });
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.rules).toHaveLength(2);
    expect(result.rules.every((r) => r.vmId === "vm_a")).toBe(true);
    expect(result.overlayRules).toHaveLength(1);
  });
});
