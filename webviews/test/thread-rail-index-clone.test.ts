// A snapshot copied with structuredClone (a gallery's, on its way to the pane) keeps its prompt index whole: the index
// is plain columns (promptHeads.ts), read through the PromptHeads functions, and the rail draws it. A promptId an
// earlier prompt already has keys on its row, so every tick's key is its own.
import { expect, test } from "bun:test";
import { PromptHeads } from "../src/agent-session/acpmux/promptHeads";
import { tickRows } from "../src/agent-session/acpmux/threadMinimap/railRows";

const CHAT = "0190a000-0000-7000-8000-0000000c0de8";

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
