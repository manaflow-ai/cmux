import { describe, expect, test } from "bun:test";
import type { Freestyle } from "freestyle";
import { FreestyleProvider } from "../services/vms/drivers/freestyle";

describe("Freestyle private network readiness", () => {
  test("create prepares the guest network before publishing its private addresses", async () => {
    const events: string[] = [];
    const data = {
      id: "vm-network-test", state: "running", snapshotId: "sh-fixture",
      resources: { cpu: 64, memory: 131072, storage: 1048576 },
      vpcs: [{ ipv4: "10.16.0.2", ipv6: "fd00::2" }],
    };
    const vm = {
      exec: async () => { events.push("guest-network"); return { statusCode: 0, stdout: "", stderr: "" }; },
      delete: async () => { events.push("delete"); },
    };
    const client = { vms: {
      create: async () => { events.push("allocated"); return { vm, vmId: data.id, data }; },
      get: async () => data,
    } } as unknown as Freestyle;
    const provider = new FreestyleProvider({
      client: () => client,
      resolveDaemonSource: async () => { throw new Error("No daemon install is needed"); },
    });

    await provider.create({ image: "sh-fixture", network: { id: "vpc-fixture" } });
    events.push("published");

    expect(events).toEqual(["allocated", "guest-network", "published"]);
  });
});
