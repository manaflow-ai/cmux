import { describe, expect, it } from "vitest";
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
});
