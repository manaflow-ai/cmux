// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Leo 2026-10-20 (cosmic-gray): after acpmux and the app restarted, the coordinator's chat "can't
// scroll up anymore to see more of the history". acpmux still held the whole log and paged it back
// to seq 2, but a long chat holds prompts queued with big pastes or images (`queued`, up to 4 MB):
// acpmux ends an older page at maxBytes, so such a record comes back as a page of its own, and a
// page of records that open no turn draws no row. The transcript's near-top loader asked once per
// first row (App.tsx olderLoadKey), so with no new first row it never asked again and the reader
// stopped at that page. The loader asks again whenever the first row or the oldest held event
// (`historyFrom`) moves; these tests ask the way it does and check the whole chat comes back.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const CHAT = "0190a000-0000-7000-8000-0000000000d7";
const START = Date.UTC(2026, 9, 20, 9, 0, 0);
type Step = [dir: string, kind: string, msg: Record<string, unknown>];
type Rec = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
const say = (text: string) => ({
  method: "session/update",
  params: { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
});
const ask = (n: number): Step[] => [
  ["mux", "user_message", { text: `Question ${n}`, promptId: `p-${n}` }],
  ["mux", "turn_started", {}],
];
const done: Step = ["mux", "turn_result", { stopReason: "end_turn" }];
const turn = (n: number): Step[] => [...ask(n), ["in", "agent_message_chunk", say(`Answer ${n}`)], done];
const queued = (id: string, kb: number): Step => ["mux", "queued", { promptId: id, text: "x".repeat(kb * 1024) }];
const records = (steps: Step[]): Rec[] =>
  steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: index + 1,
    at: START + index * 1000,
    dir,
    kind,
    msg,
  }));

/// acpmux's `events_page` (hub/paging.rs): the newest records before `beforeSeq`, ending before
/// their JSON passes `maxBytes`, and always at least one record.
function newestPage(history: Rec[], beforeSeq: number, limit: number, maxBytes: number | undefined) {
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
  return { events: events.reverse(), hasMore, lastSeq: history.length };
}

function fakeDaemon(history: Rec[]) {
  let socket: any;
  let olderReads = 0;
  const lastSeq = history.length;
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
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, ...newestPage(history, lastSeq + 1, params?.limit ?? 2000, params?.maxBytes) };
      case "_acpmux/events": {
        const kinds: unknown = params?.kinds;
        if (Array.isArray(kinds) && !kinds.includes("transcript")) {
          const before = params?.beforeSeq ?? Infinity;
          const all = history.filter((e) => e.seq < before && kinds.includes(e.kind));
          const events = all.slice(-(params?.limit ?? 5000));
          return { events, hasMore: all.length > events.length, lastSeq };
        }
        olderReads++;
        return newestPage(history, params?.beforeSeq ?? lastSeq + 1, params?.limit ?? 5000, params?.maxBytes);
      }
      default:
        return null;
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
            data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params) }),
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
const questions = (rows: AcpmuxRow[]) => rows.filter((row) => row.kind === "user").map((row) => row.text);
type Snapshot = { rows: AcpmuxRow[]; canLoadOlder: boolean; historyFrom?: number };

async function open(history: Rec[]) {
  const daemon = fakeDaemon(history);
  let snapshot: Snapshot = { rows: [], canLoadOlder: false };
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (next: any) => (snapshot = next),
    undefined,
    daemon.open,
  );
  await settle();
  return { client, daemon, snapshot: () => snapshot };
}

/// Scrolls to the top the way App.tsx's loader does: it asks once per (first row, historyFrom), so
/// an ask that moves neither is the last one the reader gets. Returns how many asks it took.
async function scrollToTop(client: AcpmuxDirectClient, snapshot: () => Snapshot): Promise<number> {
  let asks = 0;
  for (; snapshot().canLoadOlder && asks < 40; asks++) {
    const key = `${snapshot().rows[0]?.id}\u0000${snapshot().historyFrom}`;
    await client.loadOlder();
    await settle();
    expect(`${snapshot().rows[0]?.id}\u0000${snapshot().historyFrom}`).not.toBe(key);
  }
  return asks;
}

