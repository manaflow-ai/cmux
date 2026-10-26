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
  // The first keeps the prompt's key; the echo beside it keys on its row.
  expect(ticks[1]!.key).toBe(turnKey(CHAT, rows[2]!));
  expect(ticks[2]!.key).toBe(`${turnKey(CHAT, rows[3]!)}#user-2`);
});
