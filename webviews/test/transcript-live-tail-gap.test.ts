// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The live tail settles to the reply's exact text after acpmux drops streamed chunks under load.
// Leo, 2026-11-06, on the coordinator's long chat with acpmux at several cores and his messages
// arriving late: "my messages right now are so slowly getting to you that iam seeing messages and
// formating get cut off" (a table's separator row with no header above it, a bold close with no
// opening, in one reply).
//
// acpmux drops a slow connection's notifications when its outbound queue fills, and sends one
// `_acpmux/lagged` (server/outbound.rs); the pane reads the missed records again from its cursor.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const CHAT = "0190a000-0000-7000-8000-0000000000f1";
const START = Date.UTC(2026, 10, 6, 5, 0, 0);
type Rec = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };

const chunk = (seq: number, text: string): Rec => ({
  sessionId: CHAT,
  seq,
  at: START + seq * 100,
  dir: "in",
  kind: "agent_message_chunk",
  msg: {
    method: "session/update",
    params: { update: { sessionUpdate: "agent_message_chunk", messageId: "m-1", content: { type: "text", text } } },
  },
});
const mux = (seq: number, kind: string, msg: Record<string, unknown>): Rec => ({
  sessionId: CHAT,
  seq,
  at: START + seq * 100,
  dir: "mux",
  kind,
  msg,
});

const PARTS = [
  "Open items:\n\n",
  "| # | Question | Owner | State |\n",
  "|---|---|---|---|\n",
  "| (1) | **Who owns an accepted prompt across Stop:** acpmux-owner | open | ",
  "confirmed idle sessions already move |\n",
];
const opened = [
  mux(1, "user_message", { text: "what's open?", promptId: "p-1", turnId: "turn-1" }),
  mux(2, "turn_started", { promptId: "p-1", turnId: "turn-1" }),
];
const chunks = PARTS.map((text, index) => chunk(3 + index, text));
const ended = mux(3 + PARTS.length, "turn_result", { promptId: "p-1", turnId: "turn-1", status: "completed" });
const all = [...opened, ...chunks, ended];

/// A pane attached after `opened`, whose live events are `live` (`_acpmux/event`, in order);
/// `events` answers each `_acpmux/events` read after a cursor, or throws to fail it.
async function pane(events: (after: number, call: number) => Rec[], attached: Rec[] = opened) {
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness: "claude",
    family: "claude",
    status: "running",
    steering: false,
    turnCount: 1,
    updatedAt: START,
  };
  let reads = 0;
  const answer = (method: string, params: any) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: attached.at(-1)!.seq, events: attached, hasMore: false };
      case "_acpmux/events": {
        const page = events(Number(params?.afterSeq ?? 0), reads++);
        return { events: page, hasMore: false, more: false, lastSeq: page.at(-1)?.seq ?? 0 };
      }
      default:
        return null;
    }
  };
  let socket: any;
  const open = () => {
    socket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id === undefined) return;
        queueMicrotask(() => {
          let reply: Record<string, unknown>;
          try {
            reply = { result: answer(message.method, message.params) };
          } catch (error) {
            reply = { error: { code: -32603, message: String(error) } };
          }
          socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, ...reply }) });
        });
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  let rows: AcpmuxRow[] = [];
  let waiters: { holds: () => boolean; done: () => void }[] = [];
  const check = () => {
    const due = waiters.filter((waiter) => waiter.holds());
    waiters = waiters.filter((waiter) => !due.includes(waiter));
    for (const waiter of due) waiter.done();
  };
  /// Resolves once the pane's rows show `holds`; bun's test timeout is its deadline.
  const until = (holds: () => boolean) =>
    new Promise<void>((done) => {
      waiters.push({ holds, done });
      check();
    });
  await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: any) => {
      rows = snapshot.rows;
      check();
    },
    undefined,
    open,
  );
  await until(() => rows.length > 0);
  const notify = (method: string, params: unknown) =>
    socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method, params }) });
  return {
    live: (record: Rec) => notify("_acpmux/event", record),
    lagged: () => notify("_acpmux/lagged", { dropped: 1, reason: "output_queue_full" }),
    reply: () => rows.find((row) => row.kind === "assistant")?.text,
    replies: () => rows.filter((row) => row.kind === "assistant").map((row) => row.text),
    order: () => rows.filter((row) => row.kind === "assistant" || row.kind === "user").map((row) => row.kind),
    until,
  };
}

