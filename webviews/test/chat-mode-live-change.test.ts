// l10n-allow-file: test fixtures, not shipped UI.
// The /plan Mode chip stayed on "Ask" (Lawrence, 2026-11-20). acpmux applied the switch (the agent
// answered session/set_mode and acpmux sent `_acpmux/session_changed` kind `mode`), but its session
// row names the mode only as the top-level `currentModeId` (protocol/session.rs SessionSummary: no
// `modes`), and the page merged that row into the summary while the chips read
// `summary.modes.currentModeId`, which only a full detail read refreshed. So /plan, the + menu's Plan
// row, Toggle Plan Mode and a mode another window or the agent set never reached the chips until the
// next detail read; the Mode menu's own pick looked right only through its optimistic face.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";

const CHAT = "0190a000-0000-7000-8000-0000000000f2";
const MODES = [
  { id: "default", name: "Ask" },
  { id: "acceptEdits", name: "Accept Edits" },
  { id: "plan", name: "Plan" },
];

/// A daemon whose attach answers `detail` as acpmux's session detail (it has `modes`).
function fakeDaemon(detail: Record<string, unknown>, row: Record<string, unknown>) {
  let socket: any;
  const answer = (method: string) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [row] };
      case "_acpmux/attach":
        return { session: detail, lastSeq: 0, events: [], hasMore: false };
      case "_acpmux/events":
        return { events: [], hasMore: false, more: false, lastSeq: 0 };
      default:
        return null;
    }
  };
  const open = () => {
    socket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
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
  const notify = (method: string, params: Record<string, unknown>) =>
    socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method, params }) });
  return { open, notify };
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

async function connect() {
  let summary: any;
  // acpmux's session row (SessionSummary) names the mode at the top level and carries no `modes`.
  const row = {
    sessionId: CHAT,
    cwd: "/home/dev/app",
    title: "x",
    harness: "chipfake",
    status: "ready",
    currentModeId: "default",
  };
  const detail = { ...row, modes: { currentModeId: "default", availableModes: MODES } };
  const daemon = fakeDaemon(detail, row);
  await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: any) => (summary = snapshot.summary),
    undefined,
    daemon.open,
  );
  await settle();
  /// acpmux applied a mode: its `session_changed` carries the row with the new `currentModeId`.
  const modeChanged = async (currentModeId: string) => {
    daemon.notify("_acpmux/session_changed", {
      sessionId: CHAT,
      kind: "mode",
      recordKind: "mode",
      session: { ...row, currentModeId },
    });
    await settle();
  };
  return { shown: () => summary?.modes, modeChanged };
}

test("a mode acpmux applied reaches the chips' modes, with the modes the chat offers kept", async () => {
  const { shown, modeChanged } = await connect();
  expect(shown()?.currentModeId).toBe("default");
  await modeChanged("plan");
  expect(shown()?.currentModeId).toBe("plan");
  expect(shown()?.availableModes.map((mode: { id: string }) => mode.id)).toEqual(["default", "acceptEdits", "plan"]);
  await modeChanged("default");
  expect(shown()?.currentModeId).toBe("default");
});
