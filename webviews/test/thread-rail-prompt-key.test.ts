// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A prompt's tick on the thread rail keys on its promptId (model.ts turnKey), the same while this
// pane sends it, after acpmux's echo, and when the history is read again (a reconnect, a relaunch,
// another pane): the rail keeps one tick element for it, and a step or jump that looks its turn up by
// key finds it. Before: a live send keyed on its delivery and a replayed one on its row id, so the
// same prompt changed keys and its tick was mounted again.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { minimapTurns, turnKey } from "../src/agent-session/acpmux/threadMinimap/model";
import { fakeClient, records } from "./support/fakeAcpmuxClient";

const CHAT = "0190a000-0000-7000-8000-0000000c0de1";
const say = (text: string) => ({
  method: "session/update",
  params: { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
});
const turn = (n: number): [string, string, Record<string, unknown>][] => [
  ["mux", "user_message", { text: `Question ${n}`, promptId: `p-${n}`, turnId: `t-${n}` }],
  ["mux", "turn_started", { promptId: `p-${n}`, turnId: `t-${n}` }],
  ["in", "agent_message_chunk", say(`Answer ${n}`)],
  ["mux", "turn_result", { status: "completed", turnId: `t-${n}` }],
];

test("a prompt read from the history keys its tick as its live send did", async () => {
  const history = records(CHAT, [1, 2, 3, 4, 5].flatMap(turn));
  const { rows } = await fakeClient(history);
  const replayed = rows().filter((row) => row.kind === "user");
  expect(replayed.map((row) => row.promptId)).toEqual(["p-1", "p-2", "p-3", "p-4", "p-5"]);
  // The pane's own row for the last prompt while it was sending, and acpmux's echo of it here.
  const live: AcpmuxRow = {
    id: "local-p-5",
    version: 1,
    at: 0,
    kind: "user",
    text: "Question 5",
    pending: true,
    delivery: { state: "sending", promptId: "p-5", sessionId: CHAT, sentAt: 0 },
  };
  expect(turnKey(CHAT, replayed.at(-1)!)).toBe(turnKey(CHAT, live));
  // The rail as the pane drew it live, then the rows read again: the same ticks, the same objects.
  const sent = [...rows().filter((row) => row.id !== replayed.at(-1)!.id), live];
  const before = minimapTurns(sent, CHAT);
  const after = minimapTurns(rows(), CHAT, before);
  expect(after.ticks.map((tick) => tick.key)).toEqual(before.ticks.map((tick) => tick.key));
  expect(after.ticks.at(-1)!.key).toBe(before.ticks.at(-1)!.key);
});

test("a prompt whose shown text changes keeps its key", () => {
  const raw: AcpmuxRow = {
    id: "user-9",
    version: 1,
    at: 0,
    kind: "user",
    text: "panel -> this-chat: done",
    promptId: "p-9",
  };
  const shown: AcpmuxRow = { ...raw, version: 2, text: "done" };
  expect(turnKey(CHAT, shown)).toBe(turnKey(CHAT, raw));
  // A prompt acpmux recorded without a promptId (an older log) keys on its row.
  expect(turnKey(CHAT, { ...raw, promptId: undefined })).toBe(`${CHAT}#user-9`);
});

test("a failed send beside its echo, one promptId: two ticks, each with its own key", () => {
  const user = (id: string, text: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
    id,
    version: 1,
    at: 0,
    kind: "user",
    text,
    promptId: "p-7",
    ...extra,
  });
  const reply = (id: string, text: string): AcpmuxRow => ({ id, version: 1, at: 0, kind: "assistant", text });
  const rows = [
    user("user-1", "First", { promptId: "p-1" }),
    reply("a-1", "One"),
    // The send that timed out, kept as a failed row, then acpmux's echo of the same prompt.
    user("local-p-7", "Again", {
      promptId: undefined,
      delivery: { state: "failed", promptId: "p-7", sessionId: CHAT, sentAt: 0 },
    } as Partial<AcpmuxRow>),
    user("user-2", "Again"),
    reply("a-2", "Two"),
  ];
  const { ticks } = minimapTurns(rows, CHAT);
  expect(ticks).toHaveLength(3);
  expect(new Set(ticks.map((tick) => tick.key)).size).toBe(3);
  // The failed send keys on its row; acpmux's echo holds the prompt's key.
  expect(ticks[1]!.key).toBe(`${CHAT}#local-p-7`);
  expect(ticks[2]!.key).toBe(`${CHAT}#prompt-p-7`);
  // A resync can put the failed row after later prompts (direct.ts keeps it past replayed events):
  // echo, the next prompt, then the failed send. Still one key per tick.
  const resynced = [rows[0]!, rows[1]!, rows[3]!, rows[4]!, user("user-3", "Later", { promptId: "p-8" }), rows[2]!];
  const after = minimapTurns(resynced, CHAT).ticks;
  expect(after).toHaveLength(4);
  expect(new Set(after.map((tick) => tick.key)).size).toBe(4);
  // Retry reuses the promptId and puts the failed row back to sending beside the echo (direct.ts
  // retryPrompt, sendNow): both keys are the prompt's, and the second tick keys on its row too.
  const retried = { ...rows[2]!, delivery: { ...rows[2]!.delivery!, state: "sending" as const } };
  for (const order of [
    [rows[0]!, rows[1]!, retried, rows[3]!, rows[4]!],
    [rows[0]!, rows[1]!, rows[3]!, rows[4]!, user("user-3", "Later", { promptId: "p-8" }), retried],
  ]) {
    const ticks = minimapTurns(order, CHAT).ticks;
    expect(new Set(ticks.map((tick) => tick.key)).size).toBe(ticks.length);
  }
});

