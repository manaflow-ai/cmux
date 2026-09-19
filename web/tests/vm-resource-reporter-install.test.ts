import { describe, expect, test } from "bun:test";
import type { Freestyle } from "freestyle";
import { FreestyleProvider } from "../services/vms/drivers/freestyle";

function fixture(cliFails = false) {
  const deleted: string[] = [];
  const commands: string[] = [];
  const vmId = "vm-resource-reporter-test";
  const data = { id: vmId, state: "running", snapshotId: "sh-test", publicIpv6: "2602:f75c:0:1::2a",
    resources: { cpu: 64, memory: 131072, storage: 1048576 }, vpcs: [{ ipv4: "10.16.0.2", ipv6: "fd00::2" }] };
  const vm = {
    exec: async ({ command }: { command: string }) => {
      commands.push(command);
      const fails = command.includes("cmux-resource-stats.service") || (cliFails && command.includes("mv -f"));
      return { statusCode: fails ? 1 : 0, stdout: "", stderr: fails ? "systemd unavailable" : "" };
    },
    fs: { writeTextFile: async () => {}, remove: async () => {} },
    delete: async () => { deleted.push(vmId); },
  };
  const client = { vms: { create: async () => ({ vm, vmId, data }), get: async () => data } } as unknown as Freestyle;
  const provider = new FreestyleProvider({ client: () => client, resolveDaemonSource: async () => { throw new Error("No daemon install expected"); } });
  return { provider, deleted, commands };
}

describe("advisory resource reporter installation", () => {
  test.each(["create", "restore"])("reporter failure does not roll back %s", async (operation) => {
    const { provider, deleted, commands } = fixture();
    const network = { id: "vpc-resource-test" };
    const handle = operation === "create" ? await provider.create({ image: "sh-test", network }) : await provider.restore("sh-test", { network });
    expect(handle.providerVmId).toBe("vm-resource-reporter-test");
    expect(commands.some(command => command.includes("cmux-resource-stats.service"))).toBe(true);
    expect(deleted).toEqual([]);
  });

  test("required CLI installation failure still rolls back the allocated machine", async () => {
    const { provider, deleted } = fixture(true);
    await expect(provider.create({ image: "sh-test" })).rejects.toThrow();
    expect(deleted).toEqual(["vm-resource-reporter-test"]);
  });
});
