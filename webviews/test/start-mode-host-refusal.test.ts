// A new workspace's New Tab page asks `_acpmux/start_mode` for its folder (the home folder), and the
// pane's host refuses to relay it (`transport.path_outside_roots`): acpmux never saw the ask. That is
// no answer, so the kept one stays (startMode.ts), not "acpmux sets no mode", which turned the Mode
// chip to a bare "Mode" in every new workspace (2026-10-24). acpmux's own refusal still means none.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { AcpmuxRpcError } from "../src/agent-session/acpmux/handoff/protocol";

function clientRefusing(error: AcpmuxRpcError): AcpmuxDirectClient {
  const client = Object.create(AcpmuxDirectClient.prototype) as AcpmuxDirectClient;
  (client as unknown as { request: () => Promise<unknown> }).request = async () => {
    throw error;
  };
  return client;
}

test("the host's refusal to relay the ask is no answer", async () => {
  const client = clientRefusing(
    new AcpmuxRpcError({
      code: -32601,
      message: "Refused by the cmux host",
      data: { origin: "native", code: "transport.path_outside_roots", method: "_acpmux/start_mode" },
    }),
  );
  await expect(client.startMode("claude", "/Users/dev")).rejects.toBeInstanceOf(AcpmuxRpcError);
});

test("acpmux's own refusal still means it sets no mode", async () => {
  const client = clientRefusing(new AcpmuxRpcError({ code: -32602, message: "unknown harness" }));
  expect(await client.startMode("nope", "/Users/dev/project")).toBeUndefined();
});
