import { describe, expect, it } from "vitest";
import { Either, Schema } from "effect";
import { VmReceiverPolicy } from "../../src/api/mesh.ts";
import { projectVmReceivers } from "../../src/mesh/vm-receiver-policy.ts";
import type { DesiredRule } from "../../src/mesh/acl.ts";

const client = { deviceId: "device-a", wgPublicKey: "wg-a", installPublicKey: "point-a" };
const rule: DesiredRule = { key: "service", deviceId: client.deviceId, vmId: "vm-a", protocol: "tcp", port: 22, cidr: null };

describe("VM receiver projection", () => {
  it("is the reverse of the device's service projection for exactly this VM", () => {
    expect(projectVmReceivers("vm-a", [client], [rule, { ...rule, vmId: "vm-b", port: 4100 }])).toEqual([{ ...client, allow: [{ protocol: "tcp", port: 22 }] }]);
    expect(projectVmReceivers("vm-b", [client], [rule])).toEqual([]);
  });
  it("excludes public transport rules and preserves explicit wildcard services", () => {
    expect(projectVmReceivers("vm-a", [client], [{ ...rule, key: "address:from:public", cidr: "2606:4700::/128", protocol: "udp", port: 4101 }])).toEqual([]);
    expect(projectVmReceivers("vm-a", [client], [{ ...rule, protocol: null, port: null }])).toEqual([{ ...client, allow: [{ protocol: "any" }] }]);
  });
  it.each(["deviceId", "wgPublicKey", "installPublicKey"] as const)("omits every ambiguous %s", (field) => {
    const other = { deviceId: "device-b", wgPublicKey: "wg-b", installPublicKey: "point-b", [field]: client[field] };
    expect(projectVmReceivers("vm-a", [client, other], [rule])).toEqual([]);
  });
  it("requires a current install identity", () => {
    expect(projectVmReceivers("vm-a", [{ ...client, installPublicKey: null }], [rule])).toEqual([]);
  });
  it("orders identities independently of inventory insertion order", () => {
    const other = { deviceId: "device-b", wgPublicKey: "wg-b", installPublicKey: "point-b" }, rules = [rule, { ...rule, deviceId: other.deviceId }];
    expect(projectVmReceivers("vm-a", [other, client], rules)).toEqual(projectVmReceivers("vm-a", [client, other], rules));
  });
  it("decodes the versioned public contract and refuses unsupported or oversized policies", () => {
    const peer = { deviceId: `dev_${"0".repeat(26)}`, wgPublicKey: btoa("a".repeat(32)), installPublicKey: btoa(String.fromCharCode(4) + "a".repeat(64)), allow: [{ protocol: "tcp", port: 22 }] };
    const value = { schemaVersion: 1, tenantId: "team_alpha", vmId: `vm_${"0".repeat(26)}`, meshId: `mesh_${"0".repeat(26)}`, ipv4: "10.128.0.2",
      aclVersion: 1, checkedAt: 1_792_000_000_000, expiresAt: 1_792_000_030_000, policyDigest: "a".repeat(64), peers: [peer] };
    const decode = Schema.decodeUnknownEither(VmReceiverPolicy);
    expect(Either.isRight(decode(value))).toBe(true);
    expect(Either.isLeft(decode({ ...value, schemaVersion: 2 }))).toBe(true);
    expect(Either.isLeft(decode({ ...value, peers: Array.from({ length: 129 }, () => peer) }))).toBe(true);
    expect(Either.isLeft(decode({ ...value, peers: [{ ...peer, allow: Array.from({ length: 4097 }, () => ({ protocol: "tcp", port: 22 })) }] }))).toBe(true);
  });
});
