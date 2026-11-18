// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The thread rail lays out a long chat's every turn from its first frame: the prompts older than
// the held rows come from acpmux's prompt index (the snapshot's `earlierPrompts`), and an older
// page that brings them in fills their ticks instead of adding any. Leo (2026-10-31): "i hate how
// this keeps shifting all the time when things grow + the fact that things grow instead of just
// showing me a big preview of the stuff from teh start".
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { currentTurn, minimapTurns, visibleTurns } from "../src/agent-session/acpmux/threadMinimap/model";
import { fakeClient, records } from "./support/fakeAcpmuxClient";

const CHAT = "0190a000-0000-7000-8000-0000000c0de2";
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

/// The index's row for a prompt, as direct.ts `readPromptIndex` builds it.
const indexed = (row: AcpmuxRow): AcpmuxRow => ({
  id: row.id,
  version: 1,
  at: row.at,
  kind: "user",
  text: row.text,
  ...(row.promptId ? { promptId: row.promptId } : {}),
});

test("the rail holds every turn's tick while history pages in", async () => {
  const { rows } = await fakeClient(records(CHAT, Array.from({ length: 12 }, (_, n) => turn(n + 1)).flat()));
  const all = rows();
  const prompts = all.filter((row) => row.kind === "user");
  const whole = minimapTurns(all, CHAT);
  expect(whole.ticks).toHaveLength(12);
  const keys = whole.ticks.map((tick) => tick.key);
  // Held from the n-th prompt on, with the index's rows for the ones before it.
  const heldFrom = (n: number, previous?: ReturnType<typeof minimapTurns>) => {
    const first = all.indexOf(prompts[n]!);
    return minimapTurns(all.slice(first), CHAT, previous, undefined, prompts.slice(0, n).map(indexed));
  };
  const open = heldFrom(9);
  expect(open.ticks.map((tick) => tick.key)).toEqual(keys);
  expect(open.loadedStart).toBe(9);
  // Each older page: the same ticks in the same places, the newly held ones now real turns.
  let previous = open;
  for (const n of [6, 3, 0]) {
    const next = heldFrom(n, previous);
    expect(next.ticks.map((tick) => tick.key)).toEqual(keys);
    expect(next.turns.map((turn) => turn.index >= 0)).toEqual(keys.map((_, index) => index >= n));
    previous = next;
  }
});

test("the index arriving after the open, then a streamed reply, keeps every tick once and in order", async () => {
  const { rows } = await fakeClient(records(CHAT, Array.from({ length: 8 }, (_, n) => turn(n + 1)).flat()));
  const all = rows();
  const prompts = all.filter((row) => row.kind === "user");
  const keys = minimapTurns(all, CHAT).ticks.map((tick) => tick.key);
  const held = all.slice(all.indexOf(prompts[5]!));
  const earlier = prompts.slice(0, 5).map(indexed);
  // First frame: no index yet. Then it lands. Then the last reply streams over several snapshots.
  let read = minimapTurns(held, CHAT);
  read = minimapTurns(held, CHAT, read, undefined, earlier);
  expect(read.ticks.map((tick) => tick.key)).toEqual(keys);
  const reply = [...held].reverse().find((row) => row.kind === "assistant")!;
  for (let n = 0; n < 6; n++) {
    const streamed = held.map((row) => (row === reply ? { ...row, text: `${row.text} more ${n}` } : row));
    const next = minimapTurns(streamed, CHAT, read, undefined, earlier);
    expect(next.ticks.map((tick) => tick.key)).toEqual(keys);
    expect(next.turns.map((turn) => turn.index >= 0)).toEqual(keys.map((_, index) => index >= 5));
    // The committed result's lists are never written into by the next read.
    expect(read.turns.map((turn) => turn.key)).toEqual(keys);
    read = next;
  }
});

test("held from the middle, the prompts past the held rows are later ticks, and the reader is never on one", async () => {
  const { rows } = await fakeClient(records(CHAT, Array.from({ length: 9 }, (_, n) => turn(n + 1)).flat()));
  const all = rows();
  const prompts = all.filter((row) => row.kind === "user");
  const keys = minimapTurns(all, CHAT).ticks.map((tick) => tick.key);
  // Held: turns 4 to 6. Earlier: 1 to 3. Later (a store chat's `laterPrompts`): 7 to 9.
  const held = all.slice(all.indexOf(prompts[3]!), all.indexOf(prompts[6]!));
  const earlier = prompts.slice(0, 3).map(indexed);
  const read = minimapTurns(held, CHAT, undefined, undefined, earlier, 0, prompts.slice(6).map(indexed));
  expect(read.ticks.map((tick) => tick.key)).toEqual(keys);
  expect(read.turns.map((turn) => turn.index >= 0)).toEqual(keys.map((_, index) => index >= 3 && index < 6));
  expect(read.loadedStart).toBe(3);
  // Each held turn's top is its row's; a later turn has none (index -1). Scrolled past the last held
  // prompt, the reader is on turn 6, not on a later tick.
  const tops = (index: number) => (index >= 0 && index < held.length ? index * 100 : undefined);
  expect(currentTurn(read.turns, tops, 10_000, 600, 3, 6)).toBe(5);
  expect(visibleTurns(read.turns, tops, held.length * 100, 10_000, 600, 3, 6).last).toBe(5);
  // A later prompt held again (a later tick's click): the same ticks, in the same places.
  const more = all.slice(all.indexOf(prompts[3]!), all.indexOf(prompts[7]!));
  const next = minimapTurns(more, CHAT, read, undefined, earlier, 0, prompts.slice(7).map(indexed));
  expect(next.ticks.map((tick) => tick.key)).toEqual(keys);
  expect(next.turns.map((turn) => turn.index >= 0)).toEqual(keys.map((_, index) => index >= 3 && index < 7));
});
