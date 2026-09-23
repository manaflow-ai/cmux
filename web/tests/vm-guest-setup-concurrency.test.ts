import { expect, test } from "bun:test";
import type { Freestyle } from "freestyle";
import { FreestyleProvider } from "../services/vms/drivers/freestyle";

const VM_ID = "vm-fixture";
const NETWORK = { vpcs: [{ ipv4: "10.4.0.7", ipv6: "fd00:4::7" }] };

function fixture() {
  const commands: string[] = [];
  const writes: string[] = [];
  const vm = {
    data: async () => NETWORK,
    exec: async ({ command }: { command: string }) => {
      commands.push(command);
      return { statusCode: 0, stdout: "", stderr: "" };
    },
    fs: { writeTextFile: async (path: string) => { writes.push(path); }, remove: async () => {} },
    delete: async () => {},
  };
  const client = {
    vms: {
      create: async () => ({ vm, vmId: VM_ID, data: { ...NETWORK, publicIpv6: "2602:f75c:0:1::2a" } }),
      ref: () => vm,
    },
  } as unknown as Freestyle;
  const provider = new FreestyleProvider({
    client: () => client,
  });
  return { provider, commands, writes };
}

test("snapshot-v2 create has no guest setup or resize phase", async () => {
  const f = fixture();
  const result = await f.provider.create({ image: "sh-snapshot-v2", network: { id: "vpc-fixture" } });
  expect(result.providerMetadata).toMatchObject({ cmuxTuiContract: "snapshot-v2" });
  expect(f.commands).toEqual([]);
  expect(f.writes).toEqual([]);
});

test("snapshot-v2 attach is a persisted-route read with no healing calls", async () => {
  const f = fixture();
  const result = await f.provider.openCmuxRemote(VM_ID, {
    providerMetadata: { cmuxTuiContract: "snapshot-v2", networkIpv4: "10.4.0.7", networkIpv6: "fd00:4::7" },
  });
  expect(result.route).toBe("ws://10.4.0.7:1337/v1/link");
  expect(result.trustedCarrier).toBe(true);
  expect(f.commands).toEqual([]);
  expect(f.writes).toEqual([]);
});
