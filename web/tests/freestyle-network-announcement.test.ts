import { describe, expect, test } from "bun:test";
import type { Freestyle } from "freestyle";
import { FreestyleProvider } from "../services/vms/drivers/freestyle";

describe("Freestyle private network allocation", () => {
  test("create requests both private address families and publishes provider-assigned addresses", async () => {
    const requests: unknown[] = [];
    const data = {
      id: "vm-network-test", state: "running", snapshotId: "sh-fixture",
      resources: { cpu: 64, memory: 131072, storage: 1048576 },
      vpcs: [{ ipv4: "10.16.0.2", ipv6: "fd00::2" }],
    };
    const vm = {
      // The image owns guest network setup; create must not introduce a
      // second bootstrap path through provider exec.
      exec: async () => { throw new Error("Create must use the baked guest configuration"); },
      delete: async () => {},
    };
    const client = { vms: {
      create: async (options: unknown) => { requests.push(options); return { vm, vmId: data.id, data }; },
      get: async () => data,
    } } as unknown as Freestyle;
    const provider = new FreestyleProvider({
      client: () => client,
      resolveDaemonSource: async () => { throw new Error("No daemon install is needed"); },
    });

    const handle = await provider.create({ image: "sh-fixture", network: { id: "vpc-fixture" } });

    expect(requests).toHaveLength(1);
    expect(requests[0]).toMatchObject({
      vpcs: [{ vpcId: "vpc-fixture", ipv4: true, ipv6: true }],
    });
    expect(handle.providerVmId).toBe(data.id);
    expect(handle.providerMetadata).toEqual({
      networkId: "vpc-fixture",
      networkIpv4: "10.16.0.2",
      networkIpv6: "fd00::2",
    });
  });
});