test("every older page the reader asks for brings an older turn in, past a prompt queued with a big paste", async () => {
  // Turn 4 was queued behind turn 3 with a 300 KB paste: more than one older page (256 KB) holds.
  const history = records([
    ...turn(1),
    ...turn(2),
    ...turn(3).slice(0, 3),
    queued("p-4", 300),
    done,
    ["mux", "dequeued", { promptId: "p-4" }],
    ...turn(4),
    ...turn(5),
    ...turn(6),
  ]);
  const { client, snapshot } = await open(history);
  // The chat opens on its tail: the open page ends at the big queued prompt, in turn 3 (whose
  // prompt the pane reads on its own, direct.ts fetchTurnOpener).
  expect(questions(snapshot().rows)).toEqual(["Question 3", "Question 4", "Question 5", "Question 6"]);
  expect(snapshot().canLoadOlder).toBe(true);

  // Each ask brings an older turn above the first row.
  for (let asks = 0; snapshot().canLoadOlder && asks < 10; asks++) {
    const first = snapshot().rows[0]?.id;
    await client.loadOlder();
    await settle();
    expect(snapshot().rows[0]?.id).not.toBe(first);
  }
  expect(questions(snapshot().rows)).toEqual([1, 2, 3, 4, 5, 6].map((n) => `Question ${n}`));
  expect(snapshot().canLoadOlder).toBe(false);
  client.close();
});

test("a chat that opens mid-turn pages past a turn before it larger than an older page", async () => {
  // Turn 2 wrote 400 KB, so the page that ends at turn 3's prompt does not reach turn 2's; turn 3
  // outgrew the open page (128 KB), so the pane opens inside it and draws its prompt first.
  const history = records([
    ...turn(1),
    ...ask(2),
    ...[1, 2, 3, 4].map((n): Step => ["in", "agent_message_chunk", say(`${n}`.repeat(100 * 1024))]),
    done,
    ...ask(3),
    ...[1, 2, 3, 4, 5].map((n): Step => ["in", "agent_message_chunk", say(`${n}`.repeat(40 * 1024))]),
  ]);
  const { client, snapshot } = await open(history);
  expect(questions(snapshot().rows)).toEqual(["Question 3"]);
  expect(snapshot().canLoadOlder).toBe(true);

  for (let asks = 0; snapshot().canLoadOlder && asks < 10; asks++) {
    const first = snapshot().rows[0]?.id;
    await client.loadOlder();
    await settle();
    expect(snapshot().rows[0]?.id).not.toBe(first);
  }
  expect(questions(snapshot().rows)).toEqual(["Question 1", "Question 2", "Question 3"]);
  client.close();
});

test("one ask reads past a run of rows that draw nothing to the turn before it, in a bounded number of pages", async () => {
  // Twelve prompts queued with 300 KB pastes in a row: twelve pages that draw no row. One ask reads on past them
  // (direct.ts OLDER_PAGES_PER_ASK) instead of stopping after eight with nothing new to draw.
  const history = records([
    ...turn(1),
    ...ask(2),
    ...Array.from({ length: 12 }, (_, i) => queued(`q-${i}`, 300)),
    ["in", "agent_message_chunk", say("Answer 2")],
    done,
    ...turn(3),
  ]);
  const { client, daemon, snapshot } = await open(history);
  const before = daemon.olderReads();
  await client.loadOlder();
  await settle();
  expect(daemon.olderReads() - before).toBeGreaterThan(8);
  expect(daemon.olderReads() - before).toBeLessThanOrEqual(128);
  expect(questions(snapshot().rows)).toContain("Question 2");

  await scrollToTop(client, snapshot);
  expect(questions(snapshot().rows)).toEqual(["Question 1", "Question 2", "Question 3"]);
  expect(snapshot().canLoadOlder).toBe(false);
  client.close();
});

test("history whose very first record is larger than an older page loads to the top and stops", async () => {
  // The chat's first prompt carried a 600 KB paste: the oldest page is that one record alone.
  const big = `Question 1 ${"x".repeat(600 * 1024)}`;
  const history = records([
    ["mux", "user_message", { text: big, promptId: "p-1" }],
    ["mux", "turn_started", {}],
    ["in", "agent_message_chunk", say("Answer 1")],
    done,
    ...turn(2),
    ...turn(3),
  ]);
  const { client, snapshot } = await open(history);
  await scrollToTop(client, snapshot);
  expect(questions(snapshot().rows)).toEqual([big, "Question 2", "Question 3"]);
  expect(snapshot().canLoadOlder).toBe(false);
  client.close();
});

test("an oversized record that draws no row at the very top still ends the history", async () => {
  // A 600 KB prompt was queued and dropped before the first turn: the oldest page draws nothing.
  const history = records([queued("q-0", 600), ["mux", "dequeued", { promptId: "q-0" }], ...turn(1), ...turn(2)]);
  const { client, snapshot } = await open(history);
  const asks = await scrollToTop(client, snapshot);
  expect(asks).toBeLessThan(40);
  expect(questions(snapshot().rows)).toEqual(["Question 1", "Question 2"]);
  expect(snapshot().canLoadOlder).toBe(false);
  client.close();
});