test("chunks acpmux dropped come back after its lag marker: the reply is its exact text", async () => {
  const p = await pane((after) => all.filter((record) => record.seq > after));
  p.live(chunks[0]!);
  // The queue filled: the header row's chunk is dropped, and the marker comes in its place.
  p.lagged();
  for (const record of [...chunks.slice(2), ended]) p.live(record);
  await p.until(() => p.reply() === PARTS.join(""));
  expect(p.reply()).toBe(PARTS.join(""));
});

test("a read of the dropped chunks that fails under load is tried again until the reply is whole", async () => {
  // The daemon is too busy to answer the first read (load 130, acpmux at several cores).
  let failed = false;
  const p = await pane((after) => {
    // The first read after the lag marker (from the header's chunk on) times out.
    if (after >= 3 && !failed) {
      failed = true;
      throw new Error("timed out");
    }
    return all.filter((record) => record.seq > after);
  });
  p.live(chunks[0]!);
  p.lagged();
  for (const record of [...chunks.slice(2), ended]) p.live(record);
  await p.until(() => p.reply() === PARTS.join(""));
  expect(failed).toBe(true);
  expect(p.reply()).toBe(PARTS.join(""));
});

test("a reply whose turn end was dropped never takes the next reply's text once the read lands", async () => {
  // The next turn's chunks carry no messageId, so while the end is missing they look like more of the reply.
  const next = [
    mux(9, "user_message", { text: "and the owners?", promptId: "p-2", turnId: "turn-2" }),
    mux(10, "turn_started", { promptId: "p-2", turnId: "turn-2" }),
    {
      ...chunk(11, "Owners are listed above."),
      msg: {
        method: "session/update",
        params: {
          update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Owners are listed above." } },
        },
      },
    },
    mux(12, "turn_result", { promptId: "p-2", turnId: "turn-2", status: "completed" }),
  ];
  const history = [...all, ...next];
  let failed = false;
  const p = await pane((after) => {
    if (after >= 7 && !failed) {
      failed = true;
      throw new Error("timed out");
    }
    return history.filter((record) => record.seq > after);
  });
  for (const record of chunks) p.live(record);
  // The first turn's end is dropped.
  p.lagged();
  for (const record of next) p.live(record);
  await p.until(() => p.replies().length === 2 && p.replies()[0] === PARTS.join(""));
  expect(failed).toBe(true);
  expect(p.replies()).toEqual([PARTS.join(""), "Owners are listed above."]);
});

test("a finished reply is its stored text even when acpmux dropped chunks with no lag marker", async () => {
  // The coordinator's chat under load: one reply lost a middle piece ("without a focus-ring-stuck-2"),
  // another its first lines ("cosmic-gray myself at 05:49Z, ..."), and both stayed so once finished.
  const p = await pane((after) => all.filter((record) => record.seq > after));
  for (const record of [chunks[2]!, chunks[4]!, ended]) p.live(record);
  await p.until(() => p.reply() === PARTS.join(""));
  expect(p.reply()).toBe(PARTS.join(""));
});

test("a finished reply whose stored text the pane already has reads it once and changes nothing", async () => {
  let reads = 0;
  let endSent = false;
  let read!: () => void;
  const checked = new Promise<void>((resolve) => (read = resolve));
  const p = await pane((after) => {
    if (endSent) {
      reads += 1;
      queueMicrotask(read);
    }
    return all.filter((record) => record.seq > after);
  });
  for (const record of chunks) p.live(record);
  endSent = true;
  p.live(ended);
  await checked;
  await p.until(() => p.reply() === PARTS.join(""));
  expect(reads).toBe(1);
  expect(p.reply()).toBe(PARTS.join(""));
});

