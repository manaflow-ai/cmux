// l10n-allow-file: test fixtures, not shipped UI.
// A connection's first frame is its initialize: the relay carries the LocalApp token in it and
// closes a connection whose first frame is anything else (cmux-agent-pane-policy check.rs). The
// action trace's `_acpmux/trace/status` question went out at the socket's open, ahead of the
// initialize, so the page connected without its token (the Sol picks-hold browser test's New Tab
// on the wrong harness).
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";

const CHAT = "0190a000-0000-7000-8000-0000000000f1";

test("the initialize is the connection's first frame, and the trace asks after it", async () => {
  const methods: string[] = [];
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness: "codex",
    family: "codex",
    status: "ready",
    turnCount: 0,
    updatedAt: 0,
  };
  const answer = (method: string) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: 0, events: [], hasMore: false };
      case "_acpmux/events":
        return { events: [], hasMore: false, more: false, lastSeq: 0 };
      case "_acpmux/trace/status":
        return { enabled: false, now_us: 0 };
      default:
        return null;
    }
  };
  const open = () => {
    const socket: any = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (typeof message.method === "string") methods.push(message.method);
        if (message.id !== undefined)
          queueMicrotask(() =>
            socket.onmessage?.({
              data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }),
            }),
          );
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    () => {},
    undefined,
    open,
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(methods[0]).toBe("initialize");
  expect(methods).toContain("_acpmux/trace/status");
});
