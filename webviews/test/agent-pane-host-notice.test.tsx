// l10n-allow-file: test fixture notice text, not shipped UI.
// cmux Cloud resizes a machine and tells its chats with one line (`acpmux machine notice --text`):
// acpmux appends a mux `host_notice` record to every live chat (server/host_notice.rs), and the
// pane draws it as a muted notice row where it happened.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const CHAT = "0190a000-0000-7000-8000-0000000000e4";
const START = Date.UTC(2026, 9, 21, 9, 0, 0);
type Step = [dir: string, kind: string, msg: Record<string, unknown>];
const record = (steps: Step[], from = 1) =>
  steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: from + index,
    at: START + (from + index) * 1000,
    dir,
    kind,
    msg,
  }));
type Recorded = ReturnType<typeof record>[number];

/// A daemon over a fake socket for a chat on `harness`: attach answers with `history`; `push`
/// sends live events.
function fakeDaemon(history: Recorded[], harness: string, family: string) {
  let socket: any;
  const session = { sessionId: CHAT, cwd: "/Users/dev/app", title: "x", harness, family, status: "idle" };
  const lastSeq = () => history.at(-1)?.seq ?? 0;
  const answer = (method: string) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: lastSeq(), events: history, hasMore: false };
      case "_acpmux/events":
        return { events: [], hasMore: false, more: false, lastSeq: lastSeq() };
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
  const push = (events: Recorded[]) => {
    for (const event of events) {
      history.push(event);
      socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }) });
    }
  };
  return { open, push };
}

/// Yields until `ready()` holds; fails after 2 s with what it waited for.
async function until(ready: () => boolean, what: string) {
  const deadline = performance.now() + 2_000;
  while (!ready()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}

async function connect(daemon: ReturnType<typeof fakeDaemon>) {
  let snapshot: any;
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (next: any) => (snapshot = next),
    undefined,
    daemon.open,
  );
  await until(() => snapshot?.connection === "connected", "the attach");
  const notes = () =>
    (snapshot.rows as AcpmuxRow[])
      .filter((row) => row.id.startsWith("host-notice-"))
      .map((row) => ({ id: row.id, kind: row.kind, text: row.text }));
  return { client, notes };
}

const GREW = "Machine grew to 4 vCPU / 8 GiB (it ran out of memory)";

test("a host notice is a muted notice row where acpmux logged it", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "build it" }],
      ["mux", "host_notice", { text: GREW, source: "cloud" }],
    ]),
    "claude",
    "claude",
  );
  const { client, notes } = await connect(daemon);
  try {
    expect(notes()).toEqual([{ id: "host-notice-2", kind: "notice", text: GREW }]);
    // One that comes live gets its own row; an empty one draws nothing.
    daemon.push(
      record(
        [
          ["mux", "host_notice", { text: "  ", source: "cloud" }],
          ["mux", "host_notice", { text: "Machine shrank to 2 vCPU / 4 GiB", source: "cloud" }],
        ],
        3,
      ),
    );
    await until(() => notes().length === 2, "the live notice");
    expect(notes()[1]).toEqual({ id: "host-notice-4", kind: "notice", text: "Machine shrank to 2 vCPU / 4 GiB" });
  } finally {
    client.close();
  }
});
