// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A long chat's prompt index costs the rail no object per prompt (cmuxterm-hq goals/chats-flat-at-any-length.md: "A
// chat at 100k rows, and 20 such chats open, costs at most 1.2x an empty chat in renderer ... RSS"). The index names
// every prompt older than the held rows (direct.ts `readPromptIndex`), and the rail drew each as a row, a turn, a tick
// and a key map entry: about 15 MB of a 100k-row chat's renderer heap, 20 such chats 1080 MB against 489.5 MB empty
// (bench/chat-100k-flat.bench.ts, perf run 43793910041). The index is held as columns and the rail reads each prompt
// only when it draws or looks one up (railRows.ts), so what a chat keeps is the same at 1000 prompts as at 4000.
import { heapStats } from "bun:jsc";
import { expect, test } from "bun:test";
import { PromptHeads } from "../src/agent-session/acpmux/promptHeads";
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

const objects = () => {
  Bun.gc(true);
  return heapStats().objectCount;
};

/// The rail's model of a chat of `prompts` turns opened on its newest page, once its prompt index is read: the
/// objects it keeps (the client, its snapshot and the rail's rows), and those rows.
async function railOf(prompts: number) {
  const history = records(CHAT, Array.from({ length: prompts }, (_, n) => turn(n + 1)).flat());
  const before = objects();
  const chat = await fakeClient(history, { page: 40 });
  // The first snapshot asks for the index after its paint; its answer re-emits the snapshot.
  for (let n = 0; n < 50 && !chat.snapshot().earlierPrompts; n++) await settle(5);
  const snapshot = chat.snapshot();
  const read = minimapTurns(snapshot.rows, CHAT, undefined, undefined, snapshot.earlierPrompts, 0);
  const earlier = (read as { earlier?: unknown }).earlier as never;
  const turns = turnRows(read.turns, read.pendingCount ?? 0, CHAT, earlier);
  const ticks = tickRows(read.ticks, read.pendingCount ?? 0, CHAT, earlier);
  const kept = objects() - before;
  return { chat, turns, ticks, kept };
}

/// The objects a chat of `prompts` turns keeps with its rail, the fewer of two reads: each read's own chat is closed and
/// let go before the next, so only what that chat holds counts, and a collection running late adds to one read only.
async function keptBy(prompts: number): Promise<number> {
  const reads: number[] = [];
  for (let n = 0; n < 2; n += 1) {
    const rail = await railOf(prompts);
    expect(rail.ticks.length).toBe(prompts);
    reads.push(rail.kept);
    rail.chat.client.close();
  }
  return Math.min(...reads);
}

test("the prompt index costs the rail no object per prompt", async () => {
  // The first client in a process compiles the client's code: a warm-up read, not counted.
  (await railOf(200)).chat.client.close();
  const small = await keptBy(1000);
  const large = await keptBy(4000);
  const perPrompt = (large - small) / 3000;
  console.log(`rail objects kept: ${small} at 1000 prompts, ${large} at 4000 (${perPrompt.toFixed(2)} a prompt)`);
  // Before: a row, its id and text, a turn, its key, a tick and a map entry, about 9 a prompt.
  expect(perPrompt).toBeLessThan(2);
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

test("the index draws after a structuredClone, as a gallery's snapshot reaches its pane", () => {
  const rows = Array.from({ length: 3 }, (_, n) => ({
    id: `user-${n * 4 + 1}`,
    version: 1,
    at: n,
    kind: "user" as const,
    text: ` Prompt ${n} `,
    // The second repeats the first's promptId (a retried send): it keys on its row instead.
    ...(n < 2 ? { promptId: "p-0" } : {}),
  }));
  const heads = structuredClone(PromptHeads.fromRows(rows));
  const ticks = tickRows([], 0, CHAT, heads);
  expect(Array.from({ length: ticks.length }, (_, at) => ticks.at(at)!.key)).toEqual([
    `${CHAT}#prompt-p-0`,
    `${CHAT}#user-5`,
    `${CHAT}#user-9`,
  ]);
  expect(ticks.at(2)?.prompt).toBe("Prompt 2");
  expect(ticks.keyIndex(`${CHAT}#user-5`)).toBe(1);
  expect(ticks.keyIndex(`${CHAT}#prompt-p-0`)).toBe(0);
});
