// l10n-allow-file: test fixture records, not shipped UI.
//
// A chat's settled pages (settledPages.ts): each finished turn written once, never changed, and
// drawn back as one unbroken run of the newest turns, bounded however long the chat is.
import { afterEach, expect, test } from "bun:test";
import type { EventRecord } from "./direct";
import {
  SETTLED_DRAW_EVENTS,
  forgetSettled,
  readSettled,
  resetSettledForTests,
  settle,
  settledPagesOf,
  settledTail,
  type SettledPage,
} from "./settledPages";

const CHAT = "settled-chat";
let seq = 0;
const record = (dir: string, kind: string, msg: Record<string, unknown> = {}): EventRecord => {
  seq += 1;
  return { sessionId: CHAT, seq, at: seq * 1000, dir: dir as EventRecord["dir"], kind, msg };
};
/// One finished turn: its prompt, the agent's reply, its end and result.
const turn = (n: number): EventRecord[] => [
  record("mux", "user_message", { text: `Question ${n}` }),
  record("mux", "turn_started"),
  record("in", "agent_message_chunk", {
    params: { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `Answer ${n}` } } },
  }),
  record("mux", "turn_end"),
  record("mux", "turn_result", { status: "completed" }),
];

afterEach(() => {
  seq = 0;
  resetSettledForTests(undefined);
});

test("a finished turn is one page, from its prompt through its result; the turn still running is none", () => {
  const events = [...turn(1), ...turn(2), record("mux", "user_message", { text: "Still going" })];
  const pages = settledPagesOf(CHAT, events, 0);
  expect(pages.map((page) => [page.firstSeq, page.lastSeq, page.after])).toEqual([
    [1, 5, 0],
    [6, 10, 5],
  ]);
});

test("a turn_end with nothing after it yet waits for its result", () => {
  const events = [...turn(1).slice(0, 4)];
  expect(settledPagesOf(CHAT, events, 0)).toEqual([]);
});

test("records that begin inside a turn start the pages at the next prompt", () => {
  const events = [...turn(1), ...turn(2)].slice(2);
  expect(settledPagesOf(CHAT, events, 0).map((page) => page.firstSeq)).toEqual([6]);
});

test("a page is written once: settling again writes only the turns that ended since", () => {
  const shared = new Map<string, SettledPage[]>();
  resetSettledForTests(shared);
  const first = [...turn(1), ...turn(2)];
  settle(CHAT, first);
  const written = shared.get(CHAT)!;
  expect(written.map((page) => page.firstSeq)).toEqual([1, 6]);
  const kept = written[0]!;
  settle(CHAT, [...first, ...turn(3)]);
  expect(shared.get(CHAT)!.map((page) => page.firstSeq)).toEqual([1, 6, 11]);
  // The first page is the same object, unchanged.
  expect(shared.get(CHAT)![0]).toBe(kept);
});

test("a new page reads the shared store, and draws its turns with no wait on acpmux", async () => {
  const shared = new Map<string, SettledPage[]>();
  resetSettledForTests(shared);
  settle(CHAT, [...turn(1), ...turn(2)], { createdAt: 7, peer: undefined });
  // Another tab: no pages in memory, the same app store.
  resetSettledForTests(shared);
  expect(settledTail(CHAT)).toBeUndefined();
  const tail = await readSettled(CHAT);
  expect(tail?.events.map((event) => event.seq)).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
  expect(tail?.summary).toEqual({ createdAt: 7 });
  // Never a claim the chat's history is read through: older turns still load from acpmux.
  expect(tail?.historyExhausted).toBe(false);
  // Read once, held in the page.
  expect(settledTail(CHAT)?.events.length).toBe(10);
});

test("only the newest unbroken run is drawn, and never more than a draw's bound", () => {
  resetSettledForTests(new Map());
  const many = Array.from({ length: 200 }, (_, n) => turn(n)).flat();
  settle(CHAT, many);
  const tail = settledTail(CHAT)!;
  expect(tail.events.length).toBeLessThanOrEqual(SETTLED_DRAW_EVENTS);
  expect(tail.events.at(-1)!.seq).toBe(many.at(-1)!.seq);
  // A later read past a hole starts a new run: the older run is not drawn under it.
  seq += 50;
  settle(CHAT, [record("mux", "agent_message_chunk"), ...turn(999)]);
  expect(settledTail(CHAT)!.events.map((event) => event.seq)[0]).toBe(seq - 4);
});

test("a forgotten chat draws nothing, here or from the shared store", async () => {
  const shared = new Map<string, SettledPage[]>();
  resetSettledForTests(shared);
  settle(CHAT, turn(1));
  forgetSettled(CHAT);
  expect(settledTail(CHAT)).toBeUndefined();
  expect(await readSettled(CHAT)).toBeUndefined();
});

test("another session generation under the same id replaces what was kept", () => {
  const shared = new Map<string, SettledPage[]>();
  resetSettledForTests(shared);
  settle(CHAT, turn(1), { createdAt: 1 });
  seq = 0;
  settle(CHAT, turn(2), { createdAt: 2 });
  expect(settledTail(CHAT)?.summary).toEqual({ createdAt: 2 });
  expect(settledTail(CHAT)?.events.length).toBe(5);
});
