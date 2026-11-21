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
