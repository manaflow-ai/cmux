// l10n-allow-file: test fixture replies, not shipped UI.
// Chat text layered on top of itself (cmux#48659). acpmux stamps each run of reply text with a
// segment id that names its row in the pane (hub/stream.rs `reply_segment_for`). Text the agent
// wrote between turns was numbered from 1 again after every turn, so one id, `-.<boot>.1`, named two
// replies an hour apart (recorded: "The reviewer returned FIX ..." at seq 29270 and "The review is
// FIX ..." at seq 31206). The chat opens on its latest page, where only the later reply holds that
// id; the older page, once read, gave the id to the earlier reply. The row the chat had drawn at
// the bottom became the old reply, and its text drew over the rows under it. The fix names a
// between-turns reply by its segment and its message (`replyRowKey`), the same in every page.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved: [string, boolean, unknown][] = ["window", "document"].map((key) => [key, key in scope, scope[key]]);
beforeAll(() => Object.assign(scope, { window: dom.window, document: dom.window.document }));
afterAll(() => teardownDom(saved, { window: dom.window }));

const T0 = 1_795_241_000_000;
type Row = { id: string; kind: string; text?: string };
type Event = { seq: number; at: number; dir: string; kind: string; msg: unknown };

const OLD = "The reviewer returned FIX (advisory, since these are Linux renders).";
const NEW = "The review is FIX for one real defect: the URL-wrapping change.";
const LAST = "I stopped that build on purpose: the head is about to change.";

/// A turn, then a reply between turns, a turn, then another reply between turns that acpmux
/// stamped with the same segment as the first (the count started again after the turn).
function chat(): Event[] {
  let seq = 0;
  const events: Event[] = [];
  const event = (kind: string, msg: unknown, dir = "mux") => {
    seq += 1;
    events.push({ seq, at: T0 + seq * 1_000, dir, kind, msg });
  };
  const say = (text: string, messageId: string, segment: string) => {
    for (let at = 0; at < text.length; at += 20)
      event(
        "agent_message_chunk",
        {
          jsonrpc: "2.0",
          method: "session/update",
          params: {
            sessionId: "agent",
            _meta: { acpmux: { segment } },
            update: {
              sessionUpdate: "agent_message_chunk",
              messageId,
              content: { type: "text", text: text.slice(at, at + 20) },
            },
          },
        },
        "in",
      );
  };
  const turn = (id: string, prompt: string, reply: string, messageId: string) => {
    event("user_message", { client: "pane", promptId: `p-${id}`, text: prompt });
    event("turn_started", { client: "pane", prompt, promptId: `p-${id}`, turnId: id });
    say(reply, messageId, `${id}.b.1`);
    event("turn_end", { stopReason: "end_turn", turnId: id });
    event("turn_result", { status: "completed", turnId: id });
    event("status", { status: "ready" });
  };
  event("created", { harness: "claude" });
  turn("t1", "review the card", "Sending it to the reviewer.", "msg_t1");
  say(OLD, "msg_old", "-.b.1");
  turn("t2", "go on", "Pushed the fixes.", "msg_t2");
  say(NEW, "msg_new", "-.b.1");
  turn("t3", "status?", LAST, "msg_t3");
  return events;
}

async function rows(events: Event[]): Promise<Row[]> {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  let snapshot: { rows: Row[] } = { rows: [] };
  const client = AcpmuxDirectClient.replay("reused-segment", [...events] as never, (next) => {
    snapshot = next as never;
  });
  try {
    client.seekReplay(events.at(-1)!.seq);
  } finally {
    client.close();
  }
  return snapshot.rows;
}

const idOf = (all: Row[], text: string) => all.find((row) => row.kind === "assistant" && row.text === text)?.id;

test("a reply between turns keeps its row id whichever page the chat read first", async () => {
  const events = chat();
  const whole = await rows(events);
  // The chat's latest page: from the second turn on, without the earlier reply's records.
  const tail = await rows(events.slice(events.findIndex((event) => (event.msg as any)?.turnId === "t2") - 1));
  expect(idOf(tail, OLD)).toBeUndefined();
  expect(idOf(tail, NEW)).toBeDefined();
  expect(idOf(whole, NEW)).toBe(idOf(tail, NEW));
  // No id names one reply on one page and another reply on the other.
  const named = new Map<string, string>();
  for (const row of [...tail, ...whole])
    if (row.kind === "assistant") {
      const text = named.get(row.id);
      if (text !== undefined) expect({ id: row.id, text: row.text }).toEqual({ id: row.id, text });
      named.set(row.id, row.text ?? "");
    }
  // The whole log draws each reply once, in the order it came.
  const replies = whole.filter((row) => row.kind === "assistant").map((row) => row.text);
  expect(replies.filter((text) => text === OLD)).toHaveLength(1);
  expect(replies.indexOf(OLD)).toBeLessThan(replies.indexOf(NEW));
  expect(replies.indexOf(NEW)).toBeLessThan(replies.indexOf(LAST));
});

