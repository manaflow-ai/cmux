// l10n-allow-file: test fixtures, not shipped UI.
// Leo 2026-10-18: the first New Tab after launch drew no access chip. Its chat's folder is the home
// folder no pick has granted yet, so the host refused `_acpmux/start_mode` for it
// (transport.path_outside_roots) and the chip had no answer to draw. A folder's own profile can
// only apply once the folder is granted; until then the chip names acpmux's answer for the harness.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";

const CHAT = "0190a000-0000-7000-8000-0000000000c3";

function fakeDaemon() {
  let socket: any;
  const asked: Record<string, unknown>[] = [];
  const reply = (message: any) => {
    const params = message.params ?? {};
    if (message.method === "_acpmux/start_mode") {
      asked.push(params);
      if (params.cwd)
        return {
          error: {
            code: -32601,
            message: "Refused by the cmux host",
            data: { code: "transport.path_outside_roots", origin: "native", method: "_acpmux/start_mode" },
          },
        };
      return { result: { modeId: "bypassPermissions", name: "Full access" } };
    }
    switch (message.method) {
      case "initialize":
        return {
          result: { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } },
        };
      case "_acpmux/watch":
        return { result: { sessions: [] } };
      default:
        return { result: null };
    }
  };
  const open = () => {
    socket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id !== undefined)
          queueMicrotask(() =>
            socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, ...reply(message) }) }),
          );
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  return { open, asked };
}

test("a folder the host has not granted yet gets the harness's start mode", async () => {
  const daemon = fakeDaemon();
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    () => undefined,
    undefined,
    daemon.open,
  );
  expect(await client.startMode("claude", "/Users/dev")).toEqual({ modeId: "bypassPermissions", name: "Full access" });
  expect(daemon.asked).toEqual([{ harness: "claude", cwd: "/Users/dev" }, { harness: "claude" }]);
});
