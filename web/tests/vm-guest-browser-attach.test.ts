import { expect, test } from "bun:test";
import type { Freestyle } from "freestyle";
import { FreestyleProvider } from "../services/vms/drivers/freestyle";

test("snapshot-v2 attach does not install browser integration or run guest healing", async () => {
  const commands: string[] = [];
  const vm = {
    exec: async ({ command }: { command: string }) => {
      commands.push(command);
      return { statusCode: 0, stdout: "", stderr: "" };
    },
  };
  const client = { vms: { ref: () => vm } } as unknown as Freestyle;
  const provider = new FreestyleProvider({ client: () => client });
  const result = await provider.openCmuxRemote("vm-browser-attach", {
    providerMetadata: { cmuxTuiContract: "snapshot-v2", networkIpv4: "10.4.0.7", networkIpv6: "fd00:4::7" },
  });
  expect(result).toMatchObject({ route: "ws://10.4.0.7:1337/v1/link", trustedCarrier: true });
  expect(commands).toEqual([]);
});