// The second report (2026-11-23): a chat where "Shard 1 found a real issue in my code ..." drew 3-4
// times over the rows above it. Its log (seq 6841..10209) reused `-.<boot>.1` and `-.<boot>.2`
// across turns: the reply segments, message ids and order below are the recorded ones, the texts cut
// short. The pane opens on the latest page (from seq 7300 here, past the first `-.2` reply), then
// reads the older pages, as it does when the reader scrolls up or the rail fills. The page before
// it holds a turn's start, so that read folds every row again (direct.ts `rebuildKeepingLiveState`):
// on the base, that refold gave `-.<boot>.2` to the earlier reply, and the row the chat drew as
// "Shard 1 found ..." became "Now the CSS for opened wrapping rows:".
const BOOT = "1a2072ef810";
function reportedChat(): Event[] {
  let seq = 6_800;
  const events: Event[] = [];
  const event = (kind: string, msg: unknown, dir = "mux", at?: number) => {
    seq = at ?? seq + 1;
    events.push({ seq, at: T0 + seq * 100, dir, kind, msg });
  };
  const say = (text: string, messageId: string, segment: string, at?: number) => {
    const chunk = (piece: string, where?: number) =>
      event(
        "agent_message_chunk",
        {
          jsonrpc: "2.0",
          method: "session/update",
          params: {
            sessionId: "agent",
            _meta: { acpmux: { segment } },
            update: { sessionUpdate: "agent_message_chunk", messageId, content: { type: "text", text: piece } },
          },
        },
        "in",
        where,
      );
    chunk(text.slice(0, 12), at);
    chunk(text.slice(12));
  };
  const turn = (id: string, at: number, replies: [string, string][]) => {
    event("user_message", { client: "pane", promptId: `p-${id}`, text: "go on" }, "mux", at);
    event("turn_started", { client: "pane", prompt: "go on", promptId: `p-${id}`, turnId: id });
    replies.forEach(([text, messageId], index) => say(text, messageId, `${id}.${BOOT}.${index + 3}`));
    event("turn_end", { stopReason: "end_turn", turnId: id });
    event("turn_result", { status: "completed", turnId: id });
    event("status", { status: "ready" });
  };
  event("created", { harness: "claude" });
  // The turn before them: the older page brings its start, so the chat folds every row again.
  turn("01a2075d-7e05-7263-a29f-bf5b849f2720", 6_801, [["The review fixes are pushed.", "msg_01ReviewFixesPushed"]]);
  say("The review found no blocking issues in the CSS fix.", "msg_019JiKSydt0rEx3NLpLO8lDa", `-.${BOOT}.1`, 6_841);
  say("Now the CSS for opened wrapping rows:", "msg_010AyQSzDzdLduUHMFZMAjfC", `-.${BOOT}.2`, 7_265);
  say("That notice is from an earlier fetch.", "msg_018KfCAfYPqXuReb3U8aPa5X", `-.${BOOT}.1`, 8_968);
  turn("01a20785-d377-7751-8f72-45012d6e2c59", 9_500, [
    ["The background tab probably never loaded.", "msg_010ZzNOxRMCyxrQsTv3YzkBJ"],
    ["Still loading. The Monitor will tell me once the app is installed.", "msg_014JjNAeQkBq1XEjYPSNy1ES"],
    ["Downloaded and being prepared.", "msg_010VsPWdzT77zj9GZipy7fMQ"],
  ]);
  say("The tagged app is running now.", "msg_010UiLJ7RhpleEozFQ9Jl4En", `-.${BOOT}.1`, 10_053);
  say("Shard 1 found a real issue in my code.", "msg_019AxYU3IrxbzKxLOyEzIX5g", `-.${BOOT}.2`, 10_196);
  return events.map((record) => ({ sessionId: CHAT, ...record }));
}

const CHAT = "0190a000-0000-7000-8000-0000000048b9";
/// A daemon that opens on the records from `from` on and pages older ones back, as acpmux does.
function pagingDaemon(history: Event[], from: number) {
  let socket: any;
  const last = history.at(-1)!.seq;
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 1,
    updatedAt: T0,
  };
  const answer = (method: string, params: any) => {
    if (method === "initialize")
      return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    if (method === "_acpmux/watch") return { sessions: [session] };
    if (method === "_acpmux/attach")
      return { session, lastSeq: last, events: history.filter((event) => event.seq >= from), hasMore: true };
    if (method === "_acpmux/events") {
      const older = history.filter((event) => event.seq < (params?.beforeSeq ?? Infinity));
      const events = older.slice(-(params?.limit ?? 5000));
      return { events, hasMore: older.length > events.length, lastSeq: last };
    }
    return null;
  };
  return () => {
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
}

const settle = async () => {
  for (let index = 0; index < 8; index += 1) await new Promise((resolve) => setTimeout(resolve, 0));
};

test("the reported chat's rows keep their text when the older pages come in after the latest one", async () => {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  let rows: Row[] = [];
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://127.0.0.1:1/",
      token: "t",
      sessionId: CHAT,
    },
    (snapshot: any) => {
      if (snapshot.type === "snapshot") rows = snapshot.rows;
    },
    undefined,
    pagingDaemon(reportedChat(), 7_300),
  );
  try {
    await settle();
    const opened = new Map(rows.filter((row) => row.kind === "assistant").map((row) => [row.id, row.text]));
    expect([...opened.values()]).toContain("Shard 1 found a real issue in my code.");
    for (let page = 0; page < 4; page += 1) {
      await client.loadOlder();
      await settle();
    }
    const read = rows.filter((row) => row.kind === "assistant");
    // Every row drawn at the open still draws what it drew: none was handed an older reply's text.
    for (const [id, text] of opened)
      expect({ id, text: read.find((row) => row.id === id)?.text }).toEqual({ id, text });
    // The whole chat, once read, draws each reply once, in the order it came.
    expect(read.map((row) => row.text)).toEqual([
      "The review fixes are pushed.",
      "The review found no blocking issues in the CSS fix.",
      "Now the CSS for opened wrapping rows:",
      "That notice is from an earlier fetch.",
      "The background tab probably never loaded.",
      "Still loading. The Monitor will tell me once the app is installed.",
      "Downloaded and being prepared.",
      "The tagged app is running now.",
      "Shard 1 found a real issue in my code.",
    ]);
  } finally {
    client.close();
  }
});
