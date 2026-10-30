// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Leo 2026-10-21, after restarting the app on a chat of about 720 turns: "NOW I CAN'T SEE THE PAST
// HISTORY OF THIS CHAT." One older page failed, and the client then waited 2 s before it read
// again. An ask inside that wait resolved at once and read nothing, and the transcript, which had
// asked, did not ask again. An ask inside the wait now waits it out and reads.
import { expect, jest, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";

const CHAT = "0190a000-0000-7000-8000-0000000000e9";
const START = Date.UTC(2026, 9, 21, 9, 0, 0);
const TURNS = 300;
type Rec = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
const say = (text: string) => ({
  method: "session/update",
  params: { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
});
const history: Rec[] = Array.from({ length: TURNS }, (_, index) => {
  const n = index + 1;
  return [
    ["mux", "user_message", { text: `Question ${n}`, promptId: `p-${n}` }],
    ["mux", "turn_started", {}],
    ["in", "agent_message_chunk", say(`Answer ${n}`)],
    ["mux", "turn_result", { stopReason: "end_turn" }],
  ] as [string, string, Record<string, unknown>][];
})
  .flat()
  .map(([dir, kind, msg], index) => ({ sessionId: CHAT, seq: index + 1, at: START + index * 1000, dir, kind, msg }));
const lastSeq = history.length;

/// A daemon over a fake socket whose first transcript read fails, as a dropped connection's does.
function fakeDaemon() {
  let socket: any;
  let olderReads = 0;
  let failNext = true;
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "long chat",
    harness: "claude",
    family: "claude",
    status: "ready",
    turnCount: TURNS,
    updatedAt: START,
    lastSeq,
  };
  const before = (beforeSeq: number, limit: number, kinds?: string[]) => {
    const all = history.filter(
      (event) => event.seq < beforeSeq && (!kinds || kinds.includes("transcript") || kinds.includes(event.kind)),
    );
    const events = all.slice(-limit);
    return { events, hasMore: all.length > events.length, lastSeq };
  };
  const answer = (method: string, params: any): { result?: unknown; error?: unknown } => {
    switch (method) {
      case "initialize":
        return {
          result: { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } },
        };
      case "_acpmux/watch":
        return { result: { sessions: [session] } };
      case "_acpmux/attach":
        return { result: { session, ...before(lastSeq + 1, params?.limit ?? 400) } };
      case "_acpmux/events": {
        const kinds: string[] | undefined = params?.kinds;
        if (kinds?.includes("transcript")) {
          olderReads++;
          if (failNext) {
            failNext = false;
            return { error: { code: -32000, message: "connection reset" } };
          }
        }
        return { result: before(params?.beforeSeq ?? lastSeq + 1, params?.limit ?? 400, kinds) };
      }
      default:
        return { result: null };
    }
  };
  const open = () => {
    socket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id === undefined) return;
        queueMicrotask(() =>
          socket.onmessage?.({
            data: JSON.stringify({ jsonrpc: "2.0", id: message.id, ...answer(message.method, message.params) }),
          }),
        );
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  return { open, olderReads: () => olderReads };
}

const settle = async () => {
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0));
};

test("an older page asked for inside the back-off after a failed one still reads and moves historyFrom", async () => {
  const daemon = fakeDaemon();
  let snapshot: { canLoadOlder: boolean; historyFrom?: number } = { canLoadOlder: false };
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (next: any) => (snapshot = next),
    undefined,
    daemon.open,
  );
  await settle();
  expect(snapshot.canLoadOlder).toBe(true);
  const from = snapshot.historyFrom!;
  expect(from).toBeGreaterThan(1);

  await expect(client.loadOlder()).rejects.toThrow();
  expect(daemon.olderReads()).toBe(1);
  expect(snapshot.historyFrom).toBe(from);

  // The transcript asks again at once, inside the 2 s back-off: the ask waits it out, then reads.
  jest.useFakeTimers();
  let landed = false;
  try {
    const asked = client.loadOlder().then(() => (landed = true));
    await Promise.resolve();
    jest.advanceTimersByTime(2_100);
    jest.useRealTimers();
    await asked;
  } finally {
    jest.useRealTimers();
  }
  expect(landed).toBe(true);
  // A successful retry may fetch the bounded history batch in more than one page.
  expect(daemon.olderReads()).toBeGreaterThanOrEqual(2);
  expect(snapshot.historyFrom).toBeLessThan(from);
  client.close();
});