test("a reply whose first chunks were dropped before a steer is whole above the steer", async () => {
  // Leo, 2026-11-06 07:02Z, "how is your text getting cut off?": no reply above his message, and
  // below it a fragment from mid-sentence ("on a usage or rate limit ...") to a lone "If".
  const steer = mux(5, "user_message", { text: "why is this still happening", promptId: "p-2", steer: true });
  const texts = [
    "Revive only the sessions that stopped ",
    "on a usage or rate limit and list the work each one holds. ",
    "If one holds a PR, keep it.",
  ];
  const reply = [chunk(3, texts[0]!), chunk(4, texts[1]!), chunk(6, texts[2]!)];
  const end = mux(7, "turn_result", { promptId: "p-1", turnId: "turn-1", status: "completed" });
  const history = [...opened, reply[0]!, reply[1]!, steer, reply[2]!, end];
  let lagged = false;
  let failed = false;
  const p = await pane((after) => {
    // The busy daemon fails the first read after the marker.
    if (lagged && !failed) {
      failed = true;
      throw new Error("timed out");
    }
    return history.filter((record) => record.seq > after);
  });
  // The reply's first chunks are dropped and the marker takes their place; the steer and the rest arrive.
  lagged = true;
  p.lagged();
  for (const record of [steer, reply[2]!]) p.live(record);
  await p.until(() => p.replies()[0] === texts.join(""));
  expect(failed).toBe(true);
  expect(p.replies()).toEqual([texts.join("")]);
  expect(p.order()).toEqual(["user", "assistant", "user"]);
});

test("the same reply with no marker at all is whole above the steer once its turn ends", async () => {
  const steer = mux(5, "user_message", { text: "why is this still happening", promptId: "p-2", steer: true });
  const texts = ["Revive only the sessions that stopped ", "on a usage or rate limit. ", "If one holds a PR, keep it."];
  const reply = [chunk(3, texts[0]!), chunk(4, texts[1]!), chunk(6, texts[2]!)];
  const end = mux(7, "turn_result", { promptId: "p-1", turnId: "turn-1", status: "completed" });
  const history = [...opened, reply[0]!, reply[1]!, steer, reply[2]!, end];
  const p = await pane((after) => history.filter((record) => record.seq > after));
  for (const record of [steer, reply[2]!, end]) p.live(record);
  await p.until(() => p.replies()[0] === texts.join(""));
  expect(p.replies()).toEqual([texts.join("")]);
  expect(p.order()).toEqual(["user", "assistant", "user"]);
});

test("a turn that records its end before its result is still read whole", async () => {
  // acpmux records `turn_end` just before the same turn's `turn_result`; the check took it for the
  // previous turn's end and never read the turn.
  const turnEnd = mux(3 + PARTS.length, "turn_end", { promptId: "p-1", turnId: "turn-1" });
  const result = mux(4 + PARTS.length, "turn_result", { promptId: "p-1", turnId: "turn-1", status: "completed" });
  const history = [...opened, ...chunks, turnEnd, result];
  const p = await pane((after) => history.filter((record) => record.seq > after));
  for (const record of [chunks[2]!, chunks[4]!, turnEnd, result]) p.live(record);
  await p.until(() => p.reply() === PARTS.join(""));
  expect(p.reply()).toBe(PARTS.join(""));
});

test("a turn whose opening is older than the records the pane holds is read from the oldest one held", async () => {
  // The turn began before the pane's kept window: its opening is not held, but the part shown is repaired.
  const tail = [chunk(3, "Older text. "), chunk(4, "Shown first. "), chunk(5, "Lost piece. "), chunk(6, "Last piece.")];
  const end = mux(7, "turn_result", { promptId: "p-1", turnId: "turn-1", status: "completed" });
  const history = [...opened, ...tail, end];
  const p = await pane((after) => history.filter((record) => record.seq > after), [tail[1]!]);
  for (const record of [tail[3]!, end]) p.live(record);
  await p.until(() => p.reply() === "Shown first. Lost piece. Last piece.");
  expect(p.reply()).toBe("Shown first. Lost piece. Last piece.");
});