test("a streamed token beside a repeated key keeps the same ticks", () => {
  const user = (id: string, promptId: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow =>
    ({ id, version: 1, at: 0, kind: "user", text: "Again", promptId, ...extra }) as AcpmuxRow;
  const reply = (text: string): AcpmuxRow => ({ id: "a-2", version: 1, at: 0, kind: "assistant", text });
  const sending = user("local-p-7", "p-7", {
    promptId: undefined,
    delivery: { state: "sending", promptId: "p-7", sessionId: CHAT, sentAt: 0 },
  });
  const base = [user("user-1", "p-1"), user("user-2", "p-7"), sending];
  const first = minimapTurns([...base, reply("Tw")], CHAT);
  const next = minimapTurns([...base, reply("Two")], CHAT, first);
  // The reply streamed; the ticks are the same list, so the rail renders no row for it.
  expect(next.ticks).toBe(first.ticks);
  expect(new Set(next.ticks.map((tick) => tick.key)).size).toBe(3);
});

test("older turns arriving find the anchored tick, not an earlier one with its prompt's key", async () => {
  const { prependedBy } = await import("../src/agent-session/acpmux/threadMinimap/ThreadMinimap");
  const user = (id: string, promptId: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow =>
    ({ id, version: 1, at: 0, kind: "user", text: id, promptId, ...extra }) as AcpmuxRow;
  // acpmux's echo of p-7, then the pane's retried send of it (one promptId), then a later prompt.
  const retried = user("local-p-7", "p-7", {
    promptId: undefined,
    delivery: { state: "sending", promptId: "p-7", sessionId: CHAT, sentAt: 0 },
  });
  const rows = [user("user-1", "p-1"), user("user-2", "p-7"), retried, user("user-3", "p-8")];
  const before = minimapTurns(rows, CHAT).ticks;
  const ref = (index: number) => ({ key: before[index]!.key, id: before[index]!.id });
  // The band's first tick is the retried send's (index 2).
  const anchor = { tick: ref(2), first: ref(0), index: 2, layoutTop: 0, y: 0 };
  // One older turn arrives above: the retried send is now at index 3.
  const after = minimapTurns([user("user-0", "p-0"), ...rows], CHAT).ticks;
  expect(prependedBy(anchor, after)).toBe(1);
  // Nothing arrived: no shift.
  expect(prependedBy(anchor, before)).toBeUndefined();
});

test("an older echo with the first tick's promptId arriving above moves no tick to its key", async () => {
  const { prependedBy, tickIndex } = await import("../src/agent-session/acpmux/threadMinimap/ThreadMinimap");
  const user = (id: string, promptId: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow =>
    ({ id, version: 1, at: 0, kind: "user", text: id, promptId, ...extra }) as AcpmuxRow;
  // The rail starts at the pane's retried send of p-7 (no echo of it loaded yet), then two more.
  const retried = user("local-p-7", "p-7", {
    promptId: undefined,
    delivery: { state: "sending", promptId: "p-7", sessionId: CHAT, sentAt: 0 },
  });
  const rows = [retried, user("user-3", "p-8"), user("user-4", "p-9")];
  const before = minimapTurns(rows, CHAT).ticks;
  const ref = (index: number) => ({ key: before[index]!.key, id: before[index]!.id });
  const anchor = { tick: ref(0), first: ref(0), index: 0, layoutTop: 0, y: 0 };
  // The older echo of p-7 loads above it: the retried send keeps its tick's key (the rail's focus,
  // hover, card and list key stay on it), and the echo keys on its row.
  const after = minimapTurns([user("user-2", "p-7"), ...rows], CHAT, minimapTurns(rows, CHAT)).ticks;
  expect(after[1]!.id).toBe("local-p-7");
  expect(after[1]!.key).toBe(before[0]!.key);
  expect(after[0]!.key).toBe(`${before[0]!.key}#user-2`);
  // The anchored tick is the retried send's, now at index 1, and a step under way still finds it.
  expect(prependedBy(anchor, after)).toBe(1);
  expect(tickIndex(after, ref(0))).toBe(1);
  // acpmux's echo replacing this pane's row for a send (a new row id, the same key) is still found.
  expect(tickIndex(after, { key: after[2]!.key, id: "local-p-8" })).toBe(2);
});
