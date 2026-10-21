// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Leo 2026-10-20 (cosmic-gray): after acpmux and the app restarted, the coordinator's chat "can't
// scroll up anymore to see more of the history". acpmux still held the whole log and paged it back
// to seq 2, but a long chat holds prompts queued with big pastes or images (`queued`, up to 4 MB):
// acpmux ends an older page at maxBytes, so such a record comes back as a page of its own, and a
// page of records that open no turn draws no row. The transcript's near-top loader asks once per
// first row (App.tsx olderLoadKey), so with no new first row it never asked again and the reader
// stopped at that page. Each older page the pane reads must bring an older turn in.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const CHAT = "0190a000-0000-7000-8000-0000000000d7";
const START = Date.UTC(2026, 9, 20, 9, 0, 0);
type Step = [dir: string, kind: string, msg: Record<string, unknown>];
const say = (text: string) => ({
  method: "session/update",
  params: { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
});
const turn = (n: number): Step[] => [
  ["mux", "user_message", { text: `Question ${n}`, promptId: `p-${n}` }],
  ["mux", "turn_started", {}],
  ["in", "agent_message_chunk", say(`Answer ${n}`)],
  ["mux", "turn_result", { stopReason: "end_turn" }],
];
// Turn 4 was queued behind turn 3 with a 300 KB paste: more than one older page (256 KB) holds.
const steps: Step[] = [
  ...turn(1),
  ...turn(2),
  ...turn(3).slice(0, 3),
  ["mux", "queued", { promptId: "p-4", text: "x".repeat(300 * 1024) }],
  turn(3)[3]!,
  ["mux", "dequeued", { promptId: "p-4" }],
  ...turn(4),
  ...turn(5),
  ...turn(6),
];
const history = steps.map(([dir, kind, msg], index) => ({
  sessionId: CHAT,
  seq: index + 1,
  at: START + index * 1000,
  dir,
  kind,
  msg,
}));
type Rec = (typeof history)[number];
const lastSeq = history.length;

/// acpmux's `events_page` (hub/paging.rs): the newest records before `beforeSeq`, ending before
/// their JSON passes `maxBytes`, and always at least one record.
function newestPage(beforeSeq: number, limit: number, maxBytes: number | undefined) {
  const events: Rec[] = [];
  let bytes = 0;
  let hasMore = false;
  for (const event of history.filter((e) => e.seq < beforeSeq).reverse()) {
    if (events.length === limit) {
      hasMore = true;
      break;
    }
    bytes += JSON.stringify(event.msg).length + event.kind.length + 120;
    if (maxBytes !== undefined && events.length > 0 && bytes > maxBytes) {
      hasMore = true;
      break;
    }
    events.push(event);
  }
  return { events: events.reverse(), hasMore, lastSeq };
}

function fakeDaemon() {
  let socket: any;
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "coordinator",
    harness: "claude",
    family: "claude",
    status: "ready",
    turnCount: 6,
    updatedAt: START,
    lastSeq,
  };
  const answer = (method: string, params: any) => {
    switch (method) {
      case "initialize":
        return {
          protocolVersion: 1,
          _meta: { acpmux: { origin: "local", extensions: [], operations: [] } },
        };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, ...newestPage(lastSeq + 1, params?.limit ?? 2000, params?.maxBytes) };
      case "_acpmux/events": {
        const kinds: unknown = params?.kinds;
        if (Array.isArray(kinds) && !kinds.includes("transcript")) {
          const before = params?.beforeSeq ?? Infinity;
          const all = history.filter((e) => e.seq < before && kinds.includes(e.kind));
          const events = all.slice(-(params?.limit ?? 5000));
          return { events, hasMore: all.length > events.length, lastSeq };
        }
        return newestPage(params?.beforeSeq ?? lastSeq + 1, params?.limit ?? 5000, params?.maxBytes);
      }
      default:
        return null;
    }
  };
  return () => {
    socket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id === undefined) return;
        queueMicrotask(() =>
          socket.onmessage?.({
            data: JSON.stringify({
              jsonrpc: "2.0",
              id: message.id,
              result: answer(message.method, message.params),
            }),
          }),
        );
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
}

const settle = async () => {
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0));
};
const questions = (rows: AcpmuxRow[]) => rows.filter((row) => row.kind === "user").map((row) => row.text);

test("every older page the reader asks for brings an older turn in, past a prompt queued with a big paste", async () => {
  let snapshot: { rows: AcpmuxRow[]; canLoadOlder: boolean } = { rows: [], canLoadOlder: false };
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://127.0.0.1:1/",
      token: "t",
      sessionId: CHAT,
    },
    (next: any) => (snapshot = next),
    undefined,
    fakeDaemon(),
  );
  await settle();
  // The chat opens on its tail: the open page ends at the big queued prompt, in turn 3 (whose
  // prompt the pane reads on its own, direct.ts fetchTurnOpener).
  expect(questions(snapshot.rows)).toEqual(["Question 3", "Question 4", "Question 5", "Question 6"]);
  expect(snapshot.canLoadOlder).toBe(true);

  // The pane asks again only when its first row changes (App.tsx olderLoadKey): each ask must
  // bring an older turn above it, or the reader is stuck at the top of what loaded.
  for (let asks = 0; snapshot.canLoadOlder && asks < 10; asks++) {
    const first = snapshot.rows[0]?.id;
    await client.loadOlder();
    await settle();
    if (snapshot.canLoadOlder) expect(snapshot.rows[0]?.id).not.toBe(first);
  }
  expect(questions(snapshot.rows)).toEqual([1, 2, 3, 4, 5, 6].map((n) => `Question ${n}`));
  expect(snapshot.canLoadOlder).toBe(false);
  client.close();
});
