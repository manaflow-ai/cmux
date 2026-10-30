// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A Claude Code chat adopted or watched in cmux shows its transcript's newest page at once
// (acpmux adopt_replay_page.rs): the log is seeded with that page and a `native_history` record
// naming where the transcript's older turns end. Once the pane has paged the log back to its first
// record, it pages those older turns in from the transcript (`_acpmux/native_history`), above the
// seeded ones, until acpmux says there are none. Before, the chat's history stopped at the seeded
// page: everything older in the transcript was never shown (Leo 2026-10-29: "i also like the way it
// just loads in the subagent stuff instantly :(").
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";

const CHAT = "0190a000-0000-7000-8000-0000000000f7";
const START = Date.UTC(2026, 9, 29, 9, 0, 0);
type Rec = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
type Step = [dir: string, kind: string, msg: Record<string, unknown>];
const say = (text: string) => ({
  method: "session/update",
  params: { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
});
/// A turn as acpmux logs an adopted one (hub/native_history.rs turn_records).
const turn = (n: number): Step[] => [
  ["mux", "turn_started", { prompt: `Question ${n}`, turnId: `t-${n}` }],
  ["mux", "user_message", { text: `Question ${n}`, client: "adopt", turnId: `t-${n}` }],
  ["in", "agent_message_chunk", say(`Answer ${n}`)],
  ["mux", "turn_end", { stopReason: "end_turn", turnId: `t-${n}` }],
  ["mux", "turn_result", { status: "completed", stopReason: "end_turn", turnId: `t-${n}` }],
];
/// acpmux's seq for the `k`th record of the native page that ends at `before` (`native_seq`).
const nativeSeq = (before: number, k: number) => before * 2 ** 18 + k - 2 ** 52;

/// The transcript: turns 1-9; the log holds 7-9, seeded, after its own bookkeeping.
const SEEDED_BEFORE = 9_000;
const PAGES: Record<number, { turns: number[]; before: number }> = {
  [SEEDED_BEFORE]: { turns: [4, 5, 6], before: 4_000 },
  4_000: { turns: [1, 2, 3], before: 0 },
};
const log: Rec[] = (
  [
    ["mux", "created", { harness: "claude" }],
    ["mux", "adopted", { agentSessionId: "s1" }],
    ["mux", "native_history", { family: "claude", before: SEEDED_BEFORE, turns: 3 }],
    ...[7, 8, 9].flatMap(turn),
  ] as Step[]
).map(([dir, kind, msg], index) => ({ sessionId: CHAT, seq: index + 1, at: START + index * 1000, dir, kind, msg }));
const lastSeq = log.length;

function nativePage(before: number) {
  const page = PAGES[before];
  if (!page) return { events: [], before: 0, turns: 0 };
  const events = page.turns.flatMap(turn).map(([dir, kind, msg], k) => ({
    sessionId: CHAT,
    seq: nativeSeq(before, k),
    at: START - 100_000 + k,
    dir,
    kind,
    msg,
  }));
  return { events, before: page.before, turns: page.turns.length };
}

/// A daemon over a fake socket; `serves` says whether it lists `_acpmux/native_history`, and
/// `unknown` makes it answer that method as one it does not serve (an older peer's daemon).
function fakeDaemon({ serves = true, unknown = false } = {}) {
  let socket: any;
  const nativeReads: number[] = [];
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "adopted chat",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 3,
    updatedAt: START,
    lastSeq,
  };
  const answer = (method: string, params: any): { result?: unknown; error?: unknown } => {
    switch (method) {
      case "initialize":
        return {
          result: {
            protocolVersion: 1,
            _meta: {
              acpmux: { origin: "local", extensions: serves ? ["_acpmux/native_history"] : [], operations: [] },
            },
          },
        };
      case "_acpmux/watch":
        return { result: { sessions: [session] } };
      case "_acpmux/attach":
        return { result: { session, events: log, hasMore: false, lastSeq } };
      case "_acpmux/events":
        return { result: { events: [], hasMore: false, lastSeq } };
      case "_acpmux/native_history":
        nativeReads.push(params.before);
        if (unknown) return { error: { code: -32601, message: "Method not found" } };
        return { result: nativePage(params.before) };
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
  return { open, nativeReads };
}

const settle = async () => {
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0));
};

type Snapshot = { canLoadOlder: boolean; historyFrom?: number; rows: { kind: string; text?: string }[] };

async function open(daemon: ReturnType<typeof fakeDaemon>) {
  let snapshot: Snapshot = { canLoadOlder: false, rows: [] };
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (next: any) => (snapshot = next),
    undefined,
    daemon.open,
  );
  await settle();
  const prompts = () => snapshot.rows.filter((row) => row.kind === "user").map((row) => row.text);
  return { client, snapshot: () => snapshot, prompts };
}

const questions = (...ns: number[]) => ns.map((n) => `Question ${n}`);

test("an adopted chat pages its transcript's older turns in above the seeded ones, each once", async () => {
  const daemon = fakeDaemon();
  const { client, snapshot, prompts } = await open(daemon);
  expect(prompts()).toEqual(questions(7, 8, 9));
  // The log's own history is all held, and the transcript has more.
  expect(snapshot().canLoadOlder).toBe(true);

  await client.loadOlder();
  expect(daemon.nativeReads).toEqual([SEEDED_BEFORE]);
  expect(prompts()).toEqual(questions(4, 5, 6, 7, 8, 9));
  expect(snapshot().historyFrom).toBe(nativeSeq(SEEDED_BEFORE, 0));
  expect(snapshot().canLoadOlder).toBe(true);

  await client.loadOlder();
  expect(daemon.nativeReads).toEqual([SEEDED_BEFORE, 4_000]);
  expect(prompts()).toEqual(questions(1, 2, 3, 4, 5, 6, 7, 8, 9));
  // Nothing older: the pane stops asking.
  expect(snapshot().canLoadOlder).toBe(false);
  await client.loadOlder();
  expect(daemon.nativeReads).toEqual([SEEDED_BEFORE, 4_000]);
  client.close();
});

test("a daemon that serves no native pages leaves the chat at its seeded turns", async () => {
  const daemon = fakeDaemon({ serves: false });
  const { client, snapshot, prompts } = await open(daemon);
  expect(snapshot().canLoadOlder).toBe(false);
  await client.loadOlder();
  expect(daemon.nativeReads).toEqual([]);
  expect(prompts()).toEqual(questions(7, 8, 9));
  client.close();
});

test("a peer's older daemon that answers method-not-found just stops the paging", async () => {
  const daemon = fakeDaemon({ unknown: true });
  const { client, snapshot, prompts } = await open(daemon);
  expect(snapshot().canLoadOlder).toBe(true);
  await client.loadOlder();
  expect(daemon.nativeReads).toEqual([SEEDED_BEFORE]);
  expect(prompts()).toEqual(questions(7, 8, 9));
  expect(snapshot().canLoadOlder).toBe(false);
  client.close();
});
