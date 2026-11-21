// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A long chat's prompt index costs the rail no object per prompt (cmuxterm-hq goals/chats-flat-at-any-length.md: "A
// chat at 100k rows, and 20 such chats open, costs at most 1.2x an empty chat in renderer ... RSS"). The index names
// every prompt older than the held rows (direct.ts `readPromptIndex`), and the rail drew each as a row, a turn, a tick
// and a key map entry: about 15 MB of a 100k-row chat's renderer heap, 20 such chats 1080 MB against 489.5 MB empty
// (bench/chat-100k-flat.bench.ts, perf run 43793910041). The index is held as columns and the rail reads each prompt
// only when it draws or looks one up (railRows.ts), so what a chat keeps is the same at 1000 prompts as at 4000.
import { expect, test } from "bun:test";
import { minimapTurns } from "../src/agent-session/acpmux/threadMinimap/model";
import { tickRows, turnRows } from "../src/agent-session/acpmux/threadMinimap/railRows";
import { fakeClient, records, settle } from "./support/fakeAcpmuxClient";

const CHAT = "0190a000-0000-7000-8000-0000000c0de7";
const say = (text: string) => ({
  method: "session/update",
  params: { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
});
const turn = (n: number): [string, string, Record<string, unknown>][] => [
  ["mux", "user_message", { text: `Question ${n} about the lane`, promptId: `p-${n}`, turnId: `t-${n}` }],
  ["mux", "turn_started", { promptId: `p-${n}`, turnId: `t-${n}` }],
  ["in", "agent_message_chunk", say(`Answer ${n}`)],
  ["mux", "turn_result", { status: "completed", turnId: `t-${n}` }],
];

/// The rail's model of a chat of `prompts` turns opened on its newest page, once its prompt index is read: the
/// per-prompt objects it keeps (the snapshot's index as a list of rows, the rail's turns and ticks), and its rows.
async function railOf(prompts: number) {
  const history = records(CHAT, Array.from({ length: prompts }, (_, n) => turn(n + 1)).flat());
  const chat = await fakeClient(history, { page: 40 });
  // The first snapshot asks for the index after its paint; its answer re-emits the snapshot.
  for (let n = 0; n < 50 && !chat.snapshot().earlierPrompts; n++) await settle(5);
  const snapshot = chat.snapshot();
  const read = minimapTurns(snapshot.rows, CHAT, undefined, undefined, snapshot.earlierPrompts, 0);
  const earlier = (read as { earlier?: unknown }).earlier as never;
  const turns = turnRows(read.turns, read.pendingCount ?? 0, CHAT, earlier);
  const ticks = tickRows(read.ticks, read.pendingCount ?? 0, CHAT, earlier);
  // A row of the index as the snapshot holds it, a turn and a tick of the rail's model: each an object a prompt.
  const index = snapshot.earlierPrompts as unknown;
  const kept = new Set<unknown>([...(Array.isArray(index) ? index : []), ...read.turns, ...read.ticks]).size;
  return { chat, turns, ticks, kept, indexed: snapshot.earlierPrompts?.length ?? 0 };
}

test("the prompt index costs the rail no object per prompt", async () => {
  const small = await railOf(1000);
  small.chat.client.close();
  const large = await railOf(4000);
  large.chat.client.close();
  console.log(
    `per-prompt objects kept: ${small.kept} at 1000 prompts (${small.indexed} indexed), ${large.kept} at 4000 (${large.indexed} indexed)`,
  );
  // The index named the older prompts in both, and every prompt has its rail row.
  expect(small.indexed).toBeGreaterThan(900);
  expect(large.indexed).toBeGreaterThan(3900);
  expect(large.ticks.length).toBe(4000);
  // Before: the index's row, the rail's turn and its tick for every indexed prompt, 3 a prompt (and their ids, texts,
  // keys and a key map entry). Now what is kept is the held page's turns: the same at 4000 prompts as at 1000.
  expect(large.kept).toBe(small.kept);
});

test("every indexed prompt has its row, named and keyed as its turn is once its page is held", async () => {
  const rail = await railOf(4000);
  try {
    expect(rail.ticks.length).toBe(4000);
    expect(rail.turns.length).toBe(4000);
    expect(rail.ticks.at(0)?.prompt).toBe("Question 1 about the lane");
    expect(rail.ticks.at(0)?.key).toBe(`${CHAT}#prompt-p-1`);
    expect(rail.turns.at(2999)?.id).toMatch(/^user-\d+$/);
    expect(rail.ticks.keyIndex(`${CHAT}#prompt-p-3000`)).toBe(2999);
  } finally {
    rail.chat.client.close();
  }
});
