import { describe, expect, test } from "bun:test";
import type { Freestyle } from "freestyle";
import { FreestyleProvider } from "../services/vms/drivers/freestyle";

function fixture() {
  const commands: string[] = [];
  const writes: string[] = [];
  const data = { id: "vm-snapshot-contract", state: "running", snapshotId: "sh-snapshot-v2", publicIpv6: "2602:f75c:0:1::2a", resources: { cpu: 8, memory: 16384, storage: 65536 }, vpcs: [{ ipv4: "10.16.0.2", ipv6: "fd00::2" }] };
  const vm = { exec: async ({ command }: { command: string }) => { commands.push(command); return { statusCode: 0, stdout: "", stderr: "" }; }, fs: { writeTextFile: async (path: string) => { writes.push(path); }, remove: async () => {} }, delete: async () => {} };
  const client = { vms: { create: async () => ({ vm, vmId: data.id, data }) } } as unknown as Freestyle;
  return { provider: new FreestyleProvider({ client: () => client }), commands, writes };
}

describe("snapshot-v2 guest contract", () => {
  test.each(["create", "restore"])("does not install guest assets during %s", async (operation) => {
    const { provider, commands, writes } = fixture();
    const result = operation === "create" ? await provider.create({ image: "sh-snapshot-v2", imageSize: { name: "md", cpu: 8, memoryMb: 16384, storageMb: 65536 }, network: { id: "vpc-snapshot" } }) : await provider.restore("sh-snapshot-v2", { network: { id: "vpc-snapshot" } });
    expect(result.providerMetadata).toMatchObject({ cmuxTuiContract: "snapshot-v2" });
    expect(commands).toEqual([]);
    expect(writes).toEqual([]);
  });
});
